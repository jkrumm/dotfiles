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
#   volume-gate.sh run [--skip-rc N] -- <cmd...>
#                                    run <cmd> with $VOLUME_ROOT set, or skip as above. A command that fails
#                                    because the volume left mid-run is also a skip (exit 0), any other rc passes through.
#                                    --skip-rc N: a skip exits N instead of 0, for a job that is retried and must not grade
#                                    green when nothing ran (docs/storage.md §EXT mirror)
#   volume-gate.sh state             print the state word (unattached|absent|locked|unreadable|present), exit 0
#   volume-gate.sh root              print the mount point and exit 0 when present; exit 1, print nothing otherwise
# Sourced: volume_gate_state sets VG_STATE (and VG_ROOT when mounted); volume_gate_skip_line prints the skip line.
#
# BASH 3.2 (LaunchAgent jobs run on Apple's /bin/bash).

VG_DOTFILES_DIR="${DOTFILES_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
VG_CONFIG="${VOLUME_GATE_CONFIG:-$VG_DOTFILES_DIR/config/external-volume.json}"
VG_DISKUTIL="${VOLUME_GATE_DISKUTIL:-/usr/sbin/diskutil}"
# A sentinel read blocks (it does not fail) while a TCC Removable Volumes prompt waits on a screen nobody watches, and it
# stalls on a host under heavy load or swap (2026-11-16: 38 samples in a row at load 5 to 29). A read that times out is
# tried VG_READ_ATTEMPTS times in all, so one slow read is not "unreadable"; a read that fails at once is not retried.
VG_READ_TIMEOUT="${VOLUME_GATE_READ_TIMEOUT:-5}"
VG_READ_ATTEMPTS="${VOLUME_GATE_READ_ATTEMPTS:-3}"
VG_DETAIL=""   # why the state is unreadable, for the one WARN line (load, the stalled reader's state)

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
  local file="$VG_ROOT/$sentinel" attempt=1
  VG_DETAIL=""
  while :; do
    vg_read_once "$file"
    case "$?" in
      0) VG_STATE=present; return 0 ;;
      1)  # the read failed: a volume that left between the probe and the read is absent; a mounted one without the file is not ours
        if [ -d "$VG_ROOT" ]; then VG_STATE=unreadable; else VG_STATE=absent; fi
        return 0 ;;
    esac
    # Frozen (rc 2): a pending Removable Volumes prompt, a hung USB device, or a host too busy to answer in time.
    if [ "$attempt" -ge "$VG_READ_ATTEMPTS" ]; then
      VG_STATE=unreadable
      VG_DETAIL="the read stalled ${attempt} x ${VG_READ_TIMEOUT}s${VG_STALL_INFO:+ ($VG_STALL_INFO)}"
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 1
  done
}

# vg_read_once <file>: 0 read, 1 the read failed, 2 no answer within VG_READ_TIMEOUT. Sets VG_STALL_INFO on a stall:
# the 1-minute load and the reader's process state (U = uninterruptible I/O wait), the two facts that tell a busy host from a
# prompt nobody answers. The stalled reader is killed and not waited for: in uninterruptible I/O wait it ignores the kill, and
# a `wait` on it would hang this gate with it.
vg_read_once() {
  local file="$1" pid waited=0 max=$((VG_READ_TIMEOUT * 10))
  VG_STALL_INFO=""
  ( exec cat "$file" >/dev/null 2>&1 ) &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$max" ]; then
      VG_STALL_INFO="load $(/usr/sbin/sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | awk '{print $1}'), reader state $(ps -o state= -p "$pid" 2>/dev/null | tr -d ' ')"
      kill -KILL "$pid" 2>/dev/null
      return 2
    fi
    sleep 0.1; waited=$((waited + 1))
  done
  wait "$pid" && return 0
  return 1
}

volume_gate_skip_line() {
  case "$VG_STATE" in
    unattached) echo "skipped: volume not attached" ;;
    *) echo "skipped: volume $VG_STATE${VG_DETAIL:+ ($VG_DETAIL)}" ;;
  esac
}

volume_gate_run() {
  local skip_rc=0
  if [ "${1:-}" = "--skip-rc" ]; then skip_rc="${2:-}"; shift 2; fi
  case "$skip_rc" in ''|*[!0-9]*) echo "usage: volume-gate.sh run [--skip-rc N] -- <cmd...>" >&2; return 2 ;; esac
  volume_gate_state
  if [ "$VG_STATE" != present ]; then volume_gate_skip_line; return "$skip_rc"; fi
  local root="$VG_ROOT" rc=0
  VOLUME_ROOT="$root" "$@" || rc=$?
  [ "$rc" -ne 0 ] || return 0
  # The command failed. If the volume is gone now, the volume failed it, not the job.
  volume_gate_state
  if [ "$VG_STATE" != present ]; then echo "skipped: volume vanished during run"; return "$skip_rc"; fi
  return "$rc"
}

volume_gate_main() {
  case "${1:-}" in
    run)
      shift
      local skip=()
      if [ "${1:-}" = "--skip-rc" ]; then skip=("$1" "${2:-}"); shift; [ "$#" -eq 0 ] || shift; fi
      [ "${1:-}" != "--" ] || shift
      [ "$#" -gt 0 ] || { echo "usage: volume-gate.sh run [--skip-rc N] -- <cmd...>" >&2; return 2; }
      volume_gate_run ${skip[@]+"${skip[@]}"} "$@" ;;
    state) volume_gate_state; echo "$VG_STATE" ;;
    root) volume_gate_state; [ "$VG_STATE" = present ] || return 1; echo "$VG_ROOT" ;;
    *) echo "usage: volume-gate.sh run -- <cmd...> | state | root" >&2; return 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then volume_gate_main "$@"; fi
