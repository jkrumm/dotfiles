#!/bin/bash
# herdr-core-guard — installed as ~/.local/bin/hc and ~/.local/bin/herdr-core (symlinks to this file,
# `make herdr-core-setup`). Refuses to let a client start a core outside launchd (docs/herdr-core.md
# §Core as a LaunchAgent). Homebrew's binaries cannot be patched and have no autostart switch: any client
# call (`hc ls`, `herdr-core connect` from the Herdr app or the MacBook's ssh machine link) starts a core
# when none answers, and a core born outside the LaunchAgent has no launcher (no Full Disk Access) and,
# from ssh, no keychain.
#
# Exempt: help/version/skill/schema (never touch a core) and any scratch session (HC_SESSION other than
# "default", or --session). Everything else waits (HC_GUARD_WAIT s, default 5) for the job to be
# `state = running` AND its socket to accept a connection, then execs the real, Cellar-resolved binary
# (the core reports installed_by from its own exe path). Else it refuses: exit 75, nothing started.
# The LaunchAgent's launcher spawns the real binary directly, so only non-launchd callers pass through here.
#
# The check never calls hc: launchctl + a bare connect to the socket cannot autostart anything.
# bash 3.2 (ssh non-interactive on the mini; Apple's /bin/bash).
#
# Overrides (tests): HC_GUARD_REAL_DIR, HC_GUARD_LABEL, HC_GUARD_WAIT, LAUNCHCTL_BIN, NC_BIN, HC_SOCKET.

name="${0##*/}"
case "$name" in hc | herdr-core) ;; *) name=hc ;; esac
real_dir="${HC_GUARD_REAL_DIR:-/opt/homebrew/opt/herdr-core/bin}"
label="${HC_GUARD_LABEL:-com.jkrumm.herdr-core}"

real_dir=$(cd -P "$real_dir" 2>/dev/null && pwd -P) || { echo "$name: herdr-core is not installed at ${HC_GUARD_REAL_DIR:-/opt/homebrew/opt/herdr-core/bin} (fix: make herdr-core-setup)" >&2; exit 127; }
real="$real_dir/$name"
[[ -x "$real" ]] || { echo "$name: $real is not executable (fix: make herdr-core-setup)" >&2; exit 127; }

passthrough() {
  case "${1:-}" in -h | --help | -V | --version | --licenses | --skill | help | schema) return 0 ;; esac
  case "${2:-}" in -h | --help) return 0 ;; esac
  case "${1:-}" in server | machine | file) case "${3:-}" in -h | --help) return 0 ;; esac ;; esac
  [[ -n "${HC_SESSION:-}" && "$HC_SESSION" != default ]] && return 0
  local a
  for a in "$@"; do case "$a" in --session | --session=*) return 0 ;; esac; done
  return 1
}
passthrough "$@" && exec "$real" "$@"

uid=$(id -u)
launchctl="${LAUNCHCTL_BIN:-/bin/launchctl}"
nc="${NC_BIN:-/usr/bin/nc}"
if [[ -n "${HC_SOCKET:-}" ]]; then sock="$HC_SOCKET"
elif [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then sock="$XDG_RUNTIME_DIR/herdr-core/default.sock"
else sock="${XDG_STATE_HOME:-$HOME/.local/state}/herdr-core/default/default.sock"; fi

job_state() {
  "$launchctl" print "gui/$uid/$label" 2>/dev/null | /usr/bin/awk -F' = ' '/^[[:space:]]*state = /{ print $2; exit }'
}
answers() { [[ -S "$sock" ]] && "$nc" -U -w1 "$sock" </dev/null >/dev/null 2>&1; }

# Bounded wait in 0.2 s steps: the job may be mid-start (login, or a kickstart), which is not a refusal.
tries=$(( ${HC_GUARD_WAIT:-5} * 5 ))
i=0
state=""
while :; do
  state=$(job_state)
  [[ "$state" == running ]] && answers && exec "$real" "$@"
  (( i >= tries )) && break
  i=$((i + 1))
  /bin/sleep 0.2
done

if [[ "$state" == running ]]; then
  why="the job is running but its socket ($sock) does not answer"
  fix="check ~/Library/Logs/herdr-core.log; launchctl kickstart -k gui/$uid/$label"
elif [[ -n "$state" ]]; then
  why="the job is '$state', not running"
  fix="launchctl kickstart gui/$uid/$label"
else
  why="the job is not loaded"
  fix="make herdr-core-setup"
fi
{
  echo "$name: refusing to start a herdr-core outside launchd ($label): $why."
  echo "  A core started by a client has no launcher (no Full Disk Access) and, from ssh, no keychain."
  echo "  Fix: $fix, then retry. (docs/herdr-core.md §Core as a LaunchAgent)"
} >&2
exit 75
