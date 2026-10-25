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
# ("Claude login me: renewed, valid until <date>", or a failure line with the log path), on the MacBook.
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
# CLAUDE_RELOGIN_CLOSE_DELAY_S, CLAUDE_RELOGIN_BG_IDLE_S, CLAUDE_RELOGIN_FOREGROUND (run the workers inline);
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
jq -e --arg id "$id" '.accounts[$id].enabled == true' "$REGISTRY" >/dev/null 2>&1 \
  || die "'$id' is not an enabled account in $REGISTRY ($(jq -r '.accounts | to_entries | map(select(.value.enabled) | .key) | join(", ")' "$REGISTRY" 2>/dev/null))"

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
# Nothing token-shaped may reach the log, whatever the CLI prints.
redact() { sed -E 's/sk-ant-[A-Za-z0-9_-]+/[redacted]/g; s/([Tt]oken"?[=: ]+"?)[A-Za-z0-9._~+\/-]{16,}/\1[redacted]/g'; }
# End of the account's login (refresh token), YYYY-MM-DD, empty when unknown.
expiry_date() {
  local ms
  ms=$(account_cli expiry --json 2>/dev/null | jq -r --arg id "$id" '.accounts[] | select(.id == $id) | .refresh_expires_at // empty' 2>/dev/null)
  [[ "$ms" =~ ^[0-9]+$ ]] || return 0
  date -r "$((ms / 1000))" +%Y-%m-%d
}
ok_text()   { echo "Claude login $id: renewed, valid until ${1:-unknown}"; }
fail_text() { echo "Claude login $id failed - retry with: claude-relogin $id (log: $RELOGIN_LOG)"; }

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

# Terminal windows on the MacBook, addressed by id: the one we open is the only one we ever close.
open_terminal() { # <command> — prints the new window's id
  osascript - "$1" <<'OSA'
on run argv
  tell application "Terminal"
    activate
    do script (item 1 of argv)
    return id of front window
  end tell
end run
OSA
}
window_exists() { # <id>
  osascript - "$1" <<'OSA' 2>/dev/null | grep -qx true
on run argv
  tell application "Terminal" to return (exists window id (item 1 of argv as integer))
end run
OSA
}
close_window() { # <id>
  osascript - "$1" <<'OSA' >/dev/null 2>&1
on run argv
  tell application "Terminal" to close (window id (item 1 of argv as integer)) saving no
end run
OSA
}
workspace_exists() { # <workspace id> — a failing herdr counts as gone
  herdr workspace list 2>/dev/null | grep -q "\"workspace_id\":\"$1\""
}
new_result_file() { mktemp -u "${TMPDIR:-/tmp}/claude-relogin-result.XXXXXX"; }
# Detached worker (same script, another mode); inline when a test asks for it.
spawn_worker() { # <args…>
  if [[ "$FOREGROUND" == 1 ]]; then bash "$SELF" "$@"; return; fi
  mkdir -p "$(dirname "$RELOGIN_LOG")"
  nohup bash "$SELF" "$@" </dev/null >>"$RELOGIN_LOG" 2>&1 &
}
# Wait until <file> has content; echoes it. Stops early (rc 1) when `alive` says the terminal is gone.
await_result() { # <file> <alive-command…>
  local f=$1; shift
  while [[ ! -s "$f" ]]; do
    "$@" || { [[ -s "$f" ]] && break; return 1; }
    sleep "$POLL_S"
  done
  cat "$f"
}

# ── --in-pane: the login itself, in this terminal ────────────────────────────────────────────────
if (( in_pane )); then
  [[ "$machine" == "$here" ]] || die "--in-pane runs on the machine that owns the login ($machine), this is the $here"
  # This process owns the login, and with it the reverse tunnel the helper may start (its pid lands in this file):
  # whatever way we exit, the tunnel goes too. A result file (written last, atomically) tells whoever opened this
  # terminal how it ended, so it can close the window and notify.
  tunnel_pid_file=$(mktemp "${TMPDIR:-/tmp}/claude-relogin-tunnel.XXXXXX") || die "mktemp failed"
  write_result() { [[ -n "$result_file" ]] && ! (( dry )) && printf '%s\n' "$1" > "$result_file.tmp" && mv "$result_file.tmp" "$result_file"; return 0; }
  finish() { # exit trap: tunnel down, and a result for the opener even when we were interrupted
    local p rc=$?
    p=$(cat "$tunnel_pid_file" 2>/dev/null)
    [[ -z "$p" ]] || kill "$p" 2>/dev/null
    rm -f "$tunnel_pid_file"
    [[ -z "$result_file" || -s "$result_file" ]] || write_result "fail $rc"
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
    echo "would run: claude-account refresh --ids $id, then claude-account usage and expiry for $id"
    exit 0
  fi
  if ! "${login_cmd[@]}"; then
    echo "claude-relogin: the login did not complete. Manual fallback: run  CLAUDE_CONFIG_DIR=<dir> claude  (iu: unset it) here, type /login, open the URL in ${app:-the right browser}, paste the code." >&2
    write_result "fail 1"
    exit 1
  fi
  echo "claude-relogin: logged in, refreshing the quota cache"
  account_cli refresh --ids "$id" || echo "claude-relogin: refresh reported a problem (see above); run  claude-account refresh --ids $id" >&2
  account_cli usage | grep "^$id " || true
  account_cli expiry | grep "^$id " || true
  write_result "ok $(expiry_date)"
  exit 0
fi

# ── MacBook worker: the login without any window ────────────────────────────────────────────────
# Output (redacted) goes to the log, stdin stays open and silent so the CLI's paste prompt does not hit EOF. Exit
# status: 0 renewed, 1 the CLI failed, 3 stuck (no output for BG_IDLE_S: the callback never arrived).
run_background_login() {
  local fifo pid rc=0 last=-1 size idle=0 stuck=0
  mkdir -p "$(dirname "$RELOGIN_LOG")"
  fifo=$(mktemp -u "${TMPDIR:-/tmp}/claude-relogin-in.XXXXXX")
  mkfifo "$fifo" || return 1
  exec 3<>"$fifo"
  login_env "CLAUDE_LOGIN_MSG_FILE=$RELOGIN_LOG"
  stamp "background login for '$id' started" >>"$RELOGIN_LOG"
  "${login_cmd[@]}" <&3 > >(redact >>"$RELOGIN_LOG") 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    sleep "$POLL_S"
    size=$(wc -c <"$RELOGIN_LOG" 2>/dev/null | tr -d ' ')
    if [[ "$size" != "$last" ]]; then idle=0; last=$size; else idle=$((idle + POLL_S)); fi
    if (( idle >= BG_IDLE_S )); then stuck=1; kill "$pid" 2>/dev/null; break; fi
  done
  wait "$pid" 2>/dev/null || rc=$?
  exec 3>&-
  rm -f "$fifo"
  sleep 0.2 # let the redactor flush
  (( stuck )) && return 3
  return $((rc != 0))
}

worker_macbook() {
  local rc=0 d resf winid res
  if (( dry )); then
    echo "would start detached: bash $(login_shquote "$SELF") $id --machine macbook --worker"
    login_env "CLAUDE_LOGIN_MSG_FILE=$RELOGIN_LOG"
    step "${login_cmd[@]}"
    echo "  (stdin held open and silent, output redacted into $RELOGIN_LOG; stuck after ${BG_IDLE_S}s without output)"
    CLAUDE_LOGIN_ACCOUNT=$id CLAUDE_LOGIN_MACHINE=$machine bash "$HELPER" --dry-run "$SAMPLE_URL" 2>&1
    echo "on success:"; echo "  would run: claude-account refresh --ids $id"
    notify "$(ok_text "<date>")"
    echo "if it fails or gets stuck, fall back to an interactive Terminal that is closed again after success:"
    step osascript - "bash $(login_shquote "$SELF") $id --machine macbook --in-pane --result-file <result file>"
    echo "  would run: osascript close of that window id (only it), then:"
    notify "$(ok_text "<date>")"
    echo "  or, when the fallback fails too (the window stays open):"
    notify "$(fail_text)"
    return 0
  fi
  run_background_login || rc=$?
  if (( rc == 0 )); then
    account_cli refresh --ids "$id" 2>&1 | redact >>"$RELOGIN_LOG"
    account_cli usage 2>&1 | grep "^$id " | redact >>"$RELOGIN_LOG"
    d=$(expiry_date)
    stamp "login '$id' renewed, valid until ${d:-unknown}" >>"$RELOGIN_LOG"
    notify "$(ok_text "$d")"
    return 0
  fi
  stamp "background login failed (rc $rc), opening an interactive Terminal" >>"$RELOGIN_LOG"
  resf=$(new_result_file)
  winid=$(open_terminal "bash $(login_shquote "$SELF") $id --machine macbook --in-pane --result-file $(login_shquote "$resf")") || winid=""
  if ! [[ "$winid" =~ ^[0-9]+$ ]]; then
    stamp "could not open Terminal" >>"$RELOGIN_LOG"
    notify "$(fail_text)"
    return 1
  fi
  if ! res=$(await_result "$resf" window_exists "$winid"); then
    stamp "the login window was closed before the login finished" >>"$RELOGIN_LOG"
    notify "$(fail_text)"
    rm -f "$resf"
    return 1
  fi
  rm -f "$resf"
  if [[ "$res" == ok* ]]; then
    d=${res#ok}; d=${d# }
    sleep "$CLOSE_DELAY_S"   # the opened shell is idle again by then, so Terminal closes the window without asking
    close_window "$winid"
    stamp "login '$id' renewed via Terminal, valid until ${d:-unknown}" >>"$RELOGIN_LOG"
    notify "$(ok_text "$d")"
    return 0
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
  if ! res=$(await_result "$resf" workspace_exists "$ws"); then
    stamp "workspace $ws was closed before the login finished" >>"$RELOGIN_LOG"
    return 0
  fi
  rm -f "$resf"
  if [[ "$res" == ok* ]]; then
    d=${res#ok}; d=${d# }
    sleep "$CLOSE_DELAY_S"
    herdr workspace close "$ws" >/dev/null 2>&1 || stamp "could not close workspace $ws" >&2
    stamp "login '$id' renewed, valid until ${d:-unknown}" >>"$RELOGIN_LOG"
    notify "$(ok_text "$d")"
    return 0
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
if [[ "$visible" != 1 ]]; then result_file=$(new_result_file); result_arg=" --result-file $(login_shquote "$result_file")"; fi
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
  [[ -n "$pane" ]] || die "herdr workspace create gave no pane: $json"
  ws=${pane%%:*}   # the workspace we created, and the only one the watcher may close
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
