---
name: otel
description: >
  Query and debug OpenTelemetry data (traces, logs, metrics) in ClickHouse (HyperDX/ClickStack) via the
  sideclaw MCP `otel` tool. Use when investigating application errors, slow or missing traces, log anomalies,
  service health, or any observability question in local dev or VPS production (local + prod both supported).
---

# OTEL Debug — via sideclaw MCP

Call `mcp__sideclaw__otel` with:
- `investigation` — what to look into (error message, service, trace id, anomaly, time range).
- `environment` — `local` or `prod`.
- `cwd` (optional) — defaults to $HOME. OTEL access is host-level, so this rarely matters.

The worker runs **read-only** on Kimi-K2.6 via the LiteLLM bridge (EU/GDPR, off Max
quota) and queries ClickHouse through `~/.claude/skills/otel/scripts/query.py`. Only
the structured result (`status`, `environment`, `timeRange`, `findings`,
`recommendations`) returns to the caller — the raw query output stays in the worker.

Inspect `status` first: `errors` = active error spans/logs, `degraded` = elevated
latency or warnings, `healthy` = data flowing normally.

**Reliability:** Kimi-K2.6 is single-backend (Azure Sweden) and occasionally
throttles — a query can take 1–6 min. The tool's 8-min timeout absorbs most of it;
on a hard timeout, retry. If the LiteLLM bridge is down, the tool errors with a
`make litellm-restart` hint.

**Maintenance:** the ClickHouse query script (`scripts/query.py`) is the canonical
access path and lives here in dotfiles, not in sideclaw — add presets / schema
changes there. The sideclaw worker invokes it by absolute `$HOME` path.
