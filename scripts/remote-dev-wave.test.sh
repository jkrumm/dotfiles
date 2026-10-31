#!/usr/bin/env bash
# remote-dev-wave.test — `rd wave` / `rd work` on hc against a fake `hc` (remote-dev-fake-hc.sh: a fake core, never a
# real one). Properties under test:
#  - naming: a spawn without "(Wave <n>)" skips every counter number whose `<repo>-w<n>` is a live terminal name, and an
#    explicit "(Wave <n>)" whose name is live dies instead of spawning a duplicate (RD_DRY_RUN stops before the spawn);
#  - the hc-direct spawn follows docs/herdr-core.md §Spawn contract: cwd, argv with the prompt last, env with the account
#    chosen (CLAUDE_CONFIG_DIR absent for iu, never empty), labels herdr.space/herdr.tab and no_parent for a tab, the
#    space HcRunner would pick, and the tab named by compare-and-set on the herdr-app doc;
#  - no core, no spawn: a core launchd does not run is an error and no `hc` call is made (any call would start one);
#  - the shape of `rd agents` (name + status word per line; `blocked` spelled so) that iris' mother-watch.sh greps.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/rd-wave-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
fails=0
ok()  { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fails=$((fails + 1)); }
has() { grep -qF -- "$3" <<<"$2" && ok "$1" || bad "$1 — '$3' not in: $2"; }
lacks() { grep -qF -- "$3" <<<"$2" && bad "$1 — '$3' unexpectedly in: $2" || ok "$1"; }
is()  { [ "$2" = "$3" ] && ok "$1" || bad "$1 — expected '$3', got '$2'"; }

# A scratch HOME: the repo to resolve, a no-op green gate and pretrust, the "on the dev host" marker so host_run executes
# locally, and a fake hc FIRST in ~/.local/bin (rd's host PATH puts that before Homebrew's real hc).
S="$TMP/home/SourceRoot"
mkdir -p "$TMP/bin" "$TMP/state" "$S/dotfiles/scripts" "$S/myrepo/.git" "$TMP/xdg/secrets" "$TMP/home/.local/bin"
echo cache >"$TMP/xdg/secrets/backend"
printf '#!/usr/bin/env python3\n' >"$S/dotfiles/scripts/wave-gate.py"
printf '#!/usr/bin/env bash\nexit 0\n' >"$S/dotfiles/scripts/claude-pretrust.sh"
cp "$HERE/remote-dev-fake-hc.sh" "$TMP/home/.local/bin/hc"
# launchd answers for the core unless $STATE/no_core exists.
cat >"$TMP/bin/launchctl" <<'STUB'
#!/usr/bin/env bash
[ -f "$STATE/no_core" ] && { echo "Could not find service" >&2; exit 113; }
echo "state = running"
STUB
# a MacBook's rd reaches the dev host over ssh; the stub runs the command locally
printf '#!/usr/bin/env bash\nshift\nbash -c "$1"\n' >"$TMP/bin/ssh"
# The account picker is the real machine state otherwise (it can answer "spill"); $STATE/account switches it.
cat >"$TMP/home/.local/bin/claude-account" <<'STUB'
#!/usr/bin/env bash
if [ -f "$STATE/account" ]; then
  echo "export CLAUDE_CONFIG_DIR='/acct/max-b'"; echo "# picked=max-b reason=home stale=false"
else
  echo "unset CLAUDE_CONFIG_DIR"; echo "# picked=iu reason=default stale=false"
fi
STUB
chmod +x "$TMP/bin/ssh" "$TMP/bin/launchctl" "$TMP/home/.local/bin/"* "$S/dotfiles/scripts/"*.sh
# No real `factory` may answer (the mini has one in ~/.local/bin): drop every PATH dir that holds one.
clean_path=""; IFS=: read -ra dirs <<<"$PATH"
for d in "${dirs[@]}"; do [ -x "$d/factory" ] || clean_path+="${clean_path:+:}$d"; done
export PATH="$TMP/bin:$clean_path" STATE="$TMP/state" HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/xdg"
unset HC_SESSION HC_TERMINAL_ID RD_NO_FACTORY RD_ORCHESTRATED RD_WAVE_MODEL RD_WAVE_EFFORT FACTORY_SESSION
export RD_DRY_RUN=1 CLAUDE_EFFORT_TABLE="$HERE/../config/claude-effort.json"

# agents <name…>: a roster with one live, named agent per argument
agents() {
  local json="" a i=0
  for a in "$@"; do
    i=$((i + 1))
    json+="${json:+,}{\"address\":\"t$i\",\"name\":\"$a\",\"cwd\":\"/elsewhere\",\"argv\":[\"claude\"],\"status\":{\"state\":\"idle\"},\"labels\":{}}"
  done
  echo "[$json]" >"$STATE/terminals.json"
}
reset() { rm -rf "${STATE:?}"/*; agents; }
wave() { out=$(bash "$HERE/remote-dev.sh" wave myrepo "$@" 2>&1); rc=$?; }
real() { out=$(env -u RD_DRY_RUN bash "$HERE/remote-dev.sh" "$@" 2>&1 </dev/null); rc=$?; }
run0() { sed -n 1p "$STATE/runs.jsonl"; }   # the first terminal.run params
jqrun() { run0 | jq -r "$1"; }

echo "counter-based number (no Wave token)"
reset
wave "adhoc task"
has "empty roster: -w1" "$out" "agent 'myrepo-w1'"
agents myrepo-w1
wave "adhoc task"
has "live myrepo-w1: skips to -w2" "$out" "agent 'myrepo-w2'"
lacks "does not reuse the live name" "$out" "agent 'myrepo-w1'"
agents myrepo-w1 myrepo-w2
wave "adhoc task"
has "live -w1 and -w2: skips to -w3" "$out" "agent 'myrepo-w3'"
agents myrepo-w2
wave "adhoc task"
has "live -w2 only: next is -w3" "$out" "agent 'myrepo-w3'"

echo "explicit (Wave <n>) token"
agents
wave "Execute the active wave (Wave 4)"
has "free name: plan number wins" "$out" "agent 'myrepo-w4'"
agents myrepo-w4
wave "Execute the active wave (Wave 4)"
[ "$rc" -ne 0 ] && ok "live name: refused" || bad "live name: spawn accepted"
has "live name: says which agent" "$out" "agent 'myrepo-w4' is already live"

echo "unreadable roster"
touch "$STATE/list_broken"
wave "adhoc task"
[ "$rc" -ne 0 ] && ok "no roster answer: refused" || bad "no roster answer: spawn accepted"
has "no roster answer: says so" "$out" "could not read the terminal roster"
rm -f "$STATE/list_broken"; echo '{"terminals":"nope"}' >"$STATE/terminals.json"
wave "adhoc task"
[ "$rc" -ne 0 ] && ok "non-list roster: refused" || bad "non-list roster: spawn accepted"
has "non-list roster: says so" "$out" "could not read the terminal roster"

echo "another agent working in the checkout"
reset
echo "[{\"address\":\"t9\",\"name\":\"other\",\"cwd\":\"$S/myrepo\",\"argv\":[\"claude\"],\"status\":{\"state\":\"working\"},\"labels\":{}}]" >"$STATE/terminals.json"
wave "adhoc task"
[ "$rc" -ne 0 ] && ok "a working agent there: refused" || bad "accepted next to a working agent"
has "names it" "$out" "t9"
HC_TERMINAL_ID=t9 wave "adhoc task"
[ "$rc" -eq 0 ] && ok "the caller's own terminal is not a second editor" || bad "refused the caller: $out"

echo "a linked machine's terminals are not ours: not a second editor, not a name in use"
reset
echo "[{\"address\":\"mini/t9\",\"name\":\"myrepo-w1\",\"cwd\":\"$S/myrepo\",\"argv\":[\"claude\"],\"status\":{\"state\":\"working\"},\"labels\":{}}]" >"$STATE/terminals.json"
wave "adhoc task"
[ "$rc" -eq 0 ] && ok "a working agent on a linked machine does not block the wave" || bad "blocked by a linked machine: $out"
has "and its name is not taken" "$out" "agent 'myrepo-w1'"
out=$(bash "$HERE/remote-dev.sh" say mini/t9 go 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "say cannot address a linked machine's terminal" || bad "reached a linked machine: $out"

echo "the caller's terminal id only counts on the dev host"
reset
echo "[{\"address\":\"t9\",\"name\":\"other\",\"cwd\":\"$S/myrepo\",\"argv\":[\"claude\"],\"status\":{\"state\":\"working\"},\"labels\":{}}]" >"$STATE/terminals.json"
echo notcache >"$TMP/xdg/secrets/backend"
HC_TERMINAL_ID=t9 wave "adhoc task"
[ "$rc" -ne 0 ] && ok "off the dev host, a t9 on the mini is not the caller" || bad "excluded another machine's terminal id: $out"
echo cache >"$TMP/xdg/secrets/backend"

echo "HC_SESSION skips the launchd check on the dev host only"
reset; touch "$STATE/no_core"
HC_SESSION=scratch wave "adhoc task"
[ "$rc" -eq 0 ] && ok "dev host + HC_SESSION: the scratch core is the caller's" || bad "refused a scratch core: $out"
echo notcache >"$TMP/xdg/secrets/backend"
HC_SESSION=scratch wave "adhoc task"
[ "$rc" -ne 0 ] && ok "off the dev host, HC_SESSION is not forwarded: launchd is asked and says no" || bad "skipped the check: $out"
has "names the fix" "$out" "launchctl kickstart"
echo cache >"$TMP/xdg/secrets/backend"

echo "RD_WAVE_MAX counts a repo whose terminal names hc escapes (t<digit>…)"
reset; mkdir -p "$S/t7app/.git"
esc() { printf 'f-%s-%s' "$(printf %s "$1" | shasum -a 256 | cut -c1-12 | cut -c1-6)" "${1:0:22}"; }
echo "[{\"address\":\"t1\",\"name\":\"$(esc t7app-w1)\",\"cwd\":\"/e\",\"argv\":[\"claude\"],\"status\":{\"state\":\"idle\"},\"labels\":{}},{\"address\":\"t2\",\"name\":\"$(esc t7app-w2)\",\"cwd\":\"/e\",\"argv\":[\"claude\"],\"status\":{\"state\":\"idle\"},\"labels\":{}}]" >"$STATE/terminals.json"
out=$(RD_WAVE_MAX=2 bash "$HERE/remote-dev.sh" wave t7app "adhoc task" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "two live waves hit RD_WAVE_MAX=2" || bad "the escaped names were not counted: $out"
has "says the bound" "$out" "would exceed RD_WAVE_MAX=2"

echo "hc calls are bounded: a spawn that gets no answer is uncertain, never retried"
if command -v timeout >/dev/null || command -v gtimeout >/dev/null; then
  reset; touch "$STATE/run_hang"; t0=$SECONDS
  RD_HC_TIMEOUT_S=1 real wave myrepo "adhoc task"
  [ "$rc" -ne 0 ] && ok "non-zero exit" || bad "exit 0 on a timed-out spawn"
  has "says uncertain and where to look" "$out" "uncertain"
  has "points at rd agents" "$out" "'rd agents' shows whether it exists"
  is "one terminal.run, no blind retry" "$(wc -l <"$STATE/runs.jsonl" | tr -d ' ')" "1"
  (( SECONDS - t0 < 20 )) && ok "gave up at the limit, not after the stub's 30 s" || bad "took $((SECONDS - t0)) s"
fi

echo "busy: anything but idle/done in the checkout counts (starting and not-yet-reported included)"
for st in starting working blocked; do
  reset
  echo "[{\"address\":\"t9\",\"name\":\"other\",\"cwd\":\"$S/myrepo\",\"argv\":[\"claude\"],\"status\":{\"state\":\"$st\"},\"labels\":{}}]" >"$STATE/terminals.json"
  wave "adhoc task"
  [ "$rc" -ne 0 ] && ok "'$st': refused" || bad "'$st' accepted: $out"
done
reset
echo "[{\"address\":\"t9\",\"name\":\"other\",\"cwd\":\"$S/myrepo\",\"argv\":[\"claude\"],\"status\":null,\"labels\":{}}]" >"$STATE/terminals.json"
wave "adhoc task"
[ "$rc" -ne 0 ] && ok "no status yet: refused" || bad "an agent that has not reported was ignored: $out"
for st in idle "done"; do
  reset
  echo "[{\"address\":\"t9\",\"name\":\"other\",\"cwd\":\"$S/myrepo\",\"argv\":[\"claude\"],\"status\":{\"state\":\"$st\"},\"labels\":{}}]" >"$STATE/terminals.json"
  wave "adhoc task"
  [ "$rc" -eq 0 ] && ok "'$st': a finished predecessor is fine" || bad "'$st' refused: $out"
done

echo "no core: an error, and hc is never called (any call would start a core)"
reset; touch "$STATE/no_core"
wave "adhoc task"
[ "$rc" -ne 0 ] && ok "refused" || bad "ran without a core"
has "names the fix" "$out" "launchctl kickstart -k gui/\$(id -u)/com.jkrumm.herdr-core"
[ ! -e "$STATE/hc-called" ] && ok "hc was not called" || bad "hc was called: $(cat "$STATE/calls.log" "$STATE/rpc.log" 2>/dev/null)"
for sub in agents "read x" "say x y" "close x" "work myrepo"; do
  rm -f "$STATE/hc-called"
  out=$(bash "$HERE/remote-dev.sh" $sub 2>&1); rc=$?
  [ "$rc" -ne 0 ] && [ ! -e "$STATE/hc-called" ] && ok "rd $sub: error, hc not called" || bad "rd $sub: rc=$rc, hc called=$([ -e "$STATE/hc-called" ] && echo yes || echo no)"
done

echo "hc-direct tab spawn (iu account)"
reset
real wave myrepo --role wave "Execute the active wave (Wave 4). It has \"quotes\", a \$(sub) and
a second line."
is "exit 0" "$rc" "0"
has "reports the address" "$out" "wave 4 started: claude 'myrepo-w4' as t99"
is "one terminal.run" "$(wc -l <"$STATE/runs.jsonl" | tr -d ' ')" "1"
is "cwd is the repo" "$(jqrun .cwd)" "$S/myrepo"
is "argv starts with claude" "$(jqrun '.argv[0]')" "claude"
is "solo mode flag" "$(jqrun '.argv[1]')" "--dangerously-skip-permissions"
is "the prompt is the last argv word, byte-identical" "$(jqrun '.argv[-1]')" "Execute the active wave (Wave 4). It has \"quotes\", a \$(sub) and
a second line."
is "keep" "$(jqrun .keep)" "true"
is "named after the agent" "$(jqrun .name)" "myrepo-w4"
is "no_parent" "$(jqrun '.no_parent')" "true"
is "no parent key" "$(jqrun 'has("parent")')" "false"
root=$(cd "$S/myrepo" && pwd -P)
space="sp-myrepo-$(printf %s "$root" | shasum -a 256 | cut -c1-12)"
is "space label: no app entry, so the stable id from the full root" "$(jqrun '.labels["herdr.space"]')" "$space"
is "tab label: a stable id from the agent name" "$(jqrun '.labels["herdr.tab"]')" "tb-$(printf %s myrepo-w4 | shasum -a 256 | cut -c1-12)"
is "only those two labels" "$(jqrun '.labels | keys | join(",")')" "herdr.space,herdr.tab"
is "FACTORY_SESSION" "$(jqrun .env.FACTORY_SESSION)" "myrepo-w4"
is "FACTORY_ROLE" "$(jqrun .env.FACTORY_ROLE)" "wave"
is "USAGE_LANE" "$(jqrun .env.USAGE_LANE)" "wave"
is "CLAUDE_ACCOUNT_PICKED marks the pick" "$(jqrun .env.CLAUDE_ACCOUNT_PICKED)" "iu"
is "iu: CLAUDE_CONFIG_DIR is absent, not empty" "$(jqrun '.env | has("CLAUDE_CONFIG_DIR")')" "false"
is "no empty env value" "$(jqrun '[.env[] | select(. == "")] | length')" "0"

echo "hc-direct tab spawn (a Claude account)"
reset; touch "$STATE/account"
real wave myrepo "adhoc task"
is "CLAUDE_CONFIG_DIR is the account's dir" "$(jqrun .env.CLAUDE_CONFIG_DIR)" "/acct/max-b"
is "CLAUDE_ACCOUNT_PICKED" "$(jqrun .env.CLAUDE_ACCOUNT_PICKED)" "max-b"
is "the default model rides in argv" "$(jqrun '.argv | join(" ")' | cut -c1-72)" "claude --dangerously-skip-permissions --model sonnet --effort high adhoc"
rm -f "$STATE/account"

echo "space: the app's own entry for the folder wins; the tab is named by compare-and-set"
reset
tabid="tb-$(printf %s myrepo-w1 | shasum -a 256 | cut -c1-12)"
echo "{\"version\":7,\"value\":{\"spaces\":[{\"id\":\"spOTHER\",\"folder\":\"/elsewhere\",\"tabs\":[]},{\"id\":\"spAPP\",\"folder\":\"$S/myrepo\",\"name\":\"myrepo\",\"tabs\":[{\"id\":\"$tabid\",\"name\":\"\"},{\"id\":\"tbOTHER\",\"name\":\"keep me\"}]}]}}" >"$STATE/doc.json"
real wave myrepo "adhoc task"
is "space = the doc entry whose folder is the repo" "$(jqrun '.labels["herdr.space"]')" "spAPP"
is "one doc.set" "$(wc -l <"$STATE/sets.jsonl" | tr -d ' ')" "1"
is "written against the version just read" "$(jq -r .version "$STATE/sets.jsonl")" "7"
is "the tab is named after the agent" "$(jq -r --arg t "$tabid" '.value.spaces[1].tabs[] | select(.id == $t) | .name' "$STATE/sets.jsonl")" "myrepo-w1"
is "other tabs untouched" "$(jq -r '.value.spaces[1].tabs[] | select(.id == "tbOTHER") | .name' "$STATE/sets.jsonl")" "keep me"
reset
echo "{\"version\":1,\"value\":{\"spaces\":[{\"id\":\"spAPP\",\"folder\":\"$S/myrepo\",\"tabs\":[{\"id\":\"$tabid\",\"name\":\"\"}]}]}}" >"$STATE/doc.json"; echo 1 >"$STATE/set_conflicts"
real wave myrepo "adhoc task"
is "exit 0 after a conflict" "$rc" "0"
is "a conflict is retried against the fresh version" "$(wc -l <"$STATE/sets.jsonl" | tr -d ' ')" "2"
is "and lands" "$(jq -r '.spaces[0].tabs[0].name' < <(jq -c .value "$STATE/doc.json"))" "myrepo-w1"
reset
echo '{"version":1,"value":{"spaces":[]}}' >"$STATE/doc.json"
real wave myrepo "adhoc task"
is "no tab entry yet: nothing written, the spawn still succeeds" "$rc$([ -e "$STATE/sets.jsonl" ] && echo set)" "0"
reset; echo unavailable >"$STATE/doc_error"
real wave myrepo "adhoc task"
[ "$rc" -ne 0 ] && ok "an unreadable app doc refuses to guess a space" || bad "spawned into a guessed space"
is "nothing was run" "$([ -e "$STATE/runs.jsonl" ] && echo ran)" ""

echo "orchestrated wave: a labelled tab that is a child of the caller"
reset
HC_TERMINAL_ID=t5 RD_ORCHESTRATED=1 real wave myrepo "adhoc task"
is "parent = the orchestrator's terminal" "$(jqrun .parent)" "t5"
is "still labelled as a tab" "$(jqrun '.labels | has("herdr.tab")')" "true"
is "and not no_parent" "$(jqrun 'has("no_parent")')" "false"
is "outlive_parent: losing the orchestrator must not kill a working wave" "$(jqrun .outlive_parent)" "true"
reset
HC_TERMINAL_ID=t5 real wave myrepo "adhoc task"
is "a chain's next wave has no parent even with a caller" "$(jqrun 'has("parent")')" "false"
is "it is no_parent" "$(jqrun '.no_parent')" "true"
is "and has no outlive_parent (nothing to outlive)" "$(jqrun 'has("outlive_parent")')" "false"

echo "a refused spawn is an error"
reset; echo name_taken >"$STATE/run_error"
real wave myrepo "adhoc task"
[ "$rc" -ne 0 ] && ok "non-zero exit" || bad "exit 0 on a refused spawn"
has "says what hc said" "$out" "hc could not start 'myrepo-w1'"

echo "a prompt that claude would read as an option is refused"
reset
real wave myrepo -- "-dangerous"
[ "$rc" -ne 0 ] && ok "refused" || bad "accepted: $out"
is "nothing was run" "$([ -e "$STATE/runs.jsonl" ] && echo ran)" ""

echo "work: a tab, no prompt, no solo flag"
reset
real work myrepo --role lead
is "argv is bare claude: no prompt, no solo flag (a human sits in front of it; no factory here, so no role flags)" "$(jqrun '.argv | join(" ")')" "claude"
is "FACTORY_ROLE follows --role" "$(jqrun .env.FACTORY_ROLE)" "lead"
is "a tab" "$(jqrun '.labels | has("herdr.tab")')" "true"
reset
echo "[{\"address\":\"t3\",\"name\":\"x\",\"cwd\":\"$S/myrepo\",\"argv\":[\"claude\"],\"status\":{\"state\":\"idle\"},\"labels\":{}}]" >"$STATE/terminals.json"
real work myrepo
has "an agent already in the checkout is reported, not stacked" "$out" "already running: agent t3"
is "no spawn" "$([ -e "$STATE/runs.jsonl" ] && echo ran)" ""

echo "rd agents: one line per agent with its name and status word (iris' mother-watch.sh greps these)"
cat >"$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
echo '[]'
STUB
chmod +x "$TMP/bin/claude"
mkdir -p "$S/dotfiles/config"; echo '{"accounts":{}}' >"$S/dotfiles/config/claude-accounts.json"
reset
cat >"$STATE/terminals.json" <<JSON
[{"address":"t1","name":"iris-w3","cwd":"$S/iris","argv":["claude"],"status":{"app":"claude-code","state":"working"},"labels":{}},
 {"address":"t2","name":"iris-w3-api","cwd":"$S/iris-wt","argv":["claude"],"status":{"app":"claude-code","state":"blocked"},"labels":{},"parent":"t1"},
 {"address":"t3","name":null,"cwd":"$S/brain","argv":["/bin/zsh","-l"],"status":null,"labels":{}},
 {"address":"t4","name":"iris-w4","cwd":"$S/iris","argv":["/bin/zsh","-l"],"foreground":{"argv":["claude"]},"status":null,"labels":{}}]
JSON
out=$(bash "$HERE/remote-dev.sh" agents 2>&1); rc=$?
is "exit 0" "$rc" "0"
l1=$(grep 'iris-w3 ' <<<"$out"); l2=$(grep 'iris-w3-api' <<<"$out")
has "the lead's line carries its name and its status word" "$l1" "working"
has "a blocked agent's line carries the word blocked" "$l2" "blocked"
is "the watcher's grep finds the blocked wave (iris|w3, then blocked)" "$(grep -E "iris|w3" <<<"$out" | grep -c blocked)" "1"
is "the watcher's lead-gone check finds the lead by name" "$(grep -c "iris-w3" <<<"$out")" "2"
lacks "a plain shell is no agent" "$out" "brain"
has "a resumed Claude in a kept login shell (no status yet) is listed" "$out" "iris-w4"
has "a source column" "$out" "SOURCE"
has "the hc rows say hc" "$l1" "hc "
rm -f "$TMP/bin/claude"

echo; [ "$fails" -eq 0 ] && echo "remote-dev-wave: all passed" || { echo "remote-dev-wave: $fails failed"; exit 1; }
