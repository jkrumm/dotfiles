#!/usr/bin/env bash
# Rotate the LaunchAgent logs this repo owns. Hourly, via
# com.jkrumm.log-rotate (see scripts/com.jkrumm.log-rotate.plist.template).
#
# WHY THIS EXISTS. /tmp/walkingpad.err reached 35 MB growing ~1 line/sec with
# nothing rotating it, and the only thing that ever truncated any of these logs
# was macOS's periodic /tmp cleanup — which does not truncate, it DELETES,
# leaving every KeepAlive agent writing into an unlinked inode (WP9). Moving the
# logs to ~/Library/Logs fixes the unlinked-inode half and removes the accidental
# size cap in the same stroke, so an explicit rotation has to replace it.
#
# WHY COPYTRUNCATE, NOT RENAME. launchd opens StandardOutPath/StandardErrorPath
# ONCE at spawn and there is no way to tell it to reopen — no SIGHUP contract,
# nothing. Renaming the file therefore does exactly what the /tmp sweep did: the
# fd follows the inode and every later line lands in the rotated file forever,
# while the "live" log stays empty. Truncating in place keeps the inode, and
# launchd's fds are O_APPEND (probed directly on this machine with a throwaway
# agent 2026-07-31: after `: > log` the next write landed at offset 0, apparent
# size 211 bytes, 8 blocks — not a 4 MB sparse hole), so writes resume at the
# start of the file. The cp-then-truncate window can lose the lines written
# between the two calls; that is the accepted cost of the only technique that
# works against a process you cannot signal.
#
# WHY newsyslog IS NOT USED. /etc/newsyslog.d needs root, and this machine's root
# password is deliberately MacBook-only (see dotfiles CLAUDE.md, Secrets). A
# rotation that cannot be installed headlessly is not a rotation.
#
# The file list is DECLARED, never globbed. ~/Library/Logs also holds Apple and
# vendor logs (cmux-update.log, PhotosSearch.aapbz, Homebrew/, DiagnosticReports/)
# and truncating someone else's log because it matched *.log is a bug waiting for
# a bad week.

set -euo pipefail

LOG_DIR="${LOG_ROTATE_DIR:-$HOME/Library/Logs}"

# Rotate at 16 MB, keep one previous generation → ~32 MB ceiling per stream.
# Sized against the worst observed producer (walkingpad.err, ~6 MB/day): a
# 16 MB cap at an hourly cadence means a rotation every ~3 days, and even a
# crash-looping agent writing continuously cannot exceed the cap by more than
# one hour's output.
MAX_BYTES="${LOG_ROTATE_MAX_BYTES:-16777216}"

# Every log written by a LaunchAgent this repo installs or owns. Paths are
# relative to LOG_DIR unless absolute.
FILES=(
  sideclaw.log
  sideclaw.err
  litellm.log
  litellm.err
  walkingpad.log
  walkingpad.err
  usage-tracker.log
  usage-tracker.err
  brain-backup.log
  brain-sync.log
  hermes-liveness.log
  hermes-liveness.err
  hermes-backup.log
  hermes-backup.err
  hermes-webui.log
  hermes-webui.err
  hermes-webui-liveness.log
  hermes-webui-liveness.err
  hermes-serve.log
  hermes-serve.err
  hermes-serve-liveness.log
  hermes-serve-liveness.err
  # The Hermes gateway's OWN launchd streams. Absolute because `hermes gateway
  # install` generates that plist and points it at ~/.hermes/logs, not
  # ~/Library/Logs, and the plist is upstream's to write — this list bends to it
  # rather than the other way round.
  #
  # Hermes rotates agent.log and errors.log itself (agent.log.1/.2/.3), but NOT
  # these two, and nothing else did either. Found at 115 MB on 2026-08-25: a
  # slack_bolt reconnect task whose aiohttp session had been closed retried every
  # 10s for 48 hours — ~17,300 identical lines — and the file simply grew. The
  # size was the only durable evidence that anything was wrong, which is the
  # argument for capping it, not for leaving it as an accidental flight recorder.
  "$HOME/.hermes/logs/gateway.error.log"
  "$HOME/.hermes/logs/gateway.log"
  # Not a LaunchAgent log: hermes-agent/scripts/hermes-ops.sh appends one audit
  # line per invocation, so it grows with agent activity rather than on a
  # schedule. It is the only record of what Hermes did unattended, so it is
  # rotated rather than truncated.
  hermes-ops.log
  # Same shape, for the other bounded dispatcher: hermes-agent/scripts/hermes-cc.sh
  # appends one audit line per invocation — including refusals — and is the only
  # record of which repos Hermes opened a Claude Code episode against.
  hermes-cc.log
  secrets-freshness.log
  opbackup.log
  # The MacBook's userland sshd on :2222 — the only door the mini has back to
  # this machine. Its plist is KeepAlive-on-failure with a 10s throttle, so a
  # tailscaled that never hands out an IP turns .err into one respawn message
  # every 10 seconds with nothing to stop it.
  tailnet-sshd.log
  tailnet-sshd.err
  # The MacBook's forwards into the mini's dev databases. The one log here whose
  # agent holds a SINGLE fd open for the life of the tunnel, so a rename-based
  # rotation would leave it writing to a deleted inode until the next respawn —
  # copytruncate, which is what this script does, is safe for exactly this shape.
  # Its plist says so; this line is what makes that true. An unreachable mini is
  # a normal laptop state and each retry logs a line, so it grows with lid-closes
  # rather than on a schedule.
  db-tunnel.log
  devhost-health.log
  drift-check.log
  drift-check.err
  lock-at-boot.log
  linewatch-collector.log
  batt-reset.log
  "$HOME/.config/herdr/plugins/config/herdr.collie/collie.log"
)

rotated=0
checked=0

for entry in "${FILES[@]}"; do
  case "$entry" in
    /*) f="$entry" ;;
    *)  f="$LOG_DIR/$entry" ;;
  esac

  [ -f "$f" ] || continue
  checked=$((checked + 1))

  size=$(stat -f '%z' "$f" 2>/dev/null || echo 0)
  [ "$size" -gt "$MAX_BYTES" ] || continue

  # copytruncate. `cp` (not mv) so the inode the agent holds open survives;
  # the truncate is a separate step so a failed cp leaves the live log intact
  # rather than silently discarding it.
  if cp "$f" "$f.1" 2>/dev/null; then
    : > "$f"
    rotated=$((rotated + 1))
    echo "rotated $f (${size} bytes → $f.1)"
  else
    echo "warn: could not copy $f — left untouched" >&2
  fi
done

echo "$(date '+%Y-%m-%d %H:%M:%S') log-rotate: $checked checked, $rotated rotated (cap ${MAX_BYTES} bytes)"
