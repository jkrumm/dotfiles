#!/bin/bash
# Hermetic suite for fseventsd-watch.sh: top/ps/sudo/killall are stubs, no sleeping, nothing is restarted.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail=0
check() { local name=$1; shift; if "$@"; then echo "  ok  $name"; else echo "  FAIL $name"; fail=1; fi; }
has() { printf '%s' "$out" | grep -q -- "$1"; }
lacks() { ! printf '%s' "$out" | grep -q -- "$1"; }

printf '#!/bin/sh\n[ "${STUB_NO_PROC:-0}" = 1 ] && exit 1\necho 551\n' > "$TMP/pgrep"
# top: `-stats mem` answers STUB_MEM; `-stats cpu` is STUB_CPU, a space-separated sequence, one value per call (the last repeats)
cat > "$TMP/top" <<STUB
#!/bin/sh
case "\$*" in
  *cpu*)
    n=\$(cat "$TMP/ps.n" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "$TMP/ps.n"
    set -- \${STUB_CPU:-1}
    i=1; v=\$1; for x in "\$@"; do [ "\$i" -le "\$n" ] && v=\$x; i=\$((i + 1)); done
    echo "%CPU"; echo "\$v.0" ;;
  *) echo MEM; echo "\${STUB_MEM:-4544K}" ;;
esac
STUB
# sudo: -l succeeds only when STUB_RULE=1; the real call is recorded
cat > "$TMP/sudo" <<STUB
#!/bin/sh
if [ "\$1" = "-n" ] && [ "\$2" = "-l" ]; then [ "\${STUB_RULE:-0}" = 1 ]; exit \$?; fi
echo "\$*" >> "$TMP/sudo.calls"
exit \${STUB_KILL_RC:-0}
STUB
printf '#!/bin/sh\nexit 0\n' > "$TMP/sleep"
chmod +x "$TMP"/pgrep "$TMP"/top "$TMP"/sudo "$TMP"/sleep

run() { rm -f "$TMP/ps.n" "$TMP/sudo.calls"; out=$(env PGREP_BIN="$TMP/pgrep" TOP_BIN="$TMP/top" SUDO_BIN="$TMP/sudo" FSEVENTSD_SLEEP_BIN="$TMP/sleep" \
  FSEVENTSD_CPU_WINDOW_S=120 FSEVENTSD_SAMPLE_S=30 "$@" bash "$HERE/fseventsd-watch.sh" ${DRY:+--dry-run} 2>&1); rc=$?; }
killed() { [ -f "$TMP/sudo.calls" ] && grep -q 'killall fseventsd' "$TMP/sudo.calls"; }

echo "healthy"
run STUB_MEM=4544K STUB_CPU=3
check "small and idle: nothing to do, no sudo" sh -c '[ "$1" -eq 0 ]' _ "$rc"
check "...says so" has "nothing to do"
check "...no killall" test ! -f "$TMP/sudo.calls"

echo "memory rule"
run STUB_MEM=1400M STUB_CPU=3 STUB_RULE=1
check "1.4 GB is under the 1.5 GB line" test ! -f "$TMP/sudo.calls"
run STUB_MEM=2200M STUB_CPU=3 STUB_RULE=1
check "2.2 GB restarts it" killed
check "...names the memory reason" has "memory 2200 MB is above 1536 MB"
run STUB_MEM=2G STUB_CPU=3 STUB_RULE=1
check "a G-suffixed reading restarts it too" killed

echo "CPU rule"
run STUB_CPU="260" STUB_RULE=1
check "CPU over the line for the whole window restarts it" killed
check "...names the CPU reason" has "CPU stayed at or above 150%"
run STUB_CPU="260 260 40" STUB_RULE=1
check "a burst that drops inside the window does not" test ! -f "$TMP/sudo.calls"
check "...and logs healthy" has "healthy"
run STUB_CPU="149" STUB_RULE=1
check "just under the line never starts sampling" sh -c '[ "$(cat "$1")" -eq 1 ]' _ "$TMP/ps.n"

echo "the sudoers rule"
run STUB_MEM=2200M STUB_CPU=3 STUB_RULE=0
check "no rule: nothing is killed" test ! -f "$TMP/sudo.calls"
check "no rule: exits 0 and says how to install it" sh -c '[ "$1" -eq 0 ]' _ "$rc"
check "...names the make target" has "make fseventsd-sudoers"
run STUB_MEM=2200M STUB_CPU=3 STUB_RULE=1 STUB_KILL_RC=1
check "a failing killall exits 1" sh -c '[ "$1" -eq 1 ]' _ "$rc"

echo "dry run"
DRY=1 run STUB_MEM=2200M STUB_CPU=3 STUB_RULE=1
check "names what it would do" has "DRY RUN: pid 551 — memory 2200 MB is above 1536 MB — would run: sudo -n /usr/bin/killall fseventsd"
check "never calls sudo to kill" test ! -f "$TMP/sudo.calls"
check "reports the rule as installed" has "sudoers rule is installed"
DRY=1 run STUB_MEM=2200M STUB_CPU=3 STUB_RULE=0
check "reports the rule as missing" has "NOT installed"
DRY=1 run STUB_MEM=4544K STUB_CPU=3
check "healthy dry run: nothing to do" has "nothing to do"

echo "no process"
run STUB_NO_PROC=1
check "no fseventsd: exits 0" sh -c '[ "$1" -eq 0 ]' _ "$rc"

exit "$fail"
