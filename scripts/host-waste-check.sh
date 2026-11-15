#!/usr/bin/env bash
# host-waste-check — the dev host's steady background waste, one line per check. docs/host-waste.md has the causes and the numbers.
#
#   host-waste-check.sh orphan-sleeps   sleeps whose parent is launchd (a watchdog that forgot to reap its timer)
#   host-waste-check.sh tailscaled      tailscaled's CPU as a share of one core over 10 s, with the bytes it moved
#   host-waste-check.sh mediaanalysisd  Photos analysis stays disabled and stopped (docs/host-waste.md §mediaanalysisd)
#   host-waste-check.sh sshd-sessions   sshd-session processes (two per login); a pile means peers that never closed
#   host-waste-check.sh fix-mediaanalysisd   disable the agent (no sudo; `make photos-analysis-off`)
#
# Exit 0 = fine, 2 = WARN (the line says what and how to fix). Nothing here fails: `make doctor` shows a WARN and stays green.
#
# Overrides (tests): PS_BIN LAUNCHCTL_BIN TAILSCALE_BIN HOST_WASTE_SLEEP_BIN TAILSCALED_WINDOW ORPHAN_SLEEP_MAX TAILSCALED_CPU_MAX SSHD_SESSIONS_MAX.
# bash 3.2 (macOS /bin/bash).
set -uo pipefail

PS_BIN="${PS_BIN:-/bin/ps}"
LAUNCHCTL_BIN="${LAUNCHCTL_BIN:-/bin/launchctl}"
TAILSCALE_BIN="${TAILSCALE_BIN:-tailscale}"
ORPHAN_SLEEP_MAX="${ORPHAN_SLEEP_MAX:-10}"
TAILSCALED_CPU_MAX="${TAILSCALED_CPU_MAX:-40}"   # percent of one core over the window
TAILSCALED_WINDOW="${TAILSCALED_WINDOW:-10}"
SLEEP_BIN="${HOST_WASTE_SLEEP_BIN:-/bin/sleep}"
SSHD_SESSIONS_MAX="${SSHD_SESSIONS_MAX:-20}"     # sshd-session processes (a login is two)
AGENT=com.apple.mediaanalysisd

check_orphan_sleeps() {
  local out n
  out=$("$PS_BIN" -Ao ppid=,args= | awk '$1 == 1 && $2 ~ /(^|\/)sleep$/ { c[$2 " " $3]++; n++ }
    END { printf "%d", n; for (k in c) printf "|%s x%d", k, c[k] }')
  n=${out%%|*}
  if [ "$n" -gt "$ORPHAN_SLEEP_MAX" ]; then
    echo "$n orphaned sleep processes (parent launchd; limit $ORPHAN_SLEEP_MAX): $(printf '%s' "${out#*|}" | tr '|' ',' | cut -c1-120)"
    return 2
  fi
  echo "$n orphaned sleep processes (limit $ORPHAN_SLEEP_MAX)"
}

# tailscaled's accumulated CPU seconds ([dd-][hh:]mm:ss.cc) and the bytes it has moved, as "<cpu_s> <bytes>"
ts_sample() {
  local cpu bytes
  cpu=$("$PS_BIN" -Ao cputime=,comm= | awk '$2 ~ /(^|\/)tailscaled$/ {
    t = $1; d = 0; if (index(t, "-")) { split(t, p, "-"); d = p[1]; t = p[2] }
    n = split(t, a, ":"); s = 0; for (i = 1; i <= n; i++) s = s * 60 + a[i]; printf "%.2f", d * 86400 + s; exit }')
  [ -n "$cpu" ] || return 1
  bytes=$("$TAILSCALE_BIN" metrics print 2>/dev/null | awk '/^tailscaled_(inbound|outbound)_bytes_total/ { s += $NF } END { printf "%.0f", s }')
  echo "$cpu ${bytes:-0}"
}

# Read over a short window, not since boot: a bulk copy that ended an hour ago must not keep the line yellow all day.
check_tailscaled() {
  local a b pct rate
  a=$(ts_sample) || { echo "tailscaled not running"; return 0; }
  "$SLEEP_BIN" "$TAILSCALED_WINDOW"
  b=$(ts_sample) || { echo "tailscaled stopped while measuring"; return 0; }
  pct=$(awk -v a="$a" -v b="$b" -v w="$TAILSCALED_WINDOW" 'BEGIN { split(a, x, " "); split(b, y, " "); printf "%d", (y[1] - x[1]) / w * 100 }')
  rate=$(awk -v a="$a" -v b="$b" -v w="$TAILSCALED_WINDOW" 'BEGIN { split(a, x, " "); split(b, y, " "); printf "%.1f", (y[2] - x[2]) / w / 1048576 }')
  # The CPU is WireGuard work: it follows the bytes moved, not a fault. Naming the volume points the WARN at the transfer.
  if [ "$pct" -gt "$TAILSCALED_CPU_MAX" ]; then
    echo "tailscaled at ${pct}% of one core over ${TAILSCALED_WINDOW}s (limit ${TAILSCALED_CPU_MAX}%), ${rate} MiB/s moved: a bulk copy through the mini, docs/host-waste.md"
    return 2
  fi
  echo "tailscaled at ${pct}% of one core over ${TAILSCALED_WINDOW}s (limit ${TAILSCALED_CPU_MAX}%), ${rate} MiB/s moved"
}

check_mediaanalysisd() {
  local uid disabled=0 running=0
  uid=$(id -u)
  # Captured, then matched: `grep -q` closing a pipe early makes the producer die of SIGPIPE, which pipefail turns into a miss.
  local states procs
  states=$("$LAUNCHCTL_BIN" print-disabled "gui/$uid" 2>/dev/null)
  procs=$("$PS_BIN" -Ao comm=)
  grep -q "\"$AGENT\" => \(disabled\|true\)" <<<"$states" && disabled=1
  grep -q '/mediaanalysisd$' <<<"$procs" && running=1
  if [ "$disabled" -eq 1 ] && [ "$running" -eq 0 ]; then echo "$AGENT disabled and stopped"; return 0; fi
  if [ "$disabled" -eq 0 ]; then
    echo "$AGENT is enabled (Photos analysis burns about half a core on a library this size; fix: make photos-analysis-off)"
  else
    echo "$AGENT is disabled but still running (launchd keeps the loaded agent until the next restart, make planned-restart; kill the pid meanwhile, docs/host-waste.md §mediaanalysisd)"
  fi
  return 2
}

check_sshd_sessions() {
  local n
  n=$("$PS_BIN" -Ao args= | grep -c '^sshd-session: .*\[postauth\]')
  if [ "$n" -gt "$SSHD_SESSIONS_MAX" ]; then
    echo "$n sshd sessions (limit $SSHD_SESSIONS_MAX): peers that never closed; ClientAliveInterval is unset (docs/host-waste.md §sshd)"
    return 2
  fi
  echo "$n sshd sessions (limit $SSHD_SESSIONS_MAX)"
}

# The supported stop: launchd's own disable switch for the one user-domain agent. It needs no sudo and survives a reboot;
# System Integrity Protection refuses `bootout` of an Apple agent, so a running daemon ends at its next exit or login.
fix_mediaanalysisd() {
  "$LAUNCHCTL_BIN" disable "gui/$(id -u)/$AGENT" || { echo "launchctl disable $AGENT failed"; return 1; }
  echo "$AGENT disabled (undo: launchctl enable gui/$(id -u)/$AGENT)"
}

case "${1:-}" in
  orphan-sleeps) check_orphan_sleeps ;;
  tailscaled) check_tailscaled ;;
  mediaanalysisd) check_mediaanalysisd ;;
  sshd-sessions) check_sshd_sessions ;;
  fix-mediaanalysisd) fix_mediaanalysisd ;;
  *) echo "usage: host-waste-check.sh orphan-sleeps|tailscaled|mediaanalysisd|sshd-sessions|fix-mediaanalysisd" >&2; exit 64 ;;
esac
