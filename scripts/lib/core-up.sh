#!/bin/bash
# core-up.sh — THE definition of "the herdr-core on this machine is up" (docs/herdr-core.md §Core):
#
#   the default socket accepts a connection  AND  a launchd-born core exists (`herdr-core --hc-launchd`, parent pid 1).
#
# The core is upstream's own app, Herdr Core.app (official installer + `hc update`). Started by launchd (our
# com.jkrumm.herdr-core agent on the mini, the Herdr app on the MacBook) it detaches into its own one-shot job and
# is its own responsible process, so macOS attributes file access to the app bundle and the Full Disk Access grant on
# `Herdr Core.app` covers it. A core born from a client (`herdr-core connect` over ssh) answers on the same socket but
# is attributed to sshd and has no keychain: it is a stray, and no consumer may treat it as healthy. Neither half ever
# calls `hc`: any hc call auto-starts a core when none answers, so this check uses a bare connect and ps only.
#
# Sourced: core_up -> 0 up, 1 not up with CORE_UP_WHY and CORE_UP_FIX set (one clause each).
#          Used by lib/core-health.sh (heartbeat, doctor), claude-relogin.sh, hc-events/hc-resume/hc-reap.
# Run:     bash core-up.sh -> exit 0 silent, or exit 1 printing "<why>. Fix: <fix>". remote-dev.sh's require_core runs it
#          on the dev host, over ssh from the MacBook.
# Default session only: callers exempt scratch sessions (HC_SESSION other than default) themselves.
# bash 3.2 (launchd and ssh hand us Apple's /bin/bash).
#
# Overrides (tests): PS_BIN, NC_BIN, CORE_LABEL, HC_SOCKET, XDG_RUNTIME_DIR, XDG_STATE_HOME.

CORE_LABEL="${CORE_LABEL:-com.jkrumm.herdr-core}"

# The default session's socket, resolved the way hc resolves it.
core_socket() {
  if [[ -n "${HC_SOCKET:-}" ]]; then echo "$HC_SOCKET"
  elif [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then echo "$XDG_RUNTIME_DIR/herdr-core/default.sock"
  else echo "${XDG_STATE_HOME:-$HOME/.local/state}/herdr-core/default/default.sock"; fi
}

core_socket_answers() { "${NC_BIN:-nc}" -U -w1 "$(core_socket)" </dev/null >/dev/null 2>&1; }

# A core launchd started: upstream's detached form, parent pid 1. A client-started core is `herdr-core serve` under
# `herdr-core connect`.
core_launchd_born() {
  "${PS_BIN:-/bin/ps}" -axo ppid=,command= | /usr/bin/awk '$1 == 1 && /herdr-core --hc-launchd/ { f = 1 } END { exit !f }'
}

core_up() {
  local uid
  uid=$(id -u)
  CORE_UP_WHY="" CORE_UP_FIX=""
  if ! core_socket_answers; then
    CORE_UP_WHY="no core answers on $(core_socket)"
    CORE_UP_FIX="launchctl kickstart gui/$uid/$CORE_LABEL (the mini; the Herdr app starts the MacBook's), logs in ~/Library/Logs/herdr-core.log"
    return 1
  fi
  if ! core_launchd_born; then
    CORE_UP_WHY="a core answers but launchd did not start it (a client-started core is attributed to sshd and has no keychain)"
    CORE_UP_FIX="stop it (hc server stop keeps the terminals as shells but ends their programs; hc-resume resumes Claude sessions), then launchctl kickstart gui/$uid/$CORE_LABEL"
    return 1
  fi
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  core_up && exit 0
  echo "$CORE_UP_WHY. Fix: $CORE_UP_FIX"
  exit 1
fi
