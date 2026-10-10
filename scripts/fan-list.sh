#!/usr/bin/env bash
# List a repo's extra worktrees with a verdict, for `rd fan --clean`.
# Usage: fan-list.sh <repo-path>
# stdout, tab-separated: drop|keep <worktree> <branch> <merged|unmerged|dirty|fresh>
# The main worktree (first entry) is never listed. "drop" = clean, has commits,
# and every one is in the fetched origin default (patch-id, so a rebase-merge counts). A branch
# still AT the base is "fresh": a worker just started there. Nothing else is touched.
set -euo pipefail
repo=${1:?usage: fan-list.sh <repo-path>}
timeout 90 git -C "$repo" fetch -q origin
base=$(git -C "$repo" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)
if [[ -z $base ]]; then
  for b in origin/master origin/main; do git -C "$repo" rev-parse -q --verify "$b" >/dev/null && { base=$b; break; }; done
fi
[[ -n $base ]] || { echo "no origin default branch in $repo" >&2; exit 1; }
git -C "$repo" worktree list --porcelain | awk '
  /^worktree /{p=substr($0,10); n++} n>1 && /^branch refs\/heads\//{print p "\t" substr($0,19)}' |
while IFS=$'\t' read -r p b; do
  if [[ -n $(git -C "$p" status --porcelain) ]]; then printf 'keep\t%s\t%s\tdirty\n' "$p" "$b"
  elif [[ $(git -C "$repo" rev-parse "$b") == "$(git -C "$repo" rev-parse "$base")" ]]; then printf 'keep\t%s\t%s\tfresh\n' "$p" "$b"
  elif ! git -C "$repo" cherry "$base" "$b" | grep -q '^+'; then printf 'drop\t%s\t%s\tmerged\n' "$p" "$b"
  else printf 'keep\t%s\t%s\tunmerged\n' "$p" "$b"; fi
done
