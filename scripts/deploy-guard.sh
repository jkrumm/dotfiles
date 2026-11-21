#!/usr/bin/env bash
# deploy-guard.sh <dir> — refuses `make deploy` from a linked worktree.
#
# make deploy renders the LaunchAgent plists with DOTFILES_DIR (the checkout make
# ran from), so a worktree bakes its own path into them and the jobs break when
# the worktree is removed. Deploy from the main checkout instead.
#
# Usage: scripts/deploy-guard.sh <dir>   (exit 0 = main checkout, 1 = linked worktree)

set -u

dir="${1:?usage: deploy-guard.sh <dir>}"
common="$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir)" || exit 2
gitdir="$(git -C "$dir" rev-parse --path-format=absolute --git-dir)" || exit 2
[[ "$common" == "$gitdir" ]] && exit 0

echo "  ✗ make deploy refuses inside a linked worktree: $dir" >&2
echo "    run it from the main checkout: make -C $(dirname "$common") deploy" >&2
exit 1
