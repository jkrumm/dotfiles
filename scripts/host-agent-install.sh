#!/usr/bin/env bash
# Build and install the host-agent collector (agent/manifest.yaml) into ~/.local/bin, pinned like the other release binaries:
# the OpenTelemetry release (HOST_AGENT_VERSION) and the ocb release (OCB_VERSION) come from the Makefile, and the
# binary is rebuilt only when either or the manifest changes. No release binary exists for a custom ocb build, so the
# build is the install: Go (brew) fetches the pinned modules.
#
# One patch on top of the pinned release: the otlphttp exporter treats only 429, 502, 503 and 504 as retryable and every other
# status as permanent (no config option exists), so a Cloudflare 530 from the tunnel dropped a batch instead of holding it in
# the disk queue (Issue 2255). The build copies the pinned exporter module, makes every 5xx but 501 retryable, and points the
# manifest at the copy with a `replaces` entry.
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

PATCH="retry-5xx"
want="$VERSION ocb-$OCB $PATCH $(shasum -a 256 "$HERE/manifest.yaml" | awk '{print $1}')"
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
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

EXPORTER="go.opentelemetry.io/collector/exporter/otlphttpexporter"
echo "    → patching $EXPORTER v$VERSION ($PATCH)..."
SRC="$(cd "$TMP" && go mod download -json "$EXPORTER@v$VERSION" | sed -n 's/^[[:space:]]*"Dir": "\(.*\)",\{0,1\}$/\1/p')"
[ -f "$SRC/otlp.go" ] || { echo "  ✗ could not fetch $EXPORTER v$VERSION" >&2; exit 1; }
cp -R "$SRC" "$TMP/otlphttpexporter"
chmod -R u+w "$TMP/otlphttpexporter"
sed -i '' 's|^func isRetryableStatusCode(code int) bool {$|&\
	if code >= 500 \&\& code <= 599 \&\& code != http.StatusNotImplemented {\
		return true\
	}|' "$TMP/otlphttpexporter/otlp.go"
grep -q 'code >= 500 && code <= 599' "$TMP/otlphttpexporter/otlp.go" \
  || { echo "  ✗ the retry patch did not apply: isRetryableStatusCode changed upstream, update $0" >&2; exit 1; }
{ cat "$HERE/manifest.yaml"; printf 'replaces:\n  - %s => %s\n' "$EXPORTER" "$TMP/otlphttpexporter"; } > "$TMP/manifest.yaml"
echo "    → building host-agent $VERSION (darwin/arm64)..."
(cd "$TMP" && CGO_ENABLED=0 GOFLAGS=-trimpath "$BUILDER" --config manifest.yaml --output-path "$TMP/build" >"$TMP/build.log" 2>&1) \
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
