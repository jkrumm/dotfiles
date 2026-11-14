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
fake ls '[ -e "$FIX/eperm" ] && { echo "ls: $2: Operation not permitted" >&2; exit 1; }; exit 0'
fake df '[ -e "$FIX/silent" ] && exec sleep 30; [ -e "$FIX/eperm" ] && { echo "df: Operation not permitted" >&2; exit 1; }; exit 0'
fake smbutil '[ -e "$FIX/silent" ] && exec sleep 30; [ -e "$FIX/sessiongone" ] && exit 64; exit 0'
fake secrets-run '[ -e "$FIX/nosecret" ] && exit 1; printf "p@ss word/1\n"'
# The real mount_smbfs asks for the password on its controlling terminal; the fake does the same and
# records what it received apart from its argv, so the suite proves the secret is on the pty only.
fake mount_smbfs 'echo "$*" >> "$FIX/mount_smbfs.args"; [ -e "$FIX/mountfail" ] && exit 1
  printf "Password for %s: " "${@: -2:1}" > /dev/tty; read -rs pw < /dev/tty; echo "$pw" > "$FIX/received.pw"
  if [ -e "$FIX/badpw" ]; then printf "Password for %s: " "${@: -2:1}" > /dev/tty; read -rs pw < /dev/tty; exit 1; fi
  [ "$pw" = "p@ss word/1" ] || exit 1
  mp="${@: -1}"; src="${@: -2:1}"; src="//fixture-user@${src#//*@}"
  echo "$src on $mp (smbfs, nodev, nosuid, mounted by test)" >> "$FIX/table"'
fake osascript 'echo "$*" >> "$FIX/osascript.args"; [ -e "$FIX/mountfail" ] && exit 1
  url=$(printf "%s" "$*" | sed -n "s/.*\"smb:\/\/\([^\"]*\)\".*/\1/p"); share="${url##*/}"
  echo "//${url} on /Volumes/$share (smbfs, nodev, nosuid, mounted by test)" >> "$FIX/table"'
fake diskutil 'echo "unmount $*" >> "$FIX/diskutil.log"; [ -e "$FIX/unmountfail" ] && exit 1
  grep -v " on $2 " "$FIX/table" > "$FIX/table.new"; mv "$FIX/table.new" "$FIX/table"'
fake umount 'exit 1'

CONF="$TMP/shares.conf"
cat > "$CONF" <<'CONF'
# fixture
nas.example.test fixture-user SSD yes # trailing comment is not a scope
nas.example.test fixture-user HDD no macbook
nas.example.test fixture-user HDD yes mini
CONF
: > "$FIX/table"

run() { # run the script as the mini; prints its output, sets $rc
  out=$(PATH="$FAKE:$PATH" SMB_HOST_KIND="${KIND:-mini}" SMB_SHARES_CONF="$CONF" SMB_MOUNT_ROOT="$HOME/HomeLab" \
    SMB_PROBE_SECONDS=3 SMB_RETRY_SLEEP=0 SMB_UNMOUNT_SECONDS=6 SMB_MOUNT_SECONDS=10 SMB_SECRET_SECONDS=6 \
    bash "$HERE/smb-keepalive.sh" 2>&1); rc=$?
  printf '%s\n' "$out" | sed 's/^/    | /'
}
has() { printf '%s' "$out" | grep -q -- "$1"; }

echo "# unreachable server: skipped, exit 0, nothing mounted, leftover empty mount points removed"
mkdir -p "$HOME/HomeLab/SSD" "$HOME/HomeLab/HDD" # left by an earlier mount
touch "$FIX/down"
run
check "exits 0" test "$rc" -eq 0
check "reports skipped" has "skipped"
check "leftover empty mount points removed" test ! -e "$HOME/HomeLab"
check "trailing comment on a row is not a scope" sh -c '! printf "%s" "$1" | grep -q "bad scope"' _ "$out"
check "table untouched" test ! -s "$FIX/table"

echo "# a mount point with content is never removed"
mkdir -p "$HOME/HomeLab/SSD"; echo keep > "$HOME/HomeLab/SSD/file"
run
check "non-empty mount point kept" test -f "$HOME/HomeLab/SSD/file"
rm -rf "$HOME/HomeLab"
rm "$FIX/down"

echo "# absent + automount yes: mounted under the home, scoped rows honoured"
run
check "exits 0" test "$rc" -eq 0
check "SSD mounted" grep -q "/HomeLab/SSD (smbfs" "$FIX/table"
check "HDD mounted (mini row)" grep -q "/HomeLab/HDD (smbfs" "$FIX/table"
check "mount points exist" test -d "$HOME/HomeLab/SSD" -a -d "$HOME/HomeLab/HDD"
check "password reached mount_smbfs through the pty" grep -qx 'p@ss word/1' "$FIX/received.pw"
check "password in no argv" sh -c '! grep -q "p@ss\|p%40ss\|word" "$1"' _ "$FIX/mount_smbfs.args"
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
check "probe reported hung" has "hung > 3s"
check "force-unmounted" grep -q "unmount force $HOME/HomeLab/SSD" "$FIX/diskutil.log"
check "remounted" grep -q "/HomeLab/SSD (smbfs" "$FIX/table"
check "bounded (a 30 s hang finished in under 25 s)" test "$elapsed" -lt 25
: > "$FIX/diskutil.log"

echo "# silent server (stat answers from cache, df and statshares never return): hung, remounted"
touch "$FIX/silent"
SECONDS=0
( sleep 2; rm -f "$FIX/silent" ) &
run
elapsed=$SECONDS
wait
check "exits 0" test "$rc" -eq 0
check "probe reported hung" has "hung > 3s"
check "force-unmounted" grep -q "unmount force $HOME/HomeLab/SSD" "$FIX/diskutil.log"
check "remounted" grep -q "/HomeLab/SSD (smbfs" "$FIX/table"
check "bounded" test "$elapsed" -lt 25
: > "$FIX/diskutil.log"

echo "# dropped session (statshares fails, the rest answers from cache): one retry, remounted"
touch "$FIX/sessiongone"
run
rm "$FIX/sessiongone"
check "failed twice, remounted" has "failed twice"
check "force-unmounted" grep -q "unmount force" "$FIX/diskutil.log"
: > "$FIX/diskutil.log"

echo "# EPERM (the job's program lacks the Network Volumes grant) is cannot probe, never stale"
touch "$FIX/eperm"
run
rm "$FIX/eperm"
check "exits 0" test "$rc" -eq 0
check "says it cannot probe" has "cannot be probed"
check "nothing unmounted" test ! -s "$FIX/diskutil.log"
check "still mounted" grep -q "/HomeLab/SSD (smbfs" "$FIX/table"

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

echo "# server refuses the password: exit 1 with the reseal pointer, no retry loop"
: > "$FIX/table"; rm -rf "$HOME/HomeLab"; touch "$FIX/badpw"
run
rm "$FIX/badpw"
check "exits 1" test "$rc" -eq 1
check "says the password was refused" has "refused the password"
check "no mount point left" test ! -e "$HOME/HomeLab/SSD"

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

echo "# MacBook: ls refused with EPERM is cannot probe too"
: > "$FIX/diskutil.log"; touch "$FIX/eperm"
KIND=macbook run
rm "$FIX/eperm"
unset KIND
check "exits 0" test "$rc" -eq 0
check "says it cannot probe" has "cannot be probed"
check "nothing unmounted" test ! -s "$FIX/diskutil.log"

echo "# missing declaration: exit 1"
out=$(PATH="$FAKE:$PATH" SMB_HOST_KIND=mini SMB_SHARES_CONF="$TMP/none" bash "$HERE/smb-keepalive.sh" 2>&1); rc=$?
check "exits 1" test "$rc" -eq 1

[ "$fail" -eq 0 ] && echo "smb-keepalive: all ok" || { echo "smb-keepalive: FAILED"; exit 1; }
