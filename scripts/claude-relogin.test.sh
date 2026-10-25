#!/usr/bin/env bash
# claude-relogin.test.sh — hermetic suite for claude-relogin.sh, claude-login-browser.sh and lib/claude-login.sh.
# ssh, open, herdr, osascript, claude, claude-account, lsof and ask-human are PATH stubs that only record their
# argv: no real browser, tunnel, dialog or login ever happens. A scratch HOME, registry and machine marker.
# Usage: scripts/claude-relogin.test.sh   (exit 0 = all pass)
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELOGIN="$HERE/claude-relogin.sh"
BROWSER_SH="$HERE/claude-login-browser.sh"
pass=0; fail=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; [[ -n "${2:-}" ]] && printf '         %s\n' "$2"; fail=$((fail + 1)); }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
assert_contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "[$3] does not contain [$2]" ;; esac; }
assert_not_contains() { case "$3" in *"$2"*) bad "$1" "[$3] unexpectedly contains [$2]" ;; *) ok "$1" ;; esac; }

command -v jq >/dev/null || { echo "✗ jq not found"; exit 2; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/claude-relogin-test.XXXXXX")" || exit 2
cleanup() { [[ -f "$TMP/tunnel.pid" ]] && kill "$(cat "$TMP/tunnel.pid")" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT
mkdir -p "$TMP/bin" "$TMP/home" "$TMP/xdg/secrets"
export HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/xdg" LOG="$TMP/calls"
unset CLAUDE_CONFIG_DIR ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_BASE_URL BROWSER

cat > "$TMP/registry.json" <<JSON
{"accounts":{
 "iu":{"dir":null,"loginBrowser":"Google Chrome","enabled":true},
 "me":{"dir":"~/.claude-me","loginBrowser":"Helium","enabled":true},
 "nob":{"dir":"~/.claude-nob","enabled":true},
 "off":{"dir":"~/.claude-off","loginBrowser":"Helium","enabled":false}}}
JSON
export CLAUDE_ACCOUNTS_REGISTRY="$TMP/registry.json"

# ── stubs: record argv as `name[a][b]…`, behaviour by STUB_* env ───────────────────────────────
rec='printf "%s" "$(basename "$0")" >> "$LOG"; for a in "$@"; do printf "[%s]" "$a" >> "$LOG"; done; printf "\n" >> "$LOG"'
mk() { printf '#!/bin/bash\n%s\n%s\n' "$rec" "$2" > "$TMP/bin/$1"; chmod +x "$TMP/bin/$1"; }
mk ssh 'case " $* " in
  *" -N "*) echo $$ > "$TMP_DIR/tunnel.pid"; [ "${STUB_TUNNEL:-ok}" = fail ] && exit 1
            [ "${STUB_TUNNEL:-ok}" = dies ] && { sleep 2; exit 1; }; exec sleep 60 ;;
  *) [ "${STUB_OPEN:-ok}" = fail ] && exit 1; exit 0 ;;
esac'
mk open '[ "${STUB_OPENBIN:-ok}" = fail ] && exit 1; exit 0'
mk osascript 'exit 0'
mk herdr 'case "$1 $2" in "workspace create") echo "{\"result\":{\"root_pane\":{\"pane_id\":\"w9:1\"}}}" ;; esac'
mk claude '[ "${STUB_CLAUDE_BROWSER:-0}" = 1 ] && "$BROWSER" "$STUB_URL"; echo "ENV cfg=${CLAUDE_CONFIG_DIR-unset} browser=${BROWSER-unset} acc=${CLAUDE_LOGIN_ACCOUNT-unset} machine=${CLAUDE_LOGIN_MACHINE-unset} owner=${CLAUDE_LOGIN_OWNER_PID:+set} key=${ANTHROPIC_API_KEY-unset} tok=${CLAUDE_CODE_OAUTH_TOKEN-unset}" >> "$LOG"; exit "${STUB_LOGIN_RC:-0}"'
mk claude-account 'case "$1" in usage) echo "$3 usage-line" ;; expiry) echo "$3 expiry-line" ;; esac; case "$1" in usage|expiry) echo "me max5x usage-line"; echo "iu max20x usage-line" ;; esac; exit 0'
mk lsof 'case " $* " in *LISTEN*) [ "${STUB_LISTEN:-0}" = 1 ] && exit 0 ;; esac; exit 1'
mk ask-human 'echo "hm=${HUMAN_QUEUE_MAC_HOST-unset}" >> "$LOG"; echo "20260101T000000-1"'
export TMP_DIR="$TMP" PATH="$TMP/bin:$PATH"
export CLAUDE_RELOGIN_ASK_HUMAN="$TMP/bin/ask-human" CLAUDE_RELOGIN_PANE_WAIT=0 CLAUDE_LOGIN_LSOF="$TMP/bin/lsof" CLAUDE_LOGIN_MSG_FILE="$TMP/msgs" CLAUDE_LOGIN_POLL_S=1 CLAUDE_LOGIN_FORWARD_GRACE_S=1
# Safety net: every external command the scripts reach must be one of our stubs, never the real herdr/ssh/claude.
for c in ssh open herdr osascript claude claude-account; do
  [[ "$(PATH="$PATH:$HOME/.local/bin:/opt/homebrew/bin:$HOME/.bun/bin" command -v "$c")" == "$TMP/bin/$c" ]] || { echo "✗ $c does not resolve to the test stub"; exit 2; }
done
as() { printf '%s' "$([[ $1 == mini ]] && echo cache || echo op)" > "$TMP/xdg/secrets/backend"; }
reset() { : > "$LOG"; : > "$TMP/msgs"; rm -f "$TMP/tunnel.pid"; }
calls() { grep -v "^lsof" "$LOG"; } # a watchdog left over from an earlier case may still poll lsof; that is noise here

URL='https://claude.ai/oauth/authorize?code=true&client_id=abc&response_type=code&redirect_uri=http%3A%2F%2Flocalhost%3A58876%2Fcallback&scope=org%3Acreate_api_key+user%3Aprofile&state=x%y'

# ── lib: URL/port parsing, quoting, browser choice, tunnel verdict ──────────────────────────────
# shellcheck source=lib/claude-login.sh
source "$HERE/lib/claude-login.sh"
echo "callback port parsing"
assert_eq "percent-encoded redirect_uri" 58876 "$(login_url_port "$URL")"
assert_eq "raw redirect_uri" 4242 "$(login_url_port 'https://x/authorize?a=b&redirect_uri=http://localhost:4242/callback&c=d')"
assert_eq "127.0.0.1 and lower-case hex escapes" 7001 "$(login_url_port 'https://x/a?redirect_uri=http%3a%2f%2f127.0.0.1%3a7001%2fcallback')"
assert_eq "port at the end of the URL" 9000 "$(login_url_port 'https://x/a?redirect_uri=http://localhost:9000')"
for bad_url in 'https://x/a?state=1' 'https://x/a?redirect_uri=https%3A%2F%2Flocalhost%3A1%2Fcb' 'https://x/a?redirect_uri=http%3A%2F%2Fevil.example%3A1%2Fcb' 'https://x/a?redirect_uri=http%3A%2F%2Flocalhost%3A70000%2Fcb' 'https://x/a?redirect_uri=http%3A%2F%2Flocalhost%3A0%2Fcb' ''; do
  login_url_port "$bad_url" >/dev/null && bad "no port for [$bad_url]" || ok "no port for [$bad_url]"
done

echo "quoting"
q=$(login_shquote "$URL")
assert_eq "URL round-trips through a shell word" "$URL" "$(eval "printf %s $q")"
q=$(login_shquote "it's a \"test\" \$HOME \`x\` & y")
assert_eq "quotes, \$, backticks and & survive" "it's a \"test\" \$HOME \`x\` & y" "$(eval "printf %s $q")"

echo "per-account browser"
assert_eq "iu -> Google Chrome" "Google Chrome" "$(login_browser_for "$CLAUDE_ACCOUNTS_REGISTRY" iu)"
assert_eq "me -> Helium" "Helium" "$(login_browser_for "$CLAUDE_ACCOUNTS_REGISTRY" me)"
assert_eq "no loginBrowser -> empty" "" "$(login_browser_for "$CLAUDE_ACCOUNTS_REGISTRY" nob)"
assert_eq "unknown account -> empty" "" "$(login_browser_for "$CLAUDE_ACCOUNTS_REGISTRY" nobody)"

echo "browser lookup fails distinctly on an unusable registry"
login_browser_for "$TMP/missing.json" me >/dev/null 2>&1; assert_eq "missing registry: rc 2" 2 "$?"
echo '{"accounts":' > "$TMP/broken.json"
login_browser_for "$TMP/broken.json" me >/dev/null 2>&1; assert_eq "malformed registry: rc 2" 2 "$?"
login_browser_for "$CLAUDE_ACCOUNTS_REGISTRY" nobody >/dev/null 2>&1; assert_eq "unknown account: rc 3" 3 "$?"
( export PATH=/nonexistent; login_browser_for "$CLAUDE_ACCOUNTS_REGISTRY" me >/dev/null 2>&1 ); assert_eq "jq missing: rc 2" 2 "$?"
login_browser_for "$CLAUDE_ACCOUNTS_REGISTRY" nob >/dev/null 2>&1; assert_eq "account without loginBrowser: rc 0 (empty is a real answer)" 0 "$?"

echo "tunnel watchdog verdict (owner listening seen idle max)"
assert_eq "login running, nothing to report" keep "$(login_tunnel_verdict 1 1 1 10 2700)"
assert_eq "not listening yet (CLI still starting)" keep "$(login_tunnel_verdict 1 0 0 10 2700)"
assert_eq "owner gone" close:owner-gone "$(login_tunnel_verdict 0 1 1 10 2700)"
assert_eq "listener gone after it was seen: login finished" close:login-ended "$(login_tunnel_verdict 1 0 1 10 2700)"
assert_eq "idle window reached" close:idle "$(login_tunnel_verdict 1 1 1 2700 2700)"
assert_eq "owner gone beats idle" close:owner-gone "$(login_tunnel_verdict 0 0 1 9999 2700)"

# ── helper ──────────────────────────────────────────────────────────────────────────────────────
echo "helper on the MacBook"
reset
CLAUDE_LOGIN_ACCOUNT=me CLAUDE_LOGIN_MACHINE=macbook bash "$BROWSER_SH" "$URL"; rc=$?
assert_eq "rc 0" 0 "$rc"
assert_eq "open -a Helium <url>, argv intact" "open[-a][Helium][$URL]" "$(calls)"
reset; CLAUDE_LOGIN_ACCOUNT=iu CLAUDE_LOGIN_MACHINE=macbook bash "$BROWSER_SH" "$URL"
assert_eq "iu opens in Google Chrome" "open[-a][Google Chrome][$URL]" "$(calls)"
reset; CLAUDE_LOGIN_ACCOUNT=nob CLAUDE_LOGIN_MACHINE=macbook bash "$BROWSER_SH" "$URL"
assert_eq "no loginBrowser: plain open <url>" "open[$URL]" "$(calls)"
assert_contains "...and it says so" "system default browser" "$(cat "$TMP/msgs")"
reset; bash "$BROWSER_SH" "$URL"
assert_contains "no account at all: default browser, says so" "no CLAUDE_LOGIN_ACCOUNT" "$(cat "$TMP/msgs")"
bash "$BROWSER_SH" >/dev/null 2>&1; assert_eq "no URL: usage error" 2 "$?"

echo "helper on the mini: reverse forward + remote open"
reset
owner_sh=$(sleep 3 & echo $!)   # a login process that ends shortly
CLAUDE_LOGIN_ACCOUNT=me CLAUDE_LOGIN_MACHINE=mini CLAUDE_LOGIN_OWNER_PID=$owner_sh bash "$BROWSER_SH" "$URL"; rc=$?
assert_eq "rc 0" 0 "$rc"
tunnel_line=$(sed -n 1p "$LOG"); open_line=$(sed -n 2p "$LOG")
assert_contains "tunnel forwards the callback port back to the mini" "[-N][-R][127.0.0.1:58876:localhost:58876]" "$tunnel_line"
assert_contains "tunnel: own connection, fails loudly" "[ExitOnForwardFailure=yes]" "$tunnel_line"
assert_contains "tunnel: no shared control master" "[ControlPath=none]" "$tunnel_line"
assert_contains "tunnel goes to the MacBook" "[iumac]" "$tunnel_line"
remote=$(sed -n 's/^ssh.*\[iumac\]\[\(.*\)\]$/\1/p' <<<"$open_line")
assert_eq "remote command is one shell string starting with open" "open " "${remote:0:5}"
assert_eq "the remote shell sees open -a Helium <url> intact" "[-a][Helium][$URL]" "$(sh -c "printf '[%s]' ${remote#open }")"
assert_contains "user told where it opened" "Helium" "$(cat "$TMP/msgs")"
for _ in 1 2 3 4 5 6 7 8; do kill -0 "$(cat "$TMP/tunnel.pid")" 2>/dev/null || break; sleep 1; done
kill -0 "$(cat "$TMP/tunnel.pid")" 2>/dev/null && bad "tunnel closes after the login process is gone" || ok "tunnel closes after the login process is gone"

reset
CLAUDE_LOGIN_ACCOUNT=iu CLAUDE_LOGIN_MACHINE=mini CLAUDE_LOGIN_OWNER_PID=$$ bash "$BROWSER_SH" "$URL"
assert_contains "iu: Google Chrome on the MacBook" "'Google Chrome'" "$(sed -n 2p "$LOG")"
kill "$(cat "$TMP/tunnel.pid")" 2>/dev/null

echo "helper failures print the URL and keep the paste path"
reset; STUB_TUNNEL=fail CLAUDE_LOGIN_ACCOUNT=me CLAUDE_LOGIN_MACHINE=mini bash "$BROWSER_SH" "$URL"; rc=$?
assert_eq "forward refused: rc 1" 1 "$rc"
assert_not_contains "no open attempted after a dead forward" "Helium" "$(sed -n '2,$p' "$LOG")"
assert_contains "URL printed" "$URL" "$(cat "$TMP/msgs")"
assert_contains "tells to paste the code" "paste the code" "$(cat "$TMP/msgs")"
reset; STUB_OPEN=fail CLAUDE_LOGIN_ACCOUNT=me CLAUDE_LOGIN_MACHINE=mini bash "$BROWSER_SH" "$URL"; rc=$?
assert_eq "remote open failed: rc 1" 1 "$rc"
assert_contains "URL printed" "$URL" "$(cat "$TMP/msgs")"
sleep 1; kill -0 "$(cat "$TMP/tunnel.pid")" 2>/dev/null && bad "tunnel killed after a failed open" || ok "tunnel killed after a failed open"
reset; CLAUDE_LOGIN_ACCOUNT=me CLAUDE_LOGIN_MACHINE=mini bash "$BROWSER_SH" 'https://claude.ai/oauth/authorize?state=1'; rc=$?
assert_eq "no callback port in the URL: rc 1, no ssh at all" "1/" "$rc/$(calls)"
assert_contains "...and the URL is printed" "authorize?state=1" "$(cat "$TMP/msgs")"

echo "helper: open fails on the MacBook, unusable registry, unwritable terminal"
reset; STUB_OPENBIN=fail CLAUDE_LOGIN_ACCOUNT=me CLAUDE_LOGIN_MACHINE=macbook bash "$BROWSER_SH" "$URL"; rc=$?
assert_eq "open failed: rc 1" 1 "$rc"
assert_contains "...URL printed" "$URL" "$(cat "$TMP/msgs")"
assert_contains "...paste hint" "paste the code" "$(cat "$TMP/msgs")"
reset; CLAUDE_ACCOUNTS_REGISTRY="$TMP/broken.json" CLAUDE_LOGIN_ACCOUNT=me CLAUDE_LOGIN_MACHINE=macbook bash "$BROWSER_SH" "$URL" 2>/dev/null; rc=$?
assert_eq "unusable registry: rc 1, no browser guessed" "1/" "$rc/$(calls)"
assert_contains "...URL printed" "$URL" "$(cat "$TMP/msgs")"
reset; err=$(CLAUDE_LOGIN_MSG_FILE="$TMP/no-such-dir/msgs" CLAUDE_LOGIN_ACCOUNT=nob CLAUDE_LOGIN_MACHINE=macbook bash "$BROWSER_SH" "$URL" 2>&1 >/dev/null)
assert_contains "unwritable terminal: messages fall back to stderr" "system default browser" "$err"
reset; err=$(STUB_OPENBIN=fail CLAUDE_LOGIN_MSG_FILE="$TMP/no-such-dir/msgs" CLAUDE_LOGIN_ACCOUNT=me CLAUDE_LOGIN_MACHINE=macbook bash "$BROWSER_SH" "$URL" 2>&1 >/dev/null)
assert_contains "unwritable terminal: the URL fallback still reaches stderr" "$URL" "$err"

echo "helper: a tunnel that dies mid-login (login still waiting) tells the user to paste the code"
reset
STUB_TUNNEL=dies STUB_LISTEN=1 CLAUDE_LOGIN_ACCOUNT=me CLAUDE_LOGIN_MACHINE=mini CLAUDE_LOGIN_OWNER_PID=$$ bash "$BROWSER_SH" "$URL"
for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q "dropped" "$TMP/msgs" && break; sleep 1; done
assert_contains "paste hint after the tunnel dropped" "paste the code" "$(cat "$TMP/msgs")"
reset
STUB_TUNNEL=dies CLAUDE_LOGIN_ACCOUNT=me CLAUDE_LOGIN_MACHINE=mini CLAUDE_LOGIN_OWNER_PID=$$ bash "$BROWSER_SH" "$URL"
sleep 5
assert_not_contains "no alarm when nothing was listening any more (login over)" "dropped" "$(cat "$TMP/msgs")"

echo "helper --dry-run runs nothing"
reset; out=$(CLAUDE_LOGIN_ACCOUNT=me CLAUDE_LOGIN_MACHINE=mini bash "$BROWSER_SH" --dry-run "$URL" 2>&1)
assert_eq "no stub called" "" "$(calls)"
assert_contains "prints the tunnel" "'-R' '127.0.0.1:58876:localhost:58876'" "$out"
assert_contains "prints the quoted remote open" "'open '\\''-a'\\'' '\\''Helium'\\''" "$out"

# ── relogin ─────────────────────────────────────────────────────────────────────────────────────
echo "relogin --ask"
as mini; reset
bash "$RELOGIN" me --ask --reason "login dead" >/dev/null; rc=$?
line=$(sed -n 1p "$LOG")
assert_eq "ask-human called with ask" "ask-human[ask]" "${line:0:14}"
assert_contains "text names account, machine and reason" "Claude login 'me' on the mini needs a new /login (login dead)" "$line"
assert_contains "the command runs the relogin for that machine" '[--cmd][bash "$HOME/SourceRoot/dotfiles/scripts/claude-relogin.sh" me --machine mini]' "$line"
assert_contains "mini: default push (no MAC_HOST override)" "hm=unset" "$(calls)"
reset; bash "$RELOGIN" me --machine macbook --ask >/dev/null
assert_contains "mini asking for the MacBook's login: command targets the macbook" "me --machine macbook]" "$(calls)"
as macbook; reset; bash "$RELOGIN" iu --ask >/dev/null
assert_contains "MacBook: dialog shown locally" "hm=local" "$(calls)"
assert_contains "MacBook: command for the macbook" "iu --machine macbook]" "$(calls)"
assert_contains "iu text names Chrome" "Google Chrome" "$(calls)"

echo "relogin opens the login terminal"
as mini; reset
bash "$RELOGIN" me >/dev/null; rc=$?
assert_eq "rc 0" 0 "$rc"
assert_contains "herdr workspace in HOME" "herdr[workspace][create][--cwd][$HOME][--label][relogin me][--focus]" "$(calls)"
assert_contains "typed into that pane: the --in-pane run" "herdr[pane][run][w9:1][bash '$HERE/claude-relogin.sh' me --machine mini --in-pane]" "$(calls)"
as macbook; reset
bash "$RELOGIN" me >/dev/null
assert_contains "MacBook: Terminal via osascript, command as argv" "osascript[-][bash '$HERE/claude-relogin.sh' me --machine macbook --in-pane]" "$(calls)"
as mini; reset
bash "$RELOGIN" me --machine macbook >/dev/null
assert_contains "mini -> MacBook: one ssh hop to iumac" "ssh[-o][BatchMode=yes][-o][ConnectTimeout=8][iumac][export PATH=" "$(calls)"
assert_contains "...running the relogin there" 'claude-relogin.sh" me --machine macbook]' "$(calls)"
as macbook; reset
bash "$RELOGIN" me --machine mini >/dev/null
assert_contains "MacBook -> mini: hop to mini" "[mini][export PATH=" "$(calls)"

echo "relogin --in-pane (the login itself)"
as mini; reset
bash "$RELOGIN" me --machine mini --in-pane >/dev/null; rc=$?
assert_eq "rc 0" 0 "$rc"
c=$(calls)
assert_contains "claude auth login --claudeai on the me dir, BROWSER = helper" "ENV cfg=$HOME/.claude-me browser=$HERE/claude-login-browser.sh acc=me machine=mini owner=set key=unset tok=unset" "$c"
assert_contains "refresh afterwards" "claude-account[refresh][--ids][me]" "$c"
assert_contains "usage afterwards" "claude-account[usage]" "$c"
assert_contains "expiry afterwards" "claude-account[expiry]" "$c"
reset; ANTHROPIC_API_KEY=k CLAUDE_CODE_OAUTH_TOKEN=t CLAUDE_CONFIG_DIR=/elsewhere bash "$RELOGIN" iu --machine mini --in-pane >/dev/null
assert_contains "iu: CLAUDE_CONFIG_DIR stays unset, token env stripped" "ENV cfg=unset browser=$HERE/claude-login-browser.sh acc=iu machine=mini owner=set key=unset tok=unset" "$(calls)"
reset; STUB_LOGIN_RC=1 bash "$RELOGIN" me --machine mini --in-pane >/dev/null 2>"$TMP/err"; rc=$?
assert_eq "failed login: rc 1" 1 "$rc"
assert_not_contains "failed login: no refresh" "refresh" "$(calls)"
assert_contains "failed login: manual fallback named" "Manual fallback" "$(cat "$TMP/err")"
bash "$RELOGIN" me --machine macbook --in-pane >/dev/null 2>&1; assert_eq "--in-pane on the wrong machine is refused" 2 "$?"

echo "the login owner kills the tunnel on exit"
as mini; reset
export STUB_URL="$URL"
STUB_CLAUDE_BROWSER=1 CLAUDE_LOGIN_FORWARD_GRACE_S=1 bash "$RELOGIN" me --machine mini --in-pane >/dev/null; rc=$?
tp=$(cat "$TMP/tunnel.pid" 2>/dev/null)
sleep 0.2   # the watchdog polls only every second: a dead tunnel this early is the trap's doing
assert_eq "login finished: rc 0" 0 "$rc"
[[ -n "$tp" ]] && ! kill -0 "$tp" 2>/dev/null && ok "tunnel gone as soon as the owner returned" || bad "tunnel gone as soon as the owner returned" "pid [$tp]"
assert_eq "pid file removed" "0" "$(ls "${TMPDIR:-/tmp}"/claude-relogin-tunnel.* 2>/dev/null | wc -l | tr -d ' ')"
reset
STUB_CLAUDE_BROWSER=1 STUB_LOGIN_RC=1 CLAUDE_LOGIN_FORWARD_GRACE_S=1 bash "$RELOGIN" me --machine mini --in-pane >/dev/null 2>&1; rc=$?
tp=$(cat "$TMP/tunnel.pid" 2>/dev/null); sleep 0.2
[[ -n "$tp" ]] && ! kill -0 "$tp" 2>/dev/null && ok "failed login: tunnel killed too" || bad "failed login: tunnel killed too" "pid [$tp]"
unset STUB_URL

echo "relogin --dry-run (me and iu on the mini) runs nothing"
for a in me iu; do
  reset; out=$(bash "$RELOGIN" $a --dry-run 2>&1)
  assert_eq "$a: no stub called" "" "$(calls)"
  assert_contains "$a: prints the herdr step" "would run: 'herdr' 'workspace' 'create'" "$out"
  assert_contains "$a: prints the login command" "'claude' 'auth' 'login' '--claudeai'" "$out"
  assert_contains "$a: prints the tunnel" "'-R' '127.0.0.1:58876:localhost:58876'" "$out"
done
assert_contains "iu dry run: config dir unset" "'-u' 'CLAUDE_CONFIG_DIR' 'USER=" "$(bash "$RELOGIN" iu --dry-run 2>&1)"
assert_contains "me dry run: config dir set" "CLAUDE_CONFIG_DIR=$HOME/.claude-me" "$(bash "$RELOGIN" me --dry-run 2>&1)"
reset; out=$(bash "$RELOGIN" me --ask --dry-run 2>&1)
assert_eq "--ask --dry-run: no dialog" "" "$(calls)"
assert_contains "--ask --dry-run: prints the ask" "'ask' 'Claude login '\\''me'\\''" "$out"

echo "argument errors"
bash "$RELOGIN" nobody >/dev/null 2>&1; assert_eq "unknown account" 2 "$?"
bash "$RELOGIN" off >/dev/null 2>&1; assert_eq "disabled account" 2 "$?"
bash "$RELOGIN" me --machine laptop >/dev/null 2>&1; assert_eq "bad machine" 2 "$?"
bash "$RELOGIN" >/dev/null 2>&1; assert_eq "no id" 2 "$?"

echo
if (( fail )); then printf '\033[31m%d failed\033[0m, %d passed\n' "$fail" "$pass"; exit 1; fi
printf '\033[32mall %d passed\033[0m\n' "$pass"
