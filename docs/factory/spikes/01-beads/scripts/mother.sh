#!/usr/bin/env bash
# The 'mother' loop: poll ready -> claim (lease) -> heartbeat while working -> close.
# One script, two backends: TASKCLI="bd" (beads) or TASKCLI="python3 sqlite_tasks.py" (baseline).
# usage: mother.sh <name>     env: WORK=secs of simulated work  HB=heartbeat period  LOG=file
#                                 ONCE=1 exit when nothing is ready  EXCLUDE=types that are not work
#                                 EXIT_ON_LOST=1 stop after losing a lease (test hook)
ME=${1:?name}; CLI=${TASKCLI:-bd}; WORK=${WORK:-20}; HB=${HB:-5}; LOG=${LOG:-/dev/null}
EXCLUDE=${EXCLUDE:-epic,decision}
log() { echo "$(date +%s) $ME $*" >> "$LOG"; }
while :; do
  id=$($CLI ready --json --limit 1 --exclude-type "$EXCLUDE" 2>/dev/null | jq -r '.[0].id // empty')
  if [ -z "$id" ]; then
    log idle; [ -n "${ONCE:-}" ] && exit 0
    sleep 1; continue
  fi
  if ! $CLI update "$id" --claim --actor "$ME" >/dev/null 2>&1; then log "lost-claim $id"; continue; fi
  log "claimed $id"
  waited=0; lost=
  while [ "$waited" -lt "$WORK" ]; do
    sleep "$HB"; waited=$((waited + HB))
    $CLI heartbeat "$id" --actor "$ME" >/dev/null 2>&1 || { lost=1; break; }
    log "hb $id"
  done
  [ -n "$lost" ] && { log "lost-lease $id"; [ -n "${EXIT_ON_LOST:-}" ] && exit 3; continue; }
  if $CLI close "$id" -r "done by $ME" --actor "$ME" >/dev/null 2>&1; then log "closed $id"; else log "close-failed $id"; fi
done
