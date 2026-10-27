#!/usr/bin/env bash
# Pinned-release installer for `xcodes` (Xcode version manager) into ~/.local/bin.
# The Homebrew build of xcodes is broken, so the signed release binary is fetched
# instead — same discipline as install of beszel-agent: sha256 of the release zip is
# checked BEFORE anything touches ~/.local/bin, then the Developer ID signature (team
# id) is verified on the extracted binary. Bump XCODES_VERSION + XCODES_SHA256 together
# after reading the release notes. Idempotent: a no-op once the pinned version is installed.
set -euo pipefail

XCODES_VERSION="${XCODES_VERSION:-2.1.0}"
XCODES_SHA256="${XCODES_SHA256:-f1519afe934a513e85dd9b32fc872394becbbb6a41db15d9ac3926a09a891888}"
XCODES_TEAM_ID="ZU6GR6B2FY"
DEST="$HOME/.local/bin/xcodes"

if [ -x "$DEST" ] && [ "$("$DEST" version 2>/dev/null | head -1)" = "$XCODES_VERSION" ]; then
  echo "    ✓ xcodes $XCODES_VERSION already installed"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL -o "$TMP/xcodes.zip" "https://github.com/XcodesOrg/xcodes/releases/download/${XCODES_VERSION}/xcodes.zip"

actual="$(shasum -a 256 "$TMP/xcodes.zip" | awk '{print $1}')"
if [ "$actual" != "$XCODES_SHA256" ]; then
  echo "    ✗ xcodes $XCODES_VERSION checksum mismatch (expected $XCODES_SHA256, got $actual)" >&2
  exit 1
fi

unzip -q "$TMP/xcodes.zip" -d "$TMP/out"
codesign --verify --strict "$TMP/out/xcodes"
sig="$(codesign -dv "$TMP/out/xcodes" 2>&1)"
if ! grep -q "^TeamIdentifier=${XCODES_TEAM_ID}$" <<<"$sig"; then
  echo "    ✗ xcodes signature is not from team ${XCODES_TEAM_ID}" >&2
  exit 1
fi

mkdir -p "$(dirname "$DEST")"
install -m 0755 "$TMP/out/xcodes" "$DEST"
echo "    ✓ xcodes $XCODES_VERSION installed to $DEST"
