#!/usr/bin/env bash
# Keep the HomeLab Samba shares usable — on the MacBook and on the headless mini.
#
# macOS never reconnects an SMB mount after sleep or a network change: the mount
# stays in the table, and the first Finder/stat touching it blocks. Every run
# (60 s, plus every network change via WatchPaths), per declared share:
#
#   server unreachable on :445        → log "skipped", leave everything alone
#   mounted, bounded stat+ls succeed  → healthy
#   mounted, stat or ls hangs/fails   → force-unmount, remount
#   not mounted, automount=yes        → mount
#   not mounted, automount=no         → nothing (opt-in per share)
#
# Runs under `jobrun`, so the exit code is graded: non-zero only when a mount or
# remount failed or the declaration/secret is missing. Unreachable is a normal
# state (laptop off-tailnet, a HomeLab that is down at boot) and exits 0.
#
# Two hosts, one loop; only the mount step differs:
#   MacBook (login Keychain)  `osascript mount volume`, password from the Keychain
#                             entry Finder saved; mounts at /Volumes/<share>.
#   mini (secrets backend     no Finder session, never `op`: the password comes
#   'cache')                  from the secrets cache (`secrets-run read`), the
#                             mount is `mount_smbfs` at ~/HomeLab/<share>. The
#                             mount point exists only while a share sits on it
#                             (an empty directory would swallow a copy to a
#                             HomeLab that is down). The password reaches
#                             mount_smbfs through a pty (smb-mount.exp), never
#                             its argv; it is also in a 0600 temp file for the
#                             length of the secret read. Never in a tracked
#                             file, the plist, the log or the environment.
#
# Health probe: macOS answers `Operation not permitted` (or hangs on a prompt nobody
# sees) to a launchd job that READS an SMB mount unless the job's program holds the
# Network Volumes grant, which is keyed on a versioned bun path. So the mini's probe
# reads nothing: stat + df + `smbutil statshares -m`, none of which needs the grant,
# and together they hang on a silent server and fail on a dropped session (`stat`
# alone is answered from cache). The MacBook, where the job runs in the GUI session,
# still lists the root with `ls -a`. EPERM is "cannot probe", never "stale".
#
# Every external call is bounded: a hung smbfs call is abandoned, never waited
# on (launchd reaps the leftover when the run exits). Declared shares:
# dotfiles-private/smb-shares.conf (it names the server, so it stays out of this
# public repo).
set -uo pipefail

CONF="${SMB_SHARES_CONF:-$HOME/SourceRoot/dotfiles-private/smb-shares.conf}"
PROBE_SECONDS="${SMB_PROBE_SECONDS:-8}"
RETRY_SLEEP="${SMB_RETRY_SLEEP:-2}"
UNMOUNT_SECONDS="${SMB_UNMOUNT_SECONDS:-20}"
MOUNT_SECONDS="${SMB_MOUNT_SECONDS:-45}"
SECRET_SECONDS="${SMB_SECRET_SECONDS:-15}"
SECRET_REF="${SMB_SECRET_REF:-op://homelab/samba/PASSWORD}"
MOUNT_ROOT="${SMB_MOUNT_ROOT:-$HOME/HomeLab}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] smb-keepalive: $*"; }

# Which host: the secrets backend marker (cache = the mini). SMB_HOST_KIND is the test seam.
host_kind="${SMB_HOST_KIND:-}"
if [ -z "$host_kind" ]; then
  MARKER="${XDG_CONFIG_HOME:-$HOME/.config}/secrets/backend"
  if [ "$(tr -d '[:space:]' 2>/dev/null < "$MARKER" || true)" = cache ]; then host_kind=mini; else host_kind=macbook; fi
fi

[ -f "$CONF" ] || { log "no share declaration at $CONF"; exit 1; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_TMP=$(mktemp -d "${TMPDIR:-/tmp}/smb-keepalive.XXXXXX") || exit 1
trap 'rm -rf "$RUN_TMP"' EXIT
PROBE_ERR="$RUN_TMP/probe.err"

# Run "$@" for at most $1 seconds. 0 = exited 0; 1 = failed; 124 = still running
# after the deadline (abandoned, never waited on — a hung smbfs call can sit in
# the kernel uninterruptibly). Output is discarded.
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

# bounded, with $1 seconds, $2 = file receiving stderr; stdout discarded.
bounded_err() {
  local secs="$1" err="$2" pid i
  shift 2
  "$@" </dev/null >/dev/null 2>"$err" &
  pid=$!
  for ((i = 0; i < secs * 4; i++)); do
    kill -0 "$pid" 2>/dev/null || { wait "$pid"; return $(( $? == 0 ? 0 : 1 )); }
    sleep 0.25
  done
  kill -9 "$pid" 2>/dev/null
  return 124
}

# bounded, but $SECRET (one line) is fed to the command's stdin through a pipe (printf is
# a builtin: nothing in any argv). For the pty mount only.
bounded_input() {
  local secs="$1" pid i
  shift
  printf '%s\n' "$SECRET" | "$@" >/dev/null 2>&1 &
  pid=$!
  for ((i = 0; i < secs * 4; i++)); do
    kill -0 "$pid" 2>/dev/null || { wait "$pid"; return $?; }  # the child's own status: 77 = password refused
    sleep 0.25
  done
  kill -9 "$pid" 2>/dev/null
  return 124
}

# bounded, but stdout goes to the file $2 (mode 600) — for the secret read only.
bounded_to() {
  local secs="$1" out="$2" pid i
  shift 2
  : > "$out"; chmod 600 "$out"
  "$@" </dev/null >"$out" 2>/dev/null &
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

# Probe a mounted share: 0 healthy, 1 failed, 124 hung, 2 cannot probe (macOS refuses the read:
# EPERM is not a stale mount). Each command bounded on its own, run directly (no `sh -c`
# wrapper), so the process killed on a timeout is the one actually stuck.
probe_cmd() { # $1 = name, rest = the command; stderr kept in $PROBE_ERR to tell EPERM from a dead mount
  local rc
  bounded_err "$PROBE_SECONDS" "$PROBE_ERR" "${@:2}"; rc=$?
  [ "$rc" -eq 1 ] && grep -q "Operation not permitted" "$PROBE_ERR" 2>/dev/null && return 2
  return "$rc"
}

probe() {
  local mp="$1" rc
  probe_cmd stat stat "$mp"; rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  if [ "$host_kind" = mini ]; then
    probe_cmd df df -k "$mp"; rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    probe_cmd statshares smbutil statshares -m "$mp"
  else
    # the root's attributes can come from cache; the listing has to reach the server
    probe_cmd ls ls -a "$mp"
  fi
}

# The password, once per run, from the secrets cache. Sets SECRET; 1 = unavailable.
SECRET=""
SECRET_FAILED=0
load_secret() {
  [ -n "$SECRET" ] && return 0
  [ "$SECRET_FAILED" -eq 1 ] && return 1
  local rc
  bounded_to "$SECRET_SECONDS" "$RUN_TMP/pw" secrets-run read "$SECRET_REF"; rc=$?
  SECRET=$(cat "$RUN_TMP/pw" 2>/dev/null); SECRET=${SECRET%$'\n'}
  rm -f "$RUN_TMP/pw"
  [ "$rc" -eq 0 ] && [ -n "$SECRET" ] && return 0
  SECRET=""; SECRET_FAILED=1
  case "$rc" in
    124) log "secret read timed out after ${SECRET_SECONDS}s" ;;
    *)   log "secret $SECRET_REF is not in the cache — run 'make secrets-reseal-request'" ;;
  esac
  return 1
}

smb_mount_macbook() {
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

# The mount point exists only while a mount sits on it: created for the attempt,
# removed again when the mount fails (a failed run leaves nothing behind).
# rmdir refuses a directory with content, so a real one is never touched.
release_mount_point() { # mini only; the caller knows the share is not mounted
  [ "$host_kind" = mini ] || return 0
  rmdir "$MOUNT_ROOT/$1" 2>/dev/null
  rmdir "$MOUNT_ROOT" 2>/dev/null
  return 0
}

smb_mount_mini() {
  local server="$1" user="$2" share="$3" mp="$MOUNT_ROOT/$3" rc
  load_secret || { release_mount_point "$share"; return 1; }
  mkdir -p "$mp" || { log "$share: cannot create $mp"; return 1; }
  bounded_input "$MOUNT_SECONDS" expect -f "$HERE/smb-mount.exp" -- "$user" "$server" "$share" "$mp"
  rc=$?
  if [ "$rc" -eq 0 ]; then log "$share: mounted at $mp"; return 0; fi
  release_mount_point "$share"
  case "$rc" in
    124) log "$share: mount timed out after ${MOUNT_SECONDS}s" ;;
    77)  log "$share: the server refused the password (is the cached secret current? make secrets-reseal-request)" ;;
    *)   log "$share: mount_smbfs failed (rc $rc)" ;;
  esac
  return 1
}

smb_mount() {
  if [ "$host_kind" = mini ]; then smb_mount_mini "$@"; else smb_mount_macbook "$@"; fi
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
# Row: <server> <user> <share> <automount yes|no> [macbook|mini] — the optional last field
# restricts the row to one host (a share may automount on the mini and stay opt-in on the MacBook).
while read -r server user share automount scope _rest; do
  case "${server:-}" in ''|\#*) continue ;; esac
  [ -n "${share:-}" ] || { log "malformed row: '$server $user'"; continue; }
  case "${scope:-}" in \#*) scope="" ;; esac
  case "${scope:-$host_kind}" in "$host_kind") ;; macbook|mini) continue ;; *) log "$share: bad scope '$scope'"; continue ;; esac
  checked=$((checked + 1))

  if ! bounded 5 nc -z -G 3 "$server" 445; then
    log "$share: $server:445 unreachable (HomeLab down, Tailscale down or off-tailnet) — skipped"
    [ -z "$(mount_point "$server" "$share")" ] && release_mount_point "$share"
    continue
  fi

  mp=$(mount_point "$server" "$share")
  if [ -z "$mp" ]; then
    if [ "${automount:-no}" = yes ]; then
      smb_mount "$server" "$user" "$share" || failed=$((failed + 1))
    else
      release_mount_point "$share"
      log "$share: reachable, not mounted (automount off)"
    fi
    continue
  fi

  # stat the root AND list it: the root's attributes can come from cache, the
  # listing has to reach the server. A fast failure gets one retry before the
  # destructive path (a vanished entry is not a dead mount); a hang does not.
  probe "$mp"
  rc=$?
  [ "$rc" -eq 1 ] && { sleep "$RETRY_SLEEP"; probe "$mp"; rc=$?; }
  case "$rc" in
    0) log "$share: healthy at $mp"; continue ;;
    2) log "$share: mount at $mp cannot be probed (macOS refuses the read: Operation not permitted) — left alone"; continue ;;
  esac

  log "$share: mount at $mp is stale (probe $([ "$rc" -eq 124 ] && echo "hung > ${PROBE_SECONDS}s" || echo failed twice)) — remounting"
  { force_unmount "$mp" "$share" && smb_mount "$server" "$user" "$share"; } || failed=$((failed + 1))
done < "$CONF"

[ "$checked" -gt 0 ] || { log "no shares declared for the $host_kind in $CONF"; exit 1; }
[ "$failed" -eq 0 ] || { log "$failed share(s) could not be (re)mounted"; exit 1; }
exit 0
