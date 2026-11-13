#!/usr/bin/env bash
set +x
set -euo pipefail
umask 077
ulimit -c 0 2>/dev/null || true  # no core dumps — they would capture resolved plaintext from memory

# secrets-seed — resolve every op:// reference in dotfiles-private/headless.refs
# via biometric `op read` (human present) and seal them into a single SOPS+age
# cache (cache/secrets.enc.json) as an `op://ref -> value` map. That cache is what
# secrets-run reads headlessly on the mini. Run from the mini (present-human) or a
# MacBook — the split is about *when* a human approves, not which keyboard.
#
# Plaintext only ever exists in pipe buffers / process memory: never a temp file,
# never argv, never xtrace. See dotfiles-private/docs/design.md (D5).
#
# Usage:
#   scripts/secrets-seed.sh [--new-only] [--require-complete]
#
#   (none)             resolve EVERY ref and reseal (refreshes every value; the 5-day cadence)
#   --new-only         INCREMENTAL: read only refs that are not in the current cache yet (one
#                      new ref = one `op` read) and keep every other value from it. The current
#                      cache is decrypted in memory (on the mini, over ssh when sealing from a
#                      MacBook). Keeps the previous `_seeded_at` and file mtime, so the age
#                      gates keep measuring the last COMPLETE reseal.
#   --require-complete refuse to deliver when any ref stays unsealed (secrets-rotate: a partial
#                      cache must never replace the old one under a new recipient)
#
# PER ACCOUNT, NOT ALL OR NOTHING. A 1Password account that cannot be reached (not signed in,
# or none of its vaults exist on this machine) does not stop the other account: its refs keep
# the values already in the cache, and the run names the account once at the end. tkrumm is the
# trust anchor (recipient pinning + the Private-vault guard), so it must always be reachable.
# A dead ref in a REACHABLE account still fails the whole run closed, with the full list.
#
# Exit codes: 0 = sealed + delivered, everything resolved; 3 = sealed + delivered PARTIALLY
# (an account was unreachable: its old values were kept, and refs with no value anywhere are
# listed); 1 = failed,
# cache untouched.

SECRETS_PRIVATE_REPO="${SECRETS_PRIVATE_REPO:-$HOME/SourceRoot/dotfiles-private}"
BACKEND_MARKER="${SECRETS_SEED_BACKEND_MARKER:-$HOME/.config/secrets/backend}"
AGE_KEY_FILE="${SECRETS_SEED_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"  # the mini's key; read only to open the CURRENT cache
REFS_FILE="$SECRETS_PRIVATE_REPO/headless.refs"
IU_REFS_FILE="$SECRETS_PRIVATE_REPO/headless.iu.refs"
REMOTE_HOST="mini"
REMOTE_REPO_REL="SourceRoot/dotfiles-private"
OP_ACCOUNT="tkrumm"          # personal; keys BARE in the cache (see cache_key below)
IU_OP_ACCOUNT="careerpartner"  # IU work; keys NAMESPACED (both accounts own a `Private` vault)
DEFAULT_OP_ACCOUNT="$OP_ACCOUNT"
# Trusted age recipient, read from 1Password (human-controlled, NOT from the
# mini-writable dotfiles-private repo). Verifies .sops.yaml has not been swapped
# to an attacker's recipient — a compromised mini could otherwise push a poisoned
# recipient and make the next seed encrypt every secret to the attacker's key.
TRUSTED_RECIPIENT_REF="op://Private/mini age key/public key"

die() {
  echo "✗ $*" >&2
  exit 1
}

indent() {
  local line
  while IFS= read -r line; do
    printf '      %s\n' "$line"
  done
}

MODE=full
REQUIRE_COMPLETE=0
for _arg in "$@"; do
  case "$_arg" in
    --new-only) MODE=new ;;
    --require-complete) REQUIRE_COMPLETE=1 ;;
    *) die "unknown argument: $_arg (usage: secrets-seed.sh [--new-only] [--require-complete])" ;;
  esac
done

[[ -d "$SECRETS_PRIVATE_REPO" ]] \
  || die "private secrets repo not found at $SECRETS_PRIVATE_REPO — clone dotfiles-private or set SECRETS_PRIVATE_REPO"
[[ -f "$REFS_FILE" ]] \
  || die "no headless.refs at $REFS_FILE — the ref-list is the seed's input (see docs/runbook.md)"
command -v sops >/dev/null 2>&1 || die "sops not installed — brew install sops"
command -v jq >/dev/null 2>&1 || die "jq not installed — brew install jq"
command -v op >/dev/null 2>&1 || die "op (1Password CLI) not installed — brew install --cask 1password-cli"

# cd so .sops.yaml (recipient config) resolves relatively and filename-override
# matches its path_regex.
cd "$SECRETS_PRIVATE_REPO"

# --- collect + validate refs -------------------------------------------------
# Two ref-lists, one per account, each with its OWN Private-vault policy:
#
#   headless.refs     tkrumm         op://Private/* FORBIDDEN. That vault is the
#                                    human-only personal vault — the fail-safe stands.
#   headless.iu.refs  careerpartner  op://Private/* ALLOWED. careerpartner's `Private`
#                                    is the IU *work* vault holding service identity
#                                    (feuer tokens, dashboard admin tokens, Artifactory)
#                                    — non-human-only by nature, so the personal-vault
#                                    rationale does not transfer. Owner-classified
#                                    (design.md D14, security-review.md).
#
# The IU list is OPTIONAL: absent → seed personal-only, exactly as before.
#
# refs[] and accts[] stay index-aligned (bash 3.2: no nested arrays).
# Refs are NOT secret (they name vault/item/field, no values), so printing them is fine.
refs=()
accts=()

collect_refs() {  # $1=file  $2=account  $3=1 if op://Private is allowed
  local file="$1" acct="$2" allow_private="$3" line vault vault_lc
  local found=0
  local bad=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"                 # ltrim
    line="${line%"${line##*[![:space:]]}"}"                 # rtrim
    [[ -z "$line" || "$line" == \#* ]] && continue
    # Dedupe within this account (a map has one slot per key anyway).
    local i dup=0
    for ((i = 0; i < ${#refs[@]}; i++)); do
      [[ "${refs[$i]}" == "$line" && "${accts[$i]}" == "$acct" ]] && { dup=1; break; }
    done
    ((dup)) && continue
    if [[ "$line" != op://* ]]; then
      bad+=("not an op:// reference: $line")
      continue
    fi
    if [[ "$allow_private" != 1 ]]; then
      # Case-insensitive vault check: `op` may match vault names case-insensitively,
      # so guard Private/PRIVATE/pRivate alike (not just the literal spelling).
      vault="${line#op://}"; vault="${vault%%/*}"
      vault_lc=$(printf '%s' "$vault" | tr '[:upper:]' '[:lower:]')
      if [[ "$vault_lc" == "private" ]]; then
        bad+=("op://Private is forbidden in the headless cache: $line")
        continue
      fi
    fi
    refs+=("$line")
    accts+=("$acct")
    found=$((found + 1))
  done < "$file"
  if [[ ${#bad[@]} -gt 0 ]]; then
    echo "  ✗ $(basename "$file") policy violation:" >&2
    printf '      - %s\n' "${bad[@]}" >&2
    die "refusing to seed — fix $(basename "$file") (op:// refs only$([[ "$allow_private" == 1 ]] || printf '; never op://Private'))."
  fi
  # Print this list before resolving. This is the human-review checkpoint the
  # explicit-list model relies on: the person seeding can eyeball exactly what is
  # about to be cached — and Ctrl-C on an unexpected or maliciously-added ref —
  # before any value is read or sealed.
  echo "  $found reference(s) to seed from $(basename "$file") (account $acct):"
  local j
  for ((j = ${#refs[@]} - found; j < ${#refs[@]}; j++)); do
    printf '      %s\n' "${refs[$j]}"
  done
}

collect_refs "$REFS_FILE" "$OP_ACCOUNT" 0
if [[ -f "$IU_REFS_FILE" ]]; then
  collect_refs "$IU_REFS_FILE" "$IU_OP_ACCOUNT" 1
fi
[[ ${#refs[@]} -gt 0 ]] || die "headless.refs has no references"

# MUST mirror secrets-run's cache_key() exactly — the seal side and the lookup side
# agreeing on this string is the whole contract. Default account keys BARE (so a
# cache sealed before multi-account support still resolves and the live mini needs
# no flag-day reseed); every other account is namespaced, because both accounts own
# a vault named `Private` and a flat keyspace could not tell them apart.
# `.1password.com` is stripped so the two spellings `op` accepts for one account
# (`careerpartner` / `careerpartner.1password.com`) cannot key two different entries.
# MUST stay byte-identical to secrets-run's copy (cross-checked by the D-verify
# harness, which greps both bodies and asserts they match).
normalize_account() {  # $1=account → prints its canonical short form
  local a
  # Case-fold FIRST: `op` matches account identifiers case-insensitively, so
  # `CareerPartner` and `careerpartner` are one account to op — but two different
  # strings to a cache key. Folding before the suffix strip also catches a
  # `.1Password.com` spelling. Without this the op backend (which delegates the
  # match to op) and the cache backend (which string-compares) disagree on the same
  # input — precisely the divergence this shim exists to prevent.
  # bash 3.2 has no ${var,,}, hence tr.
  a=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  a="${a%.1password.com}"
  # '|' separates account from ref in a namespaced key. An account containing one
  # would make the key ambiguous (account `a|b` + ref `c` vs account `a` + ref `b|c`),
  # so refuse rather than seal something that cannot be looked up unambiguously.
  # '/' and ':' are refused for a second reason: accounts_holding_ref() distinguishes a
  # namespaced key from a bare one (a bare key IS a literal `op://…` ref) by requiring
  # the account part to carry no '://'. Enforcing it here makes that discriminator a
  # guarantee, not an accident of which accounts happen to be in use.
  case "$a" in
    *'|'* | *'/'* | *':'*)
      die "invalid OP_ACCOUNT '$1' — an account name may not contain '|', '/' or ':'" ;;
  esac
  printf '%s' "$a"
}

cache_key() {  # $1=account  $2=ref
  local acct
  acct=$(normalize_account "$1")
  if [[ "$acct" == "$DEFAULT_OP_ACCOUNT" ]]; then
    printf '%s' "$2"
  else
    printf '%s|%s' "$acct" "$2"
  fi
}

# --- delivery target: local (we are the mini) or ssh mini ---------------
local_backend="op"
if [[ -f "$BACKEND_MARKER" ]]; then
  local_backend=$(tr -d '[:space:]' <"$BACKEND_MARKER")
fi
deliver_local=0
[[ "$local_backend" == "cache" ]] && deliver_local=1
if ((deliver_local)); then
  echo "  Delivery: local (this machine is the cache backend)"
else
  echo "  Delivery: ssh $REMOTE_HOST"
fi

# --- the CURRENT cache (decrypted in memory, never a file) -------------------
# Needed for two things only: which refs are new (--new-only), and the values of an
# account this run cannot reach. Plaintext lives in EXIST_VALS[] (process memory) and
# in the pipe that fills it, exactly like vals[] below (R1).
#
# On the mini the age key is next to the cache. From a MacBook the cache is on the
# mini, so it is decrypted THERE and read back over the same ssh the delivery uses:
# no age key ever travels to the MacBook, and the extra cost is one ssh, not one
# biometric prompt. The first line is the file's mtime (see keep_mtime below).
EXIST_LOADED=0
EXIST_OK=0
EXIST_MTIME=""
EXIST_SEEDED_AT=""
EXIST_KEYS=()
EXIST_VALS=()
EX_IX=-1

read_existing_raw() {  # prints "<mtime>\n<plaintext json>"; non-zero = no readable cache
  if ((deliver_local)); then
    local f="cache/secrets.enc.json"
    [[ -f "$f" ]] || return 1
    stat -f %m "$f" || return 1
    SOPS_AGE_KEY_FILE="$AGE_KEY_FILE" sops --decrypt --input-type json --output-type json "$f" 2>/dev/null
  else
    # shellcheck disable=SC2016  # $HOME expands on the MINI, whose account differs from ours
    ssh -o BatchMode=yes -o ConnectTimeout=8 "$REMOTE_HOST" '
      PATH="/opt/homebrew/bin:$PATH"
      f="$HOME/'"$REMOTE_REPO_REL"'/cache/secrets.enc.json"
      [ -f "$f" ] || exit 3
      stat -f %m "$f" || exit 1
      SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt" sops --decrypt --input-type json --output-type json "$f" 2>/dev/null
    ' 2>/dev/null
  fi
}

load_existing() {  # memoized; failure is not fatal — callers fall back to resolving everything
  (( EXIST_LOADED )) && return 0
  EXIST_LOADED=1
  local raw="" rc=0 json k v
  raw=$(read_existing_raw) || rc=$?
  (( rc == 0 )) && [[ "$raw" == *$'\n'* ]] || return 0
  EXIST_MTIME="${raw%%$'\n'*}"
  [[ "$EXIST_MTIME" =~ ^[0-9]+$ ]] || EXIST_MTIME=""
  json="${raw#*$'\n'}"
  raw=""
  while IFS= read -r -d '' k && IFS= read -r -d '' v; do
    if [[ "$k" == "_seeded_at" ]]; then EXIST_SEEDED_AT="$v"; continue; fi
    EXIST_KEYS+=("$k")
    EXIST_VALS+=("$v")
  done < <(printf '%s' "$json" | jq -j 'to_entries[] | .key + "\u0000" + (.value|tostring) + "\u0000"')
  json=""
  EXIST_OK=1
}

existing_ix() {  # $1=cache key ; sets EX_IX (-1 = absent). No subshell: called per ref.
  local k
  EX_IX=-1
  for ((k = 0; k < ${#EXIST_KEYS[@]}; k++)); do
    [[ "${EXIST_KEYS[$k]}" == "$1" ]] && { EX_IX=$k; return 0; }
  done
  return 1
}

# --- accounts: one row each, reachable or not --------------------------------
# ACCT_* arrays are index-aligned (bash 3.2: no nested arrays).
ACCT_LIST=()   # distinct accounts, in first-seen order
ACCT_OK=()     # 1 = reachable this run
ACCT_WHY=()    # why not (empty while reachable)
ACCT_NEED=()   # refs this run has to resolve for it
ACCT_ATT=()    # per-ref reads attempted (fallback path only)
ACCT_VGONE=()  # of those, how many failed with "isn't a vault in this account"
for ((i = 0; i < ${#refs[@]}; i++)); do
  _have=0
  for ((_k = 0; _k < ${#ACCT_LIST[@]}; _k++)); do
    [[ "${ACCT_LIST[$_k]}" == "${accts[$i]}" ]] && { _have=1; break; }
  done
  ((_have)) && continue
  ACCT_LIST+=("${accts[$i]}"); ACCT_OK+=(1); ACCT_WHY+=(""); ACCT_NEED+=(0); ACCT_ATT+=(0); ACCT_VGONE+=(0)
done

acct_ix() {  # $1=account ; sets AX
  local k
  AX=-1
  for ((k = 0; k < ${#ACCT_LIST[@]}; k++)); do
    [[ "${ACCT_LIST[$k]}" == "$1" ]] && { AX=$k; return 0; }
  done
  return 1
}

# --- what has to be resolved --------------------------------------------------
# need[i]=1: read this ref from 1Password. kept[i]=N: use EXIST_VALS[N] instead.
# Full mode reads everything (that is what refreshes values); --new-only reads only
# what the current cache lacks. With no readable cache --new-only IS a full run.
need=()
kept=()
if [[ "$MODE" == new ]]; then
  load_existing
  if ((EXIST_OK)); then
    echo "  Incremental: current cache holds ${#EXIST_KEYS[@]} value(s)"
  else
    echo "  ! no readable current cache — resolving every reference" >&2
  fi
fi
for ((i = 0; i < ${#refs[@]}; i++)); do
  need[i]=1
  kept[i]=-1
  if [[ "$MODE" == new ]] && ((EXIST_OK)); then
    existing_ix "$(cache_key "${accts[$i]}" "${refs[$i]}")" || true
    if ((EX_IX >= 0)); then need[i]=0; kept[i]=$EX_IX; fi
  fi
done
if [[ "$MODE" == new ]]; then
  _n=0
  for ((i = 0; i < ${#refs[@]}; i++)); do
    ((need[i])) || continue
    _n=$((_n + 1))
    printf '      new: %s (account %s)\n' "${refs[$i]}" "${accts[$i]}"
  done
  ((_n)) || echo "      no new reference — nothing to read"
fi
for ((i = 0; i < ${#refs[@]}; i++)); do
  ((need[i])) || continue
  acct_ix "${accts[$i]}" || true
  ACCT_NEED[AX]=$((ACCT_NEED[AX] + 1))
done

# --- op sign-in guard (rules/makefile-conventions.md pattern) ---------------
# Each account is checked separately — `op` sessions are per-account.
#
# The reachability probe is `op account get`, NOT `op whoami`. Under 1Password's
# desktop-app integration there is no CLI session token, so `op whoami` returns
# rc=1 "account is not signed in" on a perfectly unlocked app — measured
# 2026-08-17 with op 2.38.1, while `op read` in this very script was resolving
# refs fine. With whoami as the test, the `||` fires on EVERY run and this script
# shells out to `op signin` unconditionally: harmless from a terminal, but from a
# LaunchAgent it is a non-TTY sign-in that cannot succeed and only adds noise
# before the real work. Same trap cost us the auto-reseed in
# opbackup-seed-auto.sh; see the long comment there.
#
# tkrumm is the TRUST ANCHOR: the Private-vault UUID guard and the recipient pin below
# both run through it, so it must be reachable (a failed sign-in is fatal, as before).
# Any other account that cannot sign in is NOT fatal: it is marked unreachable, its refs
# keep the values already in the cache, and it is reported once at the end. An account
# with nothing to resolve this run is not even probed — no dialog for a ref that is
# not changing.
echo "  1Password sign-in..."
op account get --account "$OP_ACCOUNT" >/dev/null 2>&1 || op signin --account "$OP_ACCOUNT"
echo "    ✓ $OP_ACCOUNT"
for ((_k = 0; _k < ${#ACCT_LIST[@]}; _k++)); do
  _a="${ACCT_LIST[$_k]}"
  [[ "$_a" == "$OP_ACCOUNT" ]] && continue
  if ((ACCT_NEED[_k] == 0)); then
    echo "    · $_a: nothing to resolve — not contacted"
    continue
  fi
  if op account get --account "$_a" >/dev/null 2>&1 || op signin --account "$_a"; then
    echo "    ✓ $_a"
  else
    ACCT_OK[_k]=0
    ACCT_WHY[_k]="not signed in"
    echo "    ✗ $_a: cannot sign in — continuing without it" >&2
  fi
done

# --- Private-vault fail-safe, part 2: deny by UUID too (needs op) ------------
# The collect check above rejects op://Private/... by NAME. A ref can also target
# the Private vault by its UUID (op://<uuid>/item/field), bypassing a name-only
# check. Resolve Private's canonical id once and reject any ref whose vault segment
# matches it, closing the UUID bypass (a compromised mini poisoning headless.refs so
# the next biometric seed caches a genuinely-private secret).
#
# Matched against TKRUMM's Private id only — careerpartner's Private vault is allowed
# by policy, so there is nothing to guard for it, and the two accounts' `Private`
# vaults are different vaults that merely share a name.
#
# But checked against EVERY ref, whatever list it came from. Scoping this to
# tkrumm-labeled refs would leave a bypass: a tkrumm Private ref smuggled into
# headless.iu.refs is labeled `careerpartner`, so it passes the by-name check (the
# vault segment is a UUID, not the literal "private") and would skip a
# tkrumm-only UUID guard. It would then be read with `--account careerpartner`, where
# op should reject a vault id it does not own — but that is op's behavior, not ours,
# and this script is the sole secret path on the mini. Do not delegate the fail-safe
# to an assumption. Vault UUIDs are globally unique, so a legitimate careerpartner ref
# can never collide with tkrumm's Private id: no false positives.
private_id=$(op vault get "Private" --account "$OP_ACCOUNT" --format json 2>/dev/null | jq -r '.id // empty' 2>/dev/null || true)
if [[ -n "$private_id" ]]; then
  uuid_bad=()
  for ((i = 0; i < ${#refs[@]}; i++)); do
    v="${refs[$i]#op://}"; v="${v%%/*}"
    [[ "$v" == "$private_id" ]] && uuid_bad+=("${refs[$i]} (from the ${accts[$i]} list)")
  done
  if [[ ${#uuid_bad[@]} -gt 0 ]]; then
    echo "  ✗ a ref list references tkrumm's Private vault by UUID:" >&2
    printf '      - %s\n' "${uuid_bad[@]}" >&2
    die "refusing to seed — tkrumm's Private is human-only and must never enter the headless cache."
  fi
else
  echo "    ! could not resolve the Private vault id — UUID-form Private guard skipped" >&2
fi

# --- recipient pinning (defends against a swapped .sops.yaml recipient) ------
# Assert the recipient SET in .sops.yaml is exactly {trusted}: an attacker with
# write access to the repo could otherwise *append* a second recipient (sops
# supports many) so the cache is also encrypted to their key while the first still
# matches. Reject on any extra recipient, not just a mismatched first one.
echo "  Verifying age recipient..."
expected_recipient=$(op read "$TRUSTED_RECIPIENT_REF" --account "$OP_ACCOUNT" 2>/dev/null || true)
all_recipients=$(grep -Eo 'age1[0-9a-z]+' .sops.yaml 2>/dev/null || true)
if [[ -n "$expected_recipient" ]]; then
  recipient_count=$(printf '%s\n' "$all_recipients" | grep -c . || true)
  if [[ "$recipient_count" -ne 1 || "$all_recipients" != "$expected_recipient" ]]; then
    die "age recipient set in .sops.yaml does not match exactly the trusted recipient in 1Password — possible tampering of dotfiles-private (extra or swapped recipient); refusing to seed. Found: ${all_recipients//$'\n'/, }"
  fi
  echo "    ✓ recipient matches 1Password"
else
  echo "    ! could not read trusted recipient from '$TRUSTED_RECIPIENT_REF' — skipping verification" >&2
  echo "      (add that field alongside the age-key backup per docs/runbook.md to enable this check)" >&2
fi

# --- resolve every ref (biometric) into an in-memory value array -------------
# Values live only in the vals[] shell array (process memory, never disk — R1).
# A ref that cannot be resolved aborts before any crypto, so the cache stays
# untouched. An access failure (authorization, timeout, handshake) aborts at once.
#
# ACCESS FAILURES NEVER FAN OUT. Every `op` process that lacks a macOS TCC grant
# raises its own "op wants to access data from other apps" dialog, and Allow does
# not persist. So a timeout, authorization, sign-in or handshake failure stops the
# run at its first occurrence (abort_op_access): no retry, no per-ref fallback.
# Only a genuine ref error is worth more `op` processes, because the per-ref path
# is what names the broken ref.
#
# EACH READ IS TIME-BOUNDED. `op` can hang waiting on an authorization dialog that
# never renders; from a LaunchAgent that wedges the job until launchd's next tick
# collides with it. run_bounded enforces the deadline (TERM, then KILL — op does not
# reliably die on SIGTERM); a timeout is an abort.
OP_READ_TIMEOUT="${SECRETS_SEED_OP_READ_TIMEOUT:-30}"
# One batch covers hundreds of refs, so it gets a proportionally larger deadline.
OP_BATCH_TIMEOUT="${SECRETS_SEED_OP_BATCH_TIMEOUT:-180}"
# Escape hatch: set to 0 to skip batching entirely and read ref-by-ref.
OP_BATCH="${SECRETS_SEED_OP_BATCH:-1}"

# WHY NOT coreutils `timeout` ANY MORE. macOS attributes a TCC authorization to the
# RESPONSIBLE PROCESS — the ancestor that spawned the one asking. Wrapping `op` in
# Homebrew's `timeout` made that ancestor /opt/homebrew/bin/timeout, so every read
# raised "gtimeout wants to access data from other apps", and because a Homebrew
# binary carries an ad-hoc signature that changes on every upgrade, the grant never
# stuck — it re-prompted forever, once per ref. Observed 2026-08-25: a single run
# put one dialog on screen per ref (148 of them at the time) and kept going.
#
# Running `op` as a direct child of /bin/bash keeps the responsible process
# Apple-signed and stable, so one approval persists. The deadline the old wrapper
# provided is still enforced — see run_bounded — because the hang it guarded against
# (op waiting on a dialog that never renders) is real and unchanged.
run_bounded() {  # $1=seconds  $2..=command ; stdout passes through untouched
  local secs="$1"; shift
  local rc=0 cmd_pid wd_pid
  # `<&0` is load-bearing. POSIX assigns an ASYNCHRONOUS list's stdin to /dev/null
  # "before any explicit redirections", so a bare `"$@" &` would hand `op inject` an
  # empty stdin: it reads no template, emits nothing, and exits 0. That failed safe
  # (the marker walk rejects the empty output and the per-ref fallback runs) but it
  # silently disabled batching altogether. The explicit redirection overrides the
  # default and passes the caller's pipe through.
  # Job control gives the child its own PROCESS GROUP, so the watchdog can kill
  # the whole tree with `kill -- -$pid`. Killing only the direct child is not
  # enough and fails in a way that looks like the bound working: the caller reads
  # the child's stdout through a command substitution, and any surviving
  # grandchild still holds that pipe open, so `$( )` blocks until IT exits.
  # Measured 2026-08-29 with a shell-script stub that sleeps 60: rc came back as
  # 124 (so the watchdog HAD fired) after the full 60s. Real `op` forks nothing,
  # which is why production never showed it and the regression test — wired into
  # no make target at the time — was the only thing that ever saw it.
  # `set -m` is restored to whatever it was: this is a library function.
  local was_monitor=0
  case "$-" in *m*) was_monitor=1 ;; esac
  set -m
  "$@" <&0 &
  cmd_pid=$!
  (( was_monitor )) || set +m
  # The watchdog's own stdout goes to /dev/null: it must not hold the command
  # substitution's pipe open, or the caller would block until the sleep elapsed
  # even on a fast success.
  { sleep "$secs"; kill -TERM -"$cmd_pid" 2>/dev/null; sleep 5; kill -KILL -"$cmd_pid" 2>/dev/null; } >/dev/null 2>&1 &
  wd_pid=$!
  wait "$cmd_pid" || rc=$?
  kill "$wd_pid" 2>/dev/null || true
  wait "$wd_pid" 2>/dev/null || true
  # A watchdog kill surfaces as 143 (TERM). Normalise it to coreutils' 124 so
  # op_failure_is_ref_problem's contract (timeout == 124) keeps working.
  (( rc == 143 )) && rc=124
  return "$rc"
}

op_read_once() {  # $1=account  $2=ref ; value on stdout, diagnostics in $rerr
  run_bounded "$OP_READ_TIMEOUT" op read --account "$1" "$2" 2>"$rerr"
}

# --- batched resolve ---------------------------------------------------------
# WHY BATCH. The per-ref loop below is one `op` PROCESS per ref, each doing its own
# handshake with the desktop app. That is what makes a reseal hundreds of dialogs
# long, and it is also the direct cause of the transient handshake failures the
# retry logic exists to absorb — a few hundred handshakes is a few hundred chances
# to lose one. `op inject` resolves every ref in ONE process, so the whole run costs
# one handshake per ACCOUNT (two) instead of one per ref (148 at the time of writing).
#
# The template carries only REFERENCES, never values, so it is safe on stdin. The
# resolved output is read straight into the vals[] array — plaintext still never
# lands as a file and never as argv (R1).
#
# Values are framed by a per-run sentinel rather than positionally, so a value that
# happens to look like a marker cannot shift the mapping. A ref whose value spans
# more than one line is refused here for exactly the reason the per-ref path refuses
# it: the pairing would silently misalign and corrupt the cache.
SEED_MARK="@@secrets-seed-$$-${RANDOM}@@"

# Return contract: 0 = every index filled. Non-zero = op's own exit status (124 = the
# watchdog), with BATCH_FAULT empty. A LOCAL fault (output we cannot trust) returns 1
# with BATCH_FAULT set — a separate channel, so it can never collide with an exit
# status op returns. The caller treats a fault as an abort, never a fallback: op
# itself succeeded, so a per-ref re-read would only multiply processes.
BATCH_FAULT=""
resolve_batch() {  # $1=account  $2..=indices into refs[] ; fills vals[] by index
  BATCH_FAULT=""
  local acct="$1"; shift
  local -a idx=("$@")
  (( ${#idx[@]} )) || return 0

  local tpl="" i
  for i in "${idx[@]}"; do
    tpl+="${SEED_MARK}${i}:"$'\n'"{{ ${refs[$i]} }}"$'\n'
  done
  tpl+="${SEED_MARK}END:"$'\n'

  local out rc=0
  out=$(printf '%s' "$tpl" | run_bounded "$OP_BATCH_TIMEOUT" op inject --account "$acct" 2>"$rerr") || rc=$?
  (( rc == 0 )) || return "$rc"

  local -a lines=()
  while IFS= read -r line; do lines+=("$line"); done <<<"$out"

  local n=${#lines[@]} p=0 tag
  while (( p < n )); do
    case "${lines[$p]}" in
      "${SEED_MARK}"*) ;;
      *) BATCH_FAULT="output did not line up with its markers"; return 1 ;;
    esac
    tag="${lines[$p]#"$SEED_MARK"}"; tag="${tag%:}"
    [[ "$tag" == "END" ]] && break
    # The line after a marker is the value; the line after THAT must be the next
    # marker, or the value spanned multiple lines.
    case "${lines[$((p + 2))]:-}" in
      "${SEED_MARK}"*) ;;
      *) die "value for ${refs[$tag]} is multi-line — unsupported (v1: single-line values only); remove it from headless.refs" ;;
    esac
    vals[tag]="${lines[$((p + 1))]:-}"
    p=$(( p + 2 ))
  done

  # Every index we asked for must have come back, or the mapping is not trustworthy.
  for i in "${idx[@]}"; do
    [[ -n "${vals[$i]+set}" ]] || { BATCH_FAULT="output was missing ${refs[$i]}"; return 1; }
  done
  return 0
}

# Is this `op` failure the REF's fault (unknown vault/item/field, bad syntax) rather
# than 1Password's access path (authorization, sign-in, desktop-app handshake,
# timeout)? Only the former may fan out into per-ref reads. Default is ABORT: the
# cost of a wrong "ref problem" is dozens of dialogs, the cost of a wrong "access
# problem" is one clearly-worded abort.
#
# Only op's `[ERROR]` lines are read, and the echoed `op://…` reference is cut out of
# each first, so an item name containing "isn't an item" inside an authorization
# error cannot flip the verdict. The case below accepts EXACTLY these op 2.x phrases
# (each verified present in the op binary's error strings), and nothing else:
#   %q isn't an item                       %q isn't a vault in this account
#   %q isn't a field in the %q item        More than one item matches %q
#   invalid secret reference '%s'          invalid character in secret reference
op_failure_is_ref_problem() {  # $1=exit status ; diagnostics in $rerr
  [[ "$1" == 124 || "$1" == 137 ]] && return 1   # timeout / SIGKILL after the watchdog
  local line head rest
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == "[ERROR]"* ]] || continue
    if [[ "$line" == *"op://"*"': "* ]]; then
      head="${line%%op://*}"; rest="${line#*op://}"
      line="${head}${rest#*"': "}"
    fi
    line=$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')
    case "$line" in
      *"isn't an item"*|*"isn't a vault"*|*"isn't a field in the"*|\
      *"more than one item matches"*|*"invalid secret reference"*|\
      *"invalid character in secret reference"*) return 0 ;;
    esac
  done <"$rerr"
  return 1
}

# Is the failure in $rerr specifically "<vault> isn't a vault in this account"? The echoed
# op:// reference is cut out first, as above. Only called after op_failure_is_ref_problem.
op_failure_is_vault_missing() {
  local line head rest
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == "[ERROR]"* ]] || continue
    if [[ "$line" == *"op://"*"': "* ]]; then
      head="${line%%op://*}"; rest="${line#*op://}"
      line="${head}${rest#*"': "}"
    fi
    line=$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')
    case "$line" in *"isn't a vault"*) return 0 ;; esac
  done <"$rerr"
  return 1
}

# The ONE abort for an access failure: stops the run (no loop, no retry, no per-ref
# fallback), fail closed — nothing sealed, nothing delivered. Names the resolved op
# path, the exact thing macOS keys the Full Disk Access grant on.
abort_op_access() {  # $1=what was running  $2=exit status  $3=account ; diagnostics in $rerr
  local op_bin op_real="" acct="${3:-$OP_ACCOUNT}"
  op_bin=$(command -v op 2>/dev/null || true)
  [[ -n "$op_bin" ]] && op_real=$(realpath "$op_bin" 2>/dev/null || printf '%s' "$op_bin")
  echo "" >&2
  echo "  ✗ 1Password access failed while $1 — not recognised as a bad reference; most often a missing grant or a locked 1Password." >&2
  if [[ "$2" == 124 || "$2" == 137 ]]; then
    echo "    op did not answer in time (killed by the watchdog) — typical of an authorization dialog nobody saw." >&2
  else
    indent <"$rerr" >&2
  fi
  echo "    Locked or signed out gives the same errors: unlock 1Password / run" >&2
  echo "    op signin --account $acct first, and re-run." >&2
  if [[ -z "$op_real" ]]; then
    echo "    op is not on PATH — install it (brew install --cask 1password-cli)." >&2
  else
    echo "    If it persists: macOS raises \"op wants to access data from other apps\" for every" >&2
    echo "    op process that lacks a grant, and that dialog's Allow button does NOT persist." >&2
    echo "    Add exactly this path to System Settings → Privacy & Security → Full Disk Access" >&2
    echo "    (reveal it with: open -R '$op_real', then drag it into the list):" >&2
    echo "        $op_real" >&2
  fi
  echo "    Stopped at the first failure on purpose: retrying or reading ref-by-ref" >&2
  echo "    only stacks more dialogs. Then re-run make secrets-seed." >&2
  rm -f "$rerr"
  die "aborting — cache untouched"
}

echo "  Resolving references..."
vals=()
rerr=$(mktemp "${TMPDIR:-/tmp}/secrets-seed.XXXXXX")

# Try one batched call per account first. Fall back to the per-ref loop for that
# account ONLY when the batch failed because of a ref/template problem — `op inject`
# reports a bad template as one error for the whole batch, and "which ref is wrong" is
# the single most useful thing this script tells a human. Any other failure (timeout,
# authorization, sign-in, handshake, unknown) aborts at once via abort_op_access:
# the per-ref path would spawn one `op` process per ref against the same broken
# access path, one macOS dialog each.
#
# Only refs in need[] of a REACHABLE account are resolved at all: --new-only skips what
# the cache already holds, and an unreachable account is never contacted.
declare -a _pending_idx=()
if (( OP_BATCH )); then
  for ((_k = 0; _k < ${#ACCT_LIST[@]}; _k++)); do
    (( ACCT_OK[_k] )) || continue
    _acct="${ACCT_LIST[$_k]}"
    _idx=()
    for ((i = 0; i < ${#refs[@]}; i++)); do
      [[ "${accts[$i]}" == "$_acct" ]] && (( need[i] )) && _idx+=("$i")
    done
    (( ${#_idx[@]} )) || continue
    _brc=0
    resolve_batch "$_acct" "${_idx[@]}" || _brc=$?
    if (( _brc == 0 )); then
      echo "    ✓ $_acct: resolved ${#_idx[@]} reference(s) in one call"
    elif [[ -n "$BATCH_FAULT" ]]; then
      abort_op_access "resolving the $_acct batch ($BATCH_FAULT)" "$_brc" "$_acct"
    elif op_failure_is_ref_problem "$_brc"; then
      echo "    … $_acct: batch resolve failed on a reference — falling back to per-reference reads to find it" >&2
      indent <"$rerr" >&2
      _pending_idx+=("${_idx[@]}")
    else
      abort_op_access "resolving the $_acct batch" "$_brc" "$_acct"
    fi
  done
else
  for ((i = 0; i < ${#refs[@]}; i++)); do
    acct_ix "${accts[$i]}" || true
    (( need[i] && ACCT_OK[AX] )) && _pending_idx+=("$i")
  done
fi

# Permanently-unresolvable refs are COLLECTED, not fatal on sight: aborting on the
# first one spends the human's Touch ID pass to learn about exactly one dead ref,
# and the next run then dies on the second. Verified 2026-08-29, when the deleted
# careerpartner item `care-stage` had been silently blocking every reseal — five
# refs, which without this would have been five biometric passes. The run still
# FAILS CLOSED (nothing is sealed or delivered); it just reports the whole list.
#
# The one exception is an account whose vaults are ALL gone: if every ref read for an
# account failed with "isn't a vault in this account", it is not a list of dead refs,
# it is an account this machine cannot use (signed out of the wrong org, vault access
# lost — 2026-11-13, careerpartner on the MacBook). That account becomes unreachable
# like a failed sign-in, instead of failing the other account's refs closed with it.
dead=()
dead_count=0

for i in ${_pending_idx[@]+"${_pending_idx[@]}"}; do
  ref="${refs[$i]}"
  # `rc` is captured on the OR side, NOT read from `$?` after an `if`: an `if`
  # whose condition fails and which has no `else` exits 0, so the obvious
  # spelling would classify every failure as status 0 and never see a timeout.
  rc=0
  v=$(op_read_once "${accts[$i]}" "$ref") || rc=$?
  acct_ix "${accts[$i]}" || true
  ACCT_ATT[AX]=$((ACCT_ATT[AX] + 1))
  if (( rc != 0 )); then
    # Circuit breaker: an access failure (authorization, handshake, timeout) hits
    # every remaining ref the same way and each would raise its own dialog.
    op_failure_is_ref_problem "$rc" || abort_op_access "reading $ref (account ${accts[$i]})" "$rc" "${accts[$i]}"
    echo "    ✗ op read failed for $ref (account ${accts[$i]}):" >&2
    indent <"$rerr" >&2
    op_failure_is_vault_missing && ACCT_VGONE[AX]=$((ACCT_VGONE[AX] + 1))
    dead[i]=1
    dead_count=$((dead_count + 1))
    # Keep going: the point is to end with the COMPLETE list of dead refs, not the
    # first one. vals[i] stays unset — the abort below fires before the jq fold.
    continue
  fi
  # v1 constraint: single-line values only. A multi-line value would misalign the
  # newline-paired jq fold below and silently corrupt the cache — refuse it.
  case "$v" in
    *$'\n'*) rm -f "$rerr"; die "value for $ref is multi-line — unsupported (v1: single-line values only); remove it from headless.refs" ;;
  esac
  # By INDEX, not append: the batch path above may already have filled other slots,
  # and vals[] is paired with refs[] positionally by the jq fold below.
  vals[i]="$v"
done
rm -f "$rerr"

for ((_k = 0; _k < ${#ACCT_LIST[@]}; _k++)); do
  # At least TWO refs, all failing on the vault: a single ref with a mistyped vault name is a
  # dead ref (fails closed with its name), not proof that the whole account is gone.
  (( ACCT_ATT[_k] >= 2 && ACCT_VGONE[_k] == ACCT_ATT[_k] && ACCT_ATT[_k] == ACCT_NEED[_k] )) || continue
  [[ "${ACCT_LIST[$_k]}" == "$OP_ACCOUNT" ]] && continue   # the trust anchor never degrades
  ACCT_OK[_k]=0
  ACCT_WHY[_k]="none of its vaults exist in this account on this machine"
  for ((i = 0; i < ${#refs[@]}; i++)); do
    if [[ "${accts[$i]}" == "${ACCT_LIST[$_k]}" && -n "${dead[$i]+set}" ]]; then
      unset "dead[$i]"
      dead_count=$((dead_count - 1))
    fi
  done
done

if (( dead_count > 0 )); then
  echo "" >&2
  echo "  ✗ unresolvable reference(s) — every one, so one pass tells you the whole list:" >&2
  for ((i = 0; i < ${#refs[@]}; i++)); do
    [[ -n "${dead[$i]+set}" ]] && printf '      %s  (account %s)\n' "${refs[$i]}" "${accts[$i]}" >&2
  done
  echo "    Each is a ref in headless.refs / headless.iu.refs whose item or field no" >&2
  echo "    longer exists (renamed, deleted or archived). Fix or comment it out, then" >&2
  echo "    re-run — the cache is untouched until every ref resolves." >&2
  die "aborting — cache untouched"
fi

# --- fill every slot: fresh value, kept value, or unsealed ---------------------
# fresh   = read from 1Password this run.
# kept    = the value already in the cache: a ref --new-only had no reason to re-read,
#           or one of an unreachable account.
# unsealed = an unreachable account's ref with no value anywhere: it stays out of the
#           cache and is named at the end (exit 3).
fresh=0; keptn=0; unsealed=0
unsealed_flag=()
for ((i = 0; i < ${#refs[@]}; i++)); do
  if [[ -n "${vals[$i]+set}" ]]; then
    fresh=$((fresh + 1))
    # The heads-up the fallback loop used to print per ref; the batch path skips it, so
    # sweep here. Prints the ref and the length, never the value.
    if [[ ${#vals[$i]} -lt "${REDACT_MIN_LEN:-5}" ]]; then
      echo "    ! ${refs[$i]} resolves to a ${#vals[$i]}-char value — too short to be redacted at runtime (secrets-run won't mask it)" >&2
    fi
    continue
  fi
  if (( kept[i] < 0 )); then
    acct_ix "${accts[$i]}" || true
    (( ACCT_OK[AX] )) && die "internal: no value resolved for ${refs[$i]}"
    load_existing
    # An account we cannot reach is kept at its OLD values. If the old cache cannot be
    # read (ssh down, key missing, no cache yet) there is nothing to keep, and delivering
    # would silently wipe that account out of a cache that has it — refuse instead.
    (( EXIST_OK )) || die "account ${accts[$i]} is unreachable (${ACCT_WHY[$AX]}) and the current cache cannot be read to keep its values — refusing to deliver (cache untouched)"
    existing_ix "$(cache_key "${accts[$i]}" "${refs[$i]}")" || true
    kept[i]=$EX_IX
  fi
  if (( kept[i] >= 0 )); then
    vals[i]="${EXIST_VALS[${kept[$i]}]}"
    keptn=$((keptn + 1))
  else
    unsealed_flag[i]=1
    unsealed=$((unsealed + 1))
  fi
done
echo "    ✓ ${fresh} resolved, ${keptn} kept from the current cache, ${unsealed} unsealed"

for ((_k = 0; _k < ${#ACCT_LIST[@]}; _k++)); do
  if (( REQUIRE_COMPLETE && ! ACCT_OK[_k] )); then
    die "aborting — --require-complete and account ${ACCT_LIST[$_k]} is unreachable (${ACCT_WHY[$_k]}); ${unsealed} ref(s) have no value — cache untouched"
  fi
done

# No change at all (nothing read, nothing dropped): do not re-seal an identical cache.
nothing_to_seal=0
if (( fresh == 0 && keptn == ${#EXIST_KEYS[@]} && EXIST_OK )); then nothing_to_seal=1; fi

# The end of every run that got this far: names each unreachable account ONCE, with what
# it cost (values kept but not refreshed, refs with no value at all), and picks the exit
# code — 3 when an account was unreachable (its values were kept, not refreshed, and some
# refs may be unsealed), so a caller never reads a partial seal as
# complete (opbackup-seed-auto must not stamp it as "refs sealed").
finish() {
  local k a i kept_n unsealed_n rc=0
  for ((k = 0; k < ${#ACCT_LIST[@]}; k++)); do
    (( ACCT_OK[k] )) && continue
    rc=3
    a="${ACCT_LIST[$k]}"
    kept_n=0; unsealed_n=0
    for ((i = 0; i < ${#refs[@]}; i++)); do
      [[ "${accts[$i]}" == "$a" ]] || continue
      if [[ -n "${unsealed_flag[$i]+set}" ]]; then unsealed_n=$((unsealed_n + 1)); else kept_n=$((kept_n + 1)); fi
    done
    echo "  ! account $a is unreachable (${ACCT_WHY[$k]}): kept $kept_n existing value(s) — NOT refreshed — and $unsealed_n ref(s) have no value:" >&2
    for ((i = 0; i < ${#refs[@]}; i++)); do
      [[ "${accts[$i]}" == "$a" && -n "${unsealed_flag[$i]+set}" ]] && printf '      %s\n' "${refs[$i]}" >&2
    done
    echo "    Sign in to $a on this machine (op signin --account $a), then run: make secrets-seed-new" >&2
  done
  exit "$rc"
}

if (( nothing_to_seal )); then
  echo ""
  echo "  ✓ cache already holds every resolvable reference — nothing to seal"
  echo ""
  finish
fi

# --- assemble plaintext JSON (in pipes) and encrypt --------------------------
# builtin printf emits ref/value pairs into a pipe (no argv exposure); jq folds
# them into a map; sops seals it. Plaintext never lands as a file, never as argv.
#
# `_seeded_at` and the file's mtime are what the age gates read (secrets-run's 14-day
# warning, the freshness heartbeat's 8 days, the 5-day auto-reseal), and they mean "the
# last time EVERY value was read from 1Password". A run that kept any value therefore
# carries the previous stamp and mtime forward instead of resetting them — otherwise a
# stream of one-ref seals would keep an old value looking fresh forever.
seeded_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
keep_mtime=""
if (( fresh < ${#refs[@]} )) && [[ -n "$EXIST_SEEDED_AT" ]]; then
  seeded_at="$EXIST_SEEDED_AT"
  keep_mtime="$EXIST_MTIME"
fi

emit_pairs() {
  local i
  for ((i = 0; i < ${#refs[@]}; i++)); do
    [[ -n "${unsealed_flag[$i]+set}" ]] && continue
    printf '%s\n%s\n' "$(cache_key "${accts[$i]}" "${refs[$i]}")" "${vals[$i]}"
  done
}

serr=$(mktemp "${TMPDIR:-/tmp}/secrets-seed.XXXXXX")
if ! ciphertext=$(emit_pairs \
  | jq -Rn --arg seeded "$seeded_at" '
      [inputs] as $l
      | reduce range(0; ($l | length); 2) as $i ({}; . + {($l[$i]): $l[$i + 1]})
      | . + {"_seeded_at": $seeded}
    ' \
  | sops --encrypt --input-type json --output-type json --filename-override "cache/secrets.enc.json" /dev/stdin 2>"$serr"); then
  echo "    ✗ encrypt failed:" >&2
  indent <"$serr" >&2
  rm -f "$serr"
  die "aborting — cache untouched"
fi
rm -f "$serr"

# --- sanity checks on the ciphertext (before delivery) -----------------------
[[ "$ciphertext" == *'ENC['* ]] \
  || die "ciphertext sanity check failed — no ENC[ marker, aborting (cache untouched)"

# Every ref must be present as an (encrypted) key in the ciphertext. Keys are
# plaintext in SOPS-JSON (only values are encrypted), so this confirms nothing
# was silently dropped between resolve and seal.
missing_keys=()
for ((i = 0; i < ${#refs[@]}; i++)); do
  [[ -n "${unsealed_flag[$i]+set}" ]] && continue
  key=$(cache_key "${accts[$i]}" "${refs[$i]}")
  grep -qF "\"$key\"" <<<"$ciphertext" || missing_keys+=("$key")
done
if [[ ${#missing_keys[@]} -gt 0 ]]; then
  echo "    ✗ ciphertext missing key(s): ${missing_keys[*]}" >&2
  die "aborting — cache untouched"
fi

# --- deliver atomically (temp + mv; no partial cache is ever observable) -----
# The temp name is PID-unique so two overlapping `make secrets-seed` runs can't
# interleave writes to a shared temp before either `mv` fires (mv onto the final
# path is itself atomic, so the last writer simply wins cleanly).
#
# keep_mtime (epoch seconds, or empty): the previous file's mtime, re-applied to the new
# file before the mv so the age gates keep measuring the last COMPLETE reseal (see the
# `_seeded_at` note above). It is digits-only by construction (checked on load), which
# is also what makes interpolating it into the remote script safe.
deliver_local_cache() {
  mkdir -p cache
  local tmp="cache/secrets.enc.json.$$.tmp"
  printf '%s\n' "$ciphertext" >"$tmp"
  chmod 600 "$tmp"
  [[ -z "$keep_mtime" ]] || touch -t "$(date -r "$keep_mtime" +%Y%m%d%H%M.%S)" "$tmp"
  mv "$tmp" "cache/secrets.enc.json"
}

# The remote path is fixed (no untrusted interpolation); ciphertext rides stdin.
# $$ (the local seed's PID) makes the remote temp unique too.
deliver_remote_cache() {
  printf '%s\n' "$ciphertext" | ssh "$REMOTE_HOST" '
    set -e
    umask 077
    dir="$HOME/'"$REMOTE_REPO_REL"'/cache"
    tmp="$dir/secrets.enc.json.'"$$"'.tmp"
    mkdir -p "$dir"
    cat > "$tmp"
    chmod 600 "$tmp"
    keep="'"$keep_mtime"'"
    if [ -n "$keep" ]; then touch -t "$(date -r "$keep" +%Y%m%d%H%M.%S)" "$tmp"; fi
    mv "$tmp" "$dir/secrets.enc.json"
  '
}

if ((deliver_local)); then
  deliver_local_cache || die "local write failed"
else
  deliver_remote_cache || die "delivery to $REMOTE_HOST failed"
fi

echo ""
if (( unsealed > 0 )); then
  echo "  ✓ sealed + delivered $(( ${#refs[@]} - unsealed )) of ${#refs[@]} secret(s) — PARTIAL, see below ($seeded_at)"
else
  echo "  ✓ sealed + delivered ${#refs[@]} secret(s) ($seeded_at)"
fi
echo "  · Shells already open keep their old baseline env until a new shell is opened."
echo ""
finish
