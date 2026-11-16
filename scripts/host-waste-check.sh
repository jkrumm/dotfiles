#!/usr/bin/env bash
# host-waste-check — the dev host's steady background waste, one line per check. docs/host-waste.md has the causes and the numbers.
#
#   host-waste-check.sh orphan-sleeps   sleeps whose parent is launchd (a watchdog that forgot to reap its timer)
#   host-waste-check.sh tailscaled      tailscaled's CPU as a share of one core over 10 s, with the bytes it moved
#   host-waste-check.sh mediaanalysisd  Photos analysis stays disabled and stopped (docs/host-waste.md §mediaanalysisd)
#   host-waste-check.sh sshd-sessions   sshd-session processes (two per login); a pile means peers that never closed
#   host-waste-check.sh fix-mediaanalysisd   disable the agent (no sudo; `make photos-analysis-off`)
#   host-waste-check.sh stop-mediaanalysisd   SIGSTOP the running daemon (the `com.jkrumm.photos-analysis-stop` job, every 5 minutes)
#   host-waste-check.sh cpu [SECS]     the host-service daemons' CPU over SECS (default 300) as cores, the table `make host-cpu` prints
#
# Exit 0 = fine, 2 = WARN (the line says what and how to fix). Nothing here fails: `make doctor` shows a WARN and stays green.
#
# Overrides (tests): PS_BIN LAUNCHCTL_BIN TAILSCALE_BIN HOST_WASTE_SLEEP_BIN TAILSCALED_WINDOW ORPHAN_SLEEP_MAX TAILSCALED_CPU_MAX SSHD_SESSIONS_MAX.
# bash 3.2 (macOS /bin/bash).
set -uo pipefail

PS_BIN="${PS_BIN:-/bin/ps}"
LAUNCHCTL_BIN="${LAUNCHCTL_BIN:-/bin/launchctl}"
TAILSCALE_BIN="${TAILSCALE_BIN:-tailscale}"
TOP_BIN="${TOP_BIN:-/usr/bin/top}"
KILL_BIN="${KILL_BIN:-/bin/kill}"
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
  # A process in state T (SIGSTOPped by stop-mediaanalysisd) costs nothing and counts as stopped.
  procs=$("$PS_BIN" -Ao stat=,comm= | grep -v '^T')
  grep -q "\"$AGENT\" => \(disabled\|true\)" <<<"$states" && disabled=1
  grep -q '/mediaanalysisd$' <<<"$procs" && running=1
  if [ "$disabled" -eq 1 ] && [ "$running" -eq 0 ]; then echo "$AGENT disabled and stopped"; return 0; fi
  if [ "$disabled" -eq 0 ]; then
    echo "$AGENT is enabled (Photos analysis burns about half a core on a library this size; fix: make photos-analysis-off)"
  else
    echo "$AGENT is disabled but still running (launchd keeps the loaded agent until the next restart, make planned-restart; the 5-minute com.jkrumm.photos-analysis-stop job SIGSTOPs it, so this line clears within minutes; if it does not, make photos-analysis-off, docs/host-waste.md §mediaanalysisd)"
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

# CPU seconds per pid from the accumulated cputime column, so a bursty daemon is read over the whole window. A pid that is new in
# the second snapshot counts in full (it was born inside the window: mediaanalysisd respawns); one that exited in between is missed.
cpu_snap() {
  # ps does not list pid 0; top reads kernel_task's accumulated TIME (hh:mm:ss, one-second resolution: use windows of a minute or more)
  "$TOP_BIN" -l 1 -pid 0 -stats pid,time 2>/dev/null | awk '$1 == 0 { n = split($2, a, ":"); if (n == 3) print 0, a[1] * 3600 + a[2] * 60 + a[3], "kernel_task" }'
  "$PS_BIN" -Ao pid=,cputime=,comm= | awk '{
    n = split($2, a, /[-:.]/); s = 0
    if (n == 3) s = a[1] * 60 + a[2] + a[3] / 100
    else if (n == 4) s = a[1] * 3600 + a[2] * 60 + a[3] + a[4] / 100
    else if (n == 5) s = a[1] * 86400 + a[2] * 3600 + a[3] * 60 + a[4] + a[5] / 100
    m = $3; for (i = 4; i <= NF; i++) m = m " " $i; sub(/.*\//, "", m); print $1, s, m }'
}

# The daemons issue 1744 named: Photos analysis, Spotlight, XProtect and Gatekeeper, the VPN, the copy job, the kernel.
cmd_cpu() {
  local w="${1:-300}" a b
  a=$(mktemp); b=$(mktemp); trap 'rm -f "$a" "$b"' RETURN
  cpu_snap > "$a"; "$SLEEP_BIN" "$w"; cpu_snap > "$b"
  awk -v W="$w" 'NR == FNR { t[$1] = $2; next }
    { d = ($1 in t) ? $2 - t[$1] : $2; if (d < 0) d = 0; g[$3] += d }
    END { for (k in g) if (k ~ /^(kernel_task|mediaanalysisd|corespotlightd|managedcorespotlightd|mds|mds_stores|mdworker_shared|fseventsd|XprotectService|syspolicyd|tailscaled|rclone)$/) { printf "%5.2f cores  %s\n", g[k] / W, k; sum += g[k] } printf "%5.2f cores  total\n", sum / W }' "$a" "$b" | sort -rn
  echo "window ${w}s, load: $(uptime | sed 's/.*load averages*: //')"
}

# The disable above takes effect at the next login and SIP refuses to unload the loaded agent, so the running daemon stays: killed,
# it respawns within 2-12 minutes and starts over; SIGSTOPped, it stays alive, so launchd has nothing to restart and it costs 0 CPU
# until the restart ends it. Its XPC callers (photoanalysisd, Photos) just wait; nothing on the host reads the analysis.
stop_mediaanalysisd() {
  local pids stopped=0 pid
  pids=$("$PS_BIN" -Ao pid=,stat=,comm= | awk '$2 !~ /^T/ && $3 ~ /\/mediaanalysisd$/ { print $1 }')
  for pid in $pids; do
    "$KILL_BIN" -STOP "$pid" 2>/dev/null && stopped=$((stopped + 1))
  done
  echo "mediaanalysisd: stopped $stopped process(es) (resume: kill -CONT <pid>; the next restart ends it)"
}

case "${1:-}" in
  stop-mediaanalysisd) stop_mediaanalysisd ;;
  cpu)cmd_cpu "${2:-300}" ;;
  orphan-sleeps) check_orphan_sleeps ;;
  tailscaled) check_tailscaled ;;
  mediaanalysisd) check_mediaanalysisd ;;
  sshd-sessions) check_sshd_sessions ;;
  fix-mediaanalysisd) fix_mediaanalysisd ;;
  *) echo "usage: host-waste-check.sh orphan-sleeps|tailscaled|mediaanalysisd|sshd-sessions|fix-mediaanalysisd|cpu [SECS]" >&2; exit 64 ;;
esac
