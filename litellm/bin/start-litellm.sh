#!/bin/bash
# LiteLLM proxy wrapper — Anthropic↔OpenAI bridge on 127.0.0.1:4000.
#
# Started by ~/Library/LaunchAgents/com.litellm.proxy.plist via launchd.
# Lets `claude -p` reach IU's OpenAI-only models (DeepSeek-V4-Pro etc.) by translating
# Anthropic /v1/messages → OpenAI /chat/completions. See docs/deepseek-litellm-bridge.md.
#
# Reads the IU credential from the Keychain (the same entry `make setup` caches
# for claude offloading) and derives the OpenAI-compatible base URL from it.
# Neither value is written to the committed config — both arrive via os.environ.
#
# The Keychain is not a reliable source on a headless machine: a launchd job that
# outlives (or predates) a GUI login gets a LOCKED login keychain, and
# `security find-generic-password` then fails. So each value falls back to
# `secrets-run read` on the same op:// ref `make setup` cached it from — cache
# backend on the mini (no prompt, no network), live `op` on the MacBook. Both
# lookups failing is fatal: an empty credential would start a bridge that 401s
# every request while looking healthy.
#
# launchd needs PID 1 alive for the duration; exec litellm in the foreground.

set -u

# launchd hands agents a minimal PATH; secrets-run lives in ~/.local/bin.
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

PORT="${LITELLM_PORT:-4000}"
CONFIG="$HOME/.config/litellm/config.yaml"

# keychain_or_cache <keychain-service> <op-ref> — prints the value, empty on total failure.
keychain_or_cache() {
  local v
  v=$(security find-generic-password -s "$1" -w 2>/dev/null) && [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  command -v secrets-run >/dev/null 2>&1 || return 0
  v=$(secrets-run read "$2" 2>/dev/null) && printf '%s' "$v"
}

KEY=$(keychain_or_cache claude-sdk-api-key op://common/anthropic/API_KEY)
BASE=$(keychain_or_cache claude-sdk-base-url op://common/anthropic/BASE_URL)
BASE="${BASE%/}"

if [ -z "$KEY" ] || [ -z "$BASE" ]; then
  echo "litellm: IU credentials unresolvable — neither the Keychain (claude-sdk-*) nor" >&2
  echo "         secrets-run (op://common/anthropic/{API_KEY,BASE_URL}) returned a value." >&2
  echo "         Run 'make setup' in dotfiles, or reseed the cache from the MacBook." >&2
  exit 1
fi

# claude-sdk-base-url is the IU Anthropic transport (…/anthropic). Derive the
# OpenAI-compatible transport the bridge forwards to.
export IU_API_KEY="$KEY"
export IU_OPENAI_BASE_URL="${BASE%/anthropic}/openai/v1"

# LiteLLM's Anthropic passthrough defaults to the OpenAI Responses API, which IU
# does not serve for these models. Force chat/completions instead. (See bridge doc.)
export LITELLM_USE_CHAT_COMPLETIONS_URL_FOR_ANTHROPIC_MESSAGES=true

exec "$HOME/.local/share/uv/tools/litellm/bin/litellm" \
  --config "$CONFIG" \
  --port "$PORT" \
  --host 127.0.0.1
