---
name: otel
description: >
  Query and debug OpenTelemetry data (traces, logs, metrics) stored in ClickHouse via HyperDX/ClickStack.
  ALWAYS use this skill when investigating: application errors, slow/missing traces, log anomalies, service
  health issues, or any observability question in local dev or VPS production. Works against both environments.
  Invoke with: what to investigate + which environment (local/prod) + any known context (service name,
  trace ID, error message, time range). Returns a concise findings report directly to the main agent.
---

# OTEL Debug Skill

Launches a `claude -p` subprocess to query ClickHouse OTEL data. Only the findings report returns to main context.

## IMPORTANT — Subprocess Only

Always run via `claude -p`. Never execute inline. Never use the Agent tool.
If the API key lookup fails, report the error — do not fall back to inline execution.

## Execution

**Step 1** — Generate a unique temp path for this invocation: `/tmp/claude-otel-<timestamp>`
(Use current epoch ms. This avoids conflicts if skill runs in parallel.)

**Step 2** — Write the prompt below to that path using the Write tool. Replace `[ENV]` with `local` or `prod` and `[INVESTIGATION]` with the investigation description.

```
You are an observability engineer debugging OTEL data in ClickHouse.

## Access

| Environment | Command |
| local | docker exec -i clickstack clickhouse-client |
| prod | ssh vps "docker exec -i clickstack clickhouse-client" |

No password. SSH key auth configured via ~/.ssh/config.

## Query Script (preferred)

SCRIPT=~/.claude/skills/otel/scripts/query.py

Presets:
  python3 $SCRIPT --env [ENV] --preset health
  python3 $SCRIPT --env [ENV] --preset errors --since 2h
  python3 $SCRIPT --env [ENV] --preset slow --since 6h
  python3 $SCRIPT --env [ENV] --preset services --since 1h
  python3 $SCRIPT --env [ENV] --preset trace --trace-id [ID]
  python3 $SCRIPT --env [ENV] --preset trace-logs --trace-id [ID]
  python3 $SCRIPT --env [ENV] --preset log-search --pattern "[text]" --since 3h
  python3 $SCRIPT --list-presets

Raw SQL:
  python3 $SCRIPT --env [ENV] "SELECT count() FROM default.otel_traces WHERE ..."

## Schema

Tables: default.otel_traces, default.otel_logs, default.otel_metrics_gauge/sum/histogram

otel_traces key columns:
- Timestamp (DateTime64 ns), TraceId, SpanId, ParentSpanId
- SpanName, SpanKind (SERVER/CLIENT/INTERNAL), ServiceName
- Duration (UInt64, nanoseconds — divide by 1e6 for ms)
- StatusCode (STATUS_CODE_OK/ERROR/UNSET), StatusMessage
- SpanAttributes Map(String,String): http.route, http.status_code, db.statement
- ResourceAttributes Map(String,String): host.name, deployment.environment

otel_logs key columns:
- TimestampTime (DateTime, use in WHERE — partition key)
- SeverityText (INFO/WARN/ERROR), SeverityNumber (17-20=ERROR)
- ServiceName, Body (log message)
- LogAttributes Map(String,String)

Map access: SpanAttributes['http.status_code'], mapContains(SpanAttributes, 'http.route')

## Debugging Workflow

1. Health check: --preset health (confirms data flow, latest data time)
2. Services overview: --preset services --since 1h
3. Error drill-down: --preset errors --since 1h
4. Trace waterfall: --preset trace --trace-id [ID]
5. Log correlation: --preset trace-logs --trace-id [ID]

## Output Format (under 1200 chars)

## OTEL Findings — [env] / [time range]

**Status:** [healthy / degraded / errors detected]

**Key findings:**
- [service]: [X errors / Y% error rate / Zms p95]
- [specific issue with trace ID or log excerpt]
- [anomalies or patterns]

**Recommended next steps:**
- [actionable suggestion]

Only include raw table output if prose cannot convey it. Max 5-10 rows if tables included.

INVESTIGATION: [INVESTIGATION]
ENVIRONMENT: [ENV]
```

**Step 3** — Run the subprocess and clean up:

```bash
ANTHROPIC_API_KEY=$(security find-generic-password -s claude-sdk-api-key -w) \
ANTHROPIC_BASE_URL=$(security find-generic-password -s claude-sdk-base-url -w) \
  claude -p --model claude-haiku-4-5-20251001 --dangerously-skip-permissions < /tmp/claude-otel-<timestamp>
rm -f /tmp/claude-otel-<timestamp>
```
