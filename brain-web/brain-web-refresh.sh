#!/usr/bin/env bash
# Content-refresh for the brain vault reader (~/SourceRoot/basalt-ui-obsidian,
# served as `brain-web` on the mini — see its Makefile/docker-compose.yml).
# Every 5 minutes under launchd (com.jkrumm.brain-web-refresh), polls the
# vault's git HEAD and rebuilds the reader's static site (`make refresh`) only
# when it moved.
#
# THIS AGENT IS DOWNSTREAM OF brain-sync.sh, not a replacement for it: that
# agent moves the vault's git HEAD (pull/commit/push, every 300s on both
# machines — see brain/brain-sync.sh); this one only reacts to the move, and
# only matters on the mini, where the built dist/ is actually served. A
# no-op tick (HEAD unchanged since the last refresh) must be cheap and
# silent — one `git rev-parse`, nothing else, no log line.
#
# THIS AGENT NEVER TOUCHES THE CONTAINER. `make refresh` only rebuilds
# apps/demo/dist — nginx bind-mounts that directory read-only and reads it
# fresh off disk per request (see docker-compose.yml), so a new build is live
# on its very next request with no restart. Recreating the container is
# `make up`'s job, for a CODE change, not this agent's.
set -euo pipefail

# launchd hands agents a minimal PATH. `make refresh` shells out to `bun`
# (install + two package builds + a Vite build), which is Homebrew-managed on
# this machine — NOT pointing ProgramArguments at bun (or any Homebrew
# binary) directly is the same lesson already paid for elsewhere in this repo
# (see the opbackup/collie plists): macOS Background Task Management denies a
# raw Homebrew binary as the entry point and silently downgrades the agent to
# `[enabled, disallowed]`, skipping RunAtLoad. This script is the entry point
# instead; EnvironmentVariables > PATH in the plist carries Homebrew forward
# into it, and this export is the belt-and-braces copy for a manual run.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

log()  { printf '%s brain-web-refresh: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"; }
warn() { log "$*" >&2; }

VAULT="${BRAIN_VAULT:-$HOME/SourceRoot/brain}"
APP_DIR="${BRAIN_WEB_APP_DIR:-$HOME/SourceRoot/basalt-ui-obsidian}"
STATE_DIR="${BRAIN_WEB_STATE_DIR:-$HOME/Library/Caches/brain-web-refresh}"
MARKER="$STATE_DIR/last-head"
LOCK_DIR="${BRAIN_WEB_LOCK_DIR:-$HOME/Library/Caches/brain-web-refresh.lock}"

# --- guards ------------------------------------------------------------------
#
# Quiet exit 0, not an error — same reasoning as brain-sync-setup: a machine
# missing either repo should not fail (or log) every 5 minutes over it.

[ -d "$VAULT/.git" ] || exit 0
[ -d "$APP_DIR" ] || exit 0

# --- single instance ----------------------------------------------------------
#
# `make refresh` (bun install on a cold cache + two package builds + a Vite
# build) can outrun the 5-minute interval; mkdir is the same atomic primitive
# brain-sync.sh uses and for the same reason — it fails if the directory
# exists and cannot half-exist, unlike a PID file written after the fact.

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  holder="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  # `ps`, not `kill -0`: the latter returns EPERM (not ESRCH) for a live pid
  # owned by another user and cannot tell the two apart.
  if [ -n "$holder" ] && ps -p "$holder" >/dev/null 2>&1; then
    exit 0
  fi
  lock_born="$(stat -f %m "$LOCK_DIR" 2>/dev/null || true)"
  lock_age=$(( $(date +%s) - ${lock_born:-0} ))
  if [ -z "$holder" ] && [ "$lock_age" -lt 60 ]; then
    exit 0
  fi
  warn "reclaiming the lock left by pid ${holder:-unknown} (${lock_age}s old) — no such process, so the previous run was killed mid-flight"
  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR" 2>/dev/null || exit 0
fi
printf '%s' "$$" >"$LOCK_DIR/pid"
trap 'rm -rf "$LOCK_DIR"' EXIT

# --- compare HEAD --------------------------------------------------------------

CURRENT="$(git -C "$VAULT" rev-parse HEAD 2>/dev/null || true)"
[ -n "$CURRENT" ] || exit 0

STORED="$(cat "$MARKER" 2>/dev/null || true)"

# The whole "cheap and silent" contract lives in this one comparison — every
# line below it only runs on an actual content change.
if [ "$CURRENT" = "$STORED" ]; then
  exit 0
fi

# --- refresh -------------------------------------------------------------------

log "vault HEAD moved ${STORED:-<none>} -> $CURRENT — refreshing dist/"
if make -C "$APP_DIR" refresh; then
  mkdir -p "$STATE_DIR"
  printf '%s' "$CURRENT" >"$MARKER"
  log "refreshed dist/ for $CURRENT"
else
  # Marker NOT advanced — a failed build must be retried, not silently
  # treated as caught up.
  warn "make refresh failed for $CURRENT — marker left at ${STORED:-<none>}, will retry next tick"
  exit 1
fi
