#!/usr/bin/env bash
# factory-hooks.test — the software-factory hooks (source: $FACTORY_DIR/integrations/claude-code/hooks.json, never the
# template): registered for every event and matcher, once each, rendered into every account dir by the real
# `_render-settings` merge (fresh dir, a dir with a stale settings.json, a re-render), existing hooks untouched, a
# missing hooks.json = warning and the render still succeeds without them, and the hook command itself never blocks or fails a session
# (no FACTORY_SESSION = nothing runs; no `factory` on PATH or a failing `factory` = still exit 0; a send-back from `factory hook stop` (rc 2) exits 2).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/factory-hooks-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
fails=0
ok()  { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fails=$((fails + 1)); }
is()  { [ "$2" = "$3" ] && ok "$1" || bad "$1 — expected '$3', got '$2'"; }

# hook_cmd <settings.json> <event> <matcher|-> : the factory command registered for that event/matcher
hook_cmd() {
  jq -r --arg e "$2" --arg m "$3" '
    [.hooks[$e][]? | select((.matcher // "-") == $m) | .hooks[]?.command | select(contains("factory hook"))] | first // empty' "$1"
}
# expect_hook <settings.json> <event> <matcher|-> <matcher|""> <factory sub-event>
expect_hook() {
  is "$(basename "$(dirname "$1")"): $2${4:+ ($4)} -> factory hook $5" \
    "$(hook_cmd "$1" "$2" "${4:--}" | sed -n 's/.*factory hook \([a-z-]*\);.*/\1/p')" "$5"
}

# The factory checkout when present, else a fixture of the same shape (the six entries) in the temp dir.
FACTORY_DIR="${FACTORY_DIR:-$HOME/SourceRoot/software-factory}"
if [ -f "$FACTORY_DIR/integrations/claude-code/hooks.json" ]; then
  echo "factory hooks: $FACTORY_DIR (real checkout)"
else
  FACTORY_DIR="$TMP/factory"; mkdir -p "$FACTORY_DIR/integrations/claude-code"
  g='[ -n \"$FACTORY_SESSION\" ] && command -v factory >/dev/null'
  jq -n --arg g "$g" --arg stop "$g || exit 0; factory hook stop; [ \$? -eq 2 ] && exit 2; exit 0" '
    def e(m; c): ({hooks: [{type: "command", command: c, timeout: 5}]} + (if m then {matcher: m} else {} end));
    def one(ev): e(null; ($g | gsub("\\\\\""; "\"")) + " && factory hook " + ev + "; exit 0");
    {hooks: {
      SessionStart: [one("session-start")], UserPromptSubmit: [one("user-prompt-submit")],
      Stop: [e(null; ($stop | gsub("\\\\\""; "\"")))],
      StopFailure: [e(null;($g | gsub("\\\\\""; "\"")) + " && factory hook stop-failure; exit 0")],
      Notification: [e("permission_prompt|idle_prompt|quota_auto_resume_fired|quota_auto_resume_stale|quota_auto_resume_disabled"; ($g | gsub("\\\\\""; "\"")) + " && factory hook notification; exit 0")],
      SessionEnd: [one("session-end")]}}' >"$FACTORY_DIR/integrations/claude-code/hooks.json"
  echo "factory hooks: fixture in $FACTORY_DIR (no checkout found)"
fi
HOOKS_JSON="$FACTORY_DIR/integrations/claude-code/hooks.json"
render() { make -s -C "$ROOT" _render-settings SETTINGS_DIR="$1" DOTFILES_DIR="$ROOT" FACTORY_DIR="${2:-$FACTORY_DIR}" 2>&1; }

# 1. The real merge, into a fresh dir and over a stale settings.json that carries an old hook set
#    (including the factory entries the template used to hold inline).
echo "render: fresh dir, merge over a stale settings.json, a re-render"
mkdir -p "$TMP/fresh" "$TMP/stale"
jq '{model: "opus", hooks: ({Stop: [{hooks: [{type: "command", command: "echo stale"}]}]} * .hooks)}' "$HOOKS_JSON" >"$TMP/stale/settings.json"
for d in fresh stale; do
  render "$TMP/$d" >/dev/null && ok "$d: _render-settings ran" || bad "$d: _render-settings failed"
done
render "$TMP/stale" >/dev/null && ok "stale: second render ran" || bad "stale: second render failed"
is "stale: the merge kept the live model" "$(jq -r .model "$TMP/stale/settings.json")" "opus"
is "stale: template hooks replace the stale ones" "$(jq -r '[.hooks.Stop[].hooks[].command] | map(select(. == "echo stale")) | length' "$TMP/stale/settings.json")" "0"

# 2. Every event/matcher, in both renders.
for d in fresh stale; do
  f="$TMP/$d/settings.json"
  expect_hook "$f" SessionStart - "" session-start
  expect_hook "$f" UserPromptSubmit - "" user-prompt-submit
  expect_hook "$f" Stop - "" stop
  expect_hook "$f" StopFailure - "" stop-failure
  expect_hook "$f" SessionEnd - "" session-end
  for m in permission_prompt idle_prompt quota_auto_resume_fired quota_auto_resume_stale quota_auto_resume_disabled; do
    is "$d: Notification matcher covers $m" \
      "$(jq -r --arg m "$m" '[.hooks.Notification[] | select((.matcher // "") | split("|") | index($m))] | length' "$f")" "1"
  done
  is "$d: Notification -> factory hook notification" \
    "$(jq -r '.hooks.Notification[].hooks[].command' "$f" | sed -n 's/.*factory hook \([a-z-]*\);.*/\1/p')" "notification"
  # exactly the factory's entries, once each (identical entries are not duplicated by a re-render or a stale copy)
  is "$d: factory events carry exactly the hooks.json entries" \
    "$(jq -c --slurpfile f "$HOOKS_JSON" '[. as $s | $f[0].hooks | keys[] as $e | ([$s.hooks[$e][]? | select(any(.hooks[]?; (.command // "") | contains("factory hook")))] | length)]' "$f")" \
    "$(jq -c '[.hooks | keys[] as $e | (.[$e] | length)]' "$HOOKS_JSON")"
  # existing hooks untouched
  for h in protect-branches docker-makefile model-discipline iu-model-guard session-env machine-role; do
    is "$d: existing hook $h still registered" \
      "$(jq -r --arg h "$h" '[.hooks[][]?.hooks[]?.command | select(contains($h))] | length > 0' "$f")" "true"
  done
done

# 2b. hooks.json missing: a visible warning, the render succeeds, no factory hook, the rest intact.
echo "hooks.json missing"
mkdir -p "$TMP/nofactory"
out=$(render "$TMP/nofactory" "$TMP/no-such-factory"); rc=$?
is "missing hooks.json: the render succeeds" "$rc" 0
case "$out" in *"factory hooks not installed: $TMP/no-such-factory/integrations/claude-code/hooks.json missing"*) ok "missing hooks.json: warning printed";; *) bad "missing hooks.json: no warning in '$out'";; esac
is "missing hooks.json: no factory hook rendered" "$(jq -r '[.hooks[][]?.hooks[]?.command | select(contains("factory hook"))] | length' "$TMP/nofactory/settings.json")" 0
is "missing hooks.json: the other hooks are there" "$(jq -r '[.hooks[][]?.hooks[]?.command | select(contains("protect-branches"))] | length > 0' "$TMP/nofactory/settings.json")" true

# 3. Every enabled registry account gets the template through claude-accounts-setup's per-dir render.
echo "registry: claude-accounts-setup renders settings for every account dir"
dirs=$(jq -r '.accounts[] | select(.dir != null) | .dir' "$ROOT/config/claude-accounts.json" | wc -l | tr -d ' ')
renders=$(grep -c '_render-settings SETTINGS_DIR="\$\$dir"' "$ROOT/Makefile")
[ "$dirs" -ge 1 ] && [ "$renders" -ge 1 ] && ok "$dirs account dir(s) in the registry, rendered by the setup loop" \
  || bad "setup loop does not render settings per registry dir (dirs=$dirs renders=$renders)"

# 4. The hook command: never fails, silent for the owner's own sessions; only the factory's send-back (rc 2) blocks.
echo "hook command behaviour"
cmd=$(hook_cmd "$TMP/fresh/settings.json" Stop -)
mkdir -p "$TMP/bin-ok" "$TMP/bin-fail" "$TMP/bin-back" "$TMP/bin-none"
printf '#!/bin/sh\necho "$@" >> "$CALLS"\n' >"$TMP/bin-ok/factory"
printf '#!/bin/sh\necho "$@" >> "$CALLS"\nexit 7\n' >"$TMP/bin-fail/factory"
printf '#!/bin/sh\necho "$@" >> "$CALLS"\nexit 2\n' >"$TMP/bin-back/factory"
chmod +x "$TMP/bin-ok/factory" "$TMP/bin-fail/factory" "$TMP/bin-back/factory"
# /usr/bin:/bin keeps `command`, `test` and `sh` resolvable while keeping any real factory off PATH.
BASE=/usr/bin:/bin
run_hook() { # <bindir> <FACTORY_SESSION or ->  -> sets rc, calls
  : >"$TMP/calls"
  if [ "$2" = - ]; then
    env -u FACTORY_SESSION CALLS="$TMP/calls" PATH="$1:$BASE" sh -c "$cmd" >/dev/null 2>&1; rc=$?
  else
    env FACTORY_SESSION="$2" CALLS="$TMP/calls" PATH="$1:$BASE" sh -c "$cmd" >/dev/null 2>&1; rc=$?
  fi
  calls=$(cat "$TMP/calls")
}
run_hook "$TMP/bin-ok" -;      is "no FACTORY_SESSION: exit 0" "$rc" 0;       is "no FACTORY_SESSION: factory not run" "$calls" ""
run_hook "$TMP/bin-ok" "";     is "empty FACTORY_SESSION: exit 0" "$rc" 0;    is "empty FACTORY_SESSION: factory not run" "$calls" ""
run_hook "$TMP/bin-ok" myrepo-w1; is "session set: exit 0" "$rc" 0;           is "session set: factory hook stop" "$calls" "hook stop"
run_hook "$TMP/bin-none" myrepo-w1; is "factory not installed: exit 0" "$rc" 0
run_hook "$TMP/bin-fail" myrepo-w1; is "factory fails (rc 7): the hook still exits 0" "$rc" 0
is "factory fails: it was called" "$calls" "hook stop"
run_hook "$TMP/bin-back" myrepo-w1; is "factory sends the stop back (rc 2): the hook exits 2" "$rc" 2

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; } || { echo "$fails failed"; exit 1; }
