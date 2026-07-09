# Claude Code launcher
#
# Usage: c  [claude-args...]   — Max subscription (default)
#        cs [claude-args...]   — Max subscription, defaults to Sonnet model
#        ca [claude-args...]   — LiteLLM bridge (DeepSeek-V4-Pro etc.), same setup
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

# Same as `c` (Max subscription, same config dir) but starts on Sonnet instead
# of whatever /model last left the session on — for when Opus is the default
# and this particular chat doesn't need it. `cs --model opus` overrides back.
cs() {
  local appearance claude_theme
  appearance=$(defaults read -g AppleInterfaceStyle 2>/dev/null)
  [[ "$appearance" == "Dark" ]] && claude_theme="dark-ansi" || claude_theme="light-ansi"
  jq --arg t "$claude_theme" '.theme = $t' ~/.claude.json > /tmp/.claude.json.tmp \
    && mv /tmp/.claude.json.tmp ~/.claude.json

  local -a plugin_args=()
  local git_root pdir
  git_root=$(git rev-parse --show-toplevel 2>/dev/null)
  if [[ -n "$git_root" ]]; then
    for pdir in "$git_root"/plugins/*/.claude-plugin(/N); do
      plugin_args+=(--plugin-dir "${pdir:h}")
    done
  fi

  local -a args=("$@")
  [[ " $* " == *" --model "* ]] || args=(--model sonnet "${args[@]}")

  ENABLE_TOOL_SEARCH=true ANTHROPIC_API_KEY="" ANTHROPIC_BASE_URL="" claude --dangerously-skip-permissions "${plugin_args[@]}" "${args[@]}"
}

# Same launcher as `c` — same skills/agents/hooks/CLAUDE.md, since it's the same
# ~/.claude config dir — but routed through the IU unified endpoint's native
# Anthropic transport (real Claude models, API-billed per-token) instead of the
# Max subscription. Default model: claude-sonnet-5 (latest Sonnet tier). To use a
# different model permanently, change the --model default below; a one-off
# `ca --model claude-opus-4-8` also works for any model the IU Anthropic endpoint
# serves (run /iu-endpoint for the live catalog).
#
# Full Anthropic protocol fidelity — no LiteLLM translation tax. Prompt caching
# works (first turn builds the cache, subsequent turns read at ~10% cost), tool
# use is native, WebSearch/WebFetch work, and tier differentiation is real.
#
# Default effort: high (matches --model, overridable with `ca --effort xhigh`).
# Effort is a plain request parameter (`claude --help` lists --effort), not
# gated by account/auth — it works the same over this custom base URL as it
# does on the Max subscription.
#
# Subagents/background tasks resolve by TIER (opus/sonnet/haiku/fable). A custom
# main-model name can't be classified into a tier, so each tier falls back to its
# hardcoded Anthropic default (claude-opus-4-8, …) which the IU endpoint may not
# serve. ANTHROPIC_DEFAULT_*_MODEL below pins every tier to the IU catalog:
# sonnet-5 for the workhorse tiers, haiku-4-5 for background (title-gen,
# compaction, fast reads). No opus/fable override — the sonnet fallback is cheap
# enough and those tiers are rarely invoked.
#
# Context window: over any non-api.anthropic.com ANTHROPIC_BASE_URL, Claude Code
# can't verify 1M support and budgets Sonnet 5 at 200k, even though it natively
# has 1M (docs: code.claude.com/docs/en/model-config#sonnet-5-context-window).
# CLAUDE_CODE_MAX_CONTEXT_TOKENS is not a real Claude Code env var — don't
# reintroduce it. The documented fix is the `[1m]` suffix (stripped before the
# model ID reaches the provider): --model claude-sonnet-5[1m], plus the same
# suffix on every ANTHROPIC_DEFAULT_*_MODEL tier that resolves to Sonnet 5.
#
# claude v2.x rejects ANTHROPIC_API_KEY in this flow ("Not logged in") — must
# be ANTHROPIC_AUTH_TOKEN. Env auth takes precedence over the cached claude.ai
# OAuth login for this process only — `c` and `ca` don't fight each other.
#
# IU creds are read from the macOS Keychain (same as claude_iu / opencode).
# The LiteLLM bridge is NOT used here — it's only for sideclaw workers
# (claude_bridge / mcp__sideclaw__*). ToolSearch stays on (ENABLE_TOOL_SEARCH)
# because the IU endpoint isn't api.anthropic.com and ToolSearch is off by
# default on non-first-party hosts.
#
# After editing this file: `source ~/.zshrc` (or open a new terminal). An
# already-open shell keeps running whatever `ca` it loaded at startup.
ca() {
  local key base
  key=$(security find-generic-password -s claude-sdk-api-key -w 2>/dev/null)
  base=$(security find-generic-password -s claude-sdk-base-url -w 2>/dev/null)
  if [[ -z "$key" || -z "$base" ]]; then
    print -ru2 "ca: IU credentials missing in Keychain — run 'make setup' in dotfiles"
    return 1
  fi

  local appearance claude_theme
  appearance=$(defaults read -g AppleInterfaceStyle 2>/dev/null)
  [[ "$appearance" == "Dark" ]] && claude_theme="dark-ansi" || claude_theme="light-ansi"
  jq --arg t "$claude_theme" '.theme = $t' ~/.claude.json > /tmp/.claude.json.tmp \
    && mv /tmp/.claude.json.tmp ~/.claude.json

  local -a plugin_args=()
  local git_root pdir
  git_root=$(git rev-parse --show-toplevel 2>/dev/null)
  if [[ -n "$git_root" ]]; then
    for pdir in "$git_root"/plugins/*/.claude-plugin(/N); do
      plugin_args+=(--plugin-dir "${pdir:h}")
    done
  fi

  local -a args=("$@")
  [[ " $* " == *" --model "* ]] || args=(--model "claude-sonnet-5[1m]" "${args[@]}")
  [[ " $* " == *" --effort "* ]] || args=(--effort high "${args[@]}")

  env -u ANTHROPIC_API_KEY \
    ANTHROPIC_AUTH_TOKEN="$key" \
    ANTHROPIC_BASE_URL="$base" \
    ANTHROPIC_DEFAULT_OPUS_MODEL="claude-sonnet-5[1m]" \
    ANTHROPIC_DEFAULT_SONNET_MODEL="claude-sonnet-5[1m]" \
    ANTHROPIC_DEFAULT_HAIKU_MODEL=claude-haiku-4-5 \
    ANTHROPIC_DEFAULT_FABLE_MODEL="claude-sonnet-5[1m]" \
    ENABLE_TOOL_SEARCH=true \
    claude --dangerously-skip-permissions "${plugin_args[@]}" "${args[@]}"
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
  # Pin subagent/background tiers to bridge-known names (see `ca` above) so any
  # -p flow that spawns a subagent can't fall back to an unmapped claude-* default.
  env -u ANTHROPIC_API_KEY \
    ANTHROPIC_AUTH_TOKEN="${LITELLM_BRIDGE_TOKEN:-sk-litellm-master-key}" \
    ANTHROPIC_BASE_URL="$url" \
    ANTHROPIC_DEFAULT_OPUS_MODEL=DeepSeek-V4-Pro \
    ANTHROPIC_DEFAULT_SONNET_MODEL=DeepSeek-V4-Pro \
    ANTHROPIC_DEFAULT_HAIKU_MODEL=DeepSeek-V4-Flash \
    ANTHROPIC_DEFAULT_FABLE_MODEL=DeepSeek-V4-Pro \
    CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1 \
    claude -p "${args[@]}"
}
