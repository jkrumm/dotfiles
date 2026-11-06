#!/usr/bin/env bash
# remote-dev-factory.test — which path `rd work|say|issue` takes when the factory answers, holds, fails or
# is absent (docs/remote-dev.md §rd and the factory). hc and `factory` are stubs that record every call:
#   factory  health  rc from $STATE/health-rc (default 0) · "health-hang" makes it sleep
#            spawn create  reply + rc from $STATE/create-reply · create-rc (or -<key> for one key), recorded
#            spawn get <key>  line n of $STATE/get-<key> (or get-default); the last line repeats; rc $STATE/get-rc
#            session get / session note  reply + rc from $STATE/session-reply (or -<key>) · session-rc, $STATE/note-rc
#            role get <r>  a valid role answer
#   hc       remote-dev-fake-hc.sh: the roster is $STATE/terminals.json, every terminal.run lands in $STATE/runs.jsonl
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
printf '#!/usr/bin/env bash\ntouch "$STATE/picked"\necho "unset CLAUDE_CONFIG_DIR"\n' >"$TMP/home/.local/bin/claude-account"

# A clean, pushed checkout for the `say` agents' cwd.
g init -q --bare -b master "$TMP/origin.git"
g clone -q "$TMP/origin.git" "$TMP/co" 2>/dev/null
echo a >"$TMP/co/f"; g -C "$TMP/co" add f; g -C "$TMP/co" commit -qm one; g -C "$TMP/co" push -q -u origin master 2>/dev/null

cp "$HERE/remote-dev-fake-hc.sh" "$TMP/home/.local/bin/hc"
# a launchd-born core exists (lib/core-up.sh's first half) unless $STATE/no_core exists; PS_BIN keeps the real ps out
printf '#!/usr/bin/env bash\n[ -f "${STATE:-/nonexistent}/no_core" ] || echo "    1 /x/Herdr Core.app/Contents/MacOS/herdr-core --hc-launchd /tmp/hc-launchd-1/ready"\n' >"$TMP/bin/ps"; chmod +x "$TMP/bin/ps"; export PS_BIN="$TMP/bin/ps"
# the core's socket answers (lib/core-up.sh's second half; no real nc may probe a socket)
printf '#!/usr/bin/env bash\n[ ! -f "${STATE:-/nonexistent}/sock_down" ]\n' >"$TMP/bin/nc"; chmod +x "$TMP/bin/nc"
printf '#!/usr/bin/env bash\nexit 0\n' >"$S/dotfiles/scripts/claude-pretrust.sh"
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
  "spawn create")
    if [ -f "$STATE/reject-placement" ]; then case "$*" in *--placement*) echo "error: Unknown option '--placement'" >&2; exit 2 ;; esac; fi
    if [ -f "$STATE/create-reply-$3" ]; then cat "$STATE/create-reply-$3"; exit "$(cat "$STATE/create-rc-$3" 2>/dev/null || echo 0)"; fi
    cat "$STATE/create-reply" 2>/dev/null || echo '{"error":{"kind":"internal","message":"boom"}}'; exit "$(cat "$STATE/create-rc" 2>/dev/null || echo 0)" ;;
  "spawn get")
    [ -f "$STATE/get-rc" ] && exit "$(cat "$STATE/get-rc")"
    f="$STATE/get-$3"; [ -f "$f" ] || f="$STATE/get-default"
    [ -f "$f" ] || { echo '{"error":{"kind":"not_found","message":"no such spawn"}}'; exit 1; }
    n=$(( $(cat "$f.n" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$f.n"
    total=$(wc -l <"$f"); [ "$n" -gt "$total" ] && n=$total
    sed -n "${n}p" "$f" ;;
  "session get") if [ -f "$STATE/session-reply-$3" ]; then cat "$STATE/session-reply-$3"; exit 0; fi; cat "$STATE/session-reply" 2>/dev/null; exit "$(cat "$STATE/session-rc" 2>/dev/null || echo 0)" ;;
  "issue new") [ -t 0 ] || cat >"$STATE/issue-stdin" 2>/dev/null; cat "$STATE/issue-reply" 2>/dev/null || echo "issue 7 queued"; exit "$(cat "$STATE/issue-rc" 2>/dev/null || echo 0)" ;;
  "issue list") echo "7 queued myrepo"; exit 0 ;;
  "session note") cat "$STATE/note-reply" 2>/dev/null || echo noted; exit "$(cat "$STATE/note-rc" 2>/dev/null || echo 0)" ;;
esac
STUB
chmod +x "$TMP/home/.local/bin/hc" "$TMP/home/.local/bin/factory" "$TMP/home/.local/bin/claude-account" "$S/dotfiles/scripts/"*.sh
clean_path=""; IFS=: read -ra dirs <<<"$PATH"
for d in "${dirs[@]}"; do [ -x "$d/factory" ] || clean_path+="${clean_path:+:}$d"; done
export PATH="$TMP/bin:$clean_path" STATE="$TMP/state" HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/xdg" \
  RD_FACTORY_POLL_S=0
unset RD_DRY_RUN RD_NO_FACTORY FACTORY_SESSION HC_TERMINAL_ID HC_SESSION RD_MODEL RD_EFFORT
export CLAUDE_EFFORT_TABLE="$HERE/../config/claude-effort.json"

reset() { rm -f "$STATE"/* ; : >"$STATE/calls.log"; : >"$STATE/factory-calls"; echo '[]' >"$STATE/terminals.json"; }
rd() { out=$(timeout 90 bash "$HERE/remote-dev.sh" "$@" 2>&1 </dev/null); rc=$?
       hcalls=$(cat "$STATE/calls.log"); fcalls=$(cat "$STATE/factory-calls"); hruns=$(cat "$STATE/runs.jsonl" 2>/dev/null); }
reply() { printf '%s\n' "$2" >"$STATE/get-$1"; }   # reply <key|default> <line…>
hc_ran() { [ -s "$STATE/runs.jsonl" ]; }
no_hc_spawn() { hc_ran && bad "$1 — hc started a terminal: $hruns" || ok "$1"; }
hc_spawned() { hc_ran && ok "$1" || bad "$1 — no terminal.run recorded"; }

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
echo "say: a target hc does not know is an error, not a fallback"
reset; agents_json; echo 1 >"$STATE/health-rc"
rd say ghost "go on"
[ "$rc" -ne 0 ] && ok "exit non-zero" || bad "unknown target accepted: $out"
has "says no agent matches" "$out" "no agent matches 'ghost'"
lacks "nothing typed" "$hcalls" "send "
lacks "no note attempted" "$fcalls" "session note"

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

echo "issue: rd issue files through the factory, never through hc"
reset; printf '{"what":"x"}\n' >"$TMP/facts.json"
rd issue myrepo "Do the thing" --facts "@$TMP/facts.json" --after 3 --after 4 --key k1
is "filed: exit 0" "$rc" 0
has "prints the factory's line" "$out" "issue 7 queued"
has "repo resolved to its path" "$fcalls" "issue new --repo $S/myrepo --title Do the thing"
has "after + key + facts passed" "$fcalls" "--after 3 --after 4 --key k1 --facts -"
is "facts reach the factory on stdin" "$(cat "$STATE/issue-stdin")" '{"what":"x"}'
is "no hc call" "$hcalls" ""
reset; echo 5 >"$STATE/issue-rc"; echo '{"error":{"message":"nope"}}' >"$STATE/issue-reply"
rd issue myrepo "T"
is "the factory's exit code is passed through" "$rc" 5
has "one-line message" "$out" "no Issue filed"
is "no hc fallback on a refusal" "$hcalls" ""
reset; rm -f "$TMP/home/.local/bin/factory.off"; mv "$TMP/home/.local/bin/factory" "$TMP/home/.local/bin/factory.off"
rd issue myrepo "T"
mv "$TMP/home/.local/bin/factory.off" "$TMP/home/.local/bin/factory"
is "factory not installed: exit 127" "$rc" 127
has "says no Issue was filed" "$out" "no Issue filed"
is "and starts nothing on hc" "$hruns" ""
reset
rd issue nosuchrepo "T"
[ "$rc" -ne 0 ] && ok "unknown repo refused" || bad "unknown repo accepted"
reset; rd issues
has "issues lists" "$out" "7 queued myrepo"

echo "removed: wave|fan|merge|close are unknown subcommands and start nothing"
for sub in wave fan merge close; do
  reset; rd "$sub" myrepo "x"
  [ "$rc" -ne 0 ] && ok "$sub: refused" || bad "$sub: accepted: $out"
  has "$sub: unknown subcommand" "$out" "unknown subcommand '$sub'"
  is "$sub: nothing started" "$hruns$fcalls" ""
done

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; } || { echo "$fails failed"; exit 1; }
