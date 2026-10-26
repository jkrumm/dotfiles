# agent-gateway as the platform: stations, capabilities, one CLI

**TLDR.** agent-gateway becomes the one platform the factory uses from above and Claude Code from below. Hermes and Argo call it too. It has four parts in one repo, with one dependency tree and shared routing, usage and telemetry (§2):

| Part | What it is | Proven by |
|-|-|-|
| **Capabilities** | typed functions (summarize, decide, adapters…) defined once, exposed as import + HTTP + CLI | spike 7 `capability/` |
| **Stations** | specialized cheap-model agents: own AGENTS.md, skills, route, output schema, eval set; sessions on ONE OpenCode server | spike 7 `station-host/`, locations spike |
| **Engines** | research-, audio-, image-, email-gateway: fixed pipelines, invariants in code, separate processes | production |
| **`agw` CLI** | one binary, commands generated from every service's OpenAPI document, ADR-004 contract | spike 7 `cli-runner/` |

No MCP (D2). Stations run in yolo mode by default (D4).

```
callers     factory (above) · Claude Code (below) · Hermes · Argo · cron
              ↓  agw … (CLI)  or  HTTP/SDK (apps)
agw CLI     one binary — commands from OpenAPI, pending/resume, typed errors
              ↓
stations    brain · research · otel · review · check · analyst · podcast-producer · news …
              ↓  sessions on ONE OpenCode server (one location dir per station)
capabilities  llm.summarize · llm.title · decide · modelpick · vps-postgres · usage …  (import + HTTP + CLI)
engines     research-gateway · audio-gateway · image-gateway · email-gateway
shared      route table (model + effort per route) · usage → usage-tracker · OTel → ClickStack
```

> **Status: concept v2, 2026-10-26.** Not yet folded into the factory TDD (v2.4). v1 (same day, commit 5bb920b) was the proposal. v2 adds your decisions from that conversation and the results of spike 7 (`../spikes/07-stations/`).
> **Read §10–§11 now:** they cover what this changes in the factory docs and where the factory stands. W1a starts on your sign-off of v2.4.
> **Evidence:** `../research/2026-10-26-{opencode-capability-map,opencode-v2-locations-spike,agent-first-cli,agent-platforms-compared,mastra-deep-dive}.md`, agent-gateway `docs/opencode-v2.md`, brain `wiki/engineering/{agent-loops-vs-runtimes,opencode}.md`, prometheus-scripts' `epx` and Athena Teamchat.

## 1. Decisions (owner, 2026-10-26)

| # | Decision | Note |
|-|-|-|
| D1 | **One unified agent-gateway and one `agw` CLI** | the factory CLI mounts as `agw factory …` once its OpenAPI exists |
| D2 | **All-in CLI, no MCP.** Claude Code and Hermes are the only clients | research-gateway's `/mcp` and agw's MCP server are deleted when the skills switch. chrome-devtools stays until a browser CLI exists |
| D3 | **Stations may draft** review findings and otel explanations on cheap models | otel is mostly reading data |
| D4 | **Yolo by default.** Allow everything, never `ask`, no sandbox | `profile: focused` stays opt-in, as a quality lever, not a safety one |
| D5 | **Budgets, steps and wall time are report-only.** They are recorded and flagged, never enforced | only an explicit `cancel` stops a run |
| D6 | **Stations run code.** Calculations, diagrams and rendered artifacts are normal work | artifacts come back as `[{path, kind}]` |
| D7 | **Capability layer in-house**, not Mastra | bake-off, §5 |
| D8 | **Research engine vs OpenCode research is open** | settled by the three-way comparison, §9 |
| — | **Name: "station"** (working). "desk" was rejected as unclear | open for a better word |

**Still open, not a decision:** whether `agw research run` needs `--commit` (ADR-004 item 4). Tendency: keep `--commit` only for outside side effects (send, delete, publish). Submits are retry-safe through the idempotency key.

## 2. Why one platform

Today every gateway reinvents the same five things: an LLM client, model choice, usage reporting, telemetry and a job contract. Changing the cheap model means editing research-gateway's `env.ts`, audio-gateway's `config.ts`, email-gateway's `.env.tpl`, agw's routing and Argo's `/ai/v1`. The platform makes each of them exist once:

- **One route table** in agw: route key → model **and reasoning effort**. Today effort is set per call site, because the table has no field for it (spike 7 capability gap).
- **One usage path.** The IU endpoint returns `usage.cost` on every response, so no price table is needed. Usage flows to usage-tracker under the capability or station name.
- **One telemetry path:** one span per capability call and per station session, exported to ClickStack.
- **One job contract:** submit → `pending` → resume, typed errors, idempotency keys.

**Modular monolith in the repo, separate processes at runtime.** One repo, one dependency tree, shared packages. Engines keep their own processes (LaunchAgents), deploys and drains. Why not one process:

- A deep research job runs 450–700 s and research-gateway drains for up to 1800 s. Every review/check deploy would wait on research.
- A memory spike in the research fetch chain would take down review/check.

email-gateway can stay on the VPS for availability and still consume the shared packages.

## 3. Stations

A station is a directory in the repo that owns its capability:

```
stations/brain/
  station.yaml        # name, description, route, profile (yolo|focused), budget (report-only), output schema
  AGENTS.md           # the station's context — its "CLAUDE.md"
  skills/<name>/SKILL.md
  output.schema.json  # typed result, validated by the host (one re-ask, then invalid_output)
  eval/cases.jsonl    # regression gate for prompt, skill, route or OpenCode changes
```

**How the host runs it** (spike 7, `station.ts`, 542 lines):

1. **Compile** each station into a location directory **outside any repo**. An ancestor `AGENTS.md` leaks into a location: the model quoted `dotfiles/AGENTS.md`.
2. **Warm** the location before first use. Evict it after a change (`DELETE /api/debug/location`), because agent files are not hot-reloaded.
3. **Per run:**
   - create a session with `agent`, `model` from the route and the location
   - prompt `{text}` and wait
   - read all messages: `order=asc` for the first page, then `cursor` alone
   - validate the output
   - sum cost and tokens, write the span and usage record
   - return `{output, sessionId, cost, tokens, wallMs, steps, outcome, overBudget}`
4. **`continue`, `show` and `cancel`** work on the session id, the handle every caller shares.

**What one OpenCode server isolates per location** (locations spike + station host):

| Isolated | Not isolated |
|-|-|
| AGENTS.md, agent prompt, agents, commands, skills (with `OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=true`) | in-process code. v2 doesn't load `.opencode/tools/*.ts`; plugins run inside the shared server |

So a station's code is whatever it runs in its shell: CLIs, capabilities, Bun and Python scripts, renderers. Plugins stay platform-level, owned by agw (telemetry, guards).

**Measured on DeepSeek V4.1 Flash, yolo:**

| Run | Cost | Wall time |
|-|-|-|
| brain lookup | $0.0044 | 15 s |
| follow-up | $0.0009 | 8 s |
| research via the engine | $0.0038 | 50 s |
| analyst with Python stats + SVG chart + CSV | $0.0047 | 15 s |

Three stations ran concurrently on one server. The whole spike was 70 sessions for $0.069.

**Planned stations:**
- `check` and `review`: today's agw OpenCode profiles, repackaged
- `otel`: HyperDX via the otel skill's `hdx` CLI, off Max
- `brain`
- `research`
- `analyst`: calculations, charts, diagrams
- `podcast-producer`: audio-gateway's research front half
- `news`: with a future news engine

## 4. Making cheap models strong

Each rule has a measurement behind it. Yolo changes none of them: they are about getting results, not about restricting the agent.

1. **Code owns the pipeline, the model owns the judgment.** A single research loop managed 33%. The fan-out plus a ledger in code fixed it. Review derives its verdict in code.
2. **One-call doors.** Athena needed 25–45 calls per question until composite commands made it one.
3. **Machine output by default.** `agw review` without `--json` got its own verdict wrong in 5 of 9 runs.
4. **Unknown flags fail loudly.** One swallowed flag cost 6 calls and 82k tokens.
5. **Waiting lives in the CLI.** An agent polling for itself took 6 calls and 95k tokens. A CLI that exits `pending` with the resume command takes 2 (spike 7).
6. **Typed output, validated by the host.** The re-ask fixed a broken answer in the fixture run.
7. **Small context.** A short AGENTS.md, skills loaded on demand. The baseline turn costs 5,099 input tokens.
8. **Effort and sampling live on the route.** v2 ignores agent-level `temperature`.
9. **Remote text is data,** never a follow-up command. In yolo mode this is the cheapest defence against a malicious page.
10. **Eval gates every change** to a prompt, skill, route or OpenCode version.
11. **The caller re-derives.** A station result is evidence for Claude Code, not a verdict.
12. **Narrowing is a lever to test, not a default.** §9 measures whether the focused profile improves DeepSeek's results.

## 5. Capabilities: the shared typed library

`defineCapability({ id, description, input, output, route, run })` with a registry that exposes every capability three ways from one zod definition:

- **import:** `await caps.summarize({ text })`, typed and output-validated
- **HTTP:** `POST /cap/:id`, with `GET /openapi.json` generated from the zod schemas
- **CLI:** `agw cap summarize --text …`, flags generated, ADR-004 errors and exit codes, offline `schema`

Every call records tokens and cost (from the endpoint) and one span that accepts `traceparent`.

**Bake-off, same function built twice** (spike 7 `capability/`):

| | in-house | Mastra 1.79 |
|-|-|-|
| Code / deps | 341 lines / 25 MB, 12 packages | 140 lines / 191 MB, 152 packages |
| Cold start Node / Bun | 1.5 s / 1.0 s | 2.2 s / 1.6 s |
| Cost captured | yes | tokens only; DeepSeek needs a custom pricing gateway |
| OpenAPI | 1.8 KB, typed per function | 3.2 MB, 360 paths, tool body untyped `{data:{}}` |
| CLI | generated | none. A single tool can't become a CLI, and `mastra api` needs a running server |
| Eval gate | 28 lines | needs a workflow wrapper |

**Mastra's patterns worth copying:**
- tools callable from code and from agents alike
- agents and workflows exposed as tools of other agents
- workflow steps that call agents (`.agent()`)
- scorer + gate as a CI primitive
- `outputValidation: strict | warn`

Mastra itself becomes worth adopting only for stateful agent memory, suspend/resume workflows or LLM-judge scorers. Even then, suspended runs are not resumed after a restart (`mastra-deep-dive` §3).

**First capabilities:**
- `llm.summarize`, `llm.title`, `llm.classify`: all cheap route
- `decide`: the decision model
- `modelpick.*`: catalog, prices
- `pg.vps.*`: read adapters to the VPS Postgres
- `usage.record`

Apps such as Argo, email-gateway and audio-gateway import them instead of carrying their own LLM clients.

## 6. Dynamic both ways

- **Station → fixed code.** A station decides the path at run time and calls capabilities and engines through `agw`.
- **Fixed code → station.** A pipeline (the podcast pipeline, a factory job) calls `agw station run …` as one step wherever judgment is needed.
- **Code mode, later.** A station writes one short script against the capability SDK and runs it once instead of making 15 calls. OpenCode 2 ships an `execute` tool, and Cloudflare collapsed 182 MCP tools to 2 this way. With yolo decided, it needs no sandbox decision first, only the SDK.

## 7. Self-improvement at two speeds

- **Fast: data the station writes itself.** Learned facts such as "geizhals.de lists offers in the HTML" or "this shop blocks at the TLS layer" go into a per-station learnings store, read back on the next run. Reversible and immediate.
- **Slow: code, prompts and adapters, owned by the factory.** A station run emits friction signals: thin page, blocked host, schema re-ask, `overBudget`, a follow-up the user had to ask. They feed factory intake (ADR-013) as an Issue with evidence. A lead builds the fix and the station's eval gates it. The 2026-10-26 Idealo adapter took exactly this path by hand.
- **Never in place.** A station rewriting its own prompt is how harness debt starts (`agent-platforms-compared` §9).

## 8. The `agw` CLI

One generic runner (spike 7 `cli-runner/`, 536 lines, no dependencies, Node + Bun) turns each service's served OpenAPI document plus an `x-cli` extension per operation into commands:

```
agw research run "…" [--depth deep]        # engine, pending/resume
agw station run brain "…" · agw session continue|show|cancel <id>
agw cap summarize --text …                 # capability
agw review · agw check                     # stations underneath
agw schema [cmd] · agw schema --exit-codes
```

- **Already proven:** exit codes 0–10 with an HTTP mapping, a typed error line, unknown flags → 2, offline `schema`, and a long job → `pending` → the exact resume command → `done` in 2 calls.
- **Per service:** stable operationIds and `x-cli` in the route `detail`. research-gateway already serves `/openapi/json`.
- **Still to build:** the `contract_mismatch` check (412) with spec refresh-and-retry, `jsonl` / `tsv` / `--fields` / `--out` spill, and the conformance suite.
- **Deep jobs** (450–700 s) need the per-call wait budget raised to ≥ 350 s through Claude Code's Bash timeout. Otherwise a deep job takes 5–7 calls.
- **Prior art:** none of restish, Fern or openapi-cli-generator implements pending/resume, so that part is ours.

## 9. Proofs still open

| PoC | Question | Status |
|-|-|-|
| One OpenCode, many isolated setups | does v2 isolate per location? | ✅ locations spike |
| Capability layer | in-house vs Mastra, Node + Bun | ✅ in-house |
| OpenAPI → CLI | ≤ 2 calls per long job | ✅ |
| Station host | typed output, cost, span, continue, code + artifacts, yolo | ✅ |
| **Research three-way** | engine vs pure OpenCode research vs station-on-engine, plus yolo vs focused, on research-gateway's 28 regex-checked golden questions: correctness, cost, wall time | next |
| Telemetry | station span + capability span into ClickStack and usage-tracker; does OpenCode 2's own OTel survive 2.1? | next |
| Code mode | one station run as a single script against the capability SDK vs N tool calls | later |

## 10. What this changes in the factory docs

Contradictions and amendments, applied when the TDD is next revised:

- **ADR-004**
  - *Today:* keeps MCP for research-gateway, plans per-gateway CLIs, requires `--commit` on every mutation, names Python cyclopts for warden (13-decisions chose TypeScript), and schedules the agw MCP removal in W8 where 12-plan says W6.
  - *Change:* MCP is removed entirely (D2), including research-gateway's. One `agw` binary replaces the per-gateway CLIs. The IR is each service's OpenAPI document with `x-cli`, not a per-CLI `schema --all`. The `--commit` scope is open (§1). The other contract items stand; the runner proves 3, 4, 5, 6, 8 and half of 9.
- **ADR-007**
  - *Today:* calls agw "a bounded tool server, no loop".
  - *Change:* agw hosts stations, which are loops. To the caller a station run is one tool call with typed input and output.
- **TDD 05-capacity:** add stations and capabilities to the cheap-model work list. Stations draft, they don't decide (D3). Budgets are report-only (D5), which replaces the hard caps of v1 of this page.
- **TDD 12-plan:** the `otel` side change becomes the otel station. W6 ("skills on the agw CLI, MCP removed") becomes this platform's cutover wave.
- **All TDD documents:** none has a shared capability layer yet.

## 11. Where the factory stands

**How this page and v2.4 fit together.** The factory is the layer above: Issues, leads, lifecycle. This platform is the layer below: what leads, Claude Code and Hermes call. They meet in four places:
- the otel side change (→ otel station)
- W6's CLI/MCP cutover (→ the `agw` CLI cutover)
- W5's Argo move (→ Argo imports capabilities)
- ADR-013 intake (← station friction signals)

The factory's cheap-model boundary holds as long as stations gather, compute, draft and review, and never implement or decide a root cause.

**Your reading status.** You last read v2.1; its 25 Plannotator comments are in `feedback/2026-10-25-owner-comments-raw.md`. v2.2 got a voice note from the car, v2.3 a chat reply, and both said the report itself was still unread. v2.4 (`ca94bd1`) waits for sign-off. None of v2.2–v2.4 went through the Plannotator Inbox.

**Changes since v2.1** (`2979fdb..ca94bd1`: 35 files, +3304/−558):

| Area | v2.1 | v2.4 |
|-|-|-|
| Who reasons | factory investigated, planned, fixed | **a Claude Code lead owns each Issue end to end**; the factory only sorts, words and queues |
| Layers | mothers, steward, leads | **two:** orchestrator over leads, a fresh session per event |
| Engine | DBOS on Node | **no DBOS:** a Postgres Issue state machine with an inbox and mandatory idempotency keys |
| Sessions | mixed | interactive Claude Code in herdr behind a `Runner` port; `claude -p` and the SDK rejected (≈1.8× window cost, no mid-turn steer) |
| Rollback | automatic | fix-forward |
| Dedup | decision model + investigator | one judge, shadow from W2, trusted at ≥ 0.95 precision |
| Cheap models | broad | routine work only. No investigation or planning; Max writes code |
| otel | Max | a cheap OpenCode route in W1 (owner, v2.3 reply) → the otel station here |
| Scope | SourceRoot + IuRoot | SourceRoot only; GitHub triggers only by the `factory` label or a `/factory` comment |
| Waves | W1 | W1a spine (2 d) → W1b ship and watch → W2 → W3 under a build orchestrator; W4–W6 built by the factory itself |
| Warden, Argo, Hermes | — | warden switched off in W1a and deleted in W2; Argo moves to the mini in W5; Hermes becomes the chat front in W6 |

**Next:** W1a "Spine": Postgres schema, Issue machine, `factory issue` CLI, herdr Runner, hooks, Witness. Its illustrative start is 2026-10-27. The real start is your sign-off, which isn't recorded yet.
