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
#   mini      a herdr workspace `relogin <id>` (the GUI session is needed) that is closed a few seconds after success,
#             only that workspace; the outcome notification goes to the MacBook over ssh. A failed login leaves the
#             workspace open for the paste fallback.
#   --visible   today's behaviour for debugging: a Terminal window / herdr workspace that stays open, no worker, no
#               notification.
#
#   (no flag)   from any machine: reach the owning machine and start the login there
#   --ask       instead push a native approval dialog to the MacBook (scripts/ask-human.sh); its command is the
#               line above, so one click starts the login. Never runs anything by itself.
#   --dry-run   print exactly what would run, run nothing
#   --in-pane / --worker / --watch <workspace> / --result-file <file>   internal
#
# Automating the login itself (driving the browser, reading the mail) is out of bounds: a human always approves.
# Test seams: CLAUDE_RELOGIN_ASK_HUMAN, CLAUDE_RELOGIN_PANE_WAIT, CLAUDE_RELOGIN_LOG, CLAUDE_RELOGIN_POLL_S,
# CLAUDE_RELOGIN_CLOSE_DELAY_S, CLAUDE_RELOGIN_BG_IDLE_S, CLAUDE_RELOGIN_MAX_WAIT_S, CLAUDE_RELOGIN_ABSENT_N,
# CLAUDE_RELOGIN_TERM_GRACE_S, CLAUDE_RELOGIN_FOREGROUND (run the workers inline);
# PATH stubs for ssh, herdr, osascript, claude, claude-account.
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
    --watch) [[ $# -ge 2 ]] || die "--watch needs a workspace id"; watch_ws=$2; shift ;;
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

# ── mini watcher: closes the workspace we created after success, notifies the MacBook ───────────
watcher_mini() { # <workspace id> <result file>
  local ws=$1 resf=$2 res d
  if (( dry )); then
    echo "would start detached: bash $(login_shquote "$SELF") $id --machine mini --watch <workspace> --result-file <result file>"
    echo "  on success: wait ${CLOSE_DELAY_S}s, then:"
    step herdr workspace close "<the workspace created above>"
    notify "$(ok_text "<date>")"
    echo "  on failure (the workspace stays open for the paste fallback):"
    notify "$(fail_text)"
    return 0
  fi
  local arc=0
  res=$(await_result "$resf" probe_workspace "$ws") || arc=$?
  rm -f "$resf"
  if (( arc == 1 )); then
    stamp "workspace $ws was closed before the login finished" >>"$RELOGIN_LOG"
    notify "$(gone_text "login workspace")"
    return 1
  elif (( arc != 0 )); then
    stamp "no result within ${MAX_WAIT_S}s; workspace $ws is left open" >>"$RELOGIN_LOG"
    notify "$(timeout_text "login workspace")"
    return 1
  fi
  if is_ok "$res"; then
    d=${res#ok}; d=${d# }
    sleep "$CLOSE_DELAY_S"
    herdr workspace close "$ws" >/dev/null 2>&1 || stamp "could not close workspace $ws" >&2
    stamp "login '$id' renewed, valid until ${d:-unknown}" >>"$RELOGIN_LOG"
    notify "$(ok_text "$d")"
    return 0
  fi
  if is_unchanged "$res"; then
    d=${res#unchanged}; d=${d# }
    stamp "$(unchanged_text "$d"); workspace $ws stays open" >>"$RELOGIN_LOG"
    notify "$(unchanged_text "$d")"
    return 1
  fi
  stamp "login '$id' failed ($res); workspace $ws stays open" >>"$RELOGIN_LOG"
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
  # herdr workspace in the GUI session (rd does the same); the shell needs a moment before it takes input
  if (( dry )); then
    step herdr workspace create --cwd "$HOME" --label "relogin $id" --focus
    step herdr pane run "<pane of that workspace>" "$inner"
    echo "then, in that pane:"; bash "$SELF" "$id" --machine "$machine" --in-pane --dry-run
    [[ "$visible" == 1 ]] || watcher_mini "<workspace>" "<result file>"
    exit 0
  fi
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
