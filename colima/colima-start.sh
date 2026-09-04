#!/usr/bin/env bash
# Supervised entry point for the colima brew service. Installed into colima's
# brew-service plist by `make setup` (_setup-colima) — see there for why the
# plist is rewritten rather than trusted as brew ships it. That file is
# `sh.brew.colima.plist` since Homebrew 6 (renamed from
# `homebrew.mxcl.colima.plist` on the next start/restart, not at upgrade time),
# so it is RESOLVED by scripts/lib/brew-service.sh, never spelled.
#
# THE BUG THIS EXISTS FOR. Homebrew generates that plist with
#
#     KeepAlive => { SuccessfulExit => true }
#
# which restarts the job only when it exits ZERO. `colima start -f` runs the VM
# in the foreground, so exit 0 means "the VM shut down cleanly" and a NON-zero
# exit means "the VM failed to start" — the condition is exactly inverted
# against what you want. A dirty Lima image after an unclean shutdown makes
# `colima start -f` fail, launchd shrugs, and Docker stays down until a human
# logs in. Nothing checks `docker info`, nothing pages. On a headless box that
# is a silent outage of every container on the machine.
#
# `{ Crashed => true }` is NOT the fix: launchd's Crashed means death by signal,
# not a non-zero exit, so a failed start would still not be retried.
#
# Bare `KeepAlive => true` is the fix, and it needs this wrapper, because on its
# own it turns a persistently broken image into a full Lima VM boot attempt
# every 10 seconds forever — burning CPU on a machine whose whole point is to
# run agents.
#
# THE POLICY. Up to MAX_FAILS fast attempts (launchd's own 10s throttle spaces
# them), then one BACKOFF_SECONDS cool-off, then try again from scratch. It
# never gives up permanently and that is deliberate: on a headless host the
# cause is often transient and self-clearing (a full disk that log rotation
# frees, a Lima update mid-flight), and a supervisor that latches off has to be
# reset by the human who was not there in the first place.
#
# A run that STAYED UP counts as a success however it ended. Otherwise a
# `colima stop` or a `brew services restart` months from now would land on a
# failure counter left over from an unrelated bad night.

set -u

COLIMA="${COLIMA_BIN:-/opt/homebrew/opt/colima/bin/colima}"
STATE_DIR="${COLIMA_SUPERVISOR_STATE:-$HOME/.local/state/colima-supervisor}"
FAIL_FILE="$STATE_DIR/consecutive-failures"

MAX_FAILS="${COLIMA_MAX_FAILS:-5}"
BACKOFF_SECONDS="${COLIMA_BACKOFF_SECONDS:-600}"
# A start that survives this long booted successfully; whatever ended it later
# is not a start failure.
UP_SECONDS="${COLIMA_UP_SECONDS:-120}"

mkdir -p "$STATE_DIR"
fails=$(cat "$FAIL_FILE" 2>/dev/null || echo 0)
case "$fails" in ''|*[!0-9]*) fails=0 ;; esac

if [ "$fails" -ge "$MAX_FAILS" ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') colima-start: $fails consecutive start failures — cooling off ${BACKOFF_SECONDS}s before retrying"
  # Sleeping in the foreground is the backoff: launchd sees the job as running,
  # so KeepAlive does not respawn it, and no timer or second agent is needed.
  sleep "$BACKOFF_SECONDS"
  echo 0 > "$FAIL_FILE"
  exit 1
fi

started=$(date +%s)
"$COLIMA" start -f
rc=$?
elapsed=$(( $(date +%s) - started ))

# ADOPTION. If the VM is already up but not owned by this process — a
# `brew services restart` started it detached, or a human ran `colima start` —
# `colima start -f` returns 0 within a second with "already running, ignoring".
# Counting that as a healthy run makes bare KeepAlive respawn this wrapper
# every ~10s forever, with the failure counter never engaging because rc=0
# reads as success. Stop the detached VM and start it again in the foreground
# so launchd owns it. One hop only: if it happens twice in a row something else
# is holding the VM, and that is a failure, not a loop.
if [ "$rc" -eq 0 ] && [ "$elapsed" -lt "$UP_SECONDS" ] && "$COLIMA" status >/dev/null 2>&1; then
  # Only a CLEAN history earns an adoption. When the previous attempt already
  # failed (a VM that booted but whose docker never came up leaves the VM
  # running, so the next `start -f` also says "already running"), stopping and
  # restarting it every cycle just makes each failed attempt 90s instead of
  # 10s. Count it and let the bounded-retry policy reach its cool-off.
  if [ "$fails" -gt 0 ]; then
    echo $((fails + 1)) > "$FAIL_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') colima-start: VM up but the previous start failed — not adopting, counting (failure $((fails + 1))/$MAX_FAILS)" >&2
    exit 1
  fi
  if [ -z "${COLIMA_SUPERVISOR_ADOPTED:-}" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') colima-start: VM already running outside this supervisor — stopping it so launchd owns it"
    "$COLIMA" stop
    COLIMA_SUPERVISOR_ADOPTED=1 exec "$0" "$@"
  fi
  echo $((fails + 1)) > "$FAIL_FILE"
  echo "$(date '+%Y-%m-%d %H:%M:%S') colima-start: VM still owned elsewhere after one adoption attempt (failure $((fails + 1))/$MAX_FAILS)" >&2
  exit 1
fi

if [ "$rc" -eq 0 ] || [ "$elapsed" -ge "$UP_SECONDS" ]; then
  echo 0 > "$FAIL_FILE"
  echo "$(date '+%Y-%m-%d %H:%M:%S') colima-start: exited rc=$rc after ${elapsed}s (counted as a healthy run)"
else
  echo $((fails + 1)) > "$FAIL_FILE"
  echo "$(date '+%Y-%m-%d %H:%M:%S') colima-start: START FAILED rc=$rc after ${elapsed}s (failure $((fails + 1))/$MAX_FAILS)" >&2
fi

exit "$rc"
