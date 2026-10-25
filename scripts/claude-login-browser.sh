#!/usr/bin/env bash
# claude-login-browser — the BROWSER target of `claude auth login --claudeai` (docs/claude-accounts.md §Re-login).
# claude-relogin.sh sets BROWSER to this script; the CLI calls it with the authorize URL, whose redirect_uri is
# http://localhost:<random port>/callback on the machine running the login. It opens that URL in the browser that is
# signed in to the account (registry field `loginBrowser`, read via CLAUDE_LOGIN_ACCOUNT; no field = the system
# default, and it says so). A human always approves in their own browser; nothing here drives it.
#
#   claude-login-browser.sh [--dry-run] <authorize-url>
#
# Where the login runs decides how the browser is reached:
#   macbook  `open -a <app> <url>` — the callback lands on localhost here.
#   mini     the browser is on the MacBook: `ssh -N -R <port>:localhost:<port> iumac` forwards the browser's
#            localhost callback back to the CLI on the mini, then `ssh iumac open -a <app> '<url>'`. The tunnel closes
#            when the login process is gone, when the CLI stops listening (login finished), or after a generous idle
#            window with no connection (CLAUDE_LOGIN_TUNNEL_IDLE_S, default 2700). Not a hard timeout.
# Any failure (no port in the URL, forward refused, ssh down) prints the URL: the CLI's own prompt still takes a
# pasted code, which stays the fallback.
#
# Environment: CLAUDE_LOGIN_ACCOUNT (registry id), CLAUDE_LOGIN_MACHINE (mini|macbook; default: detected),
# CLAUDE_LOGIN_OWNER_PID (the login process the tunnel lives and dies with), CLAUDE_ACCOUNTS_REGISTRY.
# Test seams: CLAUDE_LOGIN_OPEN, CLAUDE_LOGIN_SSH, CLAUDE_LOGIN_LSOF, CLAUDE_LOGIN_MAC_HOST, CLAUDE_LOGIN_POLL_S,
# CLAUDE_LOGIN_FORWARD_GRACE_S, CLAUDE_LOGIN_MSG_FILE (default /dev/tty, else stderr).
set -u
HERE="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck source=lib/claude-login.sh
source "$HERE/lib/claude-login.sh"

REGISTRY="${CLAUDE_ACCOUNTS_REGISTRY:-$HERE/../config/claude-accounts.json}"
OPEN="${CLAUDE_LOGIN_OPEN:-open}"
SSH="${CLAUDE_LOGIN_SSH:-ssh}"
LSOF="${CLAUDE_LOGIN_LSOF:-/usr/sbin/lsof}"
MAC_HOST="${CLAUDE_LOGIN_MAC_HOST:-iumac}"
POLL_S="${CLAUDE_LOGIN_POLL_S:-2}"
MAX_IDLE_S="${CLAUDE_LOGIN_TUNNEL_IDLE_S:-2700}"
GRACE_S="${CLAUDE_LOGIN_FORWARD_GRACE_S:-3}"
MSG_FILE="${CLAUDE_LOGIN_MSG_FILE:-/dev/tty}"

dry=0
[[ "${1-}" == --dry-run ]] && { dry=1; shift; }
url="${1-}"
[[ -n "$url" ]] || { echo "usage: claude-login-browser.sh [--dry-run] <authorize-url>" >&2; exit 2; }

# The CLI may have no stdout the human sees: talk to the terminal, else stderr.
say() { { printf '%s\n' "$*" >>"$MSG_FILE"; } 2>/dev/null || printf '%s\n' "$*" >&2; }
# Print (dry run) or run one command; every word is shell-quoted in the print so it can be pasted.
step() {
  if (( dry )); then
    local w out=""
    for w in "$@"; do out="$out $(login_shquote "$w")"; done
    echo "would run:$out"
    return 0
  fi
  "$@"
}
fallback() { # <why>
  say "claude-login: $1"
  say "  open this URL in ${app:-your browser} yourself, approve, then paste the code at the login prompt:"
  say "  $url"
}

account="${CLAUDE_LOGIN_ACCOUNT-}"
machine="${CLAUDE_LOGIN_MACHINE:-$(login_local_machine)}"
app=""
if [[ -z "$account" ]]; then
  say "claude-login: no CLAUDE_LOGIN_ACCOUNT, using the system default browser"
else
  app=$(login_browser_for "$REGISTRY" "$account")
  [[ -n "$app" ]] || say "claude-login: no loginBrowser for '$account' in the registry, using the system default browser"
fi

open_args=("$url")
[[ -n "$app" ]] && open_args=(-a "$app" "$url")

if [[ "$machine" != mini ]]; then
  say "claude-login: opening the approval page in ${app:-the default browser}"
  step "$OPEN" "${open_args[@]}" || { fallback "could not run open"; exit 1; }
  exit 0
fi

# ── the mini: the browser lives on the MacBook ─────────────────────────────────────────────────
port=$(login_url_port "$url") || { fallback "no loopback callback port in the URL, cannot forward it to the MacBook"; exit 1; }
remote_open="open"
for w in "${open_args[@]}"; do remote_open="$remote_open $(login_shquote "$w")"; done

# Own connection (ControlPath=none): the forward must die with this ssh process, never join a shared master.
tunnel=("$SSH" -N -R "$port:localhost:$port" -o BatchMode=yes -o ExitOnForwardFailure=yes -o ControlMaster=no -o ControlPath=none
        -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o ConnectTimeout=8 "$MAC_HOST")
opener=("$SSH" -o BatchMode=yes -o ConnectTimeout=8 "$MAC_HOST" "$remote_open")

if (( dry )); then
  say "claude-login: dry run, callback port $port, browser ${app:-system default}"
  step "${tunnel[@]}"
  step "${opener[@]}"
  exit 0
fi

"${tunnel[@]}" </dev/null >/dev/null 2>&1 &
tunnel_pid=$!
# ExitOnForwardFailure ends ssh within a moment of a refused forward: a process still alive after the grace is the forward.
for ((i = 0; i < GRACE_S; i++)); do
  sleep 1
  kill -0 "$tunnel_pid" 2>/dev/null || break
done
kill -0 "$tunnel_pid" 2>/dev/null || { fallback "could not forward port $port to $MAC_HOST (is its sshd up? is the port taken there?)"; exit 1; }

if ! "${opener[@]}"; then
  kill "$tunnel_pid" 2>/dev/null
  fallback "could not open the URL on $MAC_HOST"
  exit 1
fi
say "claude-login: approval page opened in ${app:-the default browser} on $MAC_HOST; the callback reaches this machine through the tunnel"

# Watchdog: closes the tunnel when the login is over. Detached from the CLI's stdio, which would otherwise hold it open.
(
  owner="${CLAUDE_LOGIN_OWNER_PID-}"
  seen=0; idle=0
  while kill -0 "$tunnel_pid" 2>/dev/null; do
    sleep "$POLL_S"
    owner_alive=1
    if [[ -n "$owner" ]] && ! kill -0 "$owner" 2>/dev/null; then owner_alive=0; fi
    listening=0
    "$LSOF" -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 && { listening=1; seen=1; }
    if "$LSOF" -nP -iTCP:"$port" -sTCP:ESTABLISHED >/dev/null 2>&1; then idle=0; else idle=$((idle + POLL_S)); fi
    verdict=$(login_tunnel_verdict "$owner_alive" "$listening" "$seen" "$idle" "$MAX_IDLE_S")
    [[ "$verdict" == keep ]] && continue
    kill "$tunnel_pid" 2>/dev/null
    break
  done
) >/dev/null 2>&1 &
exit 0
