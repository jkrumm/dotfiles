#!/usr/bin/env bash
# launchd-restarts.test — proves check_launchd_restarts' classification against a
# stubbed `launchctl print` and a SCRATCH state/marker dir. Runs on either Mac,
# touches no real launchd job and no real heartbeat state.
#
# The facts worth asserting are the ones that decide whether a page fires: a
# MARKED clean restart is report-only; an UNMARKED clean exit 0 still pages (the
# crash-loop review finding on PR #7); a kill still pages; a marker older than
# the window excuses nothing; a crash loop after a deploy outnumbers its marker;
# a marker never launders a kill; and a bump consumes exactly its own lines.
set -uo pipefail

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/launchd-restarts.sh"
[ -f "$LIB" ] || { echo "✗ $LIB not found"; exit 1; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/launchd-restarts-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

LABEL=com.example.svc
PLIST="$TMP/$LABEL.plist"
: > "$PLIST"

# Stub: prints $TMP/print for any `print gui/<uid>/<label>`.
cat > "$TMP/launchctl" <<EOF
#!/bin/sh
[ "\$1" = print ] && cat "$TMP/print"
EOF
chmod +x "$TMP/launchctl"

export DEVHOST_DELIBERATE_RESTART_DIR="$TMP/markers"
export DEVHOST_DELIBERATE_RESTART_WINDOW=600
export STATE_DIR="$TMP/state"
export LAUNCHCTL_BIN="$TMP/launchctl"
export AWK_BIN=/usr/bin/awk
export DATE_BIN=/bin/date
export LAUNCHD_KEEPALIVE="$LABEL|$PLIST"
# shellcheck source=lib/launchd-restarts.sh
source "$LIB"

fails=0
ok()  { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fails=$((fails + 1)); }

# launchctl print shape: runs, then either a signal or an exit code.
fake_print() {
  { echo "$LABEL = {"; echo "	runs = $1"
    [ -n "$2" ] && echo "	last terminating signal = $2"
    [ -n "$3" ] && echo "	last exit code = $3"
    echo "}"; } > "$TMP/print"
}

# case NAME PREV RUNS SIG EXIT MARKER_AGES WANT_RC [WANT_SUBSTRING]
# MARKER_AGES: space-separated seconds-ago, one marker line each ("" = none).
case_() {
  local name=$1 prev=$2 runs=$3 sig=$4 code=$5 ages=$6 want=$7 needle=${8:-} now a out rc
  rm -rf "$STATE_DIR" "$DEVHOST_DELIBERATE_RESTART_DIR"
  mkdir -p "$STATE_DIR" "$DEVHOST_DELIBERATE_RESTART_DIR"
  printf '%s %s\n' "$LABEL" "$prev" > "$STATE_DIR/launchd-runs"
  now=$(date +%s)
  for a in $ages; do echo $((now - a)) >> "$DEVHOST_DELIBERATE_RESTART_DIR/$LABEL"; done
  fake_print "$runs" "$sig" "$code"
  rc=0; out=$(check_launchd_restarts) || rc=$?
  if [ "$rc" = "$want" ] && [[ "$out" == *"$needle"* ]]; then
    ok "$name → rc=$rc ($out)"
  else
    bad "$name → got rc=$rc out='$out', want rc=$want containing '$needle'"
  fi
}

echo "launchd-restarts classification"
case_ "marked exit-0 restart"                5 6 ""               0 "120"    0 "marked deliberate"
case_ "unmarked exit-0 restart"              5 6 ""               0 ""       1 "exit 0"
case_ "Killed: 9, unmarked"                  5 6 "Killed: 9"      "" ""      1 "Killed: 9"
case_ "exit-0, marker outside 10-min window" 5 6 ""               0 "900"    1 "exit 0"
case_ "crash loop after a deploy (+3, 1 mark)" 5 8 ""             0 "120"    1 "only 1 marked"
case_ "two deploys in one cycle (+2, 2 marks)" 5 7 ""             0 "240 60" 0 "marked deliberate"
case_ "non-zero exit, unmarked"              5 6 ""               78 ""      1 "exit 78"
case_ "Terminated: 15, unmarked (unchanged)" 5 6 "Terminated: 15" "" ""     0 "SIGTERM — deliberate"
case_ "Terminated: 15, marked"               5 6 "Terminated: 15" "" "60"   0 "marked deliberate"
case_ "Killed: 9 despite a marker"           5 6 "Killed: 9"      "" "60"   1 "Killed: 9, marker ignored"
case_ "no bump, history shown"               6 6 ""               0 ""       0 "history: svc=6(exit 0)"

echo "marker lifecycle"
case_ "consumed by the bump it excused" 5 6 "" 0 "120" 0
[ -e "$DEVHOST_DELIBERATE_RESTART_DIR/$LABEL" ] && bad "marker left behind after its bump" || ok "marker removed after its bump"

case_ "surplus marker (+1, 2 marks)" 5 6 "" 0 "300 30" 0 "marked deliberate"
[ "$(wc -l < "$DEVHOST_DELIBERATE_RESTART_DIR/$LABEL" | tr -d ' ')" = 1 ] \
  && ok "only the oldest line consumed, the pending one kept" \
  || bad "surplus marker not kept — a second deploy's pending marker was destroyed"

case_ "Killed: 9 with a marker" 5 6 "Killed: 9" "" "60" 1
[ -e "$DEVHOST_DELIBERATE_RESTART_DIR/$LABEL" ] && bad "marker survived a bump it did not excuse" || ok "marker consumed by the kill's bump too"

# Seed run: no prior reading — nothing compared, a fresh marker waits for its bump.
rm -rf "$STATE_DIR" "$DEVHOST_DELIBERATE_RESTART_DIR"; mkdir -p "$DEVHOST_DELIBERATE_RESTART_DIR"
date +%s > "$DEVHOST_DELIBERATE_RESTART_DIR/$LABEL"; fake_print 9 "" 0
rc=0; out=$(check_launchd_restarts) || rc=$?
[ "$rc" = 0 ] && [ -e "$DEVHOST_DELIBERATE_RESTART_DIR/$LABEL" ] && grep -q "^$LABEL 9$" "$STATE_DIR/launchd-runs" \
  && ok "seed run → rc=0, state seeded, marker kept" \
  || bad "seed run → rc=$rc out='$out'"

# State write fails → the marker must NOT be consumed, or next run re-sees the
# same bump with its marker gone and pages it.
rm -rf "$STATE_DIR" "$DEVHOST_DELIBERATE_RESTART_DIR"; mkdir -p "$STATE_DIR" "$DEVHOST_DELIBERATE_RESTART_DIR"
printf '%s 5\n' "$LABEL" > "$STATE_DIR/launchd-runs"; date +%s > "$DEVHOST_DELIBERATE_RESTART_DIR/$LABEL"
fake_print 6 "" 0; chmod 555 "$STATE_DIR"
rc=0; out=$(check_launchd_restarts) || rc=$?
chmod 755 "$STATE_DIR"
[ "$rc" = 0 ] && [ -e "$DEVHOST_DELIBERATE_RESTART_DIR/$LABEL" ] \
  && ok "state write failed → marker kept for the re-seen bump" \
  || bad "state write failed → rc=$rc, marker $( [ -e "$DEVHOST_DELIBERATE_RESTART_DIR/$LABEL" ] && echo kept || echo CONSUMED)"

echo "per-label isolation"
# Two services, only one marked, both bumped: the marker belongs to its label.
OTHER=com.example.other
: > "$TMP/$OTHER.plist"
cat > "$TMP/launchctl" <<EOF2
#!/bin/sh
[ "\$1" = print ] || exit 0
case "\$2" in */$OTHER) printf '\\truns = 3\\n\\tlast exit code = 0\\n' ;; *) cat "$TMP/print" ;; esac
EOF2
LAUNCHD_KEEPALIVE="$LABEL|$PLIST
$OTHER|$TMP/$OTHER.plist"
rm -rf "$STATE_DIR" "$DEVHOST_DELIBERATE_RESTART_DIR"; mkdir -p "$STATE_DIR" "$DEVHOST_DELIBERATE_RESTART_DIR"
printf '%s 5\n%s 2\n' "$LABEL" "$OTHER" > "$STATE_DIR/launchd-runs"
date +%s > "$DEVHOST_DELIBERATE_RESTART_DIR/$LABEL"; fake_print 6 "" 0
rc=0; out=$(check_launchd_restarts) || rc=$?
[ "$rc" = 1 ] && [[ "$out" == "$OTHER restarted (2→3, exit 0); also $LABEL restarted (5→6, exit 0 — marked deliberate)" ]] \
  && ok "marked label report-only, unmarked sibling pages ($out)" \
  || bad "per-label → rc=$rc out='$out'"

case_ "fresh marker, no bump yet" 6 6 "" 0 "30" 0
[ -e "$DEVHOST_DELIBERATE_RESTART_DIR/$LABEL" ] && ok "fresh marker kept until its bump" || bad "fresh marker deleted before its bump"
case_ "stale marker, no bump" 6 6 "" 0 "900" 0
[ -e "$DEVHOST_DELIBERATE_RESTART_DIR/$LABEL" ] && bad "stale marker lingers" || ok "stale marker pruned"

echo
[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed"; exit 1
