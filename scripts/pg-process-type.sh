#!/usr/bin/env bash
# pg-process-type — keep ProcessType Interactive in the Postgres brew-service plist.
#
#   pg-process-type.sh converge   write the key into the plist file if it is missing (idempotent, never reloads)
#   pg-process-type.sh check      exit 1 when the file lacks the key; report whether the loaded job runs it
#
# WHY. A launchd job with no ProcessType gets "light resource limits ... throttling its CPU usage and I/O bandwidth"
# (man launchd.plist): priority 20 against 31 for everything a terminal starts. On 2026-11-14, at load 200, Postgres
# at 20 starved first and every client of it (the factory, agw, argo, the native apps) timed out with it.
# BREW REGENERATES this plist from the formula's `service` block on every `brew services start|restart` and on
# every upgrade, and the formula has no ProcessType: the key is gone after either, silently. So the file is
# converged here (the colima boot path has the same shape: `make _colima-supervise`), from `make setup` and
# asserted by `make brew-upgrade` and `make mini-ps`/`make doctor` (scripts/mini-registry.ts, process_type).
#
# `converge` deliberately does NOT reload: a reload stops Postgres and every client waits on it. The file is right
# after this; the running job keeps its old definition until the host-lane reload in docs/postgres.md
# §Process type. `check` says which of the two states it is in.
#
# Overridable for the hermetic suite: BREW_SERVICE_GUI_DIR (scripts/lib/brew-service.sh), LAUNCHCTL_BIN,
# PG_PROCESS_TYPE_UID.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/brew-service.sh
. "$HERE/lib/brew-service.sh"
LAUNCHCTL_BIN="${LAUNCHCTL_BIN:-/bin/launchctl}"
PLISTBUDDY="${BREW_SERVICE_PLISTBUDDY:-/usr/libexec/PlistBuddy}"
SERVICE=postgresql@18
WANT=Interactive

plist=$(brew_service_plist "$SERVICE") || plist=""

file_type() { "$PLISTBUDDY" -c 'Print :ProcessType' "$plist" 2>/dev/null || true; }

# launchd's own word for the LOADED definition: `spawn type = interactive (4)`; empty when the job is not loaded.
loaded_type() {
  local uid="${PG_PROCESS_TYPE_UID:-$(id -u)}" label
  label=$(brew_service_label "$SERVICE") || return 0
  "$LAUNCHCTL_BIN" print "gui/$uid/$label" 2>/dev/null | awk -F' = ' '/^[[:space:]]*spawn type = /{ sub(/ \(.*/, "", $2); print $2; exit }'
}

report_loaded() {
  local t
  t=$(loaded_type)
  if [ -z "$t" ]; then echo "    · postgres job not loaded under launchd"; return 0; fi
  if [ "$t" = "interactive" ]; then echo "    · loaded job runs interactive"; return 0; fi
  echo "    ! loaded job still runs '$t': the file is right, the running Postgres is not (host-lane reload: docs/postgres.md §Process type)"
  return 3
}

case "${1:-}" in
  converge)
    if [ -z "$plist" ]; then
      echo "    · postgresql@18 brew service not installed here — nothing to converge"; exit 0
    fi
    if [ "$(file_type)" = "$WANT" ]; then
      echo "    · postgres ProcessType (ok)"
    else
      "$PLISTBUDDY" -c 'Delete :ProcessType' "$plist" >/dev/null 2>&1 || true
      "$PLISTBUDDY" -c "Add :ProcessType string $WANT" "$plist" >/dev/null || { echo "  ✗ could not write ProcessType into $plist"; exit 1; }
      plutil -lint "$plist" >/dev/null || { echo "  ✗ postgres plist is malformed after edit"; exit 1; }
      echo "    ✓ postgres ProcessType $WANT pinned in ${plist##*/}"
    fi
    report_loaded; rc=$?
    [ "$rc" = 3 ] && rc=0 # a stale loaded job is a note here, not a failure of the converge
    exit "$rc"
    ;;
  check)
    if [ -z "$plist" ]; then echo "  · postgres brew service not installed here — skipping"; exit 0; fi
    got=$(file_type)
    if [ "$got" != "$WANT" ]; then
      echo "  ✗ postgres: plist ProcessType is '${got:-missing}', not $WANT — brew rewrote it (fix: make pg-process-type, then the host-lane reload in docs/postgres.md §Process type)"
      exit 1
    fi
    report_loaded; rc=$?
    [ "$rc" = 3 ] && exit 1
    exit "$rc"
    ;;
  *)
    echo "usage: pg-process-type.sh converge|check" >&2; exit 2
    ;;
esac
