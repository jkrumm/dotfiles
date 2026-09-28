#!/usr/bin/env bash
# swapout-rate — check_swapouts for devhost-health-check.sh.
#
# Sourceable, no side effects on load, bash 3.2 (launchd hands the heartbeat
# Apple's /bin/bash). Reads these globals, every one overridable so the test can
# drive it over a scratch dir and a stubbed sysctl:
#
#   STATE_DIR                 where the last cumulative swapout count is remembered
#   SWAPOUT_MB_PER_300S_MAX   delta that pages (default 2048 = 2 GiB, in the caller)
#   SYSCTL_BIN AWK_BIN
#
# WHY A RATE, AND WHY IT IS THE CAUSE-AGNOSTIC SIGNAL. On 2026-09-27 a Claude
# pane's memory storm swapped for eight hours while every other memory signal
# lied at once. Pressure sat at level 2 — non-lethal, and since 1c33c67 graded
# WARN (rc=2, never pages) — so it short-circuited check_memory's swap-percent
# gate and the storm never paged; the pct gate only fired later, on the settled
# level-1 reading, i.e. as a false positive on a host that was already
# recovering. What actually separated the storm from quiet was the SWAPOUT RATE:
# 19-107 GiB per 300 s window against 0-0.9 GiB idle. That is agnostic to which
# process caused it, so it also subsumes the leaked-child case check_runaways
# cannot see (that check needs PPID 1, high accumulated CPU and a SourceRoot
# cwd — a hung Claude-pane child has none of the three).
#
# The counter `vm.compressor.swapper.swapouts_total` is cumulative since boot, so
# the alertable fact is its DELTA — exactly like check_launchd_restarts' `runs`.
# It counts PAGES, so multiply by hw.pagesize for bytes. A reboot (or any counter
# reset) makes it fall; that is a re-seed, never a page.
#
# EVERY state write — creating the state directory included — is asserted, never
# swallowed with `|| true`. That swallow is the other door into the blindness the
# unreadable-counter guard above closes: an unwritable STATE_DIR means no state
# file is ever written, so every later run takes the seed branch and returns 0 —
# "seeded" for ever, and a storm that can never page again. The same failure on
# the delta path is the mirror image (a stale reading grows the delta until it
# pages a healthy host). Neither is worth reporting as healthy, so both FAIL.
swapouts_persist() {
  { printf '%s\n' "$2" > "$1.tmp"; } 2>/dev/null \
    && /bin/mv -f "$1.tmp" "$1" 2>/dev/null
}

check_swapouts() {
  local pagesize now_pages prev state_file delta_mb
  pagesize=$("$SYSCTL_BIN" -n hw.pagesize 2>/dev/null) || pagesize=""
  now_pages=$("$SYSCTL_BIN" -n vm.compressor.swapper.swapouts_total 2>/dev/null) || now_pages=""
  case "$pagesize" in ''|*[!0-9]*) pagesize="";; esac
  case "$now_pages" in ''|*[!0-9]*) now_pages="";; esac
  # An unreadable counter is a BLIND guard, not a healthy host — the same call
  # check_memory makes on an unreadable sysctl, and failing loud is the only way
  # the gap itself becomes visible.
  [[ -n "$pagesize" && -n "$now_pages" ]] \
    || { echo "swapouts: sysctl unreadable (pagesize=${pagesize:-?} swapouts=${now_pages:+set})"; return 1; }

  state_file="$STATE_DIR/swapouts"
  # Creating the directory is the first state write; an unwritable parent must
  # fail here, not be swallowed and then re-detected as a write failure below —
  # either way it is a blind state, so it fails loud like the guards that follow.
  /bin/mkdir -p "$STATE_DIR" 2>/dev/null \
    || { echo "swapouts: cannot create $STATE_DIR — state is blind, a storm can never page"; return 1; }
  prev=$(cat "$state_file" 2>/dev/null) || prev=""
  case "$prev" in ''|*[!0-9]*) prev="";; esac

  # No usable previous reading — first run, a malformed file, or a counter that
  # ran BACKWARDS across a reboot. Seed and move on: inventing a comparison
  # against zero would page once for every boot.
  if [[ -z "$prev" ]] || (( now_pages < prev )); then
    swapouts_persist "$state_file" "$now_pages" \
      || { echo "swapouts: cannot write $state_file — state is blind, a storm can never page"; return 1; }
    echo "swapouts seeded (${now_pages} pages)"
    return 0
  fi

  # Cumulative pages -> MiB since the last 300 s reading. The division is
  # fractional and bash 3.2 has no floats, so awk does it (as check_memory's
  # swap parser does) — and it rounds UP, because the comparison below is
  # `> MAX`. Truncating the conversion (plain `printf "%d", d * ps / 1048576`)
  # put every delta in (2 GiB, 2 GiB + 1 MiB] at exactly `2048M`: one 16 KiB
  # page past the line read as healthy, so the gate could only ever fire a whole
  # MiB late. Integer ceiling through the +1048575 numerator — exact in awk's
  # doubles, no float comparison. Proof: `make swapout-rate-test`.
  # shellcheck disable=SC2016  # the awk body is single-quoted on purpose
  delta_mb=$("$AWK_BIN" -v d="$(( now_pages - prev ))" -v ps="$pagesize" \
    'BEGIN { printf "%d", int((d * ps + 1048575) / 1048576) }') || delta_mb=""
  [[ -n "$delta_mb" ]] || { echo "swapouts: could not compute the delta"; return 1; }

  # Persist the new reading BEFORE deciding: an unreadable state dir must not
  # leave the same delta to be compared — and paged — again on the next run.
  # Asserted for the same reason as the seed above: a run whose state did not
  # land cannot say anything about the next one, and only "I cannot tell" is
  # honest here.
  swapouts_persist "$state_file" "$now_pages" \
    || { echo "swapouts: cannot write $state_file — state is blind, a storm can never page"; return 1; }

  (( delta_mb <= SWAPOUT_MB_PER_300S_MAX )) \
    || { echo "swapouts ${delta_mb}M/300s (max ${SWAPOUT_MB_PER_300S_MAX}M) — something is thrashing the swap file"; return 1; }
  echo "swapouts ok (${delta_mb}M/300s)"
}
