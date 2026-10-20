#!/bin/bash
# Hermetic suite for disk-sweep.sh: only the steps that touch nothing outside the fixtures.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME"
export DISK_SWEEP_TMPDIR="$TMP/tmproot"
export OCR_SESSIONS_ROOT="$TMP/ocr"
T="$DISK_SWEEP_TMPDIR"
O="$OCR_SESSIONS_ROOT"
mkdir -p "$T" "$O"

fail=0
check() { # $1 = name, rest = a condition; passes when it exits 0
  local name=$1; shift
  if "$@"; then echo "  ok  $name"; else echo "  FAIL $name"; fail=1; fi
}
old() { touch -t "$(date -v-"$1"d +%Y%m%d%H%M)" "${@:2}"; }

# tmpdir: old entries go, fresh stay, an old one with an open file stays, Apple-owned stay.
mkdir "$T/old-dir" "$T/fresh-dir" "$T/held" "$T/com.apple.keep"
echo x > "$T/old-dir/f"; echo x > "$T/old-file"; echo x > "$T/fresh-file"
echo x > "$T/held/f"
old 5 "$T/old-dir" "$T/old-file" "$T/held" "$T/com.apple.keep"
sleep 60 > "$T/held/f" &
holder=$!

# ocr-sessions: old files go, fresh stay, dirs left empty go (nested too), the root stays.
mkdir -p "$O/a/b" "$O/fresh" "$O/emptyfromstart"
echo x > "$O/a/b/old.jsonl"; echo x > "$O/fresh/new.jsonl"
old 20 "$O/a/b/old.jsonl"

out=$(bash "$HERE/disk-sweep.sh" tmpdir ocr-sessions 2>&1); rc=$?
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
printf '%s\n' "$out" | sed 's/^/    | /'

check "exits 0" test "$rc" -eq 0
check "old tmp dir removed" test ! -e "$T/old-dir"
check "old tmp file removed" test ! -e "$T/old-file"
check "fresh tmp dir kept" test -d "$T/fresh-dir"
check "fresh tmp file kept" test -f "$T/fresh-file"
check "old tmp dir with an open file kept" test -f "$T/held/f"
check "Apple-owned tmp entry kept" test -d "$T/com.apple.keep"
check "old ocr session removed" test ! -e "$O/a/b/old.jsonl"
check "emptied ocr dirs removed" test ! -e "$O/a"
check "empty ocr dir removed" test ! -e "$O/emptyfromstart"
check "fresh ocr session kept" test -f "$O/fresh/new.jsonl"
check "ocr root kept" test -d "$O"
check "every step prints a size line" sh -c 'printf "%s\n" "$1" | grep -c "free space +" | grep -qx 3' _ "$out"

out2=$(OCR_SESSIONS_ROOT="$TMP/absent" bash "$HERE/disk-sweep.sh" ocr-sessions 2>&1); rc2=$?
check "missing ocr root is a skip, exit 0" sh -c '[ "$1" -eq 0 ] && printf "%s" "$2" | grep -q "ocr-sessions: skipped"' _ "$rc2" "$out2"

bash "$HERE/disk-sweep.sh" nonsense >/dev/null 2>&1; rc3=$?
check "unknown step exits 2" test "$rc3" -eq 2

exit "$fail"
