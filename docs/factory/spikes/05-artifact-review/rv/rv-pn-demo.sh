#!/bin/bash
# Exercise rv-pn (the rv contract on the Plannotator Inbox): submit, bounded wait + default, human reply, Inbox crash mid-wait.
set -u
S="${HOME_SPIKE:-$HOME/.local/share/factory/spikes/05-review}"; RVD="$(cd "$(dirname "$0")" && pwd)"; export PLANNOTATOR_DATA_DIR="$S/home/.plannotator" PLANNOTATOR_BIN="$RVD/../scripts/pn" RV_SESSION="spike5-adapter" HOME_SPIKE="$S"
RVPN="bun $RVD/rv-pn.ts"; P="$S/projects/proj-alpha"; mkdir -p "$P"; REG="$PLANNOTATOR_DATA_DIR/inbox/inbox.json"
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS  $1 ($2)"; pass=$((pass+1)); else echo "FAIL  $1: want [$3] got [$2]"; fail=$((fail+1)); fi; }
now() { python3 -c 'import time; print(round(time.time(),2))'; }
trap 'kill $(jobs -p) 2>/dev/null; pkill -f "$S/bin/plannotator" 2>/dev/null' EXIT

echo "== submit (project folder = Inbox project; file attached; idempotent per content)"
R=$($RVPN submit "$P" "$S/artifacts/BRIEF.md" --default "ship the plan unchanged"); echo "$R"; TID=$(echo "$R" | jq -r .id)
check "resubmit same content + default replays" "$($RVPN submit "$P" "$S/artifacts/BRIEF.md" --default "ship the plan unchanged" | jq -r .replayed)" "true"

echo "== nobody answers: bounded wait returns timeout + default"
t0=$(now); R=$($RVPN wait "$TID" "$P" --timeout 4 --default "ship the plan unchanged"); t1=$(now)
check "timeout + default" "$(echo "$R" | jq -r '.status + ":" + .default')" "timeout:ship the plan unchanged"
echo "   elapsed $(python3 -c "print(round($t1-$t0,1))")s"

echo "== human replies in the Inbox; the waiting agent gets feedback"
$RVPN wait "$TID" "$P" --timeout 40 > "$S/out/w-pn1.out" & WP=$!
sleep 2; python3 -I "$RVD/../scripts/inbox_reply.py" "$REG" "$TID" "Fine overall. Tighten the Fixed list." > /dev/null
wait $WP
check "wait status" "$(jq -r .status "$S/out/w-pn1.out")" "feedback"
check "reply text delivered" "$(jq -r .body "$S/out/w-pn1.out" | head -1)" "Fine overall. Tighten the Fixed list."

echo "== Inbox crashes (SIGKILL) while the agent waits; the adapter restarts it and still gets the reply"
R=$($RVPN submit "$P" "$S/artifacts/episode-lifecycle.html" --default proceed); TID2=$(echo "$R" | jq -r .id)
$RVPN wait "$TID2" "$P" --timeout 60 > "$S/out/w-pn2.out" 2>"$S/out/w-pn2.err" & WP=$!
sleep 2; OLD=$(jq .pid "$REG"); kill -9 "$OLD"
for i in $(seq 1 40); do sleep 1; NEW=$(jq .pid "$REG"); [ "$NEW" != "$OLD" ] && curl -sf -m 2 -o /dev/null "http://localhost:$(jq .port "$REG")/api/inbox/health" && break; done
echo "   inbox back after ~${i}s (pid $OLD -> $NEW)"
python3 -I "$RVD/../scripts/inbox_reply.py" "$REG" "$TID2" "Diagram title needs a verb." > /dev/null
wait $WP
check "inbox pid changed (restarted by the adapter)" "$([ "$(jq .pid "$REG")" != "$OLD" ] && echo yes || echo no)" "yes"
check "feedback delivered after the crash" "$(jq -r .status "$S/out/w-pn2.out")" "feedback"
echo; echo "RESULT: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
