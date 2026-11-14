#!/usr/bin/env bash
# spotlight-fence — switch the Data volume's Spotlight file index off on the dev host. docs/spotlight.md has the measurements.
#
#   spotlight-fence.sh apply        `sudo -n mdutil -i off /System/Volumes/Data` through the sudoers rule; says so when it is missing
#   spotlight-fence.sh check        read-only; exit 0 = off, 2 = on (WARN in the heartbeat), one line
#   spotlight-fence.sh load [SECS]  the Spotlight and file-event daemons' CPU as a share of one core over SECS (default 60)
#
# WHY THE WHOLE VOLUME, not "the worktree directories" (measured 2026-11-14, macOS 26.7.2, docs/spotlight.md):
#   - ~/SourceRoot, ~/IuRoot and every dot-directory (.claude/worktrees, .software-factory/releases) were never indexed.
#   - `.metadata_never_index` inside a directory is NOT honoured; only a `*.noindex` directory NAME is, which cannot be
#     applied to .claude/worktrees. What Spotlight does index is whatever else churns (~/orb, ~/cache, ~/Library), and no
#     per-directory fence survives a new directory without root. Nothing on the mini searches files, so the index goes off.
#   - Not fenceable: the Spotlight Knowledge updater (corespotlightd's peak load). `launchctl disable` does not hold (it is
#     started again over Mach IPC) and SIP refuses bootout.
#
# Overrides (tests): MDUTIL_BIN SUDO_BIN PS_BIN SPOTLIGHT_SLEEP_BIN.
# bash 3.2 (the heartbeat hands us Apple's /bin/bash).
set -uo pipefail

MDUTIL_BIN="${MDUTIL_BIN:-/usr/bin/mdutil}"
SUDO_BIN="${SUDO_BIN:-/usr/bin/sudo}"
PS_BIN="${PS_BIN:-/bin/ps}"
SLEEP_BIN="${SPOTLIGHT_SLEEP_BIN:-/bin/sleep}"
DATA_VOLUME="/System/Volumes/Data"

# on | off | unknown: an mdutil that fails or says something else is neither, and must not read as "fenced".
index_state() {
  local out
  out=$("$MDUTIL_BIN" -s "$DATA_VOLUME" 2>/dev/null) || { echo unknown; return; }
  case "$out" in
    *"Indexing enabled"*) echo on ;;
    *"Indexing disabled"*|*"Indexing and searching disabled"*) echo off ;;
    *) echo unknown ;;
  esac
}

cmd_check() {
  case "$(index_state)" in
    off) echo "spotlight fenced: file index of $DATA_VOLUME is off" ;;
    on) echo "spotlight: file index of $DATA_VOLUME is on (fix: make spotlight-fence)"; return 2 ;;
    *) echo "spotlight: mdutil -s $DATA_VOLUME gave no readable state"; return 2 ;;
  esac
}

cmd_apply() {
  if [ "$(index_state)" != off ]; then
    # No `sudo -n -l <cmd>` probe: it exits 0 for a user whose full-sudo rule needs a password (measured). Try the command.
    if ! "$SUDO_BIN" -n "$MDUTIL_BIN" -i off "$DATA_VOLUME" >/dev/null 2>&1; then
      echo "  · file index is not off and the sudoers rule is missing: make spotlight-sudoers (needs sudo; the owner runs it through ask-human)"
      return 1
    fi
  fi
  if [ "$(index_state)" != off ]; then echo "  ✗ file index of $DATA_VOLUME is not off"; return 1; fi
  echo "  ✓ file index of $DATA_VOLUME is off"
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
  apply) cmd_apply ;;
  check) cmd_check ;;
  load) cmd_load "${2:-60}" ;;
  *) echo "usage: spotlight-fence.sh apply|check|load [SECS]" >&2; exit 64 ;;
esac
