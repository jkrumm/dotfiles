#!/usr/bin/env bash
# claude-relogin.test.sh — hermetic suite for claude-relogin.sh, claude-login-browser.sh and lib/claude-login.sh.
# ssh, open, hc, herdr, osascript, claude, claude-account, launchctl, lsof and ask-human are PATH stubs that only record their
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
# osascript reads its script on stdin: the kind (open/exists/close/notify) is what the case asserts on. "open" can play the
# interactive login that would run in that window (STUB_TERM_RESULT = the result file content it would write).
cat > "$TMP/bin/osascript" <<'STUB'
#!/bin/bash
body=$(cat); kind=other
case "$body" in
  *"do script"*) kind=open; echo "${STUB_WINID:-4242}"
    if [ -n "${STUB_TERM_SYMLINK:-}" ]; then f=$(printf '%s' "$2" | sed -nE "s/.*--result-file '([^']*)'.*/\1/p"); echo "ok 2027-01-01" > "$TMP_DIR/planted"; rm -f "$f"; ln -s "$TMP_DIR/planted" "$f"; fi
    if [ -n "${STUB_TERM_RESULT:-}" ]; then f=$(printf '%s' "$2" | sed -nE "s/.*--result-file '([^']*)'.*/\1/p"); [ -n "$f" ] && echo "$STUB_TERM_RESULT" > "$f"; fi ;;
  *"exists window"*) kind=exists; v="${STUB_WIN_EXISTS:-true}"
    if [ -n "${STUB_WIN_SEQ_FILE:-}" ] && [ -s "$STUB_WIN_SEQ_FILE" ]; then v=$(head -1 "$STUB_WIN_SEQ_FILE"); sed -i '' 1d "$STUB_WIN_SEQ_FILE"; fi
    case "$v" in error) printf 'osascript:exists-error\n' >> "$LOG"; exit 1 ;; garbage) echo "what?" ;; *) echo "$v" ;; esac ;;
  *"close (window"*) kind=close ;;
  *"display notification"*) kind=notify ;;
esac
printf 'osascript:%s' "$kind" >> "$LOG"; for a in "$@"; do printf "[%s]" "$a" >> "$LOG"; done; printf "\n" >> "$LOG"
STUB
chmod +x "$TMP/bin/osascript"
cat > "$TMP/bin/herdr" <<'STUB'
#!/bin/bash
printf 'herdr' >> "$LOG"; for a in "$@"; do printf "[%s]" "$a" >> "$LOG"; done; printf "\n" >> "$LOG"
case "$1 $2" in
  "workspace create") case "${STUB_CREATE:-ok}" in
      noworkspace) echo '{"result":{"root_pane":{"pane_id":"w9:1"}}}' ;;
      *) echo "{\"result\":{\"workspace\":{\"workspace_id\":\"${STUB_WS_ID:-w9}\"},\"root_pane\":{\"pane_id\":\"w9:1\"}}}" ;;
    esac ;;
  "workspace list") case "${STUB_WS_LIST:-ok}" in
      fail) printf 'herdr:list-error\n' >> "$LOG"; exit 1 ;;
      garbage) echo "not json" ;;
      gone) echo '{"result":{"workspaces":[{"workspace_id":"w1F"}]}}' ;;
      *) echo "{\"result\":{\"workspaces\":[{\"workspace_id\":\"w1F\"},{\"workspace_id\":\"${STUB_WS_ID:-w9}\"}]}}" ;;
    esac ;;
  "pane run") # play the login that would run in the pane: write its result file
    if [ -n "${STUB_PANE_RESULT:-}" ]; then f=$(printf '%s' "$4" | sed -nE "s/.*--result-file '([^']*)'.*/\1/p"); [ -z "$f" ] || echo "$STUB_PANE_RESULT" > "$f"; fi ;;
esac
STUB
chmod +x "$TMP/bin/herdr"
# The mini's core. connect: doc.get answers STUB_DOC_VALUE (JSON, default null), doc.set is recorded and accepted; run plays the
# login that would run in the terminal (STUB_PANE_RESULT -> its result file) and answers STUB_HC_ADDR; get answers by name:
# `relogin-*` is the pre-start check (STUB_HC_EXISTING: live|finished, default not found), anything else the watcher's probe
# (STUB_HC_GET: live default | finished | gone | fail | garbage).
cat > "$TMP/bin/hc" <<'STUB'
#!/bin/bash
printf 'hc' >> "$LOG"; for a in "$@"; do printf "[%s]" "$a" >> "$LOG"; done; printf "\n" >> "$LOG"
case "$1" in
  connect)
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      m=$(printf '%s' "$line" | jq -r .method); echo "rpc:$m" >> "$LOG"
      case "$m" in
        doc.get) [ "${STUB_DOC:-ok}" = fail ] && exit 1
                 printf '{"jsonrpc":"2.0","id":1,"result":{"value":%s,"version":7}}\n' "${STUB_DOC_VALUE:-null}" ;;
        doc.set) printf '%s' "$line" | jq -c .params >> "$TMP_DIR/doc-sets.jsonl"; echo '{"jsonrpc":"2.0","id":1,"result":{"version":8}}' ;;
      esac
    done ;;
  run)
    [ "${STUB_HC_RUN:-ok}" = fail ] && { echo "boom" >&2; exit 1; }
    if [ -n "${STUB_PANE_RESULT:-}" ]; then f=$(printf '%s' "${!#}" | sed -nE "s/.*--result-file '([^']*)'.*/\1/p"); [ -z "$f" ] || echo "$STUB_PANE_RESULT" > "$f"; fi
    echo "{\"address\":\"${STUB_HC_ADDR:-t9}\",\"name\":\"x\",\"state\":\"live\"}" ;;
  get)
    case "$2" in
      relogin-*) case "${STUB_HC_EXISTING:-none}" in none) exit 3 ;; *) echo "{\"address\":\"t5\",\"state\":\"$STUB_HC_EXISTING\"}" ;; esac ;;
      *) case "${STUB_HC_GET:-live}" in
           gone) exit 3 ;; fail) printf 'hc:get-error\n' >> "$LOG"; exit 1 ;; garbage) echo "not json" ;;
           finished) echo '{"address":"t9","state":"finished"}' ;;
           *) echo '{"address":"t9","state":"live"}' ;;
         esac ;;
    esac ;;
esac
STUB
chmod +x "$TMP/bin/hc"
mk claude 'echo x >> "$TMP_DIR/claude.runs"; [ "${STUB_CLAUDE_BROWSER:-0}" = 1 ] && "$BROWSER" "$STUB_URL"; [ -n "${STUB_CLAUDE_OUT:-}" ] && echo "$STUB_CLAUDE_OUT"; echo $$ > "$TMP_DIR/claude.pid"; [ "${STUB_CLAUDE_HANG:-0}" = 1 ] && exec sleep 30; [ "${STUB_CLAUDE_HANG:-0}" = trap ] && { trap "" TERM; sleep 6; }; echo "ENV cfg=${CLAUDE_CONFIG_DIR-unset} browser=${BROWSER-unset} acc=${CLAUDE_LOGIN_ACCOUNT-unset} machine=${CLAUDE_LOGIN_MACHINE-unset} owner=${CLAUDE_LOGIN_OWNER_PID:+set} key=${ANTHROPIC_API_KEY-unset} tok=${CLAUDE_CODE_OAUTH_TOKEN-unset}" >> "$LOG"; exit "${STUB_LOGIN_RC:-0}"'
# expiry --json answers STUB_EXPIRY_BEFORE until the claude stub has run since the last reset(), then STUB_EXPIRY_AFTER
# (epoch ms; "none" = the Keychain item is unreadable: refresh_expires_at null; "fail" = the CLI itself fails). The default login moves forward 30 days.
mk claude-account 'case "$1 $2" in
  "expiry --json") if [ -e "$TMP_DIR/claude.runs" ]; then ms=${STUB_EXPIRY_AFTER:-1798761600000}; else ms=${STUB_EXPIRY_BEFORE:-1796169600000}; fi
    [ "$ms" = none ] && ms=null
    [ "$ms" = fail ] && exit 1
    echo "{\"accounts\":[{\"id\":\"me\",\"refresh_expires_at\":$ms},{\"id\":\"iu\",\"refresh_expires_at\":$ms}]}" ;;
  usage*|expiry*) echo "me max5x usage-line"; echo "iu max20x usage-line" ;;
esac; exit 0'
# `launchctl print …herdr-core` says whether the mini's core runs (STUB_CORE=running; default down: the classic workspace path);
# anything else is `managername`
mk launchctl 'case "$1" in print) echo "state = ${STUB_CORE:-not running}" ;; *) echo "${STUB_SESSION:-Aqua}" ;; esac'
mk lsof 'case " $* " in *LISTEN*) [ "${STUB_LISTEN:-0}" = 1 ] && exit 0 ;; esac; exit 1'
mk ask-human 'echo "hm=${HUMAN_QUEUE_MAC_HOST-unset}" >> "$LOG"; echo "20260101T000000-1"'
export TMP_DIR="$TMP" PATH="$TMP/bin:$PATH"
mkdir -p "$TMP/space-repo"; export CLAUDE_RELOGIN_SPACE_DIR="$TMP/space-repo"
export CLAUDE_RELOGIN_ASK_HUMAN="$TMP/bin/ask-human" CLAUDE_RELOGIN_PANE_WAIT=0 CLAUDE_LOGIN_LSOF="$TMP/bin/lsof" CLAUDE_LOGIN_MSG_FILE="$TMP/msgs" CLAUDE_LOGIN_POLL_S=1 CLAUDE_LOGIN_FORWARD_GRACE_S=1
# workers run inline (never a stray detached process), no waits, a scratch log
export CLAUDE_RELOGIN_FOREGROUND=1 CLAUDE_RELOGIN_POLL_S=1 CLAUDE_RELOGIN_CLOSE_DELAY_S=0 CLAUDE_RELOGIN_BG_IDLE_S=2 CLAUDE_RELOGIN_LOG="$TMP/relogin.log" CLAUDE_RELOGIN_ABSENT_N=2 CLAUDE_RELOGIN_MAX_WAIT_S=4 CLAUDE_RELOGIN_TERM_GRACE_S=1
# Safety net: every external command the scripts reach must be one of our stubs, never the real herdr/ssh/claude.
for c in ssh open hc herdr osascript claude claude-account launchctl; do
  [[ "$(PATH="$PATH:$HOME/.local/bin:/opt/homebrew/bin:$HOME/.bun/bin" command -v "$c")" == "$TMP/bin/$c" ]] || { echo "✗ $c does not resolve to the test stub"; exit 2; }
done
as() { printf '%s' "$([[ $1 == mini ]] && echo cache || echo op)" > "$TMP/xdg/secrets/backend"; }
reset() { : > "$LOG"; : > "$TMP/msgs"; rm -f "$TMP/tunnel.pid" "$TMP/claude.runs" "$TMP/doc-sets.jsonl"; }
calls() { grep -v -e "^lsof" -e "^launchctl\[print\]" "$LOG"; } # a watchdog left over from an earlier case may still poll lsof; that is noise here

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

echo "relogin opens the login terminal (no core running: the classic herdr workspace)"
as mini; reset
bash "$RELOGIN" me --visible >/dev/null; rc=$?
assert_eq "rc 0" 0 "$rc"
assert_contains "herdr workspace in HOME" "herdr[workspace][create][--cwd][$HOME][--label][relogin me][--focus]" "$(calls)"
assert_contains "typed into that pane: the --in-pane run" "herdr[pane][run][w9:1][bash '$HERE/claude-relogin.sh' me --machine mini --in-pane]" "$(calls)"
as macbook; reset
bash "$RELOGIN" me --visible >/dev/null
assert_contains "MacBook --visible: Terminal via osascript, command as argv" "osascript:open[-][bash '$HERE/claude-relogin.sh' me --machine macbook --in-pane]" "$(calls)"
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
assert_contains "expiry afterwards" "claude-account[expiry][--ids][me]" "$c"
assert_contains "the login end is read before and after (renewal is proven, not assumed)" "claude-account[expiry][--json][--ids][me]" "$c"
assert_eq "...exactly twice" 2 "$(grep -c 'claude-account\[expiry\]\[--json\]\[--ids\]\[me\]' <<<"$c")"
reset; ANTHROPIC_API_KEY=k CLAUDE_CODE_OAUTH_TOKEN=t CLAUDE_CONFIG_DIR=/elsewhere bash "$RELOGIN" iu --machine mini --in-pane >/dev/null
assert_contains "iu: CLAUDE_CONFIG_DIR stays unset, token env stripped" "ENV cfg=unset browser=$HERE/claude-login-browser.sh acc=iu machine=mini owner=set key=unset tok=unset" "$(calls)"
reset; STUB_LOGIN_RC=1 bash "$RELOGIN" me --machine mini --in-pane >/dev/null 2>"$TMP/err"; rc=$?
assert_eq "failed login: rc 1" 1 "$rc"
assert_not_contains "failed login: no refresh" "refresh" "$(calls)"
assert_contains "failed login: manual fallback named" "Manual fallback" "$(cat "$TMP/err")"
bash "$RELOGIN" me --machine macbook --in-pane >/dev/null 2>&1; assert_eq "--in-pane on the wrong machine is refused" 2 "$?"

D=$(date -r 1798761600 +%Y-%m-%d)   # what the stubbed expiry (1798761600000 ms) renders to
count() { grep -c -- "$1" <<<"$(calls)" || true; }

echo "MacBook: the login runs behind the scenes"
as macbook; reset; : > "$CLAUDE_RELOGIN_LOG"
out=$(STUB_CLAUDE_OUT='signed in sk-ant-oat01-SECRETTOKEN123 accessToken: abcdefghijklmnopqrstuvwxyz0123' bash "$RELOGIN" me --machine macbook); rc=$?
c=$(calls)
assert_eq "rc 0" 0 "$rc"
assert_contains "says it runs in the background" "running in the background" "$out"
assert_contains "login ran on the me dir with the helper as BROWSER" "ENV cfg=$HOME/.claude-me browser=$HERE/claude-login-browser.sh acc=me machine=macbook" "$c"
assert_eq "no Terminal window opened" 0 "$(count 'osascript:open')"
assert_contains "quota cache refreshed" "claude-account[refresh][--ids][me]" "$c"
assert_contains "success notification with the expiry date" "osascript:notify[-][Claude login me][Claude login me: renewed, valid until $D]" "$c"
assert_eq "exactly one notification" 1 "$(count 'osascript:notify')"
assert_contains "output is in the log" "signed in" "$(cat "$CLAUDE_RELOGIN_LOG")"
assert_not_contains "token redacted in the log" "SECRETTOKEN" "$(cat "$CLAUDE_RELOGIN_LOG")"
assert_not_contains "access token value redacted in the log" "abcdefghijklmnopqrstuvwxyz0123" "$(cat "$CLAUDE_RELOGIN_LOG")"
assert_not_contains "no token in any recorded call (notification text included)" "SECRETTOKEN" "$c"

echo "MacBook: a login that fails falls back to an interactive Terminal, closed again after success"
as macbook; reset; : > "$CLAUDE_RELOGIN_LOG"
STUB_LOGIN_RC=1 STUB_CLAUDE_OUT='sk-ant-oat01-SECRETTOKEN123' STUB_TERM_RESULT="ok 2027-01-01" STUB_WINID=777 bash "$RELOGIN" me --machine macbook >/dev/null; rc=$?
c=$(calls)
assert_eq "rc 0" 0 "$rc"
assert_contains "Terminal opened with the interactive login and a result file" "osascript:open[-][bash '$HERE/claude-relogin.sh' me --machine macbook --in-pane --result-file '" "$c"
assert_eq "exactly one window closed" 1 "$(count 'osascript:close')"
assert_contains "...the one we opened, by id" "osascript:close[-][777]" "$c"
assert_contains "success notification" "Claude login me: renewed, valid until 2027-01-01" "$c"
assert_contains "log says why it fell back" "background login failed" "$(cat "$CLAUDE_RELOGIN_LOG")"
assert_not_contains "no token in any recorded call" "SECRETTOKEN" "$c"
reset; STUB_LOGIN_RC=1 STUB_TERM_RESULT="fail 1" bash "$RELOGIN" me --machine macbook >/dev/null; rc=$?
c=$(calls)
assert_eq "fallback fails too: rc 1" 1 "$rc"
assert_eq "...the window stays open" 0 "$(count 'osascript:close')"
assert_contains "...failure notification with the log path" "Claude login me failed - retry with: claude-relogin me (log: $CLAUDE_RELOGIN_LOG)" "$c"
reset; STUB_LOGIN_RC=1 STUB_WIN_EXISTS=false bash "$RELOGIN" me --machine macbook >/dev/null; rc=$?
assert_eq "window closed by the user before the result: rc 1, nothing closed" "1/0" "$rc/$(count 'osascript:close')"
assert_contains "...a closed window is reported, never silent" "osascript:notify[-][Claude login me][Claude login me: the login window was closed before the login finished" "$(calls)"
reset; STUB_CLAUDE_HANG=1 STUB_WIN_EXISTS=false bash "$RELOGIN" me --machine macbook >/dev/null 2>&1
assert_contains "a stuck background login (no output for the idle window) falls back to Terminal" "osascript:open" "$(calls)"
assert_contains "...and says so in the log" "background login failed (rc 3)" "$(cat "$CLAUDE_RELOGIN_LOG")"
reset; bash "$RELOGIN" me --machine macbook --visible >/dev/null
assert_contains "--visible: today's Terminal window, no result file" "osascript:open[-][bash '$HERE/claude-relogin.sh' me --machine macbook --in-pane]" "$(calls)"
assert_eq "--visible: no notification, no close" "0/0" "$(count 'osascript:notify')/$(count 'osascript:close')"

echo "mini: the workspace we created is closed after success; the outcome goes to the MacBook"
as mini; reset
STUB_PANE_RESULT="ok 2027-01-01" bash "$RELOGIN" me >/dev/null; rc=$?
c=$(calls)
assert_eq "rc 0" 0 "$rc"
assert_contains "workspace created" "herdr[workspace][create][--cwd][$HOME][--label][relogin me][--focus]" "$c"
assert_contains "pane run carries a result file" "herdr[pane][run][w9:1][bash '$HERE/claude-relogin.sh' me --machine mini --in-pane --result-file '" "$c"
assert_eq "exactly one workspace closed" 1 "$(count 'herdr\[workspace\]\[close\]')"
assert_contains "...the one created (w9), no other" "herdr[workspace][close][w9]" "$c"
assert_contains "notification over ssh to the MacBook, text as quoted argv" "ssh[-o][BatchMode=yes][-o][ConnectTimeout=8][iumac][osascript - 'Claude login me' 'Claude login me: renewed, valid until 2027-01-01']" "$c"
reset; STUB_PANE_RESULT="fail 1" bash "$RELOGIN" me >/dev/null; rc=$?
c=$(calls)
assert_eq "failed login: rc 1, workspace stays open" "1/0" "$rc/$(count 'herdr\[workspace\]\[close\]')"
assert_contains "...failure notification to the MacBook" "Claude login me failed - retry with: claude-relogin me" "$c"
reset; STUB_WS_LIST=gone bash "$RELOGIN" me >/dev/null; rc=$?
c=$(calls)
assert_eq "workspace closed by the user: nothing closed" "1/0" "$rc/$(count 'herdr\[workspace\]\[close\]')"
assert_contains "...and the owner is told, never silent" "Claude login me: the login workspace was closed before the login finished" "$c"
reset; STUB_PANE_RESULT="ok 2027-01-01" bash "$RELOGIN" me --visible >/dev/null
c=$(calls)
assert_eq "--visible: nothing closed, no notification" "0/0" "$(count 'herdr\[workspace\]\[close\]')/$(count 'osascript - ')"
assert_not_contains "--visible: no result file in the pane command" "--result-file" "$c"

echo "a probe that could not ask never reads as closed"
as macbook; reset
STUB_LOGIN_RC=1 STUB_WIN_EXISTS=error bash "$RELOGIN" me --machine macbook >/dev/null 2>&1
c=$(calls)
assert_eq "osascript probe fails every time: no window closed" 0 "$(count 'osascript:close')"
assert_not_contains "...never concluded as closed" "was closed before" "$c"
assert_contains "...ends with the did-not-finish notification instead (window left open)" "Claude login me did not finish within 0 min - the login window is still open" "$c"
reset; STUB_LOGIN_RC=1 STUB_WIN_EXISTS=garbage bash "$RELOGIN" me --machine macbook >/dev/null 2>&1
assert_not_contains "an unintelligible probe answer is not 'gone' either" "was closed before" "$(calls)"
reset; printf 'false\nerror\nfalse\nfalse\n' > "$TMP/seq"
STUB_LOGIN_RC=1 STUB_WIN_SEQ_FILE="$TMP/seq" bash "$RELOGIN" me --machine macbook >/dev/null 2>&1
c=$(calls)
assert_eq "absent, could-not-ask, absent, absent: only the last two are consecutive (4 probes)" 4 "$(count 'osascript:exists')"
assert_contains "...then it concludes closed, and says so" "was closed before the login finished" "$c"
as mini; reset
STUB_WS_LIST=fail bash "$RELOGIN" me >/dev/null 2>&1
c=$(calls)
assert_eq "herdr list fails every time: workspace not closed" 0 "$(count 'herdr\[workspace\]\[close\]')"
assert_not_contains "...never concluded as closed" "was closed before" "$c"
assert_contains "...did-not-finish notification, workspace left open" "the login workspace is still open" "$c"
reset; STUB_WS_LIST=garbage bash "$RELOGIN" me >/dev/null 2>&1
assert_not_contains "herdr answering garbage is not 'gone'" "was closed before" "$(calls)"
reset; STUB_PANE_RESULT="" bash "$RELOGIN" me >/dev/null 2>&1
assert_contains "no result within the maximum wait, workspace still there: notified, not closed" "the login workspace is still open" "$(calls)"
assert_eq "...nothing closed" 0 "$(count 'herdr\[workspace\]\[close\]')"
as macbook; reset
STUB_LOGIN_RC=1 bash "$RELOGIN" me --machine macbook >/dev/null 2>&1
assert_contains "terminal present but no result within the maximum wait: notified" "the login window is still open" "$(calls)"
assert_eq "...window not closed" 0 "$(count 'osascript:close')"

echo "a planted or empty result file is never read as success"
reset; STUB_LOGIN_RC=1 STUB_TERM_SYMLINK=1 STUB_WIN_EXISTS=false bash "$RELOGIN" me --machine macbook >/dev/null 2>&1
assert_eq "result file replaced by a symlink to an 'ok' file: nothing closed" 0 "$(count 'osascript:close')"
assert_not_contains "...no success notification" "renewed" "$(calls)"
reset; STUB_LOGIN_RC=1 STUB_WIN_EXISTS=false bash "$RELOGIN" me --machine macbook >/dev/null 2>&1
assert_eq "the empty mktemp'd file is not a result either" 0 "$(count 'osascript:close')"
first=$(calls | sed -nE "s/.*--result-file '([^']*)'.*/\1/p" | head -1)
reset; STUB_LOGIN_RC=1 STUB_WIN_EXISTS=false bash "$RELOGIN" me --machine macbook >/dev/null 2>&1
second=$(calls | sed -nE "s/.*--result-file '([^']*)'.*/\1/p" | head -1)
[[ -n "$first" && -n "$second" && "$first" != "$second" ]] && ok "result file names are unpredictable (differ per run)" || bad "result file names are unpredictable" "[$first] [$second]"

echo "GUI session"
reset; : > "$CLAUDE_RELOGIN_LOG"
STUB_SESSION=Background STUB_TERM_RESULT="ok 2027-01-01" bash "$RELOGIN" me --machine macbook >/dev/null; rc=$?
c=$(calls)
assert_eq "outside Aqua: rc 0" 0 "$rc"
assert_not_contains "...no windowless login attempted" "ENV cfg=" "$c"
assert_contains "...Terminal via osascript instead" "osascript:open[-][bash '$HERE/claude-relogin.sh' me --machine macbook --in-pane --result-file '" "$c"
assert_contains "...closed again and notified" "osascript:close[-][4242]" "$c"
assert_contains "...the log says why" "not in the Aqua GUI session (Background)" "$(cat "$CLAUDE_RELOGIN_LOG")"

echo "mini: workspace id comes from the create response"
as mini; reset
STUB_WS_ID=wZ9 STUB_PANE_RESULT="ok 2027-01-01" bash "$RELOGIN" me >/dev/null
c=$(calls)
assert_contains "the workspace_id field is what gets closed" "herdr[workspace][close][wZ9]" "$c"
assert_eq "...exactly one close" 1 "$(count 'herdr\[workspace\]\[close\]')"
reset; STUB_CREATE=noworkspace bash "$RELOGIN" me >/dev/null 2>"$TMP/err"; rc=$?
assert_eq "response without workspace_id: fails loudly (rc 2)" 2 "$rc"
assert_contains "...says what was missing" "gave no pane or workspace id" "$(cat "$TMP/err")"
assert_not_contains "...nothing typed into any pane" "pane][run" "$(calls)"

echo "mini: the login runs in the mini's core (hc run), labelled into the dotfiles space"
export STUB_CORE=running
SPACE_ID="sp-space-repo-$(printf %s "$(cd "$TMP/space-repo" && pwd -P)" | shasum -a 256 | cut -c1-12)"
as mini; reset
STUB_PANE_RESULT="ok 2027-01-01" bash "$RELOGIN" me >/dev/null; rc=$?
c=$(calls)
assert_eq "rc 0" 0 "$rc"
assert_contains "hc run: background, no parent, named, labelled into the space and tab, removed on exit" "hc[run][--bg][--json][--no-parent][--no-notify][--name][relogin-me][--cwd][$HOME][--label][herdr.space=$SPACE_ID][--label][herdr.tab=tb-relogin-me][--rm][bash '$HERE/claude-relogin.sh' me --machine mini --in-pane --result-file '" "$c"
assert_contains "...a failed login drops into a shell, a clean one exits" 'if [ "$rc" -ne 0 ]; then exec "${SHELL:-/bin/zsh}" -l; fi; exit "$rc"' "$c"
assert_not_contains "no classic herdr call" "herdr[" "$c"
assert_eq "the herdr-app doc is read for the space, then once more to name the tab (no entry yet: no write)" "2/0" "$(count 'rpc:doc.get')/$(count 'rpc:doc.set')"
assert_contains "terminal swept after success: hc rm of the address it created, no other" "hc[rm][t9]" "$c"
assert_eq "...exactly one rm" 1 "$(count 'hc\[rm\]')"
assert_not_contains "...never a kill" "hc[kill]" "$c"
assert_contains "notification over ssh to the MacBook" "ssh[-o][BatchMode=yes][-o][ConnectTimeout=8][iumac][osascript - 'Claude login me' 'Claude login me: renewed, valid until 2027-01-01']" "$c"
reset; STUB_DOC_VALUE='{"spaces":[{"id":"spAPP","folder":"'"$TMP/space-repo"'","tabs":[{"id":"tb-relogin-me","name":"3"}]},{"id":"spOther","folder":"/elsewhere"}]}' STUB_PANE_RESULT="ok 2027-01-01" bash "$RELOGIN" me >/dev/null
c=$(calls)
assert_contains "the app's own space entry for the folder wins" "[--label][herdr.space=spAPP][--label][herdr.tab=tb-relogin-me]" "$c"
assert_eq "...the tab is named 'relogin me' (doc.set, compare-and-set on the version read)" "relogin me/7" "$(jq -rs 'map(.value.spaces[0].tabs[0].name + "/" + (.version | tostring)) | .[0] // "none"' "$TMP/doc-sets.jsonl" 2>/dev/null)"
reset; STUB_PANE_RESULT="fail 1" bash "$RELOGIN" me >/dev/null; rc=$?
c=$(calls)
assert_eq "failed login: rc 1, nothing removed or killed" "1/0/0" "$rc/$(count 'hc\[rm\]')/$(count 'hc\[kill\]')"
assert_contains "...failure notification to the MacBook" "Claude login me failed - retry with: claude-relogin me" "$c"
reset; STUB_PANE_RESULT="unchanged 2026-12-01" bash "$RELOGIN" me >/dev/null; rc=$?
assert_eq "unchanged login: rc 1, terminal stays" "1/0" "$rc/$(count 'hc\[rm\]')"
reset; STUB_HC_GET=gone bash "$RELOGIN" me >/dev/null; rc=$?
c=$(calls)
assert_eq "terminal closed by the user: rc 1, nothing removed" "1/0" "$rc/$(count 'hc\[rm\]')"
assert_contains "...and the owner is told, never silent" "Claude login me: the login terminal was closed before the login finished" "$c"
reset; STUB_HC_GET=finished bash "$RELOGIN" me >/dev/null
assert_contains "a finished terminal without a result counts as gone" "the login terminal was closed before the login finished" "$(calls)"
reset; STUB_HC_GET=fail bash "$RELOGIN" me >/dev/null 2>&1
c=$(calls)
assert_not_contains "hc failing to answer is not 'gone'" "was closed before" "$c"
assert_contains "...did-not-finish notification, terminal left open" "the login terminal is still open" "$c"
reset; STUB_HC_GET=garbage bash "$RELOGIN" me >/dev/null 2>&1
assert_not_contains "hc answering garbage is not 'gone' either" "was closed before" "$(calls)"
reset; STUB_PANE_RESULT="" bash "$RELOGIN" me >/dev/null 2>&1
assert_contains "no result within the maximum wait, terminal live: notified, not removed" "the login terminal is still open" "$(calls)"
assert_eq "...nothing removed" 0 "$(count 'hc\[rm\]')"
reset; STUB_PANE_RESULT="ok 2027-01-01" bash "$RELOGIN" me --visible >/dev/null
c=$(calls)
assert_not_contains "--visible: no --rm, no result file, no watcher call" "--rm" "$c"
assert_not_contains "--visible: no result file in the command" "--result-file" "$c"
assert_contains "--visible: always ends in a shell" "--in-pane; exec \"\${SHELL:-/bin/zsh}\" -l" "$c"
assert_eq "--visible: nothing swept, no notification" "0/0" "$(count 'hc\[rm\]')/$(count 'osascript - ')"
reset; STUB_HC_EXISTING=live bash "$RELOGIN" me >/dev/null 2>"$TMP/err"; rc=$?
assert_eq "a login terminal for the account still open: refuses (rc 2)" 2 "$rc"
assert_contains "...says which, and how to close it" "still open on the mini (t5)" "$(cat "$TMP/err")"
assert_not_contains "...started nothing" "hc[run]" "$(calls)"
reset; STUB_HC_EXISTING=finished STUB_PANE_RESULT="ok 2027-01-01" bash "$RELOGIN" me >/dev/null
assert_contains "a finished one is removed first, then the new login starts" "hc[rm][relogin-me]" "$(calls)"
reset; STUB_DOC=fail bash "$RELOGIN" me >/dev/null 2>"$TMP/err"; rc=$?
assert_eq "the doc cannot be read: refuses to guess a space (rc 2)" 2 "$rc"
assert_not_contains "...started nothing" "hc[run]" "$(calls)"
reset; STUB_HC_RUN=fail bash "$RELOGIN" me >/dev/null 2>"$TMP/err"; rc=$?
assert_eq "hc run fails: rc 2, no watcher notification" "2/0" "$rc/$(count 'osascript - ')"
reset; STUB_HC_ADDR='t9; rm -rf /' bash "$RELOGIN" me >/dev/null 2>"$TMP/err"; rc=$?
assert_eq "a malformed address is never passed on (rc 2)" 2 "$rc"
STUB_CORE="not running"; reset
STUB_PANE_RESULT="ok 2027-01-01" bash "$RELOGIN" me >/dev/null
assert_not_contains "core not running per launchd: hc is never called (it would start a stray core)" "hc[" "$(calls)"
assert_contains "...the classic workspace instead" "herdr[workspace][create]" "$(calls)"
STUB_CORE=running
as mini; reset
CLAUDE_RELOGIN_FOREGROUND=0 STUB_PANE_RESULT="ok 2027-01-01" bash "$RELOGIN" me >/dev/null
for _ in $(seq 1 20); do grep -q "hc\[rm\]" "$LOG" && break; sleep 1; done
assert_contains "detached watcher sweeps the terminal it created" "hc[rm][t9]" "$(calls)"
out=$(bash "$RELOGIN" me --dry-run 2>&1); reset
assert_eq "core dry run: nothing called" "" "$(calls)"
assert_contains "core dry run: the hc run step, labelled" "'hc' 'run' '--bg'" "$out"
assert_contains "core dry run: space label placeholder" "herdr.space=<the dotfiles space>" "$out"
assert_contains "core dry run: sweep" "'hc' 'rm'" "$out"
unset STUB_CORE

echo "idle watchdog: per-run output, SIGKILL after the grace period"
as macbook; reset; : > "$CLAUDE_RELOGIN_LOG"; rm -f "$TMP/claude.pid"
STUB_CLAUDE_HANG=trap STUB_WIN_EXISTS=false bash "$RELOGIN" me --machine macbook >/dev/null 2>&1
cp_=$(cat "$TMP/claude.pid" 2>/dev/null)
[[ -n "$cp_" ]] && ! kill -0 "$cp_" 2>/dev/null && ok "a login that ignores SIGTERM is SIGKILLed" || bad "a login that ignores SIGTERM is SIGKILLed" "pid [$cp_]"
assert_contains "...and counted as stuck, falling back" "background login failed (rc 3)" "$(cat "$CLAUDE_RELOGIN_LOG")"

echo "log: owner-only, widely redacted"
rm -f "$CLAUDE_RELOGIN_LOG"; reset
STUB_CLAUDE_OUT='open https://x/cb?code=abcdef123456&state=zz11yy22xx Bearer abcdefgh12345 "refresh_token":"abcdefgh12345678" paste the code' bash "$RELOGIN" me --machine macbook >/dev/null
l=$(cat "$CLAUDE_RELOGIN_LOG")
assert_eq "log created with mode 600" 600 "$(stat -f %Lp "$CLAUDE_RELOGIN_LOG")"
for secret in abcdef123456 zz11yy22xx abcdefgh12345; do assert_not_contains "log has no $secret" "$secret" "$l"; done
assert_contains "...but keeps the harmless words" "paste the code" "$l"
chmod 644 "$CLAUDE_RELOGIN_LOG"; reset
bash "$RELOGIN" me --machine macbook >/dev/null
assert_eq "an existing log is tightened to 600" 600 "$(stat -f %Lp "$CLAUDE_RELOGIN_LOG")"
reset; err=$(CLAUDE_LOGIN_MSG_FILE="$TMP/helper-msgs" CLAUDE_LOGIN_ACCOUNT=me CLAUDE_LOGIN_MACHINE=macbook STUB_OPENBIN=fail bash "$BROWSER_SH" 'https://x/a?code=abcdef123456&state=zz11yy22xx' 2>&1)
assert_not_contains "the helper's direct writes to a file are redacted too" "abcdef123456" "$(cat "$TMP/helper-msgs")"

echo "detached workers (CLAUDE_RELOGIN_FOREGROUND=0)"
as macbook; reset; rm -f "$CLAUDE_RELOGIN_LOG"
out=$(CLAUDE_RELOGIN_FOREGROUND=0 bash "$RELOGIN" me --machine macbook); rc=$?
assert_eq "returns at once with rc 0" "0" "$rc"
assert_contains "...says it runs in the background" "running in the background" "$out"
for _ in $(seq 1 20); do grep -q "osascript:notify" "$LOG" && break; sleep 1; done
assert_contains "the detached worker finishes on its own and notifies" "osascript:notify[-][Claude login me][Claude login me: renewed" "$(calls)"
assert_eq "...worker output went to the owner-only log, not the caller's stdout" "1" "$(grep -c 'background login for' "$CLAUDE_RELOGIN_LOG")"
assert_not_contains "...caller's stdout stays clean" "background login for" "$out"
as mini; reset
CLAUDE_RELOGIN_FOREGROUND=0 STUB_PANE_RESULT="ok 2027-01-01" bash "$RELOGIN" me >/dev/null; rc=$?
for _ in $(seq 1 20); do grep -q "herdr\[workspace\]\[close\]" "$LOG" && break; sleep 1; done
assert_contains "detached watcher closes the workspace it created" "herdr[workspace][close][w9]" "$(calls)"

echo "in-pane result file"
as mini; reset; rf="$TMP/result-ok"; rm -f "$rf"
bash "$RELOGIN" me --machine mini --in-pane --result-file "$rf" >/dev/null
assert_eq "success writes ok + expiry date" "ok $D" "$(cat "$rf")"
reset; rf="$TMP/result-fail"; rm -f "$rf"
STUB_LOGIN_RC=1 bash "$RELOGIN" me --machine mini --in-pane --result-file "$rf" >/dev/null 2>&1
assert_eq "failure writes fail" "fail 1" "$(cat "$rf")"

echo "renewal is proven: the login end must move"
D0=$(date -r 1796169600 +%Y-%m-%d)   # the stubbed expiry before the login
UNCH="login finished but the Keychain login did not change (still valid until $D0)"
as mini; reset; rf="$TMP/result-unchanged"; rm -f "$rf"
STUB_EXPIRY_AFTER=1796169600000 bash "$RELOGIN" me --machine mini --in-pane --result-file "$rf" >/dev/null 2>"$TMP/err"; rc=$?
assert_eq "unchanged expiry: rc 1" 1 "$rc"
assert_eq "...result says unchanged + the date" "unchanged $D0" "$(cat "$rf")"
assert_contains "...and the terminal says why" "$UNCH" "$(cat "$TMP/err")"
reset; rf="$TMP/result-older"; rm -f "$rf"
STUB_EXPIRY_AFTER=1790000000000 bash "$RELOGIN" me --machine mini --in-pane --result-file "$rf" >/dev/null 2>&1; rc=$?
assert_eq "an older expiry than before is no renewal either" "1/unchanged $(date -r 1790000000 +%Y-%m-%d)" "$rc/$(cat "$rf")"
reset; rf="$TMP/result-null-after"; rm -f "$rf"
STUB_EXPIRY_AFTER=none bash "$RELOGIN" me --machine mini --in-pane --result-file "$rf" >/dev/null 2>&1; rc=$?
assert_eq "an unreadable item afterwards is no proof" "1/unchanged " "$rc/$(cat "$rf")"
reset; rf="$TMP/result-first"; rm -f "$rf"
STUB_EXPIRY_BEFORE=none bash "$RELOGIN" me --machine mini --in-pane --result-file "$rf" >/dev/null 2>&1; rc=$?
assert_eq "a first login (nothing before) counts when an expiry exists afterwards" "0/ok $D" "$rc/$(cat "$rf")"
as mini; reset; rm -f "$rf"
STUB_EXPIRY_BEFORE=fail STUB_EXPIRY_AFTER=$(( ($(date +%s) + 10 * 86400) * 1000 )) bash "$RELOGIN" me --machine mini --in-pane --result-file "$rf" >/dev/null 2>&1; rc=$?
assert_eq "a failed read before the login is no proof: an old-looking expiry after it is unchanged" "1" "$rc"
as mini; reset; rm -f "$rf"
STUB_EXPIRY_BEFORE=fail STUB_EXPIRY_AFTER=$(( ($(date +%s) + 30 * 86400) * 1000 )) bash "$RELOGIN" me --machine mini --in-pane --result-file "$rf" >/dev/null 2>&1; rc=$?
assert_eq "...but a fresh 30-day login after a failed read is renewed" "0" "$rc"
reset; rf="$TMP/result-moved"; rm -f "$rf"
bash "$RELOGIN" me --machine mini --in-pane --result-file "$rf" >/dev/null 2>&1; rc=$?
assert_eq "a moved expiry is a renewal" "0/ok $D" "$rc/$(cat "$rf")"

echo "MacBook: a login that changed nothing is reported as such, not as renewed"
as macbook; reset; : > "$CLAUDE_RELOGIN_LOG"
STUB_EXPIRY_AFTER=1796169600000 bash "$RELOGIN" me --machine macbook >/dev/null; rc=$?
c=$(calls)
assert_eq "rc 1" 1 "$rc"
assert_contains "notification names the unchanged Keychain login" "osascript:notify[-][Claude login me][$UNCH]" "$c"
assert_not_contains "...never 'renewed'" "renewed" "$c"
assert_eq "...no Terminal retry window" 0 "$(count 'osascript:open')"
assert_contains "log carries the same text" "$UNCH" "$(cat "$CLAUDE_RELOGIN_LOG")"
reset; STUB_LOGIN_RC=1 STUB_TERM_RESULT="unchanged $D0" STUB_WINID=555 bash "$RELOGIN" me --machine macbook >/dev/null; rc=$?
c=$(calls)
assert_eq "Terminal fallback that changed nothing: rc 1, window stays open" "1/0" "$rc/$(count 'osascript:close')"
assert_contains "...with the unchanged notification" "osascript:notify[-][Claude login me][$UNCH]" "$c"

echo "mini: an unchanged login keeps the workspace open and tells the MacBook"
as mini; reset
STUB_PANE_RESULT="unchanged $D0" bash "$RELOGIN" me >/dev/null; rc=$?
c=$(calls)
assert_eq "rc 1, workspace stays open" "1/0" "$rc/$(count 'herdr\[workspace\]\[close\]')"
assert_contains "notification over ssh to the MacBook" "ssh[-o][BatchMode=yes][-o][ConnectTimeout=8][iumac][osascript - 'Claude login me' '$UNCH']" "$c"
assert_not_contains "...never 'renewed'" "renewed" "$c"

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
as macbook; reset; out=$(bash "$RELOGIN" me --machine macbook --dry-run 2>&1)
assert_eq "macbook dry run: no stub called" "" "$(calls)"
assert_contains "macbook dry run: detached worker, no window" "would start detached: bash '$HERE/claude-relogin.sh' me --machine macbook --worker" "$out"
assert_contains "macbook dry run: success notification" "'osascript' '-' 'Claude login me' 'Claude login me: renewed, valid until <date>'" "$out"
assert_contains "macbook dry run: Terminal fallback and its close" "close of that window id" "$out"
as mini; reset; out=$(bash "$RELOGIN" me --dry-run 2>&1)
assert_contains "mini dry run: watcher closes the workspace" "'herdr' 'workspace' 'close'" "$out"
assert_contains "mini dry run: notification over ssh" "osascript - " "$out"
assert_contains "iu dry run: config dir unset" "'-u' 'CLAUDE_CONFIG_DIR' 'USER=" "$(bash "$RELOGIN" iu --dry-run 2>&1)"
assert_contains "me dry run: config dir set" "CLAUDE_CONFIG_DIR=$HOME/.claude-me" "$(bash "$RELOGIN" me --dry-run 2>&1)"
reset; out=$(bash "$RELOGIN" me --ask --dry-run 2>&1)
assert_eq "--ask --dry-run: no dialog" "" "$(calls)"
assert_contains "--ask --dry-run: prints the ask" "'ask' 'Claude login '\\''me'\\''" "$out"

echo "argument errors"
bash "$RELOGIN" nobody >/dev/null 2>&1; assert_eq "unknown account" 2 "$?"
bash "$RELOGIN" nope >/dev/null 2>&1; assert_eq "unregistered account" 2 "$?"
bash "$RELOGIN" off --dry-run >/dev/null 2>&1; assert_eq "disabled account (first login) allowed" 0 "$?"
bash "$RELOGIN" me --machine laptop >/dev/null 2>&1; assert_eq "bad machine" 2 "$?"
bash "$RELOGIN" >/dev/null 2>&1; assert_eq "no id" 2 "$?"

echo
if (( fail )); then printf '\033[31m%d failed\033[0m, %d passed\n' "$fail" "$pass"; exit 1; fi
printf '\033[32mall %d passed\033[0m\n' "$pass"
