#!/usr/bin/env bash
# Exec'd by com.jkrumm.host-agent (LaunchAgent). Resolves the machine's name and the two secrets at RUNTIME, so neither
# the ingestion key nor the endpoint sits in the plist or on disk on the mini (doctor's LaunchAgent audit flags a
# credential in EnvironmentVariables).
#   cache backend (the mini):  host.name=mini, both values through secrets-run.
#   op backend (the MacBook):  host.name=macbook; a LaunchAgent cannot answer a biometric prompt, so `make agent-setup`
#                              wrote them into ~/.config/host-agent/agent.env (mode 600, rewritten on every run), read here.
set -euo pipefail
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

BACKEND="$(tr -d '[:space:]' < "$HOME/.config/secrets/backend" 2>/dev/null || echo "")"
STATE="$HOME/.local/state/host-agent"

case "$BACKEND" in
  cache)
    AGENT_HOST_NAME=mini
    AGENT_OTLP_ENDPOINT="$(secrets-run read op://mini/agent-workflows/OTEL_EXPORTER_OTLP_ENDPOINT)"
    AGENT_OTLP_API_KEY="$(secrets-run read op://vps/argo/HYPERDX_API_KEY_PROD)"
    ;;
  op)
    AGENT_HOST_NAME=macbook
    ENV_FILE="$HOME/.config/host-agent/agent.env"
    [ -r "$ENV_FILE" ] || { echo "host-agent-wrapper: no $ENV_FILE — run make agent-setup" >&2; exit 1; }
    # Parsed, never sourced: a value is data (an endpoint with & or ;, a key with $ or a space), not shell.
    while IFS='=' read -r key value; do
      case "$key" in
        AGENT_OTLP_ENDPOINT) AGENT_OTLP_ENDPOINT="$value" ;;
        AGENT_OTLP_API_KEY) AGENT_OTLP_API_KEY="$value" ;;
      esac
    done < "$ENV_FILE"
    ;;
  *)
    echo "host-agent-wrapper: unknown secrets backend '$BACKEND'" >&2
    exit 1
    ;;
esac
[ -n "${AGENT_OTLP_ENDPOINT:-}" ] && [ -n "${AGENT_OTLP_API_KEY:-}" ] || { echo "host-agent-wrapper: endpoint or key is empty" >&2; exit 1; }

export AGENT_HOST_NAME AGENT_OTLP_ENDPOINT AGENT_OTLP_API_KEY
export AGENT_ENVIRONMENT=prod
export AGENT_QUEUE_DIR="$STATE/queue"
mkdir -p "$AGENT_QUEUE_DIR"

exec "$HOME/.local/bin/host-agent" --config "$(dirname "$0")/config.yaml"
