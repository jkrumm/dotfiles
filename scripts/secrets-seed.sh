#!/usr/bin/env bash
set +x
set -euo pipefail
umask 077
ulimit -c 0 2>/dev/null || true  # no core dumps — they would capture resolved plaintext from memory

# secrets-seed — resolve each profile's varlock schema (biometric 1Password
# resolvers fire here) and seal the result into the SOPS+age cache that
# secrets-run consumes headlessly on the mini. Run from a MacBook (human
# present); running on the mini itself (Screen Sharing) is also supported —
# the split is about *when* a human approves, not which keyboard they use.
#
# Plaintext only ever exists in pipe buffers / process memory: never a temp
# file, never argv, never xtrace. See dotfiles-private/docs/design.md (D5).
#
# Usage:
#   scripts/secrets-seed.sh                    # seed every profiles/*.env.schema
#   PROFILES="baseline,work" scripts/secrets-seed.sh   # seed a subset (space or comma separated)

SECRETS_PRIVATE_REPO="${SECRETS_PRIVATE_REPO:-$HOME/SourceRoot/dotfiles-private}"
BACKEND_MARKER="$HOME/.config/secrets/backend"
REMOTE_HOST="mac-mini"
REMOTE_REPO_REL="SourceRoot/dotfiles-private"
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
[[ -d "$SECRETS_PRIVATE_REPO/profiles" ]] \
  || die "no profiles/ directory in $SECRETS_PRIVATE_REPO — private repo not yet initialized"
command -v varlock >/dev/null 2>&1 || die "varlock not installed — brew install varlock"
command -v sops >/dev/null 2>&1 || die "sops not installed — brew install sops"
command -v op >/dev/null 2>&1 || die "op (1Password CLI) not installed — brew install --cask 1password-cli"

# cd so .sops.yaml (recipient config) and profiles/cache paths resolve relatively.
cd "$SECRETS_PRIVATE_REPO"

# --- enumerate profiles ------------------------------------------------------
profiles=()
if [[ -n "${PROFILES:-}" ]]; then
  raw_profiles=()
  IFS=', ' read -r -a raw_profiles <<<"$PROFILES"
  for p in ${raw_profiles[@]+"${raw_profiles[@]}"}; do
    [[ -n "$p" ]] && profiles+=("$p")
  done
else
  for f in profiles/*.env.schema; do
    [[ -f "$f" ]] || continue
    profiles+=("$(basename "$f" .env.schema)")
  done
fi
[[ ${#profiles[@]} -gt 0 ]] || die "no profiles to seed (profiles/*.env.schema empty, or PROFILES matched nothing)"

# Validate profile names BEFORE any use: they are interpolated into file paths
# and into the remote ssh command string in deliver_remote_cache. A name with
# shell metacharacters would be RCE on the mini; a name with `../` would be path
# traversal out of cache/. Names come from filenames or a user-supplied
# PROFILES= — neither is trusted. Restrict to a safe charset.
for p in "${profiles[@]}"; do
  [[ "$p" =~ ^[A-Za-z0-9_-]+$ ]] \
    || die "invalid profile name '$p' — only letters, digits, '_' and '-' are allowed"
done

schema_paths=()
for p in "${profiles[@]}"; do
  schema="profiles/$p.env.schema"
  [[ -f "$schema" ]] || die "no schema for profile '$p' at $SECRETS_PRIVATE_REPO/$schema"
  schema_paths+=("$schema")
done

# --- tier gate (PRD §6): the T0-only blast-radius bound is the primary §5 ----
# compensating control. Enforce it here, not by a review-only comment: every
# declared item in a seeded schema must carry a `# tier: T0` or `# tier: T1`
# marker in its attached comment block. A missing/other tier aborts the seed —
# no unmarked (or T2/T3) item ever reaches the cache.
validate_schema_tiers() {
  local schema="$1" line pending_tier="" bad=()
  while IFS= read -r line; do
    if [[ -z "$line" || "$line" == '# ---'* ]]; then
      pending_tier=""
      continue
    fi
    if [[ "$line" =~ ^#[[:space:]]*tier:[[:space:]]*([A-Za-z0-9]+) ]]; then
      pending_tier="${BASH_REMATCH[1]}"
      continue
    fi
    [[ "$line" == \#* ]] && continue
    if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      case "$pending_tier" in
        T0 | T1) : ;;
        "") bad+=("${line%%=*} (no tier: marker)") ;;
        *) bad+=("${line%%=*} (tier: $pending_tier — only T0/T1 allowed)") ;;
      esac
      pending_tier=""
    fi
  done <"$schema"
  if [[ ${#bad[@]} -gt 0 ]]; then
    echo "    ✗ tier policy violation in $schema:" >&2
    printf '        - %s\n' "${bad[@]}" >&2
    die "refusing to seed — every item needs a '# tier: T0|T1' marker (PRD §6). T2/T3 must never enter the cache."
  fi
}

for schema in "${schema_paths[@]}"; do
  validate_schema_tiers "$schema"
done

# --- op signin guards (rules/makefile-conventions.md pattern) ---------------
echo "  1Password sign-in..."
op whoami --account tkrumm >/dev/null 2>&1 || op signin --account tkrumm
echo "    ✓ tkrumm"
if grep -l "account=careerpartner" "${schema_paths[@]}" >/dev/null 2>&1; then
  op whoami --account careerpartner >/dev/null 2>&1 || op signin --account careerpartner
  echo "    ✓ careerpartner"
fi

# --- recipient pinning (defends against a swapped .sops.yaml recipient) ------
# Assert the recipient SET in .sops.yaml is exactly {trusted}: an attacker with
# write access to the repo could otherwise *append* a second recipient (sops
# supports many) so the cache is also encrypted to their key, while the first
# recipient still matches. So we reject on any extra recipient, not just a
# mismatched first one.
echo "  Verifying age recipient..."
expected_recipient=$(op read "$TRUSTED_RECIPIENT_REF" --account tkrumm 2>/dev/null || true)
# `|| true` so a no-match under pipefail doesn't abort into a false negative.
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

# Extract declared item names from a schema (comments excluded).
schema_declared_keys() {
  local schema="$1" line
  while IFS= read -r line; do
    [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
    printf '%s\n' "${line%%=*}"
  done <"$schema"
}

deliver_local_cache() {
  local profile="$1" ciphertext="$2" tmp final
  mkdir -p cache
  tmp="cache/$profile.enc.env.tmp"
  final="cache/$profile.enc.env"
  printf '%s\n' "$ciphertext" >"$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$final"
}

# $profile is interpolated into the remote command string, so it MUST be safe:
# it is charset-validated to ^[A-Za-z0-9_-]+$ up front (no shell metacharacters,
# no `/` or `..`), which is what makes this interpolation injection-proof. The
# remote side re-guards against `/`/`..` as belt-and-suspenders. The ciphertext
# rides on stdin (so it can't be positional); $HOME/$tmp/$final expand remotely.
# shellcheck disable=SC2029
deliver_remote_cache() {
  local profile="$1" ciphertext="$2"
  printf '%s\n' "$ciphertext" | ssh "$REMOTE_HOST" "
    set -e
    umask 077
    p='$profile'
    case \"\$p\" in */*|*..*) echo \"invalid profile: \$p\" >&2; exit 1 ;; esac
    dir=\"\$HOME/$REMOTE_REPO_REL/cache\"
    mkdir -p \"\$dir\"
    cat > \"\$dir/\$p.enc.env.tmp\"
    mv \"\$dir/\$p.enc.env.tmp\" \"\$dir/\$p.enc.env\"
    chmod 600 \"\$dir/\$p.enc.env\"
  "
}

# --- seed each profile --------------------------------------------------------
summary=()
failed=0

for p in "${profiles[@]}"; do
  schema="profiles/$p.env.schema"
  echo ""
  echo "  Profile: $p"

  # Capture stdout (the dotenv payload that gets sealed) SEPARATELY from stderr,
  # so no varlock warning/info line is ever woven into the encrypted cache.
  resolved=""
  resolve_err=""
  resolve_err=$(mktemp "${TMPDIR:-/tmp}/secrets-seed.XXXXXX")
  if ! resolved=$(varlock load --path "$schema" --format env --skip-cache 2>"$resolve_err"); then
    echo "    ✗ varlock load failed:"
    indent <"$resolve_err"
    rm -f "$resolve_err"
    summary+=("✗ $p — varlock load failed")
    failed=1
    continue
  fi
  rm -f "$resolve_err"

  seeded_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  dotenv_blob="$resolved
_SECRETS_SEEDED_AT=$seeded_at"

  ciphertext=""
  if ! ciphertext=$(printf '%s\n' "$dotenv_blob" | sops --encrypt --input-type dotenv --output-type dotenv --filename-override "cache/$p.enc.env" /dev/stdin 2>&1); then
    echo "    ✗ sops encrypt failed:"
    printf '%s\n' "$ciphertext" | indent
    summary+=("✗ $p — sops encrypt failed")
    failed=1
    continue
  fi

  if [[ "$ciphertext" != *'ENC['* ]]; then
    echo "    ✗ ciphertext sanity check failed — no ENC[ marker found, aborting (cache untouched)"
    summary+=("✗ $p — ciphertext sanity check failed")
    failed=1
    continue
  fi

  missing_keys=()
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    grep -q "^${key}=" <<<"$ciphertext" || missing_keys+=("$key")
  done < <(schema_declared_keys "$schema")

  if [[ ${#missing_keys[@]} -gt 0 ]]; then
    echo "    ✗ ciphertext missing declared key(s): ${missing_keys[*]} — aborting (cache untouched)"
    summary+=("✗ $p — missing key(s): ${missing_keys[*]}")
    failed=1
    continue
  fi

  if ((deliver_local)); then
    if ! deliver_local_cache "$p" "$ciphertext"; then
      echo "    ✗ local write failed"
      summary+=("✗ $p — local write failed")
      failed=1
      continue
    fi
  else
    if ! deliver_remote_cache "$p" "$ciphertext"; then
      echo "    ✗ delivery to $REMOTE_HOST failed"
      summary+=("✗ $p — ssh delivery to $REMOTE_HOST failed")
      failed=1
      continue
    fi
  fi

  echo "    ✓ sealed + delivered ($seeded_at)"
  summary+=("✓ $p")
done

echo ""
echo "  Summary"
for line in ${summary[@]+"${summary[@]}"}; do
  echo "    $line"
done
echo ""
echo "  · Shells already open keep their old baseline env until a new shell is opened."
echo ""

((failed == 0)) || exit 1
