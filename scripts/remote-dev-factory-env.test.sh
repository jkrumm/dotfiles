#!/usr/bin/env bash
# remote-dev-factory-env.test — every rd spawn (work, wave, fan) puts FACTORY_SESSION=<the agent name it
# gives the pane> into the pane at creation, through herdr's `--env` (the CLAUDE_CONFIG_DIR path), for both
# a new space and a new tab in an existing one. herdr is a stub that records each call; whatever happens
# after the create call (prompt delivery) is out of scope here, so the exit code is not asserted.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/rd-factory-env-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
fails=0
ok()  { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fails=$((fails + 1)); }
has() { grep -qF -- "$3" <<<"$2" && ok "$1" || bad "$1 — '$3' not in: $2"; }

S="$TMP/home/SourceRoot"
mkdir -p "$TMP/bin" "$TMP/state" "$S/dotfiles/scripts" "$S/myrepo/.git" "$TMP/xdg/secrets" "$TMP/home/.local/bin"
echo cache >"$TMP/xdg/secrets/backend"
printf '#!/usr/bin/env python3\n' >"$S/dotfiles/scripts/wave-gate.py"
# fan's helpers: the worktree script answers path / base / sha, the marker script is a no-op
printf '#!/usr/bin/env bash\necho "%s/myrepo-wt"\necho origin/master\necho abc1234\n' "$S" >"$S/dotfiles/scripts/fan-worktree.sh"
printf '#!/usr/bin/env bash\nexit 0\n' >"$S/dotfiles/scripts/fan-list.sh"
printf '#!/usr/bin/env bash\necho "unset CLAUDE_CONFIG_DIR"\n' >"$TMP/home/.local/bin/claude-account"
cat >"$TMP/bin/herdr" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$STATE/calls"
case "$1 $2" in
  "status ") echo "status: running" ;;
  "agent list") echo '{"result":{"agents":[]}}' ;;
  "tab list") echo '{"result":{"tabs":[]}}' ;;
  "workspace list") cat "$STATE/workspaces.json" ;;
  "tab create"|"workspace create")
    echo '{"result":{"workspace":{"workspace_id":"w1"},"root_pane":{"pane_id":"w1:1","tab_id":"t1"}}}' ;;
  "agent start") echo '{"type":"agent_started"}' ;;
  *) echo '{}' ;;
esac
STUB
chmod +x "$TMP/bin/herdr" "$TMP/home/.local/bin/claude-account" "$S/dotfiles/scripts/"*.sh
export PATH="$TMP/bin:$PATH" STATE="$TMP/state" HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/xdg" \
  RD_DELIVER_WAIT_S=0 RD_POLL_S=0
unset RD_DRY_RUN FACTORY_SESSION
printf 'Branch: feat/some-change\n\nDo the thing.\n' >"$TMP/brief.md"

# fsess: the FACTORY_SESSION value on the recorded create call (herdr sees it with the quotes already stripped)
fsess() { sed -n 's/.*--env FACTORY_SESSION=\([^ ]*\).*/\1/p' <<<"$create"; }
is() { [ "$2" = "$3" ] && ok "$1" || bad "$1 — expected '$3', got '$2'"; }

# run <rd args…>: the create call herdr saw (tab/workspace create), with an empty or one-space roster
run() { # $1 = no-space|space, rest = rd args
  local shape=$1; shift
  : >"$STATE/calls"
  if [[ $shape == space ]]; then echo '{"result":{"workspaces":[{"workspace_id":"w1","label":"myrepo"}]}}' >"$STATE/workspaces.json"
  else echo '{"result":{"workspaces":[]}}' >"$STATE/workspaces.json"; fi
  timeout 60 bash "$HERE/remote-dev.sh" "$@" >/dev/null 2>&1 </dev/null
  create=$(grep -E '^(tab|workspace) create' "$STATE/calls" | head -1)
}

echo "work"
run no-space work myrepo
is "workspace create carries FACTORY_SESSION=<agent>" "$(fsess)" "myrepo"

echo "wave"
run no-space wave myrepo "adhoc task"
has "new space: workspace create" "$create" "workspace create"
is "new space: FACTORY_SESSION is the wave agent name" "$(fsess)" "myrepo-w1"
run space wave myrepo "Execute the active wave (Wave 4)"
has "existing space: tab create" "$create" "tab create"
is "existing space: FACTORY_SESSION is the plan's wave agent name" "$(fsess)" "myrepo-w4"

echo "fan"
run no-space fan myrepo "$TMP/brief.md"
is "new space: FACTORY_SESSION is <repo>-<branch leaf>" "$(fsess)" "myrepo-some-change"
run space fan myrepo "$TMP/brief.md"
has "existing space: tab create" "$create" "tab create"
is "existing space: FACTORY_SESSION is <repo>-<branch leaf>" "$(fsess)" "myrepo-some-change"

echo "the agent that is started carries the same name"
start=$(grep -E '^agent start' "$STATE/calls" | head -1)
has "agent start uses the fan agent name" "$start" "agent start myrepo-some-change"

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; } || { echo "$fails failed"; exit 1; }
