#!/usr/bin/env bash
# Merge train: land fan-out branches one at a time, GitHub only, rebase/fast-forward only.
# For each branch, in order: fetch, rebase onto the CURRENT origin default, run the check,
# push with lease, wait for the PR's CI on the pushed head, merge the PR by rebase. A fresh worktree has no node_modules, so the check
# is preceded by an install from whichever lockfile is present; a draft PR is readied first
# (`gh pr merge` refuses drafts). Main moves after every merge, so the next branch
# re-fetches and re-rebases. A push that drops approvals (branch protection) falls back to
# arming auto-merge. All git runs `git -C <worktree>` so protect-branches judges the
# worktree, not the caller's cwd. No GitLab path: IuRoot moves to GitHub Enterprise.
#
# CI gate: after the push, the PR's checks are trusted only once the PR head IS the pushed sha
# (GitHub lags a few seconds behind a push and would otherwise report the previous head's run).
# No checks at all after RD_CI_GRACE seconds (default 30; measured: a push's check suite exists
# 0-5 s after the push, 11 pushes) means the repo has no workflows and the PR merges. Pending
# past RD_CI_TIMEOUT (default 1200 s) dies, so an offline self-hosted runner cannot hang the train.
#
# Usage: merge-train.sh <repo-path> [--check '<cmd>'] [--no-check] [--no-ci] <branch>...
set -uo pipefail
die() { printf 'merge-train: %s\n' "$*" >&2; exit 1; }

repo=${1:?usage: merge-train.sh <repo-path> [--check cmd] <branch>...}; shift
check="make check" ci=1 branches=()
while (($#)); do
  case $1 in
    --check) [[ -n ${2:-} && $2 != --* ]] || die "--check needs a command"; check=$2; shift 2 ;;
    --no-check) check=""; shift ;;
    --no-ci) ci=0; shift ;;
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

install_cmd() { # lockfile-matched dependency install for worktree $1; empty when there is none
  if [[ -f $1/bun.lock || -f $1/bun.lockb ]]; then echo "bun install --frozen-lockfile"
  elif [[ -f $1/pnpm-lock.yaml ]]; then echo "pnpm install --frozen-lockfile"
  elif [[ -f $1/package-lock.json ]]; then echo "npm ci"
  fi
}

ci_wait() { # <worktree> <pr> <sha> <branch>: return 0 when CI on head <sha> passed or there is none; die otherwise
  local wt=$1 pr=$2 sha=$3 br=$4 start=$SECONDS head json failed
  local timeout_s=${RD_CI_TIMEOUT:-1200} grace=${RD_CI_GRACE:-30} poll=${RD_CI_POLL:-10}
  while :; do
    head=$(cd "$wt" && gh pr view "$pr" --json headRefOid -q .headRefOid 2>/dev/null)
    if [[ $head == "$sha" ]]; then
      if json=$(cd "$wt" && gh pr checks "$pr" --json name,bucket,link 2>"$errf"); then
        # GitHub moved the head while we read: the list may belong to another sha.
        if [[ $(cd "$wt" && gh pr view "$pr" --json headRefOid -q .headRefOid 2>/dev/null) != "$sha" ]]; then
          sleep "$poll"; continue
        fi
        failed=$(jq -r '[.[]|select(.bucket=="fail" or .bucket=="cancel")]|map(.name)|join(", ")' <<<"$json")
        [[ -z $failed ]] || die "$br (#$pr): CI failed: $failed $(jq -r '[.[]|select(.bucket=="fail" or .bucket=="cancel")][0].link' <<<"$json")"
        # skipping (e.g. an app that opted out) is neither pass nor pending.
        if [[ $(jq '[.[]|select(.bucket=="pending")]|length' <<<"$json") == 0 && $(jq length <<<"$json") -gt 0 ]]; then
          echo "CI passed for $br (#$pr) at ${sha:0:9}"; return 0
        fi
      elif grep -q 'no checks reported' "$errf"; then
        if ((SECONDS - start >= grace)); then
          echo "no CI checks for $br (#$pr) after ${grace}s — merging without a CI gate"; return 0
        fi
      else
        echo "gh pr checks for #$pr failed: $(head -c 200 "$errf" | tr '\n' ' ') — retrying" >&2
      fi
    fi
    if ((SECONDS - start >= timeout_s)); then
      die "$br (#$pr): CI not finished for ${sha:0:9} after ${timeout_s}s (pending checks, or the PR head never became the pushed sha)"
    fi
    sleep "$poll"
  done
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
      # A fresh worktree has no node_modules: without this a Bun repo's bare `make check` dies on
      # a missing binary. A failed install is a red check, never a silent pass.
      inst=$(install_cmd "$wt")
      if [[ -n $inst ]]; then
        echo "installing deps for $br: $inst"
        # A hung registry must not wedge the train forever; RD_INSTALL_TIMEOUT only exists for the tests.
        (cd "$wt" && timeout "${RD_INSTALL_TIMEOUT:-600}" bash -c "$inst"); irc=$?
        ((irc == 124)) && die "$br: dependency install timed out after ${RD_INSTALL_TIMEOUT:-600}s ($inst)"
        ((irc == 0)) || die "$br: dependency install failed ($inst) after rebase on $base"
      fi
      (cd "$wt" && eval "$check") || die "$br: check failed after rebase on $base"
    fi
    timeout 90 git -C "$wt" push -q --force-with-lease origin "$br" || die "$br: push failed"
    pr=$(cd "$wt" && gh pr view "$br" --json number -q .number 2>/dev/null) || die "$br: no PR — worker must open one"
    # `gh pr merge` refuses a draft; that used to read as "main moved" and burn all three attempts.
    if [[ $(cd "$wt" && gh pr view "$pr" --json isDraft -q .isDraft 2>/dev/null) == true ]]; then
      (cd "$wt" && gh pr ready "$pr") || die "$br (#$pr): is a draft and 'gh pr ready' failed"
      echo "marked $br (#$pr) ready for review (it was a draft)"
    fi
    if ((ci)); then ci_wait "$wt" "$pr" "$(git -C "$wt" rev-parse HEAD)" "$br"; fi
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
    echo "merge of $br attempt $attempt failed: $(head -c 300 "$errf" | tr '\n' ' ') — re-fetching and re-rebasing" >&2
  done
  ((landed)) || die "$br: not merged after 3 attempts"
done
