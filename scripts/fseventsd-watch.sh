#!/usr/bin/env bash
# fseventsd-watch — restart the macOS file-events daemon when it leaks. Daily, via com.jkrumm.fseventsd-watch.
#
# WHY. fseventsd grows without bound on this host (agents churn worktrees, node_modules and Chrome clones): 61 GiB on
# 2026-11-06 (filled the swap, held the dev host DOWN), 2.1 GB at 260 % CPU after 5 days on 2026-11-12 (swapouts 5 GB per
# 300 s, load 200+). docs/architecture.md said "schedule the restart if it recurs"; it recurred. launchd respawns it at a
# few MiB, and `launchctl kickstart -k` is refused by SIP, so the only restart is `killall fseventsd` as root.
#
# WHEN. Restart if its memory (top's MEM column, which counts compressed pages; ps RSS leaves them out) is above
# FSEVENTSD_RESTART_MB (default 1536 = 1.5 GB), or its CPU stays at or above FSEVENTSD_CPU_PCT (default 150) for
# FSEVENTSD_CPU_WINDOW_S (default 600 = 10 min). The CPU rule samples `top` sample every FSEVENTSD_SAMPLE_S (30 s) and only
# starts sampling when the first sample is already over the line, so a healthy day costs one second.
#
# HOW. `sudo -n /usr/bin/killall fseventsd`, allowed by exactly one sudoers rule (scripts/sudoers.d/fseventsd-restart,
# installed ONCE by `make fseventsd-sudoers`, which the owner runs through ask-human: the root password is MacBook-only).
# Without the rule the job says so and exits 0 (the leak is a WARN in the heartbeat's memory component anyway).
#
# Usage: fseventsd-watch.sh [--dry-run]   --dry-run decides and names what it WOULD do; it never calls sudo.
# Exit 0 = nothing to do, or restarted, or dry run, or the rule is not installed yet; 1 = the restart itself failed.
# Overrides (tests): PGREP_BIN TOP_BIN AWK_BIN SUDO_BIN KILLALL_BIN FSEVENTSD_SLEEP_BIN.
# bash 3.2 (launchd hands us Apple's /bin/bash).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/fseventsd-mem.sh
source "$HERE/lib/fseventsd-mem.sh"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1
SUDO_BIN="${SUDO_BIN:-/usr/bin/sudo}"
KILLALL_BIN="${KILLALL_BIN:-/usr/bin/killall}"
SLEEP_BIN="${FSEVENTSD_SLEEP_BIN:-/bin/sleep}"
RESTART_MB="${FSEVENTSD_RESTART_MB:-1536}"
CPU_PCT="${FSEVENTSD_CPU_PCT:-150}"
CPU_WINDOW_S="${FSEVENTSD_CPU_WINDOW_S:-600}"
SAMPLE_S="${FSEVENTSD_SAMPLE_S:-30}"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') fseventsd-watch: $*"; }

# Instantaneous CPU: the SECOND sample of `top -l 2` (the first is since-boot noise, and ps %cpu is a decaying average).
cpu_of() { "${TOP_BIN:-/usr/bin/top}" -l 2 -pid "$1" -stats cpu 2>/dev/null | "${AWK_BIN:-/usr/bin/awk}" 'NF { l = $1 } END { printf "%d", l + 0 }'; }

pm=$(fseventsd_mem_mb) || pm=""
if [ -z "$pm" ]; then
  log "no fseventsd process (or top unreadable) — nothing to do"
  exit 0
fi
pid=${pm%% *}
mem_mb=${pm#* }

reason=""
if [ "$mem_mb" -gt "$RESTART_MB" ]; then
  reason="memory ${mem_mb} MB is above ${RESTART_MB} MB"
else
  cpu=$(cpu_of "$pid")
  cpu=${cpu:-0}
  if [ "$cpu" -ge "$CPU_PCT" ]; then
    # Over the line right now: it must STAY there for the whole window (every sample), or it was a burst.
    elapsed=0
    sustained=1
    while [ "$elapsed" -lt "$CPU_WINDOW_S" ]; do
      "$SLEEP_BIN" "$SAMPLE_S"
      elapsed=$((elapsed + SAMPLE_S))
      cpu=$(cpu_of "$pid")
      cpu=${cpu:-0}
      if [ "$cpu" -lt "$CPU_PCT" ]; then sustained=0; break; fi
    done
    [ "$sustained" -eq 1 ] && reason="CPU stayed at or above ${CPU_PCT}% for ${CPU_WINDOW_S} s (last sample ${cpu}%)"
  fi
fi

if [ -z "$reason" ]; then
  log "pid $pid healthy: ${mem_mb} MB (limit ${RESTART_MB} MB), CPU under ${CPU_PCT}% — nothing to do"
  exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
  log "DRY RUN: pid $pid — $reason — would run: sudo -n $KILLALL_BIN fseventsd (launchd respawns it at a few MiB)"
  if "$SUDO_BIN" -n -l "$KILLALL_BIN" fseventsd >/dev/null 2>&1; then
    log "DRY RUN: the sudoers rule is installed"
  else
    log "DRY RUN: the sudoers rule is NOT installed yet (make fseventsd-sudoers, through ask-human)"
  fi
  exit 0
fi

if ! "$SUDO_BIN" -n -l "$KILLALL_BIN" fseventsd >/dev/null 2>&1; then
  log "pid $pid — $reason — but the sudoers rule is not installed, so no restart (run: make fseventsd-sudoers through ask-human)"
  exit 0
fi
log "pid $pid — $reason — restarting"
if "$SUDO_BIN" -n "$KILLALL_BIN" fseventsd; then
  log "restarted: killall fseventsd sent, launchd respawns it"
else
  log "killall fseventsd FAILED"
  exit 1
fi
