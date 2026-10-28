#!/usr/bin/env bash
# remote-dev-say.test — `rd say` delivery verification against a stubbed herdr. Property under
# test: a message that did not land can never look delivered. The stub models a pane whose agent
# either picks the prompt up (`agent wait --until working` succeeds), never does, or only does
# once a blocking modal has been dismissed with `pane send-keys … esc`.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/rd-say-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
fails=0
ok()  { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fails=$((fails + 1)); }
has() { grep -qF -- "$3" <<<"$2" && ok "$1" || bad "$1 — '$3' not in: $2"; }
lacks() { grep -qF -- "$3" <<<"$2" && bad "$1 — '$3' unexpectedly in: $2" || ok "$1"; }
count() { grep -c -- "$2" "$STATE/calls.log" 2>/dev/null || true; }

mkdir -p "$TMP/bin" "$TMP/state" "$TMP/home" "$TMP/xdg/secrets"
echo cache >"$TMP/xdg/secrets/backend"
cat >"$TMP/bin/herdr" <<'STUB'
#!/usr/bin/env bash
# $WAIT: ok = agent picks the prompt up · never = it never does · after_esc = only once esc was sent
echo "$*" >>"$STATE/calls.log"
case "$1 $2" in
  "status ") echo "status: running" ;;
  "agent list") cat "$STATE/agents.json" ;;
  "agent prompt") [ -f "$STATE/reject" ] && echo '{"error":{"code":"agent_not_found"}}' || echo '{"result":{"type":"agent_prompted"}}' ;;
  "agent wait")
    case "$(cat "$STATE/wait")" in
      ok) exit 0 ;;
      after_esc) [ -f "$STATE/esc_sent" ] && exit 0 || exit 1 ;;
      *) exit 1 ;;
    esac ;;
  "pane read") cat "$STATE/pane.txt" ;;
  "pane send-keys") touch "$STATE/esc_sent" ;;
esac
STUB
chmod +x "$TMP/bin/herdr"
export PATH="$TMP/bin:$PATH" STATE="$TMP/state" HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/xdg" RD_SAY_SETTLE=0
unset RD_DRY_RUN

# scenario <agent_status> <wait mode> <pane text>
scenario() {
  rm -f "$STATE/calls.log" "$STATE/esc_sent" "$STATE/reject"
  echo "{\"result\":{\"agents\":[{\"name\":\"worker\",\"pane_id\":\"p-1\",\"cwd\":\"/x\",\"agent_status\":\"$1\"}]}}" >"$STATE/agents.json"
  echo "$2" >"$STATE/wait"
  printf '%s\n' "$3" >"$STATE/pane.txt"
}
say() { out=$(bash "$HERE/remote-dev.sh" say worker "$@" 2>&1); rc=$?; }

echo "delivered first try"
scenario idle ok "> "
say "go on"
[ "$rc" -eq 0 ] && ok "exit 0" || bad "exit $rc: $out"
has "says delivered" "$out" "delivered"
lacks "no dismissal" "$out" "dismissing"
[ "$(count x 'agent prompt')" -eq 1 ] && ok "prompt sent once" || bad "prompt sent $(count x 'agent prompt')×"
[ "$(count x 'send-keys')" -eq 0 ] && ok "no keys sent" || bad "keys sent without a modal"

echo "modal present → dismissed → delivered"
scenario idle after_esc 'Context low — Compact earlier to keep going?'
say "go on"
[ "$rc" -eq 0 ] && ok "exit 0" || bad "exit $rc: $out"
has "names the dismissed modal" "$out" 'delivered after dismissing the "compact earlier" prompt'
has "sends esc to the pane" "$(cat "$STATE/calls.log")" "pane send-keys p-1 esc"
[ "$(count x 'agent prompt')" -eq 2 ] && ok "re-sent exactly once" || bad "prompt sent $(count x 'agent prompt')×"

echo "never leaves idle, no known modal"
scenario idle never "> still waiting"
say "go on"
[ "$rc" -ne 0 ] && ok "non-zero exit" || bad "reported success: $out"
has "says NOT delivered" "$out" "NOT delivered"
has "points at rd read" "$out" "rd read worker"
[ "$(count x 'agent prompt')" -eq 1 ] && ok "no blind re-send" || bad "prompt sent $(count x 'agent prompt')×"
[ "$(count x 'send-keys')" -eq 0 ] && ok "no keys sent" || bad "keys sent without a modal"

echo "modal dismissed but the agent still does not start"
scenario idle never 'Compact earlier?'
say "go on"
[ "$rc" -ne 0 ] && ok "non-zero exit" || bad "reported success: $out"
has "says NOT delivered" "$out" "NOT delivered"
has "names the modal" "$out" 'the "compact earlier" prompt'
[ "$(count x 'agent prompt')" -eq 2 ] && ok "re-sent once, not more" || bad "prompt sent $(count x 'agent prompt')×"

echo "already working"
scenario working never "> "
say "go on"
[ "$rc" -eq 0 ] && ok "exit 0" || bad "exit $rc: $out"
has "says queued" "$out" "queued: agent busy"
[ "$(count x 'agent prompt')" -eq 1 ] && ok "prompt sent once" || bad "prompt sent $(count x 'agent prompt')×"

echo "herdr rejects the prompt"
scenario idle ok "> "; touch "$STATE/reject"
say "go on"
[ "$rc" -ne 0 ] && ok "non-zero exit" || bad "reported success: $out"
has "says NOT delivered" "$out" "NOT delivered"

echo "dry run"
scenario idle never "> "
out=$(RD_DRY_RUN=1 bash "$HERE/remote-dev.sh" say worker "go on" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "exit 0" || bad "exit $rc: $out"
[ "$out" = "p-1" ] && ok "prints the resolved pane only" || bad "unexpected output: $out"
[ "$(count x 'agent prompt')" -eq 0 ] && ok "nothing sent" || bad "dry run sent a prompt"

echo; [ "$fails" -eq 0 ] && echo "remote-dev-say: all passed" || { echo "remote-dev-say: $fails failed"; exit 1; }
