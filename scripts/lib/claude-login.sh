#!/usr/bin/env bash
# claude-login.sh — shared helpers of claude-relogin.sh and claude-login-browser.sh (docs/claude-accounts.md
# §Re-login). Sourced, no side effects. BASH 3.2 (the mini and the MacBook run Apple's bash in places).

# Which machine this is: the mini carries the secrets backend `cache` (the same signal human-queue.sh and
# remote-dev.sh key off), anything else is the MacBook.
login_local_machine() {
  if [[ "$(cat "${XDG_CONFIG_HOME:-$HOME/.config}/secrets/backend" 2>/dev/null)" == "cache" ]]; then echo mini; else echo macbook; fi
}

# Callback port of an authorize URL: the port in its redirect_uri (http://localhost:<port>/callback, either
# percent-encoded as in the real URL or raw). Prints nothing and returns 1 when there is none, or it is not a
# loopback http URL, or the port is out of range.
login_url_port() {
  local port
  port=$(printf '%s' "${1-}" | sed -n -E 's#.*[?&]redirect_uri=http(%3[Aa]|:)(%2[Ff]|/)(%2[Ff]|/)(localhost|127\.0\.0\.1)(%3[Aa]|:)([0-9]{1,5})(%2[Ff]|/|&|$).*#\6#p')
  [[ -n "$port" ]] && (( 10#$port >= 1 && 10#$port <= 65535 )) || return 1
  echo "$((10#$port))"
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

# What the reverse-forward watchdog does on one poll. Prints `keep` or `close:<reason>`.
#   owner_alive     1 = the login process still runs (or is unknown), 0 = gone
#   listening       1 = something listens on the callback port on this machine right now
#   seen_listening  1 = it listened at least once since the tunnel opened
#   idle_s          seconds since a connection last used the port (resets on activity)
#   max_idle_s      the idle watchdog; generous, the only time limit
login_tunnel_verdict() { # owner_alive listening seen_listening idle_s max_idle_s
  local owner=$1 listening=$2 seen=$3 idle=$4 max=$5
  if [[ "$owner" != 1 ]]; then echo "close:owner-gone"; return; fi
  if [[ "$seen" == 1 && "$listening" != 1 ]]; then echo "close:login-ended"; return; fi
  if (( idle >= max )); then echo "close:idle"; return; fi
  echo keep
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
