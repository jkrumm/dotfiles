#!/bin/bash
# Hermetic suite for log-rotate.sh: the file list is derived from our plists, nothing else is touched.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
LOGS="$HOME/Library/Logs"
AGENTS="$HOME/Library/LaunchAgents"
mkdir -p "$LOGS" "$AGENTS"
export CHROME_CLONE_ROOT="$TMP/chrome"
# A system-wide lsof takes minutes on a loaded host and this suite runs the script ~17 times: default to a stub that
# reports nothing open (one non-empty line, so the sweep does not fail closed); the holder test uses a stub that holds one clone.
printf '#!/bin/sh\necho p1\n' > "$TMP/lsof-stub"; chmod +x "$TMP/lsof-stub"
export LSOF_BIN="$TMP/lsof-stub" LOG_ROTATE_LOWPRIO=1
mkdir -p "$CHROME_CLONE_ROOT"

fail=0
check() { # $1 = name, rest = a condition; passes when it exits 0
  local name=$1; shift
  if "$@"; then echo "  ok  $name"; else echo "  FAIL $name"; fail=1; fi
}
rotated() { [ -f "$LOGS/$1.1" ] && [ ! -s "$LOGS/$1" ]; }
untouched() { [ ! -f "$LOGS/$1.1" ] && [ -s "$LOGS/$1" ]; }
once() { [ "$(printf '%s\n' "$out" | grep -c "^rotated .*/$1 ")" -eq 1 ]; }
plist() { # $1 = label, $2 = stdout path, $3 = stderr path
  cat > "$AGENTS/$1.plist" <<EOS
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>Label</key><string>$1</string>
<key>StandardOutPath</key><string>$2</string><key>StandardErrorPath</key><string>$3</string></dict></plist>
EOS
}
big() { head -c 2048 /dev/zero > "$1"; }

plist com.jkrumm.alpha "$LOGS/alpha.log" "$LOGS/alpha.err"
plist com.iu.beta "$LOGS/beta.log" "$LOGS/beta.log"
plist com.jkrumm.log-rotate "$LOGS/log-rotate.log" "$LOGS/log-rotate.log"
plist com.jkrumm.devnull /dev/null /dev/null
plist com.vendor.gamma "$LOGS/vendor.log" "$LOGS/vendor.log"
big "$LOGS/alpha.log"; big "$LOGS/alpha.err"; big "$LOGS/beta.log"; big "$LOGS/log-rotate.log"
ln -s "$LOGS/PhotosSearch.aapbz" "$LOGS/linked.log"; plist com.jkrumm.linked "$LOGS/linked.log" "$LOGS/linked.log"
big "$LOGS/vendor.log"; big "$LOGS/PhotosSearch.aapbz"; big "$LOGS/hermes-ops.log"; big "$LOGS/devhost-snapshots.jsonl"

out=$(LOG_ROTATE_MAX_BYTES=1024 bash "$HERE/log-rotate.sh" 2>&1); rc=$?
check "exits 0" test "$rc" -eq 0
check "com.jkrumm log rotated (stdout)" rotated alpha.log
check "com.jkrumm log rotated (stderr)" rotated alpha.err
check "com.iu log rotated" rotated beta.log
check "declared extra rotated" rotated hermes-ops.log
check "the devhost snapshot log is rotated" rotated devhost-snapshots.jsonl
check "foreign label untouched" untouched vendor.log
check "unrelated log untouched" untouched PhotosSearch.aapbz
check "own log untouched" untouched log-rotate.log
check "a symlinked log is not followed" untouched PhotosSearch.aapbz
check "a path named twice rotates once" once beta.log

rm "$AGENTS/com.jkrumm.alpha.plist"; rm -f "$LOGS"/*.1; big "$LOGS/alpha.log"
LOG_ROTATE_MAX_BYTES=1024 bash "$HERE/log-rotate.sh" >/dev/null 2>&1
check "a retired plist's log stops being rotated" untouched alpha.log

# The herdr-core world needs no hand list: every plist's log is derived, so the core starter,
# resume and the Wave 4 reap/events recorders are rotated the moment their plists land.
for l in herdr-core hc-resume hc-reap hc-events; do
  plist "com.jkrumm.$l" "$LOGS/$l.log" "$LOGS/$l.log"; big "$LOGS/$l.log"
done
rm -f "$LOGS"/*.1
LOG_ROTATE_MAX_BYTES=1024 bash "$HERE/log-rotate.sh" >/dev/null 2>&1
for l in herdr-core hc-resume hc-reap hc-events; do
  check "herdr-core world: $l.log rotated" rotated "$l.log"
done

CR="$CHROME_CLONE_ROOT"
mkdir "$CR/code_sign_clone.old" "$CR/code_sign_clone.fresh" "$CR/code_sign_clone.open"
touch -t "$(date -v-2d +%Y%m%d%H%M)" "$CR/code_sign_clone.old" "$CR/code_sign_clone.open"
# lsof stub that reports code_sign_clone.open held by a process (the real system-wide lsof takes minutes on a loaded host)
printf '#!/bin/sh\necho p1\necho "n%s/code_sign_clone.open/Contents"\n' "$(cd "$CR" && pwd -P)" > "$TMP/lsof-holder"; chmod +x "$TMP/lsof-holder"
LSOF_BIN="$TMP/lsof-holder" LOG_ROTATE_MAX_BYTES=1024 bash "$HERE/log-rotate.sh" >/dev/null 2>&1
check "old chrome clone removed" test ! -e "$CR/code_sign_clone.old"
check "fresh chrome clone kept" test -d "$CR/code_sign_clone.fresh"
check "open chrome clone kept" test -d "$CR/code_sign_clone.open"

rm -rf "$CR"/code_sign_clone.*
for n in 1 2 3 4 5; do mkdir "$CR/code_sign_clone.stale$n"; touch -t "$(date -v-2d +%Y%m%d%H%M)" "$CR/code_sign_clone.stale$n"; done
out4=$(CHROME_CLONE_MAX=2 LOG_ROTATE_MAX_BYTES=1024 bash "$HERE/log-rotate.sh" 2>&1)
check "chrome sweep stops at the removal cap" sh -c '[ "$(ls "$1" | wc -l)" -eq 3 ] && printf "%s" "$2" | grep -q "cap reached"' _ "$CR" "$out4"
LOG_ROTATE_MAX_BYTES=1024 bash "$HERE/log-rotate.sh" >/dev/null 2>&1
LOG_ROTATE_MAX_BYTES=1024 bash "$HERE/log-rotate.sh" >/dev/null 2>&1
check "chrome sweep drains the rest on later runs" sh -c '[ -z "$(ls "$1")" ]' _ "$CR"

rm -rf "$CR"/code_sign_clone.*
mkdir "$CR/code_sign_clone.3h" "$CR/code_sign_clone.30m"
touch -t "$(date -v-3H +%Y%m%d%H%M)" "$CR/code_sign_clone.3h"
touch -t "$(date -v-30M +%Y%m%d%H%M)" "$CR/code_sign_clone.30m"
LOG_ROTATE_MAX_BYTES=1024 bash "$HERE/log-rotate.sh" >/dev/null 2>&1
check "chrome clone older than 2 h removed" test ! -e "$CR/code_sign_clone.3h"
check "chrome clone younger than 2 h kept" test -d "$CR/code_sign_clone.30m"
rm -rf "$CR"/code_sign_clone.*
for n in $(seq 1 40); do mkdir "$CR/code_sign_clone.b$n"; touch -t "$(date -v-2d +%Y%m%d%H%M)" "$CR/code_sign_clone.b$n"; done
LOG_ROTATE_MAX_BYTES=1024 bash "$HERE/log-rotate.sh" >/dev/null 2>&1
check "chrome sweep clears a multi-batch backlog in one run" sh -c '[ -z "$(ls "$1")" ]' _ "$CR"

# rc=124 under load (issue 870): the budget counts from script start, so a spent budget removes nothing and says so.
rm -rf "$CR"/code_sign_clone.*
for n in 1 2 3; do mkdir "$CR/code_sign_clone.late$n"; touch -t "$(date -v-2d +%Y%m%d%H%M)" "$CR/code_sign_clone.late$n"; done
out5=$(CHROME_CLONE_BUDGET_S=0 LOG_ROTATE_MAX_BYTES=1024 bash "$HERE/log-rotate.sh" 2>&1); rc5=$?
check "a spent budget removes nothing, exits 0 and defers the rest" sh -c '[ "$1" -eq 0 ] && [ "$(ls "$2" | wc -l)" -eq 3 ] && printf "%s" "$3" | grep -q "cap reached"' _ "$rc5" "$CR" "$out5"
# three runs in a row finish green (the acceptance: rc=124 no more)
for i in 1 2 3; do
  LOG_ROTATE_MAX_BYTES=1024 bash "$HERE/log-rotate.sh" >/dev/null 2>&1; rcn=$?
  check "consecutive run $i exits 0" test "$rcn" -eq 0
done
check "the backlog drained across those runs" sh -c '[ -z "$(ls "$1")" ]' _ "$CR"
check "the script runs at background priority (re-exec guard set)" grep -q 'exec /usr/sbin/taskpolicy -b' "$HERE/log-rotate.sh"

out3=$(CHROME_CLONE_ROOT="$TMP/absent" bash "$HERE/log-rotate.sh" 2>&1); rc3=$?
check "missing chrome root is a no-op" sh -c '[ "$1" -eq 0 ] && [ ! -e "$2" ] && printf "%s" "$3" | grep -q "nothing to sweep"' _ "$rc3" "$TMP/absent" "$out3"

exit "$fail"
