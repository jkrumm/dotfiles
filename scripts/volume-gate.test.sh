#!/usr/bin/env bash
set -u
# Hermetic test for scripts/lib/volume-gate.sh and scripts/external-volume-unlock.sh: a stub `diskutil`
# plays the drive (present, absent, locked, vanished), a temp directory is the stand-in volume. No real
# disk, mount point or device is touched, and nothing may appear on the internal disk (the "scratch" tree).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$HERE/lib/volume-gate.sh"
UNLOCK="$HERE/external-volume-unlock.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/volume-gate-test.XXXXXX")" || exit 2
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; fail=$((fail + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }

mkdir -p "$T/bin" "$T/scratch" "$T/vol"
VOL="$T/vol/EXT"     # the stand-in mount point; "absent" means this does not exist
echo marker > "$T/sentinel-content"

# diskutil stub. MODE file: present | locked | absent | nomount. `apfs unlockVolume` records argv and stdin.
cat > "$T/bin/diskutil" <<STUB
#!/bin/bash
mode=\$(/bin/cat "$T/mode")
case "\$1" in
  info)
    case "\$mode" in
      absent) printf '<?xml version="1.0"?><plist version="1.0"><dict><key>Error</key><true/><key>ErrorMessage</key><string>Could not find disk</string></dict></plist>'; exit 1 ;;
      locked) printf '<?xml version="1.0"?><plist version="1.0"><dict><key>DeviceIdentifier</key><string>disk99s1</string><key>FileVault</key><true/><key>Locked</key><true/><key>MountPoint</key><string></string></dict></plist>' ;;
      nomount) printf '<?xml version="1.0"?><plist version="1.0"><dict><key>DeviceIdentifier</key><string>disk99s1</string><key>FileVault</key><true/><key>MountPoint</key><string></string></dict></plist>' ;;
      *) printf '<?xml version="1.0"?><plist version="1.0"><dict><key>DeviceIdentifier</key><string>disk99s1</string><key>FileVault</key><true/><key>Locked</key><false/><key>MountPoint</key><string>$VOL</string></dict></plist>' ;;
    esac ;;
  apfs)
    echo "\$*" >> "$T/diskutil.calls"
    /bin/cat > "$T/diskutil.stdin"
    [ -f "$T/unlock-fails" ] && exit 1
    echo present > "$T/mode"; mkdir -p "$VOL"; cp "$T/sentinel-content" "$VOL/.volume-gate" ;;
esac
STUB
chmod +x "$T/bin/diskutil"

cfg() { # cfg <attached> <passphraseRef>
  printf '{"name":"EXT","sentinel":".volume-gate","attached":%s,"passphraseRef":%s}\n' "$1" "$2" > "$T/cfg.json"
}
mkvol() { mkdir -p "$VOL"; cp "$T/sentinel-content" "$VOL/.volume-gate"; echo present > "$T/mode"; }
rmvol() { rm -rf "$VOL"; echo absent > "$T/mode"; }
export VOLUME_GATE_CONFIG="$T/cfg.json" VOLUME_GATE_DISKUTIL="$T/bin/diskutil" VOLUME_GATE_READ_TIMEOUT=1 VOLUME_GATE_READ_ATTEMPTS=1
gate() { bash "$GATE" "$@"; }
snapshot() { (cd "$T" && find scratch vol -mindepth 0 2>/dev/null | sort | tr '\n' ' '); }

# --- present ---
cfg true null; mkvol
eq "state present" present "$(gate state)"
eq "root is the mount point" "$VOL" "$(gate root)"
out=$(gate run -- sh -c 'echo "root=$VOLUME_ROOT"'); eq "run hands the root over" "root=$VOL" "$out"
gate run -- sh -c 'exit 3'; eq "a failing command's rc passes through while the volume is there" 3 $?

# --- attached false: silent no-op ---
cfg false null; : > "$T/ran"; rm "$T/ran"
out=$(gate run -- sh -c "touch '$T/ran'"); rc=$?
eq "attached=false skips with exit 0" 0 "$rc"; eq "attached=false line" "skipped: volume not attached" "$out"
[ ! -e "$T/ran" ] && ok "attached=false runs nothing" || bad "attached=false must not run the command"

# --- absent: nothing created anywhere, the command never runs ---
cfg true null; rmvol
before=$(snapshot)
out=$(gate run -- sh -c "touch '$T/ran'; mkdir -p '$VOL/data'"); rc=$?
eq "absent exit 0" 0 "$rc"; eq "absent line" "skipped: volume absent" "$out"
[ ! -e "$T/ran" ] && ok "absent runs nothing" || bad "absent must not run the command"
eq "absent creates nothing (no mkdir -p of the missing path, no internal fallback)" "$before" "$(snapshot)"
[ ! -e "$VOL" ] && ok "the missing mount point stays missing" || bad "the missing mount point was created"
gate root >/dev/null && bad "root must exit 1 when absent" || ok "root exits 1 when absent"

# --- locked ---
echo locked > "$T/mode"
out=$(gate run -- sh -c "touch '$T/ran'"); rc=$?
eq "locked exit 0" 0 "$rc"; eq "locked line" "skipped: volume locked" "$out"
[ ! -e "$T/ran" ] && ok "locked runs nothing" || bad "locked must not run the command"
echo nomount > "$T/mode"
eq "an encrypted volume with no mount point is locked" locked "$(gate state)"

# --- sentinel missing: mounted but not ours / half-mounted ---
mkvol; rm "$VOL/.volume-gate"
out=$(gate run -- sh -c "touch '$T/ran'"); rc=$?
eq "sentinel missing exit 0" 0 "$rc"; eq "sentinel missing line" "skipped: volume unreadable" "$out"
[ ! -e "$T/ran" ] && ok "sentinel missing runs nothing" || bad "sentinel missing must not run the command"

# --- the path vanishes mid-run ---
mkvol
out=$(gate run -- sh -c "rm -rf '$VOL'; echo absent > '$T/mode'; exit 1"); rc=$?
eq "vanished mid-run exit 0" 0 "$rc"; eq "vanished mid-run line" "skipped: volume vanished during run" "$out"
[ ! -e "$VOL" ] && ok "vanished mid-run: nothing re-created" || bad "the vanished path came back"
# the sentinel read races the unmount: a mount point that disappears between probe and read is absent
mkvol
cat > "$T/bin/cat" <<STUB
#!/bin/bash
rm -rf "$VOL"; echo absent > "$T/mode"; exit 1
STUB
chmod +x "$T/bin/cat"
eq "vanished between probe and read is absent" absent "$(PATH="$T/bin:$PATH" gate state)"
rm "$T/bin/cat"

# --- a frozen read (pending TCC prompt) is bounded ---
mkvol
cat > "$T/bin/cat" <<STUB
#!/bin/bash
exec sleep 30
STUB
chmod +x "$T/bin/cat"
start=$SECONDS; st=$(PATH="$T/bin:$PATH" gate state); took=$((SECONDS - start))
eq "a frozen sentinel read is unreadable" unreadable "$st"
[ "$took" -lt 10 ] && ok "the frozen read was cut at the bound (${took}s)" || bad "the read was not bounded (${took}s)"
rm "$T/bin/cat"

# --- a slow read is tried again, a stalled one says why ---
mkvol
cat > "$T/bin/cat" <<STUB
#!/bin/bash
# the first read stalls (a busy host), the second answers
if [ ! -e "$T/cat-ran" ]; then touch "$T/cat-ran"; exec sleep 30; fi
exec /bin/cat "\$@"
STUB
chmod +x "$T/bin/cat"; rm -f "$T/cat-ran"
eq "a read that stalls once and then answers is present (3 attempts)" present "$(VOLUME_GATE_READ_ATTEMPTS=3 PATH="$T/bin:$PATH" gate state)"
rm -f "$T/cat-ran"
eq "...but is unreadable when only one attempt is allowed" unreadable "$(PATH="$T/bin:$PATH" gate state)"
printf '#!/bin/bash\nexec sleep 30\n' > "$T/bin/cat"
out=$(VOLUME_GATE_READ_ATTEMPTS=2 PATH="$T/bin:$PATH" gate run -- true); rc=$?
case "$out" in "skipped: volume unreadable (the read stalled 2 x 1s ("*"load "*"reader state "*"))") ok "an unreadable skip names the attempts, the load and the reader's state" ;; *) bad "unreadable detail" "$out" ;; esac
eq "an unreadable skip still exits 0 by default" 0 "$rc"
rm "$T/bin/cat"

# --- --skip-rc: a skip is not a green run ---
out=$(gate run --skip-rc 3 -- sh -c 'echo ran'); rc=$?
eq "--skip-rc leaves a run that went through alone" "ran 0" "$out $rc"
rmvol
out=$(gate run --skip-rc 3 -- sh -c "touch '$T/ran'"); rc=$?
eq "--skip-rc: an absent volume exits with the skip rc" 3 "$rc"; eq "--skip-rc: the same one line" "skipped: volume absent" "$out"
[ ! -e "$T/ran" ] && ok "--skip-rc: still runs nothing" || bad "--skip-rc ran the command"
mkvol
out=$(gate run --skip-rc 3 -- sh -c "rm -rf '$VOL'; echo absent > '$T/mode'; exit 1"); rc=$?
eq "--skip-rc: a volume that vanished mid-run exits with the skip rc" "3 skipped: volume vanished during run" "$rc $out"
gate run --skip-rc x -- true >/dev/null 2>&1; eq "--skip-rc wants a number" 2 $?
mkvol

# --- the unlock job ---
export EXTERNAL_VOLUME_STATE_DIR="$T/state"
printf '#!/bin/sh\necho "s3cret-pass"\n' > "$T/bin/secrets-run"; chmod +x "$T/bin/secrets-run"
export VOLUME_GATE_SECRETS_RUN="$T/bin/secrets-run"
unlock() { bash "$UNLOCK"; }

cfg false null; echo locked > "$T/mode"; rm -f "$T/diskutil.calls"
out=$(unlock); eq "unlock: attached=false is silent" "" "$out"
[ ! -e "$T/diskutil.calls" ] && ok "unlock: attached=false touches nothing" || bad "unlock ran diskutil while unattached"

cfg true '"op://example/ext/passphrase"'; mkvol
out=$(unlock); eq "unlock: already mounted is silent" "" "$out"
[ ! -e "$T/diskutil.calls" ] && ok "unlock: idempotent when mounted" || bad "unlock called diskutil while mounted"

rmvol
out=$(unlock); eq "unlock: absent is silent" "" "$out"
[ ! -e "$T/diskutil.calls" ] && ok "unlock: nothing to do while absent" || bad "unlock called diskutil while absent"

cfg true null; echo locked > "$T/mode"
out=$(unlock); eq "unlock: no ref" "skipped: passphrase ref not set" "$out"

cfg true '"op://example/ext/passphrase"'; echo locked > "$T/mode"; rm -rf "$VOL" "$T/state"
out=$(unlock); rc=$?
eq "unlock exits 0" 0 "$rc"
case "$out" in *"unlocked"*) ok "unlock logs the unlock" ;; *) bad "unlock line" "$out" ;; esac
case "$(cat "$T/diskutil.calls")" in *"unlockVolume disk99s1 -stdinpassphrase"*) ok "unlock targets the device with -stdinpassphrase" ;; *) bad "unlock argv" "$(cat "$T/diskutil.calls")" ;; esac
case "$(cat "$T/diskutil.calls")" in *s3cret*|*passphrase\ s3*) bad "the passphrase reached argv" ;; *) ok "the passphrase is not in argv" ;; esac
eq "the passphrase arrives on stdin" "s3cret-pass" "$(cat "$T/diskutil.stdin")"

echo locked > "$T/mode"; rm -rf "$VOL" "$T/state"; : > "$T/unlock-fails"; rm -f "$T/diskutil.calls"
out=$(unlock); rc=$?
eq "failed unlock exits 0" 0 "$rc"
case "$out" in *"unlock failed"*) ok "failed unlock is logged" ;; *) bad "failed unlock line" "$out" ;; esac
out=$(unlock); n=$(wc -l < "$T/diskutil.calls" | tr -d ' ')
eq "a failed unlock backs off (one attempt)" 1 "$n"
case "$out" in *"backing off"*) ok "backoff is logged" ;; *) bad "backoff line" "$out" ;; esac
rm "$T/unlock-fails"

# --- the check: silent while unattached, WARN (rc 2) never a failure otherwise ---
chk() { bash "$HERE/external-volume-check.sh"; }
cfg false null; rmvol
out=$(chk); rc=$?; eq "check silent while unattached" "" "$out"; eq "check rc 0 while unattached" 0 "$rc"
cfg true null; mkvol
out=$(chk); rc=$?; eq "check present rc" 0 "$rc"; eq "check present line" "external volume present" "$out"
rmvol; out=$(chk); rc=$?; eq "check absent is WARN (2)" 2 "$rc"
case "$out" in "external volume absent"*) ok "check absent line" ;; *) bad "check absent line" "$out" ;; esac
echo locked > "$T/mode"; chk >/dev/null; eq "check locked is WARN (2)" 2 $?

# --- no code path formats, erases or converts a volume ---
bad_verbs='eraseDisk|eraseVolume|reformat|partitionDisk|deleteVolume|deleteContainer|apfs (convert|encryptVolume|decryptVolume|addVolume|resizeContainer)|newfs|mkfs|diskutil[^#]*(secureErase|zeroDisk|randomDisk)'
if grep -nEi "$bad_verbs" "$GATE" "$UNLOCK" "$HERE/external-volume-check.sh" | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' | grep -q .; then
  bad "a script names a destructive diskutil verb" "$(grep -nEi "$bad_verbs" "$GATE" "$UNLOCK" "$HERE/external-volume-check.sh")"
else ok "no destructive diskutil verb in the gate, the unlock job or the check"; fi

echo ""; echo "volume-gate.test.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
