#!/usr/bin/env bash
set -u
# external-volume-unlock — the LaunchAgent job that unlocks the encrypted external volume when it is present but locked
# (docs/external-ssd.md §Unlock). Idempotent and bounded: mounted, absent or not attached = exit 0 without a word;
# locked = one unlock attempt, then a 15 minute back-off after a failure so a wrong passphrase is not hammered.
# The passphrase is a ref (config/external-volume.json passphraseRef, listed in dotfiles-private/headless.refs),
# resolved by `secrets-run read` and piped to diskutil's stdin: never argv, never `op` on the mini. A ref the cache lacks:
# `make secrets-reseal-request`. It reads diskutil state only, never a file on the volume (no TCC grant needed).
# It never formats, erases or converts anything; it only unlocks. BASH 3.2.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/volume-gate.sh
. "$HERE/lib/volume-gate.sh"

STATE_DIR="${EXTERNAL_VOLUME_STATE_DIR:-$HOME/.local/state/external-volume}"
SECRETS_RUN="${VOLUME_GATE_SECRETS_RUN:-secrets-run}"
BACKOFF_S="${EXTERNAL_VOLUME_BACKOFF:-900}"
UNLOCK_TIMEOUT="${EXTERNAL_VOLUME_UNLOCK_TIMEOUT:-30}"

# jobrun (the plist's wrapper) timestamps every line, so the message is bare.
say() { echo "$*"; }

volume_gate_probe
[ "$VG_STATE" = locked ] || exit 0

ref=$(vg_cfg passphraseRef)
[ -n "$ref" ] || { say "skipped: passphrase ref not set"; exit 0; }
[ -n "$VG_DEVICE" ] || { say "skipped: locked volume has no device identifier"; exit 0; }

mkdir -p "$STATE_DIR"
stamp="$STATE_DIR/last-failure"
if [ -f "$stamp" ]; then
  last=$(cat "$stamp" 2>/dev/null || echo 0)
  now=$(date +%s)
  if [ $((now - last)) -lt "$BACKOFF_S" ]; then say "skipped: backing off after a failed unlock"; exit 0; fi
fi

# One run at a time: mkdir is the atomic lock; a lock older than the bound is a dead run's.
lockdir="$STATE_DIR/lock"
if ! mkdir "$lockdir" 2>/dev/null; then
  lock_age=$(( $(date +%s) - $(stat -f %m "$lockdir" 2>/dev/null || echo 0) ))
  [ "$lock_age" -gt $((UNLOCK_TIMEOUT * 2)) ] || exit 0
  rmdir "$lockdir" 2>/dev/null; mkdir "$lockdir" 2>/dev/null || exit 0
fi
trap 'rmdir "$lockdir" 2>/dev/null' EXIT

( "$SECRETS_RUN" read "$ref" 2>/dev/null | "$VG_DISKUTIL" apfs unlockVolume "$VG_DEVICE" -stdinpassphrase >/dev/null 2>&1 ) &
pid=$!
waited=0
while kill -0 "$pid" 2>/dev/null; do
  if [ "$waited" -ge $((UNLOCK_TIMEOUT * 10)) ]; then
    kill -KILL "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    date +%s > "$stamp"; say "unlock failed: timed out after ${UNLOCK_TIMEOUT}s"; exit 0
  fi
  sleep 0.1; waited=$((waited + 1))
done

volume_gate_probe
if [ "$VG_STATE" = mounted ]; then rm -f "$stamp"; say "unlocked and mounted"; exit 0; fi
date +%s > "$stamp"
say "unlock failed: volume is $VG_STATE after the attempt (is the passphrase ref in the secrets cache? make secrets-reseal-request)"
exit 0
