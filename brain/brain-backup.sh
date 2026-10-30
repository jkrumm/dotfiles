#!/usr/bin/env bash
# Nightly auto-commit + push of the brain vault to its private GitHub repo.
#
# Backstop for direct Obsidian edits that never went through a Claude Code
# session (and so were never committed/pushed there). If the working tree is
# dirty, stage everything (git add -A respects .gitignore, so secrets like
# .obsidian/plugins/*/data.json stay out), write a one-line commit message from
# the diff's file counts, commit straight to master, and push.
#
# THIS IS NOT THE SYNC LAYER — brain-sync.sh is, running every 5 minutes under
# launchd on both the mini and the MacBook (LiveSync/CouchDB has been retired
# since 2026-07-21; git through GitHub is the whole mechanism, and the MacBook
# holds a writing clone). This job exists for the one thing brain-sync
# deliberately refuses to do: commit on the mini. There, committing stays a
# considered act — Claude Code sessions commit their own work under review, and
# this 03:30 sweep catches whatever they left dirty so GitHub never drifts more
# than a day stale.
set -euo pipefail

# launchd hands agents a minimal PATH — make sure git/curl resolve either way.
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

# Resolved before the cd into the vault: $BASH_SOURCE is relative when the script
# is invoked by a relative path, and dirname would then point at the vault.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Heartbeat, so a sweep that silently stops is visible. It fails independently of
# brain-sync: the vault can be reconciling perfectly while nothing commits what
# direct Obsidian edits left behind, and that loss stays invisible until someone
# reads `git status` days later. A missing URL file is a no-op, not an error —
# the MacBook runs this script too and deliberately has no monitor.
# shellcheck source-path=SCRIPTDIR source=../scripts/lib/kuma-push.sh
source "$SCRIPT_DIR/../scripts/lib/kuma-push.sh"

BACKUP_PUSH_URL_FILE="${BRAIN_BACKUP_PUSH_URL_FILE:-$HOME/.config/uptime-kuma/brain-backup-push-url}"
backup_push_url=""
if [ -n "${BRAIN_BACKUP_PUSH_URL:-}" ] || [ -f "$BACKUP_PUSH_URL_FILE" ]; then
  backup_push_url="$(kuma_resolve_push_url "${BRAIN_BACKUP_PUSH_URL:-}" "$BACKUP_PUSH_URL_FILE")" || backup_push_url=""
fi
beat() { [ -n "$backup_push_url" ] && kuma_push "$backup_push_url" "$1" "$2" >/dev/null 2>&1 || true; }

# A sweep that dies under `set -e` — a rejected hook, a full disk, an unreachable
# origin — would otherwise exit non-zero having said nothing at all, and 25h later
# the monitor would blame a missed heartbeat rather than name the failure.
beat_sent=""
on_exit() {
  local st=$?
  if [ "$st" -ne 0 ] && [ -z "$beat_sent" ]; then
    beat down "nightly sweep failed (exit $st) — see ~/Library/Logs/brain-backup.log"
  fi
  rm -rf "$LOCK_DIR"
}

VAULT="${BRAIN_VAULT:-$HOME/SourceRoot/brain}"
cd "$VAULT" 2>/dev/null || { echo "brain-backup: vault not found at $VAULT — skipping"; exit 0; }

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "brain-backup: $VAULT is not a git work tree — skipping"; exit 0; }

# Take the SAME lock brain-sync.sh holds. Both agents run on this machine and
# both touch this repo: at 03:30 a brain-sync tick can autostash the dirty tree
# a fraction of a second before this script inspects it, whereupon the check
# below sees a clean tree, reports "nothing to commit" and exits 0 — and the
# night's uncommitted work sits in a stash that the only committing job on the
# mini has just declared absent. The other outcome is dying on .git/index.lock
# mid-`git add -A` with no sweep at all. A one-night skip is the correct
# response to a live sync; silently losing the sweep is not.
LOCK_DIR="${BRAIN_SYNC_LOCK_DIR:-$HOME/Library/Caches/brain-sync.lock}"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  holder="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  # `ps` rather than `kill -0`: the latter cannot distinguish a live process
  # owned by another user (EPERM) from one that is genuinely gone (ESRCH).
  if [ -n "$holder" ] && ps -p "$holder" >/dev/null 2>&1; then
    echo "brain-backup: brain-sync (pid $holder) holds the vault lock — skipping tonight's sweep"
    beat up "skipped: brain-sync holds the lock"; beat_sent="yes"
    exit 0
  fi
  lock_born="$(stat -f %m "$LOCK_DIR" 2>/dev/null || true)"
  lock_age=$(( $(date +%s) - ${lock_born:-0} ))
  if [ -z "$holder" ] && [ "$lock_age" -lt 60 ]; then
    echo "brain-backup: the vault lock has no pid yet and is only ${lock_age}s old — a sync run is claiming it; skipping tonight's sweep"
    exit 0
  fi
  echo "brain-backup: reclaiming the lock left by pid ${holder:-unknown} (${lock_age}s old) — no such process" >&2
  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR" 2>/dev/null || { echo "brain-backup: lost the race for $LOCK_DIR — skipping tonight's sweep"; exit 0; }
fi
printf '%s' "$$" >"$LOCK_DIR/pid"
trap on_exit EXIT

if [ -z "$(git status --porcelain)" ]; then
  echo "brain-backup: working tree clean — nothing to commit"
  beat up "clean — nothing to commit"; beat_sent="yes"
  exit 0
fi

git add -A

if git diff --cached --quiet; then
  echo "brain-backup: only ignored/empty changes staged — nothing to commit"
  beat up "only ignored changes — nothing to commit"; beat_sent="yes"
  exit 0
fi

# Deterministic message from the staged diff: no network, no credentials, nothing
# that can hang. Counts per change type, the top-level folders touched.
STATUS="$(git diff --cached --name-status)"
count() { printf '%s\n' "$STATUS" | grep -c "^$1" || true; }
ADDED="$(count A)"; MODIFIED="$(count "[MT]")"; DELETED="$(count D)"; RENAMED="$(count R)"
AREAS="$(git diff --cached --name-only | awk -F/ 'NF>1{print $1}' | sort -u | awk 'NR<=3' | paste -sd, - | sed 's/,/, /g')"
MSG="chore(brain): nightly vault sync (+$ADDED ~$MODIFIED -$DELETED r$RENAMED${AREAS:+; $AREAS})"

git commit -q -m "$MSG"
git push -q origin master
echo "brain-backup: committed + pushed — $MSG"
beat up "committed + pushed — $MSG"; beat_sent="yes"
