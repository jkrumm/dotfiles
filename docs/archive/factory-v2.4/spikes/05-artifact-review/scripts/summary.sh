#!/bin/bash
# Tally the evidence logs and re-check that nothing leaked outside the scratch tree. Usage: summary.sh > ../evidence/summary.txt
set -u; source "$(dirname "$0")/lib.sh"
echo "checks per evidence log (PASS / FAIL):"
for f in plannotator-exercise human-review-exercise rv-demo rv-pn-demo; do
  printf '  %-26s %3s PASS  %s FAIL\n' "$f" "$(grep -c '^PASS' "$EV/$f.log")" "$(grep -c '^FAIL' "$EV/$f.log")"
done
echo "processes still running from the scratch tree: $(ps -axo command | grep -F "spikes/05-review" | grep -v grep | wc -l | tr -d ' ')"
echo "real-home footprint (must stay 0 or absent):"
for f in ~/.claude/settings.json ~/.claude.json ~/.codex/config.toml ~/.codex/AGENTS.md ~/.config/opencode/opencode.json ~/.config/herdr/config.toml; do
  [ -f "$f" ] && echo "  $(grep -c -i plannotator "$f") plannotator mentions in $(echo "$f" | sed "s#^$HOME#~#")"; done
for d in ~/.plannotator ~/.human-review ~/.claude/rules/plannotator-inbox.md ~/.local/bin/plannotator; do t=$(echo "$d" | sed "s#^$HOME#~#"); [ -e "$d" ] && echo "  PRESENT: $t" || echo "  absent:  $t"; done
ups=$(tailscale serve status 2>/dev/null | grep -o 'proxy http://[^ ]*:[0-9]*' | grep -o '[0-9]*$' | tr '\n' ' ')
echo "tailnet serve upstream ports (all pre-existing services): ${ups:-none}"
mine=""; for u in $ups; do { [ "$u" -ge 39201 ] && [ "$u" -le 39299 ]; } && mine="$mine $u"; [ -f "$(inbox_reg)" ] && [ "$u" = "$(jq -r .port "$(inbox_reg)")" ] && mine="$mine $u"; done
echo "serve mappings pointing at a scratch port (must be none): ${mine:-none}"
