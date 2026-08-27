---
name: otel
description: >
  Query and debug observability data — traces, logs, metrics, dashboards, alerts —
  in ClickStack/HyperDX (local dev + VPS prod). Use for OpenTelemetry questions,
  "why is X slow/failing/erroring in prod", service health checks, dashboard or
  alert authoring, or any ClickHouse query against OTel data.
---

# OTEL / ClickStack / HyperDX

Four ways in, cheapest-appropriate first.

## Routes

| Need | Route |
|-|-|
| Quick triage, off-thread verdict | `mcp__sideclaw__otel` — read-only Sonnet worker, returns `{status, environment, timeRange, findings, recommendations}` only |
| Interactive investigation, dashboards, alerts | `mcp__hyperdx-local__clickstack_*` / `mcp__hyperdx-prod__clickstack_*` — the builder tools, discovery flow below |
| Scripted, no MCP client (cron, subagent) | `scripts/hdx.py <env> {tools,call,prompt,rest,link}` |
| Raw SQL fallback, or HyperDX API down | `scripts/query.py --env <env> --preset ...` |

**(a) `mcp__sideclaw__otel`** — call with `investigation` (error/service/trace
id/anomaly/time range) and `environment` (`local`/`prod`). Runs read-only on
claude-sonnet-5[1m] (Max, `SIDECLAW_WORKER_BACKEND=max`; IU fallback otherwise —
non-EU routing, treat prod log content accordingly) via `scripts/query.py`. Only
the structured result crosses back — raw output stays in the worker. Query can
take 1–6 min under load; the tool's 8-min timeout absorbs most of it, retry on a
hard timeout.

**(b) `mcp__hyperdx-{local,prod}__clickstack_*`** — the built-in ClickStack MCP
(28 tools local / 30 prod, prefixed `clickstack_`). Server-side tool-selection
policy, mirrored here: prefer the **builder tools** (`table`, `timeseries`,
`search`, `event_patterns`, `event_deltas`, `emerging_signals`,
`trace_waterfall`, `trace_top_time_consuming_operations`) — `clickstack_sql` is
last resort (JOINs, CTEs, window functions, unregistered tables). Discovery flow
before any query: `list_sources` → `describe_source` → build the query. Fetch
prompts at authoring time instead of restating them here: `create_dashboard`,
`dashboard_examples`, `query_guide`.

**(c) `scripts/hdx.py`** — stdlib Python, same MCP + REST v2 surface, for
callers without an MCP client. `hdx.py <env> tools`, `call <tool> '<json>'`,
`prompt <name>`, `rest <METHOD> <path> ['<json>']`, `link <dashboard-id> [--last
24h|7d]`. `<env>` is `local` or `prod`.

**(d) `scripts/query.py`** — direct ClickHouse SQL (HTTP or docker exec/ssh),
unchanged. Use when the HyperDX API itself is down, or for ad-hoc SQL the
builder tools can't express. Canonical access path for the sideclaw `otel`
worker too — add presets/schema changes here, not in sideclaw.

## Environment selection

`local` = the dev ClickStack container (`http://localhost:7707`, credentials in
`~/.config/hyperdx/local.env`, written by `make hyperdx-dev-bootstrap` in vps).
`prod` = `https://hyperdx.jkrumm.com` (credentials via `op://vps/clickstack/*`,
`make hyperdx-agent-setup` in vps) — **tailnet-only**, reachable from both Macs,
**not from cloud routines**. Author against local first when the service under
investigation ships a dev stack there; go straight to prod otherwise, and say so.

## Dashboard authoring loop

1. Fetch the `create_dashboard` and `dashboard_examples` prompts, and
   `describe_source` for every source the dashboard touches.
2. `save_dashboard` — dev first when the service has a local stack, else prod.
3. `query_tiles` (or `query_tile` per tile) — every tile must return data or be
   justified (e.g. a rare-event counter that's legitimately zero right now).
4. Screenshot via `/browse`: log in at `<base>/login` with the env's
   email/password (`take_snapshot` to find the form fields — never paste the
   password into chat), navigate to the kiosk link from `hdx.py <env> link
   <id>`, `take_screenshot` with `fullPage: true` at 1440 px width, saved under
   `/tmp/hdx/<slug>.png` — never inside a repo (a `git add -A` sweeps it up).
5. Critique the screenshot + tile list against `reference/dashboard-review.md`.
6. `patch_dashboard` for anything that failed the checklist, repeat 3–5 until it
   passes.
7. `make -C ~/SourceRoot/vps hyperdx-export ENV=<env>` and commit the JSON under
   `vps/observability/dashboards/` — dashboards live in Mongo, which is not
   backed up; the repo is the backup.

## Alerts

`get_webhook` (check for an existing Slack destination) → `save_webhook` if
missing (`op://common/slack/WEBHOOK_ALERTS`, never print the URL) →
`save_alert` targeting a tile or a saved search. State the threshold in the
alert name or description, and link to how to silence it (delete/disable via
`save_alert` with the same id, or `clickstack_get_alert` to find it first).

## Gotchas

- `clickstack_sql` is last resort — the builder tools cover almost everything
  and don't require knowing the schema.
- Logs partition on `TimestampTime`, not `Timestamp` — filter on it for
  partition pruning (see `query.py` presets for the pattern).
- Trace `Duration` is nanoseconds — divide by `1e6` for ms.
- Map-typed attributes (`SpanAttributes`, `LogAttributes`) need
  `mapValue['key']` / `ILIKE` syntax, not dot access — `query_guide` has the
  full reference.
- Tool list differs by version: local runs 2.33.0-beta (28 tools, no
  `query_tiles`/`emerging_signals`), prod runs 2.36.0-beta (30 tools). Don't
  assume parity — `hdx.py <env> tools` to check before scripting against one.
- The MCP is **stateless** — no session, no `initialize` handshake required
  before `tools/list` or `tools/call`. Every POST is independent.

## Schema facts (prod, verified 2026-08-27)

- Error predicate on request spans: `SpanKind='Server' AND StatusCode='Error'`
  — every service marks 5xx as Error and leaves 4xx `Unset`. Traefik **Client**
  spans mark 404/401 as Error and include socket-proxy `GET /_ping` — never use
  them for error rate.
- Edge view = Traefik Server spans. Host is `SpanAttributes['server.address']`
  (`http.request.header.host` is empty); `url.scheme` is `https`/`wss` — exclude
  `wss` from latency (long-lived upgrades) and `server.address='otel.<domain>'`
  (browser-SDK ingest, ~60 % of edge volume).
- Status-code attribute per service: argo-api, fpp-server, traefik →
  `http.response.status_code` (+ `http.route`, `http.request.method`); imgproxy,
  fpp-analytics, audio-gateway → legacy `http.status_code` (+ `http.method`).
- Browser SDKs (`free-planning-poker`, `argo-dashboard`) have no Server spans;
  `otelcol*` ships metrics only — `SpanKind='Server' AND ServiceName!='traefik'`
  is the clean app-service set.
- `SeverityNumber`: info 9, warn 13, error 17, fatal 21. `clickstack_search`
  ignores a custom `select`. Never alias a column `all` (`ORDER BY ALL` clash).
- Builder group-by on a Map key renders the header as `arrayElement(...)` with no
  alias — a table meant for row-click drilldown on a Map attribute is the one
  legitimate `clickstack_sql` tile.
- `clickstack_patch_dashboard` shape: `{dashboardId, tileId, tile:{name, config}}`.
  Rate tiles are counts per bucket (no window-normalised req/s in the builder).
  HyperDX opens dashboards at 15 min — hand out `hdx.py <env> link <id> --last 24h`.
- argo-api (new semconv): Postgres client spans are `db.system='postgresql'` +
  SpanName `drizzle.*`; HTTP clients carry `server.address`. Elysia's internal
  `Request`/`Transform`/`Handle` spans are 1:1 with requests — never count them.
- Browser SDKs (old semconv): `http.status_code='0'` = aborted fetch (noise).
  `unhandledrejection`/`TypeError`/`eventListener.error` are `StatusCode='Error'`,
  `console.error` is `Unset`. Page loads: `documentLoad` spans + `location.href`.
- fpp-server: the `Root` server span is an unrouted 404 (scanners); real work is
  `GET /ws` + Internal `ws.*` spans (`room.id`, `user.id`, `action.type`). Its
  logs have an **empty Body** — everything lives in `LogAttributes['event.name']`.
- `seriesLimit` on line/stacked_bar ranks by the plotted value, not by volume —
  "p95 of the 8 busiest routes" needs a `clickstack_sql` tile.
- `hdx.py` key fetch over ssh eats stdin inside shell loops — add `</dev/null`.
- **Durations**: `numberFormat: {output: "duration", factor: 0.000000001}` on
  every `Duration` select (auto "341ms" / "5.7s"). `output: "number"` with a
  1e-6 factor is NOT scaled by the UI — tiles render raw nanoseconds while
  `query_tile` looks fine, so only a screenshot catches it. Drop "(ms)" from
  titles that use it.
- `bar`/`pie` builder tiles take exactly one select (one series); use a table
  or a `clickstack_sql` tile for p50+p95 side by side.
- `clickstack_query_tile(s)` take top-level `startTime`/`endTime` (ISO); a
  `timeRange` object is silently ignored and you get the 15-minute default.
- `hyperdx-sync.sh` needs `HYPERDX_PROD_BASE_URL` on the mini until
  `op://vps/config/DOMAIN` is seeded; `make hyperdx-export ENV=prod` fails
  otherwise — and `… | tail` hides that exit code, so don't chain a commit on it.
