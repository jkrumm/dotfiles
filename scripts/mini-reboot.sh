#!/usr/bin/env bash
# mini-reboot.sh — reboot the Mac mini plainly (no macOS update involved), from here.
#
# The maintenance counterpart of mini-macos-update.sh, for the reboot after brew/cask/Safari/Tailscale upgrades. Called by
# `REASON=maintenance make planned-restart` as its step 4 (drain, tell, quiesce, THIS, recover, resume); alone it only
# reboots, it does not drain the queue or tell the leads.
#
#   snapshot   the resume labels of every Claude terminal (lib/resume-snapshot.sh, same record as the macOS applier)
#   reboot     op-fed `sudo -S shutdown -r +0`, detached: the ssh session dies with the host
#   wait       down, then up, and assert the boot time moved (a reboot that never happened is not success)
#
# The password goes over ssh stdin, never argv (visible in ps). MacBook-only: op://Private/* is refused by the mini's
# secrets cache by design. Do not use this for a pending macOS update: mini-macos-update.sh owns that, and a forced
# reboot there boots the old OS.
#
# Deliberately separate from mini-macos-update.sh: its guards and waits are shaped by the update (label pin, prepare, version check);
# only the resume snapshot is shared (lib/resume-snapshot.sh). Refuses while a macOS update prepare is running.
#
# Overrides (tests): SSH_BIN, OP_BIN, MINI_HOST, BACKEND_FILE, REBOOT_{DOWN_WAIT,UP_WAIT,POLL}.
# bash 3.2 (the MacBook's /bin/bash).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST="${MINI_HOST:-mini}"
SSH_BIN="${SSH_BIN:-ssh}"
OP_BIN="${OP_BIN:-op}"
ACCOUNT="tkrumm"
PW_REF="op://Private/mac-mini-server/password"
BACKEND_FILE="${BACKEND_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/secrets/backend}"
DOWN_WAIT="${REBOOT_DOWN_WAIT:-300}"   # s to see the host go down
UP_WAIT="${REBOOT_UP_WAIT:-2400}"      # s to see it come back
POLL="${REBOOT_POLL:-15}"
SSH_OPTS=(-o ConnectTimeout=6 -o BatchMode=yes)

# shellcheck source=lib/resume-snapshot.sh
. "$HERE/lib/resume-snapshot.sh"

die() { echo "✗ $*" >&2; exit 1; }
say() { echo "  $*"; }
remote() { "$SSH_BIN" "${SSH_OPTS[@]}" "$HOST" "$@"; }

# --- guards ------------------------------------------------------------------
backend="$( [ -f "$BACKEND_FILE" ] && cat "$BACKEND_FILE" || echo op )"
[ "$backend" = "op" ] || die "backend is '$backend': run this from the MacBook, not the dev host"
OP_BIN="$OP_BIN" bash "$HERE/lib/op-signed-in.sh" "$ACCOUNT" || die "1Password is locked for $ACCOUNT: unlock it and re-run"
remote true 2>/dev/null || die "$HOST is not reachable over ssh"

if remote 'pgrep -f "[U]pdateBrainService|[S]oftwareUpdateLauncher" >/dev/null' 2>/dev/null; then
  die "a macOS update prepare is running on $HOST: a forced reboot aborts it and boots the old OS. Let it finish its own restart"
fi

before="$(remote 'sysctl -n kern.boottime' 2>/dev/null)" || die "could not read the boot time of $HOST"
say "$HOST is up ($before)"

if [ "${YES:-0}" != "1" ]; then
  [ -t 0 ] || die "refusing to reboot $HOST unattended: re-run with YES=1"
  printf "  This reboots %s and kills every core terminal. Type 'yes' to continue: " "$HOST"
  read -r reply
  [ "$reply" = "yes" ] || die "aborted"
fi

# --- snapshot, then reboot ---------------------------------------------------
stamp="$(date +%Y%m%d-%H%M)"
resume_snapshot "$HOST" "$stamp"

PW="$("$OP_BIN" read "$PW_REF" --account "$ACCOUNT")" || die "could not read $PW_REF"
log="\$HOME/Library/Logs/mini-reboot-$stamp.log"
# Detached: the reboot takes the ssh session with it. $log expands on the host; the password is read there from stdin.
# shellcheck disable=SC2029
printf '%s\n' "$PW" | remote "read -r pw
  printf '%s\n' \"\$pw\" | nohup sudo -S shutdown -r +0 > $log 2>&1 &
  echo ok" >/dev/null || die "could not launch the shutdown on $HOST"
unset PW
say "· shutdown requested, logging to $log"

# --- down, then up -----------------------------------------------------------
waited=0
while remote true 2>/dev/null; do
  [ "$waited" -lt "$DOWN_WAIT" ] || die "$HOST never went down after ${DOWN_WAIT}s: read $log on it, the sudo password may have been refused"
  sleep "$POLL"
  waited=$((waited + POLL))
done
say "· $HOST went down"

waited=0
while ! remote true 2>/dev/null; do
  [ "$waited" -lt "$UP_WAIT" ] || die "$HOST did not come back within ${UP_WAIT}s: it may be at a boot prompt"
  sleep "$POLL"
  waited=$((waited + POLL))
done

after="$(remote 'sysctl -n kern.boottime' 2>/dev/null)" || die "$HOST is back but its boot time is unreadable"
[ "$after" != "$before" ] || die "$HOST answered again but its boot time did not move: it never rebooted"
echo ""
echo "  ✓ $HOST rebooted ($after)"
echo "    next: make doctor   (on $HOST)"
