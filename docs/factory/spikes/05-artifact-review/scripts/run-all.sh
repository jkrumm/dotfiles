#!/bin/bash
# Re-run the whole spike from a clean scratch install and regenerate evidence/*.log. About 8 minutes, loopback only.
# Everything runs under $HOME_SPIKE (default ~/.local/share/factory/spikes/05-review); every process it starts is stopped.
set -u; source "$(dirname "$0")/lib.sh"
[ -x "$S/bin/plannotator" ] && [ -d "$S/human-review/node_modules/human-review" ] || "$D/setup.sh" 2>&1 | tee "$EV/setup.log"
for step in "plannotator-exercise.sh" "human-review-exercise.sh" "../rv/rv-demo.sh" "../rv/rv-pn-demo.sh"; do
  name=$(basename "$step" .sh); echo ">>> $name"; "$D/$step" > "$EV/$name.log" 2>&1; echo "    exit $? ($(grep -c '^PASS' "$EV/$name.log") PASS, $(grep -c '^FAIL' "$EV/$name.log") FAIL)"
done
stop_all
"$D/summary.sh" | tee "$EV/summary.txt"
