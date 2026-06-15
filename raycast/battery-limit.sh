#!/bin/bash
# Set the MacBook battery charge cap via batt.
#
# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Battery Limit
# @raycast.mode compact
# @raycast.argument1 { "type": "dropdown", "placeholder": "Cap", "data": [{ "title": "80% (default)", "value": "80" }, { "title": "90%", "value": "90" }, { "title": "100% (full charge)", "value": "100" }] }
#
# Optional parameters:
# @raycast.packageName Battery
# @raycast.icon 🔋
#
# Documentation:
# @raycast.description Set the MacBook battery charge cap (batt). Auto-resets to 80% each morning.
# @raycast.author Johannes Krumm

set -euo pipefail
BATT="$(brew --prefix)/opt/batt/bin/batt"
[ -x "$BATT" ] || { echo "batt not installed — run: make batt-setup"; exit 1; }
if "$BATT" limit "$1" >/dev/null 2>&1; then
  echo "🔋 Battery cap → $1%"
else
  echo "batt daemon not running — run: make batt-setup"
  exit 1
fi
