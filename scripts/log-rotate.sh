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
#
# ALSO SWEPT, once per run: stale Chrome code-sign clones. Every headless Chrome launch leaves a
# code_sign_clone.<random> directory under $(dirname DARWIN_USER_TEMP_DIR)/X/com.google.Chrome.code_sign_clone
# and nothing removes them (2026-10-17 on the mini: 62 dirs, du 128 GB; deleting the 61 older than 24 h
# freed 24 GB real, APFS shares blocks). sweep_chrome_clones removes those directories older than 2 h,
# skipping any that lsof reports open. Only that one root is touched — net.imput.helium.code_sign_clone
# and every other sibling are out of scope. CHROME_CLONE_ROOT overrides the root (the test suite uses it).
# BOUNDED: 2026-11-11 the mini held 14k clones (agents' ad-hoc Playwright scripts launch ~300 Chrome/h) and
# a serial `lsof +D` + `rm -rf` per 2 GB bundle ran 19+ min at load 80-165 (Beszel page, issue 829). So the
# open set is ONE lsof for the whole root, rm runs at background IO/CPU priority (taskpolicy -b), and a run
# stops after CHROME_CLONE_MAX removals (default 1500) or CHROME_CLONE_BUDGET_S seconds (default 600); the
# backlog drains over successive runs instead of in one burst.
# RATE (issue 839, Beszel "disk filling fast", 16-49 GB/h): the sweep first ran hourly, 400 removals,
# age gate 24 h, while ~300-600 clones/h were created (basalt-ui layout tests launch Chrome per test) —
# the stock only grew, 14k clones, ~25 GB freed per 400. The gate is now CHROME_CLONE_MIN_AGE_MIN
# (default 120; lsof still guards any clone a running Chrome holds), removals run 4 wide, and the plist
# runs every 15 min, so the stock stays near two hours of creation instead of a day's.
# On a machine without the root (Linux, other Macs) it logs one line and does nothing.

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
# - hermes-ops.log: one audit line per invocation of the bounded dispatcher,
#   the only record of what Hermes did unattended. Rotated, not deleted.
# - claude-relogin.log: the windowless MacBook relogin worker's output (redacted, owner-only), written by
#   scripts/claude-relogin.sh, no plist names it.
# - Homebrew service logs under /opt/homebrew/var/log (launchd-written, user-owned, O_APPEND like any plist
#   stream): only the ones that grow without bound. Measured 2026-11-06 on the mini: tailscaled.log 121 MB,
#   postgresql@18.log 60 MB; colima/herdr/caddy are under 250 KB, and the caddy logs are root-owned and
#   rotated by caddy itself.
EXTRA=(
  /opt/homebrew/var/log/tailscaled.log
  /opt/homebrew/var/log/postgresql@18.log
  "$HOME/.hermes/logs/gateway.error.log"
  "$HOME/.hermes/logs/gateway.log"
  hermes-ops.log
  claude-relogin.log
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

sweep_chrome_clones() {
  local root=${CHROME_CLONE_ROOT:-} tmp before after removed=0 d
  if [ -z "$root" ]; then
    tmp=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)
    tmp=${tmp%/}
    [ -n "$tmp" ] && root="$(dirname "$tmp")/X/com.google.Chrome.code_sign_clone"
  fi
  if [ -z "$root" ] || [ ! -d "$root" ]; then
    echo "chrome-clone: no root${root:+ at $root} — nothing to sweep"
    return 0
  fi
  if [ ! -x /usr/sbin/lsof ]; then
    echo "chrome-clone: /usr/sbin/lsof missing — cannot check open clones, sweep skipped"
    return 0
  fi
  local max=${CHROME_CLONE_MAX:-1500} budget=${CHROME_CLONE_BUDGET_S:-600} capped="" open proot all
  local -a lowprio=()
  [ -x /usr/sbin/taskpolicy ] && lowprio=(/usr/sbin/taskpolicy -b)
  # One lsof for the whole system, reduced to the clone directory names something holds open.
  proot=$(cd "$root" && pwd -P) # lsof prints resolved paths (/private/var/...)
  # lsof exits non-zero when it cannot stat some file; that is not a failure. No output at all is
  # (it would read as "nothing open"), so the sweep fails closed.
  all=$(/usr/sbin/lsof -w -n -F n 2>/dev/null || true)
  if [ -z "$all" ]; then
    echo "chrome-clone: lsof returned nothing — cannot tell which clones are open, sweep skipped"
    return 0
  fi
  open=$(printf '%s\n' "$all" | awk -v r="$proot/" 'index($0, "n" r) == 1 {
    p = substr($0, length(r) + 2); sub("/.*", "", p); print p }' | sort -u)
  before=$(df -k "$root" | awk 'NR==2 {print $4}')
  SECONDS=0
  # Removals run in batches of 16 across 4 workers (one serial rm of a 2 GB bundle is ~1.3 s, so
  # a serial sweep clears ~2.7k/h at best), and the cap and budget are checked between batches.
  local -a batch=()
  flush_batch() {
    [ "${#batch[@]}" -gt 0 ] || return 0
    printf '%s\0' "${batch[@]}" | ${lowprio[@]+"${lowprio[@]}"} xargs -0 -n 1 -P 4 rm -rf --
    removed=$((removed + ${#batch[@]}))
    batch=()
  }
  while IFS= read -r -d '' d; do
    if [ $((removed + ${#batch[@]})) -ge "$max" ] || [ "$SECONDS" -ge "$budget" ]; then
      capped=" (cap reached, rest next run)"
      break
    fi
    if printf '%s\n' "$open" | grep -qxF -- "${d##*/}"; then
      echo "chrome-clone: $d is open — kept"
      continue
    fi
    batch+=("$d")
    [ "${#batch[@]}" -ge 16 ] && flush_batch
  done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -name 'code_sign_clone.*' -mmin "+${CHROME_CLONE_MIN_AGE_MIN:-120}" -print0)
  flush_batch
  after=$(df -k "$root" | awk 'NR==2 {print $4}')
  echo "chrome-clone: $removed removed from $root${capped}, free space +$(( (after - before) / 1024 )) MB"
}

sweep_chrome_clones

echo "$(date '+%Y-%m-%d %H:%M:%S') log-rotate: $checked checked, $rotated rotated (cap ${MAX_BYTES} bytes)"
