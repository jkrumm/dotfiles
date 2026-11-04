#!/bin/bash
# herdr-core-guard — installed as ~/.local/bin/hc and ~/.local/bin/herdr-core (symlinks to this file,
# `make herdr-core-setup`). Refuses to let a client start a core outside launchd (docs/herdr-core.md
# §Core as a LaunchAgent). Homebrew's binaries cannot be patched and have no autostart switch: any client
# call (`hc ls`, `herdr-core connect` from the Herdr app or the MacBook's ssh machine link) starts a core
# when none answers, and a core born outside the LaunchAgent has no launcher (no Full Disk Access) and,
# from ssh, no keychain.
#
# Exempt: help/version/skill/schema (never touch a core) and any scratch session (HC_SESSION or a leading --session,
# other than "default"). Everything else waits (HC_GUARD_WAIT s, default 5) for the core to be up as lib/core-up.sh
# defines it (job `state = running` AND its socket accepts a connection), then execs the real, Cellar-resolved binary
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

real_dir=$(cd -P "$real_dir" 2>/dev/null && pwd -P) || { echo "$name: herdr-core is not installed at ${HC_GUARD_REAL_DIR:-/opt/homebrew/opt/herdr-core/bin} (fix: make herdr-core-setup)" >&2; exit 127; }
real="$real_dir/$name"
[[ -x "$real" ]] || { echo "$name: $real is not executable (fix: make herdr-core-setup)" >&2; exit 127; }

passthrough() {
  case "${1:-}" in -h | --help | -V | --version | --licenses | --skill | help | schema) return 0 ;; esac
  case "${2:-}" in -h | --help) return 0 ;; esac
  case "${1:-}" in server | machine | file) case "${3:-}" in -h | --help) return 0 ;; esac ;; esac
  [[ -n "${HC_SESSION:-}" && "$HC_SESSION" != default ]] && return 0
  # --session only counts before the subcommand (after it, it belongs to e.g. an `hc run <cmd>` command line)
  local a want=0
  for a in "$@"; do
    if [[ $want == 1 ]]; then [[ "$a" != default ]] && return 0; want=0; continue; fi
    case "$a" in
      --session) want=1 ;;
      --session=default) ;;
      --session=?*) return 0 ;;
      -*) ;;
      *) break ;;
    esac
  done
  return 1
}
passthrough "$@" && exec "$real" "$@"

# The definition of "up" lives in lib/core-up.sh (one for every consumer). ~/.local/bin/{hc,herdr-core} are symlinks
# to this file: resolve them to find it.
self="${BASH_SOURCE[0]}"
while [[ -L "$self" ]]; do
  link=$(readlink "$self")
  case "$link" in /*) self="$link" ;; *) self="$(dirname "$self")/$link" ;; esac
done
lib="$(cd -P "$(dirname "$self")" && pwd -P)/lib/core-up.sh"
# shellcheck source=lib/core-up.sh
source "$lib" 2>/dev/null || { echo "$name: cannot read $lib (fix: make herdr-core-setup)" >&2; exit 127; }
CORE_LABEL="${HC_GUARD_LABEL:-$CORE_LABEL}"

# Bounded wait in 0.2 s steps: the job may be mid-start (login, or a kickstart), which is not a refusal.
tries=$(( ${HC_GUARD_WAIT:-5} * 5 ))
i=0
while :; do
  core_up && exec "$real" "$@"
  (( i >= tries )) && break
  i=$((i + 1))
  /bin/sleep 0.2
done

{
  echo "$name: refusing to start a herdr-core outside launchd ($CORE_LABEL): $CORE_UP_WHY."
  echo "  A core started by a client has no launcher (no Full Disk Access) and, from ssh, no keychain."
  echo "  Fix: $CORE_UP_FIX, then retry. (docs/herdr-core.md §Core as a LaunchAgent)"
} >&2
exit 75
