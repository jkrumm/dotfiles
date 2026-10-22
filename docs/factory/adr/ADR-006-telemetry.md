# ADR-006 — Telemetry: one trace per item, two join keys, one ClickHouse

- Status: accepted · 2026-10-22
- Evidence: `spikes/06-telemetry/REPORT.md` (headline trace `c1800a6ba3c5467f27450aab536071b5`: 25 spans, 3 services, 40 correlated logs), `research/2026-10-22-agents-durable-mcp-otel.md` §7, Round 5 *Established facts* (Observability)

## Context and problem statement

Nothing ties a warden item to the agent that worked on it and the gateway calls it made: agw,
warden, Hermes and OpenCode emit nothing joinable, no service propagates `traceparent`, and cost
per item is a guess. Can one trace run from an item through a herdr worker to a gateway?

## Findings that decide it

- Headless Claude Code (`claude -p`) joins a supplied `TRACEPARENT` and forwards it into Bash and
  HTTP MCP calls — but on the IU base URL only with `CLAUDE_CODE_PROPAGATE_TRACEPARENT=1`.
- **Interactive Claude Code, which is what herdr panes run, ignores an inbound `TRACEPARENT`.**
  Its spans form their own trace per prompt; a resource attribute is the only link.
- Claude Code telemetry is off on this machine: `config/settings.template.json` sets
  `CLAUDE_CODE_ENABLE_TELEMETRY=0`, and the settings `env` block beats the process environment.
- research-gateway reads no `traceparent` (30-line patch joins it); OpenCode reads it on every HTTP
  request but its run spans hang off the server's boot trace; agw and warden emit nothing.
- Volume: ≈ 47.6k spans and ≈ 38k log records per day from the mini's sessions, ≈ 6 MB/day on disk.

## Decision outcome

1. **Trace id derived from the root entity:** `sha256("<noun>:" + id)[:32]` (`warden-item:` during
   migration), so any component that knows the id computes the trace without a carrier.
2. **Carrier A — W3C `traceparent`** wherever it works: headless workers (env + propagate flag),
   OpenCode and every gateway (HTTP header), HTTP MCP `tools/call`.
3. **Carrier B — `warden.item.id` (then `factory.root`) as a resource attribute** on everything that
   cannot carry a context: herdr panes (exported by `rd` into the pane env), OpenCode run spans,
   Hermes, crons. Argo and `/otel` join on it at query time; `session.id` links spans to transcripts
   and usage rows, so cost per item is a join.
4. **One always-on ClickHouse:** the VPS ClickStack through its authenticated OTLP tier; the local
   stack stays an on-demand dev target. Hand-rolled stdlib/TS emitters, no SDKs.
5. Order (migration W9): agw's Claude env block and warden's header → research-gateway patch, then
   email and audio → OpenCode env + header → `rd` pane env (attribute only) → Hermes plugin.
6. Remove the settings `"0"` (or override per spawn) — today it silently disables all Claude Code telemetry.

### Consequences

- Good: "what did item X cost and touch" becomes one query; per-item traces need no closing event.
- Bad: interactive workers never nest under the item span (accepted: join by attribute); OpenCode's internal spans need collector-side filtering; prompt and tool content stays off (`OTEL_LOG_*` defaults).

### Confirmation

A gameday item traced from signal to gateway call in one query; a CI check that every spawn path
sets the resource attribute; the `/otel` preset fixes noted in the spike (status-code and column
names) land with W9.
