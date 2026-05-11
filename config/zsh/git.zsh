# Git helpers

# nb <branch> — smart branch switch / create
#
#   Switches to an existing branch (local or remote-only) and rebases onto
#   origin/default. Creates a new branch from origin/default if it doesn't
#   exist. Interactively offers to carry ahead commits to the new branch.
unalias nb 2>/dev/null
nb() {
  if [[ -z "$1" ]]; then
    echo "Usage: nb <branch-name>"
    return 1
  fi

  local default_branch
  default_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')
  if [[ -z "$default_branch" ]]; then
    default_branch=$(git remote show origin 2>/dev/null | sed -n 's/.*HEAD branch: //p')
  fi
  if [[ -z "$default_branch" ]]; then
    echo "error: could not determine default branch"
    return 1
  fi

  git fetch origin "$default_branch" --quiet

  local current_branch ahead_count has_changes ahead_log reply
  current_branch=$(git rev-parse --abbrev-ref HEAD)
  ahead_count=$(git rev-list --count "origin/$default_branch..HEAD" 2>/dev/null)
  has_changes=$(git status --porcelain 2>/dev/null)

  # Remote-only branch — check out tracking the remote, then rebase
  if ! git show-ref --verify --quiet "refs/heads/$1" \
      && git show-ref --verify --quiet "refs/remotes/origin/$1"; then
    echo "Branch '$1' exists on origin but not locally — checking out."
    if [[ -n "$has_changes" ]]; then
      echo "You have uncommitted changes — stash them first or commit before switching."
      return 1
    fi
    git checkout -b "$1" --track "origin/$1" || return 1
    git rebase "origin/$default_branch" || return 1
    return 0
  fi

  # Branch exists locally — switch and rebase
  if git show-ref --verify --quiet "refs/heads/$1"; then
    echo "Branch '$1' already exists."
    if [[ -n "$has_changes" ]]; then
      echo "You have uncommitted changes — stash them first or commit before switching."
      return 1
    fi
    git checkout "$1" || return 1
    git rebase "origin/$default_branch" || return 1
    return 0
  fi

  # Commits ahead — offer to carry them to the new branch
  if [[ $ahead_count -gt 0 ]]; then
    ahead_log=$(git log "origin/$default_branch..HEAD" --oneline)
    echo "$ahead_count commit(s) ahead of origin/$default_branch on '$current_branch':"
    echo "$ahead_log" | sed 's/^/  /'
    [[ -n "$has_changes" ]] && echo "  + uncommitted changes"
    echo ""
    echo -n "Carry commits to '$1' and rebase onto origin/$default_branch? [y/n] "
    read -rk1 reply; echo
    if [[ "$reply" == [yY] ]]; then
      git checkout -b "$1" || return 1
      git rebase "origin/$default_branch" || return 1
      echo -n "Reset '$current_branch' back to origin/$default_branch? [y/n] "
      read -rk1 reply; echo
      if [[ "$reply" == [yY] ]]; then
        git checkout "$current_branch" --quiet \
          && git reset --hard "origin/$default_branch" \
          && git checkout "$1" --quiet
        echo "  '$current_branch' reset to origin/$default_branch"
      fi
      return 0
    fi
  elif [[ -n "$has_changes" ]]; then
    echo "Uncommitted changes will carry over to '$1'."
    echo -n "Continue? [y/n] "
    read -rk1 reply; echo
    [[ "$reply" != [yY] ]] && return 0
  fi

  git checkout -b "$1" "origin/$default_branch"
}
