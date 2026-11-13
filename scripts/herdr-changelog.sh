#!/bin/bash
# herdr-changelog.sh — the upstream changelog sections newer than what is installed, for the core and (MacBook) the app.
#
#   herdr-changelog.sh            core since `hc --version`, app since ~/Applications/Herdr.app when it exists
#   herdr-changelog.sh core 0.1.18 | app 0.1.13      explicit installed version
#
# Reads herdrdev/herdr-core and herdrdev/herdr-app CHANGELOG.md on the master branch (public). Prints the sections
# above the installed version, newest first, so /upgrade-deps can triage them (docs/herdr-core.md §Reading the changelogs).
# Read-only. bash 3.2. Overrides (tests): CHANGELOG_BASE, HC_BIN, APP_PLIST.

set -u
BASE="${CHANGELOG_BASE:-https://raw.githubusercontent.com/herdrdev}"
HC_BIN="${HC_BIN:-$HOME/.local/bin/hc}"
APP_PLIST="${APP_PLIST:-$HOME/Applications/Herdr.app/Contents/Info.plist}"

# Sections strictly newer than $2, from the changelog on stdin: stop at the heading of the installed version.
newer_than() {
  awk -v have="$1" '
    /^## \[/ { v = $2; gsub(/[\[\]]/, "", v); if (v == have) exit; if (v == "Unreleased") next; on = 1 }
    on { print }'
}

show() { # kind repo installed
  local kind="$1" repo="$2" have="$3" body
  [ -n "$have" ] || { echo "  · $kind: not installed here"; return 0; }
  body=$(curl -fsSL "$BASE/$repo/master/CHANGELOG.md" 2>/dev/null) || { echo "  ✗ $kind: cannot read $BASE/$repo/master/CHANGELOG.md" >&2; return 1; }
  printf '%s\n' "$body" | grep -q "^## \[$have\]" || echo "  ! $kind: installed $have has no heading in the changelog, showing all of it"
  echo "== $kind changelog since $have"
  printf '%s\n' "$body" | newer_than "$have"
}

case "${1:-}" in
  core) show core herdr-core "${2:-}" ;;
  app) show app herdr-app "${2:-}" ;;
  *)
    show core herdr-core "$("$HC_BIN" --version 2>/dev/null | awk '{print $2}')"
    app=""
    [ -f "$APP_PLIST" ] && app=$(plutil -extract CFBundleShortVersionString raw "$APP_PLIST" 2>/dev/null)
    show app herdr-app "$app"
    ;;
esac
