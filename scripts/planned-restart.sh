#!/usr/bin/env bash
# planned-restart.sh — restart the mini for a pending macOS update, in a window, without stranding the leads.
#
#   make planned-restart              MacBook-only, TTY or YES=1 (it reboots the host every agent runs on)
#   DRY_RUN=1 make planned-restart    prints every step with its command and runs NOTHING (no ssh, no factory call)
#
# WHY. 2026-11-15 01:09 softwareupdated ran its "tonight" install and restarted the mini at 01:11 with 12 leads
# working; the host was back at 01:23, 11 sessions stayed down for seven hours and seven Issues were stranded.
# Automatic install is now off (drift-check asserts it), so every macOS update needs a restart, and this is it:
#
#   1 drain     factory queue set drain          no new Issue is admitted. Refused = stop: an unannounced restart IS the incident.
#   2 tell      factory session note <lead> ...  every non-idle lead hears the time and what to do (commit, push, no new merge/deploy)
#   3 quiesce   factory merge-lock / deploy-lock <project> -- true, per project: returns once the running window ended
#   4 restart   mini-macos-update.sh (YES=1)     the existing applier: pins the label, snapshots the resume labels, waits down and up,
#                                                asserts the version moved. Its header owns the "do not force a reboot" lesson.
#   5 recover   make recovery-check              polls until 0 waiting (hc-resume is paced, minutes)
#   6 resume    factory queue set run            only after a clean recovery; an unclean one leaves the queue drained and says so
#
# A failure before step 4 starts puts the queue back to run (nothing happened). From step 4 on it never silently
# undrains: a half-restarted host with leads running into it is worse than a drained queue.
#
# Overrides (tests): SSH_BIN, MACOS_UPDATE_BIN, MINI_HOST, PLANNED_RESTART_{GRACE,LOCK_WAIT,RECOVER_WAIT,POLL}, BACKEND_FILE.
# bash 3.2 (the MacBook's /bin/bash).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST="${MINI_HOST:-mini}"
SSH_BIN="${SSH_BIN:-ssh}"
UPDATER="${MACOS_UPDATE_BIN:-$HERE/mini-macos-update.sh}"
DRY_RUN="${DRY_RUN:-0}"
GRACE="${PLANNED_RESTART_GRACE:-300}"                 # s the leads get to wrap up after the note
LOCK_WAIT="${PLANNED_RESTART_LOCK_WAIT:-5400}"        # s per lock, the merge lock's own cap
RECOVER_WAIT="${PLANNED_RESTART_RECOVER_WAIT:-2700}"  # s for hc-resume to bring every terminal back
POLL="${PLANNED_RESTART_POLL:-30}"
BACKEND_FILE="${BACKEND_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/secrets/backend}"
SU_DOMAIN=/Library/Preferences/com.apple.SoftwareUpdate
# Expands on the mini: a non-interactive ssh has neither ~/.local/bin (factory) nor brew on its PATH.
MINI_PATH='PATH=$HOME/.local/bin:/opt/homebrew/bin:/usr/bin:/bin'

say() { echo "  $*"; }
die() { echo "✗ $*" >&2; exit 1; }
mini() { "$SSH_BIN" -o ConnectTimeout=6 -o BatchMode=yes "$HOST" "$MINI_PATH; $*"; }

NOTE_TEXT="Planned restart of the mini (macOS update) in about $((GRACE / 60)) min. The queue is draining: start no merge window and no deploy. Commit and push your branch and report or ship what is done; whatever is not done waits. Your terminal is resumed by hc-resume afterwards: re-read git, the pull request and production before you repeat anything."

STEP_DRAIN='factory queue set drain'
STEP_LIST='factory read sessions --live --format json | jq -r ".sessions[] | select(.role == \"lead\" and .state != \"idle\") | .id"'
STEP_NOTE='factory session note <lead> "<restart notice>"   (each non-idle lead)'
STEP_LOCKS='factory merge-lock --project <p> -- true ; factory deploy-lock --project <p> -- true   (every project of the queue)'
STEP_RESTART="YES=1 $UPDATER"
STEP_RECOVER='make recovery-check ARGS=--json   (until waiting = 0)'
STEP_RUN='factory queue set run'

if [ "$DRY_RUN" = 1 ]; then
  echo "planned-restart (DRY_RUN=1: nothing below is run)"
  say "0 preflight   backend must be op (MacBook); $HOST reachable; a macOS update pending ($SU_DOMAIN RecommendedUpdates)"
  say "1 drain       on $HOST: $STEP_DRAIN   (refused = stop)"
  say "2 tell        on $HOST: $STEP_LIST"
  say "              on $HOST: $STEP_NOTE"
  say "              note: $NOTE_TEXT"
  say "              then ${GRACE}s for the leads to wrap up"
  say "3 quiesce     on $HOST: $STEP_LOCKS   (${LOCK_WAIT}s per lock)"
  say "4 restart     here: $STEP_RESTART"
  say "5 recover     on $HOST: $STEP_RECOVER   (up to ${RECOVER_WAIT}s, every ${POLL}s)"
  say "6 resume      on $HOST: $STEP_RUN   (only after step 5 read 0 waiting)"
  say "failure before step 4: the queue is set back to run; from step 4 on it stays drained and the output says so"
  exit 0
fi

DRAINED=0
RESTARTING=0
undrain() {
  mini "$STEP_RUN" >/dev/null 2>&1 || { echo "✗ could not set the queue back to run: run '$STEP_RUN' on $HOST" >&2; return 1; }
  DRAINED=0
  say "queue: run"
}
on_exit() {
  local rc=$?
  [ "$rc" -eq 0 ] && return 0
  if [ "$DRAINED" = 1 ] && [ "$RESTARTING" = 0 ]; then
    say "failed before the restart started: putting the queue back"
    undrain || true
  elif [ "$DRAINED" = 1 ]; then
    echo "✗ the queue stays DRAINED (the restart started, so the host is not known to be healthy)." >&2
    echo "  Read: make recovery-check (on $HOST). When the leads are back: $STEP_RUN (on $HOST)" >&2
  fi
}
trap on_exit EXIT

# --- 0 preflight -------------------------------------------------------------
backend="$( [ -f "$BACKEND_FILE" ] && cat "$BACKEND_FILE" || echo op )"
[ "$backend" = "op" ] || die "backend is '$backend': run this from the MacBook (the applier needs biometric 1Password)"
[ -f "$UPDATER" ] || die "applier not found: $UPDATER"
mini true >/dev/null 2>&1 || die "$HOST is not reachable over ssh"
pending="$(mini "defaults read $SU_DOMAIN RecommendedUpdates 2>/dev/null || true" | sed -n 's/.*"Display Name" = "\(.*\)";/\1/p' | tr '\n' ',' | sed 's/,$//')"
[ -n "$pending" ] || { say "no macOS update pending: nothing to restart for"; exit 0; }
say "pending: $pending"

if [ "${YES:-0}" != 1 ]; then
  [ -t 0 ] || die "refusing to restart $HOST unattended: re-run with YES=1"
  printf "  This drains the factory queue and restarts %s. Type 'yes' to continue: " "$HOST"
  read -r reply
  [ "$reply" = yes ] || die "aborted"
fi

# --- 1 drain -----------------------------------------------------------------
say "1 drain the queue"
mini "$STEP_DRAIN" >/dev/null 2>&1 || die "the factory refused '$STEP_DRAIN': an unannounced restart is the incident this exists to prevent"
DRAINED=1

# --- 2 tell the leads --------------------------------------------------------
say "2 tell the leads"
leads="$(mini "factory read sessions --live --format json | jq -r '.sessions[] | select(.role == \"lead\" and .state != \"idle\") | .id'" 2>/dev/null || true)"
n=0
for lead in $leads; do
  if mini "factory session note $lead $(printf '%q' "$NOTE_TEXT")" >/dev/null 2>&1; then n=$((n + 1)); else say "· note to $lead failed"; fi
done
say "· $n lead(s) told; ${GRACE}s to wrap up"
sleep "$GRACE"

# --- 3 quiesce ---------------------------------------------------------------
say "3 wait for merge windows and deploys to end"
projects="$(mini "factory capacity get | jq -r '.queue.projects | keys[]'" 2>/dev/null)" || die "could not read the project list from the factory"
[ -n "$projects" ] || die "the factory returned no projects: refusing to guess that nothing is merging"
for p in $projects; do
  for lock in merge-lock deploy-lock; do
    rc=0
    /usr/bin/perl -e 'alarm shift; exec @ARGV or exit 127' "$LOCK_WAIT" \
      "$SSH_BIN" -o ConnectTimeout=6 -o BatchMode=yes "$HOST" "$MINI_PATH; factory $lock --project $p -- true" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 0 ] || die "$lock of $p did not free within ${LOCK_WAIT}s (rc=$rc): a window is still running"
  done
done
say "· every merge window and deploy lock is free"

# --- 4 restart ---------------------------------------------------------------
say "4 restart $HOST (mini-macos-update)"
RESTARTING=1
YES=1 bash "$UPDATER"

# --- 5 recover ---------------------------------------------------------------
say "5 wait for the terminals to come back"
waited=0
while :; do
  out="$(mini "cd \$HOME/SourceRoot/dotfiles && make --no-print-directory recovery-check ARGS=--json" 2>/dev/null | tail -1 || true)"
  if [ -n "$out" ] && [ "$(printf '%s' "$out" | jq -r '.waiting // empty' 2>/dev/null)" = 0 ]; then
    say "· $(printf '%s' "$out" | jq -r '"\(.resumable) resumable, \(.running) running claude, \(.waiting) waiting, \(.skipped) skipped"')"
    break
  fi
  [ "$waited" -lt "$RECOVER_WAIT" ] || die "recovery-check still does not read 0 waiting after ${RECOVER_WAIT}s (last: ${out:-no answer})"
  sleep "$POLL"
  waited=$((waited + POLL))
done

# --- 6 resume ----------------------------------------------------------------
say "6 queue back to run"
undrain || die "recovered, but the queue is still drained"
echo "  ✓ planned restart done"
