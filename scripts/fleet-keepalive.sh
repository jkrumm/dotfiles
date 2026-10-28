#!/usr/bin/env bash
# fleet-keepalive.sh — keep a fleet's mother session going unattended (overnight runs).
#
# Usage: fleet-keepalive.sh <agent> <repo-dir> [interval-seconds]
#
# Every interval (default 300 s) it looks at <agent> (the mother's herdr agent name):
#   - <repo-dir>/docs/waves/handoff/STOP exists, or PLAN.md has no active wave → exit (a real stop
#     or the plan's end; the mother writes STOP with the reason).
#   - the pane shows Claude Code's usage-limit banner → wait; the session resumes itself at reset.
#   - idle/done on two checks in a row → `rd say` a resume nudge (rd say verifies delivery).
#   - gone on three checks in a row (herdr restart, crashed pane) → spawn a fresh mother with
#     `rd wave` and rename it back to <agent>; she continues from docs/waves/handoff/mother.md.
#
# Start it detached so it outlives the calling session:
#   nohup fleet-keepalive.sh agent-workflows-mother ~/SourceRoot/agent-workflows \
#     >>~/.local/state/fleet-keepalive/agent-workflows.log 2>&1 &
# One instance per agent (pid file); a second start exits.
set -uo pipefail

agent=${1:?usage: fleet-keepalive.sh <agent> <repo-dir> [interval-seconds]}
repo=${2:?usage: fleet-keepalive.sh <agent> <repo-dir> [interval-seconds]}
interval=${3:-300}
repo=$(cd "$repo" && pwd) || exit 2
state="$HOME/.local/state/fleet-keepalive"
mkdir -p "$state"
pidfile="$state/$agent.pid"

if [[ -f $pidfile ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
  echo "already running (pid $(cat "$pidfile"))"
  exit 0
fi
echo $$ >"$pidfile"
trap 'rm -f "$pidfile"' EXIT

log() { echo "$(date '+%F %T') $*"; }

NUDGE="keepalive: you are idle while the plan still has an active wave. Resume the fleet loop: read docs/waves/handoff/mother.md (Next action) and docs/waves/PLAN.md, check the lead (rd agents, rd read), and continue. If one of the four stop reasons truly holds, write it into docs/waves/handoff/STOP, commit, and stop."
RESPAWN="You are the MOTHER of the build fleet in this repo, respawned by fleet-keepalive after the previous mother's pane vanished. Read AGENTS.md, docs/concept.md (§0), docs/waves/PLAN.md, docs/waves/handoff/mother.md and ~/.claude/skills/wave/roles/mother.md, then follow the /wave skill in fleet mode from the handoff's Next action. Stop only for the four stop reasons (write docs/waves/handoff/STOP)."

status_of() {
  herdr agent get "$1" 2>/dev/null | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin)["result"]["agent"].get("agent_status") or "unknown")
except Exception:
    print("missing")'
}

idle=0
missing=0
log "watching $agent in $repo every ${interval}s"
while true; do
  if [[ -f $repo/docs/waves/handoff/STOP ]]; then
    log "STOP present: $(head -1 "$repo/docs/waves/handoff/STOP")"
    exit 0
  fi
  if ! grep -q 'status: active' "$repo/docs/waves/PLAN.md" 2>/dev/null; then
    log "no active wave in PLAN.md: plan finished"
    exit 0
  fi

  st=$(status_of "$agent")
  if [[ $st == missing ]]; then
    idle=0
    missing=$((missing + 1))
    log "$agent missing ($missing/3)"
    if ((missing >= 3)); then
      out=$(cd "$repo" && RD_ORCHESTRATED=1 RD_WAVE_MODEL=opus RD_WAVE_EFFORT=high rd wave "$(basename "$repo")" "$RESPAWN" 2>&1)
      log "respawn: $(tail -2 <<<"$out" | tr '\n' ' ')"
      new=$(grep -o "claude '[^']*'" <<<"$out" | head -1 | tr -d "'" | sed 's/^claude //')
      if [[ -n $new ]]; then
        herdr agent rename "$new" "$agent" >/dev/null 2>&1 && log "renamed $new → $agent"
        missing=0
      fi
    fi
  else
    missing=0
    screen=$(rd read "$agent" 2>/dev/null | tail -12)
    if grep -q 'Usage limit reached' <<<"$screen"; then
      idle=0
      log "$agent at a usage limit; waiting for its reset"
    elif [[ $st == idle || $st == "done" ]]; then
      idle=$((idle + 1))
      if ((idle >= 2)); then
        log "$agent $st on $idle checks: nudging"
        rd say "$agent" "$NUDGE" 2>&1 | tail -1 | sed 's/^/  rd say: /'
        idle=0
      fi
    else
      idle=0
    fi
  fi
  sleep "$interval"
done
