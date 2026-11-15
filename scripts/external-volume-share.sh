#!/usr/bin/env bash
# external-volume-share — serve the mini's external volume over SMB as a share named like the volume (EXT),
# so the MacBook can mount it at /Volumes/EXT (docs/external-ssd.md §Share).
#
#   external-volume-share.sh add      (root) create the share point; refused unless the volume gate says present
#   external-volume-share.sh remove   (root) remove it; the data is untouched
#   external-volume-share.sh status   no root: the share point's state and the gate's, always exit 0
#
# Why a script and not a one-liner: the share point is the volume's mount point itself, so an absent or
# locked volume leaves nothing behind it (smbd has no directory to serve, the internal disk is never exposed).
# `add` therefore must only ever name the real mount point, which it reads from the gate, never a typed path.
# `sharing -a` needs root and there is no root-free route (the share points live in the local directory
# node, /var/db/dslocal, owned by root), so the owner runs this once: `sudo scripts/external-volume-share.sh add`.
#
# Access is what a macOS share point gives: the SMB-enabled users of the Mac, guest access off. The volume
# is mounted noowners, so file permissions do not narrow it further.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="${EXT_SHARE_GATE:-$HERE/lib/volume-gate.sh}"
SHARING="${EXT_SHARE_SHARING:-/usr/sbin/sharing}"
DSCL="${EXT_SHARE_DSCL:-/usr/bin/dscl}"
DSEDITGROUP="${EXT_SHARE_DSEDITGROUP:-/usr/sbin/dseditgroup}"
CFG="${VOLUME_GATE_CONFIG:-$HERE/../config/external-volume.json}"

die() { echo "external-volume-share: $*" >&2; exit 1; }

NAME=$(jq -r '.name // empty' "$CFG" 2>/dev/null)
[ -n "$NAME" ] || die "no volume name in $CFG"

# The path of the SMB share point called $NAME, empty when there is none.
share_path() {
  "$SHARING" -l -f json 2>/dev/null \
    | jq -r --arg n "$NAME" 'to_entries[] | select(.value.smb_name == $n) | .value.path' 2>/dev/null | head -n 1
}

sharepoint_groups() { "$DSCL" . -list /Groups 2>/dev/null | grep '^com\.apple\.sharepoint\.group\.' | sort; }

need_root() { [ "${EXT_SHARE_UID:-$(id -u)}" -eq 0 ] || die "must run as root: sudo $0 $1"; }

cmd_add() {
  need_root add
  local state root existing
  state=$("$GATE" state) || die "the volume gate failed"
  [ "$state" = present ] || die "volume $state (gate: present = mounted, unlocked, sentinel readable); nothing shared"
  root=$("$GATE" root) || die "the volume has no mount point"
  existing=$(share_path)
  if [ -n "$existing" ]; then
    [ "$existing" = "$root" ] && { ensure_group; echo "already shared: $NAME -> the volume"; return 0; }
    die "a share point '$NAME' exists at a different path; remove it first ($0 remove)"
  fi
  "$SHARING" -a "$root" -S "$NAME" -n "$NAME" -s 001 -g 000 || die "sharing -a failed"
  [ -n "$(share_path)" ] || die "the share point is not listed after sharing -a"
  ensure_group
  echo "shared: $NAME (smb, no guest)"
}

# smbd only serves a share point that names an access group (sharepoint_group_id), as System Settings creates it;
# `sharing -a` alone leaves it out and the client then answers "the share does not exist" (2026-11-15, measured).
# Create the group the way System Settings does (com.apple.sharepoint.group.N, gid 700+N, RealName = the share),
# link it, and put the invoking admin in it. Idempotent: a share point that already has one is left alone.
ensure_group() {
  local have max n grp uid user="${SUDO_USER:-}"
  have=$("$DSCL" . -read "/SharePoints/$NAME" sharepoint_group_id 2>/dev/null | awk '{print $2}')
  [ -z "$have" ] || return 0
  max=$(sharepoint_groups | sed 's/.*group\.//' | sort -n | tail -n 1)
  n=$(( ${max:-0} + 1 ))
  grp="com.apple.sharepoint.group.$n"
  "$DSEDITGROUP" -o create -r "$NAME" -i $((700 + n)) "$grp" || die "could not create the access group $grp"
  uid=$("$DSCL" . -read "/Groups/$grp" GeneratedUID 2>/dev/null | awk '{print $2}')
  [ -n "$uid" ] || die "the access group $grp has no GeneratedUID"
  "$DSCL" . -create "/SharePoints/$NAME" sharepoint_group_id "$uid" || die "could not link $grp to the share point"
  if [ -n "$user" ] && [ "$user" != root ]; then
    "$DSEDITGROUP" -o edit -a "$user" -t user "$grp" || echo "note: could not add $user to $grp"
  fi
  echo "access group: $grp"
}

cmd_remove() {
  need_root remove
  [ -n "$(share_path)" ] || { echo "not shared: $NAME"; return 0; }
  "$SHARING" -r "$NAME" || die "sharing -r failed"
  echo "removed share point $NAME (data untouched)"
}

cmd_status() {
  local p; p=$(share_path)
  echo "volume gate: $("$GATE" state)"
  if [ -n "$p" ]; then echo "share point: $NAME (smb)"; else echo "share point: none"; return 0; fi
  if [ -n "$("$DSCL" . -read "/SharePoints/$NAME" sharepoint_group_id 2>/dev/null | awk '{print $2}')" ]; then
    echo "access group: linked"
  else
    echo "access group: missing (smbd answers 'the share does not exist'; re-run add as root)"
  fi
}

case "${1:-}" in
  add) cmd_add ;;
  remove) cmd_remove ;;
  status) cmd_status ;;
  *) die "usage: $0 add|remove|status" ;;
esac
