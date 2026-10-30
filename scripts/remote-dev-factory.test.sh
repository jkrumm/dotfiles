#!/usr/bin/env bash
# remote-dev-factory.test — which path `rd wave|fan|say|close` takes when the factory answers, holds, fails or
# is absent (docs/remote-dev.md §rd and the factory). herdr and `factory` are stubs that record every call:
#   factory  health  rc from $STATE/health-rc (default 0) · "health-hang" makes it sleep
#            spawn create  rc from $STATE/create-rc, recorded
#            spawn get <key>  line n of $STATE/get-<key> (or get-default); the last line repeats; rc $STATE/get-rc
#            session get / session note  reply + rc from $STATE/session-reply · session-rc, $STATE/note-rc
#            role get <r>  a valid role answer
#   herdr    the roster is $STATE/agents.json; tab/workspace create and agent start answer like a live herdr
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

cat >"$TMP/bin/herdr" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$STATE/calls"
case "$1 $2" in
  "status ") echo "status: running" ;;
  "agent list") cat "$STATE/agents.json" ;;
  "tab list") echo '{"result":{"tabs":[]}}' ;;
  "tab get") echo "{\"result\":{\"tab\":{\"label\":\"$(cat "$STATE/tab-label" 2>/dev/null)\"}}}" ;;
  "workspace list") echo '{"result":{"workspaces":[]}}' ;;
  "tab create"|"workspace create")
    echo '{"result":{"workspace":{"workspace_id":"w1"},"root_pane":{"pane_id":"w1:1","tab_id":"t1"}}}' ;;
  "agent start") echo '{"type":"agent_started"}' ;;
  "agent get")
    n=$(( $(cat "$STATE/get_n" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$STATE/get_n"
    sc=10; [ -f "$STATE/sent" ] && sc=11
    echo "{\"result\":{\"agent\":{\"name\":\"worker\",\"pane_id\":\"p-1\",\"cwd\":\"x\",\"agent_status\":\"working\",\"state_change_seq\":$sc,\"completion_seq\":0}}}" ;;
  "agent prompt") touch "$STATE/sent"; echo '{"result":{"type":"agent_prompted"}}' ;;
  "tab close") echo '{"result":{}}' ;;
  *) echo '{}' ;;
esac
STUB
cat >"$TMP/home/.local/bin/factory" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = health ]; then
  echo "health" >>"$STATE/factory-calls"
  [ -f "$STATE/health-hang" ] && sleep 30
  exit "$(cat "$STATE/health-rc" 2>/dev/null || echo 0)"
fi
echo "$*" >>"$STATE/factory-calls"
case "$1 $2" in
  "role get") printf '{"role":"%s","tier":"sonnet","effort":"high"}\n' "$3" ;;
  "spawn create") echo '{}'; exit "$(cat "$STATE/create-rc" 2>/dev/null || echo 0)" ;;
  "spawn get")
    [ -f "$STATE/get-rc" ] && exit "$(cat "$STATE/get-rc")"
    f="$STATE/get-$3"; [ -f "$f" ] || f="$STATE/get-default"
    n=$(( $(cat "$f.n" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$f.n"
    total=$(wc -l <"$f"); [ "$n" -gt "$total" ] && n=$total
    sed -n "${n}p" "$f" ;;
  "session get") cat "$STATE/session-reply" 2>/dev/null; exit "$(cat "$STATE/session-rc" 2>/dev/null || echo 0)" ;;
  "session note") echo "noted"; exit "$(cat "$STATE/note-rc" 2>/dev/null || echo 0)" ;;
esac
STUB
chmod +x "$TMP/bin/herdr" "$TMP/home/.local/bin/factory" "$TMP/home/.local/bin/claude-account" "$S/dotfiles/scripts/"*.sh
clean_path=""; IFS=: read -ra dirs <<<"$PATH"
for d in "${dirs[@]}"; do [ -x "$d/factory" ] || clean_path+="${clean_path:+:}$d"; done
export PATH="$TMP/bin:$clean_path" STATE="$TMP/state" HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/xdg" \
  RD_DELIVER_WAIT_S=0 RD_POLL_S=0 RD_FACTORY_POLL_S=0 RD_SAY_SETTLE=0 RD_SAY_WAIT_S=3
unset RD_DRY_RUN RD_NO_FACTORY FACTORY_SESSION RD_WAVE_MODEL RD_WAVE_EFFORT
export CLAUDE_EFFORT_TABLE="$HERE/../config/claude-effort.json"
printf 'Branch: feat/one\n\nDo one.\n' >"$TMP/brief1.md"
printf 'Branch: feat/two\n\nDo two.\n' >"$TMP/brief2.md"

reset() { rm -f "$STATE"/* ; : >"$STATE/calls"; : >"$STATE/factory-calls"; echo '{"result":{"agents":[]}}' >"$STATE/agents.json"; }
rd() { out=$(timeout 90 bash "$HERE/remote-dev.sh" "$@" 2>&1 </dev/null); rc=$?
       hcalls=$(cat "$STATE/calls"); fcalls=$(cat "$STATE/factory-calls"); }
reply() { printf '%s\n' "$2" >"$STATE/get-$1"; }   # reply <key|default> <line…>
herdr_created() { grep -qE '^(tab|workspace) create' <<<"$hcalls"; }
no_herdr_spawn() { herdr_created && bad "$1 — herdr created a pane: $hcalls" || ok "$1"; grep -q '^agent start' <<<"$hcalls" && bad "$1 — herdr started an agent" || true; }
herdr_spawned() { herdr_created && grep -q '^agent start' <<<"$hcalls" && ok "$1" || bad "$1 — no herdr create+start in: $hcalls"; }

# --- wave ---------------------------------------------------------------------------------------------
echo "wave: the factory answers and starts it"
reset; reply default '{"state":"started","pane":"w1:7","account":"max-b"}'
rd wave myrepo "adhoc task"
is "exit 0" "$rc" "0"
has "prints today's line: agent" "$out" "claude 'myrepo-w1'"
has "prints the space" "$out" "space $S/myrepo"
has "prints the pane" "$out" "pane w1:7"
has "prints the account" "$out" "[account max-b]"
has "creates the spawn keyed by the agent name, in the repo" "$fcalls" "spawn create myrepo-w1 --repo $S/myrepo --prompt adhoc task --role wave --format json"
no_herdr_spawn "no herdr pane is made by rd"
[ ! -e "$STATE/picked" ] && ok "rd does not pick an account (the factory does)" || bad "rd picked an account"
rd wave myrepo --role mechanical "adhoc task"
has "--role rides to the spawn" "$fcalls" "--role mechanical"

echo "wave: claimed first, started later (bounded wait)"
reset; printf '%s\n' '{"state":"claimed"}' '{"state":"started","pane":"w1:2"}' >"$STATE/get-default"
rd wave myrepo "adhoc task"
has "waited for started" "$out" "pane w1:2"
is "polled twice" "$(grep -c '^spawn get' <<<"$fcalls")" "2"

echo "wave: held or queued"
reset; reply default '{"state":"queued","reason":"all accounts at their limit"}'
rd wave myrepo "adhoc task"
is "exit 0" "$rc" "0"
has "queued: <reason>" "$out" "queued: all accounts at their limit"
no_herdr_spawn "nothing started by rd"
reset; reply default '{"state":"held","hold_reason":"queue is draining"}'
rd wave myrepo "adhoc task"
is "held: exit 0" "$rc" "0"
has "held: reason" "$out" "queued: queue is draining"

echo "wave: failed"
reset; reply default '{"state":"failed","reason":"folder trust refused"}'
rd wave myrepo "adhoc task"
[ "$rc" -ne 0 ] && ok "non-zero exit" || bad "exit 0 on a failed spawn"
has "names the reason" "$out" "folder trust refused"
no_herdr_spawn "no herdr fallback after a failed spawn"

echo "wave: claimed and never started within the wait"
reset; reply default '{"state":"claimed"}'
RD_FACTORY_WAIT_S=0 rd wave myrepo "adhoc task"
is "exit 0 (the factory still owns it)" "$rc" "0"
has "says not started yet" "$out" "claimed by the factory, not started yet"

echo "wave: the factory goes silent after create"
reset; echo 1 >"$STATE/get-rc"
RD_FACTORY_WAIT_S=0 rd wave myrepo "adhoc task"
[ "$rc" -ne 0 ] && ok "non-zero exit" || bad "exit 0"
has "says it stopped answering" "$out" "stopped answering after creating spawn 'myrepo-w1'"
no_herdr_spawn "no second spawn through herdr"

echo "wave: create fails -> the herdr path"
reset; echo 1 >"$STATE/create-rc"
rd wave myrepo "adhoc task"
is "exit 0" "$rc" "0"
has "one stderr line says so" "$out" "factory spawn create failed"
herdr_spawned "herdr made the pane"
[ -e "$STATE/picked" ] && ok "the account is picked on the herdr path" || bad "no account pick on fallback"
has "FACTORY_ROLE in the pane's env" "$hcalls" "--env FACTORY_ROLE=wave"
has "FACTORY_SESSION in the pane's env" "$hcalls" "--env FACTORY_SESSION=myrepo-w1"

echo "wave: create times out but the factory recorded it"
reset; echo 124 >"$STATE/create-rc"; reply default '{"state":"started","pane":"w1:3"}'
rd wave myrepo "adhoc task"
has "carries on to the started spawn" "$out" "pane w1:3"
no_herdr_spawn "no herdr fallback"
reset; echo 124 >"$STATE/create-rc"; echo 1 >"$STATE/get-rc"
rd wave myrepo "adhoc task"
has "timeout with nothing recorded: the herdr path" "$out" "factory spawn create failed"
herdr_spawned "herdr made the pane"

echo "wave: not answering -> today's path, FACTORY_ROLE added"
reset; echo 1 >"$STATE/health-rc"
rd wave myrepo "adhoc task"
is "exit 0" "$rc" "0"
herdr_spawned "herdr made the pane"
lacks "no spawn create attempted" "$fcalls" "spawn create"
has "FACTORY_ROLE=wave" "$hcalls" "--env FACTORY_ROLE=wave"
rd wave myrepo --role mechanical "adhoc task"
has "FACTORY_ROLE follows --role" "$hcalls" "--env FACTORY_ROLE=mechanical"
reset; RD_NO_FACTORY=1 rd wave myrepo "adhoc task"
lacks "RD_NO_FACTORY=1 skips the probe" "$fcalls" "health"
herdr_spawned "RD_NO_FACTORY=1: herdr path"
if command -v timeout >/dev/null || command -v gtimeout >/dev/null; then
  reset; touch "$STATE/health-hang"; t0=$SECONDS
  rd wave myrepo "adhoc task"
  herdr_spawned "a hanging health probe: herdr path"
  (( SECONDS - t0 < 20 )) && ok "gave up at the probe limit, not after the stub's 30 s" || bad "took $((SECONDS - t0)) s"
fi
mv "$TMP/home/.local/bin/factory" "$TMP/factory.away"
reset
rd wave myrepo "adhoc task"
is "factory not installed: exit 0" "$rc" "0"
herdr_spawned "factory not installed: herdr path"
mv "$TMP/factory.away" "$TMP/home/.local/bin/factory"

# --- fan ----------------------------------------------------------------------------------------------
echo "fan: the factory answers"
reset; reply default '{"state":"started","pane":"w1:9","account":"max-a"}'
rd fan myrepo "$TMP/brief1.md"
is "exit 0" "$rc" "0"
has "key = <repo>-<branch leaf>" "$fcalls" "spawn create myrepo-one --repo $S/myrepo-wt"
has "--space is the main checkout" "$fcalls" "--space $S/myrepo"
has "role worker" "$fcalls" "--role worker"
has "the prompt carries the fetched base" "$fcalls" "Base: origin/master @ abc1234"
has "prints the line" "$out" "fan feat/one started: claude 'myrepo-one' via the factory, space $S/myrepo, pane w1:9"
no_herdr_spawn "no herdr pane"
[ ! -e "$STATE/picked" ] && ok "no account pick" || bad "rd picked an account"

echo "fan: one queued, one failed, the rest still go"
reset
reply myrepo-one '{"state":"queued","reason":"paced"}'
reply myrepo-two '{"state":"failed","reason":"boom"}'
rd fan myrepo "$TMP/brief1.md" "$TMP/brief2.md"
[ "$rc" -ne 0 ] && ok "non-zero exit when one failed" || bad "exit 0 with a failed spawn"
has "queued line" "$out" "queued: paced"
has "failed reason" "$out" "boom"
is "both spawns were created" "$(grep -c '^spawn create' <<<"$fcalls")" "2"
reset
reply myrepo-one '{"state":"queued","reason":"paced"}'
rd fan myrepo "$TMP/brief1.md"
is "queued alone: exit 0" "$rc" "0"

echo "fan: create fails -> herdr for this and every later brief"
reset; echo 1 >"$STATE/create-rc"
rd fan myrepo "$TMP/brief1.md" "$TMP/brief2.md"
is "one create attempted, then herdr only" "$(grep -c '^spawn create' <<<"$fcalls")" "1"
is "two herdr agents started" "$(grep -c '^agent start' <<<"$hcalls")" "2"
has "FACTORY_ROLE=worker in the pane" "$hcalls" "--env FACTORY_ROLE=worker"

echo "fan: not answering -> today's path"
reset; echo 1 >"$STATE/health-rc"
rd fan myrepo "$TMP/brief1.md"
herdr_spawned "herdr made the pane"
lacks "no spawn create" "$fcalls" "spawn create"
has "FACTORY_ROLE=worker" "$hcalls" "--env FACTORY_ROLE=worker"
rd fan myrepo --role mechanical "$TMP/brief1.md"
has "FACTORY_ROLE follows --role" "$hcalls" "--env FACTORY_ROLE=mechanical"

echo "work: FACTORY_ROLE only when --role is given"
reset; echo 1 >"$STATE/health-rc"
rd work myrepo
lacks "no role, no FACTORY_ROLE" "$hcalls" "FACTORY_ROLE"
rd work myrepo --role lead
has "--role lead" "$hcalls" "--env FACTORY_ROLE=lead"

# --- say ----------------------------------------------------------------------------------------------
agents_json() { # <extra agent json…>
  local cwd=$TMP/co
  echo "{\"result\":{\"agents\":[{\"name\":\"worker\",\"pane_id\":\"p-1\",\"tab_id\":\"t9\",\"cwd\":\"$cwd\",\"agent_status\":\"${AGENT_STATUS:-idle}\"}$*]}}" >"$STATE/agents.json"
}
echo "say: the factory holds the note"
reset; agents_json
rd say worker "go on"
is "exit 0" "$rc" "0"
has "noted" "$out" "noted: the factory holds it while worker works"
has "session note <agent> <text>" "$fcalls" "session note worker go on"
lacks "nothing typed through herdr" "$hcalls" "agent prompt"
echo "say: the note fails -> herdr"
reset; agents_json; echo 1 >"$STATE/note-rc"
rd say worker "go on"
has "one stderr line says so" "$out" "factory note for 'worker' failed"
has "typed through herdr" "$hcalls" "agent prompt p-1 go on"
echo "say: the note times out -> never re-sent"
reset; agents_json; echo 124 >"$STATE/note-rc"
rd say worker "go on"
[ "$rc" -ne 0 ] && ok "non-zero exit" || bad "exit 0"
has "says NOT delivered" "$out" "NOT delivered"
lacks "no herdr re-send" "$hcalls" "agent prompt"
echo "say: not answering -> today's path"
reset; agents_json; echo 1 >"$STATE/health-rc"
rd say worker "go on"
has "typed through herdr" "$hcalls" "agent prompt p-1 go on"
lacks "no note attempted" "$fcalls" "session note"
echo "say: a nameless agent is no factory session"
reset; echo '{"result":{"agents":[{"pane_id":"p-1","tab_id":"t9","cwd":"x","agent_status":"idle"}]}}' >"$STATE/agents.json"
rd say p-1 "go on"
lacks "no note attempted" "$fcalls" "session note"

# --- close --------------------------------------------------------------------------------------------
SESSION='{"state":"idle","pane":"p-1","tab":"t9"}'
closed() { grep -q '^tab close' <<<"$hcalls"; }
echo "close: the tab comes from the session, not its name"
for label in "1" "fan feat-x" "wave 2"; do
  reset; agents_json; echo "$SESSION" >"$STATE/session-reply"; echo "$label" >"$STATE/tab-label"
  rd close worker
  is "tab '$label': exit 0" "$rc" "0"
  closed && has "tab '$label': tab t9 closed" "$hcalls" "tab close t9" || bad "tab '$label' not closed: $out"
  has "asked the factory for the session" "$fcalls" "session get worker --format json"
done
echo "close: today's refusals stay"
reset; agents_json; echo '{"state":"working","pane":"p-1","tab":"t9"}' >"$STATE/session-reply"
rd close worker
[ "$rc" -ne 0 ] && ! closed && ok "session working: refused" || bad "closed a working session: $out"
reset; AGENT_STATUS=working agents_json; echo "$SESSION" >"$STATE/session-reply"
rd close worker
[ "$rc" -ne 0 ] && ! closed && ok "herdr says working: refused" || bad "closed a working agent: $out"
reset; agents_json; echo "$SESSION" >"$STATE/session-reply"; echo dirty >"$TMP/co/dirty"
rd close worker
[ "$rc" -ne 0 ] && ! closed && ok "dirty checkout: refused" || bad "closed a dirty checkout: $out"
rm -f "$TMP/co/dirty"
echo b >"$TMP/co/f"; g -C "$TMP/co" commit -qam two
reset; agents_json; echo "$SESSION" >"$STATE/session-reply"
rd close worker
[ "$rc" -ne 0 ] && ! closed && ok "unpushed commit: refused" || bad "closed with unpushed commits: $out"
g -C "$TMP/co" push -q origin master 2>/dev/null
reset; agents_json; echo '{"state":"idle","pane":"p-9","tab":"t9"}' >"$STATE/session-reply"
rd close worker
[ "$rc" -ne 0 ] && ! closed && ok "pane mismatch: refused" || bad "closed on a stale record: $out"
reset; agents_json ',{"name":"shell","pane_id":"p-2","tab_id":"t9","cwd":"x","agent_status":"idle"}'; echo "$SESSION" >"$STATE/session-reply"
rd close worker
[ "$rc" -ne 0 ] && ! closed && ok "another agent in the tab: refused" || bad "closed a shared tab: $out"
has "names the other agent" "$out" "shell"

echo "close: no such session -> the tab-name rule"
reset; agents_json; echo 1 >"$STATE/session-rc"; echo "1" >"$STATE/tab-label"
rd close worker
[ "$rc" -ne 0 ] && ! closed && ok "tab '1' without a session: refused as before" || bad "closed tab '1': $out"
has "says why" "$out" "not a 'wave <n>' tab"
has "one stderr line about the factory" "$out" "the factory has no session 'worker'"
reset; agents_json; echo 1 >"$STATE/session-rc"; echo "wave 3" >"$STATE/tab-label"
rd close worker
closed && ok "wave tab without a session: closed as before" || bad "wave 3 not closed: $out"
echo "close: not answering -> today's path"
reset; agents_json; echo 1 >"$STATE/health-rc"; echo "1" >"$STATE/tab-label"; echo "$SESSION" >"$STATE/session-reply"
rd close worker
[ "$rc" -ne 0 ] && ! closed && ok "tab '1': refused" || bad "closed tab '1': $out"
lacks "the factory was not asked for a session" "$fcalls" "session get"
echo "wave 1" >"$STATE/tab-label"
rd close worker
closed && ok "wave tab: closed" || bad "wave 1 not closed: $out"

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; } || { echo "$fails failed"; exit 1; }
