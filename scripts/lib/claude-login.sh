#!/usr/bin/env bash
# claude-login.sh — shared helpers of claude-relogin.sh and claude-login-browser.sh (docs/claude-accounts.md
# §Re-login). Sourced, no side effects. BASH 3.2 (the mini and the MacBook run Apple's bash in places).

# Which machine this is: the mini carries the secrets backend `cache` (the same signal human-queue.sh and
# remote-dev.sh key off), anything else is the MacBook.
login_local_machine() {
  if [[ "$(cat "${XDG_CONFIG_HOME:-$HOME/.config}/secrets/backend" 2>/dev/null)" == "cache" ]]; then echo mini; else echo macbook; fi
}

# The code-paste variant of an authorize URL: its loopback redirect_uri (http://localhost:<port>/callback, percent-encoded
# as in the real URL or raw) swapped for the platform's code page, which shows the code instead of calling back. That is
# the manual URL the CLI itself prints; state and PKCE challenge stay, so the code pasted at the CLI's prompt completes
# this very login. A URL without a loopback redirect_uri is printed unchanged. `code=true` is added when missing.
login_paste_url() { # <authorize-url>
  local out
  out=$(printf '%s' "${1-}" | sed -E 's#([?&]redirect_uri=)http(%3[Aa]|:)(%2[Ff]|/)(%2[Ff]|/)(localhost|127\.0\.0\.1)(%3[Aa]|:)[0-9]{1,5}[^&]*#\1https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback#')
  case "$out" in *[\?\&]code=true*|"") ;; *\?*) out="$out&code=true" ;; esac
  printf '%s' "$out"
}

# Open <url> in <app> (empty = the default browser) on the MacBook: the fixed `open-url` verb of its ssh gate, the app
# name and then the URL on stdin. Test seams as in claude-login-browser.sh.
login_open_on_mac() { # <app> <url>
  printf '%s\n%s\n' "${1-}" "${2-}" | "${CLAUDE_LOGIN_SSH:-ssh}" -o BatchMode=yes -o ConnectTimeout=8 "${CLAUDE_LOGIN_MAC_HOST:-iumac}" open-url
}

# A native notification on the MacBook, best effort: the gate's `notify` verb, the title and then the text on stdin.
login_mac_notify() { # <title> <text>
  printf '%s\n%s\n' "${1-}" "${2-}" | "${CLAUDE_LOGIN_SSH:-ssh}" -o BatchMode=yes -o ConnectTimeout=8 "${CLAUDE_LOGIN_MAC_HOST:-iumac}" notify >/dev/null 2>&1 || true
}

# One argument as a single POSIX shell word ('…' with embedded quotes spelled '\''). The authorize URL carries & and
# %, which a remote shell would otherwise split or expand.
login_shquote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# macOS app (as `open -a` names it) that is signed in to the account, from the registry's `loginBrowser`. Prints an
# empty string (rc 0) for an account that has none: the caller falls back to the system default and says so. An
# unusable registry must never look like that, so it fails distinctly: rc 2 = jq missing or the registry unreadable or
# malformed, rc 3 = the registry has no such account (the reason goes to stderr).
login_browser_for() { # <registry> <id>
  local reg=$1 id=$2
  command -v jq >/dev/null 2>&1 || { echo "claude-login: jq not found, cannot read the registry" >&2; return 2; }
  jq -e '.accounts | type == "object"' "$reg" >/dev/null 2>&1 || { echo "claude-login: registry $reg is unreadable or malformed" >&2; return 2; }
  jq -e --arg id "$id" '.accounts | has($id)' "$reg" >/dev/null 2>&1 || { echo "claude-login: registry $reg has no account '$id'" >&2; return 3; }
  jq -r --arg id "$id" '.accounts[$id].loginBrowser // ""' "$reg"
}

# Removes anything token-shaped from a stream, line-buffered (nothing is held back, so a flush at exit is never
# needed): sk-ant-… keys, Bearer values, and the value of any code / state / *token / *secret / *verifier key
# written as key=value, key: value or "key": "value" (OAuth codes and states travel in URLs and JSON).
login_redact() {
  perl -pe 'BEGIN { $| = 1 }
    s/sk-ant-[\w-]+/[redacted]/g;
    s/\b(\w*(?:code|state|token|secret|verifier))(["\x27]?\s*[=:]\s*["\x27]?)[^\s"\x27&,}]{6,}/$1$2\[redacted]/gi;
    s/\b(Bearer\s+)[\w.~+\/=-]{8,}/$1\[redacted]/gi;'
}
