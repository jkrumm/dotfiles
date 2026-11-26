#!/usr/bin/env bash
# Hermetic test for colima/mounts-check.sh: a temp mounts list, a fixture for the guest's /proc/mounts and a
# stub colima that cats it. Never the live VM.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail=0
ok() { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; fail=1; }

cat >"$t/colima" <<'STUB'
#!/bin/sh
# colima ssh -p <profile> -- cat /proc/mounts: the fixture, or a failure when MOUNTS_FIXTURE is unreadable.
cat "$MOUNTS_FIXTURE"
STUB
chmod +x "$t/colima"

cat >"$t/mounts" <<'EOF'
proc /proc proc rw,nosuid 0 0
lima-a /fake/home/IuRoot/epos-tool-athena virtiofs rw,relatime 0 0
lima-b /fake/home/IuRoot/worktrees/prometheus-dashboard virtiofs ro,relatime 0 0
vz-rosetta /mnt/lima-rosetta virtiofs rw,relatime 0 0
EOF
cat >"$t/list" <<'EOF'
# comment
~/IuRoot/epos-tool-athena rw
~/IuRoot/worktrees/prometheus-dashboard ro
EOF

check() { out=$(MOUNTS_FIXTURE="${fixture:-$t/mounts}" COLIMA_BIN="$t/colima" HOME=/fake/home "$here/mounts-check.sh" "$t/list" 2>&1); rc=$?; fixture=; }
expect() { # name, want exit, want substring
  check
  if [ "$rc" = "$2" ] && case "$out" in *"$3"*) true ;; *) false ;; esac; then ok "$1"; else bad "$1 (rc=$rc: $out)"; fi
}

expect "matching list and VM: exit 0" 0 ""

# shellcheck disable=SC2088  # the literal ~ is the point: mounts-check.sh expands it
printf '~/.local/state/new rw\n' >>"$t/list"
expect "a listed mount the VM has not applied fails, naming it" 1 "/fake/home/.local/state/new is not mounted"
sed -i '' '$d' "$t/list"

sed -i '' 's|^~/IuRoot/epos-tool-athena rw|~/IuRoot/epos-tool-athena ro|' "$t/list"
expect "a mode the VM does not run fails" 1 "/fake/home/IuRoot/epos-tool-athena is rw, the list says ro"
sed -i '' 's|^~/IuRoot/epos-tool-athena ro|~/IuRoot/epos-tool-athena rw|' "$t/list"

printf 'lima-c /fake/home/SourceRoot/old virtiofs ro,relatime 0 0\n' >>"$t/mounts"
expect "a mount under HOME the list no longer names fails" 1 "/fake/home/SourceRoot/old is mounted, the list does not name it"
sed -i '' '$d' "$t/mounts"

expect "vz-rosetta outside HOME is not compared" 0 ""

fixture="$t/missing" expect "an unreadable VM fails with the reason" 1 "unreadable"

printf '# nothing\n' >"$t/list"
expect "an empty list fails: every mount under HOME is unnamed" 1 "does not name it"

rm -f "$t/list"
expect "a missing list fails" 1 "is missing"

exit "$fail"
