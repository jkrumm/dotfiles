#!/usr/bin/env bash
set -u
# Hermetic test for scripts/ext-mirror-check.sh: the local stamps decide, the volume is never read.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$HERE/ext-mirror-check.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/ext-mirror-check-test.XXXXXX")" || exit 2
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; fail=$((fail + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
has() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "[$3] lacks [$2]" ;; esac; }

NOW=1800000000
iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
printf '{"name":"EXT","sentinel":".volume-gate","attached":false}\n' > "$T/off.json"
printf '{"name":"EXT","sentinel":".volume-gate","attached":true}\n' > "$T/on.json"
export EXT_MIRROR_STATE_DIR="$T/state" EXT_MIRROR_CHECK_NOW="$NOW"
check() { VOLUME_GATE_CONFIG="$T/$1.json" bash "$CHECK"; }
stamps() { mkdir -p "$T/state"; printf '{"ssd":"%s","fuji":"%s","videos":"%s"}\n' "$(iso "$1")" "$(iso "$2")" "$(iso "$3")" > "$T/state/last-ok.json"; }

out=$(check off); eq "attached=false: silent, exit 0" "0 " "$? $out"
[ ! -e "$T/state" ] && ok "attached=false: writes nothing" || bad "attached=false created the state dir"

stamps $((NOW - 3600)) $((NOW - 7200)) $((NOW - 10 * 3600))
out=$(check on); rc=$?
eq "fresh stamps: exit 0" 0 "$rc"; has "fresh stamps: ok line with the oldest age" "oldest 10 h" "$out"

stamps $((NOW - 35 * 3600)) $((NOW - 3600)) $((NOW - 3600))
out=$(check on); eq "35 h is inside the limit" 0 "$?"

stamps $((NOW - 3600)) $((NOW - 3600)) $((NOW - 37 * 3600))
out=$(check on); rc=$?
eq "37 h: FAIL, exit 1" 1 "$rc"; has "the stale share is named with its age" "videos 37 h (last clean sync)" "$out"
case "$out" in *ssd*|*fuji*) bad "only the stale share is named" "$out" ;; *) ok "only the stale share is named" ;; esac

STORAGE_MIRROR_MAX_AGE_HOURS=48 check on >/dev/null; eq "the limit is STORAGE_MIRROR_MAX_AGE_HOURS" 0 "$?"

# no stamp at all: the full limit from the first time the check saw it, then FAIL
rm -rf "$T/state"
out=$(check on); rc=$?
eq "no stamps yet: grace from the first sighting" 0 "$rc"; [ -f "$T/state/watching-since" ] && ok "first sighting recorded" || bad "no watching-since"
out=$(EXT_MIRROR_CHECK_NOW=$((NOW + 37 * 3600)) check on); rc=$?
eq "no stamps after 37 h: FAIL" 1 "$rc"; has "...naming all three, never synced" "ssd 37 h (never synced clean since this check began), fuji 37 h" "$out"

# a stamp the check cannot read is not a pass
printf 'not json' > "$T/state/last-ok.json"
out=$(EXT_MIRROR_CHECK_NOW=$((NOW + 37 * 3600)) check on); eq "an unreadable stamp file is stale, not green" 1 "$?"

# the volume is never read: a state with no volume anywhere answers from the stamps alone
stamps "$NOW" "$NOW" "$NOW"; out=$(VOLUME_GATE_DISKUTIL=/usr/bin/false check on); eq "answers without the volume" 0 "$?"

printf '\next-mirror-check.test.sh: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
