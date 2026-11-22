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
#   mini     the browser is on the MacBook, whose localhost is not the mini's. So the MacBook forwards that port to the
#            mini's loopback for the life of the login and opens the ORIGINAL URL (`ssh iumac login-forward`, stdin: the
#            app, the port, the URL): the browser's callback to localhost:<port> reaches the mini's listener and the login
#            finishes on the approve click, no code exists. The URL is also written to CLAUDE_LOGIN_URL_FILE, so a repeated
#            `claude-relogin` can open the same page again.
#            When the forward cannot be opened (MacBook unreachable, port taken there) the same URL with its redirect_uri
#            swapped for the platform's code page (what the CLI itself prints as the manual URL) is opened with
#            `ssh iumac open-url`; the page shows a code, and a native dialog with a text field on the MacBook takes it
#            (`ssh iumac login-code`) and sends it to the login prompt (`hc send`, never logged or written to a file).
#            Pasting it at the prompt in the login terminal works as well.
# Any failure (ssh down, open refused) prints the URL: opening it by hand and pasting the code stays the last resort.
#
# Environment: CLAUDE_LOGIN_ACCOUNT (registry id), CLAUDE_LOGIN_MACHINE (mini|macbook; default: detected),
# CLAUDE_LOGIN_URL_FILE (where the mini's approval URL is kept while the login waits; the forward lives while it exists),
# CLAUDE_LOGIN_TERMINAL (the login terminal's hc name, where the code goes), CLAUDE_ACCOUNTS_REGISTRY.
# Test seams: CLAUDE_LOGIN_OPEN, CLAUDE_LOGIN_SSH, CLAUDE_LOGIN_MAC_HOST, CLAUDE_LOGIN_HC, CLAUDE_LOGIN_MSG_FILE (default
# /dev/tty, else stderr).
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

# ── the mini: the browser lives on the MacBook, the callback is forwarded to this machine ────────
term="${CLAUDE_LOGIN_TERMINAL:-relogin-${account:-<id>}}"
port=$(login_redirect_port "$url")
if (( dry )); then
  say "claude-login: dry run, browser ${app:-system default}"
  printf '%s\n' "would run: login_forward_open ${app:-<default>} ${port:-<port>} <authorize URL> (ssh $MAC_HOST login-forward: the MacBook forwards that port here and opens the page)"
  printf '%s\n' "would run: login_mac_notify 'Claude login ${account:-?}' <approve there, nothing to paste> (ssh $MAC_HOST notify)"
  printf '%s\n' "if the forward cannot be opened: login_open_on_mac ${app:-<default>} <code-paste URL> (ssh $MAC_HOST open-url), then a code dialog on the MacBook (ssh $MAC_HOST login-code) whose text goes to the login prompt (hc send $term)"
  exit 0
fi
if [[ -n "$port" ]]; then
  [[ -z "$URL_FILE" ]] || { ( umask 077; printf '%s\n' "$url" >"$URL_FILE" ) 2>/dev/null; }
  if login_forward_open "$app" "$port" "$url" "$URL_FILE"; then
    say "claude-login: approval page opened in ${app:-the default browser} on $MAC_HOST. Approve there: the callback is forwarded to this login, so there is nothing to paste."
    login_mac_notify "Claude login ${account:-?}" "Approve in ${app:-your browser}: the approval page is open and the login finishes by itself."
    exit 0
  fi
  say "claude-login: could not forward the callback port to this machine (${CLAUDE_LOGIN_FWD_WHY:-unknown}); the approval page will show a code instead"
else
  say "claude-login: the authorize URL has no loopback redirect_uri to forward; the approval page will show a code instead"
fi

# ── fallback: the code page, the code typed into a dialog on the MacBook ───────────────────────
shown=$(login_paste_url "$url")
[[ -z "$URL_FILE" ]] || { ( umask 077; printf '%s\n' "$shown" >"$URL_FILE" ) 2>/dev/null; }
login_open_on_mac "$app" "$shown" || { fallback "could not open the URL on $MAC_HOST"; exit 1; }
say "claude-login: approval page opened in ${app:-the default browser} on $MAC_HOST."
say "  Approve there and paste the code the page shows into the dialog on the MacBook (or at the prompt below, in THIS terminal)."
login_mac_notify "Claude login ${account:-?}" "Approve in ${app:-your browser}, then paste the code the page shows into the dialog on this MacBook."
login_code_dialog_start "${account:-x}" "$term" "$URL_FILE"
exit 0
