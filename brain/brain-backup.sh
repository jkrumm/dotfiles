#!/usr/bin/env bash
# Nightly auto-commit + push of the brain vault to its private GitHub repo.
#
# Backstop for direct Obsidian edits that never went through a Claude Code
# session (and so were never committed/pushed there). If the working tree is
# dirty, stage everything (git add -A respects .gitignore, so secrets like
# _device-settings and .obsidian/plugins/*/data.json stay out), ask claude_iu
# (Haiku, IU per-token — off Max quota) to write a one-line commit message
# from the diff, commit straight to master, and push. LiveSync/CouchDB already
# mirrors raw content to homelab in near-real-time; this is what makes GitHub
# an actually-current offsite copy instead of a stale one.
set -euo pipefail

# launchd hands agents a minimal PATH — make sure git/security resolve either way.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

VAULT="${BRAIN_VAULT:-$HOME/SourceRoot/brain}"
cd "$VAULT" 2>/dev/null || { echo "brain-backup: vault not found at $VAULT — skipping"; exit 0; }

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "brain-backup: $VAULT is not a git work tree — skipping"; exit 0; }

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

KEY="$(security find-generic-password -s claude-sdk-api-key -w 2>/dev/null || true)"
BASE="$(security find-generic-password -s claude-sdk-base-url -w 2>/dev/null || true)"

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

[ -n "$MSG" ] || MSG="$FALLBACK_MSG"

git commit -q -m "$MSG"
git push -q origin master
echo "brain-backup: committed + pushed — $MSG"
