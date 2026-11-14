#!/bin/bash
# Hermetic suite for spotlight-check.sh: mdutil, ps and sleep are stubs; nothing on the host is read or changed.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail=0
check() { local name=$1; shift; if "$@"; then echo "  ok  $name"; else echo "  FAIL $name"; fail=1; fi; }
has() { printf '%s' "$out" | grep -q -- "$1"; }

# mdutil -sa prints the file named by STUB_MDUTIL (a canned output), or fails when STUB_MDUTIL_FAIL=1
cat > "$TMP/mdutil" <<STUB
#!/bin/sh
[ "\${STUB_MDUTIL_FAIL:-0}" = 1 ] && { echo "mdutil: error" >&2; exit 1; }
cat "$TMP/\${STUB_MDUTIL:-off}.txt"
STUB
printf '/:\n\tIndexing disabled.\n/System/Volumes/Data:\n\tIndexing disabled.\n/Users/x/HomeLab/HDD:\n\tIndexing and searching disabled.\n/Volumes/EXT:\n\tIndexing disabled.\n' > "$TMP/off.txt"
printf '/:\n\tIndexing disabled.\n/System/Volumes/Data:\n\tIndexing enabled.\n/Volumes/EXT:\n\tIndexing enabled.\n' > "$TMP/on.txt"
printf 'something unexpected\n' > "$TMP/junk.txt"
printf '#!/bin/sh\nexit 0\n' > "$TMP/sleep"
# ps: two snapshots; mds took 3 CPU s, fseventsd (day-form cputime) 60 s
cat > "$TMP/ps" <<STUB
#!/bin/sh
n=\$(cat "$TMP/ps.n" 2>/dev/null || echo 0); echo \$((n + 1)) > "$TMP/ps.n"
if [ "\$n" -eq 0 ]; then
  echo "  128   0:10.00 /System/Library/Frameworks/Metadata.framework/Support/mds"
  echo "  103 1-02:00:00.00 /System/Library/FSEvents.framework/Support/fseventsd"
  echo "  999   0:10.00 /usr/bin/other"
else
  echo "  128   0:13.00 /System/Library/Frameworks/Metadata.framework/Support/mds"
  echo "  103 1-02:01:00.00 /System/Library/FSEvents.framework/Support/fseventsd"
  echo "  999   9:10.00 /usr/bin/other"
fi
STUB
chmod +x "$TMP"/mdutil "$TMP"/sleep "$TMP"/ps

run() { local mode=$1 arg=$2; shift 2; rm -f "$TMP/ps.n"; out=$(env MDUTIL_BIN="$TMP/mdutil" PS_BIN="$TMP/ps" SPOTLIGHT_SLEEP_BIN="$TMP/sleep" "$@" bash "$HERE/spotlight-check.sh" "$mode" $arg 2>&1); rc=$?; }

echo "check"
run check "" STUB_MDUTIL=off
check "every volume off: exit 0" sh -c '[ "$1" -eq 0 ]' _ "$rc"
check "...says so" has "off on every volume"
run check "" STUB_MDUTIL=on
check "a volume on: exit 1 (FAIL)" sh -c '[ "$1" -eq 1 ]' _ "$rc"
check "...names every volume that is on" has "ON for: /System/Volumes/Data, /Volumes/EXT"
check "...does not name one that is off" sh -c '! printf "%s" "$1" | grep -q "for: /,"' _ "$out"
check "...names the fix" has "sudo mdutil -a -i off"
run check "" STUB_MDUTIL_FAIL=1
check "mdutil failing is a FAIL, never 'off'" sh -c '[ "$1" -eq 1 ]' _ "$rc"
check "...says the state is unknown" has "state unknown"
run check "" STUB_MDUTIL=junk
check "unexpected output is a FAIL" sh -c '[ "$1" -eq 1 ]' _ "$rc"
check "...says it is unreadable" has "no readable state"

echo "load"
run load 10 STUB_MDUTIL=off
check "mds took 3 CPU s in 10 s = 30 %" has "30.0% mds"
check "fseventsd 60 CPU s in 10 s, day-form cputime parsed = 600 %" has "600.0% fseventsd"
check "unrelated processes are not listed" sh -c '! printf "%s" "$1" | grep -q other' _ "$out"

echo "usage"
run bogus ""
check "an unknown verb is a usage error" sh -c '[ "$1" -eq 64 ]' _ "$rc"

exit $fail
