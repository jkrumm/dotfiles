#!/bin/bash
# core-health.sh — one grader for the herdr-core on THIS machine, sourced by the
# heartbeat (check_core) and doctor.sh so the two cannot drift.
#
#   core_health_check   prints ONE line; returns 0 healthy, 2 WARN, 1 FAIL
#
# FAIL: the core is not up as lib/core-up.sh defines it (the default socket answers AND a launchd-born core
#       exists). A core that answers without being launchd-born is a stray (attributed to sshd, no keychain), so
#       core_up's second clause is the stray check; its message carries the fix. Also: `hc server status` does not answer.
# WARN: scripts/hc-responsible.py finds the core or a holder not attributed to Herdr Core.app (during the migration
#       old Cellar holders stay until their terminals end), or the other machine runs a different core version.
#
# NEVER start anything. An `hc` client call AUTO-STARTS a core when none runs, and a core born outside launchd is
# exactly the broken state this check exists to catch. So core_up (bare socket connect + ps) comes first and `hc` is
# only called once it passes.
#
# bash 3.2 (launchd hands the heartbeat Apple's /bin/bash): no mapfile, no ${v,,}.
#
# Overrides (tests): HC_BIN, HC_RESPONSIBLE_BIN, PS_BIN, NC_BIN, HC_SOCKET, CORE_LABEL,
# CORE_PEER_SSH_HOST, CORE_PEER_CACHE_FILE, CORE_PEER_CACHE_TTL.

# shellcheck source=lib/core-up.sh
source "$(dirname "${BASH_SOURCE[0]}")/core-up.sh"

# Run a command with a hard wall (a wedged socket must not hang the heartbeat).
# This is a hang guard on a local CLI call, not an agent run.
_core_bounded() {
  local secs="$1"; shift
  /usr/bin/perl -e 'alarm shift; exec @ARGV or exit 127' "$secs" "$@"
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
    case "$(tr -d '[:space:]' 2>/dev/null < "${XDG_CONFIG_HOME:-$HOME/.config}/secrets/backend")" in
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
  local hc="${HC_BIN:-$HOME/.local/bin/hc}" status version uptime peer resp
  local responsible="${HC_RESPONSIBLE_BIN:-$(dirname "${BASH_SOURCE[0]}")/../hc-responsible.py}"
  [[ -x "$hc" ]] || { echo "hc not installed at $hc (fix: make herdr-core-setup)"; return 1; }

  core_up || { echo "$CORE_UP_WHY (fix: $CORE_UP_FIX)"; return 1; }

  status=$(_core_bounded 10 "$hc" server status --json 2>/dev/null) || status=""
  [[ -n "$status" ]] \
    || { echo "a launchd-born core answers the socket but 'hc server status' does not (see ~/Library/Logs/herdr-core.log)"; return 1; }
  # shellcheck disable=SC2016  # python, not shell
  read -r version uptime < <(/usr/bin/python3 -c 'import json,sys
d=json.load(sys.stdin)
print(d.get("version") or "?", int((d.get("uptime_ms") or 0)/1000))' <<<"$status" 2>/dev/null) \
    || { echo "hc server status is not JSON"; return 1; }

  resp=$(_core_bounded 20 "$responsible" 2>/dev/null) && resp="" || resp=$(printf '%s\n' "$resp" | /usr/bin/grep -E '^(offenders:|agent environment inherited)' | head -1)
  if [[ -n "$resp" ]]; then
    echo "core $version: $resp (docs/herdr-core.md §How the core runs now: an inherited environment needs make herdr-core-clean-restart, old holders end with their terminals; list them with scripts/hc-responsible.py)"
    return 2
  fi

  peer=$(core_peer_version "$hc")
  if [[ -n "$peer" && "$peer" != "$version" ]]; then
    echo "core $version but the other machine runs $peer (update both in a quiet window: make herdr-core-update)"
    return 2
  fi
  echo "core $version, up ${uptime}s${peer:+, peer $peer}"
}
