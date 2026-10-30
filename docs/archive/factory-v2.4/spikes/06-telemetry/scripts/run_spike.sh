#!/usr/bin/env bash
# One end-to-end trace attempt: warden-spike root span -> Claude Code worker -> gateway calls.
#
#   run_spike.sh <variant> [otlp-protocol]
#     A   headless `claude_iu -p`, telemetry + beta traces + inherited TRACEPARENT (the naive setup)
#     B   A + CLAUDE_CODE_PROPAGATE_TRACEPARENT=1  (needed on a custom ANTHROPIC_BASE_URL)
#     I   INTERACTIVE claude in a pty (the herdr / `rd wave` shape), B's env otherwise
#     S   agent-gateway's claude lane: `-p --setting-sources project --settings {"disableAllHooks":true}`,
#         B's env, and NO telemetry --settings override (user settings are not loaded at all)
#     protocol: http/protobuf (default) | http/json
#
# Prerequisites: local ClickStack up (make -C ~/SourceRoot/vps clickstack-up) and
# `services.sh start`. Output lands in $SPIKE_SCRATCH/run/<variant>-<utc stamp>/; the trace id is
# printed last. No timeout wraps the worker (rules/agent-limits.md).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCR="${SPIKE_SCRATCH:-$HOME/.local/share/factory/spikes/06-telemetry}"
VARIANT="${1:?variant A|B|I|S}"
PROTO="${2:-http/protobuf}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
ITEM="spike6-${VARIANT}-${STAMP}"
OUT="$SCR/run/${VARIANT}-${STAMP}"
mkdir -p "$OUT/cwd"

# A nested session must not talk to the herdr pane this script runs in (its SessionStart hook
# would report the probe's session id for the parent's pane).
unset HERDR_ENV HERDR_PANE_ID HERDR_SOCKET_PATH HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_BIN_PATH

# MCP config: ONLY the stub (--strict-mcp-config), so no live gateway is contacted.
cat > "$OUT/mcp.json" <<'JSON'
{"mcpServers":{"spikestub":{"type":"http","url":"http://localhost:17790/mcp"}}}
JSON

# Worker prompt. The bearer travels as an env var, never inline, so span attributes
# (OTEL_LOG_TOOL_DETAILS=1 records the Bash command) do not carry it.
cat > "$OUT/prompt.txt" <<'PROMPT'
You are a telemetry probe. Do exactly these four steps in order, one tool call each. Do not explain, retry, or run anything else.

Step 1. Bash, exactly:
echo "TRACEPARENT_IN_BASH=${TRACEPARENT:-unset}"

Step 2. Bash, exactly:
if [ -n "$TRACEPARENT" ]; then curl -sS -m 20 -X POST -H "traceparent: $TRACEPARENT" -H "authorization: Bearer $SPIKE_GW_TOKEN" -H "content-type: application/json" -d '{"query":"spike probe","depth":"quick"}' http://localhost:17780/research; else curl -sS -m 20 -X POST -H "authorization: Bearer $SPIKE_GW_TOKEN" -H "content-type: application/json" -d '{"query":"spike probe","depth":"quick"}' http://localhost:17780/research; fi

Step 3. Bash, exactly:
if [ -n "$TRACEPARENT" ]; then curl -sS -m 20 -H "traceparent: $TRACEPARENT" http://localhost:17790/health; else curl -sS -m 20 http://localhost:17790/health; fi

Step 4. Call the MCP tool mcp__spikestub__ping with note "spike6".

Finally reply with exactly one word: the words PROBE and FINISHED joined by an underscore.
PROMPT

# Telemetry env for the worker. CLAUDE_CODE_ENABLE_TELEMETRY is ALSO forced through --settings
# below: ~/.claude/settings.json sets it to "0" in its env block, which beats the process env.
export CLAUDE_CODE_ENABLE_TELEMETRY=1
export CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1
export OTEL_TRACES_EXPORTER=otlp OTEL_METRICS_EXPORTER=otlp OTEL_LOGS_EXPORTER=otlp
export OTEL_EXPORTER_OTLP_PROTOCOL="$PROTO"
export OTEL_EXPORTER_OTLP_ENDPOINT="${SPIKE_OTLP_BASE:-http://localhost:4319}"
export OTEL_TRACES_EXPORT_INTERVAL=1000 OTEL_LOGS_EXPORT_INTERVAL=1000 OTEL_METRIC_EXPORT_INTERVAL=5000
export OTEL_LOG_TOOL_DETAILS=1
export OTEL_RESOURCE_ATTRIBUTES="warden.item.id=${ITEM},warden.spike=06"
export SPIKE_GW_TOKEN="$(cat "$SCR/run/gw/secret.txt")"
if [[ "$VARIANT" != "A" ]]; then export CLAUDE_CODE_PROPAGATE_TRACEPARENT=1; fi

: > "$SCR/run/stub-requests.jsonl"   # fresh request log per run

if [[ "$VARIANT" == "I" ]]; then
  # cwd = ~/SourceRoot, which the owner has already trusted: skips the one-time trust dialog.
  WORKER=(python3 -I "$HERE/interactive_probe.py" --cwd "$HOME/SourceRoot" --prompt-file "$OUT/prompt.txt"
          --mcp-config "$OUT/mcp.json" --done-marker PROBE_FINISHED --transcript "$OUT/pty-transcript.txt")
elif [[ "$VARIANT" == "S" ]]; then
  WORKER=(zsh -c 'source ~/.zsh/conf.d/claude.zsh >/dev/null 2>&1
                  claude_iu --model haiku --dangerously-skip-permissions --strict-mcp-config \
                    --mcp-config "$1" --setting-sources project --settings "{\"disableAllHooks\":true}" \
                    --output-format stream-json --verbose < "$2"' _ "$OUT/mcp.json" "$OUT/prompt.txt")
else
  WORKER=(zsh -c 'source ~/.zsh/conf.d/claude.zsh >/dev/null 2>&1
                  claude_iu --model haiku --dangerously-skip-permissions --strict-mcp-config \
                    --mcp-config "$1" --settings "{\"env\":{\"CLAUDE_CODE_ENABLE_TELEMETRY\":\"1\"}}" \
                    --output-format stream-json --verbose < "$2"' _ "$OUT/mcp.json" "$OUT/prompt.txt")
fi

# warden_item.py exports TRACEPARENT into the worker's env only and emits the root span afterwards.
cd "$OUT/cwd"
python3 -I "$HERE/warden_item.py" run --item-id "$ITEM" --summary "$OUT/warden.json" -- "${WORKER[@]}" \
  > "$OUT/worker.stdout" 2> "$OUT/worker.stderr" || true
cp "$SCR/run/stub-requests.jsonl" "$OUT/stub-requests.jsonl"
[[ "$VARIANT" == "I" ]] || mv "$OUT/worker.stdout" "$OUT/claude.stream.jsonl"

TRACE_ID="$(python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["trace_id"])' "$OUT/warden.json")"
echo "$TRACE_ID" > "$OUT/trace_id.txt"
echo "variant=$VARIANT protocol=$PROTO item=$ITEM"
echo "out=$OUT"
echo "trace_id=$TRACE_ID"
