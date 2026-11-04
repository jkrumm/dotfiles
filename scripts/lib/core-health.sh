#!/bin/bash
# core-health.sh — one grader for the herdr-core on THIS machine, sourced by the
# heartbeat (check_core), doctor.sh and brew-upgrade.sh so the three cannot drift.
#
#   core_health_check   prints ONE line; returns 0 healthy, 2 WARN, 1 FAIL
#
# FAIL: the core is not up as lib/core-up.sh defines it (job `state = running` AND the
#       socket answers), or `hc server status` does not answer, or the core that answers
#       is not the job's child, or a default-session core runs outside the launcher: a
#       `herdr-core serve` with another parent (a client started it) or a detached
#       `herdr-core --hc-launchd` daemon (0.1.17+ escaping the launcher). Either has no
#       Full Disk Access and maybe no keychain.
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
# Overrides (tests): HC_BIN, PS_BIN, CORE_LAUNCHER, LAUNCHCTL_BIN, NC_BIN, HC_SOCKET, CORE_LABEL,
# CORE_PEER_SSH_HOST, CORE_PEER_CACHE_FILE, CORE_PEER_CACHE_TTL.

# shellcheck source=lib/core-up.sh
source "$(dirname "${BASH_SOURCE[0]}")/core-up.sh"

# Run a command with a hard wall (a wedged socket must not hang the heartbeat).
# This is a hang guard on a local CLI call, not an agent run.
_core_bounded() {
  local secs="$1"; shift
  /usr/bin/perl -e 'alarm shift; exec @ARGV or exit 127' "$secs" "$@"
}

# The job's own pid (the launcher's), empty when it has none.
core_launchd_pid() {
  "${LAUNCHCTL_BIN:-launchctl}" print "gui/$(id -u)/$CORE_LABEL" 2>/dev/null \
    | /usr/bin/awk -F' = ' '/^[[:space:]]*pid = /{ print $2; exit }'
}

# Print "<pid> <ppid> <parent command>" for every default-session core outside the launcher: an
# `hc|herdr-core serve` whose parent is not the launcher, or a detached `--hc-launchd` daemon (0.1.17+
# moves a core it was not told to keep to a one-shot launchd job; the launcher's HC_LAUNCHD_DIRECT
# prevents it, so one seen here escaped). ps only, no hc call. Scratch sessions (HC_SESSION other than
# "default" in the process env, via `ps -E`) are not strays.
core_strays() {
  local ps="${PS_BIN:-/bin/ps}" launcher="${CORE_LAUNCHER:-$HOME/.local/libexec/herdr-core-launcher}" pid ppid parent env
  while read -r pid ppid parent; do
    env=$("$ps" -E -ww -p "$pid" -o command= 2>/dev/null | tr ' ' '\n' | /usr/bin/grep -E '^HC_SESSION=.' | head -1) || env=""
    [[ -z "$env" || "$env" == HC_SESSION=default ]] && echo "$pid $ppid $parent"
  done < <("$ps" -U "$(id -u)" -xww -o pid=,ppid=,command= 2>/dev/null | /usr/bin/awk -v launcher="$launcher" '
    { pid=$1; ppid=$2; cmd0[pid]=$3; arg1[pid]=$4; par[pid]=ppid; ord[++n]=pid }
    END { for (i=1;i<=n;i++) { p=ord[i]; c=cmd0[p]; sub(".*/", "", c)
      if ((c != "hc" && c != "herdr-core") || (arg1[p] != "serve" && arg1[p] != "--hc-launchd")) continue
      if (cmd0[par[p]] == launcher) continue
      print p, par[p], (cmd0[par[p]] == "" ? "?" : cmd0[par[p]]) } }')
  return 0
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
  local hc="${HC_BIN:-$HOME/.local/bin/hc}" status version by uptime pid jobpid ppid peer stray spid sppid sparent
  [[ -x "$hc" ]] || { echo "hc not installed at $hc (fix: make herdr-core-setup)"; return 1; }

  [[ -n "$(core_launchd_state)" ]] \
    || { echo "$CORE_LABEL not loaded in launchd (fix: make herdr-core-setup)"; return 1; }
  # A stray first: it holds the core lock, so the job loops "spawn scheduled" and core_up below would hide it.
  stray=$(core_strays | head -1)
  if [[ -n "$stray" ]]; then
    read -r spid sppid sparent <<<"$stray"
    echo "core pid $spid runs outside the launcher (parent $sppid: $sparent): a client, a holder or a detached start, so it has no Full Disk Access and maybe no keychain (fix: kill $spid (SIGTERM keeps terminals), then launchctl kickstart -k gui/$(id -u)/$CORE_LABEL; the launcher reclaims the lock by itself on its next start; docs/herdr-core.md §Core as a LaunchAgent)"
    return 1
  fi
  core_up || { echo "$CORE_UP_WHY (fix: $CORE_UP_FIX)"; return 1; }

  status=$(_core_bounded 10 "$hc" server status --json 2>/dev/null) || status=""
  [[ -n "$status" ]] \
    || { echo "launchd runs $CORE_LABEL but 'hc server status' does not answer (see ~/Library/Logs/herdr-core.log)"; return 1; }
  # shellcheck disable=SC2016  # python, not shell
  read -r version by uptime pid < <(/usr/bin/python3 -c 'import json,sys
d=json.load(sys.stdin)
print(d.get("version") or "?", d.get("installed_by") or "none", int((d.get("uptime_ms") or 0)/1000), d.get("pid") or 0)' <<<"$status" 2>/dev/null) \
    || { echo "hc server status is not JSON"; return 1; }

  # The core that answers must be the job's child: launchd supervises it, and its terminals inherit the launcher.
  jobpid=$(core_launchd_pid)
  ppid=$("${PS_BIN:-/bin/ps}" -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
  if [[ -z "$jobpid" || "$ppid" != "$jobpid" ]]; then
    echo "core $version (pid $pid) is not the child of the $CORE_LABEL job (job pid ${jobpid:-none}, core parent ${ppid:-?}): launchd does not supervise it (fix: launchctl kickstart -k gui/$(id -u)/$CORE_LABEL; docs/herdr-core.md §Core as a LaunchAgent)"
    return 1
  fi

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
