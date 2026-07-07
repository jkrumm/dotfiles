#!/usr/bin/env bash
# Nightly git-level safety-net snapshot of the brain vault.
#
# Captures the full working tree — including untracked notes, and respecting
# .gitignore so gitignored secrets (_device-settings, .obsidian/plugins/*/
# data.json, …) never enter the snapshot — into a commit stored under
# refs/snapshots/<ts>. It NEVER touches master, HEAD, the index, or the working
# tree: the tree is built in an isolated temp index. LiveSync (CouchDB) is the
# real cross-device backup; git stays the deliberate `git diff` review gate.
# This is only a git-level net so an un-reviewed day of edits is never lost, and
# it deliberately writes to a separate ref namespace so it can't muddy the
# reviewed history. Inspect: `git -C <vault> for-each-ref refs/snapshots`.
set -euo pipefail

# launchd hands agents a minimal PATH — make sure git resolves either way.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

VAULT="${BRAIN_VAULT:-$HOME/SourceRoot/brain}"
cd "$VAULT" 2>/dev/null || { echo "brain-snapshot: vault not found at $VAULT — skipping"; exit 0; }

# Not a git repo (or bare)? bail quietly.
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "brain-snapshot: $VAULT is not a git work tree — skipping"; exit 0; }

TS="$(date +%Y%m%dT%H%M%S)"
HEAD_SHA="$(git rev-parse HEAD 2>/dev/null || true)"

# Build the snapshot tree in an isolated temp index so the real index, working
# tree, and HEAD are untouched. `git add -A` respects .gitignore, so ignored
# secrets stay out; it also captures untracked notes and staged/unstaged edits.
TMP_INDEX="$(mktemp "${TMPDIR:-/tmp}/brain-snap-index.XXXXXX")"
trap 'rm -f "$TMP_INDEX"' EXIT
# git rejects a zero-byte index ("index file smaller than expected"); remove the
# placeholder mktemp created so `git add` writes a fresh, valid index here.
rm -f "$TMP_INDEX"
export GIT_INDEX_FILE="$TMP_INDEX"

git add -A
TREE="$(git write-tree)"

# Commit-if-dirty: skip when the working tree already matches HEAD.
if [ -n "$HEAD_SHA" ] && [ "$TREE" = "$(git rev-parse "HEAD^{tree}")" ]; then
  echo "brain-snapshot: working tree clean vs HEAD — no snapshot needed"
  exit 0
fi

if [ -n "$HEAD_SHA" ]; then
  COMMIT="$(git commit-tree "$TREE" -p "$HEAD_SHA" -m "snapshot $TS")"
else
  COMMIT="$(git commit-tree "$TREE" -m "snapshot $TS")"
fi

git update-ref "refs/snapshots/$TS" "$COMMIT"
echo "brain-snapshot: $VAULT -> refs/snapshots/$TS ($COMMIT)"
