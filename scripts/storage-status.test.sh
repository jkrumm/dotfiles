#!/bin/bash
# Hermetic suite for storage-status.sh: fake mount table, nc, stat, df, smbutil, diskutil, ssh and a job grader on PATH.
# No network, no real mount. A hanging `stat` fixture proves the bounded probe; mount_smbfs/osascript/umount fakes prove it
# never mounts or unmounts. The jq contract check at the end is the executable form of docs/storage.md §Status.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/storage-status.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME"
FAKE="$TMP/fake"; FIX="$TMP/fix"; VOL="$TMP/volume"
mkdir -p "$FAKE" "$FIX" "$VOL"
export FIX VOL

fail=0
check() { # $1 = name, rest = a condition; passes when it exits 0
  local name=$1; shift
  if "$@"; then echo "  ok  $name"; else echo "  FAIL $name"; fail=1; fi
}
fake() { printf '#!/bin/bash\n%s\n' "$2" > "$FAKE/$1"; chmod +x "$FAKE/$1"; }

NOW=1794680000
HOURS=3600

# Mount table: $FIX/table. Both shares mounted by default.
fake mount 'cat "$FIX/table"'
fake nc '[ ! -e "$FIX/down" ]'
fake stat 'case "$1" in */.storage-status-probe-*) probe=1 ;; *) probe="" ;; esac
  [ -e "$FIX/hang" ] && exec sleep 30; [ -e "$FIX/eperm" ] && { echo "stat: $1: Operation not permitted" >&2; exit 1; }; [ -e "$FIX/statfail" ] && exit 1
  if [ -n "$probe" ]; then [ -e "$FIX/silent" ] && exec sleep 30; [ -e "$FIX/sessiongone" ] && { echo "stat: $1: Operation timed out" >&2; exit 1; }; echo "stat: $1: stat: No such file or directory" >&2; exit 1; fi
  exit 0'
fake df 'if [ -e "$FIX/fallthrough" ]; then fs=/dev/disk3s5; else fs="//fixture-user@nas.example.test/SHARE"; fi
  echo "Filesystem 1024-blocks Used Available Capacity Mounted on"; echo "$fs 1000 400 600 40% $3"'
fake smbutil 'echo smbutil >> "$FIX/forbidden.calls"; exit 1'
fake ssh '[ -e "$FIX/kumadown" ] && exit 255; if [ -e "$FIX/nobeat" ]; then echo; else echo "$KUMA_EPOCH"; fi'
fake diskutil 'cat "$FIX/disk.plist"'
for never in mount_smbfs osascript umount; do fake "$never" "echo $never >> \"\$FIX/forbidden.calls\"; exit 1"; done
# diskutil is also what a forced unmount would call: make it record that, too
fake diskutil 'case "$1" in unmount) echo diskutil-unmount >> "$FIX/forbidden.calls"; exit 1 ;; esac; cat "$FIX/disk.plist"'

CONF="$TMP/shares.conf"
cat > "$CONF" <<'CONF'
# fixture
nas.example.test fixture-user SSD yes # trailing comment is not a scope
nas.example.test fixture-user HDD yes mini
nas.example.test fixture-user OPT no macbook
CONF
VGCONF="$TMP/external-volume.json"
echo '{"name":"EXT","sentinel":".volume-gate","attached":false,"passphraseRef":null}' > "$VGCONF"
cat > "$FIX/disk.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>DeviceIdentifier</key><string>disk9s1</string>
<key>MountPoint</key><string>$VOL</string>
<key>Locked</key><false/><key>FileVault</key><true/>
</dict></plist>
PLIST
GRADE='[{"label":"com.jkrumm.smb-keepalive","rc":0,"consecutive_fail":0,"last_ok":"2026-11-14T18:00:00.000Z","last_started":"2026-11-14T18:00:00.000Z","grade":"ok"}]'

reset() {
  rm -f "$FIX"/down "$FIX"/hang "$FIX"/eperm "$FIX"/statfail "$FIX"/fallthrough "$FIX"/silent "$FIX"/sessiongone \
        "$FIX"/kumadown "$FIX"/nobeat "$FIX"/forbidden.calls
  rm -rf "$VOL/mirror"
  cat > "$FIX/table" <<TABLE
//fixture-user@nas.example.test/SSD on $HOME/HomeLab/SSD (smbfs, nodev, nosuid, mounted by test)
//fixture-user@nas.example.test/HDD on $HOME/HomeLab/HDD (smbfs, nodev, nosuid, mounted by test)
TABLE
  echo '{"name":"EXT","sentinel":".volume-gate","attached":false,"passphraseRef":null}' > "$VGCONF"
}

run() { # run the script; args pass through; sets $out, $rc, $secs
  local t0=$SECONDS
  out=$(PATH="$FAKE:$PATH" STORAGE_HOST_KIND="${KIND:-mini}" SMB_SHARES_CONF="${TEST_CONF:-$CONF}" STORAGE_PROBE_SECONDS=2 STORAGE_NOW=$NOW \
    STORAGE_JOBS_GRADE_CMD="printf '%s' '$GRADE'" VOLUME_GATE_CONFIG="$VGCONF" VOLUME_GATE_DISKUTIL="$FAKE/diskutil" \
    KUMA_EPOCH=$((NOW - 15 * HOURS)) bash "$SCRIPT" "$@" 2>"$TMP/stderr"); rc=$?
  secs=$((SECONDS - t0))
}
j() { printf '%s' "$out" | jq -r "$1"; }
jt() { printf '%s' "$out" | jq -e "$1" >/dev/null; }
adopt() { echo '{"name":"EXT","sentinel":".volume-gate","attached":true,"passphraseRef":null}' > "$VGCONF"; echo ok > "$VOL/.volume-gate"; }

# The contract of docs/storage.md §Status, as one jq predicate on the object.
CONTRACT='
  def nb: type == "number" or . == null;
  def sb: type == "string" or . == null;
  .schema == 1 and (.generated_at | type == "string") and (.host == "mini" or .host == "macbook")
  and (.shares | type == "array")
  and (.shares | all(.name | type == "string"))
  and (.shares | all(.state | IN("healthy","stale","not_mounted","unreachable","unprobeable")))
  and (.shares | all((.automount | type == "boolean") and (.mounted | type == "boolean") and (.mount_point | sb)
                     and (.reachable | type == "boolean") and (.healthy == null or (.healthy | type == "boolean"))
                     and (.free_bytes | nb) and (.total_bytes | nb) and (.reason | sb)))
  and (.shares_reason | sb)
  and (.keepalive.available | type == "boolean") and (.keepalive.reason | sb)
  and (.external_volume.available | type == "boolean") and (.external_volume.reason | sb)
      and (.external_volume.state | sb) and (.external_volume.free_bytes | nb) and (.external_volume.total_bytes | nb)
  and (.mirror.available | type == "boolean") and (.mirror.reason | sb)
  and (.backup.available | type == "boolean") and (.backup.reason | sb)
  and (.warnings | all((.code | IN("share_not_healthy","mirror_stale")) and (.subject | type == "string") and (.message | type == "string")))
  and ((.keepalive | if .available then (.grade | type == "string") and (.last_run_age_seconds | nb) and (.consecutive_fail | type == "number") else true end))
  and ((.mirror | if .available then (.finished | type == "string") and (.age_seconds | type == "number") else true end))
  and ((.backup | if .available then (.age_seconds | type == "number") and (.last_success | type == "string") else true end))'

echo "# both shares healthy: free and total from the mounted file system, JSON validates"
reset; run --json
check "exits 0" test "$rc" -eq 0
check "contract" jt "$CONTRACT"
check "two shares, scope row for the MacBook skipped" test "$(j '.shares | length')" = 2
check "SSD healthy" test "$(j '.shares[0] | .name + ":" + .state')" = "SSD:healthy"
check "free and total in bytes (1 KiB blocks)" test "$(j '.shares[0] | "\(.free_bytes)/\(.total_bytes)"')" = "614400/1024000"
check "no warnings" jt '.warnings == []'
check "keepalive grade and age" test "$(j '.keepalive | "\(.grade)/\(.last_run_age_seconds)"')" = "ok/$((NOW - 1794679200))"
check "restic age from the monitor" test "$(j '.backup.age_seconds')" = "$((15 * HOURS))"
check "the server name never appears" sh -c '! printf "%s" "$1" | grep -qi "nas.example"' _ "$out"
check "nothing mounted or unmounted" test ! -e "$FIX/forbidden.calls"

echo "# table"
reset; run
check "table lists both shares" sh -c 'printf "%s" "$1" | grep -q "SSD .*healthy" && printf "%s" "$1" | grep -q "HDD .*healthy"' _ "$out"
check "table has no server name" sh -c '! printf "%s" "$1" | grep -qi "nas.example"' _ "$out"
check "table shows ~ for the home folder" sh -c 'printf "%s" "$1" | grep -q "~/HomeLab/SSD"' _ "$out"

echo "# hanging stat: bounded, share reported stale, warned"
reset; touch "$FIX/hang"; run --json
check "returns within the bound (2 probes x 2 s at most)" test "$secs" -le 6
check "contract" jt "$CONTRACT"
check "stale, not healthy" test "$(j '.shares[0] | .state + ":" + (.healthy | tostring)')" = "stale:false"
check "free is null on a stale mount" jt '.shares[0].free_bytes == null'
check "warns" jt '.warnings | map(.code) | index("share_not_healthy") != null'
check "nothing mounted or unmounted" test ! -e "$FIX/forbidden.calls"

echo "# a silent server (the lookup hangs), a dropped session, a mount hidden behind the boot volume"
reset; touch "$FIX/silent"; run --json
check "lookup hang: stale within the bound" sh -c '[ "$1" -le 6 ] && [ "$2" = stale ]' _ "$secs" "$(j '.shares[0].state')"
reset; touch "$FIX/sessiongone"; run --json
check "session gone: stale" test "$(j '.shares[0].state')" = stale
reset; touch "$FIX/fallthrough"; run --json
check "df answering for a non-SMB file system: stale" test "$(j '.shares[0].state')" = stale

echo "# Operation not permitted is unprobeable, never stale and never a warning"
reset; touch "$FIX/eperm"; run --json
check "unprobeable, healthy null" test "$(j '.shares[0] | .state + ":" + (.healthy | tostring)')" = "unprobeable:null"
check "no warning" jt '.warnings == []'

echo "# force-unmounted share: reported unmounted, no hang, never mounted"
reset; grep -v "/SSD" "$FIX/table" > "$FIX/table.new"; mv "$FIX/table.new" "$FIX/table"; touch "$FIX/hang"; run --json
check "SSD not_mounted (reachable)" test "$(j '.shares[0] | .state + ":" + (.mounted | tostring) + ":" + (.reachable | tostring)')" = "not_mounted:false:true"
check "the other share still probed and reported" test "$(j '.shares[1].state')" = stale
check "mount point null" jt '.shares[0].mount_point == null'
check "warns for the automount share" jt '.warnings | map(.subject) | index("SSD") != null'
check "nothing mounted" test ! -e "$FIX/forbidden.calls"
echo "# unreachable server"
reset; touch "$FIX/down"; : > "$FIX/table"; run --json
check "unreachable" test "$(j '[.shares[].state] | unique | join(",")')" = unreachable
check "contract" jt "$CONTRACT"

echo "# an opt-out share that is not mounted is not a warning (MacBook scope row)"
reset; KIND=macbook run --json
check "macbook: only the rows for it (SSD, OPT)" test "$(j '[.shares[].name] | join(",")')" = "SSD,OPT"
check "mini-only sections are null with a reason" jt '.external_volume.available == false and .external_volume.reason == "mini only" and .mirror.reason == "mini only"'
check "OPT (automount no) not warned" jt '[.warnings[].subject] | index("OPT") == null'
check "contract" jt "$CONTRACT"
unset KIND

echo "# external volume: unattached, absent"
reset; run --json
check "unattached: state and reason" jt '.external_volume.state == "unattached" and (.external_volume.reason | test("not adopted"))'
check "mirror says why" jt '.mirror.available == false and (.mirror.reason | test("unattached"))'
echo "# volume present, no mirror yet"
reset; adopt; run --json
check "present, free and total from the volume" test "$(j '.external_volume | "\(.state)/\(.free_bytes)/\(.total_bytes)"')" = "present/614400/1024000"
check "mirror not built yet" jt '.mirror.available == false and (.mirror.reason | test("not built yet"))'
check "no mirror warning without a mirror" jt '.warnings == []'
check "contract" jt "$CONTRACT"

echo "# mirror status file: fresh and stale"
mkdir -p "$VOL/mirror"
fin=$(date -u -r $((NOW - 3 * HOURS)) '+%Y-%m-%dT%H:%M:%S.123Z')
printf '{"started":"x","finished":"%s","sources":{"ssd":{"files":10,"bytes":20,"errors":0}}}' "$fin" > "$VOL/mirror/.status.json"
run --json
check "age from finished" test "$(j '.mirror.age_seconds')" = "$((3 * HOURS))"
check "sources passed through" jt '.mirror.sources.ssd.files == 10'
check "fresh mirror: no warning" jt '.warnings == []'
check "contract" jt "$CONTRACT"
fin=$(date -u -r $((NOW - 40 * HOURS)) '+%Y-%m-%dT%H:%M:%SZ')
printf '{"finished":"%s"}' "$fin" > "$VOL/mirror/.status.json"
run --json
check "40 h old mirror warns" jt '.warnings | map(.code) | index("mirror_stale") != null'
check "the warning is data, exit 0" test "$rc" -eq 0
echo '{"finished":"nonsense"}' > "$VOL/mirror/.status.json"; run --json
check "unreadable finished: not available, with a reason" jt '.mirror.available == false and (.mirror.reason | test("finished"))'
echo 'not json' > "$VOL/mirror/.status.json"; run --json
check "invalid JSON: not available, with a reason" jt '.mirror.available == false and (.mirror.reason | test("not valid JSON"))'
echo "# volume locked: mirror unavailable, volume says why"
reset; adopt; sed -i '' 's|<key>Locked</key><false/>|<key>Locked</key><true/>|' "$FIX/disk.plist"; run --json
check "locked" test "$(j '.external_volume.state')" = locked
check "mirror unavailable" jt '.mirror.available == false'

echo "# restic: Kuma unreachable, no heartbeat, --no-remote"
reset; touch "$FIX/kumadown"; run --json
check "unreachable: left out with a reason" jt '.backup.available == false and (.backup.reason | test("not reachable"))'
check "still exits 0 with the rest" test "$rc" -eq 0
reset; touch "$FIX/nobeat"; run --json
check "no successful heartbeat" jt '.backup.available == false and (.backup.reason | test("no successful"))'
reset; run --json --no-remote
check "--no-remote skips it" jt '.backup.reason | test("no-remote")'

echo "# keepalive: no row, grader failing"
reset; GRADE='[]' run --json
check "no row: unavailable with a reason" jt '.keepalive.available == false and (.keepalive.reason | test("no jobrun state"))'
reset; GRADE='' run --json
check "empty grader output: unavailable" jt '.keepalive.available == false'
GRADE='[{"label":"com.jkrumm.smb-keepalive","rc":143,"consecutive_fail":378,"last_ok":"2026-11-14T11:31:36.016Z","last_started":"2026-11-14T18:12:08.336Z","grade":"failing","reason":"x"}]'
reset; run --json
check "failing grade reported as is" test "$(j '.keepalive | "\(.grade)/\(.consecutive_fail)"')" = "failing/378"
check "contract" jt "$CONTRACT"

echo "# no declaration"
reset; TEST_CONF="$TMP/missing.conf" run --json
check "empty shares with a reason, exit 0" sh -c '[ "$1" -eq 0 ] && [ "$2" = true ]' _ "$rc" "$(j '(.shares == []) and (.shares_reason | test("no share declaration"))')"

echo "# usage"
reset; run --bogus
check "unknown flag: exit 2" test "$rc" -eq 2

echo
if [ "$fail" -eq 0 ]; then echo "storage-status: all ok"; else echo "storage-status: FAILURES"; fi
exit "$fail"
