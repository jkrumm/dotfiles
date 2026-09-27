#!/bin/bash
# Set the MacBook battery charge cap via batt, optionally pausing the daily
# 09:00 auto-reset to 80% for N days (e.g. before a multi-day trip).
# Called by the Battery command of the tinycast-extensions repo:
#   $1 = cap in percent (required), $2 = pause days (optional).

set -euo pipefail
BATT="$(brew --prefix)/opt/batt/bin/batt"
PAUSE_FILE="$HOME/.config/batt/pause-until"
[ -x "$BATT" ] || { echo "batt not installed — run: make batt-setup"; exit 1; }
# The launcher field is free text, so validate before batt turns a typo into a
# misleading "daemon not running".
if ! [[ "${1:-}" =~ ^[0-9]+$ ]] || [ "$1" -lt 10 ] || [ "$1" -gt 100 ]; then
  echo "Cap must be a whole number from 10 to 100 (80 = default, 100 = full charge)"
  exit 1
fi
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
