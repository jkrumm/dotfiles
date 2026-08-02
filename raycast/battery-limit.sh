#!/bin/bash
# Set the MacBook battery charge cap via batt, optionally pausing the daily
# 09:00 auto-reset to 80% for N days (e.g. before a multi-day trip).
#
# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Battery Limit
# @raycast.mode compact
# @raycast.argument1 { "type": "dropdown", "placeholder": "Cap", "data": [{ "title": "80% (default)", "value": "80" }, { "title": "90%", "value": "90" }, { "title": "100% (full charge)", "value": "100" }] }
# @raycast.argument2 { "type": "text", "placeholder": "Pause days (blank = auto-reset tonight)", "optional": true }
#
# Optional parameters:
# @raycast.packageName Battery
# @raycast.icon 🔋
#
# Documentation:
# @raycast.description Set the MacBook battery charge cap (batt). Auto-resets to 80% at 09:00 daily, unless paused for N days.
# @raycast.author Johannes Krumm

set -euo pipefail
BATT="$(brew --prefix)/opt/batt/bin/batt"
PAUSE_FILE="$HOME/.config/batt/pause-until"
[ -x "$BATT" ] || { echo "batt not installed — run: make batt-setup"; exit 1; }
if ! "$BATT" limit "$1" >/dev/null 2>&1; then
  echo "batt daemon not running — run: make batt-setup"
  exit 1
fi

DAYS="${2:-}"
if [ -n "$DAYS" ]; then
  if ! [[ "$DAYS" =~ ^[0-9]+$ ]] || [ "$DAYS" -lt 1 ]; then
    echo "🔋 Cap → $1% (pause days must be a positive whole number — ignored, auto-reset still runs tonight)"
    exit 0
  fi
  mkdir -p "$(dirname "$PAUSE_FILE")"
  UNTIL="$(date -v+"${DAYS}"d +%s)"
  echo "$UNTIL" > "$PAUSE_FILE"
  echo "🔋 Cap → $1%, auto-reset paused until $(date -r "$UNTIL" "+%a %b %d")"
else
  rm -f "$PAUSE_FILE"
  echo "🔋 Cap → $1% (auto-resets to 80% at 09:00)"
fi
