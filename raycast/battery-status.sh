#!/bin/bash
# Show the batt charge-limiter status.
#
# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Battery Status
# @raycast.mode fullOutput
#
# Optional parameters:
# @raycast.packageName Battery
# @raycast.icon 🔋
#
# Documentation:
# @raycast.description Show the current batt charge limiter status (cap, charge, rate).
# @raycast.author Johannes Krumm

set -euo pipefail
BATT="$(brew --prefix)/opt/batt/bin/batt"
PAUSE_FILE="$HOME/.config/batt/pause-until"
[ -x "$BATT" ] || { echo "batt not installed — run: make batt-setup"; exit 1; }
"$BATT" status
if [ -f "$PAUSE_FILE" ]; then
  UNTIL="$(cat "$PAUSE_FILE")"
  NOW="$(date +%s)"
  if [ -n "$UNTIL" ] && [ "$NOW" -lt "$UNTIL" ]; then
    echo ""
    echo "⏸  Auto-reset paused until $(date -r "$UNTIL" "+%a %b %d, %H:%M")"
  fi
fi
