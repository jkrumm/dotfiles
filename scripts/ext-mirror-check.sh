#!/usr/bin/env bash
set -u
# ext-mirror-check — the heartbeat's "ext mirror" component: every share of the EXT mirror has synced clean within 36 h
# (docs/storage.md §EXT mirror). Reads ONLY the local stamps scripts/ext-mirror.py writes outside the volume
# (~/.local/state/ext-mirror/last-ok.json), so a volume that cannot be read still has an age, and it never touches the volume.
#   attached=false (config/external-volume.json; only the mini sets it) -> prints nothing, exit 0
#   every source stamped within the limit                              -> one "ext mirror ok" line, exit 0
#   a source with no stamp, or one older than the limit                -> one FAIL line naming it, exit 1
# FAIL, not WARN: the heartbeat's detail monitor goes DOWN on it and the factory door files it with a lead, which is the alert
# for a mirror that has silently not run (2026-11-16: skipped for a night, graded green, 17 of 221 GiB). The skipped run itself
# is already red in jobs-grade (exit 3); this is the age check that holds when the job is unloaded, never fires or never succeeds.
# A source never stamped counts from the first time this check saw it, so a fresh install has the full limit to finish its first copy.
# Env: EXT_MIRROR_STATE_DIR, STORAGE_MIRROR_MAX_AGE_HOURS (36, the same limit storage-status warns on), EXT_MIRROR_CHECK_NOW (epoch, tests),
# VOLUME_GATE_CONFIG. BASH 3.2.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${VOLUME_GATE_CONFIG:-$HERE/../config/external-volume.json}"
STATE_DIR="${EXT_MIRROR_STATE_DIR:-$HOME/.local/state/ext-mirror}"
MAX_H="${STORAGE_MIRROR_MAX_AGE_HOURS:-36}"
NOW="${EXT_MIRROR_CHECK_NOW:-$(date +%s)}"
SOURCES="ssd fuji videos"

[ "$(jq -r '.attached // false' "$CONFIG" 2>/dev/null)" = "true" ] || exit 0

stamps="$STATE_DIR/last-ok.json"
since="$STATE_DIR/watching-since"
mkdir -p "$STATE_DIR" 2>/dev/null
[ -f "$since" ] || echo "$NOW" > "$since" 2>/dev/null
watch_start=$(cat "$since" 2>/dev/null)
case "$watch_start" in ''|*[!0-9]*) watch_start="$NOW" ;; esac

iso_epoch() { date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null; }

stale=""
oldest=0
for name in $SOURCES; do
  stamp=$(jq -r --arg k "$name" '.[$k] // empty' "$stamps" 2>/dev/null)
  at=""
  [ -z "$stamp" ] || at=$(iso_epoch "$stamp")
  if [ -z "$at" ]; then
    at="$watch_start"; how="never synced clean since this check began"
  else
    how="last clean sync"
  fi
  age_h=$(( (NOW - at) / 3600 ))
  [ "$age_h" -ge "$oldest" ] && oldest="$age_h"
  if [ "$age_h" -ge "$MAX_H" ]; then stale="$stale${stale:+, }$name ${age_h} h ($how)"; fi
done

if [ -n "$stale" ]; then
  echo "ext mirror stale (limit ${MAX_H} h): $stale; \`make ext-mirror-status\`, \`jobs-grade\` and ~/Library/Logs/ext-mirror.log say why"
  exit 1
fi
echo "ext mirror ok (every share synced clean within ${MAX_H} h, oldest ${oldest} h)"
exit 0
