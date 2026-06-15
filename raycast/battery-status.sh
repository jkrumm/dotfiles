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
[ -x "$BATT" ] || { echo "batt not installed — run: make batt-setup"; exit 1; }
"$BATT" status
