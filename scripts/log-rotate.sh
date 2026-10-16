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
# password is deliberately MacBook-only (see dotfiles AGENTS.md, Secrets). A
# rotation that cannot be installed headlessly is not a rotation.
#
# The file list is DERIVED, never hand-kept and never globbed. ~/Library/Logs also holds
# Apple and vendor logs (PhotosSearch.aapbz, Homebrew/, DiagnosticReports/) and truncating
# someone else's log because it matched *.log is a bug waiting for a bad week. So the
# list is exactly the StandardOutPath/StandardErrorPath of the plists WE install —
# labels com.jkrumm.* and com.iu.* — and nothing else. A new agent's logs are rotated
# the moment its plist lands; a retired agent's stop being rotated the moment its plist goes.
# EXTRA below is the only hand list: audit logs our scripts append to that no plist names.

set -euo pipefail

LOG_DIR="${LOG_ROTATE_DIR:-$HOME/Library/Logs}"

# Rotate at 16 MB, keep one previous generation → ~32 MB ceiling per stream.
# Sized against the worst observed producer (walkingpad.err, ~6 MB/day): a
# 16 MB cap at an hourly cadence means a rotation every ~3 days, and even a
# crash-looping agent writing continuously cannot exceed the cap by more than
# one hour's output.
MAX_BYTES="${LOG_ROTATE_MAX_BYTES:-16777216}"

PLIST_DIR="${LOG_ROTATE_PLIST_DIR:-$HOME/Library/LaunchAgents}"

# Not LaunchAgent logs, so no plist names them, and not ours to derive:
# - the Hermes gateway's own launchd streams (`hermes gateway install` writes that plist
#   upstream, pointing at ~/.hermes/logs). Hermes rotates agent.log itself but NOT these
#   two; one was found at 115 MB on 2026-08-25 (a reconnect task retrying every 10 s for
#   48 hours), so they stay capped.
# - hermes-ops.log / warden-cli.log: one audit line per invocation of the bounded
#   dispatchers, the only record of what Hermes did unattended. Rotated, not deleted.
# - the herdr collie plugin's own log.
EXTRA=(
  "$HOME/.hermes/logs/gateway.error.log"
  "$HOME/.hermes/logs/gateway.log"
  hermes-ops.log
  warden-cli.log
  "$HOME/.config/herdr/plugins/config/herdr.collie/collie.log"
)

# Log paths of every com.jkrumm.* / com.iu.* plist, one per line. log-rotate's own log stays
# out (see its plist: truncating the file it is writing to), and anything outside $HOME
# (/dev/null, /var/log) is not ours to truncate.
derive_files() {
  local plist label key path
  for plist in "$PLIST_DIR"/com.jkrumm.*.plist "$PLIST_DIR"/com.iu.*.plist; do
    [ -f "$plist" ] || continue
    label=$(basename "$plist" .plist)
    [ "$label" = "com.jkrumm.log-rotate" ] && continue
    for key in StandardOutPath StandardErrorPath; do
      path=$(/usr/bin/plutil -extract "$key" raw -o - -- "$plist" 2>/dev/null) || continue
      # A symlink under $HOME could point at a non-log file; cp and `: >` would follow it.
      [ -L "$path" ] && { echo "warn: $path ($label) is a symlink — not rotated" >&2; continue; }
      case "$path" in "$HOME"/*) printf '%s\n' "$path" ;; esac
    done
  done
}

FILES=()
while IFS= read -r line; do FILES+=("$line"); done < <({ derive_files; printf '%s\n' "${EXTRA[@]}"; } | awk '!seen[$0]++')

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
