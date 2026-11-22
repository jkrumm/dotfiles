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

# The port of an authorize URL's loopback redirect_uri (http://localhost:<port>/callback, percent-encoded or raw); empty when
# it has none.
login_redirect_port() { # <authorize-url>
  printf '%s' "${1-}" | sed -nE 's#.*[?&]redirect_uri=http(%3[Aa]|:)(%2[Ff]|/)(%2[Ff]|/)(localhost|127\.0\.0\.1)(%3[Aa]|:)([0-9]{1,5})(%2[Ff]|/|&|$).*#\6#p' | head -n 1
}

# True for the code-paste variant of an authorize URL (login_paste_url's output): its redirect_uri is the platform's code page.
login_url_is_paste() { # <url>
  case "${1-}" in *platform.claude.com%2[Ff]oauth%2[Ff]code* | *platform.claude.com/oauth/code*) return 0 ;; *) return 1 ;; esac
}

# The MacBook forwards <port> to this machine's loopback and opens <url> in <app> (the gate's login-forward verb: stdin app,
# port, URL), so the browser's callback to localhost:<port> lands in this machine's `claude auth login` and nothing is
# pasted. The verb holds the forward while its stdin is open; that is kept open here for as long as <marker> exists (the
# login's own file, gone when the login ends), or, without one, while the calling process lives. Returns 0 once the MacBook
# says "forwarded"; otherwise 1 with a reason word in CLAUDE_LOGIN_FWD_WHY (port-busy, forward, open, ssh, timeout).
# shellcheck disable=SC2034 # CLAUDE_LOGIN_FWD_WHY is the caller's to read
login_forward_open() { # <app> <port> <url> <marker>
  local out parent=$PPID marker="${4-}" pid i=0 first
  CLAUDE_LOGIN_FWD_WHY=ssh
  out=$(mktemp "${TMPDIR:-/tmp}/claude-login-fwd.XXXXXX") || return 1
  {
    printf '%s\n%s\n%s\n' "${1-}" "${2-}" "${3-}"
    while if [[ -n "$marker" ]]; then [[ -e "$marker" ]]; else kill -0 "$parent" 2>/dev/null; fi; do sleep 2; done
  } </dev/null 2>/dev/null | "${CLAUDE_LOGIN_SSH:-ssh}" -o BatchMode=yes -o ConnectTimeout=8 "${CLAUDE_LOGIN_MAC_HOST:-iumac}" login-forward >"$out" 2>/dev/null &
  pid=$!
  while (( i < 150 )); do
    first=$(head -n 1 "$out" 2>/dev/null)
    [[ -n "$first" ]] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.2; i=$((i + 1))
  done
  first=$(head -n 1 "$out" 2>/dev/null)
  rm -f "$out"
  case "$first" in
    forwarded) CLAUDE_LOGIN_FWD_WHY=""; return 0 ;;
    "failed: "*) CLAUDE_LOGIN_FWD_WHY="${first#failed: }" ;;
    "") kill "$pid" 2>/dev/null; (( i >= 150 )) && CLAUDE_LOGIN_FWD_WHY=timeout ;;
  esac
  return 1
}

# The code dialog of a mini login in paste mode, started detached, one per account at a time (pid file next to <marker>):
# the MacBook shows a native text field (the gate's login-code verb), and what is typed is sent to the login's prompt in its
# terminal (hc send). It ends when the dialog is cancelled, empty or times out (asking again reopens it) or when the login is
# over (<marker> gone). The code lives in one variable: never printed, logged or written to a file.
login_code_dialog_start() { # <account> <terminal> <marker>
  local lock pid
  lock="$(dirname "${3:-${TMPDIR:-/tmp}/x}")/$1.dialog-pid"
  if [[ -e "$lock" ]]; then
    pid=$(cat "$lock" 2>/dev/null)
    if [[ -n "$pid" ]]; then kill -0 "$pid" 2>/dev/null && return 0
    elif [[ -n "$(find "$lock" -mmin -20 2>/dev/null)" ]]; then return 0; fi   # still starting
  fi
  : >"$lock" 2>/dev/null || true
  # the subshell records its own pid (sh's parent), and its lock is gone when the dialog is over
  ( sh -c 'echo $PPID' >"$lock" 2>/dev/null; login_code_dialog "$1" "$2" "${3-}"; rm -f "$lock" ) </dev/null >/dev/null 2>&1 &
}
login_code_dialog() { # <account> <terminal> <marker>
  local acct=$1 term=$2 marker=$3 code
  code=$(printf '%s\n' "$acct" | "${CLAUDE_LOGIN_SSH:-ssh}" -o BatchMode=yes -o ConnectTimeout=8 "${CLAUDE_LOGIN_MAC_HOST:-iumac}" login-code 2>/dev/null)
  if [[ -z "$code" ]]; then
    login_mac_notify "Claude login $acct" "No code entered. Run claude-relogin $acct again to open the dialog again."
    return 0
  fi
  code=$(printf '%s' "$code" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
  if [[ -n "$marker" && ! -e "$marker" ]]; then return 0; fi   # the login ended while the dialog was open
  if (( ${#code} < 8 || ${#code} > 600 )) || ! [[ "$code" =~ ^[A-Za-z0-9._~#%/+=:-]+$ ]]; then
    login_mac_notify "Claude login $acct" "That did not look like the code from the approval page. Run claude-relogin $acct again to paste it again."
    return 0
  fi
  if ! perl -e 'alarm 20; exec @ARGV' -- "${CLAUDE_LOGIN_HC:-hc}" send --force "$term" "$code" >/dev/null 2>&1; then
    login_mac_notify "Claude login $acct" "The code could not be sent to the login terminal $term. Run claude-relogin $acct again."
  fi
  return 0
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
