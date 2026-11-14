#!/usr/bin/env bash
# spotlight-check — Spotlight indexing stays off on every volume of the dev host. docs/spotlight.md has the why and the undo.
#
#   spotlight-check.sh check        read-only; exit 0 = every volume reports indexing disabled, 1 = one has it on (or the
#                                   state is unreadable); one line naming the volumes
#   spotlight-check.sh load [SECS]  the Spotlight and file-event daemons' CPU as a share of one core over SECS (default 60)
#
# The owner switched it off with `sudo mdutil -a -i off` (2026-11-14). A macOS update can turn it back on, so the heartbeat
# runs `check`. Fixing it is that same command, which needs the owner's sudo (an Errand, never a sudoers rule).
#
# Overrides (tests): MDUTIL_BIN PS_BIN SPOTLIGHT_SLEEP_BIN.
# bash 3.2 (the heartbeat hands us Apple's /bin/bash).
set -uo pipefail

MDUTIL_BIN="${MDUTIL_BIN:-/usr/bin/mdutil}"
PS_BIN="${PS_BIN:-/bin/ps}"
SLEEP_BIN="${SPOTLIGHT_SLEEP_BIN:-/bin/sleep}"

cmd_check() {
  local out on
  out=$("$MDUTIL_BIN" -sa 2>/dev/null) || { echo "spotlight: mdutil -sa failed, indexing state unknown"; return 1; }
  # mdutil -sa prints a "<volume>:" line, then "\tIndexing enabled." / "\tIndexing disabled." / "\tIndexing and searching disabled."
  if ! printf '%s\n' "$out" | grep -q 'Indexing .*disabled'; then
    echo "spotlight: mdutil -sa gave no readable state"; return 1
  fi
  on=$(printf '%s\n' "$out" | awk '/^[^\t].*:$/ { v = $0; sub(/:$/, "", v) } /Indexing enabled/ { printf "%s%s", (n++ ? ", " : ""), v }')
  if [ -n "$on" ]; then
    echo "spotlight indexing is ON for: $on (fix: sudo mdutil -a -i off, docs/spotlight.md)"
    return 1
  fi
  echo "spotlight indexing off on every volume"
}

# CPU seconds per process name over a window, from the accumulated cputime column, so a bursty daemon is read over the
# whole window rather than at one instant. [dd-]hh:mm:ss.cc and mm:ss.cc both occur.
snap() {
  "$PS_BIN" -Ao pid=,cputime=,comm= | awk '{
    n = split($2, a, /[-:.]/); s = 0
    if (n == 3) s = a[1] * 60 + a[2] + a[3] / 100
    else if (n == 4) s = a[1] * 3600 + a[2] * 60 + a[3] + a[4] / 100
    else if (n == 5) s = a[1] * 86400 + a[2] * 3600 + a[3] * 60 + a[4] + a[5] / 100
    m = $3; for (i = 4; i <= NF; i++) m = m " " $i; sub(/.*\//, "", m); print $1, s, m }'
}

cmd_load() {
  local w="${1:-60}" a b
  a=$(mktemp); b=$(mktemp); trap 'rm -f "$a" "$b"' RETURN
  snap > "$a"; "$SLEEP_BIN" "$w"; snap > "$b"
  awk -v W="$w" 'NR == FNR { t[$1] = $2; next }
    $1 in t { g[$3] += $2 - t[$1] }
    END { for (k in g) if (k ~ /^(corespotlightd|fseventsd|mds|mds_stores|mdworker_shared|managedcorespotlightd|spotlightknowledged|spotlightknowledged\.updater)$/) printf "%6.1f%% %s\n", g[k] / W * 100, k }' "$a" "$b" | sort -rn
  echo "load: $(uptime | sed 's/.*load averages*: //')"
}

case "${1:-}" in
  check) cmd_check ;;
  load) cmd_load "${2:-60}" ;;
  *) echo "usage: spotlight-check.sh check|load [SECS]" >&2; exit 64 ;;
esac
