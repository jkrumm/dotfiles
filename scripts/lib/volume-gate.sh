#!/usr/bin/env bash
# volume-gate — the gate every job passes before it touches the external volume (docs/external-ssd.md).
#
# launchd has no mount dependency, so a volume that is absent, locked or half-mounted at boot or after a USB
# hiccup is every dependent's own problem. The gate makes it one answer:
#   present  = mounted, unlocked, and the sentinel file at the volume root is readable
#   anything else = ONE line "skipped: volume <state>", exit 0, nothing run, nothing created,
#   never a fall back to the internal disk (a job that writes to a missing path would fill the boot disk).
# The mount point is read from diskutil at run time by the volume's NAME (config/external-volume.json);
# it is never written into a tracked file. This file reads only; it formats, erases or converts nothing.
#
# CLI (what a LaunchAgent job calls):
#   volume-gate.sh run -- <cmd...>   run <cmd> with $VOLUME_ROOT set, or skip as above. A command that fails
#                                    because the volume left mid-run is also a skip (exit 0), any other rc passes through
#   volume-gate.sh state             print the state word (unattached|absent|locked|unreadable|present), exit 0
#   volume-gate.sh root              print the mount point and exit 0 when present; exit 1, print nothing otherwise
# Sourced: volume_gate_state sets VG_STATE (and VG_ROOT when mounted); volume_gate_skip_line prints the skip line.
#
# BASH 3.2 (LaunchAgent jobs run on Apple's /bin/bash).

VG_DOTFILES_DIR="${DOTFILES_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
VG_CONFIG="${VOLUME_GATE_CONFIG:-$VG_DOTFILES_DIR/config/external-volume.json}"
VG_DISKUTIL="${VOLUME_GATE_DISKUTIL:-/usr/sbin/diskutil}"
# A sentinel read blocks (it does not fail) while a TCC Removable Volumes prompt waits on a screen nobody watches.
VG_READ_TIMEOUT="${VOLUME_GATE_READ_TIMEOUT:-5}"

VG_STATE=""
VG_ROOT=""
VG_NAME=""
VG_DEVICE=""   # read by external-volume-unlock.sh

vg_cfg() { jq -r --arg k "$1" '.[$k] // empty' "$VG_CONFIG" 2>/dev/null; }

# One key of a plist on stdin, empty when absent.
vg_plist_key() { /usr/bin/plutil -extract "$1" raw -o - - 2>/dev/null; }

# volume_gate_probe: diskutil state only (unattached|absent|locked|mounted), no file on the volume is touched,
# so a caller that never reads from it (the unlock job) needs no TCC grant. Sets VG_NAME, VG_DEVICE, VG_ROOT.
volume_gate_probe() {
  VG_STATE=""; VG_ROOT=""; VG_DEVICE=""
  [ "$(vg_cfg attached)" = "true" ] || { VG_STATE=unattached; return 0; }
  VG_NAME=$(vg_cfg name)
  [ -n "$VG_NAME" ] || { VG_STATE=absent; return 0; }
  local info
  info=$("$VG_DISKUTIL" info -plist "$VG_NAME" 2>/dev/null) || info=""
  [ -n "$info" ] || { VG_STATE=absent; return 0; }
  [ "$(printf '%s' "$info" | vg_plist_key Error)" != "true" ] || { VG_STATE=absent; return 0; }
  # shellcheck disable=SC2034  # read by the unlock job
  VG_DEVICE=$(printf '%s' "$info" | vg_plist_key DeviceIdentifier)
  local mp locked fv
  mp=$(printf '%s' "$info" | vg_plist_key MountPoint)
  locked=$(printf '%s' "$info" | vg_plist_key Locked)
  fv=$(printf '%s' "$info" | vg_plist_key FileVault)
  if [ "$locked" = "true" ] || { [ "$fv" = "true" ] && [ -z "$mp" ]; }; then VG_STATE=locked; return 0; fi
  if [ -z "$mp" ] || [ ! -d "$mp" ]; then VG_STATE=absent; return 0; fi
  VG_ROOT="$mp"; VG_STATE=mounted
}

# volume_gate_state: probe, then the bounded sentinel read. Sets VG_STATE to
# unattached|absent|locked|unreadable|present.
volume_gate_state() {
  volume_gate_probe
  [ "$VG_STATE" = mounted ] || return 0
  local sentinel; sentinel=$(vg_cfg sentinel)
  [ -n "$sentinel" ] || { VG_STATE=unreadable; return 0; }
  local file="$VG_ROOT/$sentinel" pid waited=0 max=$((VG_READ_TIMEOUT * 10))
  ( exec cat "$file" >/dev/null 2>&1 ) &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$max" ]; then
      kill -KILL "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
      VG_STATE=unreadable; return 0   # frozen: a pending Removable Volumes prompt, or a hung USB device
    fi
    sleep 0.1; waited=$((waited + 1))
  done
  if wait "$pid"; then VG_STATE=present; return 0; fi
  # The read failed: a volume that left between the probe and the read is absent; a mounted one without the file is not ours.
  if [ -d "$VG_ROOT" ]; then VG_STATE=unreadable; else VG_STATE=absent; fi
}

volume_gate_skip_line() {
  case "$VG_STATE" in
    unattached) echo "skipped: volume not attached" ;;
    *) echo "skipped: volume $VG_STATE" ;;
  esac
}

volume_gate_run() {
  volume_gate_state
  if [ "$VG_STATE" != present ]; then volume_gate_skip_line; return 0; fi
  local root="$VG_ROOT" rc=0
  VOLUME_ROOT="$root" "$@" || rc=$?
  [ "$rc" -ne 0 ] || return 0
  # The command failed. If the volume is gone now, the volume failed it, not the job.
  volume_gate_state
  if [ "$VG_STATE" != present ]; then echo "skipped: volume vanished during run"; return 0; fi
  return "$rc"
}

volume_gate_main() {
  case "${1:-}" in
    run)
      shift
      [ "${1:-}" != "--" ] || shift
      [ "$#" -gt 0 ] || { echo "usage: volume-gate.sh run -- <cmd...>" >&2; return 2; }
      volume_gate_run "$@" ;;
    state) volume_gate_state; echo "$VG_STATE" ;;
    root) volume_gate_state; [ "$VG_STATE" = present ] || return 1; echo "$VG_ROOT" ;;
    *) echo "usage: volume-gate.sh run -- <cmd...> | state | root" >&2; return 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then volume_gate_main "$@"; fi
