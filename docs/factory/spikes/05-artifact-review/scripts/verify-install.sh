#!/bin/bash
# Read-only record of what is installed in the scratch tree: versions, checksum against the release sidecar, dependency list.
set -u; source "$(dirname "$0")/lib.sh"
echo "plannotator: $("$S/bin/plannotator" --version)   binary $(du -h "$S/bin/plannotator" | cut -f1)"
echo "  sha256 installed: $(shasum -a 256 "$S/bin/plannotator" | cut -d' ' -f1)"
echo "  sha256 release sidecar: $(cut -d" " -f1 $S/downloads/plannotator*/plannotator-darwin-arm64.sha256 2>/dev/null | head -1 || echo 'sidecar not kept')"
echo "human-review: $(node "$S/human-review/node_modules/human-review/src/cli.js" --version)   installed size $(du -sh "$S/human-review/node_modules" | cut -f1)"
echo "  dependencies: $(jq -c '.dependencies' "$S/human-review/node_modules/human-review/package.json")   lifecycle scripts: $(jq -c '.scripts | del(.test, .start)' "$S/human-review/node_modules/human-review/package.json")"
echo "  node_modules: $(ls "$S/human-review/node_modules" | tr '\n' ' ')"
