#!/usr/bin/env bash
# planned-restart.test — hermetic suite for scripts/planned-restart.sh.
#
# ssh is a stub that records every remote command and answers the factory/jq/recovery-check calls from files; the
# applier (mini-macos-update.sh) is a stub that records that it ran. Nothing touches a host.
# Asserted: DRY_RUN prints every step and runs nothing; the order drain -> notes -> locks -> restart -> recover -> run;
# a refused drain stops before anything else; a failure before the restart puts the queue back; a failure after the
# restart leaves it drained; "0 waiting" is awaited, not assumed; nothing pending exits 0 without draining.
# REASON=maintenance: the plain-reboot mode runs the same steps with no update pending and the reboot applier in step 4.
# mini-reboot.sh (that applier) runs against the same stubs: snapshot, then the op-fed shutdown, then down, up, boot time moved.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/planned-restart.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/planned-restart-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

fails=0
ok()  { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fails=$((fails + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — got '$2', want '$3'"; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1 — missing '$3' in: $2"; fi; }
assert_not_contains() { if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1 — unexpected '$3' in: $2"; fi; }

ST="$TMP/st"; BIN="$TMP/bin"
export ST
mkdir -p "$BIN"

# ssh <opts> <host> '<cmd>': the command is the last argument. Recorded, then answered.
cat > "$BIN/ssh" <<'EOF'
#!/bin/sh
for last; do :; done
printf '%s\n' "$last" >> "$ST/ssh.log"
case "$last" in
  true)
    if [ -f "$ST/shutdown_sent" ] && [ ! -f "$ST/nodown" ] && [ ! -f "$ST/down_seen" ]; then touch "$ST/down_seen"; exit 255; fi ;;
  *"kern.boottime"*)
    if [ -f "$ST/shutdown_sent" ] && [ ! -f "$ST/same_boot" ]; then echo "{ sec = 200 }"; else echo "{ sec = 100 }"; fi ;;
  *"nohup sudo -S shutdown -r +0"*) cat > "$ST/stdin"; touch "$ST/shutdown_sent" ;;
  *"python3 -"*) cat > /dev/null; echo 2 ;;
  *"RecommendedUpdates"*)
    [ -f "$ST/nopending" ] || printf '    "Display Name" = "macOS Tahoe 26.7.3";\n' ;;
  *"queue set drain"*) [ -f "$ST/drain_fail" ] && exit 1 ;;
  *"queue set run"*) [ -f "$ST/run_fail" ] && exit 1 ;;
  *"read sessions"*) printf 'lead-1-1\nlead-2-1\n' ;;
  *"capacity get"*) [ -f "$ST/nocapacity" ] && exit 1; printf 'alpha\nbeta\n' ;;
  *"merge-lock --project beta"*) [ -f "$ST/lock_fail" ] && exit 1 ;;
  *"recovery-check"*)
    n=$(cat "$ST/rc_calls" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$ST/rc_calls"
    if [ "$n" -le "$(cat "$ST/rc_waiting_calls" 2>/dev/null || echo 0)" ]; then
      echo '{"resumable":9,"running":8,"waiting":1,"skipped":0}'
    else
      echo '{"resumable":9,"running":9,"waiting":0,"skipped":0}'
    fi ;;
esac
exit 0
EOF
cat > "$BIN/updater" <<'EOF'
#!/bin/bash
echo "updater YES=${YES:-}" >> "$ST/ssh.log"
[ -f "$ST/updater_fail" ] && exit 1
exit 0
EOF
cat > "$BIN/rebooter" <<'EOF'
#!/bin/bash
echo "rebooter YES=${YES:-}" >> "$ST/ssh.log"
[ -f "$ST/updater_fail" ] && exit 1
exit 0
EOF
cat > "$BIN/op" <<'EOF'
#!/bin/sh
[ -f "$ST/op_locked" ] && exit 1
[ "$1" = read ] && echo "the-password"
exit 0
EOF
chmod +x "$BIN"/*

export SSH_BIN="$BIN/ssh" MACOS_UPDATE_BIN="$BIN/updater" BACKEND_FILE="$TMP/backend"
export OP_BIN="$BIN/op" MINI_REBOOT_BIN="$BIN/rebooter" REBOOT_POLL=0 REBOOT_DOWN_WAIT=1 REBOOT_UP_WAIT=1
export PLANNED_RESTART_GRACE=0 PLANNED_RESTART_POLL=0 PLANNED_RESTART_RECOVER_WAIT=2 PLANNED_RESTART_LOCK_WAIT=10
export YES=1
unset DRY_RUN

reset() { rm -rf "$ST"; mkdir -p "$ST"; echo op > "$BACKEND_FILE"; : > "$ST/ssh.log"; }
OUT=""; RC=0
run() { RC=0; OUT=$(/bin/bash "$SRC" 2>&1 </dev/null) || RC=$?; }
log() { cat "$ST/ssh.log"; }
line_of() { grep -n -- "$1" "$ST/ssh.log" | head -1 | cut -d: -f1; }

echo "DRY_RUN"
reset; DRY_RUN=1 run
assert_eq "exit 0" "$RC" 0
for step in "0 preflight" "1 drain" "2 tell" "3 quiesce" "4 restart" "5 recover" "6 resume"; do
  assert_contains "prints step $step" "$OUT" "$step"
done
assert_contains "names the drain command" "$OUT" "factory queue set drain"
assert_contains "names the lock waits" "$OUT" "factory merge-lock --project <p> -- true"
assert_contains "names the recovery read" "$OUT" "make recovery-check ARGS=--json"
assert_contains "names the queue release" "$OUT" "factory queue set run"
assert_eq "touches nothing: no ssh call" "$(wc -l < "$ST/ssh.log" | tr -d ' ')" 0
reset; DRY_RUN=1 run
assert_eq "DRY_RUN runs even where the backend is not op" "$RC" 0
echo cache > "$BACKEND_FILE"; DRY_RUN=1 run
assert_eq "DRY_RUN does not need the MacBook" "$RC" 0

echo "full run"
reset; run
assert_eq "exit 0" "$RC" 0
assert_contains "done line" "$OUT" "planned restart done"
assert_contains "recovery line printed" "$OUT" "9 resumable, 9 running claude, 0 waiting, 0 skipped"
assert_contains "both non-idle leads get the note" "$(log)" "factory session note lead-1-1"
assert_contains "second lead too" "$(log)" "factory session note lead-2-1"
assert_contains "every project's merge lock" "$(log)" "factory merge-lock --project alpha -- true"
assert_contains "every project's deploy lock" "$(log)" "factory deploy-lock --project beta -- true"
assert_contains "the applier runs with YES=1" "$(log)" "updater YES=1"
d=$(line_of "queue set drain"); n=$(line_of "session note"); l=$(line_of "merge-lock --project alpha"); u=$(line_of "updater"); r=$(line_of "recovery-check"); q=$(line_of "queue set run")
if [ -n "$d" ] && [ "$d" -lt "$n" ] && [ "$n" -lt "$l" ] && [ "$l" -lt "$u" ] && [ "$u" -lt "$r" ] && [ "$r" -lt "$q" ]; then
  ok "order: drain, notes, locks, restart, recover, run"; else bad "order wrong: $d $n $l $u $r $q"; fi

echo "REASON=maintenance"
reset; DRY_RUN=1 REASON=maintenance run
assert_eq "exit 0" "$RC" 0
for step in "0 preflight" "1 drain" "2 tell" "3 quiesce" "4 snapshot" "4 reboot" "5 recover" "6 resume"; do
  assert_contains "prints step $step" "$OUT" "$step"
done
assert_contains "names the reboot applier" "$OUT" "rebooter"
assert_not_contains "no update is required" "$OUT" "a macOS update pending"
assert_eq "touches nothing: no ssh call" "$(wc -l < "$ST/ssh.log" | tr -d ' ')" 0
reset; touch "$ST/nopending"; REASON=maintenance run
assert_eq "no update pending, maintenance: exit 0" "$RC" 0
assert_contains "done line" "$OUT" "planned restart done"
assert_contains "the reboot applier runs with YES=1" "$(log)" "rebooter YES=1"
assert_not_contains "the macOS applier does not run" "$(log)" "updater"
assert_not_contains "no RecommendedUpdates read" "$(log)" "RecommendedUpdates"
assert_contains "the leads are told it is a maintenance reboot" "$(log)" 'maintenance\ reboot'
d=$(line_of "queue set drain"); n=$(line_of "session note"); l=$(line_of "merge-lock --project alpha"); u=$(line_of "rebooter"); r=$(line_of "recovery-check"); q=$(line_of "queue set run")
if [ -n "$d" ] && [ "$d" -lt "$n" ] && [ "$n" -lt "$l" ] && [ "$l" -lt "$u" ] && [ "$u" -lt "$r" ] && [ "$r" -lt "$q" ]; then
  ok "order: drain, notes, locks, reboot, recover, run"; else bad "order wrong: $d $n $l $u $r $q"; fi
reset; touch "$ST/updater_fail"; REASON=maintenance run
assert_eq "reboot applier failed: exit 1" "$RC" 1
assert_not_contains "after the reboot started the queue is not released" "$(log)" "queue set run"
assert_contains "and says it stays drained" "$OUT" "stays DRAINED"
reset; touch "$ST/lock_fail"; REASON=maintenance run
assert_eq "a lock that does not free: exit 1" "$RC" 1
assert_not_contains "no reboot with a window running" "$(log)" "rebooter"
assert_contains "failure before the reboot puts the queue back" "$(log)" "queue set run"
reset; REASON=bogus run
assert_eq "unknown REASON: exit 1" "$RC" 1
assert_contains "names the valid mode" "$OUT" "REASON=maintenance"
assert_eq "unknown REASON: no ssh at all" "$(wc -l < "$ST/ssh.log" | tr -d ' ')" 0

echo "mini-reboot.sh"
REBOOT_SRC="$HERE/mini-reboot.sh"
run_reboot() { RC=0; OUT=$(/bin/bash "$REBOOT_SRC" 2>&1 </dev/null) || RC=$?; }
reset; run_reboot
assert_eq "exit 0" "$RC" 0
assert_contains "says it rebooted" "$OUT" "rebooted"
assert_contains "the resume snapshot runs" "$(log)" "resume-pre-reboot"
assert_contains "the shutdown is requested" "$(log)" "shutdown -r +0"
assert_eq "the password reaches the host over stdin" "$(cat "$ST/stdin")" "the-password"
assert_not_contains "the password is never an argument" "$(log)" "the-password"
s=$(line_of "resume-pre-reboot"); d=$(line_of "shutdown -r +0")
if [ -n "$s" ] && [ -n "$d" ] && [ "$s" -lt "$d" ]; then ok "order: snapshot, then shutdown"; else bad "order wrong: $s $d"; fi
reset; touch "$ST/nodown" "$ST/same_boot"; REBOOT_DOWN_WAIT=1 REBOOT_POLL=1 run_reboot
assert_eq "a host that never goes down: exit 1" "$RC" 1
assert_contains "says so" "$OUT" "never went down"
reset; touch "$ST/same_boot"; run_reboot
assert_eq "boot time unchanged: exit 1" "$RC" 1
assert_contains "says it never rebooted" "$OUT" "it never rebooted"
reset; touch "$ST/op_locked"; run_reboot
assert_eq "1Password locked: exit 1" "$RC" 1
assert_not_contains "locked: no shutdown" "$(log)" "shutdown -r +0"
reset; echo cache > "$BACKEND_FILE"; run_reboot
assert_eq "not the MacBook: exit 1" "$RC" 1
assert_eq "not the MacBook: no ssh at all" "$(wc -l < "$ST/ssh.log" | tr -d ' ')" 0
reset; unset YES; run_reboot
assert_eq "no TTY and no YES: refused" "$RC" 1
assert_not_contains "refused before the shutdown" "$(log)" "shutdown -r +0"
export YES=1

echo "recovery is awaited"
reset; echo 2 > "$ST/rc_waiting_calls"; PLANNED_RESTART_RECOVER_WAIT=60 run
assert_eq "waiting>0 twice, then 0: exit 0" "$RC" 0
assert_eq "recovery-check polled 3 times" "$(cat "$ST/rc_calls")" 3
reset; echo 99 > "$ST/rc_waiting_calls"; PLANNED_RESTART_POLL=1 PLANNED_RESTART_RECOVER_WAIT=1 run
assert_eq "waiting never reaches 0: exit 1" "$RC" 1
assert_contains "says why" "$OUT" "still does not read 0 waiting"
assert_not_contains "the queue is NOT set back to run" "$(log)" "queue set run"
assert_contains "and the output says it stays drained" "$OUT" "stays DRAINED"

echo "refusals and failures"
reset; touch "$ST/nopending"; run
assert_eq "nothing pending: exit 0" "$RC" 0
assert_contains "nothing pending says so" "$OUT" "no macOS update pending"
assert_not_contains "nothing pending never drains" "$(log)" "queue set drain"
reset; touch "$ST/drain_fail"; run
assert_eq "drain refused: exit 1" "$RC" 1
assert_contains "drain refusal named" "$OUT" "the factory refused"
assert_not_contains "no note after a refused drain" "$(log)" "session note"
assert_not_contains "no restart after a refused drain" "$(log)" "updater"
assert_not_contains "nothing was drained, so nothing is released" "$(log)" "queue set run"
reset; touch "$ST/lock_fail"; run
assert_eq "a lock that does not free: exit 1" "$RC" 1
assert_contains "names the project" "$OUT" "merge-lock of beta"
assert_not_contains "no restart with a window running" "$(log)" "updater"
assert_contains "failure before the restart puts the queue back" "$(log)" "queue set run"
reset; touch "$ST/nocapacity"; run
assert_eq "no project list: exit 1, no guess" "$RC" 1
assert_not_contains "no restart without the project list" "$(log)" "updater"
reset; touch "$ST/updater_fail"; run
assert_eq "applier failed: exit 1" "$RC" 1
assert_not_contains "after the restart started the queue is not released" "$(log)" "queue set run"
assert_contains "and says it stays drained" "$OUT" "stays DRAINED"
reset; echo cache > "$BACKEND_FILE"; run
assert_eq "not the MacBook: exit 1" "$RC" 1
assert_eq "not the MacBook: no ssh at all" "$(wc -l < "$ST/ssh.log" | tr -d ' ')" 0
reset; unset YES; run
assert_eq "no TTY and no YES: refused" "$RC" 1
assert_contains "says so" "$OUT" "re-run with YES=1"
assert_not_contains "refused before draining" "$(log)" "queue set drain"
export YES=1

echo
if [ "$fails" -eq 0 ]; then echo "planned-restart: all passed"; else echo "planned-restart: $fails failed"; exit 1; fi
