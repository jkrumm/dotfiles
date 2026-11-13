#!/bin/bash
# herdr-core-preflight.sh — read-only checks before `hc update` (docs/herdr-core.md §Updates).
#
#   1. latest core release vs the installed one (exit 3 when already current)
#   2. the release tarball: SHA-256 from the manifest, then its Herdr Core.app signing requirement against the
#      installed bundle's. Same requirement = the Full Disk Access grant survives; different = re-grant (exit 4).
#   3. the live agents: any terminal with status "working" is a turn in flight (exit 5 unless FORCE=1).
#
# Prints the release notes. Never touches the installed core. Download lands in its own fresh temp dir.
# bash 3.2. Overrides (tests): HC_BIN, APP_PATH, LATEST_URL, CURL_BIN.

set -u

HC_BIN="${HC_BIN:-$HOME/.local/bin/hc}"
APP_PATH="${APP_PATH:-$HOME/.local/share/herdr-core/active/Herdr Core.app}"
LATEST_URL="${LATEST_URL:-https://releases.herdr.dev/core/latest.json}"
CURL_BIN="${CURL_BIN:-curl}"

fail() { echo "  ✗ $1" >&2; exit "${2:-1}"; }

installed=$("$HC_BIN" --version 2>/dev/null | awk '{print $2}')
[ -n "$installed" ] || fail "hc --version gave nothing"

meta=$("$CURL_BIN" -fsSL "$LATEST_URL") || fail "cannot read $LATEST_URL"
latest=$(printf '%s' "$meta" | jq -r .version)
[ -n "$latest" ] && [ "$latest" != null ] || fail "no version in $LATEST_URL"

echo "  installed $installed, latest $latest"
if [ "$installed" = "$latest" ]; then
  echo "  · already current"
  exit 3
fi
# Headlines (the bold items) of every release between the two; the full text and the app: scripts/herdr-changelog.sh.
echo "  changelog headlines since $installed (full: scripts/herdr-changelog.sh, triage: skills/upgrade-deps herdr-core step 1):"
bash "$(dirname "$0")/herdr-changelog.sh" core "$installed" 2>/dev/null | grep -E '^## \[|^- \*\*|^- `hc ' | cut -c1-200 | sed 's/^/    /'

# 2. Signing requirement of the new bundle must equal the installed one.
url=$(printf '%s' "$meta" | jq -r '.targets["macos-aarch64"].url')
sha=$(printf '%s' "$meta" | jq -r '.targets["macos-aarch64"].sha256')
[ "$(uname -m)" = arm64 ] || fail "preflight knows macos-aarch64 only" 1
dir=$(mktemp -d) || fail "no temp dir"
trap 'rm -rf "$dir"' EXIT
"$CURL_BIN" -fsSL "$url" -o "$dir/core.tgz" || fail "download failed: $url"
printf '%s  %s\n' "$sha" "$dir/core.tgz" | shasum -a 256 -c - >/dev/null 2>&1 || fail "SHA-256 mismatch for $url"
mkdir "$dir/x" && tar -xzf "$dir/core.tgz" -C "$dir/x" || fail "unpack failed"
new_app="$dir/x/Herdr Core.app"
[ -d "$new_app" ] || fail "tarball has no Herdr Core.app"
codesign --verify --deep --strict "$new_app" 2>/dev/null || fail "new bundle fails codesign --verify"
spctl -a "$new_app" >/dev/null 2>&1 || fail "new bundle is not notarized (spctl)"

req_new=$(codesign -dr - "$new_app" 2>&1 | grep '^designated')
req_old=$(codesign -dr - "$APP_PATH" 2>&1 | grep '^designated')
[ -n "$req_new" ] && [ -n "$req_old" ] || fail "cannot read a designated requirement"
if [ "$req_new" = "$req_old" ]; then
  echo "  ✓ signing requirement unchanged: the Full Disk Access grant carries over"
else
  echo "  ✗ signing requirement CHANGED: Full Disk Access on Herdr Core.app must be re-granted at the screen after the update" >&2
  echo "    old: $req_old" >&2
  echo "    new: $req_new" >&2
  exit 4
fi

# 3. Turns in flight.
working=$("$HC_BIN" ls 2>/dev/null | jq -r '.terminals[] | select(.status == "working") | "    " + .address + "  " + (.name // .where // "-")')
if [ -n "$working" ]; then
  echo "  working agents (an update may end the program in a terminal, upstream herdr-core #133):"
  echo "$working"
  [ "${FORCE:-0}" = 1 ] || fail "wait until they are idle or done, or rerun with FORCE=1" 5
  echo "  · FORCE=1: continuing"
else
  echo "  ✓ no agent mid-turn"
fi
