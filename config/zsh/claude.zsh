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

# ── Off-Max `claude -p` transports ────────────────────────────────────────────
#
# Two helpers so subprocess skills (otel, analyze, read-drawing, ralph cleanup)
# don't copy-paste the IU credential plumbing. Both run `claude -p` off the Max
# subscription — billing is IU per-token, not Max quota. Pass any `claude -p`
# flags + a prompt (positional or via stdin), e.g.
#
#   claude_iu     --model haiku --dangerously-skip-permissions < prompt.txt
#   claude_bridge --model Kimi-K2.6 --dangerously-skip-permissions < prompt.txt
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

# Local LiteLLM bridge (LaunchAgent on :4000) → Kimi-K2.6 (EU/GDPR, Azure Sweden),
# with native failover to claude-sonnet-4-6-eu. Defaults --model to Kimi-K2.6 if
# the caller omits it (the bridge 404s on an unmapped model name). The bridge
# derives its own IU creds; the token here is a dummy claude v2.x requires.
# Constraint: no WebSearch/WebFetch (they make internal Anthropic calls the bridge
# can't serve). See dotfiles/docs/kimi-litellm-bridge.md.
claude_bridge() {
  local url="${LITELLM_BRIDGE_URL:-http://127.0.0.1:4000}"
  if ! curl -fsS -m 3 "${url}/health/liveliness" >/dev/null 2>&1; then
    print -ru2 "claude_bridge: LiteLLM bridge unreachable at ${url} — run 'make litellm-restart' in dotfiles"
    return 1
  fi
  local -a args=("$@")
  [[ " $* " == *" --model "* ]] || args=(--model Kimi-K2.6 "${args[@]}")
  env -u ANTHROPIC_API_KEY \
    ANTHROPIC_AUTH_TOKEN="${LITELLM_BRIDGE_TOKEN:-sk-litellm-master-key}" \
    ANTHROPIC_BASE_URL="$url" \
    CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1 \
    claude -p "${args[@]}"
}
