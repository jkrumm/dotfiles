#!/bin/bash
# core-up.sh — THE definition of "the herdr-core on this machine is up" (docs/herdr-core.md §Core as a LaunchAgent):
#
#   launchd's com.jkrumm.herdr-core is `state = running`  AND  the default socket accepts a connection.
#
# Both halves matter. 0.1.17 showed a core that answered on its socket while launchd respawned the job every 10 s
# (`spawn scheduled`): an orphan outside the launcher, which no consumer may treat as healthy. A job that is running
# but whose socket does not answer is mid-start or wedged. Neither half ever calls `hc`: any hc call auto-starts a
# core when none answers, so this check uses launchctl and a bare connect only.
#
# Sourced: core_up -> 0 up, 1 not up with CORE_UP_STATE, CORE_UP_WHY and CORE_UP_FIX set (one clause each).
#          Used by herdr-core-guard.sh (every hc call), lib/core-health.sh (heartbeat, doctor), claude-relogin.sh.
# Run:     bash core-up.sh -> exit 0 silent, or exit 1 printing "<why>. Fix: <fix>". remote-dev.sh's require_core runs it
#          on the dev host, over ssh from the MacBook.
# Default session only: callers exempt scratch sessions (HC_SESSION other than default) themselves.
# bash 3.2 (launchd and ssh hand us Apple's /bin/bash).
#
# Overrides (tests): LAUNCHCTL_BIN, NC_BIN, CORE_LABEL, HC_SOCKET, XDG_RUNTIME_DIR, XDG_STATE_HOME.

CORE_LABEL="${CORE_LABEL:-com.jkrumm.herdr-core}"

# `state = running` of the job itself (first match: nested blocks say `state = active`). Empty when not loaded.
core_launchd_state() {
  "${LAUNCHCTL_BIN:-launchctl}" print "gui/$(id -u)/$CORE_LABEL" 2>/dev/null \
    | /usr/bin/awk -F' = ' '/^[[:space:]]*state = /{ print $2; exit }'
}

# The default session's socket, resolved the way hc resolves it.
core_socket() {
  if [[ -n "${HC_SOCKET:-}" ]]; then echo "$HC_SOCKET"
  elif [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then echo "$XDG_RUNTIME_DIR/herdr-core/default.sock"
  else echo "${XDG_STATE_HOME:-$HOME/.local/state}/herdr-core/default/default.sock"; fi
}

core_socket_answers() { "${NC_BIN:-nc}" -U -w1 "$(core_socket)" </dev/null >/dev/null 2>&1; }

core_up() {
  local uid
  uid=$(id -u)
  CORE_UP_STATE=$(core_launchd_state)
  CORE_UP_WHY="" CORE_UP_FIX=""
  if [[ -z "$CORE_UP_STATE" ]]; then
    CORE_UP_WHY="$CORE_LABEL is not loaded in launchd"
    CORE_UP_FIX="make herdr-core-setup"
    return 1
  fi
  if [[ "$CORE_UP_STATE" != running ]]; then
    CORE_UP_WHY="$CORE_LABEL is '$CORE_UP_STATE', not running"
    CORE_UP_FIX="launchctl kickstart gui/$uid/$CORE_LABEL; if launchctl print shows runs climbing, see docs/herdr-core.md §Core as a LaunchAgent"
    return 1
  fi
  if ! core_socket_answers; then
    CORE_UP_WHY="$CORE_LABEL is running but its socket ($(core_socket)) does not answer"
    CORE_UP_FIX="check ~/Library/Logs/herdr-core.log; launchctl kickstart -k gui/$uid/$CORE_LABEL"
    return 1
  fi
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  core_up && exit 0
  echo "$CORE_UP_WHY. Fix: $CORE_UP_FIX"
  exit 1
fi
