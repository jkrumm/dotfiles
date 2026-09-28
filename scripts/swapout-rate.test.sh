#!/usr/bin/env bash
# swapout-rate.test — proves check_swapouts' delta/reset classification against a
# stubbed sysctl and a SCRATCH state dir. Runs on either Mac, touches no real
# heartbeat state.
#
# The facts worth asserting are the ones that decide whether a page fires: a
# first run seeds; a quiet delta is ok; the threshold is inclusive; a delta over
# it pages; a counter that fell (reboot) re-seeds instead of inventing a phantom
# rate; the new reading is persisted even when it pages, so one storm is not
# paged twice; and an unreadable counter fails rather than reporting a blind
# host healthy.
set -uo pipefail

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/swapout-rate.sh"
[ -f "$LIB" ] || { echo "✗ $LIB not found"; exit 1; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/swapout-rate-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

PAGESIZE=16384          # one page is 16 KiB
MIB_PER_PAGE=$(( 1048576 / PAGESIZE ))   # pages per MiB == 64
echo "$PAGESIZE" > "$TMP/pagesize"

# Stub: `-n hw.pagesize` and `-n vm.compressor.swapper.swapouts_total`. The
# counter file is written per case; deleting it makes the counter unreadable.
cat > "$TMP/sysctl" <<EOF
#!/bin/sh
case "\$2" in
  hw.pagesize) cat "$TMP/pagesize" ;;
  vm.compressor.swapper.swapouts_total) cat "$TMP/swapouts_total" ;;
esac
EOF
chmod +x "$TMP/sysctl"

export STATE_DIR="$TMP/state"
export SWAPOUT_MB_PER_300S_MAX=2048
export SYSCTL_BIN="$TMP/sysctl"
export AWK_BIN=/usr/bin/awk
# shellcheck source=lib/swapout-rate.sh
source "$LIB"

fails=0
ok()  { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fails=$((fails + 1)); }

mib() { echo $(( $1 * MIB_PER_PAGE )); }   # $1 MiB -> pages

# case NAME PREV NOW WANT_RC [NEEDLE]  — PREV empty = no state file at all.
case_() {
  local name=$1 prev=$2 now=$3 want=$4 needle=${5:-} out rc
  rm -rf "$STATE_DIR"; mkdir -p "$STATE_DIR"
  [ -n "$prev" ] && printf '%s\n' "$prev" > "$STATE_DIR/swapouts"
  printf '%s\n' "$now" > "$TMP/swapouts_total"
  rc=0; out=$(check_swapouts) || rc=$?
  if [ "$rc" = "$want" ] && [[ "$out" == *"$needle"* ]]; then
    ok "$name → rc=$rc ($out)"
  else
    bad "$name → got rc=$rc out='$out', want rc=$want containing '$needle'"
  fi
}

echo "swapout-rate classification"
case_ "no state file → seed"               ""     1000                 0 "seeded"
case_ "quiet (0.5 GiB)"                    "$(mib 1000)" $(( $(mib 1000) + $(mib 512) ))  0 "ok"
case_ "exactly at threshold (2 GiB)"       "$(mib 1000)" $(( $(mib 1000) + $(mib 2048) )) 0 "ok"
case_ "just over threshold (2049 MiB)"     "$(mib 1000)" $(( $(mib 1000) + $(mib 2049) )) 1 "M/300s"
case_ "storm (16 GiB)"                     "$(mib 1000)" $(( $(mib 1000) + $(mib 16384) )) 1 "M/300s"
case_ "no change (0 MiB)"                  "$(mib 5000)" "$(mib 5000)"           0 "ok (0M/300s)"
case_ "counter fell (reboot) → re-seed"    "$(mib 9000)" 10                   0 "seeded"
case_ "malformed state → re-seed"          "garbage"     1000                 0 "seeded"

echo "state persistence"
case_ "storm pages" "$(mib 1000)" $(( $(mib 1000) + $(mib 16384) )) 1 >/dev/null
got=$(cat "$STATE_DIR/swapouts" 2>/dev/null)
[ "$got" = "$(( $(mib 1000) + $(mib 16384) ))" ] \
  && ok "new reading persisted on the paging run" \
  || bad "state after the paging run = '$got'"
rc=0; out=$(check_swapouts) || rc=$?
[ "$rc" = 0 ] && [[ "$out" == *"ok (0M/300s)"* ]] \
  && ok "same counter next run → rc=0 (a storm is not paged twice)" \
  || bad "second run → rc=$rc out='$out'"

echo "blind guard fails loud"
rm -rf "$STATE_DIR"; mkdir -p "$STATE_DIR"; printf '%s\n' "$(mib 1000)" > "$STATE_DIR/swapouts"
rm -f "$TMP/swapouts_total"
rc=0; out=$(check_swapouts) || rc=$?
[ "$rc" = 1 ] && [[ "$out" == *"unreadable"* ]] \
  && ok "counter unreadable → rc=1 ($out)" || bad "counter unreadable → rc=$rc out='$out'"

rm -f "$TMP/pagesize"; printf '%s\n' 1000 > "$TMP/swapouts_total"
rc=0; out=$(check_swapouts) || rc=$?
[ "$rc" = 1 ] && [[ "$out" == *"unreadable"* ]] \
  && ok "pagesize unreadable → rc=1 ($out)" || bad "pagesize unreadable → rc=$rc out='$out'"

echo
[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed"; exit 1
