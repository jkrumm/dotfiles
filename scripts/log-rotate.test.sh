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
big "$LOGS/vendor.log"; big "$LOGS/PhotosSearch.aapbz"; big "$LOGS/hermes-ops.log"

out=$(LOG_ROTATE_MAX_BYTES=1024 bash "$HERE/log-rotate.sh" 2>&1); rc=$?
check "exits 0" test "$rc" -eq 0
check "com.jkrumm log rotated (stdout)" rotated alpha.log
check "com.jkrumm log rotated (stderr)" rotated alpha.err
check "com.iu log rotated" rotated beta.log
check "declared extra rotated" rotated hermes-ops.log
check "foreign label untouched" untouched vendor.log
check "unrelated log untouched" untouched PhotosSearch.aapbz
check "own log untouched" untouched log-rotate.log
check "a symlinked log is not followed" untouched PhotosSearch.aapbz
check "a path named twice rotates once" once beta.log

rm "$AGENTS/com.jkrumm.alpha.plist"; rm -f "$LOGS"/*.1; big "$LOGS/alpha.log"
LOG_ROTATE_MAX_BYTES=1024 bash "$HERE/log-rotate.sh" >/dev/null 2>&1
check "a retired plist's log stops being rotated" untouched alpha.log

CR="$CHROME_CLONE_ROOT"
mkdir "$CR/code_sign_clone.old" "$CR/code_sign_clone.fresh" "$CR/code_sign_clone.open"
touch -t "$(date -v-2d +%Y%m%d%H%M)" "$CR/code_sign_clone.old" "$CR/code_sign_clone.open"
(cd "$CR/code_sign_clone.open" && exec sleep 60) &
holder=$!
LOG_ROTATE_MAX_BYTES=1024 bash "$HERE/log-rotate.sh" >/dev/null 2>&1
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
check "old chrome clone removed" test ! -e "$CR/code_sign_clone.old"
check "fresh chrome clone kept" test -d "$CR/code_sign_clone.fresh"
check "open chrome clone kept" test -d "$CR/code_sign_clone.open"

out3=$(CHROME_CLONE_ROOT="$TMP/absent" bash "$HERE/log-rotate.sh" 2>&1); rc3=$?
check "missing chrome root is a no-op" sh -c '[ "$1" -eq 0 ] && [ ! -e "$2" ] && printf "%s" "$3" | grep -q "nothing to sweep"' _ "$rc3" "$TMP/absent" "$out3"

exit "$fail"
