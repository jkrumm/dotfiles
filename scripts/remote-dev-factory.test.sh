#!/usr/bin/env bash
# remote-dev-factory.test — which path `rd wave|fan|say|close` takes when the factory answers, holds, fails or
# is absent (docs/remote-dev.md §rd and the factory). hc and `factory` are stubs that record every call:
#   factory  health  rc from $STATE/health-rc (default 0) · "health-hang" makes it sleep
#            spawn create  rc from $STATE/create-rc, recorded
#            spawn get <key>  line n of $STATE/get-<key> (or get-default); the last line repeats; rc $STATE/get-rc
#            session get / session note  reply + rc from $STATE/session-reply · session-rc, $STATE/note-rc
#            role get <r>  a valid role answer
#   hc       remote-dev-fake-hc.sh: the roster is $STATE/terminals.json, every terminal.run lands in $STATE/runs.jsonl
#   herdr    only for the classic fallback (TODO(Wave 7): drop classic): the roster is $STATE/agents.json, calls in herdr-calls
# No real `factory` may answer: PATH is scrubbed of any and the scratch ~/.local/bin holds the stub.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/rd-factory-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
fails=0
ok()  { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fails=$((fails + 1)); }
has()   { grep -qF -- "$3" <<<"$2" && ok "$1" || bad "$1 — '$3' not in: $2"; }
lacks() { grep -qF -- "$3" <<<"$2" && bad "$1 — '$3' unexpectedly in: $2" || ok "$1"; }
is()    { [ "$2" = "$3" ] && ok "$1" || bad "$1 — expected '$3', got '$2'"; }
g()     { git -c user.email=t@t -c user.name=t -c commit.gpgsign=false "$@"; }

S="$TMP/home/SourceRoot"
mkdir -p "$TMP/bin" "$TMP/state" "$S/dotfiles/scripts" "$S/myrepo/.git" "$TMP/xdg/secrets" "$TMP/home/.local/bin"
echo cache >"$TMP/xdg/secrets/backend"
printf '#!/usr/bin/env python3\n' >"$S/dotfiles/scripts/wave-gate.py"
printf '#!/usr/bin/env bash\necho "%s/myrepo-wt"\necho origin/master\necho abc1234\n' "$S" >"$S/dotfiles/scripts/fan-worktree.sh"
printf '#!/usr/bin/env bash\nexit 0\n' >"$S/dotfiles/scripts/fan-list.sh"
printf '#!/usr/bin/env bash\ntouch "$STATE/picked"\necho "unset CLAUDE_CONFIG_DIR"\n' >"$TMP/home/.local/bin/claude-account"

# A clean, pushed checkout for `close`.
g init -q --bare -b master "$TMP/origin.git"
g clone -q "$TMP/origin.git" "$TMP/co" 2>/dev/null
echo a >"$TMP/co/f"; g -C "$TMP/co" add f; g -C "$TMP/co" commit -qm one; g -C "$TMP/co" push -q -u origin master 2>/dev/null

cp "$HERE/remote-dev-fake-hc.sh" "$TMP/home/.local/bin/hc"
printf '#!/usr/bin/env bash\necho "state = running"\n' >"$TMP/bin/launchctl"
printf '#!/usr/bin/env bash\nexit 0\n' >"$S/dotfiles/scripts/claude-pretrust.sh"
cat >"$TMP/bin/herdr" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$STATE/herdr-calls"
case "$1 $2" in
  "agent list") cat "$STATE/agents.json" 2>/dev/null || echo '{"result":{"agents":[]}}' ;;
  "tab get") echo "{\"result\":{\"tab\":{\"label\":\"$(cat "$STATE/tab-label" 2>/dev/null)\"}}}" ;;
  "tab close") echo '{"result":{}}' ;;
  *) echo '{}' ;;
esac
STUB
cat >"$TMP/home/.local/bin/factory" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = health ]; then
  echo "health" >>"$STATE/factory-calls"
  [ -f "$STATE/health-dies-after-create" ] && grep -q '^spawn create' "$STATE/factory-calls" && exit 1
  [ -f "$STATE/health-hang" ] && sleep 30
  exit "$(cat "$STATE/health-rc" 2>/dev/null || echo 0)"
fi
echo "$*" >>"$STATE/factory-calls"
[ "$1 $2" = "spawn create" ] && echo "parent-env=${FACTORY_SESSION-unset}" >>"$STATE/factory-calls"
case "$1 $2" in
  "role get") printf '{"role":"%s","tier":"sonnet","effort":"high"}\n' "$3" ;;
  "spawn create") cat "$STATE/create-reply" 2>/dev/null || echo '{"error":{"kind":"internal","message":"boom"}}'; exit "$(cat "$STATE/create-rc" 2>/dev/null || echo 0)" ;;
  "spawn get")
    [ -f "$STATE/get-rc" ] && exit "$(cat "$STATE/get-rc")"
    f="$STATE/get-$3"; [ -f "$f" ] || f="$STATE/get-default"
    [ -f "$f" ] || { echo '{"error":{"kind":"not_found","message":"no such spawn"}}'; exit 1; }
    n=$(( $(cat "$f.n" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$f.n"
    total=$(wc -l <"$f"); [ "$n" -gt "$total" ] && n=$total
    sed -n "${n}p" "$f" ;;
  "session get") cat "$STATE/session-reply" 2>/dev/null; exit "$(cat "$STATE/session-rc" 2>/dev/null || echo 0)" ;;
  "session note") cat "$STATE/note-reply" 2>/dev/null || echo noted; exit "$(cat "$STATE/note-rc" 2>/dev/null || echo 0)" ;;
esac
STUB
chmod +x "$TMP/bin/herdr" "$TMP/bin/launchctl" "$TMP/home/.local/bin/hc" "$TMP/home/.local/bin/factory" "$TMP/home/.local/bin/claude-account" "$S/dotfiles/scripts/"*.sh
clean_path=""; IFS=: read -ra dirs <<<"$PATH"
for d in "${dirs[@]}"; do [ -x "$d/factory" ] || clean_path+="${clean_path:+:}$d"; done
export PATH="$TMP/bin:$clean_path" STATE="$TMP/state" HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/xdg" \
  RD_DELIVER_WAIT_S=0 RD_POLL_S=0 RD_FACTORY_POLL_S=0 RD_SAY_SETTLE=0 RD_SAY_WAIT_S=3
unset RD_DRY_RUN RD_NO_FACTORY FACTORY_SESSION HC_TERMINAL_ID HC_SESSION RD_WAVE_MODEL RD_WAVE_EFFORT
export CLAUDE_EFFORT_TABLE="$HERE/../config/claude-effort.json"
printf 'Branch: feat/one\n\nDo one.\n' >"$TMP/brief1.md"
printf 'Branch: feat/two\n\nDo two.\n' >"$TMP/brief2.md"

reset() { rm -f "$STATE"/* ; : >"$STATE/calls.log"; : >"$STATE/factory-calls"; echo '[]' >"$STATE/terminals.json"; echo '{"result":{"agents":[]}}' >"$STATE/agents.json"; }
rd() { out=$(timeout 90 bash "$HERE/remote-dev.sh" "$@" 2>&1 </dev/null); rc=$?
       hcalls=$(cat "$STATE/calls.log"); fcalls=$(cat "$STATE/factory-calls"); hruns=$(cat "$STATE/runs.jsonl" 2>/dev/null)
       hclassic=$(cat "$STATE/herdr-calls" 2>/dev/null); }
reply() { printf '%s\n' "$2" >"$STATE/get-$1"; }   # reply <key|default> <line…>
hc_ran() { [ -s "$STATE/runs.jsonl" ]; }
no_hc_spawn() { hc_ran && bad "$1 — hc started a terminal: $hruns" || ok "$1"; }
hc_spawned() { hc_ran && ok "$1" || bad "$1 — no terminal.run recorded"; }

# --- wave ---------------------------------------------------------------------------------------------
echo "wave: the factory answers and starts it"
reset; reply default '{"key":"k","status":"started","hold":null,"account":"max-b","resumeAt":null,"session":"w1:7","pane":"w1:7","tab":"w1:t7","workspace":"w1","error":null}'
rd wave myrepo "adhoc task"
is "exit 0" "$rc" "0"
has "prints today's line: agent" "$out" "claude 'myrepo-w1'"
has "prints the space" "$out" "space $S/myrepo"
has "prints the pane" "$out" "pane w1:7"
has "prints the account" "$out" "[account max-b]"
has "creates the spawn keyed by the agent name, in the repo" "$fcalls" "spawn create myrepo-w1 --repo $S/myrepo --prompt adhoc task --role wave --format json"
no_hc_spawn "no terminal is made by rd"
[ ! -e "$STATE/picked" ] && ok "rd does not pick an account (the factory does)" || bad "rd picked an account"
rd wave myrepo --role mechanical "adhoc task"
has "--role rides to the spawn" "$fcalls" "--role mechanical"

echo "wave: claimed first, started later (bounded wait)"
reset; printf '%s\n' '{"status":"starting","pane":null}' '{"status":"started","pane":"w1:2","tab":"w1:t2","workspace":"w1"}' >"$STATE/get-default"
rd wave myrepo "adhoc task"
has "waited for started" "$out" "pane w1:2"
is "polled twice" "$(grep -c '^spawn get' <<<"$fcalls")" "2"

echo "wave: held or queued"
reset; reply default '{"status":"queued","hold":"pace","pane":null,"error":null}'
rd wave myrepo "adhoc task"
is "exit 0" "$rc" "0"
has "queued: <hold>" "$out" "queued: pace"
no_hc_spawn "nothing started by rd"
reset; reply default '{"status":"waiting","hold":null,"resumeAt":"2026-10-31T01:00:00Z"}'
rd wave myrepo "adhoc task"
is "waiting: exit 0" "$rc" "0"
has "waiting: no capacity until resumeAt" "$out" "queued: no capacity until 2026-10-31T01:00:00Z"
no_hc_spawn "waiting: nothing started by rd"
reset; reply default '{"status":"waiting","hold":null,"resumeAt":null}'
rd wave myrepo "adhoc task"
has "waiting without resumeAt" "$out" "queued: no capacity"
reset; reply default '{"status":"queued","hold":null}'
RD_FACTORY_WAIT_S=0 rd wave myrepo "adhoc task"
is "plain queued past the wait: exit 0" "$rc" "0"
has "plain queued: not claimed yet" "$out" "queued: not claimed yet"
reset; printf '%s\n' '{"status":"queued","hold":null}' '{"status":"started","pane":"w1:5"}' >"$STATE/get-default"
rd wave myrepo "adhoc task"
has "plain queued is waited on until started" "$out" "pane w1:5"

echo "wave: failed"
reset; reply default '{"status":"failed","error":"folder trust refused"}'
rd wave myrepo "adhoc task"
[ "$rc" -ne 0 ] && ok "non-zero exit" || bad "exit 0 on a failed spawn"
has "names the reason" "$out" "folder trust refused"
no_hc_spawn "no hc fallback after a failed spawn"
reset; reply default '{"status":"failed","error":{"kind":"start","message":"hc refused the tab"}}'
rd wave myrepo "adhoc task"
has "an error object: its message" "$out" "hc refused the tab"

echo "wave: an answered create never falls back, whatever the status is"
for body in '{}' '{"status":""}' '{"status":null}' '{"status":"melting"}' '{"state":"started","pane":"w1:1"}'; do
  reset; reply default "$body"
  RD_FACTORY_WAIT_S=0 rd wave myrepo "adhoc task"
  [ "$rc" -ne 0 ] && ok "get says $body: error" || bad "get says $body: exit 0 ($out)"
  no_hc_spawn "get says $body: no hc terminal"
done

echo "wave: claimed and never started within the wait"
reset; reply default '{"status":"starting"}'
RD_FACTORY_WAIT_S=0 rd wave myrepo "adhoc task"
is "exit 0 (the factory still owns it)" "$rc" "0"
has "says not started yet" "$out" "claimed by the factory, not started yet"

echo "wave: the factory goes silent after create"
reset; echo 1 >"$STATE/get-rc"
RD_FACTORY_WAIT_S=0 rd wave myrepo "adhoc task"
[ "$rc" -ne 0 ] && ok "non-zero exit" || bad "exit 0"
has "says the factory gave no status" "$out" "gave no status for spawn 'myrepo-w1'"
no_hc_spawn "no second spawn through hc"

echo "wave: create fails -> hc directly"
reset; echo 1 >"$STATE/create-rc"
rd wave myrepo "adhoc task"
is "exit 0" "$rc" "0"
has "one stderr line says so" "$out" "factory spawn create failed"
hc_spawned "hc made the terminal"
[ -e "$STATE/picked" ] && ok "the account is picked on hc directly" || bad "no account pick on fallback"
has "FACTORY_ROLE in the terminal's env" "$hruns" '"FACTORY_ROLE":"wave"'
has "FACTORY_SESSION in the terminal's env" "$hruns" '"FACTORY_SESSION":"myrepo-w1"'

echo "wave: create times out but the factory recorded it"
reset; echo 124 >"$STATE/create-rc"; : >"$STATE/create-reply"; reply default '{"status":"started","pane":"w1:3"}'
rd wave myrepo "adhoc task"
has "carries on to the started spawn" "$out" "pane w1:3"
no_hc_spawn "no hc fallback"
reset; echo 124 >"$STATE/create-rc"; : >"$STATE/create-reply"
rd wave myrepo "adhoc task"
[ "$rc" -ne 0 ] && ok "timeout, spawn not visible yet: uncertain, error" || bad "exit 0: $out"
no_hc_spawn "no hc terminal while the create may still be in flight"
reset; echo 255 >"$STATE/create-rc"; : >"$STATE/create-reply"
rd wave myrepo "adhoc task"
[ "$rc" -ne 0 ] && ok "dropped hop, spawn not visible yet: uncertain, error" || bad "exit 0: $out"
no_hc_spawn "no hc terminal while the create may still be in flight"
reset; echo 255 >"$STATE/create-rc"; : >"$STATE/create-reply"; reply default '{"status":"starting"}'
RD_FACTORY_WAIT_S=0 rd wave myrepo "adhoc task"
has "a dropped hop after the spawn was recorded is followed" "$out" "claimed by the factory"
no_hc_spawn "no second pane under the same name"
reset; echo 255 >"$STATE/create-rc"; : >"$STATE/create-reply"; echo 1 >"$STATE/get-rc"
rd wave myrepo "adhoc task"
[ "$rc" -ne 0 ] && ok "create failed and get will not say, factory still healthy: error" || bad "exit 0: $out"
has "says it will not start a second pane" "$out" "not starting a second pane under that name"
no_hc_spawn "no hc terminal"
reset; echo 255 >"$STATE/create-rc"; : >"$STATE/create-reply"; echo 1 >"$STATE/get-rc"; touch "$STATE/health-dies-after-create"
rd wave myrepo "adhoc task"
[ "$rc" -ne 0 ] && ok "create failed and the factory is unreachable now: error, not a guess" || bad "exit 0: $out"
no_hc_spawn "no hc terminal (the spawn may be recorded)"
reset; echo 255 >"$STATE/create-rc"; : >"$STATE/create-reply"; echo '{"error":{"kind":"internal","message":"config not found"}}' >"$STATE/get-default"
rd wave myrepo "adhoc task"
[ "$rc" -ne 0 ] && ok "no answer to create and an unrelated error from get: error" || bad "exit 0: $out"
no_hc_spawn "no hc terminal"

echo "wave: not answering -> today's path, FACTORY_ROLE added"
reset; echo 1 >"$STATE/health-rc"
rd wave myrepo "adhoc task"
is "exit 0" "$rc" "0"
hc_spawned "hc made the terminal"
lacks "no spawn create attempted" "$fcalls" "spawn create"
has "FACTORY_ROLE=wave" "$hruns" '"FACTORY_ROLE":"wave"'
rd wave myrepo --role mechanical "adhoc task"
has "FACTORY_ROLE follows --role" "$hruns" '"FACTORY_ROLE":"mechanical"'
reset; RD_NO_FACTORY=1 rd wave myrepo "adhoc task"
lacks "RD_NO_FACTORY=1 skips the probe" "$fcalls" "health"
hc_spawned "RD_NO_FACTORY=1: hc path"
if command -v timeout >/dev/null || command -v gtimeout >/dev/null; then
  reset; touch "$STATE/health-hang"; t0=$SECONDS
  rd wave myrepo "adhoc task"
  hc_spawned "a hanging health probe: hc path"
  (( SECONDS - t0 < 20 )) && ok "gave up at the probe limit, not after the stub's 30 s" || bad "took $((SECONDS - t0)) s"
fi
reset
RD_TIMEOUT_CMDS="no-such-timeout-binary" rd wave myrepo "adhoc task"
is "no timeout binary on the host: exit 0" "$rc" "0"
lacks "no unbounded factory call is made" "$fcalls" "health"
hc_spawned "no timeout binary: hc directly"
mv "$TMP/home/.local/bin/factory" "$TMP/factory.away"
reset
rd wave myrepo "adhoc task"
is "factory not installed: exit 0" "$rc" "0"
hc_spawned "factory not installed: hc path"
mv "$TMP/factory.away" "$TMP/home/.local/bin/factory"

echo "wave: a chain wave's successor has no parent, an orchestrated one has the caller"
reset; reply default '{"key":"k","status":"started","hold":null,"account":"max-b","resumeAt":null,"session":"w1:7","pane":"w1:7","tab":"w1:t7","workspace":"w1","error":null}'
FACTORY_SESSION=lead-1 rd wave myrepo "adhoc task"
has "chain: created without FACTORY_SESSION" "$fcalls" "parent-env=unset"
reset; reply default '{"key":"k","status":"started","hold":null,"account":"max-b","resumeAt":null,"session":"w1:7","pane":"w1:7","tab":"w1:t7","workspace":"w1","error":null}'
FACTORY_SESSION=lead-1 RD_ORCHESTRATED=1 rd wave myrepo "adhoc task"
has "orchestrated: the caller is the parent" "$fcalls" "parent-env=lead-1"

# --- fan ----------------------------------------------------------------------------------------------
echo "fan: the factory answers"
reset; reply default '{"status":"started","pane":"w1:9","tab":"w1:t9","workspace":"w1","account":"max-a"}'
rd fan myrepo "$TMP/brief1.md"
is "exit 0" "$rc" "0"
has "key = <repo>-<branch leaf>" "$fcalls" "spawn create myrepo-one --repo $S/myrepo-wt"
has "--space is the main checkout" "$fcalls" "--space $S/myrepo"
has "role worker" "$fcalls" "--role worker"
has "the prompt carries the fetched base" "$fcalls" "Base: origin/master @ abc1234"
has "prints the line" "$out" "fan feat/one started: claude 'myrepo-one' via the factory, space $S/myrepo, pane w1:9"
no_hc_spawn "no hc terminal"
[ ! -e "$STATE/picked" ] && ok "no account pick" || bad "rd picked an account"

echo "fan: one queued, one failed, the rest still go"
reset
reply myrepo-one '{"status":"queued","hold":"paced"}'
reply myrepo-two '{"status":"failed","error":"boom"}'
rd fan myrepo "$TMP/brief1.md" "$TMP/brief2.md"
[ "$rc" -ne 0 ] && ok "non-zero exit when one failed" || bad "exit 0 with a failed spawn"
has "queued line" "$out" "queued: paced"
has "failed reason" "$out" "boom"
is "both spawns were created" "$(grep -c '^spawn create' <<<"$fcalls")" "2"
reset
reply myrepo-one '{"status":"queued","hold":"paced"}'
rd fan myrepo "$TMP/brief1.md"
is "queued alone: exit 0" "$rc" "0"

echo "fan: create fails -> hc for that brief; every brief still asks the factory about its own key"
reset; echo 1 >"$STATE/create-rc"
rd fan myrepo "$TMP/brief1.md" "$TMP/brief2.md"
is "each brief tried the factory" "$(grep -c '^spawn create' <<<"$fcalls")" "2"
is "two terminals started on hc" "$(grep -c . <<<"$hruns")" "2"
has "FACTORY_ROLE=worker in the terminal" "$hruns" '"FACTORY_ROLE":"worker"'

echo "fan: not answering -> today's path"
reset; echo 1 >"$STATE/health-rc"
rd fan myrepo "$TMP/brief1.md"
hc_spawned "hc made the terminal"
lacks "no spawn create" "$fcalls" "spawn create"
has "FACTORY_ROLE=worker" "$hruns" '"FACTORY_ROLE":"worker"'
rd fan myrepo --role mechanical "$TMP/brief1.md"
has "FACTORY_ROLE follows --role" "$hruns" '"FACTORY_ROLE":"mechanical"'

echo "work: FACTORY_ROLE only when --role is given"
reset; echo 1 >"$STATE/health-rc"
rd work myrepo
lacks "no role, no FACTORY_ROLE" "$hruns" "FACTORY_ROLE"
rd work myrepo --role lead
has "--role lead" "$hruns" '"FACTORY_ROLE":"lead"'

# --- say ----------------------------------------------------------------------------------------------
# The roster of hc: one agent `worker` (t5) in the clean checkout, labelled with its factory key. AGENT_STATUS sets its status.
agents_json() {
  echo "[{\"address\":\"t5\",\"name\":\"worker\",\"cwd\":\"$TMP/co\",\"argv\":[\"claude\"],\"status\":{\"app\":\"claude-code\",\"state\":\"${AGENT_STATUS:-idle}\"},\"labels\":{\"factory.key\":\"worker\"}}]" >"$STATE/terminals.json"
}
echo "say: the factory holds the note"
reset; agents_json
rd say worker "go on"
is "exit 0" "$rc" "0"
has "noted" "$out" "noted: the factory holds it while worker works"
has "session note <agent> <text>" "$fcalls" "session note worker go on"
lacks "nothing typed through hc" "$hcalls" "send "
echo "say: the note fails -> hc send"
reset; agents_json; echo 1 >"$STATE/note-rc"; echo '{"error":{"kind":"not_found","message":"no such session: worker"}}' >"$STATE/note-reply"
rd say worker "go on"
has "one stderr line says so" "$out" "the factory has no session 'worker'"
has "typed through hc" "$hcalls" "send -- t5 go on"
echo "say: any other note failure may have recorded it -> never re-sent"
reset; agents_json; echo 255 >"$STATE/note-rc"; echo "ssh: connection reset" >"$STATE/note-reply"
rd say worker "go on"
[ "$rc" -ne 0 ] && ok "non-zero exit" || bad "exit 0"
has "says NOT delivered" "$out" "NOT delivered"
lacks "no hc re-send" "$hcalls" "send "
reset; agents_json; echo 1 >"$STATE/note-rc"; echo '{"error":{"kind":"internal","message":"session store not found"}}' >"$STATE/note-reply"
rd say worker "go on"
[ "$rc" -ne 0 ] && ok "an unrelated 'not found' may have recorded it: NOT delivered" || bad "exit 0"
lacks "no hc re-send" "$hcalls" "send "
echo "say: the note times out -> never re-sent"
reset; agents_json; echo 124 >"$STATE/note-rc"
rd say worker "go on"
[ "$rc" -ne 0 ] && ok "non-zero exit" || bad "exit 0"
has "says NOT delivered" "$out" "NOT delivered"
lacks "no hc re-send" "$hcalls" "send "
echo "say: not answering -> hc send"
reset; agents_json; echo 1 >"$STATE/health-rc"
rd say worker "go on"
has "typed through hc" "$hcalls" "send -- t5 go on"
lacks "no note attempted" "$fcalls" "session note"
echo "say: an agent without a name is no factory session"
reset; echo "[{\"address\":\"t5\",\"name\":null,\"cwd\":\"/x\",\"argv\":[\"claude\"],\"status\":{\"state\":\"idle\"},\"labels\":{}}]" >"$STATE/terminals.json"
rd say t5 "go on"
lacks "no note attempted" "$fcalls" "session note"
has "typed through hc" "$hcalls" "send -- t5 go on"
echo "say: a classic herdr agent (hc does not know it) still takes a note"
reset; echo '{"result":{"agents":[{"name":"classic","pane_id":"p-1","cwd":"x","agent_status":"idle"}]}}' >"$STATE/agents.json"
rd say classic "go on"
has "noted" "$out" "noted: the factory holds it while classic works"

# --- close --------------------------------------------------------------------------------------------
closed() { grep -q '^kill ' <<<"$hcalls" && grep -q '^rm ' <<<"$hcalls"; }
echo "close: hc kill + hc rm"
reset; agents_json
rd close worker
is "exit 0" "$rc" "0"
closed && ok "killed and removed" || bad "not closed: $out / $hcalls"
has "kill by address" "$hcalls" "kill -- t5"
has "rm by address" "$hcalls" "rm -- t5"
has "says what it closed" "$out" "closed worker (t5)"
echo "close: today's refusals stay"
reset; AGENT_STATUS=working agents_json
rd close worker
[ "$rc" -ne 0 ] && ! closed && ok "working: refused" || bad "closed a working agent: $out"
reset; AGENT_STATUS=blocked agents_json
rd close worker
[ "$rc" -ne 0 ] && ! closed && ok "blocked: refused" || bad "closed a blocked agent: $out"
reset; agents_json; echo dirty >"$TMP/co/dirty"
rd close worker
[ "$rc" -ne 0 ] && ! closed && ok "dirty checkout: refused" || bad "closed a dirty checkout: $out"
rm -f "$TMP/co/dirty"
echo b >"$TMP/co/f"; g -C "$TMP/co" commit -qam two
reset; agents_json
rd close worker
[ "$rc" -ne 0 ] && ! closed && ok "unpushed commit: refused" || bad "closed with unpushed commits: $out"
g -C "$TMP/co" push -q origin master 2>/dev/null
reset; echo "[{\"address\":\"t5\",\"name\":\"mine\",\"cwd\":\"$TMP/co\",\"argv\":[\"/bin/zsh\",\"-l\"],\"status\":{\"state\":\"idle\"},\"labels\":{}}]" >"$STATE/terminals.json"
rd close mine
[ "$rc" -ne 0 ] && ! closed && ok "a terminal running a shell, not claude: refused (not started by rd or the factory)" || bad "closed a hand-run terminal: $out"
has "says so" "$out" "not started by rd or the factory"
reset; agents_json; touch "$STATE/rm_fail"
rd close worker
[ "$rc" -ne 0 ] && ok "hc rm failing is an error" || bad "reported success: $out"

echo "close: a classic herdr agent keeps the tab-name rule (TODO(Wave 7): drop classic)"
classic_agent() { echo "{\"result\":{\"agents\":[{\"name\":\"classic\",\"pane_id\":\"p-1\",\"tab_id\":\"t9\",\"cwd\":\"$TMP/co\",\"agent_status\":\"idle\"}]}}" >"$STATE/agents.json"; }
SESSION='{"id":"classic","state":"idle","wait":null,"turn":1,"spawn":null,"pane":"p-1","tab":"t9","role":"wave","account":"iu","parent":null}'
cclosed() { grep -q '^tab close' <<<"$hclassic"; }
reset; classic_agent; echo "1" >"$STATE/tab-label"; echo 1 >"$STATE/health-rc"
rd close classic
[ "$rc" -ne 0 ] && ! cclosed && ok "tab '1': refused as before" || bad "closed tab '1': $out"
has "says why" "$out" "not a 'wave <n>' tab"
echo "wave 1" >"$STATE/tab-label"
rd close classic
cclosed && ok "wave tab: closed" || bad "wave 1 not closed: $out"
lacks "hc was not asked to kill anything" "$hcalls" "kill "
reset; classic_agent; echo "fan feat-x" >"$STATE/tab-label"; echo "$SESSION" >"$STATE/session-reply"
rd close classic
cclosed && ok "the factory owns the session: its tab closes whatever its name" || bad "not closed: $out"
has "asked the factory for the session" "$fcalls" "session get classic --format json"

echo "close: only a known idle/done status counts as finished"
for st in starting unknown; do
  reset; AGENT_STATUS=$st agents_json
  rd close worker
  [ "$rc" -ne 0 ] && ! closed && ok "status '$st': refused" || bad "closed a '$st' agent: $out"
done
reset; echo "[{\"address\":\"t5\",\"name\":\"worker\",\"cwd\":\"$TMP/co\",\"argv\":[\"claude\"],\"status\":null,\"labels\":{}}]" >"$STATE/terminals.json"
rd close worker
[ "$rc" -ne 0 ] && ! closed && ok "no status yet: refused" || bad "closed an agent that has not reported: $out"
reset; AGENT_STATUS="done" agents_json
rd close worker
closed && ok "status done: closes" || bad "done not closed: $out"

echo "close: a cwd with a space and a quote reaches git intact"
g clone -q "$TMP/origin.git" "$TMP/co it's" 2>/dev/null
reset; echo "[{\"address\":\"t5\",\"name\":\"worker\",\"cwd\":\"$TMP/co it's\",\"argv\":[\"claude\"],\"status\":{\"state\":\"idle\"},\"labels\":{\"factory.key\":\"k\"}}]" >"$STATE/terminals.json"
rd close worker
closed && ok "closed" || bad "not closed: $out"

echo "close: a linked machine's terminal is not ours"
reset; echo "[{\"address\":\"mini/t5\",\"name\":\"worker\",\"cwd\":\"$TMP/co\",\"argv\":[\"claude\"],\"status\":{\"state\":\"idle\"},\"labels\":{}}]" >"$STATE/terminals.json"
rd close worker
[ "$rc" -ne 0 ] && ! closed && ok "refused" || bad "closed a linked machine's terminal: $out"

echo "fan --clean: every agent in the worktree is judged, and the worktree stays unless all of them are gone"
cp "$S/dotfiles/scripts/fan-list.sh" "$TMP/fan-list.orig"
printf '#!/usr/bin/env bash\nprintf "remove\\t%s/myrepo-wt\\tfeat/one\\t\\n" "%s"\n' "$S" "$S" >"$S/dotfiles/scripts/fan-list.sh"
two() { # <status of the second agent>
  echo "[{\"address\":\"t5\",\"name\":\"a\",\"cwd\":\"$S/myrepo-wt\",\"argv\":[\"claude\"],\"status\":{\"state\":\"idle\"},\"labels\":{\"factory.key\":\"k\"}},{\"address\":\"t6\",\"name\":\"b\",\"cwd\":\"$S/myrepo-wt\",\"argv\":[\"claude\"],\"status\":{\"state\":\"$1\"},\"labels\":{\"factory.key\":\"k\"}}]" >"$STATE/terminals.json"
}
reset; two working
rd fan --clean myrepo
has "the second agent (not the first) is the reason to keep" "$out" "t6 working"
lacks "nothing was ended" "$hcalls" "kill "
reset; two starting
rd fan --clean myrepo
has "a starting agent keeps it" "$out" "t6 starting"
reset; echo "[{\"address\":\"t5\",\"name\":\"a\",\"cwd\":\"$S/myrepo-wt\",\"argv\":[\"claude\"],\"status\":null,\"labels\":{\"factory.key\":\"k\"}}]" >"$STATE/terminals.json"
rd fan --clean myrepo
has "an agent without a status keeps it" "$out" "t5 unknown"
reset; two idle
rd fan --clean myrepo
has "both idle: t5 ended" "$hcalls" "rm -- t5"
has "both idle: t6 ended" "$hcalls" "rm -- t6"
reset; two idle; touch "$STATE/rm_fail"
rd fan --clean myrepo
has "an rm that fails keeps the worktree" "$out" "could not end every terminal"
lacks "and does not report it removed" "$out" "removed feat/one"
cp "$TMP/fan-list.orig" "$S/dotfiles/scripts/fan-list.sh"

echo "fan from an owner's own terminal on the dev host: hc-direct, hidden children of the caller"
reset; reply default '{"status":"started","pane":"w1:9","tab":"w1:t9","workspace":"w1","account":"max-a"}'
HC_TERMINAL_ID=t4 rd fan myrepo "$TMP/brief1.md"
lacks "the factory is not asked to create it" "$fcalls" "spawn create"
is "the worker is a child of the caller" "$(jq -r .parent <<<"$(sed -n 1p "$STATE/runs.jsonl")")" "t4"
reset; reply default '{"status":"started","pane":"w1:9","tab":"w1:t9","workspace":"w1","account":"max-a"}'
HC_TERMINAL_ID=t4 FACTORY_SESSION=lead-1 rd fan myrepo "$TMP/brief1.md"
has "a factory session fans through the factory" "$fcalls" "spawn create"

echo "say: the state is checked before the factory note"
reset; AGENT_STATUS=blocked agents_json
rd say worker "go on"
[ "$rc" -ne 0 ] && ok "blocked: refused" || bad "noted into a blocked agent: $out"
lacks "no note recorded" "$fcalls" "session note"
reset; echo "[{\"address\":\"t5\",\"name\":\"worker\",\"cwd\":\"/x\",\"argv\":[\"claude\"],\"status\":null,\"labels\":{\"factory.key\":\"worker\"}}]" >"$STATE/terminals.json"
rd say worker "go on"
[ "$rc" -ne 0 ] && ok "not reported yet: refused" || bad "noted into an agent that has not reported: $out"
has "says why" "$out" "not at a prompt yet"
lacks "no note recorded" "$fcalls" "session note"

echo "close and fan --clean know an agent by its foreground program"
resumed() { echo "[{\"address\":\"t5\",\"name\":\"worker\",\"cwd\":\"$1\",\"argv\":[\"/bin/zsh\",\"-l\"],\"foreground\":{\"argv\":[\"claude\",\"--resume\",\"x\"]},\"status\":{\"state\":\"idle\"},\"labels\":{\"factory.key\":\"k\"}}]" >"$STATE/terminals.json"; }
reset; resumed "$TMP/co"
rd close worker
closed && ok "a session resumed inside a kept login shell closes" || bad "not closed: $out"
reset; echo "[{\"address\":\"t5\",\"name\":\"mine\",\"cwd\":\"$TMP/co\",\"argv\":[\"/bin/zsh\",\"-l\"],\"foreground\":{\"argv\":[\"vim\"]},\"status\":{\"state\":\"idle\"},\"labels\":{\"factory.key\":\"k\"}}]" >"$STATE/terminals.json"
rd close mine
[ "$rc" -ne 0 ] && ! closed && ok "a shell running vim: refused" || bad "closed a non-claude terminal: $out"
printf '#!/usr/bin/env bash\nprintf "remove\\t%s/myrepo-wt\\tfeat/one\\t\\n" "%s"\n' "$S" "$S" >"$S/dotfiles/scripts/fan-list.sh"
reset; resumed "$S/myrepo-wt"
rd fan --clean myrepo
has "fan --clean ends the resumed session's terminal" "$hcalls" "rm -- t5"
reset; echo "[{\"address\":\"t5\",\"name\":\"a\",\"cwd\":\"$S/myrepo-wt\",\"argv\":[\"claude\"],\"status\":{\"state\":\"idle\"},\"labels\":{\"factory.key\":\"k\"}},{\"address\":\"t6\",\"name\":\"sh\",\"cwd\":\"$S/myrepo-wt\",\"argv\":[\"/bin/zsh\",\"-l\"],\"status\":null,\"labels\":{\"factory.key\":\"k\"}}]" >"$STATE/terminals.json"
rd fan --clean myrepo
has "a plain shell in the worktree keeps it" "$out" "t6 runs zsh, not claude"
lacks "and nothing was ended" "$hcalls" "kill "
cp "$TMP/fan-list.orig" "$S/dotfiles/scripts/fan-list.sh"

echo "orchestrated wave from an owner's own terminal: hc-direct tab-child"
reset; reply default '{"status":"started","pane":"w1:9","tab":"w1:t9","workspace":"w1","account":"max-a"}'
HC_TERMINAL_ID=t4 RD_ORCHESTRATED=1 rd wave myrepo "adhoc task"
lacks "not through the factory" "$fcalls" "spawn create"
is "a child of the caller" "$(jq -r .parent <<<"$(sed -n 1p "$STATE/runs.jsonl")")" "t4"
is "outlives it" "$(jq -r .outlive_parent <<<"$(sed -n 1p "$STATE/runs.jsonl")")" "true"
is "still a labelled tab" "$(jq -r '.labels | has("herdr.tab")' <<<"$(sed -n 1p "$STATE/runs.jsonl")")" "true"
reset; reply default '{"status":"started","pane":"w1:9","tab":"w1:t9","workspace":"w1","account":"max-a"}'
HC_TERMINAL_ID=t4 FACTORY_SESSION=lead-1 RD_ORCHESTRATED=1 rd wave myrepo "adhoc task"
has "a factory session's orchestrated wave stays on the factory" "$fcalls" "spawn create"

echo "fan: the closing hint names the wait that fits"
reset; reply default '{"status":"started","pane":"w1:9","tab":"w1:t9","workspace":"w1","account":"max-a"}'
rd fan myrepo "$TMP/brief1.md"
has "factory spawns: factory session wait" "$out" "factory session wait --on workers"
lacks "and not hc wait" "$out" "hc wait --children"
reset
HC_TERMINAL_ID=t4 rd fan myrepo "$TMP/brief1.md"
has "hc-direct children: hc wait" "$out" "hc wait --children all"
lacks "and not the factory's" "$out" "factory session wait"
reset; echo 1 >"$STATE/create-rc"
rd fan myrepo "$TMP/brief1.md" "$TMP/brief2.md"
has "a create that fell back to hc, with no caller, is a tab: hc wait <addr>" "$out" "'hc wait t"

echo "close and fan --clean: a hand-started Claude (no factory key, no rd name) is not ours"
reset; echo "[{\"address\":\"t5\",\"name\":null,\"cwd\":\"$TMP/co\",\"argv\":[\"claude\"],\"status\":{\"state\":\"idle\"},\"labels\":{}}]" >"$STATE/terminals.json"
rd close t5
[ "$rc" -ne 0 ] && ! closed && ok "close refuses it" || bad "closed a hand-started Claude: $out"
has "says so" "$out" "not an rd agent"
reset; echo "[{\"address\":\"t5\",\"name\":\"mine\",\"cwd\":\"$TMP/co\",\"argv\":[\"claude\"],\"status\":{\"state\":\"idle\"},\"labels\":{\"herdr.tab\":\"tb-someone-elses\"}}]" >"$STATE/terminals.json"
rd close mine
[ "$rc" -ne 0 ] && ! closed && ok "a name without rd's tab id is no marker" || bad "closed: $out"
tabid="tb-$(printf %s mine | shasum -a 256 | cut -c1-12)"
reset; echo "[{\"address\":\"t5\",\"name\":\"mine\",\"cwd\":\"$TMP/co\",\"argv\":[\"claude\"],\"status\":{\"state\":\"idle\"},\"labels\":{\"herdr.tab\":\"$tabid\"}}]" >"$STATE/terminals.json"
rd close mine
closed && ok "rd's own tab id for the name is a marker" || bad "not closed: $out"
reset; echo "[{\"address\":\"t5\",\"name\":\"kid\",\"parent\":\"t1\",\"cwd\":\"$TMP/co\",\"argv\":[\"claude\"],\"status\":{\"state\":\"idle\"},\"labels\":{}}]" >"$STATE/terminals.json"
rd close kid
closed && ok "a named hidden child (a fan worker) is a marker" || bad "not closed: $out"
printf '#!/usr/bin/env bash\nprintf "remove\\t%s/myrepo-wt\\tfeat/one\\t\\n" "%s"\n' "$S" "$S" >"$S/dotfiles/scripts/fan-list.sh"
reset; echo "[{\"address\":\"t5\",\"name\":null,\"cwd\":\"$S/myrepo-wt\",\"argv\":[\"claude\"],\"status\":{\"state\":\"idle\"},\"labels\":{}}]" >"$STATE/terminals.json"
rd fan --clean myrepo
has "fan --clean keeps a worktree with a hand-started Claude" "$out" "t5 is not an rd agent"
lacks "and ends nothing" "$hcalls" "kill "
cp "$TMP/fan-list.orig" "$S/dotfiles/scripts/fan-list.sh"

echo "fan: a worker that became a tab is listed per address, not under --children"
reset; echo 1 >"$STATE/health-rc"
rd fan myrepo "$TMP/brief1.md"
has "no calling terminal: a tab" "$out" "'hc wait t"
lacks "so not --children" "$out" "hc wait --children"
reset; echo 1 >"$STATE/health-rc"
HC_TERMINAL_ID=t4 rd fan myrepo "$TMP/brief1.md"
has "a calling terminal: a child" "$out" "hc wait --children all"

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; } || { echo "$fails failed"; exit 1; }
