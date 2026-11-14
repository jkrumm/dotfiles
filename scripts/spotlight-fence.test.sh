#!/bin/bash
# Hermetic suite for spotlight-fence.sh: mdutil, sudo, ps and sleep are stubs; nothing on the host changes.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail=0
check() { local name=$1; shift; if "$@"; then echo "  ok  $name"; else echo "  FAIL $name"; fail=1; fi; }
has() { printf '%s' "$out" | grep -q -- "$1"; }

# mdutil -s reports the state file; the sudo stub flips it (STUB_RULE=1 = the sudoers rule is installed)
cat > "$TMP/mdutil" <<STUB
#!/bin/sh
[ "\$1" = "-s" ] || exit 0
[ -f "$TMP/index_on" ] && echo "/System/Volumes/Data:
	Indexing enabled." || echo "/System/Volumes/Data:
	Indexing disabled."
STUB
cat > "$TMP/sudo" <<STUB
#!/bin/sh
[ "\${STUB_RULE:-0}" = 1 ] || exit 1
echo "\$*" >> "$TMP/sudo.calls"
[ "\${STUB_NOOP:-0}" = 1 ] || rm -f "$TMP/index_on"
exit 0
STUB
printf '#!/bin/sh\nexit 0\n' > "$TMP/sleep"
# ps: two snapshots, the second 3 CPU seconds later for mds and 1 minute later for fseventsd
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
chmod +x "$TMP"/mdutil "$TMP"/sudo "$TMP"/sleep "$TMP"/ps

setup() { rm -f "$TMP"/index_on "$TMP"/*.calls "$TMP"/ps.n; for s in "$@"; do touch "$TMP/$s"; done; }
run() { local mode=$1; shift; out=$(env MDUTIL_BIN="$TMP/mdutil" SUDO_BIN="$TMP/sudo" PS_BIN="$TMP/ps" SPOTLIGHT_SLEEP_BIN="$TMP/sleep" "$@" bash "$HERE/spotlight-fence.sh" "$mode" $ARG 2>&1); rc=$?; }
ARG=""

echo "check"
setup
run check
check "index off: fenced, exit 0" sh -c '[ "$1" -eq 0 ]' _ "$rc"
check "...says fenced" has "spotlight fenced"
setup index_on
run check
check "index on: WARN exit 2" sh -c '[ "$1" -eq 2 ]' _ "$rc"
check "...names the file index" has "file index of /System/Volumes/Data is on"
check "...names the fix" has "make spotlight-fence"

echo "apply"
setup index_on
run apply STUB_RULE=1
check "with the rule: exit 0" sh -c '[ "$1" -eq 0 ]' _ "$rc"
check "...mdutil -i off on the Data volume ran through sudo -n" grep -q '^-n .*mdutil -i off /System/Volumes/Data' "$TMP/sudo.calls"
run check
check "...and check now reports fenced" sh -c '[ "$1" -eq 0 ]' _ "$rc"
setup index_on
run apply STUB_RULE=0
check "without the rule: exit 1" sh -c '[ "$1" -eq 1 ]' _ "$rc"
check "...names make spotlight-sudoers" has "make spotlight-sudoers"
setup index_on
run apply STUB_RULE=1 STUB_NOOP=1
check "a mdutil that changed nothing is a failure, not a success" sh -c '[ "$1" -eq 1 ]' _ "$rc"
setup
run apply STUB_RULE=0
check "already off: exit 0, no sudo" sh -c '[ "$1" -eq 0 ] && [ ! -f "$2" ]' _ "$rc" "$TMP/sudo.calls"

echo "load"
setup
ARG=10 run load
check "mds took 3 CPU s in 10 s = 30 %" has "30.0% mds"
check "fseventsd 1 minute (60 s) in 10 s, day-form cputime parsed = 600 %" has "600.0% fseventsd"
check "unrelated processes are not listed" sh -c '! printf "%s" "$1" | grep -q other' _ "$out"
ARG=""

echo "usage"
run bogus
check "an unknown verb is a usage error" sh -c '[ "$1" -eq 64 ]' _ "$rc"

exit $fail
