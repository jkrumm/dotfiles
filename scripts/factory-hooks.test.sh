#!/usr/bin/env bash
# factory-hooks.test — the software-factory hooks in config/settings.template.json: registered for every event
# and matcher, rendered into every account dir by the real `_render-settings` merge (fresh dir and a dir with a
# stale settings.json), existing hooks untouched, and the hook command itself never blocks or fails a session
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

# 1. The real merge, into a fresh dir and over a stale settings.json that carries an old hook set.
echo "render: fresh dir and merge over a stale settings.json"
mkdir -p "$TMP/fresh" "$TMP/stale"
echo '{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo stale"}]}]}}' >"$TMP/stale/settings.json"
for d in fresh stale; do
  make -s -C "$ROOT" _render-settings SETTINGS_DIR="$TMP/$d" DOTFILES_DIR="$ROOT" >/dev/null 2>&1 \
    && ok "$d: _render-settings ran" || bad "$d: _render-settings failed"
done
is "stale: the merge kept the live model" "$(jq -r .model "$TMP/stale/settings.json")" "opus"
is "stale: template hooks replace the stale ones" "$(jq -r '[.hooks.Stop[].hooks[].command] | map(select(. == "echo stale")) | length' "$TMP/stale/settings.json")" "0"

# 2. Every event/matcher, in both renders.
for d in fresh stale; do
  f="$TMP/$d/settings.json"
  expect_hook "$f" SessionStart - "" session-start
  expect_hook "$f" UserPromptSubmit - "" user-prompt-submit
  expect_hook "$f" Stop - "" stop
  expect_hook "$f" StopFailure rate_limit rate_limit stop-failure
  expect_hook "$f" SessionEnd - "" session-end
  for m in permission_prompt idle_prompt quota_auto_resume_fired quota_auto_resume_stale quota_auto_resume_disabled; do
    is "$d: Notification matcher covers $m" \
      "$(jq -r --arg m "$m" '[.hooks.Notification[] | select((.matcher // "") | split("|") | index($m))] | length' "$f")" "1"
  done
  is "$d: Notification -> factory hook notification" \
    "$(jq -r '.hooks.Notification[].hooks[].command' "$f" | sed -n 's/.*factory hook \([a-z-]*\);.*/\1/p')" "notification"
  # existing hooks untouched
  for h in protect-branches docker-makefile model-discipline iu-model-guard session-env machine-role; do
    is "$d: existing hook $h still registered" \
      "$(jq -r --arg h "$h" '[.hooks[][]?.hooks[]?.command | select(contains($h))] | length > 0' "$f")" "true"
  done
done

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
