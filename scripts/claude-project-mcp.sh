#!/bin/bash
# claude-project-mcp.sh — project-local `chrome-devtools` MCP registrations in one account's .claude.json.
#
# `claude mcp remove ... --scope user` and `claude mcp list` run from the dotfiles directory never see a
# registration under projects["<dir>"].mcpServers, yet every session started in <dir> (or a worktree of it)
# then spawns an npx + node pair (~150 MiB). This finds them across all projects of the file.
#
#   check <claude.json> <account>   one ✗ line per project holding the entry (exit 1), else one ✓ line (exit 0)
#   clean <claude.json> <account>   remove them: `claude mcp remove chrome-devtools --scope local` run in the
#                                   project directory (CLAUDE_CONFIG_DIR as the caller set it); a directory that
#                                   is gone, or an entry the CLI left behind, gets a jq rewrite that keeps
#                                   <claude.json>.bak-chrome-devtools. Exit 1 when an entry survives.
set -u

SERVER="chrome-devtools"

projects_with_server() { # $1 = file; one project path per line
  [ -f "$1" ] || return 0
  jq -r --arg s "$SERVER" '(.projects // {}) | to_entries[] | select((.value.mcpServers // {}) | has($s)) | .key' "$1" 2>/dev/null
}

rewrite() { # $1 = file, $2 = project path: drop the entry with jq, keeping a backup
  local file=$1 project=$2 tmp
  [ -f "$file.bak-chrome-devtools" ] || cp -p "$file" "$file.bak-chrome-devtools" || return 1
  tmp=$(mktemp "$file.XXXXXX") || return 1
  if jq --arg p "$project" --arg s "$SERVER" 'del(.projects[$p].mcpServers[$s])' "$file" > "$tmp"; then
    chmod "$(stat -f %Lp "$file")" "$tmp"
    mv "$tmp" "$file"
  else
    rm -f "$tmp"; return 1
  fi
}

has_entry() { # $1 = file, $2 = project
  jq -e --arg p "$2" --arg s "$SERVER" '(.projects[$p].mcpServers // {}) | has($s)' "$1" >/dev/null 2>&1
}

cmd=${1:-}; file=${2:-}; account=${3:-default account}
[ -n "$cmd" ] && [ -n "$file" ] || { echo "usage: $0 check|clean <claude.json> [account]" >&2; exit 2; }

found=$(projects_with_server "$file")
case "$cmd" in
  check)
    if [ -z "$found" ]; then
      echo "    ✓ no project-local $SERVER MCP ($account)"; exit 0
    fi
    while IFS= read -r p; do
      echo "    ✗ $SERVER MCP registered project-locally for $account in $p [starts in every session there — run make setup]"
    done <<< "$found"
    exit 1 ;;
  clean)
    rc=0
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      if [ -d "$p" ] && command -v claude >/dev/null 2>&1; then
        (cd "$p" && claude mcp remove "$SERVER" --scope local >/dev/null 2>&1) || true
      fi
      if has_entry "$file" "$p"; then
        rewrite "$file" "$p" || true
      fi
      if has_entry "$file" "$p"; then
        echo "    ✗ could not remove project-local $SERVER MCP for $account in $p"; rc=1
      else
        echo "    ✓ removed project-local $SERVER MCP for $account in $p"
      fi
    done <<< "$found"
    exit $rc ;;
  *) echo "usage: $0 check|clean <claude.json> [account]" >&2; exit 2 ;;
esac
