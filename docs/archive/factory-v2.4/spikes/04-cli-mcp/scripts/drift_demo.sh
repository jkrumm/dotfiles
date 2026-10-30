#!/usr/bin/env bash
# Demonstrate the routing-block drift check: in sync (exit 0), a CLI changes its --help (exit 1,
# diff shown), a missing block (exit 2), back in sync. The "CLI change" is simulated with a shim
# that renames `--scope` to `--range` in agw's help text; no real CLI or file is modified.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRATCH="${SPIKE_SCRATCH:-$HOME/.local/share/factory/spikes/04-cli-mcp}"
export PATH="$SCRATCH/bin:$PATH"
cd "$HERE/.." || exit 1  # run from the spike directory so printed paths stay relative
TARGET="${1:-routing-block.md}"
REAL_AGW="$(command -v agw)"
SHIM="$(mktemp -d)"
trap 'rm -rf "$SHIM"' EXIT

step() { printf '\n$ %s\n' "$*"; }

step "render_routing.py --write routing-block.md"
python3 "$HERE/render_routing.py" --write "$TARGET"

step "render_routing.py --check routing-block.md   # CLIs unchanged"
python3 "$HERE/render_routing.py" --check "$TARGET"; echo "exit=$?"

cat > "$SHIM/agw" <<EOF
#!/bin/sh
if [ "\$1" = "--help" ]; then "$REAL_AGW" --help | sed 's/--scope S/--range S/'; else exec "$REAL_AGW" "\$@"; fi
EOF
chmod +x "$SHIM/agw"
step "PATH=<shim>:\$PATH render_routing.py --check routing-block.md   # agw renamed --scope to --range"
PATH="$SHIM:$PATH" python3 "$HERE/render_routing.py" --check "$TARGET"; echo "exit=$?"

printf '# no block here\n' > "$SHIM/empty.md"
step "render_routing.py --check empty.md   # a file without markers"
(cd "$SHIM" && python3 "$HERE/render_routing.py" --check empty.md); echo "exit=$?"

step "render_routing.py --check routing-block.md   # shim gone, back in sync"
python3 "$HERE/render_routing.py" --check "$TARGET"; echo "exit=$?"
