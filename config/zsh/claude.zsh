# Claude Code launcher — with cqueue /clear restart loop
#
# Usage: c [claude-args...]
#
# Skills load from ~/.claude/skills/ (global) and <repo>/.claude/skills/ (per-repo)
# automatically — no --plugin-dir needed. Workspace detection lives in skills
# themselves (e.g. SourceRoot/IuRoot 1Password account routing).
#
# Queue restart: when the stop hook writes a next task to .queue-restart,
# the session is restarted with fresh context and the task injected.

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

    ENABLE_TOOL_SEARCH=true ANTHROPIC_API_KEY="" ANTHROPIC_BASE_URL="" claude --dangerously-skip-permissions "${claude_args[@]}"

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
