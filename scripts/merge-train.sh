#!/usr/bin/env bash
# Merge train: land fan-out branches one at a time, GitHub only, rebase/fast-forward only.
# For each branch, in order: fetch, rebase onto the CURRENT origin default, run the check,
# push with lease, wait for the PR's CI on the pushed head, merge the PR by rebase. A fresh
# worktree has no node_modules, so the check is preceded by an install from whichever lockfile
# is present; a draft PR is readied first (`gh pr merge` refuses drafts). Main moves after every
# merge, so the next branch re-fetches and re-rebases. A push that drops approvals (branch
# protection) falls back to arming auto-merge. All git runs `git -C <worktree>` so
# protect-branches judges the worktree, not the caller's cwd. No GitLab path: IuRoot moves to
# GitHub Enterprise.
#
# CI gate (needs jq): one `gh pr view --json headRefOid,statusCheckRollup` per poll, so the head
# and its checks are one snapshot, trusted only while the head IS the pushed sha (GitHub lags a
# push by a few seconds and would report the previous head's run). A failed or cancelled check
# dies at once. A pass is never declared before RD_CI_GRACE seconds (default 30) have passed
# since the push, and needs at least one non-skipping check: checks register late and
# independently, so an early all-green list can be partial. Only none/skipping-only after the
# grace means "no CI" and merges. Measured: a push's check suite exists 0-5 s after the push
# (11 pushes). Still pending after RD_CI_TIMEOUT (default 1200 s) dies, so an offline
# self-hosted runner cannot hang the train. RD_CI_POLL (default 10) is the seconds between
# polls; every gh call is bounded by RD_CI_GH_TIMEOUT (default 30).
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
((ci == 0)) || command -v jq >/dev/null || die "jq is required for the CI gate (or pass --no-ci)"
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

# Normalise statusCheckRollup (CheckRun + StatusContext entries) to {head,url,checks:[{name,link,bucket}]}
# with bucket pass|pending|skipping|fail (cancelled and timed-out count as fail).
CI_NORM='def b: if .__typename == "StatusContext" then
    {name: .context, link: (.targetUrl // ""),
     bucket: (if .state == "SUCCESS" then "pass" elif .state == "PENDING" or .state == "EXPECTED" then "pending" else "fail" end)}
  else
    {name: .name, link: (.detailsUrl // ""),
     bucket: (if .status != "COMPLETED" then "pending" elif .conclusion == "SUCCESS" then "pass"
              elif .conclusion == "NEUTRAL" or .conclusion == "SKIPPED" then "skipping" else "fail" end)}
  end;
  {head: .headRefOid, url: .url, checks: [(.statusCheckRollup // [])[] | b]}'

ci_wait() { # <worktree> <pr> <sha> <branch>: return 0 when CI on head <sha> passed or there is none; die otherwise
  local wt=$1 pr=$2 sha=$3 br=$4 start=$SECONDS raw snap why="" bad link
  local timeout_s=${RD_CI_TIMEOUT:-1200} grace=${RD_CI_GRACE:-30} poll=${RD_CI_POLL:-10} gh_t=${RD_CI_GH_TIMEOUT:-30}
  while :; do
    if raw=$(cd "$wt" && timeout "$gh_t" gh pr view "$pr" --json headRefOid,statusCheckRollup,url 2>"$errf") \
        && snap=$(jq -c "$CI_NORM" <<<"$raw" 2>>"$errf"); then
      if [[ $(jq -r .head <<<"$snap") != "$sha" ]]; then
        why="the PR head never became the pushed sha"
      else
        bad=$(jq -r '[.checks[] | select(.bucket == "fail")] | map(.name) | join(", ")' <<<"$snap")
        if [[ -n $bad ]]; then
          link=$(jq -r '(.checks | map(select(.bucket == "fail"))[0].link) as $l | if $l == "" then .url else $l end' <<<"$snap")
          die "$br (#$pr): CI failed: $bad $link"
        fi
        if [[ $(jq '[.checks[] | select(.bucket == "pending")] | length' <<<"$snap") -gt 0 ]]; then
          why="checks pending"
        elif ((SECONDS - start < grace)); then
          why="settling"
        elif [[ $(jq '[.checks[] | select(.bucket == "pass")] | length' <<<"$snap") -gt 0 ]]; then
          echo "CI passed for $br (#$pr) at ${sha:0:9}"; return 0
        else
          echo "no CI checks for $br (#$pr) after ${grace}s — merging without a CI gate"; return 0
        fi
      fi
    else
      why="gh kept failing"
      echo "gh pr view for #$pr failed: $(head -c 200 "$errf" | tr '\n' ' ') — retrying" >&2
    fi
    if ((SECONDS - start >= timeout_s)); then
      die "$br (#$pr): CI not finished for ${sha:0:9} after ${timeout_s}s ($why)"
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
