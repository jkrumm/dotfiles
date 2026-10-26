# Gateways, desks and one CLI

> **Status: proposal, 2026-10-26.** Not yet part of TDD v2.4. It fills the gap the TDD leaves open:
> specialized cheap-model agents that Claude Code, Hermes and Argo can call. It amends ADR-004 and
> ADR-007 (§9). Inputs: the owner's brief of 2026-10-26, agent-gateway `docs/opencode-v2.md`,
> brain `wiki/engineering/agent-loops-vs-runtimes.md`, prometheus-scripts' `epx` CLI and Athena
> Teamchat, `research/2026-10-26-opencode-capability-map.md`, `research/2026-10-26-agent-first-cli.md`.

**TLDR.** One OpenCode runtime, many desks, one CLI.

- **Engines stay engines.** research-, audio-, image- and email-gateway keep their invariants in code
  (citation ledger, writers' room, TTS). None of them gets its own agent loop or its own OpenCode.
- **A desk is a package, not a service:** a system prompt, skills, a shell allowlist of CLI commands,
  a route key, a step and cost budget, an output schema and an eval set. Each desk runs as a session
  on the OpenCode server agent-gateway already supervises. The research desk, otel desk, review
  desk and podcast producer are desks.
- **One runtime to pin, probe, upgrade, monitor and bill:** agw's server. A new desk adds a
  directory, not a process.
- **One CLI, `gw`,** generated at runtime from each gateway's OpenAPI document. Commands are never
  written by hand.
- **CLI only.** MCP leaves the estate except chrome-devtools. That also removes the blocker that
  stalled the research desk. OpenCode 2 can only configure MCP for the whole server.

```
callers   Claude Code (skills) · Hermes (allowlist) · Argo (HTTP) · cron / factory jobs
            ↓  all through
cli       gw — one binary, commands generated from OpenAPI, ADR-004 contract
            ↓  gw desk run / gw session …
desks     review · check · otel · research · podcast-producer · news   (packages, not services)
            ↓  run as sessions on
runtime   agent-gateway's OpenCode server — pinned, probed, session ledger, steer,
          re-attach, per-turn cost, OTel per session
            ↓  shell allowlist = gw commands only
engines   research-gateway · audio-gateway · image-gateway · email-gateway · HyperDX
          invariants in code, HTTP + OpenAPI, cost per job
```

## 1. Why this shape

The owner wants OpenCode for research, because research is multi-turn, steerable and
task-dependent. The wish is right about the *thread* and wrong about the *engine*:

- **One big loop failed here once.** The first research-gateway was a single agent loop: 67 prod
  jobs, 22 clean reports (33%). Plan → parallel workers → synthesis, with grounding in code, fixed it.
  Moving the fan-out into an OpenCode session moves the loop somewhere with less control. The
  ledger would have to be rebuilt as an OpenCode plugin, on a plugin API that changed completely
  between 1.x and 2.x.
- **The thread belongs above the engine.** Follow-ups, "dig deeper on section 3", the brain via the
  Obsidian CLI, asking the human: these are what a session is good at. A research desk holds the
  thread and calls the engine as one tool.
- **agw already paid OpenCode's operating cost:** the version pin after a `brew upgrade` broke
  every dispatch, the idle watchdog, re-attach after a restart, the env sanitising, and the
  self-access deny list. A second driver anywhere else pays it again. That is the case for one
  runtime.
- **Athena proves the desk shape works on cheap models.** OpenCode 2.0.32 on DeepSeek V4.1 Flash,
  read-only, skills baked in, `epx` as the only data door, credentials held by a broker outside the
  agent, a $0.25 per-take budget. The pattern is already proven for IU work.

## 2. The runtime: one OpenCode per trust domain

agent-gateway's server (`com.jkrumm.agent-gateway-opencode`) becomes *the* runtime for every personal
desk. It already has what a desk needs:

| Need | Already in agw (`docs/opencode-v2.md`) | Add |
|-|-|-|
| Pinned version, upgrade gate | `OPENCODE_PINNED_VERSION`, `scripts/opencode-v2-probe.ts` (60 checks) | each desk's eval smoke in the gate |
| Durable handle | `session_id` on the job row, `job_sessions` ledger, re-attach by state | desk name + caller id on the row |
| Steer, cancel | `delivery: "steer"`, interrupt | `gw session steer|cancel` |
| Per-turn usage | `tokens` + `cost` on every assistant message, settled rollup | per-desk rollup into usage-tracker (blind since 10-14, factory Phase 0 fix) |
| Permissions | v2 rule arrays, last match wins, `deny` removes the tool | per-desk shell allowlist generated from the desk package |
| Env and secrets | session `PUT /environment`; server env never reaches the shell | desk-scoped gateway tokens only |
| Telemetry | NDJSON logs only | one span per session + per turn, `traceparent` passed to OpenCode (spike 6: it honours it) |

**One per trust domain, not one per machine.** Athena keeps its own OpenCode in its Colima sandbox:
different account (`careerpartner`), prod data, a broker, no outbound network. Merging it into the
personal runtime would trade a real isolation boundary for one fewer process. Two runtimes, each
pinned and probed, is the floor.

**Shared-server costs, accepted:**
- **One password, one blast radius.** Already mitigated: loopback only, sanitised session env, and
  self-access denies.
- **Server-wide config.** Harmless here: desks differ only in agent rules, skills and session env,
  all set per session or per agent.
- **One upgrade moves every desk.** That is the point of the gate: one probe plus every desk's
  eval smoke, then the bump.

## 3. Desks

A desk lives in the repo that owns the capability. The research desk lives in research-gateway,
the podcast producer in audio-gateway, review and check in agent-gateway. `project.yaml` declares
it (`spec.provides.desks`, beside `clis`; ADR-010).

```
research-gateway/desks/research/
  desk.yaml          # contract below
  SYSTEM.md          # the system prompt — short, task-specific
  skills/            # progressive disclosure: name + description advertised, body on demand
  output.schema.json # the result shape, validated in code
  eval/golden.jsonl  # 10–30 real tasks with checkable expectations
```

```yaml
name: research
description: Multi-turn research desk — runs research jobs, asks follow-ups, reads the brain.
route: desk_research          # a key in `agw routing`; model ids never appear here
system: ./SYSTEM.md
skills: ./skills
shell:                         # the whole toolset; everything else is denied, so removed
  - gw research *
  - gw brain *
  - gw ask-human *
  - rg *
edit: deny
steps: 40                      # OpenCode's own loop cap → summarise-and-stop
budget: { usd: 0.50, wall_s: 1800 }
workdir: scratch               # scratch | worktree:<repo> | in-place:<repo>
output: ./output.schema.json
handover: re-derive            # the caller is told a cheaper model wrote this
```

**How agw runs it.**
- **Compile at server start.** agw compiles every declared desk into the generated server config:
  one v2 agent per desk with `system`, `permissions` (catch-all deny, then the allowlist, then the
  self-access denies) and `steps`, plus the desk's skills path. `buildOpencodeServerConfig` makes
  the same move for `agw-readonly` today.
- **A run** is `POST /api/desks/:name/runs` → create session (`agent`, `model` from the route,
  `location.directory`) → `PUT /environment` → prompt → wait → validate the final message against
  `output.schema.json`.
- **Schema failure:** re-ask once with the validation error, then fail typed.
- **Per-location `.opencode/` loading is *not* relied on.** agw strips it from worktrees for good
  reasons, and compiled config is what the probe already covers.

**The desks this proposal plans for:**

| Desk | Owner repo | Tools (shell allowlist) | Replaces | Gate before it ships |
|-|-|-|-|-|
| check | agent-gateway | repo make/test, read-only | `agw-check` profile (same behaviour) | existing check probes |
| review | agent-gateway | git, fallow, `gw research` | review angles + synthesis (the phases stay in code) | review eval on 10 past PRs, outcome still derived in code |
| otel | agent-gateway | `hdx` (the otel skill's CLI) | `otel` on Max via `claude -p` + injected HyperDX MCP | ten recorded queries (TDD 12-plan side change) |
| research | research-gateway | `gw research`, `gw brain`, `gw ask-human`, `rg`, `obsidian` | nothing yet; sits above the engine | A/B vs plain `gw research run` on 10 real questions: quality, follow-up rate, $, wall time |
| podcast-producer | audio-gateway | `gw research`, `gw brain`, `gw audio episodes` | the pipeline's research front half | 3 episodes side by side |
| news | news-gateway (future) | engine CLI + `gw brain` | — | built engine-plus-desk from day one |

**The boundary that keeps this inside the factory's rules.** Desks gather, read, summarise, draft
and review. They do not implement code, and they do not hand a lead a root cause as a decision
(TDD `05-capacity.md`). The otel desk returns queries, data and candidate explanations labelled
as candidates; the lead decides. Implementation stays on Max (`MAX_ONLY_IMPLEMENT`).

## 4. Making cheap models strong: the desk playbook

**Every rule has a measurement behind it. A desk that breaks one needs a reason in its `desk.yaml`.**

1. **Code owns the pipeline, the model owns the judgment.** research-gateway went from 33% to a
   fallback-free fan-out once phases moved into code. agw's review derives `clean|actionable|needs-human`
   in code, not from the model.
2. **One-call doors beat discovery.** Athena's questions took 25–45 calls until four composite
   commands made them one (`chat/CLAUDE.md`). Design each desk's top five questions as single commands.
3. **Remove tools, don't forbid them.** An OpenCode `deny` removes the tool from the model's toolset
   (measured, agw probe). A cheap model can't misuse what it can't see. The shell allowlist is the
   toolset.
4. **Machine output is the default.** Without `--json`, `agw review` restated its verdict wrongly in
   5 of 9 runs. With it, 0 of 3 (spike 4).
5. **Unknown flags fail loudly.** One swallowed flag cost 6 calls and 82k tokens (spike 4).
6. **Waiting lives in the CLI.** A long job polled by the model took 6 calls and 95k tokens. A CLI
   that blocks to a budget and exits `pending` with the resume command does it in 2 (ADR-004 item 6).
7. **Typed result, validated in code.** agw checks `output.schema.json`. OpenCode's own
   `format: json_schema` (v1 `retryCount`) is an optimisation once the v2 probe confirms it.
8. **Hard caps.** `steps` makes OpenCode summarise and stop. `budget.usd` is enforced from per-turn
   cost, so a looping run is cut at its budget instead of at the idle watchdog.
9. **Small context.** System prompt under ~2k tokens, skills on demand. Measured prompts already
   run 38–64k, and Haiku costs 5× above 100k.
10. **Settings on the model variant.** v2 ignores agent-level `temperature`, and DeepSeek ignores
    temperature while thinking is on. The route picks the variant (`#high`), the desk doesn't.
11. **Credentials stay outside.** The session env carries a desk-scoped gateway token, never a
    provider key. Gateways are the broker, Athena's `epx serve` pattern.
12. **Remote text is data.** Page text, mail bodies and log lines never become a follow-up command
    (ADR-004 item 7).
13. **Eval gates every change.** A prompt, skill, route or OpenCode bump runs the desk's
    `eval/golden.jsonl` first. research-gateway's `make eval` is the template.
14. **The caller re-derives.** Results carry `handover: re-derive`, Athena's "a cheaper model wrote
    this" contract. Claude Code treats a desk result as evidence, not as a verdict.

## 5. One CLI: `gw`

**Verdict: one binary with one group per gateway. Its command table comes from each gateway's
OpenAPI document, so the CLI is generated, not written.** (Name open, §11.)

```
gw research run "…" [--depth deep] [--wait]      # engine
gw research follow-up <jobId> "…"
gw audio episodes list
gw desk run research "…" [--session <id>]         # desk → {jobId, sessionId, status, output}
gw session show|log|steer|continue|cancel|export|cost <sessionId>
gw review [--ref …]   gw check                    # agw tools; desks underneath
gw schema [cmd]                                   # JSON Schema, offline, from the cached spec
```

**Why one binary.** One install and version, one `secrets-run` auth path, one implementation of
the ADR-004 contract (formats, envelope, error line, exit table, `--commit`,
`--idempotency-key`, `pending` + resume, spill), one conformance run, and one routing block an
agent reads. Five CLIs would mean five drifting implementations of the same nine rules — exactly
what the conformance suite exists to catch.

**Why OpenAPI as the source.** It is the one IR every stack here already emits or can emit:

| Producer | OpenAPI from |
|-|-|
| research-gateway, agent-gateway, audio-, image-, email-gateway (Elysia) | the route schemas: research-gateway's routes already carry Zod `body`/`response` |
| factory API (oRPC, TDD W1a) | oRPC's OpenAPI generator |
| Athena broker, warden (FastAPI) | native |

**How the runner uses it.**
- **`x-cli` on each operation:** command path, default format, `mutating`, `job:
  {statusPath, resume}`.
- **Cached snapshot** of each gateway's `GET /openapi.json`. A request carries the snapshot's sha.
- **Drift:** a gateway on another contract answers `contract_mismatch` (ADR-004 item 9), and the
  runner refreshes the snapshot and retries once.

A new route therefore reaches agents with zero CLI release, and `gw schema` stays offline.

**Self-documentation, generated:** `--help`, `gw schema [cmd]`, `REFERENCE.md`, each skill's
`references/cli.md` and the global routing rule are rendered from the same specs (ADR-004
"commands defined once"). The flag lint fails a SKILL.md that names a flag the spec lacks. epx
proved the loop: `epx schema` derived from the parser, with a generated reference and a drift gate
in `make test`.

**What `gw` does not absorb.**
- **Passthrough shims** (`secrets-run`, `hl`) keep someone else's CLI shape.
- **Repo-local tools** with no server (`epx`, `warden` until it serves HTTP) keep their own binary
  on the same contract.
- **The factory CLI** ships as its own entry in W1a and mounts as `gw factory …` once its OpenAPI
  exists. Folding it later costs a group; forcing it now would put W1a's critical path behind
  this proposal.

**Frameworks.** None of the nine TS frameworks researched generates commands from an *external*
OpenAPI document, so the runner is ours. incur (wevm, Zod 4, `--llms`, `--schema`, OpenAPI and MCP
from one definition) is the closest off-the-shelf design. It is CLI-first, 0.7.1 and eight months
old: a watch item, and the reference to copy conventions from. The rest of the market has no
manifest (`research/2026-10-26-agent-first-cli.md`). The runner itself is one module: spec →
command tree → request → envelope. That is the "small in-house runner" ADR-004 already budgets,
fed by OpenAPI instead of per-CLI `schema --all`. Generic OpenAPI CLIs exist outside that set
(restish, in Go); G1 checks them against the contract with `/research` before writing code.

## 6. Sessions as the cross-tool handle

The owner wants to read, continue and steer any desk run from anywhere. The session id is that
handle, and agw's ledger already maps job ↔ session.

- **Claude Code** runs `gw desk run research "…" --wait`, gets `{output, sessionId}`, and continues
  with `gw session continue <id> "…"`. Offloading to a cheap model is one command, and the context
  cost is the typed result, not the transcript.
- **Hermes** maps a chat thread to a session: the idempotency key comes from the message id
  (ADR-004 item 4), and a reply in the thread becomes `gw session continue`. That works within
  W11's "allowlist of factory CLIs, no terminal".
- **Argo** shows sessions per desk: transcript (`/api/session/{id}/message`, paginated), cost,
  status, steer. On the mini from W5 it reads agw directly. Starting a desk run from Argo is an
  intent through the factory API (ADR-015), not a direct call.
- **Export:** `gw session export` writes agw's own JSON record (messages + usage + job row).
  OpenCode's share links are gone (always HTTP 500 since 1.19.1).

## 7. Observability and cost

- **One span per session** (`desk.session`) with children per assistant turn: `desk`, `route`,
  `tokens.*`, `cost`, `tool`, `outcome`. agw emits them from the message stream it already
  reads. OpenCode's own spans (service `opencode`, ~601 per boot + prompt) are filtered at the
  collector (ADR-006) and joined on `x-opencode-session`.
- **Cost is the settled session rollup** (agw always sets `title`, so rollup = message sum) and
  goes to usage-tracker under the desk name. Argo's Usage page gets a per-desk column.
- **Budget alerts** per desk: daily $ and p90 $ per run, against the desk's own eval baseline.

## 8. Gateway by gateway

| Today | Becomes |
|-|-|
| **research-gateway**: engine, HTTP, MCP `/mcp`, `research` CLI (896-line hand parser) | Engine unchanged. New: `follow_up(jobId, question)` reusing the job's ledger and digests. CLI → `gw research` from OpenAPI. MCP deleted after callers move. Owns the research desk. |
| **agent-gateway**: 17 MCP tools, `agw` CLI, OpenCode server, `claude -p` lane | The runtime and desk host. MCP deleted (TDD W6). review, check and otel become desks. `decide`, `triage` and `read_image` stay single-shot tools. `dispatch implement` retires per TDD. |
| **audio-gateway**: podcast pipeline, STT/TTS | Engine unchanged. Owns the podcast-producer desk. CLI group `gw audio`. |
| **image-gateway**: HTTP, `imgcli` | `gw image` replaces `imgcli` once the OpenAPI covers `/generate|edit|cutout|icons`. |
| **email-gateway**: REST + MCP (7 tools) | `gw mail` from OpenAPI. MCP deleted. Spike 4's "no email CLI" advice predates generation, and with no hand-written CLI there is no build cost left to avoid. |
| **HyperDX**: `hdx.py` in the otel skill | Stays a skill CLI on the contract. The otel desk's only tool. |
| **Hermes**: curl through skills, one MCP (WeatherOrb) | `gw` allowlist. Threads map to desk sessions. |
| **Argo**: VPS, own `/ai/v1`, audio proxy | Mini at W5. Reads sessions and cost, starts desk runs as intents. |
| **Athena** (IU) | Separate runtime, same playbook. epx is the reference implementation of the contract. |

## 9. What this changes in the factory docs

- **ADR-004:**
  - (a) MCP stays only for chrome-devtools, and research-gateway's MCP goes (owner, 2026-10-26:
    "CLI only").
  - (b) One `gw` binary replaces the per-gateway agw/email/audio/image/research CLIs.
  - (c) The IR for server-backed tools is the gateway's OpenAPI document with `x-cli`, not a
    per-CLI `schema --all` snapshot.
  - The contract items 1–9 stay as written.
- **ADR-007** ("agw is a bounded tool server, no loop"): agw hosts *bounded loops*. A desk run is
  a tool call from the caller's side: typed input, typed output, step and $ caps, and no repo
  writes outside its declared workdir.
- **TDD 05-capacity:** add desks to the cheap-model job list with the §3 boundary. The `otel` side
  change becomes the otel desk.
- **TDD 12-plan:** §10 below slots in beside W1a–W6 and touches nothing on W1a's critical path.

## 10. Waves

G0–G2 are independent of the factory's W1a and can run now. G5 *is* TDD W6 and lands with it.

| Wave | Delivers | Proof gate |
|-|-|-|
| G0 | research-gateway: OpenAPI at `/openapi.json` with `x-cli`, `follow_up` door | spec covers every route, follow-up eval on 5 past jobs |
| G1 | `gw` runner + the dotfiles conformance suite, with research as the first group; `/research` skill switched | spike 4 re-run: long job ≤ 2 calls with no policy sentence |
| G2 | agw desk registry (`desk.yaml` → server config, `/api/desks/:name/runs`, session routes, per-desk usage + spans); check migrated as the first desk; a `desk` authoring skill for Claude Code (scaffold, eval, probe) | check probes unchanged, desk eval harness green |
| G3 | otel desk on a cheap route with `hdx` | ten recorded queries vs today's Max `otel` |
| G4 | research desk | A/B on 10 real questions: keep only if it wins |
| G5 | Callers moved: skills → `gw`, Hermes allowlist, agw + research MCP deregistered (= TDD W6) | ADR-004's W8 gate, resident tool tokens = 0 |
| G6 | review as a desk package, podcast-producer, `gw image|mail|audio`, news-gateway | per-desk eval, Argo per-desk usage |

## 11. Open decisions (owner)

1. **Name and reach of the single CLI.** `gw` is a working name, with the factory mounted later
   (§5). Tendency: yes.
2. **Research MCP deleted outright.** That cuts off Claude Desktop and claude.ai, which have no
   shell. Tendency: delete. Not checked: whether either client calls it today. G5 reads
   research-gateway's request log first.
3. **Desks may *draft* review findings and otel explanations on cheap routes.** They do not
   decide. Tendency: yes, gated by each desk's eval.
4. **OpenCode 2.1.x.** agw stays on 2.0.32 (two known fatal compaction bugs) until 2.1's first
   patch passes the probe. Desks inherit whatever the gate admits.
