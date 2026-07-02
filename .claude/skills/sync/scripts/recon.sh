#!/usr/bin/env bash
# recon.sh — emit one JSON line of git state per repo under the given roots.
# Designed to run identically on the local MacBook and over SSH on the Mac mini
# (pipe it in: `ssh mac-mini 'bash -s -- SourceRoot IuRoot' < recon.sh`).
#
# Roots are given as NAMES relative to $HOME (e.g. SourceRoot IuRoot) so the same
# invocation works on any machine regardless of the absolute home path.
#
# Usage: recon.sh [--no-fetch] ROOTNAME [ROOTNAME...]
#   --no-fetch   skip the `git fetch` pass (faster, but ahead/behind may be stale)
set -uo pipefail

FETCH=1
if [ "${1:-}" = "--no-fetch" ]; then FETCH=0; shift; fi

# minimal JSON string escaping (backslash + double-quote; strip control chars)
esc() { printf '%s' "${1:-}" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g'; }

is_git() { [ -d "$1/.git" ] || git -C "$1" rev-parse --git-dir >/dev/null 2>&1; }

for rootname in "$@"; do
  root="$HOME/$rootname"
  [ -d "$root" ] || continue

  # Parallel fetch pass — network-bound, safe to fan out. Prune stale remotes so
  # behind/ahead reflect reality. Failures (offline, no remote) are ignored.
  if [ "$FETCH" = 1 ]; then
    for d in "$root"/*/; do
      d="${d%/}"; is_git "$d" || continue
      ( git -C "$d" fetch --quiet --all --prune 2>/dev/null ) &
    done
    wait
  fi

  for d in "$root"/*/; do
    d="${d%/}"; is_git "$d" || continue
    name=$(basename "$d")
    (
      cd "$d" || exit 0
      branch=$(git symbolic-ref --short HEAD 2>/dev/null)
      detached=false
      if [ -z "$branch" ]; then detached=true; branch=$(git rev-parse --short HEAD 2>/dev/null); fi
      dirty=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
      remote=$(git config --get remote.origin.url 2>/dev/null)
      head_sha=$(git rev-parse --short HEAD 2>/dev/null)
      head_date=$(git log -1 --format=%cI 2>/dev/null)
      head_msg=$(git log -1 --format=%s 2>/dev/null)

      # upstream: "true"  = tracks a remote branch that exists → normal reconcile
      #           "gone"  = HAD an upstream but the remote ref is deleted (merged MR,
      #                     pruned branch) → the branch is stale/dead, do NOT push -u;
      #                     the action is "move off it" (see reconcile.md).
      #           "false" = never tracked anything → a genuinely new local branch.
      if git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
        upstream=true
        ahead=$(git rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
        behind=$(git rev-list --count 'HEAD..@{u}' 2>/dev/null || echo 0)
      elif [ -n "$(git config --get "branch.$branch.merge" 2>/dev/null)" ]; then
        upstream=gone; ahead=0; behind=0
      else
        upstream=false; ahead=0; behind=0
      fi

      # OTHER local branches (not the checked-out one). Distinguish real unpushed
      # work from the stale local-branch graveyard:
      #   unpushed = branches that TRACK a remote and are ahead ("branch:N") — real
      #              work worth pushing.
      #   local_only = COUNT of no-upstream local branches — almost always old,
      #              merged, remote-deleted branches. Never enumerate/push them en
      #              masse; just surface the number. (The current branch is always
      #              handled separately via ahead/behind, so it's excluded here.)
      unpushed=""; local_only=0
      while IFS= read -r b; do
        [ -z "$b" ] && continue
        [ "$b" = "$branch" ] && continue
        if git rev-parse --abbrev-ref --symbolic-full-name "$b@{u}" >/dev/null 2>&1; then
          a=$(git rev-list --count "$b@{u}..$b" 2>/dev/null || echo 0)
          [ "${a:-0}" -gt 0 ] && unpushed="${unpushed}${unpushed:+,}$(esc "$b"):$a"
        else
          local_only=$((local_only + 1))
        fi
      done < <(git for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null)

      printf '{"root":"%s","repo":"%s","path":"%s","branch":"%s","detached":%s,"dirty":%s,"upstream":"%s","ahead":%s,"behind":%s,"remote":"%s","head":"%s","head_date":"%s","head_msg":"%s","unpushed_branches":"%s","local_only":%s}\n' \
        "$(esc "$rootname")" "$(esc "$name")" "$(esc "$d")" "$(esc "$branch")" "$detached" \
        "${dirty:-0}" "$upstream" "${ahead:-0}" "${behind:-0}" "$(esc "$remote")" \
        "$(esc "$head_sha")" "$(esc "$head_date")" "$(esc "$head_msg")" "$unpushed" "$local_only"
    )
  done
done
