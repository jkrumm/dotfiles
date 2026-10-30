#!/bin/bash
# Shared helpers for the spike 05 scripts. Source it; never run it. Everything lives under the scratch tree.
S="${HOME_SPIKE:-$HOME/.local/share/factory/spikes/05-review}"; export HOME_SPIKE="$S"
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"            # this scripts/ directory
EV="${EVIDENCE_DIR:-$D/../evidence}"; mkdir -p "$EV"
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS  $1 ($2)"; pass=$((pass+1)); else echo "FAIL  $1: want [$3] got [$2]"; fail=$((fail+1)); fi; }
now() { python3 -c 'import time; print(round(time.time(),2))'; }
secs() { python3 -c "print(round($2-$1,1))"; }
wait_http() { for _ in $(seq 1 "${2:-30}"); do curl -s -m 2 -o /dev/null "$1" && return 0; sleep 1; done; return 1; }
inbox_reg() { echo "$S/home/.plannotator/inbox/inbox.json"; }
inbox_port() { jq -r .port "$(inbox_reg)"; }
inbox_pid() { jq -r .pid "$(inbox_reg)"; }
stop_all() { # stop every process this spike may have started (matched by the scratch path)
  pkill -f "$S/bin/plannotator" 2>/dev/null; pkill -f "$S/human-review/node_modules" 2>/dev/null; pkill -f "bun .*rv/rv.ts serve" 2>/dev/null
  sleep 1; pkill -9 -f "$S/bin/plannotator" 2>/dev/null; return 0; }
