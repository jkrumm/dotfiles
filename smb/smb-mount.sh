#!/bin/bash
# One SMB mount for the mini, run by smb-keepalive.sh as a transient launchd job (`launchctl submit`).
#   smb-mount.sh <rc-file> <user> <server> <share> <mountpoint>      env: SMB_SECRET_REF
# Why a job of its own: macOS attributes a process to the program of the launchd job it descends from,
# and under `jobrun` that is bun, whose Network Volumes permission is keyed on a versioned Cellar path and
# unanswerable on a headless host: mount_smbfs from there hangs before it asks for anything (measured
# 2026-11-14: an argv mount hung > 20 s under jobrun, 1 s as a submitted job). Here the password is read
# from the secrets cache and handed to mount_smbfs through a pty (smb-mount.exp), so it is in no argv, and
# the keepalive process never holds it.
# Writes its exit status to <rc-file>: mount_smbfs' own, 3 = the secret is not in the cache, 77 = the
# server refused the password, 124 = no answer in time.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rcfile="$1"; user="$2"; server="$3"; share="$4"; mp="$5"
finish() { echo "$1" > "$rcfile.tmp" && mv "$rcfile.tmp" "$rcfile"; exit "$1"; }

secret=$(secrets-run read "${SMB_SECRET_REF:-op://homelab/samba/PASSWORD}" 2>/dev/null) || finish 3
[ -n "$secret" ] || finish 3
printf '%s\n' "$secret" | /usr/bin/expect -f "$HERE/smb-mount.exp" -- "$user" "$server" "$share" "$mp" >/dev/null 2>&1
finish $?
