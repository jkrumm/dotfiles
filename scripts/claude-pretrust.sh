#!/usr/bin/env bash
# claude-pretrust.sh <path>... — accept Claude Code's "do you trust this folder?" dialog for each path in
# every registered account's .claude.json (config/claude-accounts.json): .projects[<path>]
# .hasTrustDialogAccepted = true, written by atomic replace (a running session rewrites the same file).
#
# Why: a fresh config dir shows the dialog on first start in a path, and it blocks
# `herdr agent start` (agent_not_ready). `make claude-accounts-setup` runs this for $HOME so a bare
# `claude` in a fresh herdr pane starts; fan-worktree.sh does the same for each new worktree.
# An account whose .claude.json does not exist yet (never logged in) is skipped — re-run after /login.
# Idempotent; exits 1 if any account file could not be updated.
set -u
(( $# )) || { echo "usage: claude-pretrust.sh <path>..." >&2; exit 2; }
registry="$(dirname "${BASH_SOURCE[0]}")/../config/claude-accounts.json"

jq -e '.accounts' "$registry" >/dev/null 2>&1 || { echo "claude-pretrust: registry unreadable: $registry" >&2; exit 1; }

# Claude Code keys .projects by the physical path.
paths=()
rc=0
for path in "$@"; do
  real=$(cd "$path" 2>/dev/null && pwd -P) || { echo "claude-pretrust: not a directory: $path" >&2; rc=1; continue; }
  paths+=("$real")
done

(( ${#paths[@]} )) || exit "$rc"

while IFS= read -r dir; do
  dir=${dir/#\~/$HOME}
  cfg="$dir/.claude.json"
  [[ $dir == "$HOME" ]] && cfg="$HOME/.claude.json"
  [[ -f $cfg ]] || continue
  for path in "${paths[@]}"; do
    [[ "$(jq -r --arg p "$path" '.projects[$p].hasTrustDialogAccepted // false' "$cfg" 2>/dev/null)" == true ]] && continue
    tmp=$(mktemp "$(dirname "$cfg")/.claude.json.XXXXXX") || { rc=1; continue; }
    if jq --arg p "$path" '.projects[$p].hasTrustDialogAccepted = true' "$cfg" > "$tmp" \
      && chmod "$(stat -f %Lp "$cfg" 2>/dev/null || stat -c %a "$cfg")" "$tmp" && mv "$tmp" "$cfg"; then
      echo "    ✓ trusted $path in $cfg"
    else
      rm -f "$tmp"; echo "    ✗ could not trust $path in $cfg" >&2; rc=1
    fi
  done
done < <(jq -r '.accounts[] | (.dir // "~")' "$registry")
exit $rc
