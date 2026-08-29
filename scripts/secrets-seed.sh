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
#   scripts/secrets-seed.sh

SECRETS_PRIVATE_REPO="${SECRETS_PRIVATE_REPO:-$HOME/SourceRoot/dotfiles-private}"
BACKEND_MARKER="$HOME/.config/secrets/backend"
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
TRUSTED_RECIPIENT_REF="op://Private/mac-mini age key/public key"

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
seed_iu=0
if [[ -f "$IU_REFS_FILE" ]]; then
  collect_refs "$IU_REFS_FILE" "$IU_OP_ACCOUNT" 1
  seed_iu=1
fi
[[ ${#refs[@]} -gt 0 ]] || die "headless.refs has no references"

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
echo "  1Password sign-in..."
op account get --account "$OP_ACCOUNT" >/dev/null 2>&1 || op signin --account "$OP_ACCOUNT"
echo "    ✓ $OP_ACCOUNT"
if ((seed_iu)); then
  op account get --account "$IU_OP_ACCOUNT" >/dev/null 2>&1 || op signin --account "$IU_OP_ACCOUNT"
  echo "    ✓ $IU_OP_ACCOUNT"
fi

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

# --- resolve every ref (biometric) into an in-memory value array -------------
# Values live only in the vals[] shell array (process memory, never disk — R1).
# A ref that cannot be resolved even after retries aborts before any crypto, so
# the cache stays untouched. That invariant is unchanged; what changed is what
# counts as unresolvable.
#
# WHY RETRIES. This loop is one `op read` PROCESS per ref — a few hundred of them
# back to back, each doing its own handshake with the 1Password desktop app. A
# small number of those handshakes fail transiently:
#   error initializing client: response: promptError
#   error initializing client: You are not currently signed in
# and the ref is perfectly readable one second later — verified 2026-08-17 by
# re-reading, by hand, the exact refs two consecutive automated runs died on
# (op://hermes/slack/app-token at 11:17, op://vps/argo/GITLAB_TOKEN at 12:41):
# both returned in ~1s, rc=0, no prompt. So the failure is in the app handshake,
# not the ref, not the vault and not the account.
#
# Aborting the whole run on the first of those is what made the reseed feel
# impossible: it spends the human's Touch ID approval, resolves hundreds of refs,
# then throws all of it away over one hiccup near the end and arms a 6h backoff.
# Three attempts with backoff turn that into a hiccup. A ref that is genuinely
# gone still fails on the first attempt and is NOT retried — a typo'd ref must
# not cost 30s of pointless waiting, and "item not found" is not a hiccup.
#
# WHY EACH READ IS TIME-BOUNDED. A transient handshake failure has a third form:
# `op read` hangs indefinitely waiting on an authorization dialog that never
# renders (observed here — 2 minutes, no output, no dialog on screen). From a
# LaunchAgent that wedges the job until launchd's next tick collides with it.
# The deadline is enforced by run_bounded (below), which escalates TERM to KILL
# because op does not reliably die on SIGTERM.
OP_READ_TIMEOUT="${SECRETS_SEED_OP_READ_TIMEOUT:-30}"
OP_READ_ATTEMPTS="${SECRETS_SEED_OP_READ_ATTEMPTS:-3}"
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
  # op_read_transient's existing contract keeps working unchanged.
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

resolve_batch() {  # $1=account  $2..=indices into refs[] ; fills vals[] by index
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
      *) echo "    ! batch output did not line up with its markers" >&2; return 91 ;;
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
    [[ -n "${vals[$i]+set}" ]] || { echo "    ! batch output was missing ${refs[$i]}" >&2; return 92; }
  done
  return 0
}

# Transient == the desktop-app handshake, never the ref. Keep this list tight:
# retrying a genuine "item not found" only delays an error the human must fix.
op_read_transient() {  # $1=exit status of op_read_once
  [[ "$1" == 124 || "$1" == 137 ]] && return 0   # timeout / SIGKILL after -k
  case "$(cat "$rerr" 2>/dev/null || true)" in
    *promptError*|*"not currently signed in"*|*"error initializing client"*|\
    *"could not connect"*|*"connection refused"*|*"deadline exceeded"*) return 0 ;;
  esac
  return 1
}

echo "  Resolving references..."
vals=()
rerr=$(mktemp "${TMPDIR:-/tmp}/secrets-seed.XXXXXX")

# Try one batched call per account first. On ANY failure fall back to the per-ref
# loop below for that account — `op inject` reports a bad template as one error for
# the whole batch, and "which ref is wrong" is the single most useful thing this
# script tells a human. Speed is not worth losing that, so the fallback is not an
# afterthought: it is the diagnostic path, and the batch is the fast path.
declare -a _pending_idx=()
if (( OP_BATCH )); then
  declare -a _seen_accts=()
  for ((i = 0; i < ${#refs[@]}; i++)); do
    _known=0
    for _a in ${_seen_accts[@]+"${_seen_accts[@]}"}; do
      [[ "$_a" == "${accts[$i]}" ]] && { _known=1; break; }
    done
    (( _known )) || _seen_accts+=("${accts[$i]}")
  done
  for _acct in ${_seen_accts[@]+"${_seen_accts[@]}"}; do
    _idx=()
    for ((i = 0; i < ${#refs[@]}; i++)); do
      [[ "${accts[$i]}" == "$_acct" ]] && _idx+=("$i")
    done
    if resolve_batch "$_acct" "${_idx[@]}"; then
      echo "    ✓ $_acct: resolved ${#_idx[@]} reference(s) in one call"
    else
      echo "    … $_acct: batch resolve failed — falling back to per-reference reads" >&2
      indent <"$rerr" >&2
      _pending_idx+=("${_idx[@]}")
    fi
  done
else
  for ((i = 0; i < ${#refs[@]}; i++)); do _pending_idx+=("$i"); done
fi

# Permanently-unresolvable refs are COLLECTED, not fatal on sight: aborting on the
# first one spends the human's Touch ID pass to learn about exactly one dead ref,
# and the next run then dies on the second. Verified 2026-08-29, when the deleted
# careerpartner item `care-stage` had been silently blocking every reseal — five
# refs, which without this would have been five biometric passes. The run still
# FAILS CLOSED (nothing is sealed or delivered); it just reports the whole list.
dead_refs=""

for i in ${_pending_idx[@]+"${_pending_idx[@]}"}; do
  ref="${refs[$i]}"
  attempt=1
  _dead=0
  while :; do
    # `rc` is captured on the OR side, NOT read from `$?` after an `if`: an `if`
    # whose condition fails and which has no `else` exits 0, so the obvious
    # spelling would classify every failure as status 0 and never see a timeout.
    rc=0
    v=$(op_read_once "${accts[$i]}" "$ref") || rc=$?
    if (( rc == 0 )); then
      break
    fi
    if (( attempt >= OP_READ_ATTEMPTS )) || ! op_read_transient "$rc"; then
      echo "    ✗ op read failed for $ref (account ${accts[$i]}, attempt $attempt/$OP_READ_ATTEMPTS):" >&2
      indent <"$rerr" >&2
      dead_refs="${dead_refs}${ref}  (account ${accts[$i]})
"
      _dead=1
      break
    fi
    # Backoff gives the app time to settle, and — when the cause is a lock — the
    # human a moment to answer. Never printed as a failure: it is not one yet.
    echo "    … transient op error on $ref (attempt $attempt/$OP_READ_ATTEMPTS), retrying" >&2
    sleep $(( attempt * 3 ))
    attempt=$(( attempt + 1 ))
  done
  # Keep going: the point is to end with the COMPLETE list of dead refs, not the
  # first one. vals[i] stays unset — the abort below fires before the jq fold.
  if (( _dead )); then continue; fi
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

if [[ -n "$dead_refs" ]]; then
  echo "" >&2
  echo "  ✗ unresolvable reference(s) — every one, so one pass tells you the whole list:" >&2
  printf '%s' "$dead_refs" | sed 's/^/      /' >&2
  echo "    Each is a ref in headless.refs / headless.iu.refs whose item or field no" >&2
  echo "    longer exists (renamed, deleted or archived). Fix or comment it out, then" >&2
  echo "    re-run — the cache is untouched until every ref resolves." >&2
  die "aborting — cache untouched"
fi

# The short-value heads-up is per-ref in the fallback loop; the batch path skips it,
# so sweep once here for anything it filled. Prints the ref and the length, never
# the value.
for ((i = 0; i < ${#refs[@]}; i++)); do
  [[ -n "${vals[$i]+set}" ]] || die "internal: no value resolved for ${refs[$i]}"
  if [[ ${#vals[$i]} -lt "${REDACT_MIN_LEN:-5}" ]]; then
    echo "    ! ${refs[$i]} resolves to a ${#vals[$i]}-char value — too short to be redacted at runtime (secrets-run won't mask it)" >&2
  fi
done
echo "    ✓ resolved ${#vals[@]} value(s)"

# --- assemble plaintext JSON (in pipes) and encrypt --------------------------
# builtin printf emits ref/value pairs into a pipe (no argv exposure); jq folds
# them into a map; sops seals it. Plaintext never lands as a file, never as argv.
seeded_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

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

emit_pairs() {
  local i
  for ((i = 0; i < ${#refs[@]}; i++)); do
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
deliver_local_cache() {
  mkdir -p cache
  local tmp="cache/secrets.enc.json.$$.tmp"
  printf '%s\n' "$ciphertext" >"$tmp"
  chmod 600 "$tmp"
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
    mv "$tmp" "$dir/secrets.enc.json"
  '
}

if ((deliver_local)); then
  deliver_local_cache || die "local write failed"
else
  deliver_remote_cache || die "delivery to $REMOTE_HOST failed"
fi

echo ""
echo "  ✓ sealed + delivered ${#refs[@]} secret(s) ($seeded_at)"
echo "  · Shells already open keep their old baseline env until a new shell is opened."
echo ""
