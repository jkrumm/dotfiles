#!/bin/bash
# herdr-glance-sync.sh — bring the Herdr app's jk-glance mod level with the live factory release on the mini.
#
# Runs on the MacBook (the `herdr-glance-sync` verb of scripts/iumac-gate.sh, `make herdr-app-setup`). Pulls the
# mod through the core (`hc exec --on mini`, already authenticated: no `ssh mini`, no 1Password), compares it with
# the copy the app loads, and only if it differs and `herdr-app check` passes swaps it in and reloads the layout.
#   unchanged  -> "jk-glance <12 hex> (current)"
#   changed    -> "jk-glance <12 hex> (updated)"
#   failed     -> the reason on stderr, exit 1, the running copy untouched
# No arguments. Idempotent; a second run at once exits 0 ("busy"). docs/herdr-core.md §Desktop layout.
#
# Test seams (tests only): HERDR_GLANCE_DIR (the copy's parent), HERDR_APP_HOME, HERDR_GLANCE_HC, HERDR_GLANCE_APP.
# HERDR_GLANCE_NO_RELOAD=1 skips the layout reload (herdr-app-setup.sh reloads once itself).
#
# Runs under /bin/bash 3.2: no associative arrays, no mapfile.
set -u

DEST="${HERDR_GLANCE_DIR:-$HOME/.local/share/herdr-app}"
LIVE="$DEST/jk-glance"
LINK="${HERDR_APP_HOME:-$HOME/.config/herdr-app}/mods/jk-glance"
HC="${HERDR_GLANCE_HC:-hc}"
APP="${HERDR_GLANCE_APP:-herdr-app}"
MAX_BYTES=2000000
REMOTE_TAR='tar -C "$HOME/.software-factory/current/integrations/herdr" -cf - jk-glance'

fail() {
  printf 'herdr-glance-sync: %s\n' "$*" >&2
  exit 1
}

[ $# -eq 0 ] || fail "takes no arguments"
mkdir -p "$DEST" || fail "cannot create $DEST"

# One run at a time; a lock older than 10 minutes is a crashed run's.
LOCK="$DEST/.glance-sync.lock"
[ -z "$(find "$LOCK" -maxdepth 0 -mmin +10 2>/dev/null)" ] || rm -rf "$LOCK"
mkdir "$LOCK" 2>/dev/null || { echo "jk-glance busy (another sync is running)"; exit 0; }
WORK="$(mktemp -d "$DEST/.glance-new.XXXXXX")" || { rmdir "$LOCK"; fail "no temp dir"; }
trap 'rm -rf "$WORK" "$LOCK"' EXIT

# digest <dir> — one sha256 over the two files that carry the version (empty when either is missing).
digest() {
  [ -f "$1/main.js" ] && [ -f "$1/mod.json" ] || return 0
  (cd "$1" && shasum -a 256 main.js mod.json | shasum -a 256 | cut -c1-64)
}

# 1. Pull the live release's glance. The tar is data: its listing is checked before anything is extracted.
"$HC" exec --on mini sh -c "$REMOTE_TAR" >"$WORK/glance.tar" 2>"$WORK/hc.err" ||
  fail "cannot read the glance on the mini: $(head -c 300 "$WORK/hc.err")"
[ "$(wc -c <"$WORK/glance.tar")" -le "$MAX_BYTES" ] || fail "the glance tar is over $MAX_BYTES bytes"
bad="$(tar -tvf "$WORK/glance.tar" 2>/dev/null | awk '$1 !~ /^[-d]/ { print; exit }')"
[ -z "$bad" ] || fail "the glance tar holds a link or special file: $bad"
bad="$(tar -tf "$WORK/glance.tar" 2>/dev/null | awk '$0 !~ /^jk-glance(\/|$)/ || $0 ~ /(^|\/)\.\.(\/|$)/ { print; exit }')"
[ -z "$bad" ] || fail "the glance tar holds a path outside jk-glance: $bad"
mkdir "$WORK/new" && tar -xf "$WORK/glance.tar" -C "$WORK/new" || fail "cannot extract the glance tar"
NEW="$WORK/new/jk-glance"
new_sum="$(digest "$NEW")"
[ -n "$new_sum" ] || fail "the pulled glance has no main.js and mod.json"

# 2. Compare with the copy the app loads.
if [ "$(digest "$LIVE")" = "$new_sum" ]; then
  printf 'jk-glance %s (current)\n' "${new_sum:0:12}"
  exit 0
fi

# 3. Check a copy (herdr-app check writes gpui-kit.d.ts next to the mod; the live dir is never written).
mkdir "$WORK/check" && cp -R "$NEW" "$WORK/check/jk-glance" || fail "cannot copy the glance for the check"
"$APP" check "$WORK/check/jk-glance" >"$WORK/check.out" 2>&1 ||
  fail "herdr-app check failed, the running copy stays: $(head -c 600 "$WORK/check.out")"

# 4. Swap: two renames, the first undone if the second fails.
rm -rf "$LIVE.old"
if [ -e "$LIVE" ]; then mv "$LIVE" "$LIVE.old" || fail "cannot move the running copy aside"; fi
if ! mv "$NEW" "$LIVE"; then
  [ ! -e "$LIVE.old" ] || mv "$LIVE.old" "$LIVE"
  fail "cannot move the new copy into place, the running copy stays"
fi
rm -rf "$LIVE.old"
if [ -d "$(dirname "$LINK")" ] && [ "$(readlink "$LINK" 2>/dev/null)" != "$LIVE" ]; then
  ln -sfn "$LIVE" "$LINK" || fail "cannot link $LINK"
fi

# 5. Reload: switching away and back makes the app read the mod again; only when the app answers.
if [ -z "${HERDR_GLANCE_NO_RELOAD:-}" ] && "$APP" status >/dev/null 2>&1; then
  "$APP" "do" layout.switch --name main >/dev/null 2>&1
  for _ in $(seq 20); do "$APP" status 2>/dev/null | grep -q '"layout": "main"' && break; sleep 0.25; done
  "$APP" "do" layout.switch --name jk >/dev/null 2>&1 || fail "copied, but layout.switch jk failed (herdr-app status)"
fi
printf 'jk-glance %s (updated)\n' "${new_sum:0:12}"
