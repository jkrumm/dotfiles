#!/usr/bin/env bash
# Guarded automatic reseed of the headless Mac mini's secrets cache.
#
# This runs from the present-human MacBook's existing opbackup LaunchAgent. It
# never runs on the cache backend: the mini deliberately has no interactive
# 1Password session. The remote cache mtime is the source of truth, so a manual
# seed also resets the clock without needing a second local stamp.

set -euo pipefail

STATE_DIR="${OPBACKUP_SEED_STATE_DIR:-${OPBACKUP_STATE_DIR:-$HOME/.local/state/opbackup}}"
ATTEMPT_STAMP="$STATE_DIR/seed-last-attempt"
MAX_AGE_DAYS="${OPBACKUP_SEED_MAX_AGE_DAYS:-5}"
RETRY_HOURS="${OPBACKUP_SEED_RETRY_HOURS:-6}"
REMOTE_HOST="${OPBACKUP_SEED_REMOTE_HOST:-mini}"
# The two REMOTE_* defaults carry a LITERAL, unexpanded `$HOME` and are quoted
# with double quotes in the ssh payloads below, so the MINI's shell expands them.
# The accounts differ — /Users/johannes.krumm here, /Users/jkrumm there — so a
# locally-expanded path names a directory that does not exist on the mini. That
# failure is silent and inverted: the probe's `[ -f ]` is false, `printf 0` makes
# the cache look like it was last written in 1970, and the >5d gate therefore
# passes on EVERY hourly tick. What looks like a five-day cadence becomes "seed
# whenever the 6h backoff expires", and the freshness-heartbeat `cd` at the end
# fails for the same reason, so the Uptime Kuma monitor stays red after a
# successful reseed. Keep the `\$HOME`; do not "simplify" it to a real path.
REMOTE_CACHE_FILE="${OPBACKUP_SEED_REMOTE_CACHE_FILE:-\$HOME/SourceRoot/dotfiles-private/cache/secrets.enc.json}"
SEED_SCRIPT="${OPBACKUP_SEED_SCRIPT:-$HOME/SourceRoot/dotfiles/scripts/secrets-seed.sh}"
REMOTE_DOTFILES_DIR="${OPBACKUP_SEED_REMOTE_DOTFILES_DIR:-\$HOME/SourceRoot/dotfiles}"
BACKEND_FILE="${OPBACKUP_SEED_BACKEND_FILE:-$HOME/.config/secrets/backend}"
SSH_CMD="${OPBACKUP_SEED_SSH:-/usr/bin/ssh}"
PGREP_CMD="${OPBACKUP_SEED_PGREP:-/usr/bin/pgrep}"
IOREG_CMD="${OPBACKUP_SEED_IOREG:-/usr/sbin/ioreg}"
STAT_CMD="${OPBACKUP_SEED_STAT:-/usr/bin/stat}"
DATE_CMD="${OPBACKUP_SEED_DATE:-/bin/date}"
OSASCRIPT_CMD="${OPBACKUP_SEED_OSASCRIPT:-/usr/bin/osascript}"
OP_AGENT_SOCK="${OPBACKUP_SEED_OP_AGENT:-$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock}"
OP_CMD="${OPBACKUP_SEED_OP:-/opt/homebrew/bin/op}"
OP_ACCOUNT="${OPBACKUP_SEED_OP_ACCOUNT:-tkrumm}"
TIMEOUT_CMD="${OPBACKUP_SEED_TIMEOUT:-/opt/homebrew/bin/timeout}"
UNLOCK_TIMEOUT="${OPBACKUP_SEED_UNLOCK_TIMEOUT:-20}"

log() { echo "$("$DATE_CMD" '+%Y-%m-%d %H:%M:%S') opbackup-seed: $*"; }
skip() { log "skip — $*"; exit 0; }

age_seconds() {
  local mtime now
  mtime=$("$STAT_CMD" -f '%m' "$1" 2>/dev/null || echo 0)
  now="${OPBACKUP_SEED_NOW:-$("$DATE_CMD" +%s)}"
  echo $(( now - mtime ))
}

screen_locked() {
  local out
  out=$("$IOREG_CMD" -n Root -d1 -k CGSSessionScreenIsLocked 2>/dev/null || true)
  case "$out" in
    *'"CGSSessionScreenIsLocked" = Yes'*) return 0 ;;
  esac
  return 1
}

notify() {
  "$OSASCRIPT_CMD" -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1 || true
}

backend=$(tr -d '[:space:]' <"$BACKEND_FILE" 2>/dev/null || echo "")
[ "$backend" = "op" ] || skip "secrets backend is '${backend:-unset}', not 'op'"

# `ssh mini` is OpenSSH + key, unlike the keyless Tailscale SSH this machine uses
# for homelab/vps — and this MacBook holds NO private key on disk (`ls ~/.ssh/id_*`
# is empty). Every identity comes from the 1Password SSH agent, whose socket an
# interactive shell exports from ~/.zsh/conf.d/secrets.zsh. A LaunchAgent gets no
# such shell, and launchd does NOT leave SSH_AUTH_SOCK unset — it points it at
# Apple's own ssh-agent, a perfectly valid socket holding ZERO identities. So the
# obvious `[ -S "$SSH_AUTH_SOCK" ]` guard passes, ssh finds no key, and this script
# reports `mini unreachable` and exits 0 — a normal-looking skip, forever, with the
# reseed never running. Prefer 1Password's socket; treat the inherited one as the
# fallback, deliberately the opposite of the obvious ordering. (Same trap and same
# resolution as dbtunnel/db-tunnel.sh.)
#
# Exported rather than passed as `-o IdentityAgent=…`: secrets-seed.sh shells out
# to `ssh mini` itself, so the child needs it too — and the env var sidesteps the
# quoting hazard in the -o form, whose value contains a space ("Group Containers").
if [ -S "$OP_AGENT_SOCK" ]; then
  export SSH_AUTH_SOCK="$OP_AGENT_SOCK"
elif [ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "$SSH_AUTH_SOCK" ]; then
  log "1Password agent socket absent; falling back to inherited SSH_AUTH_SOCK"
else
  skip "no SSH agent socket — is the 1Password desktop app running? ($OP_AGENT_SOCK)"
fi

remote_mtime=$("$SSH_CMD" -o BatchMode=yes -o ConnectTimeout=8 "$REMOTE_HOST" \
  "if [ -f \"$REMOTE_CACHE_FILE\" ]; then stat -f %m \"$REMOTE_CACHE_FILE\"; else printf 0; fi" \
  2>/dev/null) || skip "$REMOTE_HOST unreachable"

case "$remote_mtime" in
  ''|*[!0-9]*) skip "remote cache mtime unavailable" ;;
esac

# A missing cache and an ancient one are different conditions and must not share a
# code path: `printf 0` above means "no file at that path on $REMOTE_HOST", which
# is a wiring fault far more often than it is a genuinely unseeded mini, and as an
# age it reads as 20000+ days and silently passes every staleness gate. Refuse.
if [ "$remote_mtime" -eq 0 ]; then
  log "FAILED — no cache at $REMOTE_CACHE_FILE on $REMOTE_HOST (path is expanded by the REMOTE shell; the accounts differ)"
  exit 1
fi

cache_age=$(( ${OPBACKUP_SEED_NOW:-$("$DATE_CMD" +%s)} - remote_mtime ))
if [ "$cache_age" -lt $(( MAX_AGE_DAYS * 86400 )) ]; then
  skip "remote cache $(( cache_age / 86400 ))d old (< ${MAX_AGE_DAYS}d)"
fi

tried_ago=$(age_seconds "$ATTEMPT_STAMP")
if [ "$tried_ago" -lt $(( RETRY_HOURS * 3600 )) ]; then
  skip "seed attempted $(( tried_ago / 60 ))m ago (backoff ${RETRY_HOURS}h)"
fi

! screen_locked || skip "screen is locked"
"$PGREP_CMD" -x "1Password" >/dev/null 2>&1 || skip "1Password desktop is not running"

# RUNNING IS NOT UNLOCKED, and conflating the two is what produces the prompt
# storm. secrets-seed.sh resolves ~26 refs with one `op read` each; against an
# unlocked app that is 26 silent calls, but against a LOCKED one every single call
# raises its own "op möchte auf Daten aus anderen Apps zugreifen" dialog, fails
# with `error initializing client: You are not currently signed in` when nobody
# answers it in time, and the loop marches on to the next ref. Observed twice on
# 2026-08-17: dozens of dialogs, and the seed aborted anyway.
#
# `op whoami` is the cheap probe — no secret, one call, instant against an unlocked
# app. Against a locked one it raises exactly ONE dialog, which is the biometric
# moment this job is supposed to have. Bounded by `timeout` because an unanswered
# dialog otherwise hangs the job until launchd's next tick collides with it.
# Failing here SKIPS at exit 0 rather than starting work that cannot finish: the
# next hourly tick retries, and the notification says what to do meanwhile.
if ! "$TIMEOUT_CMD" "$UNLOCK_TIMEOUT" "$OP_CMD" whoami --account "$OP_ACCOUNT" >/dev/null 2>&1; then
  notify "1Password secrets cache" "Unlock 1Password — the mini's cache reseed is due and will run on the next tick."
  skip "1Password is running but locked (op whoami failed within ${UNLOCK_TIMEOUT}s) — unlock it; next tick retries"
fi

[ -x "$SEED_SCRIPT" ] || { log "seed script missing or not executable: $SEED_SCRIPT"; exit 1; }

mkdir -p "$STATE_DIR"
: >"$ATTEMPT_STAMP"
log "running — remote cache $(( cache_age / 86400 ))d old; approve the Touch ID prompts"
notify "1Password secrets cache" "Starting — approve the Touch ID prompts."

if "$SEED_SCRIPT"; then
  if "$SSH_CMD" -o BatchMode=yes -o ConnectTimeout=8 "$REMOTE_HOST" \
    "cd \"$REMOTE_DOTFILES_DIR\" && make secrets-freshness-check" >/dev/null 2>&1; then
    log "done — secrets cache reseeded and freshness heartbeat refreshed"
    notify "1Password secrets cache" "Complete — cache reseeded and monitor refreshed on $REMOTE_HOST."
    exit 0
  fi
  log "FAILED — cache was reseeded, but freshness heartbeat could not be refreshed"
  notify "1Password secrets cache" "Cache reseeded; freshness monitor update failed."
  exit 1
fi

log "FAILED — cache unchanged; will retry after ${RETRY_HOURS}h"
notify "1Password secrets cache failed" "See ~/Library/Logs/opbackup.log"
exit 1
