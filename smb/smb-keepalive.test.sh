#!/bin/bash
# Hermetic suite for smb-keepalive.sh: fake mount table, stat, ls, nc, mount_smbfs, diskutil,
# osascript and secrets-run on PATH — no network, no real mount, no secret. A hanging `stat`
# fixture proves the bounded probe, force-unmount and remount path.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME"
FAKE="$TMP/fake"; FIX="$TMP/fix"
mkdir -p "$FAKE" "$FIX"
export FIX

fail=0
check() { # $1 = name, rest = a condition; passes when it exits 0
  local name=$1; shift
  if "$@"; then echo "  ok  $name"; else echo "  FAIL $name"; fail=1; fi
}
fake() { printf '#!/bin/bash\n%s\n' "$2" > "$FAKE/$1"; chmod +x "$FAKE/$1"; }

# The mount table is $FIX/table; mount_smbfs appends, diskutil/umount remove.
fake mount 'cat "$FIX/table"'
fake nc '[ ! -e "$FIX/down" ]'
fake stat '[ -e "$FIX/hang" ] && exec sleep 30; [ -e "$FIX/statfail" ] && exit 1; exit 0'
fake ls 'exit 0'
fake secrets-run '[ -e "$FIX/nosecret" ] && exit 1; printf "p@ss word/1\n"'
fake mount_smbfs 'echo "$*" >> "$FIX/mount_smbfs.args"; [ -e "$FIX/mountfail" ] && exit 1
  # last arg = mount point, previous = //user:pw@server/share
  mp="${@: -1}"; src="${@: -2:1}"; src="//${src#//*@}"; src="//fixture-user@${src#//}"
  echo "$src on $mp (smbfs, nodev, nosuid, mounted by test)" >> "$FIX/table"'
fake osascript 'echo "$*" >> "$FIX/osascript.args"; [ -e "$FIX/mountfail" ] && exit 1
  url="${*#*\"smb://}"; url="${url%\"*}"; share="${url##*/}"
  echo "//${url} on /Volumes/$share (smbfs, nodev, nosuid, mounted by test)" >> "$FIX/table"'
fake diskutil 'echo "unmount $*" >> "$FIX/diskutil.log"; [ -e "$FIX/unmountfail" ] && exit 1
  grep -v " on $2 " "$FIX/table" > "$FIX/table.new"; mv "$FIX/table.new" "$FIX/table"'
fake umount 'exit 1'

CONF="$TMP/shares.conf"
cat > "$CONF" <<'CONF'
# fixture
nas.example.test fixture-user SSD yes
nas.example.test fixture-user HDD no macbook
nas.example.test fixture-user HDD yes mini
CONF
: > "$FIX/table"

run() { # run the script as the mini; prints its output, sets $rc
  out=$(PATH="$FAKE:$PATH" SMB_HOST_KIND="${KIND:-mini}" SMB_SHARES_CONF="$CONF" SMB_MOUNT_ROOT="$HOME/HomeLab" \
    SMB_PROBE_SECONDS=1 SMB_RETRY_SLEEP=0 SMB_UNMOUNT_SECONDS=2 SMB_MOUNT_SECONDS=2 SMB_SECRET_SECONDS=2 \
    bash "$HERE/smb-keepalive.sh" 2>&1); rc=$?
  printf '%s\n' "$out" | sed 's/^/    | /'
}
has() { printf '%s' "$out" | grep -q -- "$1"; }

echo "# unreachable server: skipped, exit 0, nothing mounted or created"
touch "$FIX/down"
run
check "exits 0" test "$rc" -eq 0
check "reports skipped" has "skipped"
check "no mount point created" test ! -e "$HOME/HomeLab"
check "table untouched" test ! -s "$FIX/table"
rm "$FIX/down"

echo "# absent + automount yes: mounted under the home, scoped rows honoured"
run
check "exits 0" test "$rc" -eq 0
check "SSD mounted" grep -q "/HomeLab/SSD (smbfs" "$FIX/table"
check "HDD mounted (mini row)" grep -q "/HomeLab/HDD (smbfs" "$FIX/table"
check "mount points exist" test -d "$HOME/HomeLab/SSD" -a -d "$HOME/HomeLab/HDD"
check "password url-encoded in the mount call" grep -q 'fixture-user:p%40ss%20word%2F1@nas.example.test/SSD' "$FIX/mount_smbfs.args"
check "password never logged" sh -c '! printf "%s" "$1" | grep -q "p@ss\|p%40ss"' _ "$out"
check "no osascript on the mini" test ! -e "$FIX/osascript.args"

echo "# healthy: nothing happens"
: > "$FIX/mount_smbfs.args"
run
check "exits 0" test "$rc" -eq 0
check "reports healthy" has "SSD: healthy"
check "no remount" test ! -s "$FIX/mount_smbfs.args"

echo "# hanging stat: bounded probe, force-unmount, remount (no waiting on the hung call)"
touch "$FIX/hang"
SECONDS=0
( sleep 2; rm -f "$FIX/hang" ) &   # the server "comes back" once the stale mount is dropped
run
elapsed=$SECONDS
wait
check "exits 0" test "$rc" -eq 0
check "probe reported hung" has "hung > 1s"
check "force-unmounted" grep -q "unmount force $HOME/HomeLab/SSD" "$FIX/diskutil.log"
check "remounted" grep -q "/HomeLab/SSD (smbfs" "$FIX/table"
check "bounded (a 30 s hang finished in under 15 s)" test "$elapsed" -lt 15
: > "$FIX/diskutil.log"

echo "# fast stat failure: one retry, then the same path"
touch "$FIX/statfail"
run
rm "$FIX/statfail"
check "failed twice, remounted" has "failed twice"
check "force-unmounted" grep -q "unmount force" "$FIX/diskutil.log"

echo "# force-unmount fails: exit 1, no remount attempt on that share"
: > "$FIX/mount_smbfs.args"; : > "$FIX/diskutil.log"
touch "$FIX/statfail" "$FIX/unmountfail"
run
rm "$FIX/statfail" "$FIX/unmountfail"
check "exits 1" test "$rc" -eq 1
check "says so" has "force-unmount of"

echo "# mount fails: exit 1, no mount point left behind"
: > "$FIX/table"; rm -rf "$HOME/HomeLab"; touch "$FIX/mountfail"
run
rm "$FIX/mountfail"
check "exits 1" test "$rc" -eq 1
check "reports the failure" has "mount_smbfs failed"
check "no mount point created" test ! -e "$HOME/HomeLab/SSD" -a ! -e "$HOME/HomeLab/HDD"

echo "# secret missing from the cache: exit 1 with the reseal pointer, no mount attempt"
: > "$FIX/mount_smbfs.args"; touch "$FIX/nosecret"
run
rm "$FIX/nosecret"
check "exits 1" test "$rc" -eq 1
check "names make secrets-reseal-request" has "secrets-reseal-request"
check "no mount attempt" test ! -s "$FIX/mount_smbfs.args"

echo "# MacBook: scoped rows, osascript, no secret read, no mount point of ours"
: > "$FIX/table"; rm -rf "$HOME/HomeLab"
KIND=macbook run
unset KIND
check "exits 0" test "$rc" -eq 0
check "SSD mounted via osascript" grep -q "/Volumes/SSD (smbfs" "$FIX/table"
check "HDD (automount no) not mounted" sh -c '! grep -q "/Volumes/HDD" "$1"' _ "$FIX/table"
check "mini row skipped" has "HDD: reachable, not mounted (automount off)"
check "nothing created under the home" test ! -e "$HOME/HomeLab"

echo "# missing declaration: exit 1"
out=$(PATH="$FAKE:$PATH" SMB_HOST_KIND=mini SMB_SHARES_CONF="$TMP/none" bash "$HERE/smb-keepalive.sh" 2>&1); rc=$?
check "exits 1" test "$rc" -eq 1

[ "$fail" -eq 0 ] && echo "smb-keepalive: all ok" || { echo "smb-keepalive: FAILED"; exit 1; }
