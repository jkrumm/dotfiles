#!/usr/bin/env bash
# mini-macos-update.sh — apply a pending macOS update to the Mac mini, from here.
#
# `make drift-check` NAMES a pending macOS update; this applies it. It exists
# because the obvious spelling of "apply it" is wrong in a way that leaves no
# error behind, and the whole cost lands on the one host every agent runs on.
#
# WHAT IS COUNTER-INTUITIVE. `softwareupdate -i -a -R` returns in SECONDS with
# `Restarting...` and does not restart. That line is a request; the work starts
# afterwards, asynchronously — UpdateBrainService and SoftwareUpdateLauncher
# prepare the update for several minutes and then reboot the machine themselves.
# Forcing `shutdown -r now` there ABORTS the prepare and boots the old OS, with
# every artifact still looking armed (Update.plist personalized, nvram
# ota-updateType set, RecommendedUpdates still populated). Learned the hard way
# 2026-08-29: two spurious reboots before the third attempt was left alone.
# The only honest check is `sw_vers -productVersion`, which is what this asserts.
#
# WHY THE REQUEST GETS SWALLOWED. macOS can route the restart to a *notification*
# instead of performing it (usernoted registers RESTART_NOW / RESTART_LATER); a
# stale GUI session with a modal up is how that happens — after 22 days of uptime
# this mini had an EscrowSecurityAlert and a leftover Chrome pinning two cores.
# Re-running against a freshly booted session worked first try. So: if the
# prepare never starts, reboot the mini plainly and run this again.
#
# WHY THE PASSWORD GOES IN TWICE. Apple Silicon needs volume-owner auth, hence
# `--user … --stdinpass`. `sudo -S` eats one stdin line and `--stdinpass` reads
# the next, so the same password twice satisfies both and never reaches argv —
# which `sudo softwareupdate … --stdinpass "$PW"` would (visible in ps auxww).
# If sudo's timestamp is already warm it consumes nothing and softwareupdate
# takes line 1; both orderings work because both lines are the same secret.
#
# MacBook-only: op://Private/* is refused by the mini's secrets cache by design.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST="${MINI_HOST:-mini}"
ACCOUNT="tkrumm"
PW_REF="op://Private/mac-mini-server/password"
REMOTE_USER="${MINI_ADMIN_USER:-jkrumm}"

PREPARE_WAIT="${PREPARE_WAIT:-120}"   # s to see the prepare processes appear
DOWN_WAIT="${DOWN_WAIT:-900}"         # s to see the host go down
UP_WAIT="${UP_WAIT:-2400}"            # s to see it come back

SSH_OPTS=(-o ConnectTimeout=6 -o BatchMode=yes)

die() { echo "✗ $*" >&2; exit 1; }
say() { echo "  $*"; }

# --- guards ------------------------------------------------------------------
# Present-human machine only. The mini cannot run this against itself: the
# password is op://Private/*, which its cache refuses unconditionally.
backend_file="${XDG_CONFIG_HOME:-$HOME/.config}/secrets/backend"
backend="$( [ -f "$backend_file" ] && cat "$backend_file" || echo op )"
[ "$backend" = "op" ] || die "backend is '$backend' — run this from the MacBook, not the dev host"

bash "$HERE/lib/op-signed-in.sh" "$ACCOUNT" \
  || die "1Password is locked for $ACCOUNT — unlock it and re-run"

ssh "${SSH_OPTS[@]}" "$HOST" true 2>/dev/null || die "$HOST is not reachable over ssh"

# --- what is pending ---------------------------------------------------------
# Apple's own cached scan, same source as drift-check — no network round trip,
# no tens of seconds of `softwareupdate -l`.
before="$(ssh "${SSH_OPTS[@]}" "$HOST" 'sw_vers -productVersion')"
pending="$(ssh "${SSH_OPTS[@]}" "$HOST" \
  'defaults read /Library/Preferences/com.apple.SoftwareUpdate RecommendedUpdates 2>/dev/null || true' \
  | sed -n 's/.*"Display Name" = "\(.*\)";/\1/p' | sed 's/\\\\U00a0/ /g')"

echo "  $HOST is on macOS $before"
if [ -z "$pending" ]; then
  echo "  ✓ no recommended update pending — nothing to do"
  exit 0
fi
echo "  pending: $(echo "$pending" | tr '\n' ',' | sed 's/,$//')"

# --- confirm -----------------------------------------------------------------
# Reboots the host every agent runs on: herdr restores the layout by name but
# every process inside it dies. Policy override, not a doubt override.
if [ "${YES:-0}" != "1" ]; then
  [ -t 0 ] || die "refusing to reboot $HOST unattended — re-run with YES=1"
  printf "  This reboots %s and kills every herdr pane. Type 'yes' to continue: " "$HOST"
  read -r reply
  [ "$reply" = "yes" ] || die "aborted"
fi

# --- snapshot resumable agents ----------------------------------------------
# herdr restores the layout and loses the processes, so the session ids are the
# only way back into work that was mid-flight. Best effort: never block on it.
stamp="$(date +%Y%m%d-%H%M)"
snap="\$HOME/Library/Logs/herdr-panes-pre-reboot-$stamp.txt"
# shellcheck disable=SC2029  # $snap is built here on purpose; \$HOME expands on the mini
if ssh "${SSH_OPTS[@]}" "$HOST" "herdr pane list > $snap 2>/dev/null"; then
  say "· agent panes snapshotted to $snap on $HOST"
else
  say "· herdr pane snapshot skipped (herdr not answering)"
fi

# --- launch the installer, detached -----------------------------------------
# Detached on purpose: a brew upgrade of the tailscale formula in the same
# maintenance window restarts tailscaled — the transport this ssh rides — and a
# foreground installer dies with it. Log lands in ~/Library/Logs, never /tmp
# (launchd-style unlinked-inode class; see the agent-logs section in CLAUDE.md).
PW="$(op read "$PW_REF" --account "$ACCOUNT")" || die "could not read $PW_REF"
log="\$HOME/Library/Logs/macos-update-$stamp.log"
# shellcheck disable=SC2029  # $REMOTE_USER/$log are meant to expand here; $pw is read remotely
printf '%s\n' "$PW" | ssh "${SSH_OPTS[@]}" "$HOST" "read -r pw
  { printf '%s\n' \"\$pw\"; printf '%s\n' \"\$pw\"; } |
    nohup sudo -S softwareupdate -i -a -R --user $REMOTE_USER --stdinpass \
      > $log 2>&1 &
  echo ok" >/dev/null || die "could not launch the installer on $HOST"
unset PW
say "· installer launched, logging to $log"

# --- assert the prepare actually started ------------------------------------
say "· waiting up to ${PREPARE_WAIT}s for the prepare to start…"
waited=0
prepared=0
while [ "$waited" -lt "$PREPARE_WAIT" ]; do
  if ssh "${SSH_OPTS[@]}" "$HOST" \
       'pgrep -f "UpdateBrainService|SoftwareUpdateLauncher" >/dev/null' 2>/dev/null; then
    prepared=1; break
  fi
  # The host going away IS the success case if it happened fast.
  ssh "${SSH_OPTS[@]}" "$HOST" true 2>/dev/null || { prepared=1; break; }
  sleep 10
  waited=$(( waited + 10 ))
done

if [ "$prepared" != "1" ]; then
  echo "" >&2
  echo "  ✗ no prepare after ${PREPARE_WAIT}s — the restart request was swallowed." >&2
  echo "    That is the stale-GUI-session case: a modal (EscrowSecurityAlert) or an" >&2
  echo "    app is vetoing the restart. Reboot $HOST plainly and run this again:" >&2
  echo "      ssh $HOST 'sudo shutdown -r now'   # needs the password" >&2
  echo "    Do NOT force a reboot once a prepare IS running — that boots the old OS." >&2
  echo "    Check by hand: ssh $HOST 'pgrep -fl UpdateBrainService'" >&2
  exit 1
fi
say "· preparing (this takes minutes, and $HOST restarts itself — leave it alone)"

# --- down, then up -----------------------------------------------------------
waited=0
while ssh "${SSH_OPTS[@]}" "$HOST" true 2>/dev/null; do
  [ "$waited" -lt "$DOWN_WAIT" ] || die "$HOST never went down after ${DOWN_WAIT}s — check it by hand"
  sleep 15
  waited=$(( waited + 15 ))
done
say "· $HOST went down — applying"

waited=0
while ! ssh "${SSH_OPTS[@]}" "$HOST" true 2>/dev/null; do
  [ "$waited" -lt "$UP_WAIT" ] || die "$HOST did not come back within ${UP_WAIT}s — it may be at a boot prompt"
  sleep 20
  waited=$(( waited + 20 ))
done

after="$(ssh "${SSH_OPTS[@]}" "$HOST" 'sw_vers -productVersion')"
if [ "$after" = "$before" ]; then
  die "$HOST rebooted but is still on $after — the prepare was interrupted; re-run (see the header)"
fi

echo ""
echo "  ✓ $HOST: macOS $before → $after"
echo "    next: make devhost-health-check && make drift-check   (on $HOST)"
