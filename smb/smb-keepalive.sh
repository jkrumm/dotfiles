#!/usr/bin/env bash
# Keep the HomeLab Samba shares usable on the MacBook.
#
# macOS never reconnects an SMB mount after sleep or a network change: the mount
# stays in the table, and the first Finder/stat touching it blocks. Every run
# (60 s, plus every network change via WatchPaths), per declared share:
#
#   server unreachable on :445        → log, leave everything alone
#   mounted, bounded stat succeeds    → healthy
#   mounted, stat hangs or fails      → force-unmount, remount
#   not mounted, automount=yes        → mount
#   not mounted, automount=no         → nothing (opt-in per share)
#
# Runs under `jobrun`, so the exit code is graded: non-zero only when a mount or
# remount failed or the declaration is missing. Unreachable is a normal laptop
# state and exits 0.
#
# Mounting goes through `osascript mount volume`, which takes the password from
# the login Keychain entry Finder saved — no secret here or in the plist.
# Every external call is bounded: a hung smbfs call is abandoned, never waited
# on (launchd reaps the leftover when the run exits).
#
# MacBook-only: no-ops on the cache backend (the mini — agents there use `hl`,
# never an SMB mount). Declared shares: dotfiles-private/smb-shares.conf (it
# names the server, so it stays out of this public repo).
set -uo pipefail

CONF="${SMB_SHARES_CONF:-$HOME/SourceRoot/dotfiles-private/smb-shares.conf}"
PROBE_SECONDS=8
UNMOUNT_SECONDS=20
MOUNT_SECONDS=45

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] smb-keepalive: $*"; }

MARKER="${XDG_CONFIG_HOME:-$HOME/.config}/secrets/backend"
if [ "$(tr -d '[:space:]' 2>/dev/null < "$MARKER" || true)" = cache ]; then
  log "secrets backend is 'cache' (the mini) — agents use hl, nothing to keep alive."
  exit 0
fi

[ -f "$CONF" ] || { log "no share declaration at $CONF"; exit 1; }

# Run "$@" for at most $1 seconds. 0 = exited 0; 1 = failed; 124 = still running
# after the deadline (abandoned, never waited on — a hung smbfs call can sit in
# the kernel uninterruptibly).
bounded() {
  local secs="$1" pid i
  shift
  "$@" </dev/null >/dev/null 2>&1 &
  pid=$!
  for ((i = 0; i < secs * 4; i++)); do
    kill -0 "$pid" 2>/dev/null || { wait "$pid"; return $(( $? == 0 ? 0 : 1 )); }
    sleep 0.25
  done
  kill -9 "$pid" 2>/dev/null
  return 124
}

# Mount point of //[user@]server/share, from the mount table (case-insensitive:
# smbfs reports the server the way it was typed).
mount_point() {
  local server="$1" share="$2"
  mount | awk -v want="$(printf '%s/%s' "$server" "$share" | tr '[:upper:]' '[:lower:]')" '
    / \(smbfs/ {
      src = tolower($1); sub(/^\/\/([^@]*@)?/, "", src)
      if (src == want) { sub(/^[^ ]+ on /, ""); sub(/ \(smbfs.*$/, ""); print; exit }
    }'
}

# Each command bounded on its own, run directly (no `sh -c` wrapper), so the
# process killed on a timeout is the one actually stuck — no orphaned grandchild.
probe() {
  local rc
  bounded "$PROBE_SECONDS" stat "$1"; rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  bounded "$PROBE_SECONDS" ls -a "$1"
}

smb_mount() {
  local server="$1" user="$2" share="$3" rc
  bounded "$MOUNT_SECONDS" osascript -e "mount volume \"smb://${user}@${server}/${share}\""
  rc=$?
  case "$rc" in
    0)   log "$share: mounted at $(mount_point "$server" "$share")"; return 0 ;;
    124) log "$share: mount timed out after ${MOUNT_SECONDS}s" ;;
    *)   log "$share: mount failed (Keychain entry missing? mount it once in Finder with 'Remember')" ;;
  esac
  return 1
}

force_unmount() {
  local mp="$1" share="$2"
  bounded "$UNMOUNT_SECONDS" diskutil unmount force "$mp" \
    || bounded "$UNMOUNT_SECONDS" umount -f "$mp" \
    || { log "$share: force-unmount of $mp failed"; return 1; }
  log "$share: force-unmounted $mp"
}

checked=0
failed=0
while read -r server user share automount _rest; do
  case "${server:-}" in ''|\#*) continue ;; esac
  [ -n "${share:-}" ] || { log "malformed row: '$server $user'"; continue; }
  checked=$((checked + 1))

  if ! bounded 5 nc -z -G 3 "$server" 445; then
    log "$share: $server:445 unreachable (Tailscale down or off-tailnet) — skipped"
    continue
  fi

  mp=$(mount_point "$server" "$share")
  if [ -z "$mp" ]; then
    if [ "$automount" = yes ]; then
      smb_mount "$server" "$user" "$share" || failed=$((failed + 1))
    else
      log "$share: reachable, not mounted (automount off)"
    fi
    continue
  fi

  # stat the root AND list it: the root's attributes can come from cache, the
  # listing has to reach the server. A fast failure gets one retry before the
  # destructive path (a vanished entry is not a dead mount); a hang does not.
  probe "$mp"
  rc=$?
  [ "$rc" -eq 1 ] && { sleep 2; probe "$mp"; rc=$?; }
  if [ "$rc" -eq 0 ]; then
    log "$share: healthy at $mp"
    continue
  fi

  log "$share: mount at $mp is stale (probe $([ "$rc" -eq 124 ] && echo "hung > ${PROBE_SECONDS}s" || echo failed twice)) — remounting"
  { force_unmount "$mp" "$share" && smb_mount "$server" "$user" "$share"; } || failed=$((failed + 1))
done < "$CONF"

[ "$checked" -gt 0 ] || { log "no shares declared in $CONF"; exit 1; }
[ "$failed" -eq 0 ] || { log "$failed share(s) could not be (re)mounted"; exit 1; }
exit 0
