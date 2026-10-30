#!/bin/bash
# Exercise the rv prototype end to end: blocking wait, ack/redelivery, crash recovery, supersede, close, inbox, timeout+default.
# usage: rv-demo.sh   (scratch state under $HOME_SPIKE; loopback only; stops every process it starts)
set -u
S="${HOME_SPIKE:-$HOME/.local/share/factory/spikes/05-review}"; RVD="$(cd "$(dirname "$0")" && pwd)"; RV="bun $RVD/rv.ts"; export RV_PORT="${RV_PORT:-39221}" RV_DB="$S/rv-work.db"
W="$S/rv-work"; rm -rf "$W" "$RV_DB"* && mkdir -p "$W"; cp "$S/artifacts/BRIEF.md" "$W/BRIEF.md"; cp "$S/artifacts/episode-lifecycle.html" "$W/diagram.html"
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS  $1 ($2)"; pass=$((pass+1)); else echo "FAIL  $1: want [$3] got [$2]"; fail=$((fail+1)); fi; }
start_server() { cd "$W"; nohup $RV serve > "$W/server.log" 2>&1 & echo $! > "$W/server.pid"; cd - > /dev/null; sleep 0.8; }
kill_server() { local p; p=$(cat "$W/server.pid" 2>/dev/null) || return 0; kill -9 "$p" 2>/dev/null; sleep 0.3; kill -0 "$p" 2>/dev/null && echo "WARN: server $p survived SIGKILL"; return 0; }
port_owner() { lsof -nP -tiTCP:"$RV_PORT" -sTCP:LISTEN | head -1; }
trap 'kill_server; kill $(jobs -p) 2>/dev/null' EXIT
now() { python3 -c 'import time; print(round(time.time(),2))'; }

start_server
echo "== submit two artifacts in two projects"
A=$($RV submit proj-alpha "$W/BRIEF.md"); echo "$A"; ID1=$(echo "$A" | jq .id)
B=$($RV submit proj-beta "$W/diagram.html"); echo "$B"; ID3=$(echo "$B" | jq .id)
check "resubmit of identical content is idempotent" "$($RV submit proj-alpha "$W/BRIEF.md" | jq -r .unchanged)" "true"

echo "== blocking wait is released by a comment (anchored to a quote)"
t0=$(now); $RV wait "$ID1" --timeout 60 > "$W/w1.out" & WP=$!
sleep 1.5
$RV comment "$ID1" --quote "Never break the lane used to fix things" --prefix "- " --suffix ": the manual" --body "Name the lane explicitly" > /dev/null
wait $WP; t1=$(now)
check "wait status" "$(jq -r .status "$W/w1.out")" "feedback"
check "comment quote delivered" "$(jq -r '.comments[0].quote' "$W/w1.out")" "Never break the lane used to fix things"
echo "   released $(python3 -c "print(round($t1-$t0-1.5,2))")s after the comment"
CUR=$(jq .cursor "$W/w1.out")

echo "== unacked feedback is redelivered (at-least-once); acked feedback is not"
check "redelivery without ack" "$($RV wait "$ID1" --timeout 5 | jq -r .status)" "feedback"
t0=$(now); R=$($RV wait "$ID1" --ack "$CUR" --timeout 3 --default ship); t1=$(now)
check "after ack: timeout carries the agent default (non-blocking)" "$(echo "$R" | jq -r '.status + ":" + .default')" "timeout:ship"
echo "   gave up after $(python3 -c "print(round($t1-$t0,1))")s and proceeds with the default"

echo "== crash recovery: comment, SIGKILL the server, restart, the comment is still there"
$RV comment "$ID1" --quote "Phase 4" --body "after the crash?" > /dev/null
OLDPID=$(port_owner); kill_server; start_server
check "server really restarted (new pid owns the port)" "$([ -n "$(port_owner)" ] && [ "$(port_owner)" != "$OLDPID" ] && echo yes || echo no)" "yes"
check "restart: unacked comment survives" "$($RV wait "$ID1" --timeout 5 | jq -r '.comments[0].body')" "after the crash?"
CUR=$($RV wait "$ID1" --timeout 5 | jq .cursor)

echo "== a wait in flight survives a server crash + restart"
$RV wait "$ID1" --ack "$CUR" --timeout 40 > "$W/w2.out" & WP=$!
sleep 1.5; OLDPID=$(port_owner); kill_server; sleep 1; start_server; sleep 1.2
check "second restart: new pid owns the port" "$([ -n "$(port_owner)" ] && [ "$(port_owner)" != "$OLDPID" ] && echo yes || echo no)" "yes"
$RV comment "$ID1" --quote "Phase 6" --body "sent after the restart" > /dev/null
wait $WP
check "in-flight wait delivered after restart" "$(jq -r '.comments[0].body' "$W/w2.out")" "sent after the restart"

echo "== supersede: a new revision releases the old waiter"
$RV wait "$ID1" --ack "$(jq .cursor "$W/w2.out")" --timeout 30 > "$W/w3.out" & WP=$!
sleep 1; echo "<!-- revised -->" >> "$W/BRIEF.md"; A2=$($RV submit proj-alpha "$W/BRIEF.md"); echo "$A2"
wait $WP; check "old waiter status" "$(jq -r .status "$W/w3.out")" "superseded"
check "new revision number" "$(echo "$A2" | jq .rev)" "2"; ID2=$(echo "$A2" | jq .id)

echo "== close releases the waiter on the current revision"
$RV wait "$ID2" --timeout 30 > "$W/w4.out" & WP=$!; sleep 1; $RV close "$ID2" > /dev/null; wait $WP
check "closed status" "$(jq -r .status "$W/w4.out")" "closed"

echo "== nobody answers: bounded wait returns timeout + default, never a gate"
t0=$(now); R=$($RV wait "$ID3" --timeout 4 --default "proceed-with-default"); t1=$(now)
check "timeout + default" "$(echo "$R" | jq -r '.status + ":" + .default')" "timeout:proceed-with-default"
echo "   elapsed $(python3 -c "print(round($t1-$t0,1))")s"

echo "== resolve + project-grouped inbox"
$RV comment "$ID3" --quote "Life of an OpenCode episode" --body "title typo" > /dev/null
$RV resolve 4 > /dev/null 2>&1; $RV inbox
kill_server; check "no server left running" "$(port_owner)" ""
echo; echo "RESULT: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
