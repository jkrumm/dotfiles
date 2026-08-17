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
# Record the agent the caller handed us: under launchd this is the whole
# difference between a working reseed and a permanent "mini unreachable".
if [[ -n "${FAKE_SSH_AGENT_LOG:-}" ]]; then
  printf '%s\n' "${SSH_AUTH_SOCK:-<unset>}" >"$FAKE_SSH_AGENT_LOG"
fi
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

# A real unix socket, because the script's guard is `[ -S ]` — a plain file
# would pass a naive test and prove nothing.
fake_agent="$TMP/agent.sock"
python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$fake_agent"
test -S "$fake_agent"

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
  OPBACKUP_SEED_OP_AGENT="$fake_agent" \
  FAKE_SSH_AGENT_LOG="${FAKE_SSH_AGENT_LOG:-}" \
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
OPBACKUP_SEED_OP_AGENT="$fake_agent" \
"$SCRIPT"
test ! -e "$TMP/unreachable.marker"

# ssh must be handed 1Password's agent, never whatever launchd inherited. Apple's
# ssh-agent is a valid socket holding zero identities, so an inherited one that
# survives to `ssh mini` yields Permission denied → a permanent silent skip.
rm -rf "$TMP/state"
FAKE_SSH_AGENT_LOG="$TMP/agent.seen" \
  run_seed 700000 181000 "$TMP/agentcheck.marker"
test -f "$TMP/agentcheck.marker"
grep -qxF "$fake_agent" "$TMP/agent.seen"

# No 1Password socket and no usable inherited one: skip cleanly, exit 0, and do
# NOT run the seed — a Touch ID prompt nobody can answer is worse than waiting.
rm -rf "$TMP/state" "$TMP/noagent.marker"
set +e
out=$(SEED_MARKER="$TMP/noagent.marker" \
  FAKE_CACHE_MTIME=181000 \
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
  OPBACKUP_SEED_OP_AGENT="$TMP/nonexistent.sock" \
  SSH_AUTH_SOCK="" \
  "$SCRIPT")
rc=$?
set -e
test "$rc" -eq 0
test ! -e "$TMP/noagent.marker"
case "$out" in *"no SSH agent socket"*) ;; *) echo "expected agent-socket skip, got: $out" >&2; exit 1 ;; esac

printf '%s\n' 'opbackup-seed-auto: all tests passed'
