#!/bin/bash
# claude-account-sync.sh — bring the MacBook's claude-account level with the live factory release on the mini.
#
# Runs on the MacBook (the `claude-account-sync` verb of scripts/iumac-gate.sh, `make claude-account-link`,
# `make herdr-app-setup`). The MacBook has no software-factory checkout, so the built single file of
# packages/accounts (dist/claude-account) is pulled through the core (`hc exec --on mini`, already authenticated: no
# `ssh mini`, no 1Password), compared with the copy here, and swapped in only if it differs and `--version` runs.
#   unchanged  -> "claude-account <version line> (current)"
#   changed    -> "claude-account <version line> (updated)"
#   failed     -> the reason on stderr, exit 1, the running copy untouched
# No arguments. Idempotent; a second run at once exits 0 ("busy"). The copy is ~/.local/share/claude-account/claude-account;
# ~/.local/bin/claude-account points at it after `make claude-account-link`. docs/claude-accounts.md §Package.
#
# Test seams (tests only): CLAUDE_ACCOUNT_SYNC_DIR (the copy's parent), CLAUDE_ACCOUNT_SYNC_HC.
#
# Runs under /bin/bash 3.2: no associative arrays, no mapfile.
set -u

DEST="${CLAUDE_ACCOUNT_SYNC_DIR:-$HOME/.local/share/claude-account}"
LIVE="$DEST/claude-account"
HC="${CLAUDE_ACCOUNT_SYNC_HC:-hc}"
MAX_BYTES=5000000
REMOTE_CAT='cat "$HOME/.software-factory/current/packages/accounts/dist/claude-account"'

fail() {
  printf 'claude-account-sync: %s\n' "$*" >&2
  exit 1
}

[ $# -eq 0 ] || fail "takes no arguments"
mkdir -p "$DEST" || fail "cannot create $DEST"
export PATH="$PATH:$HOME/.bun/bin:/opt/homebrew/bin"   # appended: a forced-command session has a minimal PATH, an own bun wins

# One run at a time; a lock older than 10 minutes is a crashed run's.
LOCK="$DEST/.sync.lock"
[ -z "$(find "$LOCK" -maxdepth 0 -mmin +10 2>/dev/null)" ] || rm -rf "$LOCK"
mkdir "$LOCK" 2>/dev/null || { echo "claude-account busy (another sync is running)"; exit 0; }
WORK="$(mktemp -d "$DEST/.new.XXXXXX")" || { rmdir "$LOCK"; fail "no temp dir"; }
trap 'rm -rf "$WORK" "$LOCK"' EXIT

sum() { shasum -a 256 "$1" 2>/dev/null | cut -c1-64; }

# 1. Pull the live release's built file. It is data until it has run `--version`.
"$HC" exec --on mini sh -c "$REMOTE_CAT" >"$WORK/claude-account" 2>"$WORK/hc.err" ||
  fail "cannot read claude-account on the mini: $(head -c 300 "$WORK/hc.err")"
size="$(wc -c <"$WORK/claude-account")"
[ "$size" -gt 0 ] || fail "the pulled file is empty"
[ "$size" -le "$MAX_BYTES" ] || fail "the pulled file is over $MAX_BYTES bytes"
[ "$(head -c 19 "$WORK/claude-account")" = "#!/usr/bin/env bun" ] || fail "the pulled file is not a bun script"
new_sum="$(sum "$WORK/claude-account")"

# 2. Compare with the copy here.
if [ "$(sum "$LIVE")" = "$new_sum" ] && [ -x "$LIVE" ]; then
  printf 'claude-account %s (current)\n' "$("$LIVE" --version 2>/dev/null)"
  exit 0
fi

# 3. It must run and name the package before it replaces anything.
chmod +x "$WORK/claude-account"
ver="$("$WORK/claude-account" --version 2>"$WORK/ver.err")" || fail "the pulled file does not run, the running copy stays: $(head -c 300 "$WORK/ver.err")"
case "$ver" in "@software-factory/accounts "*) ;; *) fail "the pulled file reports '$ver', not the accounts package; the running copy stays" ;; esac

# 4. Swap: two renames, the first undone if the second fails.
rm -f "$LIVE.old"
if [ -e "$LIVE" ]; then mv "$LIVE" "$LIVE.old" || fail "cannot move the running copy aside"; fi
if ! mv "$WORK/claude-account" "$LIVE"; then
  [ ! -e "$LIVE.old" ] || mv "$LIVE.old" "$LIVE"
  fail "cannot move the new copy into place, the running copy stays"
fi
rm -f "$LIVE.old"
printf 'claude-account %s (updated)\n' "$ver"
