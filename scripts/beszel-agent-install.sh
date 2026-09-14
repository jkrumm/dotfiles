#!/usr/bin/env bash
# Pinned-release installer for the Beszel agent binary. Same pinning
# discipline as COLLIE_REF/XCADDY_VERSION in the Makefile: a GitHub release
# tarball, verified by sha256 BEFORE anything touches ~/.local/bin, upgraded
# only on a reviewed version+hash bump there. This replaces the Homebrew tap
# route (`henrygd/beszel/beszel-agent`), which hung twice in build.rb on
# pthread_once.
#
# Called by `make beszel-agent-setup` with BESZEL_AGENT_VERSION and
# BESZEL_AGENT_SHA256 exported from the Makefile's pins. Idempotent: a no-op
# once the installed binary already reports the pinned version.
set -euo pipefail

VERSION="${BESZEL_AGENT_VERSION:?BESZEL_AGENT_VERSION not set}"
SHA256="${BESZEL_AGENT_SHA256:?BESZEL_AGENT_SHA256 not set}"
DEST="$HOME/.local/bin/beszel-agent"

current=""
if [ -x "$DEST" ]; then
  current="$("$DEST" -v 2>/dev/null | awk '{print $2}')"
fi
if [ "$current" = "$VERSION" ]; then
  echo "    ✓ beszel-agent $VERSION already installed"
  exit 0
fi

URL="https://github.com/henrygd/beszel/releases/download/v${VERSION}/beszel-agent_darwin_arm64.tar.gz"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "    → downloading beszel-agent $VERSION..."
curl -fsSL -o "$TMP/beszel-agent.tar.gz" "$URL"

ACTUAL_SHA="$(shasum -a 256 "$TMP/beszel-agent.tar.gz" | awk '{print $1}')"
if [ "$ACTUAL_SHA" != "$SHA256" ]; then
  echo "  ✗ sha256 mismatch for beszel-agent $VERSION — refusing to install" >&2
  echo "    expected: $SHA256" >&2
  echo "    got:      $ACTUAL_SHA" >&2
  exit 1
fi

tar -xzf "$TMP/beszel-agent.tar.gz" -C "$TMP"
[ -f "$TMP/beszel-agent" ] || { echo "  ✗ tarball did not contain a beszel-agent binary" >&2; exit 1; }

mkdir -p "$(dirname "$DEST")"
install -m 755 "$TMP/beszel-agent" "$DEST"
echo "    ✓ beszel-agent $VERSION installed → $DEST (sha256 verified)"
