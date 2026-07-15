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
REMOTE_HOST="mac-mini"
REMOTE_REPO_REL="SourceRoot/dotfiles-private"
OP_ACCOUNT="tkrumm"   # tkrumm-only; careerpartner (IU) refs are out of scope headless
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
# One op:// ref per non-comment line. Refs are NOT secret (they name vault/item/
# field, no values), so sorting/printing them is fine.
refs=()
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line#"${line%%[![:space:]]*}"}"                 # ltrim
  line="${line%"${line##*[![:space:]]}"}"                 # rtrim
  [[ -z "$line" || "$line" == \#* ]] && continue
  refs+=("$line")
done < "$REFS_FILE"
[[ ${#refs[@]} -gt 0 ]] || die "headless.refs has no references"

# Dedupe (order irrelevant for a map).
deduped=()
while IFS= read -r line; do
  [[ -n "$line" ]] && deduped+=("$line")
done < <(printf '%s\n' "${refs[@]}" | sort -u)
refs=("${deduped[@]}")

# Validate shape + enforce the two hard rules (design.md, PRD §6):
#   1. every entry is an op:// reference;
#   2. op://Private/... is refused unconditionally — Private is human-only and
#      must never enter the headless cache (fail-safe against a fat-finger).
bad=()
for ref in "${refs[@]}"; do
  [[ "$ref" == op://* ]] || { bad+=("not an op:// reference: $ref"); continue; }
  # Case-insensitive vault check: `op` may match vault names case-insensitively,
  # so guard Private/PRIVATE/pRivate alike (not just the literal spelling).
  vault="${ref#op://}"; vault="${vault%%/*}"
  vault_lc=$(printf '%s' "$vault" | tr '[:upper:]' '[:lower:]')
  [[ "$vault_lc" == "private" ]] \
    && bad+=("op://Private is forbidden in the headless cache: $ref")
done
if [[ ${#bad[@]} -gt 0 ]]; then
  echo "  ✗ headless.refs policy violation:" >&2
  printf '      - %s\n' "${bad[@]}" >&2
  die "refusing to seed — fix headless.refs (op:// refs only; never op://Private)."
fi
# Print the ref list before resolving. Refs are non-secret (vault/item/field, no
# values), and this is the human-review checkpoint the explicit-list model relies
# on: the person seeding can eyeball exactly what is about to be cached — and Ctrl-C
# on an unexpected or maliciously-added ref — before any value is read or sealed.
echo "  ${#refs[@]} reference(s) to seed from headless.refs:"
printf '      %s\n' "${refs[@]}"

# --- op sign-in guard (rules/makefile-conventions.md pattern) ---------------
echo "  1Password sign-in..."
op whoami --account "$OP_ACCOUNT" >/dev/null 2>&1 || op signin --account "$OP_ACCOUNT"
echo "    ✓ $OP_ACCOUNT"

# --- Private-vault fail-safe, part 2: deny by UUID too (needs op) ------------
# The pre-sign-in check above rejects op://Private/... by NAME. A ref can also
# target the Private vault by its UUID (op://<uuid>/item/field), bypassing a
# name-only check. Resolve Private's canonical id once and reject any ref whose
# vault segment matches it, closing the UUID bypass (a compromised mini poisoning
# headless.refs so the next biometric seed caches a genuinely-private secret).
private_id=$(op vault get "Private" --account "$OP_ACCOUNT" --format json 2>/dev/null | jq -r '.id // empty' 2>/dev/null || true)
if [[ -n "$private_id" ]]; then
  uuid_bad=()
  for ref in "${refs[@]}"; do
    v="${ref#op://}"; v="${v%%/*}"
    [[ "$v" == "$private_id" ]] && uuid_bad+=("$ref")
  done
  if [[ ${#uuid_bad[@]} -gt 0 ]]; then
    echo "  ✗ headless.refs references the Private vault by UUID:" >&2
    printf '      - %s\n' "${uuid_bad[@]}" >&2
    die "refusing to seed — Private is human-only and must never enter the headless cache."
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

# --- delivery target: local (we are the mini) or ssh mac-mini ---------------
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
# A single failing op read aborts before any crypto (cache stays untouched).
echo "  Resolving references..."
vals=()
rerr=$(mktemp "${TMPDIR:-/tmp}/secrets-seed.XXXXXX")
for ref in "${refs[@]}"; do
  if ! v=$(op read --account "$OP_ACCOUNT" "$ref" 2>"$rerr"); then
    echo "    ✗ op read failed for $ref:" >&2
    indent <"$rerr" >&2
    rm -f "$rerr"
    die "aborting — cache untouched"
  fi
  # v1 constraint: single-line values only. A multi-line value would misalign the
  # newline-paired jq fold below and silently corrupt the cache — refuse it.
  case "$v" in
    *$'\n'*) rm -f "$rerr"; die "value for $ref is multi-line — unsupported (v1: single-line values only); remove it from headless.refs" ;;
  esac
  # Heads-up (not fatal): a value shorter than the runtime redaction floor won't be
  # masked from a command's output on the mini (secrets-run REDACT_MIN_LEN). Print
  # only the ref + length, never the value.
  if [[ ${#v} -lt "${REDACT_MIN_LEN:-5}" ]]; then
    echo "    ! $ref resolves to a ${#v}-char value — too short to be redacted at runtime (secrets-run won't mask it)" >&2
  fi
  vals+=("$v")
done
rm -f "$rerr"
echo "    ✓ resolved ${#vals[@]} value(s)"

# --- assemble plaintext JSON (in pipes) and encrypt --------------------------
# builtin printf emits ref/value pairs into a pipe (no argv exposure); jq folds
# them into a map; sops seals it. Plaintext never lands as a file, never as argv.
seeded_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

emit_pairs() {
  local i
  for ((i = 0; i < ${#refs[@]}; i++)); do
    printf '%s\n%s\n' "${refs[$i]}" "${vals[$i]}"
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
for ref in "${refs[@]}"; do
  grep -qF "\"$ref\"" <<<"$ciphertext" || missing_keys+=("$ref")
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
