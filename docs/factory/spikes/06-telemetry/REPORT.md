# Spike 6: one trace from a warden item through a Claude Code worker to a gateway call

- Status: proposed (spike result; the Decision section is the draft for `adr/`)
- Date: 2026-10-22
- Question (BRIEF Phase 4.6): can one trace run from a warden item through a herdr-style Claude Code worker to a gateway call, landing in one ClickHouse, and what does each component emit today?
- Time box: 2 h, about 1 h 40 used. Everything was measured on the mini against the local ClickStack. Nothing was committed; no service, env file, launchd job or code was changed (a scratch copy of research-gateway carries the one patch).

## Answer

**Yes for headless workers, with three preconditions and one hard limit.** A stdlib-Python `warden.item` root span, a headless `claude_iu -p` worker and a gateway that reads `traceparent` joined into one 25-span trace (headline trace `c1800a6ba3c5467f27450aab536071b5`: three services, 40 log records correlated by the same trace id, rendered as one waterfall by HyperDX). It took:

1. Telemetry actually on. `~/.claude/settings.json` sets `CLAUDE_CODE_ENABLE_TELEMETRY=0` in its `env` block and that **beats the process environment** (0 spans without `--settings`).
2. `CLAUDE_CODE_PROPAGATE_TRACEPARENT=1`, because `claude_iu` runs on a custom `ANTHROPIC_BASE_URL`. Without it the Bash subprocess just inherits the spawner's `TRACEPARENT` (flat, mis-parented) and HTTP MCP calls carry none.
3. A gateway that reads `traceparent`. **The real research-gateway does not** and has no per-request span: its only span root is one `research.job` per job, with the trace id derived from the job id. A 30-line patch (scratch copy, `patches/`) joins it.

Hard limit: **interactive Claude Code, which is what herdr and `rd wave` run, ignores an inbound `TRACEPARENT`.** Its spans form their own trace per prompt. The only link to the warden item is a resource attribute (`warden.item.id` via `OTEL_RESOURCE_ATTRIBUTES`), which did land on spans, logs and metrics. So "warden item, through a herdr worker, to a gateway" is one trace only for headless workers; for herdr panes it is one item-level view.

## Setup

- Collector: local ClickStack (`make -C ~/SourceRoot/vps clickstack-up`, ClickHouse 26.8.25, on demand, stopped again afterwards). OTLP/HTTP on the unauthenticated receiver `localhost:4319`, ClickHouse HTTP `localhost:8123`, HyperDX `localhost:7707` (the `/otel` skill's `query.py` and `hdx.py`).
- Worker: Claude Code 2.1.308 via `claude_iu -p --model haiku` (IU endpoint, no Max quota; about 0.004 USD per probe session, under 0.1 USD for the whole spike). Env names verified against the official monitoring docs and the installed binary (`CLAUDE_CODE_ENHANCED_TELEMETRY_BETA`, `CLAUDE_CODE_PROPAGATE_TRACEPARENT`, `OTEL_TRACES_EXPORTER`, `CLAUDE_CODE_OTEL_FLUSH_TIMEOUT_MS` all present).
- Gateways: the real research-gateway code (commit be76f30) as a throwaway process on its own port with a scratch job DB, dummy credentials and an unreachable LLM endpoint (jobs fail fast and cost nothing); plus `gateway_stub.py`, a positive control that reads `traceparent` and speaks minimal MCP over HTTP so the headers it receives can be logged.
- Root span: `scripts/warden_item.py`, stdlib only. Trace id = `sha256("warden-item:" + item id)[:32]` (recomputable by anyone who knows the item id), random span id, exported when the worker exits.
- Variants: A naive (`-p`, inherited `TRACEPARENT`); B = A plus `CLAUDE_CODE_PROPAGATE_TRACEPARENT=1`; S = agent-gateway's exact flag vector (`--setting-sources project --settings {"disableAllHooks":true}`); I = interactive `claude` in a pty (the herdr shape).

## What joined

Headline trace B (`evidence/B.trace.md`), condensed:

```text
warden-spike / warden.item                                  root, 33.9 s
  claude-code / claude_code.interaction                     parent = warden.item (parent.source=env)
    claude_code.llm_request x6, claude_code.tool x5 (Bash x3, ToolSearch, MCP call)
      each tool: tool.blocked_on_user + tool.execution
      tool.execution (Bash curl)  -> gateway-stub-spike / GET /health       parent = this tool.execution
      tool.execution (MCP ping)   -> gateway-stub-spike / mcp tools/call    parent = this tool.execution
```

Per variant:

|check|A naive `-p`|B `-p` + propagate|S agw lane|I interactive|
|-|-|-|-|-|
|`warden.item` to `claude_code.interaction`|joined|joined|joined|**not joined** (`parent.source=none`, own trace)|
|llm / tool / execution spans|22, same trace|22|22|23, own trace|
|`TRACEPARENT` in the worker's Bash|the warden root span itself (inherited)|the live `tool.execution` span|same as B|live `tool.execution` of its own trace|
|Bash `curl` to a gateway|joins, but under the root (skips the tool span)|joins under `tool.execution`|same as B|joins the worker's own trace|
|HTTP MCP `tools/call`|no `traceparent`, orphan trace|`traceparent` = that call's `tool.execution`|same as B|same as B|
|MCP connect-time calls (`server/discover`, `initialize`, `tools/list`)|never|never|never|never|
|log records carrying the trace id|40 (warden trace)|40|24 (hooks off)|0 for the warden trace, 38 for the worker's own|
|`warden.item.id` on spans / logs / metric points|22 / 40 / 32|22 / 40 / 32|22 / 24 / 32|24 / 43 / 44 (both traces)|

Evidence: `evidence/{A,B,S,I,I-claude,Bjson}.trace.md|json`, `bash-traceparent.md` (the span id Bash saw, looked up in ClickHouse), `{A,B,S,I}.stub-requests.jsonl` (the headers the receiver got), `B.hyperdx-waterfall.json`.

## What broke, and why

|#|break|cause|measured|fix|
|-|-|-|-|-|
|1|No Claude Code telemetry at all|`config/settings.template.json:3` puts `CLAUDE_CODE_ENABLE_TELEMETRY="0"` in the settings `env` block; settings env wins over the process env|`evidence/settings-probe.out.txt`: env only 0 spans, `--settings {"env":{...=1}}` 2 spans, `--setting-sources project` 2 spans|per-spawn `--settings` override, or drop the `"0"`; agent-gateway's lane (`--setting-sources project`) never loads user settings, so env alone works there|
|2|Bash and MCP lose the call context|`ANTHROPIC_BASE_URL` is not first-party, so Claude Code withholds `traceparent` and the Bash injection unless `CLAUDE_CODE_PROPAGATE_TRACEPARENT=1`|A vs B above; the binary has the same gate on model requests|set the flag on every IU-backed worker (`claude_iu`, `ca`, agw's `iu` backend)|
|3|Interactive workers do not join|only `-p` and Agent SDK sessions read inbound `TRACEPARENT`; interactive sessions ignore it by design|I: the warden trace holds 1 span, the worker's own trace 23|join by the `warden.item.id` resource attribute (lands on all three signals)|
|4|The gateway span is in another trace|research-gateway reads no `traceparent`; spans exist only per job (`research.job` plus rounds and workers), trace id = job id; no HTTP request span, so `/health` and `job_status` produce nothing|A/B/S: `research.job` landed in job-id-derived traces. The patched copy joined: `research.job` parent = the supplied span, plus a `research.job_id` attribute (`evidence/research-gateway-patched.out.txt`)|`patches/research-gateway-traceparent.patch` (+30/-7 lines, typechecks); persist the context with the job so a restart-adopted job keeps its parent|
|5|MCP startup traffic is untraced|`server/discover`, `initialize` and `tools/list` happen before any interaction span exists|stub logs, all variants|inherent; only `tools/call` carries context. stdio MCP (agent-gateway) gets no per-call context, see the agw row|
|6|OpenCode run spans are not under the request|the session fiber is forked from the server's boot context|`evidence/opencode-probe.out.txt`: 8 `http.server` spans joined the supplied trace; the LLM `http.client POST` and runner spans sit in the server-process trace (601 spans, root `ServerProcess.start`)|join through the session id header attributes on the LLM span (`x-opencode-session`); do not expect request-level nesting|

Not breaks (checked): the exporter (`http/protobuf` and `http/json` produced identical traces, `evidence/Bjson.trace.md`); short runs losing data (a 6 s single-turn run at the default 5 s and 60 s intervals delivered 2 spans, 7 log records and 7 metric points, so Claude Code flushes on exit, `evidence/flush-probe.out.txt`); the IU endpoint rejecting `traceparent` (6 turns fine; it returns its own `traceresponse`, recorded as a span link on every `llm_request`, and does not adopt our trace id).

## Per-component inventory and minimal change

|component|emits today|propagates today|minimal change to join|
|-|-|-|-|
|Claude Code 2.1.308|spans (beta; interaction, llm_request, tool, tool.blocked_on_user, tool.execution; includes `gen_ai.operation.name`, `gen_ai.tool.name`, `gen_ai.conversation.id`, `session.id`, `tool_use_id`), 11 log event kinds (about 40 per session), 4 metrics|reads `TRACEPARENT` only in `-p`/SDK; injects it into Bash and `traceparent` into HTTP MCP and model requests only on a first-party base URL or with the propagate flag; stdio MCP servers inherit the spawn-time root `TRACEPARENT` and get `_meta["claudecode/toolUseId"]` per call (equals the tool span's `tool_use_id`)|spawn env `CLAUDE_CODE_ENABLE_TELEMETRY=1 CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1 OTEL_TRACES_EXPORTER=otlp OTEL_LOGS_EXPORTER=otlp OTEL_EXPORTER_OTLP_PROTOCOL OTEL_EXPORTER_OTLP_ENDPOINT CLAUDE_CODE_PROPAGATE_TRACEPARENT=1 TRACEPARENT OTEL_RESOURCE_ATTRIBUTES=warden.item.id=<id>`, plus `--settings` unless the lane skips user settings; `~/SourceRoot/dotfiles/config/settings.template.json:3`|
|OpenCode 2.0.32 (agw server)|OTLP traces and logs when `OTEL_EXPORTER_OTLP_ENDPOINT` is set: `http.server`, many internal Effect spans (601 in the server-process trace for one boot plus one prompt), `http.client` for the LLM call; no metrics; `service.name` fixed to `opencode` (`OTEL_SERVICE_NAME` ignored); Authorization header recorded as `<redacted>`|**reads inbound `traceparent` on every HTTP request** (verified, including a 401)|add the OTLP endpoint (and headers for the authed tier) to the server env list, `~/SourceRoot/agent-gateway/scripts/opencode-server-env.ts:54` (the wrapper's `env -i` forwards only that list); send `traceparent` in the fetch headers at `~/SourceRoot/agent-gateway/server/mcp/opencode-client.ts:200`|
|agent-gateway|nothing (0 OTel or traceparent references)|nothing; the env scrubber (`server/mcp/worker-shared.ts:12`) does not match trace or OTel names, so they survive|read `traceparent` on `POST /api/jobs` (`server/routes/jobs.ts:38`) and keep it in the `params` JSON (no schema change, `server/jobs/store.ts:112`); add the Claude env block above where the worker env is built (`server/mcp/session-runner.ts:410`, after `workerBaseEnv`); forward the header in `opencode-client.ts`; stdio MCP server (`server/mcp.ts`): read `TRACEPARENT` from its own env once and `_meta["claudecode/toolUseId"]` per call, store both on the job|
|warden|nothing|nothing|one egress to agw: add `traceparent` to the headers at `~/SourceRoot/warden/scripts/clients/agent_gateway.py:107`; emit `warden.item` / per-transition spans with the 100-line stdlib emitter proven here (`scripts/otlp.py`), trace id derived from the item id, hooked where items open (`scripts/ledger.py`)|
|Hermes v0.22.2 (`~/.hermes/hermes-agent`)|nothing (`~/SourceRoot/hermes-agent/AGENTS.md:554`)|nothing|one plugin in `~/SourceRoot/hermes-agent/plugins/` registering `pre_tool_call`, `post_tool_call` and `pre_api_request` (`hermes_cli/plugins.py:109-145`), enabled once with `hermes plugins enable`; trace id from the item id the tool call names. Hook API read, plugin not run|
|herdr 0.9.3 / `rd`|no OTel (0 `OTEL` or `traceparent` strings in the binary); events recorded to `~/.local/share/herdr-events/*.jsonl`|pane env `HERDR_*` only|herdr itself needs nothing. In `agent_pane_setup` (`~/SourceRoot/dotfiles/scripts/remote-dev.sh:304`) export `OTEL_RESOURCE_ATTRIBUTES=warden.item.id=<id>` and the OTLP env into the pane shell, and add `--settings` to the start commands (`remote-dev.sh:607`, `:709`). `TRACEPARENT` is useless here (interactive)|
|research-gateway|hand-rolled OTLP traces and logs, per job only (`src/lib/otel.ts`, root at `src/agent/run.ts:151`)|none|`patches/research-gateway-traceparent.patch`: parse in `src/routes/research.ts` and `src/routes/mcp.ts:148`, `withRootSpan({traceId, parentSpanId})`, attribute `research.job_id`|
|email-gateway|per-request server span (`src/telemetry/http.ts`, `.onRequest`)|none|about 6 lines: parse `traceparent` there and pass the ids into `startSpan` (`src/telemetry/otel.ts:303`)|
|audio-gateway|root span per request or job (`src/speech.ts:50`, `src/podcasts.ts:552`)|none|about 6 lines in the `withRootSpan` callers (`src/otel.ts`)|
|image-gateway, usage-tracker|nothing|nothing|outside the first join; `session.id` links Claude spans to usage rows later|

Cross-cutting: `claude_code.*` spans and `OTEL_RESOURCE_ATTRIBUTES` both carry `session.id`, which is also the transcript and usage-tracker key, so cost per warden item is a join, not new instrumentation.

## Cost and volume

Span shape, validated (the transcript counters reproduce probe B's 22 Claude Code spans exactly): `spans = interactions + llm_requests + 3 x tool_calls`. Counted over the last 7 days of mini transcripts, subagent files included (`scripts/session_volume.py`; MacBook not included):

|measure|value|
|-|-|
|sessions with model calls|868 (82.5 active per full day)|
|spans, 7 days|346,101|
|spans per session|median 134, mean 399, p90 1,030, p99 4,155, max 7,266|
|spans per day|mean 47.6k, range 6.5k to 92.8k|
|log records per day|about 38k, estimated (one per model request, two per tool call, about 22 per session of startup and hook events)|
|raw size|about 1.45 KB per span, 1.35 KB per log row, so about 120 MB per day raw|
|on disk (ClickHouse, measured at 850 spans)|about 51 B per span, 89 B per log row, so roughly 6 MB per day or 2 GB per year; pessimistic at this table size|

The naive product (22 spans per probe times 128 transcripts per day by file count) gives about 2.8k spans per day and is 17 times too low: real sessions are long. OpenCode adds hundreds of spans per server start and an unmeasured number per multi-step prompt, mostly internal Effect spans worth dropping at the collector. Content stays off by default (`OTEL_LOG_USER_PROMPTS`, `OTEL_LOG_TOOL_CONTENT`, `OTEL_LOG_RAW_API_BODIES`); the spike set `OTEL_LOG_TOOL_DETAILS=1` locally, which records full Bash commands and must stay off for the prod export.

## Decision

**Adopt one trace per warden item, joined by two keys that are always both set.**

1. Trace id = `sha256("warden-item:" + item id)[:32]`, computed by any component that knows the item id. Warden emits one span per transition or episode under that trace, not a root spanning days of waiting.
2. Carrier A, W3C `traceparent`, wherever the carrier works: headless `claude -p` workers (agw claude lane, warden dispatch) via `TRACEPARENT` env plus the propagate flag; OpenCode and gateways via the HTTP header; HTTP MCP `tools/call` comes free with the flag.
3. Carrier B, `warden.item.id` as `OTEL_RESOURCE_ATTRIBUTES` and span attribute, for everything that cannot carry a context: interactive herdr workers, OpenCode run spans, Hermes, cron. Join at query time on `ResourceAttributes['warden.item.id']`; secondary keys `session.id`, `tool_use_id`, `x-opencode-session`.
4. One always-on ClickHouse: the prod ClickStack through its authed public OTLP tier (the path research- and audio-gateway use today); the local ClickStack stays an on-demand dev target. Keep the hand-rolled OTLP emitters (no SDK) in Python and TS.
5. Order of work (Round 5 W9): (a) agw Claude-lane env block and the warden header; (b) research-gateway patch, then email and audio; (c) OpenCode env plus header; (d) `rd wave` pane env (attribute only); (e) Hermes plugin last.
6. Consequences: workers export to the VPS, so the ingestion key must reach spawned processes under a name the agw scrubber keeps (`OTEL_EXPORTER_OTLP_HEADERS` does); the settings `"0"` becomes a documented gotcha; OpenCode needs collector-side filtering if volume matters; a derived trace id makes late attachment cheap but a trace never "closes", so use queries rather than trace-complete events.

## Confidence

- High: Claude Code join behaviour in all four variants (repeated twice with identical shape; docs and binary agree); research-gateway ignores `traceparent` (code, runtime and patched copy); OpenCode joins on HTTP; the volume formula.
- Medium: agw and warden changes (code read and pointers checked, not patched); `rd wave` env injection (interactive behaviour measured in a pty, not through herdr); the per-day volume (one validated trace shape, MacBook excluded, compressed bytes from a small table).
- Low or not run: the Hermes plugin; the prod authed path from the mini; subagent nesting (docs only); OpenCode multi-step sessions; `OTEL_RESOURCE_ATTRIBUTES` on OpenCode; resumed (`--resume`) herdr sessions.

Other findings to route: the research note's claim that `gen_ai.operation.name` and `gen_ai.tool.name` are undocumented no longer holds, 2.1.308 emits them. In the `/otel` skill's `scripts/query.py`, the `errors` and `services` presets filter `StatusCode = 'STATUS_CODE_ERROR'` while this ClickStack stores `Error`, and the log presets use a `TimestampTime` column this local `otel_logs` lacks (not touched). A nested `claude -p` inside a herdr pane inherits `HERDR_*` and its SessionStart hook reports to herdr; the scripts strip those variables (the parent pane's record was checked and intact).

## Reproduce

Headline trace id `c1800a6ba3c5467f27450aab536071b5`, item `spike6-B-20261022T083009Z`. Other trace ids: A `f3103cadb4ece1641f760aa120cfe54c`, S `7f4e9781fdafc4c442bff97925fc26b7`, B over JSON `63012172c159a644d0d48ee738db013b`, I warden `c3d2bfa8b7d476e3f68dde881b8acd99` and worker `05d468195deee87ca69bbb3e14698410`.

```sql
SELECT toString(Timestamp) AS ts, ServiceName, SpanName, SpanKind, SpanId, ParentSpanId,
       round(Duration / 1e6, 1) AS ms, StatusCode
FROM default.otel_traces
WHERE TraceId = 'c1800a6ba3c5467f27450aab536071b5'
ORDER BY Timestamp, SpanId
```

Run it with `python3 -I ~/.claude/skills/otel/scripts/query.py --env local "<sql>"` (ClickStack up). The item-level join, logs and metrics queries are at the end of every `evidence/*.trace.md`.

```text
make -C ~/SourceRoot/vps clickstack-up
scripts/services.sh start            # stub :17790, real research-gateway :17780 (scratch)
scripts/run_spike.sh B               # A | B | S | I ; optional 2nd arg http/json
python3 -I scripts/query_trace.py --trace-id <id> --item-id <item> --label B --out evidence --run-dir <run dir>
scripts/services.sh stop
```

Scripts: `otlp.py`, `warden_item.py`, `gateway_stub.py`, `stdio_stub.py`, `services.sh`, `run_spike.sh`, `interactive_probe.py`, `query_trace.py`, `bash_traceparent.py`, `settings_probe.sh`, `flush_probe.sh`, `stdio_probe.sh`, `opencode_probe.sh`, `session_volume.py`. Raw run directories stay in `~/.local/share/factory/spikes/06-telemetry/` (not in git).

Side effects: the local ClickStack image was pulled and the container started, then stopped; about 20 headless sessions and one interactive session ran on the IU endpoint, leaving transcripts under `~/.claude/projects/` slugs for the scratch directory, and usage-tracker rows.
