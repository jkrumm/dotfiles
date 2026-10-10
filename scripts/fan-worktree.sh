#!/usr/bin/env bash
# Create one fan-out worktree from FETCHED origin state, never the local checkout.
# A local master that is behind (or carries unpushed commits) briefed a worker against
# the wrong tree once (Wave 6, basalt-ui); this is the one place that cannot happen.
#
# Usage: fan-worktree.sh <repo-path> <branch>
# stdout (3 lines): worktree path, base ref (origin/<default>), base sha.
# Tooling: the repo's own `wtp` config (.wtp.yml, so post_create hooks install deps and
# copy env) when present, else plain `git worktree add` under <repo>/.claude/worktrees.
set -euo pipefail
repo=${1:?usage: fan-worktree.sh <repo-path> <branch>} branch=${2:?branch}

timeout 90 git -C "$repo" fetch -q origin
default=$(git -C "$repo" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)
if [[ -z $default ]]; then
  for b in origin/master origin/main; do
    git -C "$repo" rev-parse -q --verify "$b" >/dev/null && { default=$b; break; }
  done
fi
[[ -n $default ]] || { echo "no origin default branch in $repo" >&2; exit 1; }
sha=$(git -C "$repo" rev-parse "$default")

if git -C "$repo" rev-parse -q --verify "refs/heads/$branch" >/dev/null; then
  echo "branch '$branch' already exists in $repo" >&2; exit 1
fi

if [[ -f $repo/.wtp.yml ]] && command -v wtp >/dev/null; then
  path=$(cd "$repo" && command wtp add -b "$branch" "$default" --quiet | tail -1)
else
  path="$repo/.claude/worktrees/${branch//\//-}"
  git -C "$repo" worktree add -q -b "$branch" "$path" "$default"
fi
[[ -d $path ]] || { echo "worktree path '$path' missing after create" >&2; exit 1; }
# A branch cut from origin/<default> must not track it: `git push` would target master.
git -C "$path" branch --unset-upstream "$branch" 2>/dev/null || true
printf '%s\n%s\n%s\n' "$path" "$default" "$sha"
