#!/usr/bin/env bash
# remote-dev-say.test — `rd say` on hc (fake `hc`, remote-dev-fake-hc.sh) and, for a target hc does not know, on the
# classic-herdr fallback (TODO(Wave 7): drop classic) against a stubbed herdr. Property under
# test: a message that did not land can never look delivered, and one that did land is never
# reported lost (which would invite a duplicate). The stub keeps an agent's status plus its
# state_change_seq/completion_seq; `agent prompt` changes them according to $STATE/mode:
#   working | blocked | done   the agent picked the prompt up and ended in that state (fast answers
#                              are `blocked` / a fresh `done`, never a visible `working`)
#   never                      nothing changes
#   after_esc                  only a prompt sent after `pane send-keys … esc` is picked up
# `agent get` accepts the agent NAME (the pane id, for a nameless agent) only — the id the script
# must use. Live herdr takes either for an agent that has both; the stub is stricter on purpose.
# Fault flags (files in $STATE): get_broken · get_broken_after_send · get_fail_from=<n> (every
# `agent get` after the n-th) make the state unreadable; reject · ssh_fail · keys_fail break the
# prompt / hop / esc; esc_working makes esc leave the agent `working`. The exact prompt bytes the
# stub received are in $STATE/last_prompt.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/rd-say-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
fails=0
ok()  { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fails=$((fails + 1)); }
has() { grep -qF -- "$3" <<<"$2" && ok "$1" || bad "$1 — '$3' not in: $2"; }
lacks() { grep -qF -- "$3" <<<"$2" && bad "$1 — '$3' unexpectedly in: $2" || ok "$1"; }
calls() { grep -c -- "$1" "$STATE/calls.log" 2>/dev/null || true; }
expect_calls() { [ "$(calls "$2")" -eq "$3" ] && ok "$1" || bad "$1 — '$2' called $(calls "$2")×, want $3"; }

mkdir -p "$TMP/bin" "$TMP/state" "$TMP/home/.local/bin" "$TMP/xdg/secrets"
echo cache >"$TMP/xdg/secrets/backend"
cp "$HERE/remote-dev-fake-hc.sh" "$TMP/home/.local/bin/hc"
# launchd runs the core unless $STATE/no_core exists
cat >"$TMP/bin/launchctl" <<'STUB'
#!/usr/bin/env bash
[ -f "$STATE/no_core" ] && exit 113
echo "state = running"
STUB
chmod +x "$TMP/bin/launchctl" "$TMP/home/.local/bin/hc"
cat >"$TMP/bin/herdr" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$STATE/calls.log"
status=$(cat "$STATE/status"); sc=$(cat "$STATE/sc"); cs=$(cat "$STATE/cs")
agent_json() { n='"name":"worker",'; [ -f "$STATE/nameless" ] && n=""; echo "{${n}\"pane_id\":\"p-1\",\"cwd\":\"/x\",\"agent_status\":\"$status\",\"state_change_seq\":$sc,\"completion_seq\":$cs}"; }
case "$1 $2" in
  "status ") echo "status: running" ;;
  "agent list") echo "{\"result\":{\"agents\":[$(agent_json)]}}" ;;
  "agent get")
    want=worker; [ -f "$STATE/nameless" ] && want=p-1
    [ "$3" = "$want" ] || { echo "{\"error\":{\"code\":\"agent_not_found\"}}"; exit 1; }
    n=$(( $(cat "$STATE/get_n" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$STATE/get_n"
    broken=0
    [ -f "$STATE/get_broken" ] && broken=1
    [ -f "$STATE/get_broken_after_send" ] && [ -f "$STATE/sent" ] && broken=1
    [ -f "$STATE/get_fail_from" ] && [ "$n" -gt "$(cat "$STATE/get_fail_from")" ] && broken=1
    [ "$broken" = 1 ] && { echo '{"result":{"agent":{}}}'; exit 0; }
    echo "{\"result\":{\"agent\":$(agent_json)}}" ;;
  "agent prompt")
    [ -f "$STATE/ssh_fail" ] && { echo "ssh: connection reset" >&2; exit 255; }
    [ -f "$STATE/reject" ] && { echo '{"error":{"code":"agent_not_found"}}'; exit 0; }
    printf %s "$4" >"$STATE/last_prompt"; touch "$STATE/sent"
    mode=$(cat "$STATE/mode")
    [ "$mode" = after_esc ] && { [ -f "$STATE/esc_sent" ] && mode=working || mode=never; }
    case $mode in
      working|blocked) echo "$mode" >"$STATE/status"; echo $((sc + 1)) >"$STATE/sc" ;;
      done) echo done >"$STATE/status"; echo $((sc + 1)) >"$STATE/sc"; echo $((cs + 1)) >"$STATE/cs" ;;
    esac
    echo '{"result":{"type":"agent_prompted"}}' ;;
  "pane read") cat "$STATE/pane.txt" ;;
  "pane send-keys")
    [ -f "$STATE/keys_fail" ] && { echo '{"error":{"code":"pane_not_found"}}'; exit 0; }
    touch "$STATE/esc_sent"
    if [ -f "$STATE/esc_working" ]; then echo working >"$STATE/status"; fi ;;
esac
STUB
chmod +x "$TMP/bin/herdr"
# No real `factory` may answer (the mini has one in ~/.local/bin): drop every PATH dir that holds one.
clean_path=""; IFS=: read -ra dirs <<<"$PATH"
for d in "${dirs[@]}"; do [ -x "$d/factory" ] || clean_path+="${clean_path:+:}$d"; done
export PATH="$TMP/bin:$clean_path" STATE="$TMP/state" HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/xdg" \
  RD_SAY_SETTLE=0 RD_POLL_S=0 RD_SAY_WAIT_S=3
unset RD_DRY_RUN

# scenario <status> <mode> <pane text> [cs]
scenario() {
  rm -rf "${STATE:?}"/*   # the roster of hc is empty: the target is a classic herdr agent
  echo "$1" >"$STATE/status"; echo 10 >"$STATE/sc"; echo "${4:-0}" >"$STATE/cs"
  echo "$2" >"$STATE/mode"; printf '%s\n' "$3" >"$STATE/pane.txt"
}
say() { out=$(bash "$HERE/remote-dev.sh" say worker "$@" 2>&1); rc=$?; }
ends_ok()   { [ "$rc" -eq 0 ] && ok "exit 0" || bad "exit $rc: $out"; }
ends_fail() { [ "$rc" -ne 0 ] && ok "non-zero exit" || bad "reported success: $out"; has "says NOT delivered" "$out" "NOT delivered"; }

MODAL=$'earlier transcript\nsome output\n\n  Context low — Compact earlier to keep going?\n  1. Yes  2. No\n'

echo "delivered first try (agent enters working)"
scenario idle working "> "
say "go on"; ends_ok
has "says delivered" "$out" "delivered"
lacks "no dismissal" "$out" "dismissing"
expect_calls "prompt sent once" "agent prompt" 1
expect_calls "no keys sent" "send-keys" 0
has "state read by agent name" "$(cat "$STATE/calls.log")" "agent get worker"
expect_calls "never by pane id" "agent get p-1" 0

echo "fast answer: blocked, never seen working"
scenario idle blocked "> "
say "go on"; ends_ok
has "says delivered" "$out" "delivered"
expect_calls "prompt sent once" "agent prompt" 1

echo "fast answer: a fresh done (completion_seq bumps)"
scenario "done" "done" "> " 7
say "go on"; ends_ok
has "says delivered" "$out" "delivered"
expect_calls "prompt sent once" "agent prompt" 1

echo "modal present → dismissed → delivered"
scenario idle after_esc "$MODAL"
say "go on"; ends_ok
has "names the dismissed modal" "$out" 'delivered after dismissing the "compact earlier" prompt'
has "sends esc to the pane" "$(cat "$STATE/calls.log")" "pane send-keys p-1 esc"
expect_calls "re-sent exactly once" "agent prompt" 2

echo "never changes state, no known modal"
scenario idle never "> still waiting"
say "go on"; ends_fail
has "points at rd read" "$out" "rd read worker"
expect_calls "no blind re-send" "agent prompt" 1
expect_calls "no keys sent" "send-keys" 0

echo "modal text only in the transcript, not in the modal area"
scenario idle never "$(printf 'Compact earlier was mentioned here\n%s\n' "$(seq 1 20)")"
say "go on"; ends_fail
expect_calls "no keys sent" "send-keys" 0
expect_calls "no re-send" "agent prompt" 1

echo "modal dismissed but the agent still does not change state"
scenario idle never "$MODAL"
say "go on"; ends_fail
has "names the modal" "$out" 'the "compact earlier" prompt'
expect_calls "re-sent once, not more" "agent prompt" 2

echo "dismissing the modal fails"
scenario idle after_esc "$MODAL"; touch "$STATE/keys_fail"
say "go on"; ends_fail
has "says the dismissal failed" "$out" "dismissing it failed"
expect_calls "no re-send" "agent prompt" 1

echo "already working"
scenario working never "> "
say "go on"; ends_ok
has "says queued" "$out" "queued: agent busy"
expect_calls "prompt sent once" "agent prompt" 1

echo "state unreadable before the send"
scenario idle working "> "; touch "$STATE/get_broken"
say "go on"; ends_fail
has "says why" "$out" "could not read its state"
expect_calls "nothing sent" "agent prompt" 0

echo "herdr rejects the prompt"
scenario idle working "> "; touch "$STATE/reject"
say "go on"; ends_fail
has "says herdr rejected" "$out" "herdr rejected the prompt"

echo "transport failure (ssh exit 255)"
scenario idle working "> "; touch "$STATE/ssh_fail"
say "go on"; ends_fail
has "says transport failure" "$out" "transport failure"
lacks "not mistaken for a rejection" "$out" "rejected"
expect_calls "no retry" "agent prompt" 1

echo "modal dismissed and the agent was already working afterwards"
scenario idle after_esc "$MODAL"; touch "$STATE/esc_working"
say "go on"; ends_ok
has "says queued, not delivered" "$out" "queued after dismissing the \"compact earlier\" prompt"
lacks "not claimed as delivered" "$out" "delivered after"

echo "state becomes unreadable after the send"
scenario idle never "$MODAL"; touch "$STATE/get_broken_after_send"
say "go on"; ends_fail
has "says delivery unconfirmed" "$out" "unconfirmed"
expect_calls "never re-sent" "agent prompt" 1
expect_calls "no keys sent" "send-keys" 0

echo "exact bytes: trailing newlines, quotes, \$(…)"
scenario idle working "> "
text=$'line one \'quoted\' "dq" $(echo no) `no`\n\nlast line\n\n\n'
say "$text"; ends_ok
printf %s "$text" >"$STATE/want_prompt"
cmp -s "$STATE/want_prompt" "$STATE/last_prompt" && ok "prompt arrives byte-identical" || bad "prompt bytes differ: $(od -c "$STATE/last_prompt" | tail -3)"

echo "send, esc, then the state is unreadable before the re-send"
scenario idle after_esc "$MODAL"; echo 4 >"$STATE/get_fail_from"
say "go on"; ends_fail
has "says delivery unconfirmed" "$out" "delivery unconfirmed"
lacks "does not claim nothing was sent" "$out" "nothing was sent"
expect_calls "first send only" "agent prompt" 1

echo "nameless (hand-started) agent"
scenario idle working "> "; touch "$STATE/nameless"
out=$(bash "$HERE/remote-dev.sh" say p-1 "go on" 2>&1); rc=$?; ends_ok
has "says delivered" "$out" "delivered"
has "state read by pane id" "$(cat "$STATE/calls.log")" "agent get p-1"
lacks "never by a name it does not have" "$(cat "$STATE/calls.log")" "agent get worker"

echo "dry run"
scenario idle never "> "
out=$(RD_DRY_RUN=1 bash "$HERE/remote-dev.sh" say worker "go on" 2>&1); rc=$?
ends_ok
[ "$out" = "p-1" ] && ok "prints the resolved pane only" || bad "unexpected output: $out"
expect_calls "nothing sent" "agent prompt" 0

# --- hc: the target lives in herdr-core -------------------------------------------------------------------------
roster() { # <status-or-null> [name]
  local st=$1 name=${2:-worker}
  [ "$st" = null ] || st="{\"app\":\"claude-code\",\"state\":\"$st\"}"
  echo "[{\"address\":\"t5\",\"name\":\"$name\",\"cwd\":\"/x\",\"argv\":[\"claude\"],\"status\":$st,\"labels\":{}}]" >"$STATE/terminals.json"
}
hcreset() { rm -rf "${STATE:?}"/*; }
sent() { cat "$STATE/last_args" 2>/dev/null; }

echo "hc: idle agent gets the text through hc send"
hcreset; roster idle
say "go on"; ends_ok
has "says delivered" "$out" "delivered"
has "sent to its address" "$(cat "$STATE/calls.log")" "send -- t5 go on"
lacks "never forced past a dialog" "$(cat "$STATE/calls.log")" "--force"

echo "hc: working agent: the message is queued behind its turn"
hcreset; roster working
say "go on"; ends_ok
has "says queued" "$out" "queued: agent busy"
has "still sent once" "$(cat "$STATE/calls.log")" "send -- t5 go on"

echo "hc: a blocked agent is refused (the text would answer its dialog)"
hcreset; roster blocked
say "go on"; ends_fail
has "says why" "$out" "blocked on a dialog"
has "points at rd read" "$out" "rd read worker"
[ ! -e "$STATE/last_args" ] && ok "nothing was typed" || bad "typed into a blocked agent: $(sent)"

echo "hc: hc itself refuses -> NOT delivered"
hcreset; roster idle; touch "$STATE/send_fail"
say "go on"; ends_fail
has "says hc send failed" "$out" "hc send failed"

echo "hc: exact bytes, leading dash, quotes, newlines"
hcreset; roster idle
text=$'-dash \'quoted\' "dq" $(echo no) `no`\n\nlast line\n\n\n'
say "$text"; ends_ok
want=$(printf '%s\n%s\n%s\n' "--" "t5" "$text")
[ "$(sent)" = "${want%$'\n'}" ] && ok "arrives byte-identical after the address" || bad "bytes differ: $(sent | od -c | head -3)"

echo "hc: a send that times out is unconfirmed, never 'NOT delivered'"
if command -v timeout >/dev/null || command -v gtimeout >/dev/null; then
  hcreset; roster idle; touch "$STATE/send_hang"
  out=$(RD_HC_TIMEOUT_S=1 bash "$HERE/remote-dev.sh" say worker "go on" 2>&1); rc=$?
  [ "$rc" -ne 0 ] && ok "non-zero exit" || bad "reported success"
  has "says delivery unconfirmed" "$out" "delivery unconfirmed"
  has "advises rd read before retrying" "$out" "'rd read worker' before retrying"
  lacks "not claimed as undelivered" "$out" "NOT delivered"
fi

echo "hc: no status yet is not a prompt"
hcreset; roster null
say "go on"; ends_fail
has "says so" "$out" "not at a prompt yet"
[ ! -e "$STATE/last_args" ] && ok "nothing was typed" || bad "typed into an agent that has not reported"

echo "hc: never types into a shell"
hcreset
echo "[{\"address\":\"t5\",\"name\":\"worker\",\"cwd\":\"/x\",\"argv\":[\"/bin/zsh\",\"-l\"],\"status\":{\"state\":\"idle\"},\"labels\":{}}]" >"$STATE/terminals.json"
out=$(bash "$HERE/remote-dev.sh" say t5 "go on" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "a shell with a status: refused" || bad "typed into a shell: $out"
has "says so" "$out" "not claude"
[ ! -e "$STATE/last_args" ] && ok "nothing was typed" || bad "typed into a shell"
echo "[{\"address\":\"t5\",\"name\":\"worker\",\"cwd\":\"/x\",\"argv\":[\"/bin/zsh\",\"-l\"],\"foreground\":{\"argv\":[\"claude\"]},\"status\":{\"state\":\"idle\"},\"labels\":{}}]" >"$STATE/terminals.json"
say "go on"; ends_ok

echo "hc: a send that ends without an error answer is unconfirmed"
hcreset; roster idle; touch "$STATE/send_crash"
say "go on"; [ "$rc" -ne 0 ] && ok "non-zero exit" || bad "reported success"
has "unconfirmed" "$out" "delivery unconfirmed"
lacks "not claimed as undelivered" "$out" "NOT delivered"

echo "hc: resolves by repo name, address and cwd; a shell is no agent"
hcreset; roster idle
out=$(bash "$HERE/remote-dev.sh" say nope "go" 2>&1); rc=$?; [ "$rc" -ne 0 ] && ok "unknown token: error" || bad "unknown token accepted"
has "unknown token: lists the roster" "$out" "t5"
for tok in t5 worker /x x; do
  out=$(RD_DRY_RUN=1 bash "$HERE/remote-dev.sh" say "$tok" "go" 2>&1)
  [ "$tok" = x ] && { has "'x' (the cwd's basename) resolves" "$out" "t5"; continue; }
  [ "$out" = "t5" ] && ok "'$tok' resolves to t5" || bad "'$tok' -> $out"
done
echo "[{\"address\":\"t5\",\"name\":\"worker\",\"cwd\":\"/x\",\"argv\":[\"/bin/zsh\",\"-l\"],\"status\":null,\"labels\":{}}]" >"$STATE/terminals.json"
out=$(RD_DRY_RUN=1 bash "$HERE/remote-dev.sh" say worker "go" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "a plain shell is not an agent" || bad "a shell resolved: $out"
echo "[{\"address\":\"t5\",\"name\":\"a\",\"cwd\":\"/x\",\"argv\":[\"claude\"],\"status\":null,\"labels\":{}},{\"address\":\"t6\",\"name\":\"b\",\"cwd\":\"/x\",\"argv\":[\"claude\"],\"status\":null,\"labels\":{}}]" >"$STATE/terminals.json"
out=$(RD_DRY_RUN=1 bash "$HERE/remote-dev.sh" say x "go" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "two agents in one checkout: ask which" || bad "ambiguous token resolved: $out"
has "ambiguity lists both" "$out" "t6"

echo "hc: an address-like name (t7app) resolves through its escaped terminal name"
hcreset
esc="f-$(printf %s t7app | shasum -a 256 | cut -c1-12 | cut -c1-6)-t7app"
echo "[{\"address\":\"t5\",\"name\":\"$esc\",\"cwd\":\"/y\",\"argv\":[\"claude\"],\"status\":null,\"labels\":{}}]" >"$STATE/terminals.json"
out=$(RD_DRY_RUN=1 bash "$HERE/remote-dev.sh" say t7app "go" 2>&1)
[ "$out" = "t5" ] && ok "resolved" || bad "t7app -> $out"

echo "hc wins over classic for a token both know; classic answers what hc does not"
hcreset; roster idle
echo 10 >"$STATE/sc"; echo 0 >"$STATE/cs"; echo idle >"$STATE/status"; echo working >"$STATE/mode"
say "go on"; ends_ok
expect_calls "classic untouched when hc knows the target" "agent prompt" 0

echo "no core: error, hc is not called"
hcreset; touch "$STATE/no_core"
say "go on"; [ "$rc" -ne 0 ] && ok "refused" || bad "ran without a core"
has "names the fix" "$out" "launchctl kickstart"
[ ! -e "$STATE/hc-called" ] && ok "hc was not called" || bad "hc was called"

echo; [ "$fails" -eq 0 ] && echo "remote-dev-say: all passed" || { echo "remote-dev-say: $fails failed"; exit 1; }
