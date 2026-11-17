#!/usr/bin/env bash
# claude-login-browser — the BROWSER target of `claude auth login --claudeai` (docs/claude-accounts.md §Re-login).
# claude-relogin.sh sets BROWSER to this script; the CLI calls it with the authorize URL, whose redirect_uri is
# http://localhost:<random port>/callback on the machine running the login. It opens the approval page in the browser
# that is signed in to the account (registry field `loginBrowser`, read via CLAUDE_LOGIN_ACCOUNT; no field = the system
# default, and it says so). A human always approves in their own browser; nothing here drives it.
#
#   claude-login-browser.sh [--dry-run] <authorize-url>
#
# Where the login runs decides how the approval page is reached:
#   macbook  `open -a <app> <url>` — the browser's callback lands on localhost here, no code to paste.
#   mini     the browser is on the MacBook, whose localhost is not the mini's, and the mini's key grants no reverse
#            forward. So the code-paste path is the designed one: the same URL with its redirect_uri swapped for the
#            platform's code page (what the CLI itself prints as the manual URL) is opened with `ssh iumac open-url`
#            (stdin: the app name, then the URL); the page shows a code, the owner pastes it at the CLI's prompt in
#            the login terminal. The owner is told so on the MacBook (notification via `ssh iumac notify`) and in the
#            terminal, naming the tab. The URL is also written to CLAUDE_LOGIN_URL_FILE, so a repeated
#            `claude-relogin` can open the same page again instead of refusing.
# Any failure (ssh down, open refused) prints the URL: opening it by hand and pasting the code stays the fallback.
#
# Environment: CLAUDE_LOGIN_ACCOUNT (registry id), CLAUDE_LOGIN_MACHINE (mini|macbook; default: detected),
# CLAUDE_LOGIN_URL_FILE (where the mini's approval URL is kept while the login waits), CLAUDE_ACCOUNTS_REGISTRY.
# Test seams: CLAUDE_LOGIN_OPEN, CLAUDE_LOGIN_SSH, CLAUDE_LOGIN_MAC_HOST, CLAUDE_LOGIN_MSG_FILE (default /dev/tty,
# else stderr).
set -u
HERE="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck source=lib/claude-login.sh
source "$HERE/lib/claude-login.sh"

REGISTRY="${CLAUDE_ACCOUNTS_REGISTRY:-$HERE/../config/claude-accounts.json}"
OPEN="${CLAUDE_LOGIN_OPEN:-open}"
MAC_HOST="${CLAUDE_LOGIN_MAC_HOST:-iumac}"
URL_FILE="${CLAUDE_LOGIN_URL_FILE-}"
MSG_FILE="${CLAUDE_LOGIN_MSG_FILE:-/dev/tty}"

dry=0
[[ "${1-}" == --dry-run ]] && { dry=1; shift; }
url="${1-}"
[[ -n "$url" ]] || { echo "usage: claude-login-browser.sh [--dry-run] <authorize-url>" >&2; exit 2; }

# The CLI may have no stdout the human sees: talk to the terminal, else stderr.
# A terminal gets the text as is (the URL must stay pasteable); any file target gets it redacted.
say() {
  if [[ "$MSG_FILE" == /dev/tty ]]; then
    { printf '%s\n' "$*" >>"$MSG_FILE"; } 2>/dev/null || printf '%s\n' "$*" >&2
  else
    { printf '%s\n' "$*" | login_redact >>"$MSG_FILE"; } 2>/dev/null || printf '%s\n' "$*" >&2
  fi
}
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
shown="$url" # the URL a fallback prints: the one that works from where the browser is
fallback() { # <why>
  say "claude-login: $1"
  say "  open this URL in ${app:-your browser} yourself, approve, then paste the code at the login prompt:"
  say "  $shown"
}

account="${CLAUDE_LOGIN_ACCOUNT-}"
machine="${CLAUDE_LOGIN_MACHINE:-$(login_local_machine)}"
app=""
if [[ -z "$account" ]]; then
  say "claude-login: no CLAUDE_LOGIN_ACCOUNT, using the system default browser"
else
  # an unusable registry is not "no loginBrowser": never guess a browser for an account that may be the wrong one
  app=$(login_browser_for "$REGISTRY" "$account") || { fallback "cannot tell which browser belongs to '$account' (registry unusable)"; exit 1; }
  [[ -n "$app" ]] || say "claude-login: no loginBrowser for '$account' in the registry, using the system default browser"
fi

if [[ "$machine" != mini ]]; then
  open_args=("$url")
  [[ -n "$app" ]] && open_args=(-a "$app" "$url")
  say "claude-login: opening the approval page in ${app:-the default browser}"
  step "$OPEN" "${open_args[@]}" || { fallback "could not run open"; exit 1; }
  exit 0
fi

# ── the mini: the browser lives on the MacBook, the code is pasted here ─────────────────────────
shown=$(login_paste_url "$url")
tab="relogin ${account:-<id>}"
where="the tab '$tab' (terminal relogin-${account:-<id>}) in the Herdr app"
if (( dry )); then
  say "claude-login: dry run, code-paste URL, browser ${app:-system default}"
  printf '%s\n' "would run: login_open_on_mac ${app:-<default>} <code-paste URL> (ssh $MAC_HOST open-url)"
  printf '%s\n' "would run: login_mac_notify 'Claude login ${account:-?}' <where the code goes> (ssh $MAC_HOST notify)"
  exit 0
fi
[[ -z "$URL_FILE" ]] || { ( umask 077; printf '%s\n' "$shown" >"$URL_FILE" ) 2>/dev/null; }
login_open_on_mac "$app" "$shown" || { fallback "could not open the URL on $MAC_HOST"; exit 1; }
say "claude-login: approval page opened in ${app:-the default browser} on $MAC_HOST."
say "  Approve there, copy the code the page shows, and paste it at the prompt below, in THIS terminal."
login_mac_notify "Claude login ${account:-?}" "Approve in ${app:-your browser}, then paste the code into $where on the mini."
exit 0
