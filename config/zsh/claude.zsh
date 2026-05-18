# Claude Code launcher
#
# Usage: c [claude-args...]
#
# Skills load from ~/.claude/skills/ (global) and <repo>/.claude/skills/ (per-repo)
# automatically — no --plugin-dir needed. Workspace detection lives in skills
# themselves (e.g. SourceRoot/IuRoot 1Password account routing).

c() {
  # Auto-sync Claude Code theme with macOS appearance (no "system" theme exists)
  local appearance claude_theme
  appearance=$(defaults read -g AppleInterfaceStyle 2>/dev/null)
  [[ "$appearance" == "Dark" ]] && claude_theme="dark-ansi" || claude_theme="light-ansi"
  jq --arg t "$claude_theme" '.theme = $t' ~/.claude.json > /tmp/.claude.json.tmp \
    && mv /tmp/.claude.json.tmp ~/.claude.json

  ENABLE_TOOL_SEARCH=true ANTHROPIC_API_KEY="" ANTHROPIC_BASE_URL="" claude --dangerously-skip-permissions "$@"
}
