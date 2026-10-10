#!/usr/bin/env bash
# List a repo's extra worktrees with a verdict, for `rd fan --clean`.
# Usage: fan-list.sh <repo-path>
# stdout, tab-separated: drop|keep <worktree> <branch> <merged|unmerged|dirty>
# The main worktree (first entry) is never listed. "drop" = clean AND fully merged into the fetched origin default; nothing else is touched.
set -euo pipefail
repo=${1:?usage: fan-list.sh <repo-path>}
timeout 90 git -C "$repo" fetch -q origin
base=$(git -C "$repo" symbolic-ref -q --short refs/remotes/origin/HEAD || echo origin/master)
git -C "$repo" worktree list --porcelain | awk '
  /^worktree /{p=substr($0,10); n++} n>1 && /^branch refs\/heads\//{print p "\t" substr($0,19)}' |
while IFS=$'\t' read -r p b; do
  if [[ -n $(git -C "$p" status --porcelain) ]]; then printf 'keep\t%s\t%s\tdirty\n' "$p" "$b"
  elif git -C "$repo" merge-base --is-ancestor "$b" "$base" 2>/dev/null; then printf 'drop\t%s\t%s\tmerged\n' "$p" "$b"
  else printf 'keep\t%s\t%s\tunmerged\n' "$p" "$b"; fi
done
