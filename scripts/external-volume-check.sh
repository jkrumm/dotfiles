#!/usr/bin/env bash
set -u
# external-volume-check — doctor's and the heartbeat's "external volume" check (docs/external-ssd.md §Check).
#   attached=false  -> prints nothing, exit 0 (the check does not exist yet)
#   present         -> one "external volume present" line, exit 0
#   absent, locked, unreadable -> one WARN line, exit 2 (the heartbeat's WARN grade). NEVER a failure:
#                      a drive that is unplugged is the owner's to notice, and no page is worth it.
# Not part of the liveness push (that carries tailnet, sshd and the core only). BASH 3.2.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/volume-gate.sh
. "$HERE/lib/volume-gate.sh"

volume_gate_state
case "$VG_STATE" in
  unattached) exit 0 ;;
  present) echo "external volume present"; exit 0 ;;
  unreadable) echo "external volume unreadable (mounted, but the sentinel did not read in ${VG_READ_TIMEOUT}s: wrong volume, or a Removable Volumes grant is pending; docs/external-ssd.md §TCC)"; exit 2 ;;
  *) echo "external volume $VG_STATE (dependents skip themselves; docs/external-ssd.md)"; exit 2 ;;
esac
