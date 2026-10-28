#!/usr/bin/env bash
# remote-dev-say.test — `rd say` delivery verification against a stubbed herdr. Property under
# test: a message that did not land can never look delivered, and one that did land is never
# reported lost (which would invite a duplicate). The stub keeps an agent's status plus its
# state_change_seq/completion_seq; `agent prompt` changes them according to $STATE/mode:
#   working | blocked | done   the agent picked the prompt up and ended in that state (fast answers
#                              are `blocked` / a fresh `done`, never a visible `working`)
#   never                      nothing changes
#   after_esc                  only a prompt sent after `pane send-keys … esc` is picked up
# `agent get` accepts the agent NAME only — the id the script must use, as deliver_prompt does.
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

mkdir -p "$TMP/bin" "$TMP/state" "$TMP/home" "$TMP/xdg/secrets"
echo cache >"$TMP/xdg/secrets/backend"
cat >"$TMP/bin/herdr" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$STATE/calls.log"
status=$(cat "$STATE/status"); sc=$(cat "$STATE/sc"); cs=$(cat "$STATE/cs")
agent_json() { echo "{\"name\":\"worker\",\"pane_id\":\"p-1\",\"cwd\":\"/x\",\"agent_status\":\"$status\",\"state_change_seq\":$sc,\"completion_seq\":$cs}"; }
case "$1 $2" in
  "status ") echo "status: running" ;;
  "agent list") echo "{\"result\":{\"agents\":[$(agent_json)]}}" ;;
  "agent get")
    [ "$3" = worker ] || { echo "{\"error\":{\"code\":\"agent_not_found\"}}"; exit 1; }
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
export PATH="$TMP/bin:$PATH" STATE="$TMP/state" HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/xdg" \
  RD_SAY_SETTLE=0 RD_POLL_S=0 RD_SAY_WAIT_S=3
unset RD_DRY_RUN

# scenario <status> <mode> <pane text> [cs]
scenario() {
  rm -f "$STATE"/{calls.log,esc_sent,reject,ssh_fail,keys_fail,get_broken,get_broken_after_send,get_fail_from,get_n,sent,last_prompt,esc_working}
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

echo "deliver_prompt (rd wave / rd fan) shares the primitive"
export RD_DELIVER_WAIT_S=3
deliver() { res=$( ( source "$HERE/remote-dev.sh"; deliver_prompt p-1 worker "hello"; rc=$?; echo "rc=$rc"; echo "err=$DELIVER_ERR" ) 2>&1 ); }
scenario idle blocked "> ";  deliver
has "fast blocked answer: delivered" "$res" "rc=0"
expect_calls "sent once" "agent prompt" 1
scenario idle never "> ";    deliver
has "never picked up: rc 1" "$res" "rc=1"
expect_calls "re-sent once after an observed no-change" "agent prompt" 2
scenario idle working "> ";  touch "$STATE/get_broken"; deliver
has "unreadable before any send: rc 4" "$res" "rc=4"
has "claims nothing was sent" "$res" "nothing was sent"
expect_calls "nothing sent" "agent prompt" 0
scenario idle never "> ";    touch "$STATE/get_broken_after_send"; deliver
has "unreadable after the send: rc 4" "$res" "rc=4"
has "says delivery unconfirmed" "$res" "delivery unconfirmed"
lacks "does not claim nothing was sent" "$res" "nothing was sent"
lacks "does not say rejected" "$res" "rejected"
expect_calls "never re-sent" "agent prompt" 1
scenario idle never "> ";    echo 4 >"$STATE/get_fail_from"; deliver
has "unreadable before the re-send: rc 4" "$res" "rc=4"
has "first send is remembered" "$res" "delivery unconfirmed"
expect_calls "not re-sent blind" "agent prompt" 1
scenario idle working "> ";  touch "$STATE/reject"; deliver
has "rejected: rc 2" "$res" "rc=2"
scenario idle working "> ";  touch "$STATE/ssh_fail"; deliver
has "transport failure: rc 3" "$res" "rc=3"
has "reported as transport failure" "$res" "transport failure"
lacks "not as a rejection" "$res" "rejected"
unset RD_DELIVER_WAIT_S

echo "dry run"
scenario idle never "> "
out=$(RD_DRY_RUN=1 bash "$HERE/remote-dev.sh" say worker "go on" 2>&1); rc=$?
ends_ok
[ "$out" = "p-1" ] && ok "prints the resolved pane only" || bad "unexpected output: $out"
expect_calls "nothing sent" "agent prompt" 0

echo; [ "$fails" -eq 0 ] && echo "remote-dev-say: all passed" || { echo "remote-dev-say: $fails failed"; exit 1; }
