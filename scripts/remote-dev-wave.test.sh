#!/usr/bin/env bash
# remote-dev-wave.test — `rd wave` agent naming against a stubbed herdr. Property under test: a
# spawn without "(Wave <n>)" skips every counter number whose `<repo>-w<n>` is a live agent name,
# and an explicit "(Wave <n>)" whose name is live dies instead of spawning a duplicate.
# RD_DRY_RUN=1 stops before anything is created, so only the naming decision is exercised.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/rd-wave-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
fails=0
ok()  { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fails=$((fails + 1)); }
has() { grep -qF -- "$3" <<<"$2" && ok "$1" || bad "$1 — '$3' not in: $2"; }
lacks() { grep -qF -- "$3" <<<"$2" && bad "$1 — '$3' unexpectedly in: $2" || ok "$1"; }

# A scratch HOME: the repo to resolve, a no-op green gate, and the "on the dev host" marker so
# host_run executes locally against the herdr stub.
mkdir -p "$TMP/bin" "$TMP/state" "$TMP/home/SourceRoot/dotfiles/scripts" "$TMP/home/SourceRoot/myrepo/.git" "$TMP/xdg/secrets" "$TMP/home/.local/bin"
echo cache >"$TMP/xdg/secrets/backend"
printf '#!/usr/bin/env python3\n' >"$TMP/home/SourceRoot/dotfiles/scripts/wave-gate.py"
cat >"$TMP/bin/herdr" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "status ") echo "status: running" ;;
  "agent list") cat "$STATE/agents.json" ;;
  "workspace list") echo '{"result":{"workspaces":[{"workspace_id":"w1","label":"myrepo"}]}}' ;;
  "tab list") cat "$STATE/tabs.json" ;;
esac
STUB
# The account picker is the real machine state otherwise (it can answer "spill"); pin it to the default account.
printf '#!/usr/bin/env bash\necho "unset CLAUDE_CONFIG_DIR"\n' >"$TMP/home/.local/bin/claude-account"
chmod +x "$TMP/bin/herdr" "$TMP/home/.local/bin/claude-account"
export PATH="$TMP/bin:$PATH" STATE="$TMP/state" HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/xdg" RD_DRY_RUN=1

# agents <name…>: a roster with one live, named agent per argument
agents() {
  local json="" a
  for a in "$@"; do json+="${json:+,}{\"name\":\"$a\",\"pane_id\":\"p-$a\",\"cwd\":\"/elsewhere\",\"agent_status\":\"idle\"}"; done
  echo "{\"result\":{\"agents\":[$json]}}" >"$STATE/agents.json"
}
tabs() { # wave tab numbers open in the space
  local json="" n
  for n in "$@"; do json+="${json:+,}{\"label\":\"wave $n\"}"; done
  echo "{\"result\":{\"tabs\":[$json]}}" >"$STATE/tabs.json"
}
wave() { out=$(bash "$HERE/remote-dev.sh" wave myrepo "$@" 2>&1); rc=$?; }

echo "counter-based number (no Wave token)"
agents; tabs
wave "adhoc task"
has "empty roster: -w1" "$out" "agent 'myrepo-w1'"
agents myrepo-w1; tabs
wave "adhoc task"
has "live myrepo-w1 (no tab): skips to -w2" "$out" "agent 'myrepo-w2'"
lacks "does not reuse the live name" "$out" "agent 'myrepo-w1'"
agents myrepo-w1 myrepo-w2; tabs
wave "adhoc task"
has "live -w1 and -w2: skips to -w3" "$out" "agent 'myrepo-w3'"
agents myrepo-w2; tabs 1
wave "adhoc task"
has "tab 1 open, -w2 live: next free is -w3" "$out" "agent 'myrepo-w3'"

echo "explicit (Wave <n>) token"
agents; tabs
wave "Execute the active wave (Wave 4)"
has "free name: plan number wins" "$out" "agent 'myrepo-w4'"
agents myrepo-w4; tabs
wave "Execute the active wave (Wave 4)"
[ "$rc" -ne 0 ] && ok "live name: refused" || bad "live name: spawn accepted"
has "live name: says which agent" "$out" "agent 'myrepo-w4' is already live"

echo "unreadable roster"
echo 'not json' >"$STATE/agents.json"; tabs
wave "adhoc task"
[ "$rc" -ne 0 ] && ok "unparseable roster: refused" || bad "unparseable roster: spawn accepted"
has "unparseable roster: says so" "$out" "could not read the agent roster"
echo '{"result":{"agents":"nope"}}' >"$STATE/agents.json"
wave "adhoc task"
[ "$rc" -ne 0 ] && ok "non-list agents: refused" || bad "non-list agents: spawn accepted"
has "non-list agents: says so" "$out" "could not read the agent roster"

echo; [ "$fails" -eq 0 ] && echo "remote-dev-wave: all passed" || { echo "remote-dev-wave: $fails failed"; exit 1; }
