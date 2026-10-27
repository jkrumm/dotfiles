#!/usr/bin/env bash
# claude-launcher.test.sh — regression harness for the `claude` shell function and the account
# marker contract (config/zsh/claude-auth.zsh + claude.zsh, remote-dev.sh pick_account + herdr --env).
#
# Hermetic: HOME/XDG_CONFIG_HOME are scratch dirs, `claude`, `claude-account`, `secrets-run` and
# `herdr` are stubs on PATH. The stub `claude-account pick` appends one line per call to a pick
# log, so "one pick-log line per spawn" is counted, not argued. Never starts a real agent.
#
# Usage: scripts/claude-launcher.test.sh   (exit 0 = all pass)

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZDIR="$HERE/../config/zsh"
AUTH="$ZDIR/claude-auth.zsh"
LAUNCH="$ZDIR/claude.zsh"
RD="$HERE/remote-dev.sh"

pass=0
fail=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; [[ -n "${2:-}" ]] && printf '         %s\n' "$2"; fail=$((fail + 1)); }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
assert_contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "[$3] does not contain [$2]" ;; esac; }
assert_not_contains() { case "$3" in *"$2"*) bad "$1" "[$3] contains [$2]" ;; *) ok "$1" ;; esac; }

command -v zsh >/dev/null || { echo "✗ zsh not found"; exit 2; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/claude-launcher-test.XXXXXX")" || exit 2
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home" "$TMP/xdg/secrets" "$TMP/work"
ME="$TMP/home/.claude-me" # the registry's `me` dir, relative to the scratch HOME
PICKS="$TMP/picks"; CALLS="$TMP/calls"

cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
if [[ ${1-} == auth ]]; then
  if [[ ${STUB_LOGGED_IN:-1} == 1 ]]; then echo '{"loggedIn": true}'; else echo '{"loggedIn": false}'; fi
  exit 0
fi
echo "RAN cfg=${CLAUDE_CONFIG_DIR-unset} picked=${CLAUDE_ACCOUNT_PICKED-unset} tok=${CLAUDE_CODE_OAUTH_TOKEN:+set} reason=${CLAUDE_ACCOUNT_REASON-unset} args=$*"
EOF
cat > "$TMP/bin/claude-account" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$STUB_CALLS"
case ${1-} in
  pick)
    lane=""; why=0
    while (( $# )); do [[ $1 == --lane ]] && lane=$2; [[ $1 == --why ]] && why=1; shift; done
    echo "$lane" >> "$STUB_PICKS"
    [[ -n ${STUB_PICK_SILENT-} ]] && exit "${STUB_PICK_RC:-1}"
    echo "${STUB_PICK_LINE:-unset CLAUDE_CONFIG_DIR}"
    (( why )) && echo "# picked=${STUB_PICK_ID:-iu} reason=${STUB_PICK_REASON:-test} stale=false"
    exit "${STUB_PICK_RC:-0}" ;;
  latest) [[ -n ${STUB_LATEST-} ]] && { echo "$STUB_LATEST"; exit 0; }; exit 1 ;;
  session) [[ -n ${STUB_SESSION-} ]] && { echo "$STUB_SESSION"; exit 0; }; exit 1 ;;
  env) case $2 in me) echo "export CLAUDE_CONFIG_DIR='$HOME/.claude-me'" ;; iu) echo "unset CLAUDE_CONFIG_DIR" ;; *) exit 1 ;; esac ;;
esac
EOF
cat > "$TMP/bin/secrets-run" <<'EOF'
#!/usr/bin/env bash
echo "stub-token"
EOF
cat > "$TMP/bin/herdr" <<'EOF'
#!/usr/bin/env bash
# `herdr pane run <pane> <cmd…>`: record the command as the pane's startup lines;
# `herdr … create --env K=V …`: record the spawn-time env
[[ ${1-} == pane && ${2-} == run ]] && { shift 3; echo "$*" >> "$STUB_PANE"; }
while (( $# )); do [[ $1 == --env ]] && echo "$2" >> "$STUB_ENVS"; shift; done
exit 0
EOF
chmod +x "$TMP/bin/"*

# The harness may itself run inside a picked session: scrub everything the contract reads.
unset CLAUDE_CONFIG_DIR CLAUDE_ACCOUNT_PICKED CLAUDE_ACCOUNT_REASON USAGE_LANE CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY
export STUB_PICKS="$PICKS" STUB_CALLS="$CALLS" STUB_PANE="$TMP/pane.rc" STUB_ENVS="$TMP/pane.env"

reset() { : > "$PICKS"; : > "$CALLS"; : > "$STUB_PANE"; : > "$STUB_ENVS"; }
picks() { wc -l < "$PICKS" | tr -d ' '; }
# Run a snippet in a scratch zsh. $1 = interactive|plain, $2 = snippet; extra env via the caller's `env`-style prefix.
zrun() {
  local mode=$1 snippet=$2 flags=-fc
  [[ $mode == interactive ]] && flags=-fic
  ( cd "${ZCWD:-$TMP/work}" && HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/xdg" PATH="$TMP/bin:$PATH" \
      zsh $flags "source '$AUTH'; source '$LAUNCH'; $snippet" 2>&1 )
}
echo "not-cache" > "$TMP/xdg/secrets/backend"

echo "bare claude, marker unset"
reset; out=$(STUB_PICK_LINE="export CLAUDE_CONFIG_DIR='$ME'" STUB_PICK_ID=me zrun interactive 'claude --dangerously-skip-permissions --model sonnet')
assert_contains "interactive claude runs on the picked account" "cfg=$ME picked=me" "$out"
assert_eq "exactly one pick" 1 "$(picks)"
assert_eq "default lane is interactive" interactive "$(head -1 "$PICKS")"

reset; out=$(USAGE_LANE=wave zrun interactive 'claude')
assert_eq "USAGE_LANE becomes the pick lane" wave "$(head -1 "$PICKS")"
assert_contains "iu pick is marked as chosen" "cfg=unset picked=iu" "$out"

echo "marker set -> no pick"
reset; out=$(CLAUDE_ACCOUNT_PICKED=iu zrun interactive 'claude --foo')
assert_eq "marker iu (CLAUDE_CONFIG_DIR unset): no pick" 0 "$(picks)"
assert_contains "marker survives into the binary" "cfg=unset picked=iu" "$out"
reset; out=$(CLAUDE_ACCOUNT_PICKED=me CLAUDE_CONFIG_DIR=$ME zrun interactive 'claude --foo')
assert_eq "marker me: no pick" 0 "$(picks)"
assert_contains "pane dir untouched" "cfg=$ME picked=me" "$out"

echo "stale marker (inconsistent with CLAUDE_CONFIG_DIR) is ignored"
reset; out=$(CLAUDE_ACCOUNT_PICKED=me zrun interactive 'claude --foo')
assert_eq "marker me + CLAUDE_CONFIG_DIR unset: picks" 1 "$(picks)"
reset; out=$(CLAUDE_ACCOUNT_PICKED=iu CLAUDE_CONFIG_DIR=$ME zrun interactive 'claude --foo')
assert_eq "marker iu + a me dir: picks" 1 "$(picks)"
reset; out=$(CLAUDE_ACCOUNT_PICKED=nobody zrun interactive 'claude --foo')
assert_eq "marker for an unregistered id: picks" 1 "$(picks)"
reset; out=$(CLAUDE_ACCOUNT_PICKED=me CLAUDE_CONFIG_DIR=$ME/ zrun interactive 'claude --foo')
assert_eq "marker me + trailing-slash dir: still consistent, no pick" 0 "$(picks)"

echo "resume pins the session's account"
for form in '--resume 1234-abcd' '-r 1234-abcd' '--resume=1234-abcd'; do
  reset; out=$(STUB_SESSION=me zrun interactive "claude $form")
  assert_contains "claude $form -> session account" "cfg=$ME picked=me" "$out"
  assert_eq "claude $form: no pick" 0 "$(picks)"
done
reset; out=$(zrun interactive 'claude --resume 1234-abcd')
assert_eq "unknown session falls through to the pick" 1 "$(picks)"

echo "--continue pins to the account of the newest session in the cwd"
for form in '--continue' '-c'; do
  reset; out=$(STUB_LATEST=1234-abcd STUB_SESSION=me zrun interactive "claude $form")
  assert_contains "claude $form -> newest session's account" "cfg=$ME picked=me" "$out"
  assert_eq "claude $form: no pick" 0 "$(picks)"
  assert_contains "claude $form looked up the cwd's session" "/work" "$(grep '^latest' "$CALLS")"
done
reset; out=$(STUB_LATEST=1234-abcd STUB_SESSION=me zrun interactive 'c -c')
assert_contains "c -c pins too" "cfg=$ME picked=me" "$out"
assert_eq "c -c: no pick" 0 "$(picks)"
reset; out=$(STUB_SESSION=me zrun interactive 'claude --continue')
assert_eq "--continue without a known session falls through to the pick" 1 "$(picks)"

echo "--continue looks the session up by the physical cwd, not a symlinked \$PWD"
ln -s "$TMP/work" "$TMP/link"
phys=$(cd -P "$TMP/work" && pwd)
reset; out=$(ZCWD="$TMP/link" STUB_LATEST=1234-abcd STUB_SESSION=me zrun interactive 'claude --continue')
assert_contains "symlinked cwd: still pinned to the session's account" "cfg=$ME picked=me" "$out"
assert_eq "symlinked cwd: latest got the resolved path" "latest $phys" "$(grep '^latest' "$CALLS")"

echo "untouched invocations"
reset; out=$(zrun plain 'claude --foo')
assert_contains "non-interactive shell runs the binary as-is" "cfg=unset picked=unset" "$out"
assert_eq "non-interactive shell: no pick" 0 "$(picks)"
for args in '-p "reply ok"' '--version' 'mcp list' 'auth status' '--bg'; do
  reset; zrun interactive "claude $args" >/dev/null
  assert_eq "interactive claude $args: no pick" 0 "$(picks)"
done

echo "routing reason (CLAUDE_ACCOUNT_REASON, read by the statusline)"
reset; out=$(STUB_PICK_LINE="export CLAUDE_CONFIG_DIR='$ME'" STUB_PICK_ID=me STUB_PICK_REASON=pace zrun interactive 'claude --foo')
assert_contains "bare claude exports the picker's reason" "picked=me tok= reason=pace" "$out"
reset; out=$(STUB_PICK_LINE="export CLAUDE_CONFIG_DIR='$ME'" STUB_PICK_ID=me STUB_PICK_REASON=home zrun interactive 'c --foo')
assert_contains "c exports the picker's reason" "picked=me tok= reason=home" "$out"
echo "per-model default effort (config/claude-effort.json)"
reset; out=$(zrun interactive 'cs')
assert_contains "cs: Sonnet runs at high" "--effort high" "$out"
reset; out=$(zrun interactive 'cf')
assert_contains "cf: Fable runs at medium" "--effort medium" "$out"
reset; out=$(zrun interactive 'c')
assert_contains "c: the default model (Opus/Fable) runs at medium" "--effort medium" "$out"
reset; out=$(zrun interactive 'cs --effort low')
assert_not_contains "an explicit --effort wins" "--effort high" "$out"
reset; out=$(zrun interactive 'claude --model sonnet')
assert_contains "bare claude --model sonnet: high" "--effort high" "$out"
reset; out=$(zrun interactive 'claude --model haiku')
assert_not_contains "an unlisted family gets no flag" "--effort" "$out"
reset; out=$(zrun interactive 'c --account me')
assert_contains "forced account: reason forced" "reason=forced" "$out"
reset; out=$(STUB_SESSION=me zrun interactive 'c --resume 1234-abcd')
assert_contains "session-pinned account: reason resume" "reason=resume" "$out"
reset; out=$(STUB_PICK_RC=4 zrun interactive 'c')
assert_contains "registry error: the picker's reason (registry-error in production) passes through" "reason=test" "$out"
reset; out=$(CLAUDE_ACCOUNT_REASON=stale zrun interactive 'c --account iu')
assert_contains "a reason from a parent never leaks into a new choice" "reason=forced" "$out"
reset; out=$(CLAUDE_ACCOUNT_PICKED=me CLAUDE_CONFIG_DIR=$ME CLAUDE_ACCOUNT_REASON=pace zrun interactive 'claude --foo')
assert_contains "valid marker: no re-pick, reason inherited" "picked=me tok= reason=pace" "$out"

echo "c / cs / cf set the marker, never pick twice"
reset; out=$(STUB_PICK_LINE="export CLAUDE_CONFIG_DIR='$ME'" STUB_PICK_ID=me zrun interactive 'c --foo')
assert_eq "c: exactly one pick" 1 "$(picks)"
assert_contains "c: binary sees account and marker" "cfg=$ME picked=me" "$out"
assert_eq "c: lane interactive" interactive "$(head -1 "$PICKS")"
reset; out=$(zrun interactive 'cs')
assert_contains "cs pins the model" "--model sonnet" "$out"
assert_contains "cs on an iu pick: marker iu" "picked=iu" "$out"
assert_eq "cs: exactly one pick" 1 "$(picks)"
reset; out=$(zrun interactive 'c --account me')
assert_eq "c --account me: no pick" 0 "$(picks)"
assert_contains "c --account me: forced account + marker" "cfg=$ME picked=me" "$out"
reset; out=$(STUB_SESSION=me zrun interactive 'c --resume 1234-abcd')
assert_eq "c --resume pins: no pick" 0 "$(picks)"
assert_contains "c --resume pin" "cfg=$ME picked=me" "$out"
reset; out=$(STUB_PICK_RC=4 zrun interactive 'c')
assert_contains "registry error warns" "registry unreadable" "$out"
assert_contains "registry error still launches on iu" "cfg=unset picked=iu" "$out"
reset; out=$(STUB_PICK_SILENT=1 STUB_PICK_RC=2 zrun interactive 'c')
assert_contains "crashing picker (silent): says so" "account picker failed (rc=2) - launching on iu" "$out"
assert_contains "crashing picker still launches on iu" "cfg=unset picked=iu" "$out"
reset; out=$(STUB_PICK_LINE="garbage" STUB_PICK_RC=127 zrun interactive 'claude')
assert_contains "garbage answer from the picker: says so" "account picker failed (rc=127)" "$out"
assert_contains "bare claude stays non-blocking" "cfg=unset picked=iu" "$out"
reset; out=$(STUB_PICK_LINE=spill STUB_PICK_RC=3 zrun interactive 'claude')
case $out in *"picker failed"*) bad "spill is an answer, not a failure" "$out" ;; *) ok "spill is silent, launches on iu" ;; esac
reset; out=$(CLAUDE_CODE_OAUTH_TOKEN=leak STUB_PICK_LINE="export CLAUDE_CONFIG_DIR='$ME'" STUB_PICK_ID=me zrun interactive 'c')
case $out in *tok=set*) bad "me pick must not inherit the IU token" "$out" ;; *) ok "me pick strips CLAUDE_CODE_OAUTH_TOKEN" ;; esac

echo "rd spawn: one pick-log line (pick_account + herdr --env + agent_pane_setup, then the pane's claude)"
extract() { awk -v n="$1" '$0 ~ "^" n "\\(\\) \\{" {p=1} p {print} p && /^}/ {exit}' "$RD"; }
rd_spawn() { # $1 = pick line, $2 = id; simulates cmd_wave's pick + pane setup against the real functions
  reset
  echo cache > "$TMP/xdg/secrets/backend"
  HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/xdg" PATH="$TMP/bin:$PATH" STUB_PICK_LINE="$1" STUB_PICK_ID="$2" \
    bash -c "$(extract on_dev_host; extract host_run; extract pick_account; extract agent_pane_setup)
      pick_account wave; eval \"herdr workspace create --cwd /tmp \$PICK_ENV\"; agent_pane_setup %1 wave" >/dev/null 2>&1
  echo "not-cache" > "$TMP/xdg/secrets/backend"
}
for case_ in "export CLAUDE_CONFIG_DIR='$ME':me" "unset CLAUDE_CONFIG_DIR:iu"; do
  line=${case_%:*}; id=${case_##*:}
  rd_spawn "$line" "$id"
  assert_contains "herdr gets the marker at spawn time ($id)" "CLAUDE_ACCOUNT_PICKED=$id" "$(cat "$STUB_ENVS")"
  assert_contains "herdr gets the routing reason at spawn time ($id)" "CLAUDE_ACCOUNT_REASON=test" "$(cat "$STUB_ENVS")"
  assert_eq "pane setup types only the lane tag ($id)" "export USAGE_LANE=wave" "$(cat "$STUB_PANE")"
  # the pane: herdr's spawn-time --env, then the typed setup line and the agent command
  # shellcheck disable=SC2046
  out=$(cd "$TMP/work" && env $(cat "$STUB_ENVS") HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/xdg" PATH="$TMP/bin:$PATH" \
    zsh -fic "source '$AUTH'; source '$LAUNCH'; $(cat "$STUB_PANE"); claude --dangerously-skip-permissions --model sonnet" 2>&1)
  assert_contains "rd pane ($id): agent runs on the rd account" "picked=$id" "$out"
  assert_contains "rd pane ($id): agent sees the reason" "reason=test" "$out"
  assert_eq "rd pane ($id): exactly ONE pick-log line (rd's), none from the wrapper" 1 "$(picks)"
  assert_eq "rd pick lane" wave "$(head -1 "$PICKS")"
done

echo "mini token fallback composes with the pick (backend=cache)"
echo cache > "$TMP/xdg/secrets/backend"
reset; out=$(STUB_LOGGED_IN=0 zrun interactive 'claude --foo')
assert_contains "iu pick + dead keychain login: token injected" "cfg=unset picked=iu tok=set" "$out"
reset; out=$(STUB_LOGGED_IN=0 CLAUDE_ACCOUNT_PICKED=iu zrun interactive 'claude --foo')
assert_contains "marker iu + dead login: token injected, still no pick" "tok=set" "$out"
assert_eq "no pick" 0 "$(picks)"
reset; out=$(STUB_LOGGED_IN=1 zrun interactive 'claude --foo')
assert_contains "iu + live login: no token" "tok= " "$out"
reset; out=$(STUB_LOGGED_IN=0 STUB_PICK_LINE="export CLAUDE_CONFIG_DIR='$ME'" STUB_PICK_ID=me zrun interactive 'claude --foo')
assert_contains "me pick + dead login: hint, never the IU token" "no token fallback for this account" "$out"
case $out in *tok=set*) bad "me must never get the IU token" "$out" ;; *) ok "me never gets the IU token" ;; esac
reset; out=$(STUB_LOGGED_IN=0 zrun plain 'claude --foo')
assert_contains "non-interactive mini shell keeps the token fallback" "tok=set" "$out"
assert_eq "non-interactive mini shell: no pick" 0 "$(picks)"

echo
if (( fail )); then printf '\033[31m%d failed\033[0m, %d passed\n' "$fail" "$pass"; exit 1; fi
printf '\033[32mall %d passed\033[0m\n' "$pass"
