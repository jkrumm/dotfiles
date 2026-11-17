#!/usr/bin/env bash
# Build and install the host-agent collector (agent/manifest.yaml) into ~/.local/bin, pinned like the Beszel agent:
# the OpenTelemetry release (HOST_AGENT_VERSION) and the ocb release (OCB_VERSION) come from the Makefile, and the
# binary is rebuilt only when either or the manifest changes. No release binary exists for a custom ocb build, so the
# build is the install: Go (brew) fetches the pinned modules.
#
# Called by `make agent-setup`. Idempotent: a no-op while the stamp matches. A new binary over a loaded agent restarts it.
set -euo pipefail

VERSION="${HOST_AGENT_VERSION:?HOST_AGENT_VERSION not set}"
OCB="${OCB_VERSION:?OCB_VERSION not set}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../agent" && pwd)"
DEST="$HOME/.local/bin/host-agent"
STATE="$HOME/.local/state/host-agent"
STAMP="$STATE/built"
LABEL="com.jkrumm.host-agent"

want="$VERSION ocb-$OCB $(shasum -a 256 "$HERE/manifest.yaml" | awk '{print $1}')"
if [ -x "$DEST" ] && [ "$(cat "$STAMP" 2>/dev/null || true)" = "$want" ]; then
  echo "    ✓ host-agent $VERSION already installed"
  exit 0
fi

command -v go >/dev/null 2>&1 || { echo "  ✗ go not found — brew install go" >&2; exit 1; }

BUILDER_DIR="$HOME/.cache/host-agent"
BUILDER="$BUILDER_DIR/builder-$OCB"
mkdir -p "$BUILDER_DIR" "$STATE"
if [ ! -x "$BUILDER" ]; then
  echo "    → installing ocb $OCB..."
  GOBIN="$BUILDER_DIR/tmp" go install "go.opentelemetry.io/collector/cmd/builder@v$OCB"
  mv "$BUILDER_DIR/tmp/builder" "$BUILDER"
  rmdir "$BUILDER_DIR/tmp"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "    → building host-agent $VERSION (darwin/arm64)..."
(cd "$HERE" && CGO_ENABLED=0 GOFLAGS=-trimpath "$BUILDER" --config manifest.yaml --output-path "$TMP/build" >"$TMP/build.log" 2>&1) \
  || { cat "$TMP/build.log" >&2; echo "  ✗ build failed" >&2; exit 1; }
[ -x "$TMP/build/host-agent" ] || { echo "  ✗ the build produced no host-agent binary" >&2; exit 1; }

got="$("$TMP/build/host-agent" --version 2>&1 | awk '{print $NF}')"
[ "$got" = "$VERSION" ] || { echo "  ✗ built binary reports '$got', pinned $VERSION" >&2; exit 1; }

mkdir -p "$(dirname "$DEST")"
install -m 755 "$TMP/build/host-agent" "$DEST.new"
mv "$DEST.new" "$DEST"   # atomic: a running agent keeps its old inode
printf '%s\n' "$want" > "$STAMP"
echo "    ✓ host-agent $VERSION installed → $DEST"

if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
  launchctl kickstart -k "gui/$(id -u)/$LABEL" >/dev/null 2>&1 && echo "    ✓ $LABEL restarted on the new binary"
fi
