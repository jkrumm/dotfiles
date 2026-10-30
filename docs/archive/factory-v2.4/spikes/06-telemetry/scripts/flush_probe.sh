#!/usr/bin/env bash
# Does a SHORT headless run lose telemetry at exit when the export intervals are left at their
# defaults (traces 5 s, logs 5 s, metrics 60 s)? (Spike 6: the "exporter" suspect.)
#
#   flush_probe.sh
#
# One `claude_iu -p` turn with no tools (agw's single-shot triage/decide shape), a warden-style
# root span and TRACEPARENT, telemetry through the same `--setting-sources project` lane agw uses.
# Prints the run's wall time and how many spans / log records / metric points reached ClickHouse.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCR="${SPIKE_SCRATCH:-$HOME/.local/share/factory/spikes/06-telemetry}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"; ITEM="spike6-D-${STAMP}"; OUT="$SCR/run/D-${STAMP}"
mkdir -p "$OUT/cwd"
unset HERDR_ENV HERDR_PANE_ID HERDR_SOCKET_PATH HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_BIN_PATH
echo "Reply with the single word OK." > "$OUT/prompt.txt"

export CLAUDE_CODE_ENABLE_TELEMETRY=1 CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1 CLAUDE_CODE_PROPAGATE_TRACEPARENT=1
export OTEL_TRACES_EXPORTER=otlp OTEL_METRICS_EXPORTER=otlp OTEL_LOGS_EXPORTER=otlp
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf OTEL_EXPORTER_OTLP_ENDPOINT="${SPIKE_OTLP_BASE:-http://localhost:4319}"
export OTEL_RESOURCE_ATTRIBUTES="warden.item.id=${ITEM},warden.spike=06"
# deliberately NOT set: OTEL_TRACES_EXPORT_INTERVAL, OTEL_LOGS_EXPORT_INTERVAL, OTEL_METRIC_EXPORT_INTERVAL

cd "$OUT/cwd"
START=$(date +%s)
python3 -I "$HERE/warden_item.py" run --item-id "$ITEM" --summary "$OUT/warden.json" -- \
  zsh -c 'source ~/.zsh/conf.d/claude.zsh >/dev/null 2>&1
          claude_iu --model haiku --dangerously-skip-permissions --strict-mcp-config --mcp-config "{\"mcpServers\":{}}" \
            --setting-sources project --settings "{\"disableAllHooks\":true}" --output-format json < "$1"' _ "$OUT/prompt.txt" \
  > "$OUT/worker.stdout" 2> "$OUT/worker.stderr" || true
echo "worker wall time: $(( $(date +%s) - START )) s (includes the warden export)"

sleep 8   # collector batch + ClickHouse insert, nothing more
TRACE="$(python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["trace_id"])' "$OUT/warden.json")"
python3 -I - "$TRACE" "$ITEM" <<'EOF'
import json, sys, urllib.request
trace, item = sys.argv[1], sys.argv[2]
def n(sql):
    r = urllib.request.urlopen(urllib.request.Request("http://localhost:8123/", data=(sql + " FORMAT JSONEachRow").encode(), method="POST")).read().decode()
    return json.loads(r.splitlines()[0])["n"]
print("trace id:", trace)
print("claude-code spans in the warden trace :", n(f"SELECT count() AS n FROM default.otel_traces WHERE TraceId='{trace}' AND ServiceName='claude-code'"))
print("claude-code log records in the trace  :", n(f"SELECT count() AS n FROM default.otel_logs WHERE TraceId='{trace}' AND ServiceName='claude-code'"))
print("claude-code metric points (item attr) :", n(f"SELECT count() AS n FROM default.otel_metrics_sum WHERE ResourceAttributes['warden.item.id']='{item}'"))
EOF
