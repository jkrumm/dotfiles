#!/usr/bin/env bash
# Regression tests for the guarded automatic secrets-cache seed.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/opbackup-seed-auto.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/opbackup-seed-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fake_ssh="$TMP/ssh"
cat >"$fake_ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${FAKE_SSH_FAIL:-0}" == 1 ]]; then
  exit 255
fi
if [[ " $* " == *" make secrets-freshness-check "* ]]; then
  : >"${FAKE_FRESHNESS_MARKER:?}"
  exit 0
fi
printf '%s\n' "${FAKE_CACHE_MTIME:?}"
EOF
chmod +x "$fake_ssh"

fake_pgrep="$TMP/pgrep"
cat >"$fake_pgrep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$fake_pgrep"

fake_ioreg="$TMP/ioreg"
cat >"$fake_ioreg" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$fake_ioreg"

backend_file="$TMP/backend"
printf '%s\n' op >"$backend_file"

fake_seed="$TMP/seed"
cat >"$fake_seed" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: >"${SEED_MARKER:?}"
EOF
chmod +x "$fake_seed"

run_seed() {
  local now="$1" mtime="$2" marker="$3"
  rm -f "$marker" "$marker.freshness"
  FAKE_CACHE_MTIME="$mtime" \
  FAKE_FRESHNESS_MARKER="$marker.freshness" \
  SEED_MARKER="$marker" \
  OPBACKUP_SEED_NOW="$now" \
  OPBACKUP_SEED_MAX_AGE_DAYS=5 \
  OPBACKUP_SEED_REMOTE_HOST=mini \
  OPBACKUP_SEED_REMOTE_CACHE_FILE=/remote/cache/secrets.enc.json \
  OPBACKUP_SEED_REMOTE_DOTFILES_DIR=/remote/dotfiles \
  OPBACKUP_SEED_SSH="$fake_ssh" \
  OPBACKUP_SEED_PGREP="$fake_pgrep" \
  OPBACKUP_SEED_IOREG="$fake_ioreg" \
  OPBACKUP_SEED_BACKEND_FILE="$backend_file" \
  OPBACKUP_SEED_STATE_DIR="$TMP/state" \
  OPBACKUP_SEED_SCRIPT="$fake_seed" \
  "$SCRIPT"
}

# A six-day-old cache must trigger the seed.
run_seed 700000 181000 "$TMP/due.marker"
test -f "$TMP/due.marker"
test -f "$TMP/due.marker.freshness"

# A two-day-old cache must be a no-op.
run_seed 700000 527200 "$TMP/fresh.marker"
test ! -e "$TMP/fresh.marker"

# An unreachable mini must not prompt or run the seed.
rm -f "$TMP/unreachable.marker"
FAKE_SSH_FAIL=1 \
SEED_MARKER="$TMP/unreachable.marker" \
OPBACKUP_SEED_NOW=700000 \
OPBACKUP_SEED_MAX_AGE_DAYS=5 \
OPBACKUP_SEED_REMOTE_HOST=mini \
OPBACKUP_SEED_REMOTE_CACHE_FILE=/remote/cache/secrets.enc.json \
OPBACKUP_SEED_SSH="$fake_ssh" \
OPBACKUP_SEED_PGREP="$fake_pgrep" \
OPBACKUP_SEED_IOREG="$fake_ioreg" \
OPBACKUP_SEED_BACKEND_FILE="$backend_file" \
OPBACKUP_SEED_STATE_DIR="$TMP/state" \
OPBACKUP_SEED_SCRIPT="$fake_seed" \
"$SCRIPT"
test ! -e "$TMP/unreachable.marker"

printf '%s\n' 'opbackup-seed-auto: all tests passed'
