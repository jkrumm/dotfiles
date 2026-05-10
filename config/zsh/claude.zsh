# Claude Code launcher — workspace-aware with cqueue /clear restart loop
#
# Usage: c [claude-args...]
#
# Workspace detection:
#   ~/SourceRoot/*  → ensures <repo>/.claude/skills points at shared skills
#                     (lazy symlink for Zed parity), then plain claude
#   ~/IuRoot/*      → loads per-project .claude/ skills via --plugin-dir
#   elsewhere       → plain claude with ENABLE_TOOL_SEARCH
#
# Queue restart: when the stop hook writes a next task to .queue-restart,
# the session is restarted with fresh context and the task injected.

# API mode: pulls ANTHROPIC_API_KEY + ANTHROPIC_BASE_URL from 1Password and
# delegates to c() — bypasses subscription, routes through custom endpoint.
capi() {
  local api_key base_url
  api_key=$(op read "op://common/anthropic/API_KEY" --account tkrumm) || return 1
  base_url=$(op read "op://common/anthropic/BASE_URL" --account tkrumm) || return 1
  ANTHROPIC_API_KEY="$api_key" ANTHROPIC_BASE_URL="$base_url" c "$@"
}

c() {
  local restart_marker="$HOME/.claude/.queue-restart"
  local claude_args=("$@")

  while true; do
    # Auto-sync Claude Code theme with macOS appearance (no "system" theme exists)
    local appearance claude_theme
    appearance=$(defaults read -g AppleInterfaceStyle 2>/dev/null)
    [[ "$appearance" == "Dark" ]] && claude_theme="dark-ansi" || claude_theme="light-ansi"
    jq --arg t "$claude_theme" '.theme = $t' ~/.claude.json > /tmp/.claude.json.tmp \
      && mv /tmp/.claude.json.tmp ~/.claude.json

    if [[ "$PWD" == "$HOME/SourceRoot"* ]]; then
      # Lazy: ensure project sees the shared SourceRoot skills under
      # .claude/skills/ AND has CLAUDE.local.md importing ~/SourceRoot/CLAUDE.md.
      # Both needed for Zed's vendored Claude ACP, which can't accept --plugin-dir
      # and doesn't walk parent dirs above the workspace root. Mirrors the
      # _setup-sourceroot-* targets in Makefile.
      local repo_root
      repo_root=$(git rev-parse --show-toplevel 2>/dev/null)
      if [[ -n "$repo_root" && "$repo_root" != "$HOME/SourceRoot/dotfiles" && "$repo_root" == "$HOME/SourceRoot/"* ]]; then
        local skills_dir="$HOME/SourceRoot/.claude/skills"
        local link="$repo_root/.claude/skills"
        if [[ -L "$link" || ! -e "$link" ]]; then
          if [[ ! -L "$link" ]]; then
            mkdir -p "$repo_root/.claude"
            ln -sfn "$skills_dir" "$link"
          fi
        else
          for skill in "$skills_dir"/*/; do
            local sname dst
            sname=$(basename "$skill")
            dst="$link/$sname"
            [[ ! -e "$dst" && ! -L "$dst" ]] && ln -sfn "$skill" "$dst"
          done
        fi
        local claude_local="$repo_root/CLAUDE.local.md"
        [[ ! -f "$claude_local" ]] && echo '@~/SourceRoot/CLAUDE.md' > "$claude_local"
      fi
      ENABLE_TOOL_SEARCH=true ANTHROPIC_API_KEY="" ANTHROPIC_BASE_URL="" claude --dangerously-skip-permissions "${claude_args[@]}"
    elif [[ "$PWD" == "$HOME/IuRoot"* ]]; then
      ENABLE_TOOL_SEARCH=true ANTHROPIC_API_KEY="" ANTHROPIC_BASE_URL="" claude --dangerously-skip-permissions --plugin-dir "$(git rev-parse --show-toplevel 2>/dev/null || echo '.')/.claude" "${claude_args[@]}"
    else
      ENABLE_TOOL_SEARCH=true ANTHROPIC_API_KEY="" ANTHROPIC_BASE_URL="" claude --dangerously-skip-permissions "${claude_args[@]}"
    fi

    if [[ -f "$restart_marker" ]]; then
      local next_task
      next_task=$(<"$restart_marker")
      rm -f "$restart_marker"
      if [[ -n "$next_task" ]]; then
        echo "\n[cq] Fresh context — continuing queue\n"
        claude_args=("$next_task")
        continue
      fi
    fi
    break
  done
}
