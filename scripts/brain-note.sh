#!/usr/bin/env bash
set -euo pipefail

# brain-note — open THIS terminal's repo project page from the brain vault in
# $EDITOR. Called by cmd-e in the Herdr app, where the jk-keys mod
# (config/herdr-app/mods/jk-keys) starts it with `hc run --bg --cwd <the focused
# terminal's cwd>` and shows it with `terminal.peek`. hc terminals take the core's
# launchd environment, so there is no $EDITOR there unless the machine sets one:
# vim is the fallback, BRAIN_NOTE_EDITOR overrides.
#
# WHY IT LIVES IN THE VAULT. Notes used to sit in a per-workspace plugin store
# (untracked, unsynced, keyed to an id a closed workspace orphans). The vault
# already syncs to both machines every 5 minutes, is searchable by /brain and
# Hermes, and survives the machine: one store.
#
# WHY PER-REPO, NOT PER-WORKSPACE. Two spaces open on the same checkout are
# the same project, and their notes were two files. Resolving through
# `git rev-parse --show-toplevel` makes them one page, findable by a human who has
# never heard of Herdr.
#
# WHY `Projects/<repo>.md` AND NOT A SCRATCH TREE. PARA `Projects` is the vault's
# curated human surface (light lint: wikilinks must resolve, no forced schema),
# and an active repo IS an active project. Scratch that turns out to matter gets
# tidied in place instead of migrated; scratch that does not gets deleted. One
# store, which was the entire point.
#
# WHY NO `git pull` HERE. brain-sync reconciles both machines through GitHub
# every 5 minutes and is the designated reconciler; AGENTS.md's "pull before you
# write" is aimed at agentic batch writes, not at a keystroke that must feel
# instant. Editing a five-minute-stale note is the documented model, and a real
# conflict aborts the rebase and leaves the tree untouched — loud, not silent.
# Note the mini's lane pulls and pushes but never COMMITS, so a note written
# here lands via the nightly brain-backup sweep rather than immediately.

VAULT="${BRAIN_VAULT:-$HOME/SourceRoot/brain}"
EDITOR_BIN="${BRAIN_NOTE_EDITOR:-${EDITOR:-${VISUAL:-vim}}}"

# A terminal closes the instant this exits, so an unpaused error message is a flash
# of text nobody can read. Every failure path goes through here.
die() {
  echo "" >&2
  echo "  ✗ $*" >&2
  echo "" >&2
  printf "  press enter to close "
  read -r _ || true
  exit 1
}

[ -d "$VAULT/.git" ] || die "no brain vault at $VAULT (set BRAIN_VAULT to override)"

# Under hc the run's --cwd is $PWD, which is also what running this by hand from a
# shell gives.
CWD="$PWD"

# Refuse rather than guess. Without a repo the only name available is the
# basename of whatever directory the pane happens to sit in, and writing
# `Projects/Downloads.md` into a curated tree is worse than doing nothing.
ROOT=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null) \
  || die "this terminal is not inside a git repo — the project-note key opens the note for the repo you are in"

REPO=$(basename "$ROOT")

# Folder-note form first: Obsidian's folder-notes plugin is in use, so a project
# that grew subpages lives at Projects/<repo>/<repo>.md (basalt-ui, iu) while a
# simple one is a flat Projects/<repo>.md. Checking the folder first keeps the
# keybinding pointed at the page a human would open.
if [ -d "$VAULT/Projects/$REPO" ]; then
  NOTE="$VAULT/Projects/$REPO/$REPO.md"
else
  NOTE="$VAULT/Projects/$REPO.md"
fi

if [ ! -f "$NOTE" ]; then
  # Frontmatter matches the existing project pages (Projects/rollhook.md), which
  # is what puts a new page into the Projects dashboard's dataview without
  # anyone editing the dashboard: it selects on type = project AND lifecycle =
  # active. `status` is the human's free field; the linter does not enforce it.
  REPO_REL="${ROOT/#$HOME/~}"
  /bin/mkdir -p "$(dirname "$NOTE")"
  cat > "$NOTE" <<EOF
---
title: $REPO
type: project
status: personal
lifecycle: active
tags:
  - project
dateCreated: $(/bin/date +%Y-%m-%d)
repo: $REPO_REL
---

# $REPO

EOF

  # Link it from the Projects folder note. NOT optional politeness: vault-lint
  # warns `not wikilinked from its folder note` for any curated page the MOC
  # does not reach, and the dashboard's dataview does not satisfy it — that
  # query is rendered by Obsidian, while the linter reads the file. Creating a
  # page that immediately makes the vault warn is how a linter stops being
  # believed. Appended after the last existing bullet, and skipped when the link
  # is already there, so re-creating a deleted note cannot duplicate it.
  MOC="$VAULT/Projects/Projects.md"
  if [ -f "$MOC" ] && ! /usr/bin/grep -qF "[[$REPO]]" "$MOC"; then
    /usr/bin/awk -v repo="$REPO" '
      /^## Projects$/            { inlist = 1; print; next }
      inlist && /^- \[\[/        { print; seen = 1; next }
      inlist && seen             { print "- [[" repo "]]"; inlist = 0 }
                                 { print }
    ' "$MOC" > "$MOC.tmp" && /bin/mv "$MOC.tmp" "$MOC"
  fi
fi

exec "$EDITOR_BIN" "$NOTE"
