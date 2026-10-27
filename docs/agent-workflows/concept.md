# agent-workflows: one platform for every workflow, one CLI for every caller

**TLDR.** A fresh monorepo, `agent-workflows`, replaces agent-gateway, research-gateway and
audio-gateway by a hard rewrite. The unit is the **workflow**: typed in and out, versioned,
evaluated. Every workflow runs inside the same middleware, so journaling, cost, telemetry, spend
gates and scoring are global standards, not per-service code. Claude Code and Hermes reach
everything through one `agw` CLI; MCP is gone except chrome-devtools. Order: warden off → core with
review and check → evals on review → research, otel, brain → audio, image, usage → slim Claude Code
and Hermes → retire the old repos. The factory is re-planned afterwards, on top of this.

> **Status: concept v3, 2026-10-27.** Supersedes `../factory/design/gateways.md` (concept v2) for
> the platform. The factory (TDD v2.4) is **deferred**; it gets re-planned around this setup.
> **Inputs:** owner voice note `../factory/feedback/2026-10-27-owner-voice-note-platform-first.md`
> and the chat that followed; `research/2026-10-27-{deepseek-harness,setup-inventory}.md`; the
> 2026-10-26 research and spike 7 cited in concept v2.
> **Next:** the owner resolves §12, then P0.

## 1. Decisions

Carried from concept v2 (still hold):

| # | Decision |
|-|-|
| D2 | No MCP. chrome-devtools stays until a browser CLI exists |
| D3 | Cheap models may draft (review findings, otel explanations); the caller re-derives |
| D4 | Yolo by default; `profile: focused` is an opt-in quality lever |
| D5 | Per-run budgets, steps and wall time are report-only. Wallet spend gates (§4) are enforced |
| D6 | Agents run code; artifacts come back as `[{path, kind}]` |
| D7 | Capability layer in-house, not Mastra |

New on 2026-10-27:

| # | Decision |
|-|-|
| N1 | **Platform first.** The factory waits and is re-planned on top |
| N2 | **Warden off now**, as its own step (P0), not inside a factory wave |
| N3 | **Hard rewrite in a fresh repo.** Old services freeze (fixes only) and keep running until each workflow is cut over, then they are deleted. No code is migrated; behaviour is, through eval sets |
| N4 | **Workflow is the unit.** "Station" and "engine" are retired (§2) |
| N5 | **Middleware wraps every workflow and every step** (§4) |
| N6 | **The platform is the system of record for its own runs.** Argo gets a usage projection; usage-tracker keeps only runtimes outside the platform |
| N7 | **otel needs no MCP.** HyperDX has an HTTP API; `/otel` already uses it |
| N8 | **IU budget is tight.** OCR stays gated (paused to 2026-11-02, then off while IU 30-day spend ≥ $400); the rebuild gets its own budget line |

## 2. Vocabulary

| Term | Meaning |
|-|-|
| **workflow** | the unit: `id`, typed `input` and `output`, a `run` procedure, a scorer, an eval set. Called as `agw <workflow>` |
| **step** | one journaled unit inside a run. Three kinds: `code`, `agent`, `workflow` |
| **agent** | a reusable definition: `AGENTS.md`, skills, route. Several workflows reference the same agent (`brain` serves research and podcast) |
| **capability** | a typed function defined once, exposed as import, HTTP and CLI. Used by code steps directly and by agents through `agw` |
| **run** | one execution of a workflow; owns a run record (§5) |

A former "station" is a workflow with one agent step. A former "engine" is a workflow that is mostly
code steps. The distinction was never about the thing, only about the ratio.

## 3. A workflow

Target API, not built yet. The shape is the owner's: prepare → agent → score → nudge → finish → post-process.

```ts
export default defineWorkflow({
  id: "research.report",
  input: z.object({ question: z.string(), depth: z.enum(["standard", "deep"]) }),
  output: Report,
  scorer: reportScorer,
  async run(ctx, { question, depth }) {
    const plan = await ctx.step("plan", () => caps.decide({ question, options: PLAN_OPTIONS }));
    let draft = await ctx.agent("research", { prompt: brief(question, plan), output: Draft });
    const verdict = await ctx.score("gate", draft);
    if (!verdict.pass) draft = await ctx.continue(draft, verdict.feedback);
    const title = await ctx.step("title", () => caps.title({ text: draft.body }));
    return { ...draft, title };
  },
});
```

- **Journal.** Each step's result is stored under `(runId, stepId)`. After a restart or deploy the
  run resumes at the first unfinished step. Completed steps are not re-run.
- **Agent steps re-attach.** An agent step's durable handle is its OpenCode session id. A restarted
  workflow process re-attaches to the session instead of re-prompting. This replaces today's
  30-minute drain on research-gateway deploys.
- **Effects need keys.** A step with an outside effect (send, publish, write) carries an idempotency
  key derived from `(runId, stepId)`, because no recovery can prove an interrupted effect didn't happen.
- **Bounded runs only.** A workflow run lasts seconds to tens of minutes. Anything that lives for
  days (a factory Issue) is an entity state machine that *starts* workflows, never one long run. This
  is the lesson behind rejecting DBOS for the factory; it does not argue against durable steps here.
- **Failure split** (from DeepSeek Harness): a failing step is fatal; a failing child workflow in a
  fan-out returns `null` and the parent decides.

## 4. Middleware

The workflow author writes `run`. Everything below is the platform's, the same for every workflow.

| Layer | Workflow level | Step level |
|-|-|-|
| Contract | auth, input/output validation (one re-ask, then `invalid_output`), idempotency key | output schema for agent steps |
| Durability | journal, resume, re-attach | step result stored, effect keys |
| Record | run record with fingerprint (§5) | step timing, tokens, cost, tool calls |
| Telemetry | one OTel span per run, `traceparent` accepted | child span per step |
| Money | **wallet spend gate** (IU 30-day cap, fail closed), budget report | cost from `usage.cost` |
| Control | cancel, steer, concurrency limit per workflow | step timeout, retry policy |
| Quality | scorer sampling on production runs | friction counters (§7) |

Interception points follow DeepSeek Harness's taxonomy: `run/pre`, `step/pre`, `tool/pre`,
`tool/post`, `step/post`, `run/post`. The OCR spend gate that is hand-built in review today becomes
one middleware rule that protects every workflow.

## 5. Run record and fingerprint

Every run writes one record: workflow id, input hash, output, outcome, wall time, steps, tokens
(input, output, cache read, reasoning), cost, tool calls, friction counters, scores, trace id.

The **fingerprint** is a hash over everything that can change behaviour: the workflow code version,
each referenced agent's `AGENTS.md` and skills, route (model + effort), OpenCode version. "Did the
change help?" becomes a query: score, cost, latency, tokens and tool calls grouped by fingerprint.

## 6. Evals

One scorer per workflow, used three ways:

1. **Inline gate:** the `ctx.score` step that decides whether to nudge the agent.
2. **Regression:** `agw eval run <workflow>` replays `eval/cases.jsonl` against the current
   fingerprint; a change to code, prompt, skill, route or OpenCode version must not lose.
3. **Drift:** sampled production runs are scored after the fact.

`agw eval compare <workflow> --a <fp> --b <fp>` answers model, effort and prompt questions with
numbers: better, cheaper, faster, fewer tokens, fewer tool calls. Eval replays spend IU money, so
they run under their own budget line (§12.8).

Eval sets today: research-gateway has 28 regex-checked golden questions. **Review and check have
none** — P1 builds them from recorded past runs before the cutover can be judged.

## 7. Self-improvement

Three tiers, cheapest first:

1. **Friction counters, every run, no LLM:** schema re-ask, over budget, repeated identical tool
   call (nudge at 3, 5, 8 — DeepSeek Harness), tool error, a follow-up the user had to ask. A
   threshold breach per workflow opens an Issue with the runs as evidence.
2. **Retrospective workflow, weekly per workflow:** samples run records and transcripts, finds code
   the agent keeps writing (→ a capability), recurring mistakes (→ `AGENTS.md` or skill), tool pain
   (→ CLI change). Output: proposals as Issues, never edits.
3. **Fixes land as PRs behind the eval gate.** Nothing rewrites itself in place.

Learned facts ("this shop blocks at TLS") go into a per-agent learnings store, read back on the next
run — reversible and immediate. The same retrospective later points at Claude Code sessions:
per-repo setup, skills, basalt-ui, alerts. The factory, when it exists, owns the Issues.

## 8. Runtime and deployment

- **Everything on the mini.** email-gateway may stay on the VPS and consume the shared packages.
- **Agent steps run on one OpenCode server**, one location directory per agent, compiled outside
  any repo (an ancestor `AGENTS.md` leaks in otherwise).
- **Processes by deploy unit, not per workflow:** one `host` process (light workflows, capabilities,
  HTTP API), plus own processes for heavy pipelines (research, audio). A review deploy never waits on
  a research run, and a research memory spike can't take review down.
- **Store:** see §12.3.

**OpenCode stays the agent runtime. DeepSeek Harness is a reference** (`research/2026-10-27-deepseek-harness.md`):
Node 24 only, pre-1.0 with announced breaking changes, stdio-only server, and its workflow engine has
no journal, resume or budget — our middleware would still be the point. Taken from it: the event
taxonomy (§4), "model-visible means logged", the repeat-tool nudge, the failure split, a "token
effect / cache effect" note in every package README, and the DeepSeek wire rules for our cheap
routes — pass reasoning back verbatim, never edit history, append system and tool changes instead of
rewriting the head, record cache-read tokens. Its default session-log upload to DeepSeek rules out
running it unconfigured.

## 9. The `agw` CLI

Generated from each process's OpenAPI document plus an `x-cli` extension per operation (spike 7
runner, 536 lines). Every workflow and capability appears without hand-written CLI code. Contract
(ADR-004, proven in spike 7): machine output by default, unknown flags exit 2, exit codes 0–10,
typed error line, long runs exit `pending` with the exact resume command, offline `agw schema`.

Today's `agw` (1,557 hand-written lines in agent-gateway) is renamed `agw-legacy` for the
transition, so the new binary owns the final name from day one.

## 10. Claude Code and Hermes target picture

Facts in `research/2026-10-27-setup-inventory.md`.

| Item | Today | Target |
|-|-|-|
| `check`, `review` skills | MCP + `job_wait` | `agw check` / `agw review`; skill shrinks to when-to-use (P1) |
| `research` skill | research-gateway MCP | `agw research` (P3) |
| `otel` skill | agw MCP `otel` + `hdx.py` / `query.py` | `agw otel` workflow; `hdx` becomes a capability in the repo (P3) |
| `excalidraw-diagram` | agw MCP | `agw diagram` (P3) |
| `prose` | `agw prose` | new `agw prose` (P3) |
| `podcast` | `bun run podcast` in audio-gateway | `agw podcast` (P4) |
| `img` | `imgcli` | `agw image` (P4) |
| `implement`, `wave`, `remote-dev` | name `mcp__agent-gateway__dispatch` | name `agw-legacy dispatch` until the factory replaces it |
| `browse` | chrome-devtools MCP | unchanged |
| agw MCP server | 16 tools | deleted per tool as ported; server gone at P5 |
| research-gateway MCP | `/mcp` | deleted at P3 |
| Unused agw tools (`triage`, `decide`, `update_pr`, `read_image`, `read_drawing`) | MCP, no caller by name | ported only when a caller appears; `decide` returns as a capability |
| hooks, rules, `@implementer`, `@verifier` | — | unchanged |
| CLAUDE.md lanes | four, incl. `warden run` | three after P0 |
| CLAUDE.md "Async jobs" | `mcp__…` → `job_wait` | one line: `agw` waits itself; on `pending`, run the printed resume command |
| Hermes → warden | `hermes-cc.sh`, `warden` skill | deleted at P0 |
| Hermes → gateways | HTTP from scripts and skills; HyperDX via `/api/mcp` | `agw` commands via `terminal` (P5) |
| Hermes TTS/STT | audio-gateway OpenAI-compatible URL | an OpenAI-compatible door on the new audio process (P4) |
| Hermes narratives, overview | agw HTTP | ported workflows (P5) |

## 11. Order

Every phase moves at least one real caller and deletes the old path. A phase with no caller moved
is not done.

| Phase | Builds | Caller moved / deleted | Gate |
|-|-|-|-|
| **P0** | warden off: the checklist in `../factory/tdd/10-surfaces.md` §What is switched off, and when; Kuma and HyperDX alerts go raw to Slack | warden lane, Hermes shim and skill, warden LaunchAgents | `make doctor` green, no caller of warden left |
| **S1, S2** | spikes, about a day each: workflow runtime (§12.2), telemetry (run span + step span into ClickStack, record into Argo) | — | a written verdict each |
| **P1** | repo, workflow runtime, middleware, run record, route table with effort, capabilities, CLI generator, OpenCode host; review and check ported incl. depth gating and the OCR gate | `/check`, `/review` skills; agw MCP `check`, `review` | review and check eval sets built and not worse than the old service on findings, cost, wall time |
| **P2** | scorers, `agw eval run/compare`, friction counters, first retrospective — on review, the biggest IU spender | — | one model or effort question on review answered with numbers |
| **P3** | research (the three-way comparison picks the design), otel, brain, diagram, prose | `/research`, `/otel`, `/excalidraw-diagram`, `/prose`; research-gateway MCP | research golden set held; otel cost per query recorded |
| **P4** | audio pipeline and TTS/STT door, image, podcast; usage projection to Argo; usage-tracker trimmed | `/podcast`, `/img`, Hermes TTS/STT; usage-tracker's platform collectors | one episode produced end to end on the new path |
| **P5** | Claude Code and Hermes slimmed (§10); narratives and overview ported | agw MCP server, research MCP registration in the Makefile | CLAUDE.md and skills reference no MCP gateway tool |
| **P6** | retire research-gateway and audio-gateway; agent-gateway shrinks to `dispatch` | old repos archived | `make doctor` and architecture map clean |
| **then** | factory re-plan on this base | — | — |

## 12. Open decisions

1. **Name.** Repo `agent-workflows`, CLI stays `agw`, today's becomes `agw-legacy`. *Tendency: yes.*
2. **Workflow runtime.** Our own journal, Vercel Workflow (`workflow` package, no Bun guide) or
   DBOS TypeScript. Spike S1 decides with a fake agent step, so it costs no IU tokens. *Tendency: our
   own journal — the same pattern as the factory inbox.*
3. **Store.** Postgres on the mini or SQLite. *Tendency: Postgres* — concurrent processes, evals as
   SQL, and the factory will need it anyway.
4. **Processes.** `host` plus research and audio. *Tendency: yes; split more only on evidence.*
5. **`dispatch`.** Stays on `agw-legacy` until the factory replaces it; not ported. *Tendency: yes.*
6. **Factory in the same monorepo.** Decided at the factory re-plan. *Tendency: yes*, as an app on
   the same runtime and records.
7. **email-gateway.** Stays on the VPS, consumes the packages, moves last or never.
8. **Rebuild budget.** Spikes, eval sets and replays are tagged `purpose=build` with their own cap
   inside the IU wallet gate. *Owner sets the number.*
9. **Agent naming.** "agent" here means an OpenCode agent definition, not a Claude Code subagent.
   *Tendency: accept the overlap; the context makes it clear.*
