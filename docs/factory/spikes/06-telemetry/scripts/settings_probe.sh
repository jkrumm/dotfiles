#!/usr/bin/env bash
# Does the process environment or ~/.claude/settings.json win for CLAUDE_CODE_ENABLE_TELEMETRY?
# (Spike 6: break point 1.) The global settings template sets it to "0" in its env block.
#
#   settings_probe.sh
#
# Three one-turn headless runs with an identical OTLP env, differing only in how telemetry is
# switched on; prints how many claude-code spans each produced.
set -euo pipefail

SCR="${SPIKE_SCRATCH:-$HOME/.local/share/factory/spikes/06-telemetry}"
unset HERDR_ENV HERDR_PANE_ID HERDR_SOCKET_PATH HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_BIN_PATH
mkdir -p "$SCR/run/settings-probe/cwd"; echo "Reply with the single word OK." > "$SCR/run/settings-probe/prompt.txt"
cd "$SCR/run/settings-probe/cwd"

run() { # <slug> <label> <extra claude flags...>   (slug becomes the item id: no spaces or commas allowed)
  local slug="$1" label="$2"; shift 2
  local item="spike6-settings-${slug}-$(date -u +%H%M%S)"
  ( export CLAUDE_CODE_ENABLE_TELEMETRY=1 CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1 OTEL_TRACES_EXPORTER=otlp \
           OTEL_METRICS_EXPORTER=none OTEL_LOGS_EXPORTER=none OTEL_TRACES_EXPORT_INTERVAL=1000 \
           OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf OTEL_EXPORTER_OTLP_ENDPOINT="${SPIKE_OTLP_BASE:-http://localhost:4319}" \
           OTEL_RESOURCE_ATTRIBUTES="warden.item.id=${item}"
    zsh -c 'source ~/.zsh/conf.d/claude.zsh >/dev/null 2>&1; label=$1; shift
            claude_iu --model haiku --dangerously-skip-permissions --strict-mcp-config --mcp-config "{\"mcpServers\":{}}" "$@" --output-format json < "$SPIKE_PROMPT"' _ "$label" "$@" \
      > /dev/null 2>&1 ) || true
  sleep 5
  local n
  n=$(python3 -I - "$item" <<'PY'
import sys, urllib.request
sql = f"SELECT count() FROM default.otel_traces WHERE ServiceName = 'claude-code' AND ResourceAttributes['warden.item.id'] = '{sys.argv[1]}'"
print(urllib.request.urlopen(urllib.request.Request("http://localhost:8123/", data=sql.encode(), method="POST")).read().decode().strip())
PY
)
  printf '%-58s claude-code spans: %s\n' "$label" "$n"
}
export SPIKE_PROMPT="$SCR/run/settings-probe/prompt.txt"
run envonly "env only (user settings.json env says 0)"
run override "env + --settings {env: ENABLE_TELEMETRY=1}" --settings '{"env":{"CLAUDE_CODE_ENABLE_TELEMETRY":"1"}}'
run agwlane "env + --setting-sources project (agent-gateway lane)" --setting-sources project --settings '{"disableAllHooks":true}'
