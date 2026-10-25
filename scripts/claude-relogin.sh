#!/usr/bin/env bash
# claude-relogin — one-click re-login of a Claude account (docs/claude-accounts.md §Re-login).
#
#   claude-relogin <id> [--machine mini|macbook] [--ask [--reason <text>]] [--dry-run]
#
# Logins are per machine: the mini and the MacBook keep separate Keychain items, so a login happens on the machine
# that owns the credential (--machine, default: this one). It runs `claude auth login --claudeai` with BROWSER set to
# claude-login-browser.sh in a real GUI-session terminal (the login Keychain is only reachable from the GUI session;
# never `ssh mini claude …`): a herdr workspace on the mini, a Terminal window on the MacBook. The helper opens the
# authorize URL in the browser signed in to the account (registry `loginBrowser`); the owner clicks approve, no
# copy/paste (the CLI prompt still takes a pasted code as the fallback). Afterwards the login terminal runs
# `claude-account refresh --ids <id>` and prints the account's usage line and expiry.
#
#   (no flag)   from any machine: reach the owning machine and open the login terminal there
#   --ask       instead push a native approval dialog to the MacBook (scripts/ask-human.sh); its command is the
#               line above, so one click starts the login. Never runs anything by itself.
#   --dry-run   print exactly what would run, run nothing
#   --in-pane   internal: do the login in THIS terminal (what the opened terminal types)
#
# Automating the login itself (driving the browser, reading the mail) is out of bounds: a human always approves.
# Test seams: CLAUDE_RELOGIN_ASK_HUMAN, CLAUDE_RELOGIN_PANE_WAIT; PATH stubs for ssh, herdr, osascript, claude,
# claude-account.
set -u
SELF="$(readlink -f "${BASH_SOURCE[0]}")" # ~/.local/bin/claude-relogin is a symlink into the checkout
HERE="$(dirname "$SELF")"
HELPER="$HERE/claude-login-browser.sh"
# shellcheck source=lib/claude-login.sh
source "$HERE/lib/claude-login.sh"

REGISTRY="${CLAUDE_ACCOUNTS_REGISTRY:-$HERE/../config/claude-accounts.json}"
ASK_HUMAN="${CLAUDE_RELOGIN_ASK_HUMAN:-$HERE/ask-human.sh}"
PANE_WAIT="${CLAUDE_RELOGIN_PANE_WAIT:-1}"
export PATH="$PATH:$HOME/.local/bin:/opt/homebrew/bin:$HOME/.bun/bin" # appended: a non-login ssh shell lacks them, an existing PATH entry (or a test stub) wins
REMOTE_PATH='export PATH="$HOME/.local/bin:/opt/homebrew/bin:$HOME/.bun/bin:$PATH"'
# What a remote shell runs to start the relogin on its own machine ($HOME is that machine's).
# shellcheck disable=SC2016
REMOTE_SCRIPT='bash "$HOME/SourceRoot/dotfiles/scripts/claude-relogin.sh"'
SAMPLE_URL='https://claude.ai/oauth/authorize?client_id=sample&response_type=code&redirect_uri=http%3A%2F%2Flocalhost%3A58876%2Fcallback&scope=user%3Ainference&state=sample'

die() { echo "claude-relogin: $*" >&2; exit 2; }

id=""; machine=""; ask=0; dry=0; in_pane=0; reason=""
while (( $# )); do
  case "$1" in
    --machine) [[ $# -ge 2 ]] || die "--machine needs mini or macbook"; machine=$2; shift ;;
    --reason) [[ $# -ge 2 ]] || die "--reason needs a text"; reason=$2; shift ;;
    --ask) ask=1 ;;
    --dry-run) dry=1 ;;
    --in-pane) in_pane=1 ;;
    -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option $1" ;;
    *) [[ -z "$id" ]] || die "one account id only"; id=$1 ;;
  esac
  shift
done
[[ -n "$id" ]] || die "usage: claude-relogin <id> [--machine mini|macbook] [--ask] [--dry-run]"
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
  text="Claude login '$id' on the $machine needs a new /login${reason:+ ($reason)}. Run opens a login terminal on the $machine and the approval page in ${app:-your default browser}; approve there. Nothing runs until you click Run."
  if [[ "$here" == macbook ]]; then
    # this IS the MacBook: show the dialog here, no ssh self-loop
    (( dry )) && echo "would set: HUMAN_QUEUE_MAC_HOST=local"
    HUMAN_QUEUE_MAC_HOST=local step bash "$ASK_HUMAN" ask "$text" --cmd "$cmd"
  else
    step bash "$ASK_HUMAN" ask "$text" --cmd "$cmd"
  fi
  exit $?
fi

# ── --in-pane: the login itself, in this terminal ────────────────────────────────────────────────
login_env() {
  local dir
  dir=$(jq -r --arg id "$id" '.accounts[$id].dir // ""' "$REGISTRY")
  # env wants every -u before the first NAME=value; iu owns the default ~/.claude, so CLAUDE_CONFIG_DIR must stay
  # unset for it (setting it changes the Keychain service)
  login_cmd=(env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_BASE_URL)
  [[ -z "$dir" ]] && login_cmd+=(-u CLAUDE_CONFIG_DIR)
  login_cmd+=("USER=${USER:-$(id -un)}" "BROWSER=$HELPER" "CLAUDE_LOGIN_ACCOUNT=$id" "CLAUDE_LOGIN_MACHINE=$machine" "CLAUDE_LOGIN_OWNER_PID=$$" "CLAUDE_LOGIN_TUNNEL_PID_FILE=$tunnel_pid_file")
  [[ -n "$dir" ]] && login_cmd+=("CLAUDE_CONFIG_DIR=${dir/#\~/$HOME}")
  login_cmd+=(claude auth login --claudeai)
}
account_cli() { if command -v claude-account >/dev/null 2>&1; then claude-account "$@"; else bun "$HERE/claude-account.ts" "$@"; fi; }

if (( in_pane )); then
  [[ "$machine" == "$here" ]] || die "--in-pane runs on the machine that owns the login ($machine), this is the $here"
  # This process owns the login, and with it the reverse tunnel the helper may start (its pid lands in this file):
  # whatever way we exit, the tunnel goes too.
  tunnel_pid_file=$(mktemp "${TMPDIR:-/tmp}/claude-relogin-tunnel.XXXXXX") || die "mktemp failed"
  stop_tunnel() {
    local p
    p=$(cat "$tunnel_pid_file" 2>/dev/null)
    [[ -z "$p" ]] || kill "$p" 2>/dev/null
    rm -f "$tunnel_pid_file"
  }
  trap stop_tunnel EXIT
  trap 'stop_tunnel; exit 130' INT
  trap 'stop_tunnel; exit 143' TERM
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
    exit 1
  fi
  echo "claude-relogin: logged in, refreshing the quota cache"
  account_cli refresh --ids "$id" || echo "claude-relogin: refresh reported a problem (see above); run  claude-account refresh --ids $id" >&2
  account_cli usage | grep "^$id " || true
  account_cli expiry | grep "^$id " || true
  exit 0
fi

# ── open the login terminal on the machine that owns the credential ─────────────────────────────
if [[ "$machine" != "$here" ]]; then
  # reach the other machine (mini -> iumac, MacBook -> mini); it opens its own terminal
  host=mini; [[ "$machine" == macbook ]] && host=iumac
  step ssh -o BatchMode=yes -o ConnectTimeout=8 "$host" "$REMOTE_PATH; $REMOTE_SCRIPT $id --machine $machine"
  exit $?
fi

inner="bash $(login_shquote "$SELF") $id --machine $machine --in-pane"
if [[ "$machine" == mini ]]; then
  # herdr workspace in the GUI session (rd does the same); the shell needs a moment before it takes input
  if (( dry )); then
    step herdr workspace create --cwd "$HOME" --label "relogin $id" --focus
    step herdr pane run "<pane of that workspace>" "$inner"
    echo "then, in that pane:"; bash "$SELF" "$id" --machine "$machine" --in-pane --dry-run
    exit 0
  fi
  json=$(herdr workspace create --cwd "$HOME" --label "relogin $id" --focus) || die "herdr workspace create failed"
  pane=$(printf '%s' "$json" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
  [[ -n "$pane" ]] || die "herdr workspace create gave no pane: $json"
  sleep "$PANE_WAIT"
  herdr pane run "$pane" "$inner" >/dev/null || die "herdr pane run failed"
  echo "claude-relogin: login terminal 'relogin $id' opened on the mini; approve in ${app:-your browser}"
else
  if (( dry )); then
    step osascript - "$inner"
    echo "then, in that Terminal window:"; bash "$SELF" "$id" --machine "$machine" --in-pane --dry-run
    exit 0
  fi
  # the command reaches AppleScript as argv, never spliced into the script source
  osascript - "$inner" <<'OSA' >/dev/null || die "osascript could not open Terminal"
on run argv
  tell application "Terminal"
    activate
    do script (item 1 of argv)
  end tell
end run
OSA
  echo "claude-relogin: Terminal window opened on the MacBook; approve in ${app:-your browser}"
fi
