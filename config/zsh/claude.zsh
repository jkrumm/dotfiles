# Claude Code launcher
#
# Usage: c [claude-args...]
#
# Skills load from ~/.claude/skills/ (global) and <repo>/.claude/skills/ (per-repo)
# automatically. Additionally, if the current git repo ships local plugins under
# plugins/*/.claude-plugin (e.g. basalt-ui), they're loaded live via --plugin-dir so
# skill edits apply without publishing — a no-op in repos without them. Workspace
# detection lives in skills themselves (e.g. SourceRoot/IuRoot 1Password routing).

c() {
  # Auto-sync Claude Code theme with macOS appearance (no "system" theme exists)
  local appearance claude_theme
  appearance=$(defaults read -g AppleInterfaceStyle 2>/dev/null)
  [[ "$appearance" == "Dark" ]] && claude_theme="dark-ansi" || claude_theme="light-ansi"
  jq --arg t "$claude_theme" '.theme = $t' ~/.claude.json > /tmp/.claude.json.tmp \
    && mv /tmp/.claude.json.tmp ~/.claude.json

  # Local Claude Code plugin dev: load any plugins this repo ships under
  # plugins/*/.claude-plugin live from disk, so SKILL.md edits apply without
  # publishing. No-op outside such repos. (/N) = dirs-only + nullglob.
  local -a plugin_args=()
  local git_root pdir
  git_root=$(git rev-parse --show-toplevel 2>/dev/null)
  if [[ -n "$git_root" ]]; then
    for pdir in "$git_root"/plugins/*/.claude-plugin(/N); do
      plugin_args+=(--plugin-dir "${pdir:h}")
    done
  fi

  ENABLE_TOOL_SEARCH=true ANTHROPIC_API_KEY="" ANTHROPIC_BASE_URL="" claude --dangerously-skip-permissions "${plugin_args[@]}" "$@"
}

# ── Off-Max `claude -p` transports ────────────────────────────────────────────
#
# Two helpers so subprocess skills (otel, analyze, read-drawing, ralph cleanup)
# don't copy-paste the IU credential plumbing. Both run `claude -p` off the Max
# subscription — billing is IU per-token, not Max quota. Pass any `claude -p`
# flags + a prompt (positional or via stdin), e.g.
#
#   claude_iu     --model haiku --dangerously-skip-permissions < prompt.txt
#   claude_bridge --model DeepSeek-V4-Pro --dangerously-skip-permissions < prompt.txt
#
# ANTHROPIC_API_KEY is stripped: claude v2.x rejects it ("Not logged in") and it
# would shadow ANTHROPIC_AUTH_TOKEN.

# IU unified endpoint, native Anthropic transport. Best Claude fidelity; NOT
# EU-residency-guaranteed (native routing can land in the US — use claude_bridge
# for GDPR-bound data). Creds from the same Keychain entries `make setup` caches.
claude_iu() {
  local key base
  key=$(security find-generic-password -s claude-sdk-api-key -w 2>/dev/null)
  base=$(security find-generic-password -s claude-sdk-base-url -w 2>/dev/null)
  if [[ -z "$key" || -z "$base" ]]; then
    print -ru2 "claude_iu: IU credentials missing in Keychain — run 'make setup' in dotfiles"
    return 1
  fi
  env -u ANTHROPIC_API_KEY \
    ANTHROPIC_AUTH_TOKEN="$key" \
    ANTHROPIC_BASE_URL="$base" \
    claude -p "$@"
}

# Local LiteLLM bridge (LaunchAgent on :4000) → DeepSeek-V4-Pro (EU/GDPR, Azure Spain),
# with native failover to claude-sonnet-4-6-eu. Defaults --model to DeepSeek-V4-Pro if
# the caller omits it (the bridge 404s on an unmapped model name). Pass
# --model DeepSeek-V4-Flash for the fast/cheap tier. The bridge derives its own IU
# creds; the token here is a dummy claude v2.x requires. Constraint: no
# WebSearch/WebFetch (they make internal Anthropic calls the bridge can't serve).
# See dotfiles/docs/deepseek-litellm-bridge.md.
claude_bridge() {
  local url="${LITELLM_BRIDGE_URL:-http://127.0.0.1:4000}"
  if ! curl -fsS -m 3 "${url}/health/liveliness" >/dev/null 2>&1; then
    print -ru2 "claude_bridge: LiteLLM bridge unreachable at ${url} — run 'make litellm-restart' in dotfiles"
    return 1
  fi
  local -a args=("$@")
  [[ " $* " == *" --model "* ]] || args=(--model DeepSeek-V4-Pro "${args[@]}")
  env -u ANTHROPIC_API_KEY \
    ANTHROPIC_AUTH_TOKEN="${LITELLM_BRIDGE_TOKEN:-sk-litellm-master-key}" \
    ANTHROPIC_BASE_URL="$url" \
    CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1 \
    claude -p "${args[@]}"
}
