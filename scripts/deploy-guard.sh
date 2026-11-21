#!/usr/bin/env bash
# deploy-guard.sh <dir> [goal] — refuses a make goal that writes host state from a linked worktree.
#
# setup and deploy render the LaunchAgent plists and host links with DOTFILES_DIR (the
# checkout make ran from), so a worktree bakes its own path into them and the jobs break
# when the worktree is removed. Run those goals from the main checkout instead.
#
# Usage: scripts/deploy-guard.sh <dir> [goal]   (goal defaults to deploy;
#        exit 0 = main checkout, 1 = linked worktree, 2 = not a git checkout)

set -u

dir="${1:?usage: deploy-guard.sh <dir> [goal]}"
goal="${2:-deploy}"
common="$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir)" || exit 2
gitdir="$(git -C "$dir" rev-parse --path-format=absolute --git-dir)" || exit 2
[[ "$common" == "$gitdir" ]] && exit 0

echo "  ✗ make $goal refuses inside a linked worktree: $dir" >&2
echo "    run it from the main checkout: make -C $(dirname "$common") $goal" >&2
exit 1
