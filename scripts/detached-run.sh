#!/usr/bin/env bash
set +x
set -euo pipefail

# detached-run — run a command under launchd so it survives the death of the
# session that started it. The macOS answer to `systemd-run --unit=… --collect`.
#
# WHY THIS EXISTS. Any change that restarts networking on the mini also kills
# the ssh session issuing it, and on this host that session is the only way in —
# homelab is on a different LAN and Screen Sharing rides the same tunnel, so
# neither survives it (docs/remote-dev.md §8). Run such a command
# in the foreground of an ssh session and it dies HALFWAY: the network drops,
# SIGHUP lands, and the machine is left in whatever half-configured state the
# command reached. That is exactly how the 2026-08-05 Tailscale update attempt
# quit the app and never got to the relaunch — on Linux the same operation was
# safe precisely because it went through `systemd-run`.
#
# `nohup cmd &` mostly works and is not enough. It survives SIGHUP but stays in
# the ssh session's process group and dies with a logout or a session reap;
# launchd owns the job outright.
#
# THE PLIST DELIBERATELY DOES NOT LIVE IN ~/Library/LaunchAgents. Everything
# there is loaded again at every login, so a one-shot job whose cleanup failed
# would silently re-run on the next reboot — for this class of command (restart
# the network, swap the VPN client) that is a genuinely bad outcome. Staging it
# under ~/.local/state instead makes the failure mode inert: a leftover file
# does nothing at all. Cleanup is then a convenience, not a correctness
# requirement.
#
# Usage: detached-run.sh <label> <command> [args...]
#   detached-run.sh ts-update /bin/bash /path/to/upgrade-tailscale.sh
#
# Output goes to ~/Library/Logs/detached-<label>.log; the path is printed on
# stdout so a caller that is about to lose its connection knows where to look
# when it reconnects.

if [ "$#" -lt 2 ]; then
  echo "usage: detached-run.sh <label> <command> [args...]" >&2
  exit 2
fi

LAUNCHCTL_BIN="${LAUNCHCTL_BIN:-/bin/launchctl}"
PLISTBUDDY_BIN="${PLISTBUDDY_BIN:-/usr/libexec/PlistBuddy}"

label_raw="$1"; shift
# Labels become filenames and launchd service names. Reject anything that is not
# obviously safe rather than quoting around it — a label with a slash would
# write the plist somewhere unintended.
case "$label_raw" in
  ''|*[!A-Za-z0-9._-]*)
    echo "detached-run: label must match [A-Za-z0-9._-]+ (got '$label_raw')" >&2
    exit 2 ;;
esac

LABEL="com.jkrumm.detached.$label_raw"
STAGE_DIR="${DETACHED_RUN_STAGE_DIR:-$HOME/.local/state/detached-run}"
PLIST="$STAGE_DIR/$LABEL.plist"
LOG="$HOME/Library/Logs/detached-$label_raw.log"
UID_N=$(/usr/bin/id -u)

/bin/mkdir -p "$STAGE_DIR" "$(/usr/bin/dirname "$LOG")"

# A previous run under the same label may still be loaded. Boot it out first —
# bootstrap on an existing label fails with EEXIST, which would otherwise read
# as "the command failed" when the command never started.
"$LAUNCHCTL_BIN" bootout "gui/$UID_N/$LABEL" 2>/dev/null || true

# PlistBuddy rather than a heredoc: the command and its arguments are arbitrary
# strings, and hand-rolling XML escaping for them is how a path with an ampersand
# in it silently produces a corrupt plist.
/bin/rm -f "$PLIST"
"$PLISTBUDDY_BIN" -c "Add :Label string $LABEL" \
                  -c "Add :ProgramArguments array" \
                  -c "Add :RunAtLoad bool true" \
                  -c "Add :StandardOutPath string $LOG" \
                  -c "Add :StandardErrorPath string $LOG" \
                  -c "Add :ProcessType string Background" \
                  "$PLIST" >/dev/null

i=0
for arg in "$@"; do
  "$PLISTBUDDY_BIN" -c "Add :ProgramArguments:$i string $arg" "$PLIST" >/dev/null
  i=$(( i + 1 ))
done

# No KeepAlive key at all — absent means "run once and stay exited", which is
# the whole contract here. Setting it to false would be equivalent but invites
# someone to later flip it to true without realising this is a one-shot.
if ! "$LAUNCHCTL_BIN" bootstrap "gui/$UID_N" "$PLIST"; then
  echo "detached-run: failed to bootstrap $LABEL" >&2
  exit 1
fi

echo "detached-run: started $LABEL"
echo "  log:   $LOG"
echo "  stop:  launchctl bootout gui/$UID_N/$LABEL"
echo "  state: launchctl print gui/$UID_N/$LABEL"
