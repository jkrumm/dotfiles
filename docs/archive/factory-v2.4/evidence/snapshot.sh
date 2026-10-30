#!/usr/bin/env bash
# Freeze the mutable stores the evidence scripts read, so every number reproduces.
# Append-only sources (git, transcripts, human-queue files, OpenCode/Hermes stores) are
# read live and filtered by AS_OF instead. Snapshots hold private data and never enter git.
set -euo pipefail
AS_OF="${AS_OF:-2026-10-22T08:00:00Z}"
DEST="${FACTORY_SNAPSHOTS:-$HOME/.local/share/factory/snapshots}/${AS_OF%%T*}"
mkdir -p "$DEST"
snap() { # <src> <name>
  [[ -f $1 ]] || { echo "missing: $1" >&2; return 0; }
  [[ -f $DEST/$2 ]] && { echo "exists: $DEST/$2 (delete it to re-snapshot)"; return 0; }
  sqlite3 "file:$1?mode=ro" ".backup '$DEST/$2'" && sqlite3 "$DEST/$2" "PRAGMA journal_mode=DELETE;" >/dev/null && chmod 444 "$DEST/$2" && echo "snapshot: $2 ($(du -h "$DEST/$2" | cut -f1))"
}
snap "$HOME/.warden/warden.db" warden.db
snap "$HOME/.local/share/agent-gateway/jobs.db" agw-jobs.db
snap "$HOME/.local/share/usage-tracker/usage.db" usage.db
snap "$HOME/.research-gateway/data/jobs.sqlite" research-jobs.sqlite
[[ -d $DEST/human-queue ]] || cp -R "$HOME/.local/state/human-queue" "$DEST/human-queue"
echo "$AS_OF" > "$DEST/AS_OF"
echo "snapshots in $DEST"
