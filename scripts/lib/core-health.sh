#!/bin/bash
# core-health.sh — one grader for the herdr-core on THIS machine, sourced by the
# heartbeat (check_core), doctor.sh and brew-upgrade.sh so the three cannot drift.
#
#   core_health_check   prints ONE line; returns 0 healthy, 2 WARN, 1 FAIL
#
# FAIL: the LaunchAgent is not loaded/running, or `hc server status` does not answer.
# WARN: the core is unmanaged (`installed_by` null — the Herdr app could replace it
#       behind launchd's back) or the other machine runs a different version.
#
# NEVER start anything. An `hc` client call AUTO-STARTS a core when none runs
# (docs/herdr-core.md fact 9, re-verified 2026-10-31: `hc server status` on a fresh
# session booted one), and a core born outside launchd is exactly the broken state
# this check exists to catch. So launchd is asked first, and `hc` is only called
# when `launchctl print` says the job is running.
#
# bash 3.2 (launchd hands the heartbeat Apple's /bin/bash): no mapfile, no ${v,,}.
#
# Overrides (tests): HC_BIN, LAUNCHCTL_BIN, CORE_LABEL, CORE_PEER_SSH_HOST,
# CORE_PEER_CACHE_FILE, CORE_PEER_CACHE_TTL.

CORE_LABEL="${CORE_LABEL:-com.jkrumm.herdr-core}"

# Run a command with a hard wall (a wedged socket must not hang the heartbeat).
# This is a hang guard on a local CLI call, not an agent run.
_core_bounded() {
  local secs="$1"; shift
  /usr/bin/perl -e 'alarm shift; exec @ARGV or exit 127' "$secs" "$@"
}

# `state = running` of the job itself (first match: nested blocks say `state = active`).
core_launchd_state() {
  "${LAUNCHCTL_BIN:-/bin/launchctl}" print "gui/$(id -u)/$CORE_LABEL" 2>/dev/null \
    | /usr/bin/awk -F' = ' '/^[[:space:]]*state = /{ print $2; exit }'
}

# The other machine's core version, empty when it cannot be learned (a sleeping
# laptop is not a fault). Order: linked machines in `hc machine ls` (the MacBook
# links the mini), else ssh to the peer — the mini has no machine link to the
# MacBook. The ssh answer is cached so a 300 s heartbeat does not knock on a
# laptop every run.
core_peer_version() {
  local hc="$1" v="" host cache ttl now at
  v=$(_core_bounded 10 "$hc" machine ls --json 2>/dev/null \
    | /usr/bin/python3 -c 'import json,sys
for m in json.load(sys.stdin).get("machines",[]):
    if m.get("version"): print(m["version"]); break' 2>/dev/null) || v=""
  if [[ -n "$v" ]]; then echo "$v"; return 0; fi

  host="${CORE_PEER_SSH_HOST:-}"
  if [[ -z "$host" ]]; then
    case "$(tr -d '[:space:]' < "${XDG_CONFIG_HOME:-$HOME/.config}/secrets/backend" 2>/dev/null)" in
      cache) host=iumac ;;
      op)    host=mini ;;
    esac
  fi
  [[ -n "$host" ]] || return 0
  cache="${CORE_PEER_CACHE_FILE:-}"
  ttl="${CORE_PEER_CACHE_TTL:-1800}"
  if [[ -n "$cache" && -f "$cache" ]]; then
    read -r at v < "$cache" || true
    now=$(/bin/date +%s)
    if [[ -n "${v:-}" && "${at:-0}" =~ ^[0-9]+$ ]] && (( now - at < ttl )); then echo "$v"; return 0; fi
  fi
  # shellcheck disable=SC2016  # $HOME must expand on the peer
  v=$(_core_bounded 15 /usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=5 "$host" \
    '"$HOME/.local/bin/hc" --version' 2>/dev/null | /usr/bin/awk '{ print $2; exit }') || v=""
  if [[ -n "$v" && -n "$cache" ]]; then
    printf '%s %s\n' "$(/bin/date +%s)" "$v" > "$cache" 2>/dev/null || true
  fi
  echo "$v"
}

core_health_check() {
  local hc="${HC_BIN:-$HOME/.local/bin/hc}" state status version by uptime peer
  [[ -x "$hc" ]] || { echo "hc not installed at $hc (fix: make herdr-core-setup)"; return 1; }

  state=$(core_launchd_state)
  [[ -n "$state" ]] \
    || { echo "$CORE_LABEL not loaded in launchd (fix: make herdr-core-setup)"; return 1; }
  [[ "$state" == "running" ]] \
    || { echo "$CORE_LABEL is '$state', not running (KeepAlive should restart it; see ~/Library/Logs/herdr-core.log)"; return 1; }

  status=$(_core_bounded 10 "$hc" server status --json 2>/dev/null) || status=""
  [[ -n "$status" ]] \
    || { echo "launchd runs $CORE_LABEL but 'hc server status' does not answer (see ~/Library/Logs/herdr-core.log)"; return 1; }
  # shellcheck disable=SC2016  # python, not shell
  read -r version by uptime < <(/usr/bin/python3 -c 'import json,sys
d=json.load(sys.stdin)
print(d.get("version") or "?", d.get("installed_by") or "none", int((d.get("uptime_ms") or 0)/1000))' <<<"$status" 2>/dev/null) \
    || { echo "hc server status is not JSON"; return 1; }

  if [[ "$by" == "none" ]]; then
    echo "core $version is unmanaged (installed_by null): the Herdr app can replace it behind launchd (fix: make herdr-core-setup YES=1)"
    return 2
  fi

  peer=$(core_peer_version "$hc")
  if [[ -n "$peer" && "$peer" != "$version" ]]; then
    echo "core $version ($by) but the other machine runs $peer (the daily herdr-core-update converges them; make herdr-core-update)"
    return 2
  fi
  echo "core $version ($by), up ${uptime}s${peer:+, peer $peer}"
}
