#!/bin/bash
# Daily 09:00 reset of the batt charge cap to 80%, run by
# com.jkrumm.batt-reset. Skips the reset while a pause is in effect (see
# raycast/battery-limit.sh's "Pause days" field / `make batt-limit DAYS=N`),
# so a temporary 100% boost before a trip survives every morning until it
# expires on its own.

BATT="/opt/homebrew/opt/batt/bin/batt"
PAUSE_FILE="$HOME/.config/batt/pause-until"

if [ -f "$PAUSE_FILE" ]; then
  UNTIL="$(cat "$PAUSE_FILE")"
  NOW="$(date +%s)"
  if [ -n "$UNTIL" ] && [ "$NOW" -lt "$UNTIL" ]; then
    echo "$(date): paused until $(date -r "$UNTIL"), skipping reset"
    exit 0
  fi
  rm -f "$PAUSE_FILE"
  echo "$(date): pause expired, resuming daily reset"
fi

"$BATT" limit 80
