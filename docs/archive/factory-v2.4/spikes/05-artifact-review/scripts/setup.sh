#!/bin/bash
# Scratch install for spike 05. Nothing global: no hooks, no plugins, nothing outside $HOME_SPIKE.
#   plannotator: GitHub release binary, sha256 sidecar verified before first run
#   human-review: npm with a local prefix, lifecycle scripts off, the private registry config bypassed
set -euo pipefail
S="${HOME_SPIKE:-$HOME/.local/share/factory/spikes/05-review}"; PN_TAG="${PN_TAG:-v0.28.26}"; HR_VERSION="${HR_VERSION:-0.8.2}"
mkdir -p "$S"/{bin,home,downloads/plannotator,artifacts,out,projects/proj-alpha,projects/proj-beta}
: > "$S/home/.npmrc-empty"
gh release download "$PN_TAG" --repo backnotprop/plannotator --pattern 'plannotator-darwin-arm64*' --dir "$S/downloads/plannotator" --clobber
(cd "$S/downloads/plannotator" && shasum -a 256 -c plannotator-darwin-arm64.sha256)
install -m 0755 "$S/downloads/plannotator/plannotator-darwin-arm64" "$S/bin/plannotator"
npm install --prefix "$S/human-review" --userconfig "$S/home/.npmrc-empty" --ignore-scripts --no-audit --no-fund --loglevel=error "human-review@$HR_VERSION"
# the artifacts under review are copies; the originals are never opened by a review tool
cp "$HOME/SourceRoot/dotfiles/docs/factory/BRIEF.md" "$S/artifacts/BRIEF.md"
cp "$HOME/SourceRoot/jkrumm.com/public/diagrams/episode-lifecycle.html" "$S/artifacts/episode-lifecycle.html"
"$S/bin/plannotator" --version; node "$S/human-review/node_modules/human-review/src/cli.js" --version
