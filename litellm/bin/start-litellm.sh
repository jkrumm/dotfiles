#!/bin/bash
# LiteLLM proxy wrapper — Anthropic↔OpenAI bridge on 127.0.0.1:4000.
#
# Started by ~/Library/LaunchAgents/com.litellm.proxy.plist via launchd.
# Lets `claude -p` reach IU's OpenAI-only models (Kimi-K2.6 etc.) by translating
# Anthropic /v1/messages → OpenAI /chat/completions. See docs/kimi-litellm-bridge.md.
#
# Reads the IU credential from the Keychain (the same entry `make setup` caches
# for claude offloading) and derives the OpenAI-compatible base URL from it.
# Neither value is written to the committed config — both arrive via os.environ.
#
# launchd needs PID 1 alive for the duration; exec litellm in the foreground.

set -u

PORT="${LITELLM_PORT:-4000}"
CONFIG="$HOME/.config/litellm/config.yaml"

KEY=$(security find-generic-password -s claude-sdk-api-key -w 2>/dev/null || echo "")
BASE=$(security find-generic-password -s claude-sdk-base-url -w 2>/dev/null || echo "")
BASE="${BASE%/}"

if [ -z "$KEY" ] || [ -z "$BASE" ]; then
  echo "litellm: IU credentials missing in Keychain — run 'make setup' in dotfiles" >&2
  exit 1
fi

# claude-sdk-base-url is the IU Anthropic transport (…/anthropic). Derive the
# OpenAI-compatible transport the bridge forwards to.
export IU_API_KEY="$KEY"
export IU_OPENAI_BASE_URL="${BASE%/anthropic}/openai/v1"

# LiteLLM's Anthropic passthrough defaults to the OpenAI Responses API, which IU
# does not serve for Kimi. Force chat/completions instead. (See bridge doc.)
export LITELLM_USE_CHAT_COMPLETIONS_URL_FOR_ANTHROPIC_MESSAGES=true

exec "$HOME/.local/share/uv/tools/litellm/bin/litellm" \
  --config "$CONFIG" \
  --port "$PORT" \
  --host 127.0.0.1
