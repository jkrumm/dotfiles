#!/usr/bin/env bash
# Merge train: land fan-out branches one at a time, GitHub only, rebase/fast-forward only.
# For each branch, in order: fetch, rebase onto the CURRENT origin default, run the check,
# push with lease, merge the PR by rebase. Main moves after every merge, so the next branch
# re-fetches and re-rebases. A push that drops approvals (branch protection) falls back to
# arming auto-merge. All git runs `git -C <worktree>` so protect-branches judges the
# worktree, not the caller's cwd. No GitLab path: IuRoot moves to GitHub Enterprise.
#
# Usage: merge-train.sh <repo-path> [--check '<cmd>'] [--no-check] <branch>...
set -uo pipefail
die() { printf 'merge-train: %s\n' "$*" >&2; exit 1; }

repo=${1:?usage: merge-train.sh <repo-path> [--check cmd] <branch>...}; shift
check="make check" branches=()
while (($#)); do
  case $1 in
    --check) [[ -n ${2:-} && $2 != --* ]] || die "--check needs a command"; check=$2; shift 2 ;;
    --no-check) check=""; shift ;;
    *) branches+=("$1"); shift ;;
  esac
done
((${#branches[@]})) || die "no branches"
if [[ -z ${GH_TOKEN:-} ]]; then
  GH_TOKEN=$(secrets-run read op://mini/github/token) || die "could not resolve the GitHub token (secrets-run read op://mini/github/token)"
fi
export GH_TOKEN
origin_url=$(git -C "$repo" remote get-url origin)
[[ $origin_url =~ (^git@|//)([^/:]*github[^/:]*)[:/] ]] || die "origin is not a GitHub host — the train is GitHub-only"

wt_of() { # worktree path holding branch $1
  git -C "$repo" worktree list --porcelain | awk -v b="refs/heads/$1" '/^worktree /{p=$2} $0=="branch " b{print p}'
}

errf=$(mktemp)
trap 'rm -f "$errf"' EXIT
for br in "${branches[@]}"; do
  wt=$(wt_of "$br"); [[ -n $wt ]] || die "no worktree holds '$br'"
  [[ -z $(git -C "$wt" status --porcelain) ]] || die "$wt is dirty — the worker has not committed"
  landed=0
  for attempt in 1 2 3; do
    timeout 90 git -C "$wt" fetch -q origin || die "fetch failed"
    base=$(git -C "$wt" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null) || {
      base=""; for b in origin/master origin/main; do git -C "$wt" rev-parse -q --verify "$b" >/dev/null && { base=$b; break; }; done; }
    [[ -n $base ]] || die "no origin default branch in $wt"
    git -C "$wt" rebase -q "$base" || { git -C "$wt" rebase --abort 2>/dev/null || true; die "$br: rebase onto $base conflicts — back to its worker"; }
    if [[ -n $check ]]; then
      (cd "$wt" && eval "$check") || die "$br: check failed after rebase on $base"
    fi
    timeout 90 git -C "$wt" push -q --force-with-lease origin "$br" || die "$br: push failed"
    pr=$(cd "$wt" && gh pr view "$br" --json number -q .number 2>/dev/null) || die "$br: no PR — worker must open one"
    if (cd "$wt" && gh pr merge "$pr" --rebase 2>"$errf"); then
      echo "merged $br (#$pr) onto $base"; landed=1; break
    fi
    if grep -qiE 'base branch policy|required (status|review|approving)|review is required' "$errf"; then
      if (cd "$wt" && gh pr merge "$pr" --rebase --auto); then
        echo "armed auto-merge for $br (#$pr), waiting for it to land"
        for _ in $(seq 60); do
          [[ $(cd "$wt" && gh pr view "$pr" --json state -q .state) == MERGED ]] && { landed=1; break; }
          sleep 20
        done
        ((landed)) && break
        die "$br (#$pr): auto-merge armed but not merged after 20 min — the next branch would rebase onto a stale main"
      fi
    fi
    echo "merge of $br attempt $attempt failed ($(head -c 200 "$errf")) — main probably moved, re-rebasing" >&2
  done
  ((landed)) || die "$br: not merged after 3 attempts"
done
