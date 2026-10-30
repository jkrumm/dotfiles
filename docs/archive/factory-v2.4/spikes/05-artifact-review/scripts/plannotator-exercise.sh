#!/bin/bash
# Option A: plannotator 0.28.26 (scratch binary). Exercises the blocking gate, the Inbox, durability, grouping, timeouts and the door.
#   P1 annotate --gate --json   P2 HTML + crash + draft restore   P3 tab closed (client lease)
#   I1 Inbox send/wait/reply    I2 SIGKILL + read-back            I3 worktree grouping   I4 door (Host guard, framing, HTTP MCP)
set -u; source "$(dirname "$0")/lib.sh"
trap 'stop_all' EXIT
rm -rf "$S/home/.plannotator"; mkdir -p "$S/out" "$S/projects/proj-alpha" "$S/projects/proj-beta"
rm -f "$S"/out/p-*   # --result-file refuses to overwrite an existing file, so a re-run needs a clean out/
A="$S/projects/proj-alpha"; B="$S/projects/proj-beta"; export HOME_SPIKE="$S"
FB="$S/home/.plannotator/feedback/proj-alpha/index.jsonl"

echo "== P1: annotate --gate --json (blocking gate), run from project proj-alpha"
cd "$A"; PN_EXTRA_ENV="PLANNOTATOR_PORT=39201" "$D/pn" annotate "$S/artifacts/BRIEF.md" --gate --json --result-file "$S/out/p-gate.result.json" > "$S/out/p-gate.stdout" 2> "$S/out/p-gate.stderr" & GP=$!
wait_http http://localhost:39201/api/plan 40
sleep 6; check "nobody answers: the gate is still blocking after 6 s (annotate has no timeout flag)" "$(kill -0 $GP 2>/dev/null && echo yes || echo no)" "yes"
NONCE=$(curl -s localhost:39201/api/plan | jq -r .serverSession)
jq -n --arg n "$NONCE" '{feedback: "# Markdown Annotations\n\n## 1. Feedback on: \"The owner decides business questions only\"\n> Define business question with three examples.\n", annotations: [{id: "a1", type: "COMMENT", text: "Define business question with three examples.", originalText: "The owner decides business questions only", author: "spike"}, {id: "a2", type: "GLOBAL_COMMENT", text: "Say what happens when nobody answers.", author: "spike"}], serverSession: $n}' > "$S/out/p-gate.body.json"
curl -s -X POST -H 'content-type: application/json' --data @"$S/out/p-gate.body.json" localhost:39201/api/feedback; echo
for _ in $(seq 1 15); do kill -0 $GP 2>/dev/null || break; sleep 1; done
echo "   stdout (the agent reads): $(cat "$S/out/p-gate.stdout")"
check "stdout decision" "$(jq -r .decision "$S/out/p-gate.stdout")" "annotated"
check "result-file identical to stdout" "$(cmp -s "$S/out/p-gate.stdout" "$S/out/p-gate.result.json" && echo same || echo differ)" "same"
check "durable record written before exit, grouped by project (cwd)" "$(jq -r '.project + ":" + (.counts.annotations|tostring)' "$FB" 2>/dev/null | tail -1)" "proj-alpha:2"
echo "   feedback dir: $(cd "$S/home/.plannotator" && find feedback history -type f | sort | tr '\n' ' ')"

echo "== P2: HTML artifact + crash: draft survives SIGKILL and is restored by the same command"
cd "$A"; PN_EXTRA_ENV="PLANNOTATOR_PORT=39202" "$D/pn" annotate "$S/artifacts/episode-lifecycle.html" --gate --json --result-file "$S/out/p-html.result.json" > "$S/out/p-html.stdout" 2> "$S/out/p-html.stderr" & HP=$!
wait_http http://localhost:39202/api/plan 40
check "HTML is rendered raw" "$(curl -s localhost:39202/api/plan | jq -r .renderAs)" "html"
curl -s -X POST -H 'content-type: application/json' --data '{"annotations":[{"id":"d1","type":"COMMENT","text":"draft comment before crash","originalText":"Life of an OpenCode episode"}]}' localhost:39202/api/draft > /dev/null
echo "   sessions listing: $("$D/pn" sessions 2>&1 | grep -c 'annotate') live annotate session(s)"
kill -9 $HP 2>/dev/null; sleep 1
check "agent-side stdout after SIGKILL is empty (the call just dies)" "$(wc -c < "$S/out/p-html.stdout" | tr -d ' ')" "0"
cd "$A"; PN_EXTRA_ENV="PLANNOTATOR_PORT=39202" "$D/pn" annotate "$S/artifacts/episode-lifecycle.html" --gate --json > "$S/out/p-html2.stdout" 2> /dev/null & HP2=$!
wait_http http://localhost:39202/api/plan 40
check "draft restored after re-running the same command" "$(curl -s localhost:39202/api/draft | jq -r '.annotations[0].text')" "draft comment before crash"
kill $HP2 2>/dev/null; wait $HP2 2>/dev/null

echo "== P3: the owner opens the review then closes the tab (client lease), no decision"
cd "$B"; PN_EXTRA_ENV="PLANNOTATOR_PORT=39204" "$D/pn" annotate "$S/artifacts/BRIEF.md" --gate --json > "$S/out/p-lease.stdout" 2> /dev/null & LP=$!
wait_http http://localhost:39204/api/plan 40
curl -s -N -m 3 localhost:39204/api/annotate/client-lease > /dev/null
t0=$(now); wait $LP; t1=$(now)
check "tab closed without a decision -> dismissed" "$(jq -r .decision "$S/out/p-lease.stdout")" "dismissed"
echo "   released $(secs "$t0" "$t1") s after the tab closed (30 s grace)"

echo "== I1: the Inbox. Two projects, three agent sessions, two attachments, one question with a recommended default"
cd "$A"; "$D/pn" inbox --background > "$S/out/p-inbox-start.txt" 2>&1; wait_http "http://localhost:$(inbox_port)/api/inbox/health" 30
python3 -I "$D/mcp_call.py" "$A" size | tee "$EV/inbox-mcp-size.json"
send() { python3 -I "$D/mcp_call.py" "$1" send_message "$2"; }
M1=$(send "$A" "$(jq -nc --arg s "$S" '{subject:"Factory brief: review before wave 1", agent_session:"spike5-alpha-1", idempotency_key:"spike5-a1", body:"Plan attached.\n\n:::question\nShould wave 1 start with the event log or the manifest?\n\nDefault if you do not answer: event log first.\n\n- [ ] Event log first - unblocks read models\n- [ ] Manifest first - unblocks routing generation\n\nRecommended: Event log first - unblocks read models\n:::\n", attachments:[($s+"/artifacts/BRIEF.md"), ($s+"/artifacts/episode-lifecycle.html")]}')")
TID=$(echo "$M1" | jq -r .thread_id); echo "$M1" | jq -c '{thread_id, project: .project.name, attachments: [.attachments[] | {name, kind}], question: .questions[0].prompt}'
send "$B" "$(jq -nc --arg s "$S" '{subject:"Beta: report ready", agent_session:"spike5-beta-1", idempotency_key:"spike5-b1", body:"Report attached.\n\n:::question\nShip tonight or wait for the owner review?\n\nDefault after 30 minutes without an answer: ship.\n\nHolds up: beta-release; changelog\n\n- [ ] Ship tonight - rollback verified\n- [ ] Wait - owner reviews first\n\nRecommended: Ship tonight - rollback verified\n:::\n", attachments:[($s+"/artifacts/BRIEF.md")]}')" > /dev/null
send "$A" '{"subject":"Alpha: second agent status","agent_session":"spike5-alpha-2","idempotency_key":"spike5-a2","body":"Lint pass done, nothing needed from you."}' > /dev/null
PORT=$(inbox_port); curl -s "localhost:$PORT/api/inbox/threads?archived=exclude" > "$EV/inbox-list.json"
check "projects grouped" "$(jq -r '[.projects[].name] | sort | join(",")' "$EV/inbox-list.json")" "proj-alpha,proj-beta"
check "attention sections" "$(jq -r '[.sections[] | select((.threads|length) > 0) | .label] | join("|")' "$EV/inbox-list.json")" "Holding up work|Waiting on you|New since you looked"
check "attachment kinds detected" "$(echo "$M1" | jq -r '[.attachments[].kind] | join(",")')" "markdown,html"
t0=$(now); W=$(python3 -I "$D/mcp_call.py" "$A" wait_for_reply "{\"thread_id\":\"$TID\",\"timeout_seconds\":3}"); t1=$(now)
check "nobody answers: wait_for_reply returns waiting + cursor (non-blocking)" "$(echo "$W" | jq -r .status)" "waiting"
echo "   returned after $(secs "$t0" "$t1") s including ~3.5 s stdio start-up; the agent proceeds with its default"
python3 -I "$D/inbox_human.py" "$(inbox_reg)" "$TID" "Go with the recommended option."
W=$(python3 -I "$D/mcp_call.py" "$A" wait_for_reply "{\"thread_id\":\"$TID\",\"timeout_seconds\":5}")
echo "$W" | jq -r '.reply.body' | sed 's/^/   | /'
check "reply delivered with the picked answer" "$(echo "$W" | jq -r '.status + ":" + (.reply.body | contains("Answer: Event log first (your recommendation)") | tostring)')" "replied:true"

echo "== I2: SIGKILL the Inbox, restart through the next agent call, read the thread back"
wc -l "$S"/home/.plannotator/inbox/projects/*/*.jsonl | sed "s#$S/home/##"
OLD=$(inbox_pid); OLDPORT=$(inbox_port); kill -9 "$OLD"; sleep 1
R=$(python3 -I "$D/mcp_call.py" "$A" read_thread "{\"thread_id\":\"$TID\"}")
check "the person's reply survived the crash" "$(echo "$R" | jq -r '.thread.messages | map(select(.author.kind=="person")) | length')" "1"
check "a new process serves the Inbox" "$([ "$(inbox_pid)" != "$OLD" ] && echo yes || echo no)" "yes"
echo "   port before/after restart: $OLDPORT / $(inbox_port) (sticky in this run; the docs do not promise it)"
jq -c '{v, seq, kind}' "$S"/home/.plannotator/inbox/projects/proj-alpha-*/messages.jsonl | head -2

echo "== I3: git worktrees fold into the repository's project"
rm -rf "$S/projects/wt-demo"; mkdir -p "$S/projects/wt-demo/repo"; cd "$S/projects/wt-demo/repo"
git init -q . && git -c user.name=spike -c user.email=spike commit -q --allow-empty -m init && git worktree add -q ../repo-wave-1 -b wave-1
p1=$(send "$S/projects/wt-demo/repo" '{"subject":"main","agent_session":"wt-main","body":"from the main checkout"}' | jq -r .project.id)
p2=$(send "$S/projects/wt-demo/repo-wave-1" '{"subject":"wave","agent_session":"wt-wave","body":"from a worktree"}' | jq -r .project.id)
check "worktree and main checkout share one project" "$([ "$p1" = "$p2" ] && echo same || echo different)" "same"

echo "== I4: the door. Host guard, framing, Streamable-HTTP MCP"
PORT=$(inbox_port)
check "foreign Host is refused" "$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: inbox.mini.example' "localhost:$PORT/api/inbox/threads")" "403"
check "framing denied (X-Frame-Options)" "$(curl -s -D - -o /dev/null "localhost:$PORT/" | tr -d '\r' | awk -F': ' 'tolower($1)=="x-frame-options"{print $2}')" "DENY"
H1='Content-Type: application/json'; H2='Accept: application/json, text/event-stream'
check "HTTP MCP initialize on loopback" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "$H1" -H "$H2" "localhost:$PORT/mcp" --data '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"spike5","version":"0"}}}')" "200"
check "HTTP MCP refuses a request that carries an Origin header" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "$H1" -H "$H2" -H 'Origin: https://other.example' "localhost:$PORT/mcp" --data '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')" "403"
BODY=$(jq -nc --arg id "$TID" --arg p "$A" '{jsonrpc:"2.0",id:7,method:"tools/call",params:{name:"read_thread",arguments:{thread_id:$id,project_path:$p,agent_session:"http-probe",limit:1}}}')
check "stateless tools/call over HTTP (no session, explicit project_path and agent_session)" "$(curl -s -X POST -H "$H1" -H "$H2" "localhost:$PORT/mcp" --data "$BODY" | grep -c 'Factory brief')" "1"
kill "$(inbox_pid)"; sleep 2
cd "$A"; PN_EXTRA_ENV="PLANNOTATOR_ALLOWED_HOSTS=inbox.mini.example" "$D/pn" inbox --background > /dev/null 2>&1; wait_http "http://localhost:$(inbox_port)/api/inbox/health" 30; PORT=$(inbox_port)
check "with PLANNOTATOR_ALLOWED_HOSTS the door host is accepted" "$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: inbox.mini.example' "localhost:$PORT/api/inbox/threads")" "200"
check "other hosts stay refused" "$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: other.example' "localhost:$PORT/api/inbox/threads")" "403"
check "the agent door (/mcp) refuses the proxied host" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Host: inbox.mini.example' -H "$H1" -H "$H2" "localhost:$PORT/mcp" --data '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')" "403"

echo "== T: tailnet identity facts that decide the vendor phone path (read-only)"
if command -v tailscale > /dev/null; then
  tailscale status --json 2> /dev/null | jq -r '"   this host tagged: \((.Self.Tags // []) | length > 0)", "   iOS peers: \([.Peer[] | select(.OS == "iOS")] | length), tagged: \([.Peer[] | select(.OS == "iOS" and ((.Tags // []) | length > 0))] | length)"'
fi
echo; echo "RESULT: $pass passed, $fail failed"
