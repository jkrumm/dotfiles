#!/usr/bin/env bash
# claude-relogin — one-click re-login of a Claude account (docs/claude-accounts.md §Re-login).
#
#   claude-relogin <id> [--machine mini|macbook] [--ask [--reason <text>]] [--visible] [--dry-run]
#
# Logins are per machine: the mini and the MacBook keep separate Keychain items, so a login happens on the machine
# that owns the credential (--machine, default: this one). It runs `claude auth login --claudeai` with BROWSER set to
# claude-login-browser.sh (never `ssh mini claude …`: the login Keychain is only reachable from the GUI session). The
# helper opens the authorize URL in the browser signed in to the account (registry `loginBrowser`); the owner clicks
# approve, no copy/paste. Afterwards `claude-account refresh --ids <id>` runs and the owner gets a native notification
# ("Claude login me: renewed, valid until <date>", or a failure line with the log path), on the MacBook. "Renewed"
# is proven, not assumed: the Keychain item's refresh_expires_at is read before and after the login (`claude-account
# expiry --json --ids <id>`, which also reads a disabled account's first login) and must be newer afterwards; a login
# that finishes without changing it is a failure ("login finished but the Keychain login did not change").
# A registered but disabled account is accepted: its first login is how it comes out of the dark.
#
#   MacBook   runs behind the scenes: a detached worker, no window; the CLI's output (tokens redacted) goes to
#             ~/Library/Logs/claude-relogin.log. Only if that cannot complete (the callback never arrived within the
#             idle watchdog, the Keychain is locked, any failure) it opens Terminal with the interactive login, and
#             closes exactly that window after success.
#   mini      a terminal in the mini's herdr-core (`hc run`; the core is a launchd GUI-session child, so the Keychain
#             works), labelled into the dotfiles space as the tab `relogin <id>`, no parent. After success it exits and
#             removes itself a few seconds later, only that terminal; the outcome notification goes to the MacBook over
#             ssh. A failed login drops into a shell there, left open for the paste fallback. Without a running core
#             (checked through launchd first: an `hc` call would start a stray one) it falls back to a classic herdr
#             workspace `relogin <id>`.
#   --visible   today's behaviour for debugging: a Terminal window / herdr terminal that stays open, no worker, no
#               notification.
#
#   (no flag)   from any machine: reach the owning machine and start the login there
#   --ask       instead push a native approval dialog to the MacBook (scripts/ask-human.sh); its command is the
#               line above, so one click starts the login. Never runs anything by itself.
#   --dry-run   print exactly what would run, run nothing
#   --in-pane / --worker / --watch <hc:address|workspace> / --result-file <file>   internal
#
# Automating the login itself (driving the browser, reading the mail) is out of bounds: a human always approves.
# Test seams: CLAUDE_RELOGIN_ASK_HUMAN, CLAUDE_RELOGIN_PANE_WAIT, CLAUDE_RELOGIN_LOG, CLAUDE_RELOGIN_POLL_S,
# CLAUDE_RELOGIN_CLOSE_DELAY_S, CLAUDE_RELOGIN_BG_IDLE_S, CLAUDE_RELOGIN_MAX_WAIT_S, CLAUDE_RELOGIN_ABSENT_N,
# CLAUDE_RELOGIN_TERM_GRACE_S, CLAUDE_RELOGIN_FOREGROUND (run the workers inline);
# CLAUDE_RELOGIN_SPACE_DIR (the repo whose herdr space the tab joins; default ~/SourceRoot/dotfiles);
# PATH stubs for ssh, hc, herdr, osascript, launchctl, claude, claude-account.
set -u
SELF="$(readlink -f "${BASH_SOURCE[0]}")" # ~/.local/bin/claude-relogin is a symlink into the checkout
HERE="$(dirname "$SELF")"
HELPER="$HERE/claude-login-browser.sh"
# shellcheck source=lib/claude-login.sh
source "$HERE/lib/claude-login.sh"

REGISTRY="${CLAUDE_ACCOUNTS_REGISTRY:-$HERE/../config/claude-accounts.json}"
ASK_HUMAN="${CLAUDE_RELOGIN_ASK_HUMAN:-$HERE/ask-human.sh}"
PANE_WAIT="${CLAUDE_RELOGIN_PANE_WAIT:-1}"
RELOGIN_LOG="${CLAUDE_RELOGIN_LOG:-$HOME/Library/Logs/claude-relogin.log}"
POLL_S="${CLAUDE_RELOGIN_POLL_S:-2}"
CLOSE_DELAY_S="${CLAUDE_RELOGIN_CLOSE_DELAY_S:-4}"
BG_IDLE_S="${CLAUDE_RELOGIN_BG_IDLE_S:-600}"   # no new log output for this long = the background login is stuck
FOREGROUND="${CLAUDE_RELOGIN_FOREGROUND:-0}"
MAX_WAIT_S="${CLAUDE_RELOGIN_MAX_WAIT_S:-3600}"   # longest the opener waits for a login terminal to report; then it notifies and leaves it open
ABSENT_N="${CLAUDE_RELOGIN_ABSENT_N:-3}"          # consecutive clean "it is gone" answers before a terminal counts as closed
TERM_GRACE_S="${CLAUDE_RELOGIN_TERM_GRACE_S:-5}"  # SIGTERM, this long, then SIGKILL
export PATH="$PATH:$HOME/.local/bin:/opt/homebrew/bin:$HOME/.bun/bin" # appended: a non-login ssh shell lacks them, an existing PATH entry (or a test stub) wins
REMOTE_PATH='export PATH="$HOME/.local/bin:/opt/homebrew/bin:$HOME/.bun/bin:$PATH"'
# What a remote shell runs to start the relogin on its own machine ($HOME is that machine's).
# shellcheck disable=SC2016
REMOTE_SCRIPT='bash "$HOME/SourceRoot/dotfiles/scripts/claude-relogin.sh"'
SAMPLE_URL='https://claude.ai/oauth/authorize?client_id=sample&response_type=code&redirect_uri=http%3A%2F%2Flocalhost%3A58876%2Fcallback&scope=user%3Ainference&state=sample'

die() { echo "claude-relogin: $*" >&2; exit 2; }

id=""; machine=""; ask=0; dry=0; in_pane=0; reason=""; visible=0; worker=0; watch_ws=""; result_file=""; tunnel_pid_file=""
while (( $# )); do
  case "$1" in
    --machine) [[ $# -ge 2 ]] || die "--machine needs mini or macbook"; machine=$2; shift ;;
    --reason) [[ $# -ge 2 ]] || die "--reason needs a text"; reason=$2; shift ;;
    --ask) ask=1 ;;
    --dry-run) dry=1 ;;
    --in-pane) in_pane=1 ;;
    --visible) visible=1 ;;
    --worker) worker=1 ;;
    --watch) [[ $# -ge 2 ]] || die "--watch needs a terminal or workspace id"; watch_ws=$2; shift ;;
    --result-file) [[ $# -ge 2 ]] || die "--result-file needs a path"; result_file=$2; shift ;;
    -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option $1" ;;
    *) [[ -z "$id" ]] || die "one account id only"; id=$1 ;;
  esac
  shift
done
[[ -n "$id" ]] || die "usage: claude-relogin <id> [--machine mini|macbook] [--ask] [--visible] [--dry-run]"
[[ "$id" =~ ^[A-Za-z0-9_-]+$ ]] || die "bad account id '$id'"
# A registered but disabled account is allowed: its first login is how a new account comes out of the dark.
jq -e --arg id "$id" '.accounts | has($id)' "$REGISTRY" >/dev/null 2>&1 \
  || die "'$id' is not a registered account in $REGISTRY ($(jq -r '.accounts | keys_unsorted | join(", ")' "$REGISTRY" 2>/dev/null))"

here=$(login_local_machine)
machine=${machine:-$here}
case "$machine" in mini|macbook) ;; *) die "--machine must be mini or macbook" ;; esac
app=$(login_browser_for "$REGISTRY" "$id") || die "cannot read loginBrowser for '$id' from $REGISTRY"

# Run a command, or (dry run) print it shell-quoted.
step() {
  if (( dry )); then
    local w out=""
    for w in "$@"; do out="$out $(login_shquote "$w")"; done
    echo "would run:$out"
    return 0
  fi
  "$@"
}

# ── --ask: a dialog on the MacBook whose command starts the login, so the owner clicks once ───────
if (( ask )); then
  cmd="$REMOTE_SCRIPT $id --machine $machine"
  text="Claude login '$id' on the $machine needs a new /login${reason:+ ($reason)}. Run starts the login on the $machine and opens the approval page in ${app:-your default browser}; approve there, a notification follows. Nothing runs until you click Run."
  if [[ "$here" == macbook ]]; then
    # this IS the MacBook: show the dialog here, no ssh self-loop
    (( dry )) && echo "would set: HUMAN_QUEUE_MAC_HOST=local"
    HUMAN_QUEUE_MAC_HOST=local step bash "$ASK_HUMAN" ask "$text" --cmd "$cmd"
  else
    step bash "$ASK_HUMAN" ask "$text" --cmd "$cmd"
  fi
  exit $?
fi

# ── shared pieces ────────────────────────────────────────────────────────────────────────────────
login_env() { # [extra NAME=value…] — builds login_cmd
  local dir
  dir=$(jq -r --arg id "$id" '.accounts[$id].dir // ""' "$REGISTRY")
  # env wants every -u before the first NAME=value; iu owns the default ~/.claude, so CLAUDE_CONFIG_DIR must stay
  # unset for it (setting it changes the Keychain service)
  login_cmd=(env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_BASE_URL)
  [[ -z "$dir" ]] && login_cmd+=(-u CLAUDE_CONFIG_DIR)
  login_cmd+=("USER=${USER:-$(id -un)}" "BROWSER=$HELPER" "CLAUDE_LOGIN_ACCOUNT=$id" "CLAUDE_LOGIN_MACHINE=$machine" "CLAUDE_LOGIN_OWNER_PID=$$" "CLAUDE_LOGIN_TUNNEL_PID_FILE=$tunnel_pid_file")
  [[ -n "$dir" ]] && login_cmd+=("CLAUDE_CONFIG_DIR=${dir/#\~/$HOME}")
  login_cmd+=("$@" claude auth login --claudeai)
}
account_cli() { if command -v claude-account >/dev/null 2>&1; then claude-account "$@"; else bun "$HERE/claude-account.ts" "$@"; fi; }
stamp() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
# Nothing token-shaped may reach the log, whatever the CLI prints (lib/claude-login.sh).
redact() { login_redact; }
# End of the account's login (refresh token) as epoch ms; empty when the account has no login item yet (a first login),
# "unknown" when the read itself failed (CLI or Keychain error, unparseable answer). --ids: a disabled account too.
expiry_ms() {
  local out ms
  out=$(account_cli expiry --json --ids "$id" 2>/dev/null) || { echo unknown; return 0; }
  ms=$(jq -er --arg id "$id" '.accounts[] | select(.id == $id) | .refresh_expires_at // ""' <<<"$out" 2>/dev/null) || { echo unknown; return 0; }
  [[ -z "$ms" || "$ms" =~ ^[0-9]+$ ]] && echo "$ms" || echo unknown
  return 0
}
ms_date() { [[ "${1:-}" =~ ^[0-9]+$ ]] && date -r "$(($1 / 1000))" +%Y-%m-%d; return 0; } # <epoch ms> -> YYYY-MM-DD, empty when unknown
# A login renewed only if the end of the refresh token moved: <after> exists and is newer than <before>, or there was no
# login before. A failed "before" read proves nothing, so then only a fresh 30-day login counts (ends > 29 d from now).
login_renewed() { # <before> <after>
  [[ "$2" =~ ^[0-9]+$ ]] || return 1
  [[ -z "$1" ]] && return 0
  [[ "$1" == unknown ]] && { (( $2 > ($(date +%s) + 29 * 86400) * 1000 )); return; }
  (( $2 > $1 ))
}
ok_text()   { echo "Claude login $id: renewed, valid until ${1:-unknown}"; }
unchanged_text() { echo "login finished but the Keychain login did not change (still valid until ${1:-unknown})"; }
fail_text() { echo "Claude login $id failed - retry with: claude-relogin $id (log: $RELOGIN_LOG)"; }
gone_text() { echo "Claude login $id: the $1 was closed before the login finished - retry with: claude-relogin $id (log: $RELOGIN_LOG)"; }
timeout_text() { echo "Claude login $id did not finish within $((MAX_WAIT_S / 60)) min - the $1 is still open (log: $RELOGIN_LOG)"; }

# Native macOS notification on the MacBook (locally there, over ssh from the mini). Text and title reach AppleScript
# as argv, the script on stdin; the text is built from the id, a date and the log path only, never from CLI output.
NOTIFY_OSA='on run argv
  display notification (item 2 of argv) with title (item 1 of argv)
end run'
notify() { # <text> — best effort
  local title="Claude login $id" rc=0
  if (( dry )); then
    if [[ "$here" == macbook ]]; then step osascript - "$title" "$1"
    else step ssh -o BatchMode=yes -o ConnectTimeout=8 iumac "osascript - $(login_shquote "$title") $(login_shquote "$1")"; fi
    return 0
  fi
  if [[ "$here" == macbook ]]; then
    printf '%s\n' "$NOTIFY_OSA" | osascript - "$title" "$1" >/dev/null 2>&1 || rc=$?
  else
    printf '%s\n' "$NOTIFY_OSA" | ssh -o BatchMode=yes -o ConnectTimeout=8 iumac "osascript - $(login_shquote "$title") $(login_shquote "$1")" >/dev/null 2>&1 || rc=$?
  fi
  (( rc == 0 )) || stamp "notification could not be shown (rc $rc)" >&2
  return 0
}

# Every osascript call is bounded: a wedged WindowServer must not hang a worker (exit 142 = timed out).
bounded() { perl -e 'alarm 20; exec @ARGV' -- "$@"; }
# True in the logged-in GUI session. iumac's userland sshd runs inside it (measured: ssh iumac launchctl managername
# = Aqua), so the common ssh hop stays windowless; a Background/System session cannot reach the login Keychain or
# WindowServer and goes straight to the Terminal path. (`launchctl asuser` would need root.)
gui_session() { [[ "$(launchctl managername 2>/dev/null)" == Aqua ]]; }

# Terminal windows on the MacBook, addressed by id: the one we open is the only one we ever close. The scripts reach
# osascript on stdin, the id as argv.
OSA_OPEN='on run argv
  tell application "Terminal"
    activate
    do script (item 1 of argv)
    return id of front window
  end tell
end run'
OSA_EXISTS='on run argv
  tell application "Terminal" to return (exists window id (item 1 of argv as integer))
end run'
OSA_CLOSE='on run argv
  tell application "Terminal" to close (window id (item 1 of argv as integer)) saving no
end run'
open_terminal() { printf '%s\n' "$OSA_OPEN" | bounded osascript - "$1"; } # <command> — prints the new window's id
close_window() { printf '%s\n' "$OSA_CLOSE" | bounded osascript - "$1" >/dev/null 2>&1; } # <id>

# Presence probes answer 0 = present, 1 = absent (a clean answer), 2 = could not ask (osascript/herdr failed, timed
# out, answered something unexpected). Only await_result decides "gone", after ABSENT_N clean absents in a row.
probe_window() { # <id>
  local out
  out=$(printf '%s\n' "$OSA_EXISTS" | bounded osascript - "$1" 2>/dev/null) || return 2
  case "$out" in true) return 0 ;; false) return 1 ;; *) return 2 ;; esac
}
probe_workspace() { # <workspace id>
  local out
  out=$(herdr workspace list 2>/dev/null) || return 2
  jq -e '.result.workspaces | type == "array"' <<<"$out" >/dev/null 2>&1 || return 2
  jq -e --arg ws "$1" '[.result.workspaces[].workspace_id] | index($ws) != null' <<<"$out" >/dev/null 2>&1
}
# ── herdr-core (hc): the mini's login terminal ───────────────────────────────────────────────────
CORE_LABEL=com.jkrumm.herdr-core
SPACE_DIR="${CLAUDE_RELOGIN_SPACE_DIR:-$HOME/SourceRoot/dotfiles}"
APP_DOC=herdr-app
# True when hc exists and launchd has the core running. HC_SESSION names another core (a scratch one): its owner started it.
# Never call hc otherwise: an hc call starts a stray core when none runs.
hc_usable() {
  command -v hc >/dev/null 2>&1 || return 1
  [[ -n "${HC_SESSION:-}" ]] && return 0
  launchctl print "gui/$(id -u)/$CORE_LABEL" 2>/dev/null | grep -q 'state = running'
}
sha12() { printf %s "$1" | shasum -a 256 | cut -c1-12; }
# One JSON-RPC call over `hc connect`; prints the answer line. rc 1 when nothing usable came back.
hc_rpc() { # <method> <params-json>
  local req out
  req=$(jq -nc --arg m "$1" --argjson p "$2" '{jsonrpc:"2.0",id:1,method:$m,params:$p}') || return 1
  out=$(printf '%s\n' "$req" | bounded hc connect 2>/dev/null) || return 1
  out=$(jq -c 'select(.id == 1)' <<<"$out" 2>/dev/null | head -1)
  [[ -n "$out" ]] || return 1
  printf '%s' "$out"
}
# The dotfiles space, rd's rule (remote-dev.sh hc_space_id): the herdr-app doc entry whose folder is the repo root, else the
# stable id from the full root. Fails when the doc cannot be read: a space is never made up from a call that told nothing.
hc_space_id() {
  local root doc kind id
  root=$(cd "$SPACE_DIR" 2>/dev/null && pwd -P) || root=$SPACE_DIR
  doc=$(hc_rpc doc.get "$(jq -nc --arg n "$APP_DOC" '{name:$n}')") || return 1
  kind=$(jq -r 'if .error then (.error.data.kind // "error") else empty end' <<<"$doc" 2>/dev/null)
  [[ -z "$kind" || "$kind" == not_found ]] || return 1
  id=$(jq -r --arg a "$SPACE_DIR" --arg b "$root" '((.result.value | objects | .spaces | arrays) // [])
    | map(select(type == "object" and ((.folder // "") | . == $a or . == $b))) | .[0].id // empty' <<<"$doc" 2>/dev/null)
  if [[ -n "$id" ]]; then printf %s "$id"; else printf 'sp-%s-%s' "$(basename "$root")" "$(sha12 "$root")"; fi
}
# Name the tab "relogin <id>" once the app has an entry for it (it adopts a labelled tab only after it saw the terminal),
# compare-and-set on the doc, retried on a conflict. Best effort: the tab is numbered when this never lands.
name_tab() { # <tab id> <name>
  local i doc version value resp
  for i in 1 2 3; do
    doc=$(hc_rpc doc.get "$(jq -nc --arg n "$APP_DOC" '{name:$n}')") || return 0
    jq -e '.error' <<<"$doc" >/dev/null 2>&1 && return 0
    version=$(jq -r '.result.version // empty' <<<"$doc")
    [[ -n "$version" ]] || return 0
    value=$(jq -c --arg id "$1" --arg n "$2" '.result.value
      | if type == "object" and ((.spaces | type) == "array")
           and any(.spaces[] | objects | .tabs | arrays | .[] | objects; .id == $id and .name != $n)
        then .spaces |= map(if type == "object" and ((.tabs | type) == "array")
                             then .tabs |= map(if type == "object" and .id == $id then .name = $n else . end) else . end)
        else empty end' <<<"$doc" 2>/dev/null)
    [[ -n "$value" ]] || return 0
    resp=$(hc_rpc doc.set "$(jq -nc --arg n "$APP_DOC" --argjson v "$value" --argjson ver "$version" '{name:$n,version:$ver,value:$v}')") || return 0
    jq -e '.error.data.kind == "conflict"' <<<"$resp" >/dev/null 2>&1 || return 0
  done
  return 0
}
# hc terminal names: 1-32 of a-z 0-9 - _
hc_term_name() { local n; n=$(printf 'relogin-%s' "$1" | tr '[:upper:]' '[:lower:]'); printf %s "${n:0:32}"; }
probe_terminal() { # <address> — 0 live, 1 gone (not found or finished), 2 could not ask
  local out rc=0
  out=$(bounded hc get "$1" --json 2>/dev/null) || rc=$?
  (( rc == 3 )) && return 1
  (( rc == 0 )) || return 2
  case "$(jq -r '.state // empty' <<<"$out" 2>/dev/null)" in live) return 0 ;; finished) return 1 ;; *) return 2 ;; esac
}
# A private empty file (mktemp: unpredictable name, mode 600, ours). Content counts only if it is a regular file we own.
new_result_file() { mktemp "${TMPDIR:-/tmp}/claude-relogin-result.XXXXXX"; }
result_ready() { [[ -f "$1" && ! -L "$1" && -O "$1" && -s "$1" ]]; }
# The log holds nothing secret (redacted) but names accounts and URLs: owner-only.
ensure_log() { mkdir -p "$(dirname "$RELOGIN_LOG")"; ( umask 077; : >>"$RELOGIN_LOG" ); chmod 600 "$RELOGIN_LOG" 2>/dev/null; return 0; }
# Detached worker (same script, another mode); inline when a test asks for it.
spawn_worker() { # <args…>
  if [[ "$FOREGROUND" == 1 ]]; then bash "$SELF" "$@"; return; fi
  ensure_log
  nohup bash "$SELF" "$@" </dev/null >>"$RELOGIN_LOG" 2>&1 &
}
# Wait for the login terminal's result file; prints its content. `probe` is how to ask whether the terminal still
# exists. Status: 0 result, 1 the terminal is gone (ABSENT_N clean absents in a row; a probe that could not ask never
# counts), 3 nothing within MAX_WAIT_S. The caller notifies on 1 and 3 and leaves the terminal alone.
await_result() { # <file> <probe-command…>
  local f=$1 absent=0 waited=0 rc; shift
  while ! result_ready "$f"; do
    rc=0; "$@" || rc=$?
    case $rc in
      0|2) absent=0 ;;
      *) absent=$((absent + 1)) ;;
    esac
    if (( absent >= ABSENT_N )); then result_ready "$f" && break; return 1; fi
    (( waited >= MAX_WAIT_S )) && return 3
    sleep "$POLL_S"; waited=$((waited + POLL_S))
  done
  cat "$f"
}
is_ok() { [[ "$1" == ok || "$1" == "ok "* ]]; }
is_unchanged() { [[ "$1" == unchanged || "$1" == "unchanged "* ]]; }
# Stop a process: SIGTERM, a grace period, then SIGKILL.
kill_bounded() { # <pid>
  local i
  kill "$1" 2>/dev/null || return 0
  for ((i = 0; i < TERM_GRACE_S; i++)); do sleep 1; kill -0 "$1" 2>/dev/null || return 0; done
  kill -9 "$1" 2>/dev/null
  return 0
}

# ── --in-pane: the login itself, in this terminal ────────────────────────────────────────────────
if (( in_pane )); then
  [[ "$machine" == "$here" ]] || die "--in-pane runs on the machine that owns the login ($machine), this is the $here"
  # This process owns the login, and with it the reverse tunnel the helper may start (its pid lands in this file):
  # whatever way we exit, the tunnel goes too. A result file (written last, atomically) tells whoever opened this
  # terminal how it ended, so it can close the window and notify.
  tunnel_pid_file=$(mktemp "${TMPDIR:-/tmp}/claude-relogin-tunnel.XXXXXX") || die "mktemp failed"
  write_result() { # temp file next to the target (mktemp, never a predictable name), then an atomic rename
    local t
    [[ -n "$result_file" ]] && ! (( dry )) || return 0
    t=$(mktemp "$result_file.XXXXXX") && printf '%s\n' "$1" > "$t" && mv "$t" "$result_file"
    return 0
  }
  finish() { # exit trap: tunnel down, and a result for the opener even when we were interrupted
    local p rc=$?
    p=$(cat "$tunnel_pid_file" 2>/dev/null)
    [[ -z "$p" ]] || kill "$p" 2>/dev/null
    rm -f "$tunnel_pid_file"
    [[ -z "$result_file" ]] || result_ready "$result_file" || write_result "fail $rc"
  }
  trap finish EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  login_env
  echo "claude-relogin: login for '$id' on the $machine, approval page in ${app:-the default browser}"
  if (( dry )); then
    step "${login_cmd[@]}"
    echo "the helper then opens the approval page (sample URL):"
    CLAUDE_LOGIN_ACCOUNT=$id CLAUDE_LOGIN_MACHINE=$machine bash "$HELPER" --dry-run "$SAMPLE_URL" 2>&1
    echo "would run: claude-account expiry --json --ids $id before and after the login (it must move), claude-account refresh --ids $id, then claude-account usage and expiry for $id"
    exit 0
  fi
  before=$(expiry_ms)
  if ! "${login_cmd[@]}"; then
    echo "claude-relogin: the login did not complete. Manual fallback: run  CLAUDE_CONFIG_DIR=<dir> claude  (iu: unset it) here, type /login, open the URL in ${app:-the right browser}, paste the code." >&2
    write_result "fail 1"
    exit 1
  fi
  echo "claude-relogin: logged in, refreshing the quota cache"
  account_cli refresh --ids "$id" || echo "claude-relogin: refresh reported a problem (see above); run  claude-account refresh --ids $id" >&2
  account_cli usage | grep "^$id " || true
  account_cli expiry --ids "$id" | grep "^$id " || true
  after=$(expiry_ms)
  if ! login_renewed "$before" "$after"; then
    echo "claude-relogin: $(unchanged_text "$(ms_date "$after")")" >&2
    write_result "unchanged $(ms_date "$after")"
    exit 1
  fi
  write_result "ok $(ms_date "$after")"
  exit 0
fi

# ── MacBook worker: the login without any window ────────────────────────────────────────────────
# Output goes through the line-buffered redactor into a per-run file (the idle watchdog watches that file's growth,
# not the shared log) and the owner-only log; stdin stays open and silent so the CLI's paste prompt does not hit EOF.
# Exit status: 0 renewed, 1 the CLI failed, 3 stuck (no output for BG_IDLE_S: the callback never arrived).
run_background_login() {
  local work pid rpid rc=0 last=-1 size idle=0 stuck=0 i
  ensure_log
  work=$(mktemp -d "${TMPDIR:-/tmp}/claude-relogin.XXXXXX") || return 1
  mkfifo "$work/in" "$work/out" || { rm -rf "$work"; return 1; }
  : > "$work/seen"
  exec 3<>"$work/in"
  login_env "CLAUDE_LOGIN_MSG_FILE=$RELOGIN_LOG"
  stamp "background login for '$id' started" >>"$RELOGIN_LOG"
  login_redact <"$work/out" | tee -a "$work/seen" >>"$RELOGIN_LOG" &
  rpid=$!
  "${login_cmd[@]}" <&3 >"$work/out" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    sleep "$POLL_S"
    size=$(wc -c <"$work/seen" 2>/dev/null | tr -d ' ')
    if [[ "$size" != "$last" ]]; then idle=0; last=$size; else idle=$((idle + POLL_S)); fi
    if (( idle >= BG_IDLE_S )); then stuck=1; kill_bounded "$pid"; break; fi
  done
  wait "$pid" 2>/dev/null || rc=$?
  exec 3>&-
  # the redactor ends when the CLI's output closes; wait for it (bounded) instead of guessing a delay
  for ((i = 0; i < TERM_GRACE_S * 2; i++)); do kill -0 "$rpid" 2>/dev/null || break; sleep 0.5; done
  kill -0 "$rpid" 2>/dev/null && kill "$rpid" 2>/dev/null
  wait "$rpid" 2>/dev/null
  rm -rf "$work"
  (( stuck )) && return 3
  return $((rc != 0))
}

worker_macbook() {
  local rc=0 d resf winid res arc=0 before after
  if (( dry )); then
    echo "would start detached: bash $(login_shquote "$SELF") $id --machine macbook --worker"
    login_env "CLAUDE_LOGIN_MSG_FILE=$RELOGIN_LOG"
    step "${login_cmd[@]}"
    echo "  (stdin held open and silent, output redacted into $RELOGIN_LOG; stuck after ${BG_IDLE_S}s without output)"
    CLAUDE_LOGIN_ACCOUNT=$id CLAUDE_LOGIN_MACHINE=$machine bash "$HELPER" --dry-run "$SAMPLE_URL" 2>&1
    echo "on success:"; echo "  would run: claude-account refresh --ids $id"
    notify "$(ok_text "<date>")"
    echo "if it fails, gets stuck, or this is not the Aqua GUI session, fall back to an interactive Terminal that is closed again after success:"
    step osascript - "bash $(login_shquote "$SELF") $id --machine macbook --in-pane --result-file <result file>"
    echo "  would run: osascript close of that window id (only it), then:"
    notify "$(ok_text "<date>")"
    echo "  or, when the fallback fails too (the window stays open):"
    notify "$(fail_text)"
    return 0
  fi
  if gui_session; then
    before=$(expiry_ms)
    run_background_login || rc=$?
  else
    stamp "not in the Aqua GUI session ($(launchctl managername 2>/dev/null || echo unknown)): no windowless login, using Terminal" >>"$RELOGIN_LOG"
    rc=4
  fi
  if (( rc == 0 )); then
    account_cli refresh --ids "$id" 2>&1 | redact >>"$RELOGIN_LOG"
    account_cli usage 2>&1 | grep "^$id " | redact >>"$RELOGIN_LOG"
    after=$(expiry_ms)
    d=$(ms_date "$after")
    if ! login_renewed "$before" "$after"; then
      stamp "$(unchanged_text "$d")" >>"$RELOGIN_LOG"
      notify "$(unchanged_text "$d")"
      return 1
    fi
    stamp "login '$id' renewed, valid until ${d:-unknown}" >>"$RELOGIN_LOG"
    notify "$(ok_text "$d")"
    return 0
  fi
  stamp "background login failed (rc $rc), opening an interactive Terminal" >>"$RELOGIN_LOG"
  resf=$(new_result_file) || { stamp "could not create a result file" >>"$RELOGIN_LOG"; notify "$(fail_text)"; return 1; }
  winid=$(open_terminal "bash $(login_shquote "$SELF") $id --machine macbook --in-pane --result-file $(login_shquote "$resf")") || winid=""
  if ! [[ "$winid" =~ ^[0-9]+$ ]]; then
    stamp "could not open Terminal" >>"$RELOGIN_LOG"
    notify "$(fail_text)"
    return 1
  fi
  res=$(await_result "$resf" probe_window "$winid") || arc=$?
  rm -f "$resf"
  if (( arc == 1 )); then
    stamp "the login window was closed before the login finished" >>"$RELOGIN_LOG"
    notify "$(gone_text "login window")"
    return 1
  elif (( arc != 0 )); then
    stamp "no result within ${MAX_WAIT_S}s; the login window is left open" >>"$RELOGIN_LOG"
    notify "$(timeout_text "login window")"
    return 1
  fi
  if is_ok "$res"; then
    d=${res#ok}; d=${d# }
    sleep "$CLOSE_DELAY_S"   # the opened shell is idle again by then, so Terminal closes the window without asking
    close_window "$winid"
    stamp "login '$id' renewed via Terminal, valid until ${d:-unknown}" >>"$RELOGIN_LOG"
    notify "$(ok_text "$d")"
    return 0
  fi
  if is_unchanged "$res"; then
    d=${res#unchanged}; d=${d# }
    stamp "$(unchanged_text "$d"); the Terminal window stays open" >>"$RELOGIN_LOG"
    notify "$(unchanged_text "$d")"
    return 1
  fi
  stamp "interactive login failed ($res); the Terminal window stays open" >>"$RELOGIN_LOG"
  notify "$(fail_text)"
  return 1
}

# ── mini watcher: closes the terminal/workspace we created after success, notifies the MacBook ─
# <target> is `hc:<address>` (a terminal in the mini's core) or a classic herdr workspace id.
watcher_mini() { # <target> <result file>
  local target=$1 resf=$2 res d what arc=0 probe=(probe_workspace "$1")
  what="login workspace"
  if [[ "$target" == hc:* ]]; then what="login terminal"; probe=(probe_terminal "${target#hc:}"); fi
  if (( dry )); then
    echo "would start detached: bash $(login_shquote "$SELF") $id --machine mini --watch <hc:address or workspace> --result-file <result file>"
    if [[ "$target" == hc:* ]]; then
      echo "  on success: wait ${CLOSE_DELAY_S}s, then (the terminal has exited and removed itself; this only sweeps it):"
      step hc rm "<the terminal created above>"
    else
      echo "  on success: wait ${CLOSE_DELAY_S}s, then:"
      step herdr workspace close "<the workspace created above>" # TODO(Wave 7): drop classic
    fi
    notify "$(ok_text "<date>")"
    echo "  on failure (the terminal stays open, in a shell, for the paste fallback):"
    notify "$(fail_text)"
    return 0
  fi
  if [[ "$target" == hc:* ]]; then
    name_tab "tb-relogin-$id" "relogin $id" # TODO(Wave 7): the classic path below has no tab to name
  fi
  res=$(await_result "$resf" "${probe[@]}") || arc=$?
  rm -f "$resf"
  if (( arc == 1 )); then
    stamp "$what $target was closed before the login finished" >>"$RELOGIN_LOG"
    notify "$(gone_text "$what")"
    return 1
  elif (( arc != 0 )); then
    stamp "no result within ${MAX_WAIT_S}s; $what $target is left open" >>"$RELOGIN_LOG"
    notify "$(timeout_text "$what")"
    return 1
  fi
  if is_ok "$res"; then
    d=${res#ok}; d=${d# }
    sleep "$CLOSE_DELAY_S"
    if [[ "$target" == hc:* ]]; then
      # a clean exit removes the terminal by itself (--rm); this sweeps one that is merely finished. Never a live one.
      bounded hc rm "${target#hc:}" >/dev/null 2>&1 || true
    else
      herdr workspace close "$target" >/dev/null 2>&1 || stamp "could not close workspace $target" >&2 # TODO(Wave 7): drop classic
    fi
    stamp "login '$id' renewed, valid until ${d:-unknown}" >>"$RELOGIN_LOG"
    notify "$(ok_text "$d")"
    return 0
  fi
  if is_unchanged "$res"; then
    d=${res#unchanged}; d=${d# }
    stamp "$(unchanged_text "$d"); $what $target stays open" >>"$RELOGIN_LOG"
    notify "$(unchanged_text "$d")"
    return 1
  fi
  stamp "login '$id' failed ($res); $what $target stays open" >>"$RELOGIN_LOG"
  notify "$(fail_text)"
  return 1
}

if (( worker )); then
  [[ "$machine" == macbook && "$here" == macbook ]] || die "--worker runs on the MacBook, for a MacBook login"
  worker_macbook
  exit $?
fi
if [[ -n "$watch_ws" ]]; then
  [[ "$machine" == mini && "$here" == mini && -n "$result_file" ]] || die "--watch runs on the mini with --result-file"
  [[ "$watch_ws" =~ ^(hc:t[0-9a-z]+|[A-Za-z0-9_-]+)$ ]] || die "bad --watch target '$watch_ws'"
  watcher_mini "$watch_ws" "$result_file"
  exit $?
fi

# ── open the login on the machine that owns the credential ──────────────────────────────────────
if [[ "$machine" != "$here" ]]; then
  # reach the other machine (mini -> iumac, MacBook -> mini); it starts the login itself
  host=mini; [[ "$machine" == macbook ]] && host=iumac
  vis_arg=""; (( visible )) && vis_arg=" --visible"
  step ssh -o BatchMode=yes -o ConnectTimeout=8 "$host" "$REMOTE_PATH; $REMOTE_SCRIPT $id --machine $machine$vis_arg"
  exit $?
fi

if [[ "$machine" == macbook && "$visible" != 1 ]]; then
  if (( dry )); then worker_macbook; exit 0; fi
  wrc=0
  spawn_worker "$id" --machine macbook --worker || wrc=$?   # detached: always 0; inline (tests): the worker's own status
  echo "claude-relogin: login for '$id' running in the background; approve in ${app:-your browser}, a notification follows. Log: $RELOGIN_LOG"
  exit "$wrc"
fi

result_arg=""
if [[ "$visible" != 1 ]]; then
  if (( dry )); then result_file="<result file>"; else result_file=$(new_result_file) || die "mktemp failed"; fi
  result_arg=" --result-file $(login_shquote "$result_file")"
fi
inner="bash $(login_shquote "$SELF") $id --machine $machine --in-pane$result_arg"
if [[ "$machine" == mini ]]; then
  # The mini's herdr-core (a launchd GUI-session child: the Keychain works). No core running: the classic workspace.
  tab="tb-relogin-$id"; tname=$(hc_term_name "$id")
  # The login, then: success exits (the terminal removes itself), failure drops into a shell for the paste fallback;
  # --visible always keeps the shell. The shell is an exec, so the terminal stays live (and "present" to the watcher).
  keep_shell='exec "${SHELL:-/bin/zsh}" -l'
  if [[ "$visible" == 1 ]]; then hc_cmd="$inner; $keep_shell"
  else hc_cmd="$inner; rc=\$?; if [ \"\$rc\" -ne 0 ]; then $keep_shell; fi; exit \"\$rc\""; fi
  build_hc_args() { # <space id> — builds hc_args; no --rm for --visible
    hc_args=(run --bg --json --no-parent --no-notify --name "$tname" --cwd "$HOME" --label "herdr.space=$1" --label "herdr.tab=$tab")
    [[ "$visible" == 1 ]] || hc_args+=(--rm)
  }
  if (( dry )); then
    if hc_usable; then
      build_hc_args "<the dotfiles space>"; step hc "${hc_args[@]}" "$hc_cmd"
      echo "then, in that terminal:"; bash "$SELF" "$id" --machine "$machine" --in-pane --dry-run
      [[ "$visible" == 1 ]] || watcher_mini "hc:<address>" "<result file>"
      exit 0
    fi
    # TODO(Wave 7): drop classic
    step herdr workspace create --cwd "$HOME" --label "relogin $id" --focus
    step herdr pane run "<pane of that workspace>" "$inner"
    echo "then, in that pane:"; bash "$SELF" "$id" --machine "$machine" --in-pane --dry-run
    [[ "$visible" == 1 ]] || watcher_mini "<workspace>" "<result file>"
    exit 0
  fi
  if hc_usable; then
    # A login terminal of this account that is still around (a failed one left at its shell, or one being approved): not ours
    # to replace silently, and hc refuses a second terminal of the same name anyway.
    if existing=$(bounded hc get "$tname" --json 2>/dev/null); then
      case "$(jq -r '.state // empty' <<<"$existing" 2>/dev/null)" in
        finished) bounded hc rm "$tname" >/dev/null 2>&1 ;;
        *) die "a login terminal for '$id' is still open on the mini ($(jq -r '.address // "?"' <<<"$existing")): finish it there, or close it with  hc kill $tname" ;;
      esac
    fi
    space=$(hc_space_id) || die "could not read the herdr-app document from the mini's core - refusing to guess the dotfiles space"
    build_hc_args "$space"
    json=$(bounded hc "${hc_args[@]}" "$hc_cmd") || die "hc run failed: ${json:-no output}"
    addr=$(jq -r '.address // empty' <<<"$json" 2>/dev/null)
    [[ "$addr" =~ ^t[0-9a-z]+$ ]] || die "hc run gave no terminal address: $json"
    wrc=0
    [[ "$visible" == 1 ]] || spawn_worker "$id" --machine mini --watch "hc:$addr" --result-file "$result_file" || wrc=$?
    echo "claude-relogin: login terminal '$tname' ($addr) opened on the mini; approve in ${app:-your browser}"
    exit "$wrc"
  fi
  # TODO(Wave 7): drop classic
  json=$(herdr workspace create --cwd "$HOME" --label "relogin $id" --focus) || die "herdr workspace create failed"
  pane=$(printf '%s' "$json" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
  # the workspace we created, and the only one the watcher may close: from the response (as remote-dev.sh reads it),
  # never inferred from the pane id
  ws=$(printf '%s' "$json" | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null)
  [[ -n "$pane" && "$ws" =~ ^[A-Za-z0-9_-]+$ ]] || die "herdr workspace create gave no pane or workspace id: $json"
  sleep "$PANE_WAIT"
  herdr pane run "$pane" "$inner" >/dev/null || die "herdr pane run failed"
  wrc=0
  [[ "$visible" == 1 ]] || spawn_worker "$id" --machine mini --watch "$ws" --result-file "$result_file" || wrc=$?
  echo "claude-relogin: login terminal 'relogin $id' opened on the mini; approve in ${app:-your browser}"
  exit "$wrc"
else
  # --visible on the MacBook: a Terminal window that stays
  if (( dry )); then
    step osascript - "$inner"
    echo "then, in that Terminal window:"; bash "$SELF" "$id" --machine "$machine" --in-pane --dry-run
    exit 0
  fi
  open_terminal "$inner" >/dev/null || die "osascript could not open Terminal"
  echo "claude-relogin: Terminal window opened on the MacBook; approve in ${app:-your browser}"
fi
