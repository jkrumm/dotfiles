#!/usr/bin/env bash
# Can a trace context reach a STDIO MCP server (agent-gateway's only transport)? (Spike 6, step 5.)
#
#   stdio_probe.sh
#
# Variant-B environment (telemetry + PROPAGATE=1 + inherited TRACEPARENT), `-p` worker, ONE MCP
# call to stdio_stub.py. Prints what the stub saw (env names, `_meta`) next to the tool span's
# own `tool_use_id`, so the correlation key can be compared by eye.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCR="${SPIKE_SCRATCH:-$HOME/.local/share/factory/spikes/06-telemetry}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"; ITEM="spike6-M-${STAMP}"; OUT="$SCR/run/M-${STAMP}"
mkdir -p "$OUT/cwd"
unset HERDR_ENV HERDR_PANE_ID HERDR_SOCKET_PATH HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_BIN_PATH

cat > "$OUT/mcp.json" <<JSON
{"mcpServers":{"spikestdio":{"command":"python3","args":["-I","$HERE/stdio_stub.py"],"env":{"SPIKE_STDIO_LOG":"$OUT/stdio-requests.jsonl"}}}}
JSON
echo 'Call the MCP tool mcp__spikestdio__ping once with note "spike6", then reply with exactly one word: the words PROBE and FINISHED joined by an underscore.' > "$OUT/prompt.txt"

export CLAUDE_CODE_ENABLE_TELEMETRY=1 CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1 CLAUDE_CODE_PROPAGATE_TRACEPARENT=1
export OTEL_TRACES_EXPORTER=otlp OTEL_METRICS_EXPORTER=none OTEL_LOGS_EXPORTER=none
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf OTEL_EXPORTER_OTLP_ENDPOINT="${SPIKE_OTLP_BASE:-http://localhost:4319}"
export OTEL_TRACES_EXPORT_INTERVAL=1000 OTEL_RESOURCE_ATTRIBUTES="warden.item.id=${ITEM},warden.spike=06"

cd "$OUT/cwd"
python3 -I "$HERE/warden_item.py" run --item-id "$ITEM" --summary "$OUT/warden.json" -- \
  zsh -c 'source ~/.zsh/conf.d/claude.zsh >/dev/null 2>&1
          claude_iu --model haiku --dangerously-skip-permissions --strict-mcp-config --mcp-config "$1" \
            --settings "{\"env\":{\"CLAUDE_CODE_ENABLE_TELEMETRY\":\"1\"}}" --output-format json < "$2"' _ "$OUT/mcp.json" "$OUT/prompt.txt" \
  > "$OUT/worker.stdout" 2> "$OUT/worker.stderr" || true

echo "--- what the stdio server saw"
cat "$OUT/stdio-requests.jsonl"
sleep 4
TRACE="$(python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["trace_id"])' "$OUT/warden.json")"
echo "--- the matching claude_code.tool span (tool_use_id) in trace $TRACE"
python3 -I - "$TRACE" <<'EOF'
import json, sys, urllib.request
sql = f"SELECT SpanAttributes['tool_name'] AS tool, SpanAttributes['tool_use_id'] AS tool_use_id FROM default.otel_traces WHERE TraceId='{sys.argv[1]}' AND SpanName='claude_code.tool' AND SpanAttributes['tool_name'] LIKE 'mcp%' FORMAT JSONEachRow"
print(urllib.request.urlopen(urllib.request.Request("http://localhost:8123/", data=sql.encode(), method="POST")).read().decode().strip() or "(no mcp tool span)")
EOF
