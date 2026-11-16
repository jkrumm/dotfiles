#!/bin/bash
# Hermetic suite for host-waste-check.sh: ps, launchctl, tailscale and sleep are stubs; nothing on the host is read or changed.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail=0
check() { local name=$1; shift; if "$@"; then echo "  ok  $name"; else echo "  FAIL $name"; fail=1; fi; }
has() { printf '%s' "$out" | grep -q -- "$1"; }
rc_is() { [ "$rc" -eq "$1" ]; }

printf '#!/bin/sh\nexit 0\n' > "$TMP/sleep"

# ps answers by its -o list; each scenario is a directory of canned outputs, chosen by STUB_SCENARIO.
cat > "$TMP/ps" <<STUB
#!/bin/sh
d="$TMP/\${STUB_SCENARIO:-calm}"
case "\$2" in
  ppid=,args=) cat "\$d/ppid-args.txt" ;;
  cputime=,comm=)
    n=\$(cat "$TMP/ps.n" 2>/dev/null || echo 0); echo \$((n + 1)) > "$TMP/ps.n"
    if [ "\$n" -eq 0 ]; then cat "\$d/cpu-1.txt"; else cat "\$d/cpu-2.txt"; fi ;;
  stat=,comm=) cat "\$d/comm.txt" ;;
  pid=,stat=,comm=) cat "\$d/pid-stat-comm.txt" ;;
  pid=,cputime=,comm=)
    n=\$(cat "$TMP/cpu.n" 2>/dev/null || echo 0); echo \$((n + 1)) > "$TMP/cpu.n"
    if [ "\$n" -eq 0 ]; then cat "\$d/pcpu-1.txt"; else cat "\$d/pcpu-2.txt"; fi ;;
  args=) cat "\$d/args.txt" ;;
esac
STUB
# tailscale metrics print: two snapshots, 100 MiB apart in the busy scenario
cat > "$TMP/tailscale" <<STUB
#!/bin/sh
n=\$(cat "$TMP/ts.n" 2>/dev/null || echo 0); echo \$((n + 1)) > "$TMP/ts.n"
d="$TMP/\${STUB_SCENARIO:-calm}"
if [ "\$n" -eq 0 ]; then cat "\$d/metrics-1.txt"; else cat "\$d/metrics-2.txt"; fi
STUB
# launchctl: print-disabled reads the scenario's file; disable records its argument
cat > "$TMP/launchctl" <<STUB
#!/bin/sh
case "\$1" in
  print-disabled) cat "$TMP/\${STUB_SCENARIO:-calm}/disabled.txt" ;;
  disable) echo "\$2" > "$TMP/disabled.arg"; exit "\${STUB_DISABLE_RC:-0}" ;;
esac
STUB
# kill records its arguments; top answers kernel_task's TIME, 1:00:00 then 1:00:40 (40 s apart)
printf '#!/bin/sh\necho "$@" >> "%s/kill.log"\n' "$TMP" > "$TMP/kill"
cat > "$TMP/top" <<STUB
#!/bin/sh
n=\$(cat "$TMP/top.n" 2>/dev/null || echo 0); echo \$((n + 1)) > "$TMP/top.n"
echo "PID    TIME"
if [ "\$n" -eq 0 ]; then echo "0      1:00:00"; else echo "0      1:00:40"; fi
STUB
rm -f "$TMP/top.n"
chmod +x "$TMP"/sleep "$TMP"/ps "$TMP"/tailscale "$TMP"/launchctl "$TMP"/kill "$TMP"/top

mkdir "$TMP/calm" "$TMP/busy"
# calm: no orphans, tailscaled 1 CPU s in the 10 s window (10 %), 1 MiB moved, agent disabled and stopped, 4 sshd processes
printf '    1 /sbin/launchd\n  500 sleep 5\n    1 /usr/bin/other 3\n' > "$TMP/calm/ppid-args.txt"
printf '  5:00.00 /opt/homebrew/opt/tailscale/bin/tailscaled\n' > "$TMP/calm/cpu-1.txt"
printf '  5:01.00 /opt/homebrew/opt/tailscale/bin/tailscaled\n' > "$TMP/calm/cpu-2.txt"
printf 'tailscaled_inbound_bytes_total{path="direct_ipv4"} 1048576\ntailscaled_outbound_bytes_total{path="derp"} 0\n' > "$TMP/calm/metrics-1.txt"
printf 'tailscaled_inbound_bytes_total{path="direct_ipv4"} 2097152\ntailscaled_outbound_bytes_total{path="derp"} 0\n' > "$TMP/calm/metrics-2.txt"
printf '\t"com.apple.mediaanalysisd" => disabled\n\t"com.apple.other" => enabled\n' > "$TMP/calm/disabled.txt"
printf 'S     /usr/libexec/other\nS     /System/Library/PrivateFrameworks/MediaAnalysisAccess.framework/x/mediaanalysisd-access\n' > "$TMP/calm/comm.txt"
printf 'sshd-session: jk [postauth]\nsshd-session: jk@notty\nsshd-session: jk [postauth]\nsshd-session: jk\n' > "$TMP/calm/args.txt"
# busy: 12 orphaned sleeps (41-style), tailscaled 6 CPU s in 10 s (60 %), 100 MiB moved, agent enabled and running, 30 sshd processes
{ for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do echo '    1 /bin/sleep 180'; done; echo '    1 sleep 30'; } > "$TMP/busy/ppid-args.txt"
printf '  1-00:00:00.00 /opt/homebrew/opt/tailscale/bin/tailscaled\n' > "$TMP/busy/cpu-1.txt"
printf '  1-00:00:06.00 /opt/homebrew/opt/tailscale/bin/tailscaled\n' > "$TMP/busy/cpu-2.txt"
printf 'tailscaled_inbound_bytes_total{path="direct_ipv4"} 0\ntailscaled_outbound_bytes_total{path="direct_ipv6"} 0\n' > "$TMP/busy/metrics-1.txt"
printf 'tailscaled_inbound_bytes_total{path="direct_ipv4"} 52428800\ntailscaled_outbound_bytes_total{path="direct_ipv6"} 52428800\n' > "$TMP/busy/metrics-2.txt"
printf '\t"com.apple.other" => enabled\n' > "$TMP/busy/disabled.txt"
printf 'Ss    /System/Library/PrivateFrameworks/MediaAnalysis.framework/Versions/A/mediaanalysisd\n' > "$TMP/busy/comm.txt"
{ for _ in $(seq 1 15); do echo 'sshd-session: jk [postauth]'; echo 'sshd-session: jk@notty'; done; } > "$TMP/busy/args.txt"

run() { local scenario=$1; shift; rm -f "$TMP/ps.n" "$TMP/ts.n" "$TMP/disabled.arg"
  out=$(env STUB_SCENARIO="$scenario" PS_BIN="$TMP/ps" LAUNCHCTL_BIN="$TMP/launchctl" TAILSCALE_BIN="$TMP/tailscale" \
    HOST_WASTE_SLEEP_BIN="$TMP/sleep" TAILSCALED_WINDOW=10 bash "$HERE/host-waste-check.sh" "$@" 2>&1); rc=$?; }

echo "orphan-sleeps"
run calm orphan-sleeps
check "a sleep under a shell does not count: exit 0" rc_is 0
check "...says 0" has "^0 orphaned"
run busy orphan-sleeps
check "13 orphans over the limit of 10: WARN (2)" rc_is 2
check "...names the 180 s ones" has "sleep 180 x12"

echo "tailscaled"
run calm tailscaled
check "10 % over the window: exit 0" rc_is 0
check "...reports share and rate" has "at 10% of one core over 10s.*0.1 MiB/s"
run busy tailscaled
check "60 % over the window: WARN (2)" rc_is 2
check "...names the transfer volume" has "10.0 MiB/s moved"
check "...points at the doc" has "docs/host-waste.md"

echo "mediaanalysisd"
run calm mediaanalysisd
check "disabled and not running: exit 0" rc_is 0
run busy mediaanalysisd
check "enabled: WARN (2)" rc_is 2
check "...names the fix" has "make photos-analysis-off"
run calm mediaanalysisd
printf 'Ss    /System/Library/PrivateFrameworks/MediaAnalysis.framework/Versions/A/mediaanalysisd\n' > "$TMP/calm/comm.txt"
run calm mediaanalysisd
check "disabled but still running: WARN (2)" rc_is 2
check "...says it is still running" has "still running"

printf 'T     /System/Library/PrivateFrameworks/MediaAnalysis.framework/Versions/A/mediaanalysisd\n' > "$TMP/calm/comm.txt"
run calm mediaanalysisd
check "disabled and SIGSTOPped (state T): exit 0" rc_is 0

echo "stop-mediaanalysisd"
printf ' 4001 Ss /System/Library/PrivateFrameworks/MediaAnalysis.framework/Versions/A/mediaanalysisd\n 4002 S /x/mediaanalysisd-access\n 4003 T /System/Library/PrivateFrameworks/MediaAnalysis.framework/Versions/A/mediaanalysisd\n 4004 R /usr/bin/other\n' > "$TMP/calm/pid-stat-comm.txt"
rm -f "$TMP/kill.log"
out=$(env STUB_SCENARIO=calm PS_BIN="$TMP/ps" KILL_BIN="$TMP/kill" bash "$HERE/host-waste-check.sh" stop-mediaanalysisd 2>&1); rc=$?
check "stops the running daemon: exit 0" rc_is 0
check "...with SIGSTOP on pid 4001 only (not the -access helper, not the already stopped one)" test "$(cat "$TMP/kill.log")" = "-STOP 4001"
check "...says one process" has "stopped 1 process"
rm -f "$TMP/kill.log"
printf ' 4003 T /System/Library/PrivateFrameworks/MediaAnalysis.framework/Versions/A/mediaanalysisd\n' > "$TMP/calm/pid-stat-comm.txt"
out=$(env STUB_SCENARIO=calm PS_BIN="$TMP/ps" KILL_BIN="$TMP/kill" bash "$HERE/host-waste-check.sh" stop-mediaanalysisd 2>&1); rc=$?
check "an already stopped daemon is left alone" test ! -e "$TMP/kill.log"

echo "cpu"
printf ' 10 1:00.00 /usr/sbin/mediaanalysisd\n 11 0:10.00 /x/tailscaled\n 12 5:00.00 /usr/bin/other\n' > "$TMP/calm/pcpu-1.txt"
printf ' 10 1:30.00 /usr/sbin/mediaanalysisd\n 11 0:25.00 /x/tailscaled\n 12 6:00.00 /usr/bin/other\n 13 0:15.00 /usr/sbin/mediaanalysisd\n' > "$TMP/calm/pcpu-2.txt"
rm -f "$TMP/cpu.n"
out=$(env STUB_SCENARIO=calm PS_BIN="$TMP/ps" TOP_BIN="$TMP/top" HOST_WASTE_SLEEP_BIN="$TMP/sleep" bash "$HERE/host-waste-check.sh" cpu 30 2>&1); rc=$?
check "exit 0" rc_is 0
check "a respawned pid counts in full: mediaanalysisd (30 + 15) s / 30 s = 1.50 cores" has "1.50 cores  mediaanalysisd"
check "tailscaled 15 s / 30 s = 0.50 cores" has "0.50 cores  tailscaled"
check "kernel_task from top: 40 s / 30 s = 1.33 cores" has "1.33 cores  kernel_task"
check "an unlisted process is not counted" test -z "$(printf '%s' "$out" | grep other)"
check "total is the sum: 3.33 cores" has "3.33 cores  total"

echo "sshd-sessions"
run calm sshd-sessions
check "2 logins (4 processes, 2 [postauth]): exit 0" rc_is 0
run busy sshd-sessions
check "15 logins (30 processes, 15 [postauth]) under the limit of 20: exit 0" rc_is 0
out=$(env PS_BIN="$TMP/ps" STUB_SCENARIO=busy SSHD_SESSIONS_MAX=10 bash "$HERE/host-waste-check.sh" sshd-sessions 2>&1); rc=$?
check "a limit of 10 turns the same 15 into a WARN (2)" rc_is 2

echo "fix-mediaanalysisd"
run calm fix-mediaanalysisd
check "disables the user-domain agent" grep -q "gui/[0-9]*/com.apple.mediaanalysisd" "$TMP/disabled.arg"
check "...exit 0 and names the undo" has "undo: launchctl enable"
out=$(env STUB_DISABLE_RC=1 LAUNCHCTL_BIN="$TMP/launchctl" bash "$HERE/host-waste-check.sh" fix-mediaanalysisd 2>&1); rc=$?
check "a refused disable is a failure (1)" rc_is 1

echo "usage"
run calm bogus
check "an unknown verb is a usage error" rc_is 64

exit $fail
