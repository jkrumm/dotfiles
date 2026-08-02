#!/usr/bin/env bash
# Nightly auto-commit + push of the brain vault to its private GitHub repo.
#
# Backstop for direct Obsidian edits that never went through a Claude Code
# session (and so were never committed/pushed there). If the working tree is
# dirty, stage everything (git add -A respects .gitignore, so secrets like
# .obsidian/plugins/*/data.json stay out), ask claude_iu (Haiku, IU per-token —
# off Max quota) to write a one-line commit message from the diff, commit
# straight to master, and push.
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

# launchd hands agents a minimal PATH — make sure git/security resolve either way.
# ~/.local/bin is where `claude` and `secrets-run` live (neither is Homebrew-managed);
# without it the claude call below silently missed and every run committed the literal
# fallback message instead of a generated one.
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

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
trap 'rm -rf "$LOCK_DIR"' EXIT

if [ -z "$(git status --porcelain)" ]; then
  echo "brain-backup: working tree clean — nothing to commit"
  exit 0
fi

git add -A

if git diff --cached --quiet; then
  echo "brain-backup: only ignored/empty changes staged — nothing to commit"
  exit 0
fi

FALLBACK_MSG="chore(brain): nightly vault sync"
MSG=""

# The login keychain is unreadable to a launchd job whose GUI session is locked or
# absent, and `security` then just fails — which used to be swallowed into an empty
# credential and a silent fallback message. Fall back to `secrets-run read` on the
# same op:// refs `make setup` cached these entries from (cache backend on the mini:
# no prompt, no network), and say so on stderr when neither works. Missing credentials
# stay non-fatal here on purpose: a generated commit message is a nicety, and refusing
# to back the vault up over it would be the worse failure.
keychain_or_cache() {
  local v
  v=$(security find-generic-password -s "$1" -w 2>/dev/null) && [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  command -v secrets-run >/dev/null 2>&1 || return 0
  v=$(secrets-run read "$2" 2>/dev/null) && printf '%s' "$v"
}

KEY="$(keychain_or_cache claude-sdk-api-key op://common/anthropic/API_KEY || true)"
BASE="$(keychain_or_cache claude-sdk-base-url op://common/anthropic/BASE_URL || true)"

if [ -z "$KEY" ] || [ -z "$BASE" ]; then
  echo "brain-backup: IU credential unresolvable (Keychain claude-sdk-* and secrets-run both failed) — using the fallback commit message" >&2
fi

if [ -n "$KEY" ] && [ -n "$BASE" ]; then
  PROMPT="Write ONE git commit message line, conventional-commits format
'type(scope): description' (imperative mood, no trailing period, no AI
attribution), summarizing this diff to a personal Obsidian vault. Scope is
usually 'brain'. Output ONLY the commit message line, nothing else.

$(git diff --cached --stat)

$(git diff --cached | head -c 20000)"

  MSG="$(printf '%s' "$PROMPT" | env -u ANTHROPIC_API_KEY \
    ANTHROPIC_AUTH_TOKEN="$KEY" \
    ANTHROPIC_BASE_URL="$BASE" \
    claude -p --model haiku --dangerously-skip-permissions 2>/dev/null \
    | tail -1 | tr -d '\r' || true)"
fi

if [ -z "$MSG" ]; then
  if [ -n "$KEY" ] && [ -n "$BASE" ]; then
    echo "brain-backup: claude produced no message (is 'claude' on PATH?) — using the fallback" >&2
  fi
  MSG="$FALLBACK_MSG"
fi

git commit -q -m "$MSG"
git push -q origin master
echo "brain-backup: committed + pushed — $MSG"
