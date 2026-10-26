# Agent platforms and harnesses compared — Mastra, Pi, OpenCode 2, Claude Agent SDK, others (research-gateway job 0b7684f1, deep, 2026-10-26)

> Status **partial** (3 claims dropped, Goose pages unverified) · 231 pages retrieved · 147 citations kept · $0.47.

> **Partial result — evidence was lost during this run.** 3 claim(s) were dropped because the pages backing them could not be retrieved; 2 source(s) named in the report body could not be verified and are flagged inline below; 1 citation(s) had their confidence lowered to match the evidence actually retrieved. Anything below that is not backed by an entry in `citations` is unconfirmed; see `unverified` for what could not be checked.

> **Unverified in prose:** this report references <https://goose-docs.ai/docs/guides/recipes/recipe-reference/>, which this run could NOT verify (Page fetch refused: page-text budget exhausted; only search snippets \(field names extensions/parameters/sub\_recipes\) are available.). Treat that reference as unconfirmed — see `unverified`.

> **Unverified in prose:** this report references <https://goose-docs.ai/docs/mcp/summon-mcp/>, which this run could NOT verify (Page fetch refused: page-text budget exhausted; details rest on search-result snippets only.). Treat that reference as unconfirmed — see `unverified`.

## Bottom line

- **Mastra** is the only product in this set that ships every piece of the described platform in one stack — `Agent` + `createTool` + workflows + `Memory` + a Hono server + built-in scorers + OTel export + a model router that accepts arbitrary OpenAI-compatible base URLs — at `@mastra/core` **1.79.0**, so it is the default choice for a "one runtime, many narrow agents" build.
- **Pi (`@earendil-works/pi-*` 1.4.0)** is the opposite trade: a deliberately minimal loop (four tools, prompt+tool defs "below 1000 tokens") extended by TypeScript extensions, `SKILL.md` skills, an SDK and a strict-JSONL RPC mode, with JSONL session trees (fork/clone/compact) and inline per-call cost — but no built-in permission system and no orchestration layer.
- **OpenCode 2** (the `@opencode/*` 2.1.4 line, distinct from `opencode-ai` 1.19.4) is the strongest fit when the *runtime* is the product: an embeddable in-process SDK, one shared background server owning sessions/permissions/tool execution, per-directory config with documented precedence, markdown agents with `primary`/`subagent` modes, ordered last-match-wins permission rules, and a production Durable Object harness.
- **Claude Agent SDK** (npm 0.3.310, PyPI 0.2.174) has the most mature subagent/skill/MCP/hook surface, but it is a thin client over a bundled Claude Code binary: skills are filesystem-only with no programmatic registration API, fan-out is capped (spawn depth 3, 20 concurrent subagents), and routing to non-Claude models through a gateway appears not to be a supported path, though that policy page was not read.
- **VoltAgent, LangGraph/LangSmith Deployment and the OpenAI Agents SDK** each own a different third of the problem (OTel + evals; durable graph execution + managed deployment; the widest session/provider adapter set); **Letta** has pivoted away from the multi-agent server story to a TypeScript agent CLI/SDK, and Goose/Amp/Copilot custom agents were not verified in this run.
- **On the cross-cutting layer**: DeepSeek's current API ids are `deepseek-flash` and `deepseek-v4-pro`, with `deepseek-chat`/`deepseek-reasoner` announced for discontinuation on 2026-07-24 (LiteLLM still lists both — an unresolved disagreement); OTel GenAI semantic conventions are still `[Development]` in a separate repo that has published no tagged release, so version-pinning has to happen at the instrumentation layer.
- **The consolidation literature runs opposite to intuition**: every quantified postmortem found describes *subtracting* agents and instructions, while the largest enterprise centralization (Cloudflare, 3,683 active users on one OpenCode runtime) kept a multi-agent reviewer — so the "modular monolith" is a shared runtime and shared context layer, not fewer agents.

---

## Versions at a glance (registries, 2026‑10‑26)

| Product | Current package(s) & version | Repo signal |
|---|---|---|
| Mastra | `@mastra/core` **1.79.0** (Apache‑2.0, node ≥22.13.0); `@mastra/observability` **1.21.0**; `@mastra/otel-exporter` **1.4.9**; `@mastra/otel-bridge` **1.5.18** | [29,094★, 618 open issues, latest release `@mastra/core@1.79.0`](https://github.com/mastra-ai/mastra) |
| Pi | `@earendil-works/pi-agent-core` **1.4.0**, `@earendil-works/pi-ai` **1.4.0**, CLI `@earendil-works/pi-coding-agent`; old `@mariozechner/*` **0.73.1** is deprecated | [118,014★, v1.4.0 (2026‑10‑21)](https://github.com/badlogic/pi-mono) |
| OpenCode | V1 `opencode-ai` **1.19.4** + `@opencode-ai/sdk` 1.19.4; **V2** `@opencode/{client,sdk,plugin,schema,protocol}` **2.1.4** | [anomalyco/opencode, MIT, release v1.19.4](https://github.com/sst/opencode) |
| Claude Agent SDK | npm `@anthropic-ai/claude-agent-sdk` **0.3.310** (`next` 0.3.311); PyPI `claude-agent-sdk` **0.2.174** (MIT) | [Python repo 8,356★](https://github.com/anthropics/claude-agent-sdk-python) |
| VoltAgent | `@voltagent/core` **2.11.0** (`next` 3.0.0‑next.1), `@voltagent/evals` 2.0.5 | [10,874★](https://github.com/VoltAgent/voltagent) |
| LangGraph | `langgraph` **1.2.18**, `langchain` **1.4.7**, `@langchain/langgraph` **1.5.3** | [43,937★](https://github.com/langchain-ai/langgraph) |
| OpenAI Agents SDK | `openai-agents` **0.24.0**, `@openai/agents` **0.21.0** | [30,302★ (Python)](https://github.com/openai/openai-agents-python) |
| Letta | PyPI `letta` **0.34.12**, `@letta-ai/letta-agent-sdk` **0.8.53**, Docker 0.34.21 | [25,261★ but last GH release 0.16.8](https://github.com/letta-ai/letta) |

---

## 1. Mastra — the full-stack option

**Core abstraction.** `new Agent({ id, name, instructions, model })` from `@mastra/core/agent`, registered via `new Mastra({ agents })` and fetched with `getAgentById()` so it inherits instance storage, logging and the agent registry ([agents overview](https://mastra.ai/docs/agents/overview)). A specialized agent is therefore just a config object: distinct `instructions`, a `tools` record, optional `memory`, optional `scorers`.

**Tools and sharing — the important part.** `createTool({ id, description, inputSchema, outputSchema, execute })` from `@mastra/core/tools`, with schemas from any Standard JSON Schema library. Cross-agent reuse is a plain import: *"Direct imports are the best choice when one tool is used by multiple agents"* ([tools docs](https://mastra.ai/docs/agents/tools)). Sharing also works without imports: subagents passed as `agents: {…}` are auto-exposed as `agent-<key>` tools and `workflows: {…}` as `workflow-<key>` tools (using the workflow's input/output schemas), which is exactly the "library of capabilities callable by any agent" pattern. The `execute(inputData, context)` context exposes `requestContext`, `abortSignal`, `agent`, `workflow` (state/setState/suspend), `mcp`, `observe(name, fn, attrs)` for child spans and a no-op-safe `log()` ([createTool reference](https://mastra.ai/reference/tools/create-tool)); tool options include `requireApproval`/`beforeApproval`, `outputValidation: 'strict' | 'warn'`, `suspendSchema`/`resumeSchema`, `transform`, `mcp.annotations`, `background` and lifecycle hooks.

**Workflows.** `createStep({ id, inputSchema, outputSchema, stateSchema, execute })` composed with `.then()/.branch()/.parallel()/.dountil()/.dowhile()/.foreach()/.map()/.sleep()/.agent()/.tool()/.classifier()`, then `.commit()`; runs via `createRun().start({inputData})` with `stream()`, `resumeStream()`, `restart()` and statuses `success | failed | suspended | tripwire | paused` ([workflows](https://mastra.ai/docs/workflows/overview)). Sub-workflows nest as steps or are duplicated with `cloneWorkflow`.

**Memory & durability.** `@mastra/memory`'s `Memory` plus a registered store (docs use `LibSQLStore`); features are message history, **Observational Memory** (marked Recommended), working memory, semantic recall, and per-resource/thread scoping. Multi-agent delegation isolates subagent memory automatically: fresh threadId per delegation and a deterministic resourceId `{parentResourceId}-{agentName}`, with a memory-less subagent inheriting the supervisor's Memory ([memory docs](https://mastra.ai/docs/memory/overview)).

**Server.** Hono-based, `.mastra` build output; `server: { port, host }` defaults to `PORT`//4111 and `MASTRA_HOST`/localhost; OpenAPI at `/api/openapi.json` and Swagger at `/swagger-ui` (off in production by default); OpenAI-compatible Responses/Conversations routes exist but are documented as experimental ([server](https://mastra.ai/docs/server/overview.md)). Agent routes include `/generate`, `/stream`, `/send-message`, `/queue-message`, `/signals`, `/threads/subscribe`, `/threads/abort`, `/send-tool-approval`, `/resume-stream`; workflows expose `/create-run`, `/start-async`, `/stream`, `/resume`, `/runs`; plus `/api/tools/:toolId/execute`, `/api/memory/threads…` and `/api/vectors/:vectorName/*` ([routes reference](https://mastra.ai/reference/server/routes.md)).

**Evals/scorers — attach point vs registry.** Scorers attach on the Agent constructor: `new Agent({ id, scorers: { relevancy: { scorer: createAnswerRelevancyScorer({…}), sampling: { type: 'ratio', rate: 0.5 } } } })`, typed as `scorers?: DynamicArgument<MastraScorers>` (static or per-request) ([evals overview](https://mastra.ai/docs/evals/overview)). Separately, `new Mastra({ scorers })` is a *registry*: scorers attached to agents/steps self-register, but scorers passed to `runEvals()` (incl. Quick Checks) need the Mastra option or each save fails with `Scorer with id <id> not found` and scores never reach storage. Live scoring runs asynchronously after the response, gated by `sampling.rate` (1.0 = every response), and sampling is **deterministic per trace ID**, so re-running a trace reproduces the decision; on-demand modes are trace evaluation in Studio and `runEvals({ target, data, scorers, gates, concurrency })` with `passed | scored | failed` verdicts ([runEvals](https://mastra.ai/reference/evals/run-evals.md)). Built-ins include answer-relevancy, faithfulness, hallucination, completeness, tool-call-accuracy, trajectory-accuracy, context-precision/relevance, toxicity/bias, plus zero-LLM `checks.*` like `calledTool`, `toolOrder`, `maxToolCalls` ([built-in scorers](https://mastra.ai/docs/evals/built-in-scorers)).

**Observability & cost.** Tracing is configured as `observability: new Observability({ configs: { … } })` from `@mastra/observability`; span *types* (`SpanType`, `AnySpan`, `CustomSpanFormatter`) still come from `@mastra/core/observability`, while exporters/processors moved out ([tracing](https://mastra.ai/docs/observability/tracing/overview)). The stable OTel path is `OtelExporter` (presets `dash0 | signoz | newrelic | traceloop | laminar | custom`), while `OtelBridge` for joining an existing OTel pipeline is explicitly flagged experimental ([OTel integration](https://mastra.ai/integrations/observability/opentelemetry), [bridge reference](https://mastra.ai/reference/observability/tracing/bridges/otel)). Span naming follows GenAI semconv v1.38.0: `chat {model}`, `model_generation {model}`, `agent_step {agent_id}`, `execute_tool {tool_name}`, `invoke_agent {agent_id}`, `invoke_workflow {workflow_id}` — and **only the chat span carries** `gen_ai.request.model` and `gen_ai.usage.input_tokens`/`output_tokens`, so summing usage across spans counts each model call exactly once. Cost is derived, not an attribute: *"When a span ends, Mastra extracts duration, token counts, and cost estimates"* into the metrics domain ([observability overview](https://mastra.ai/docs/observability/overview)).

**Model router.** `ModelRouterModelId` is a real public type in `@mastra/core/llm`, a template-literal union over the registry plus `` `mastra/${…}` `` **plus `(string & {})`** — so it gives autocomplete but does *not* reject unknown ids at compile time; strictness requires `satisfies` unions or `declare module '@mastra/core/llm' { interface ProviderModelsMap }` augmentation ([source](https://github.com/mastra-ai/mastra/blob/HEAD/packages/core/src/llm/index.ts), [custom gateways](https://mastra.ai/models/gateways/custom-gateways)). Runtime acceptance is separate: `isValidModelId()` requires the provider to be registered. **Fallbacks are an object array**, not bare strings: `ModelWithRetries = { id?, model, maxRetries?, enabled?, modelSettings?, providerOptions?, headers? }` ([types.ts](https://github.com/mastra-ai/mastra/blob/HEAD/packages/core/src/agent/types.ts)). **Custom OpenAI-compatible endpoints are first-class**: `model: { id: 'custom/my-qwen3-model', url: 'http://host/v1' }` (base URL, not `/chat/completions`), with `api: 'responses'` to select the Responses API, and a source comment confirming that a custom `url` deliberately skips API-key/gateway resolution because "the provider might not be in the registry (e.g., custom providers like ollama)" ([router.ts](https://github.com/mastra-ai/mastra/blob/HEAD/packages/core/src/llm/model/router.ts), [models](https://mastra.ai/models)).

**Maturity and pain points.** Cadence is aggressive: the dist-tag list holds hundreds of `0.0.0-<branch>-<timestamp>` canaries across 2025‑02 → 2026‑10 ([npm](https://www.npmjs.com/package/@mastra/core)), and the docs carry a per-subsystem v1.0 migration set (agent, CLI, client, deployment, evals, mastra, MCP, memory, processors, RAG, storage, tools, tracing, vectors, voice, workflows) ([llms.txt](https://mastra.ai/llms.txt)) — the 0.x→1.x break surface is real. Observability is versioned on its own train and peers to `@mastra/core >=1.16.0-0 <2.0.0-0`, so upgrades must be tracked separately. Two documented inconsistencies: `docs/agents/tools` says `execute` has "exactly one signature" while the reference types the context as optional; and the DeepSeek provider page headings claim "4 models" against a two-row table.

---

## 2. Pi — the minimal harness with a large extension surface

**What it is.** `badlogic/pi-mono` now redirects to **`earendil-works/pi`**, and the packages moved scope: `@mariozechner/pi-agent-core` and `@mariozechner/pi-ai` (last 0.73.1) are **deprecated on npm** with "please use @earendil-works/… instead going forward" ([pi-agent-core](https://www.npmjs.com/package/@mariozechner/pi-agent-core), [pi-ai](https://www.npmjs.com/package/@mariozechner/pi-ai)). The monorepo builds `chord` (typed hot-reload plugin host), `pi-telemetry`, `pi-ai` ("Unified multi-provider LLM API"), `pi-durable` (durable conversation/task/document runtime), `pi-agent-core` ("Agent runtime with tool calling and state management"), `pi-coding-agent` (the CLI) and `pi-tui`, plus `codemode`, `mcp`, `env` and `eval` → `@earendil-works/pi-evals` ([README](https://github.com/earendil-works/pi/blob/HEAD/README.md), [package.json](https://github.com/earendil-works/pi/blob/HEAD/package.json)).

**Building a custom agent.** `new Agent({ initialState: { systemPrompt, model, thinkingLevel, tools, messages }, streamFn, convertToLlm, transformContext })`, with the flow `AgentMessage[] → transformContext() → convertToLlm() → Message[] → LLM` and events `agent_start → turn_start → message_* → tool_execution_* → turn_end → agent_end`; low-level `agentLoop()`/`agentLoopContinue()` yield raw event streams, and `beforeToolCall`/`afterToolCall`/`prepareRequest`/`finishTurn`, `steer()`/`followUp()` queues and `streamProxy` (browser→backend) are available ([agent README](https://github.com/earendil-works/pi/blob/HEAD/packages/agent/README.md)). Tools are plain `AgentTool` objects (TypeBox `parameters`, `execute(toolCallId, params, signal, onUpdate)`) living in the mutable `agent.state.tools` array — so the **host owns the loadout** and can construct many Agent instances each with its own tool array; execution is parallel by default with per-tool `sequential` opt-in. The CLI installs with `npm install -g --ignore-scripts @earendil-works/pi-coding-agent` and requires Node 22.19+.

**Extension/skill model (this is Pi's "shared tools library").** Extensions are TypeScript modules at `~/.pi/agent/extensions/*.ts` (or project dirs) exporting `export default function (pi: ExtensionAPI)`, jiti-loaded without a build step, running in-process with the same OS permissions; the surface is `pi.on()`, `registerTool/registerCommand/registerShortcut/registerFlag/registerProvider/registerMcpServer/registerVirtualModel`, `sendUserMessage/sendMessage`, `appendEntry`, `pi.events`, plus `ctx.ui`, `ctx.sessionManager` and `ctx.executeTool()` ([extensions](https://github.com/earendil-works/pi/blob/HEAD/packages/coding-agent/docs/extensions.md)). Tools compose across agents by nesting: `ctx.executeTool(name, args, { signal, onUpdate })` gives pi-assigned ids `<parent id>/<n>`, carries `parentToolCallId`, and folds nested `usage` into the caller's result. Skills are directory-`SKILL.md` per the Agent Skills spec (frontmatter `name`, `description`, `allowed-tools`, `disable-model-invocation`), only name/description/path enter the system prompt, `/skill:name` forces a load, and Pi also reads `~/.agents/skills/` and `.agents/skills/` ([skills](https://github.com/earendil-works/pi/blob/HEAD/packages/coding-agent/docs/skills.md)).

**Modes and durability.** SDK: `createAgentSession()` returns an AgentSession (`prompt/steer/followUp/subscribe/abort/waitForIdle/dispose`) with `SessionManager.inMemory()` available, plus `AgentSessionRuntime` for newSession/switchSession/fork/importFromJsonl ([sdk](https://github.com/earendil-works/pi/blob/HEAD/packages/coding-agent/docs/sdk.md)). RPC: `pi --mode rpc --no-session` speaks strict JSONL over stdin/stdout with four record families correlated by an optional `id`; split only on LF, keep stdout protocol-only, and wait for `agent_settled` rather than `agent_end` ([rpc](https://github.com/earendil-works/pi/blob/HEAD/packages/coding-agent/docs/rpc.md)). Sessions autosave to `~/.pi/agent/sessions/` grouped by cwd; `--continue`, `--resume`, `--session-dir`/`PI_CODING_AGENT_SESSION_DIR`, and entries stored as a **tree** with `/tree`, `/fork`, `/clone` and `/compact` (auto-compaction near the context limit adds a summary without deleting originals); `/session` reports file, ID, message count, token usage and cost ([sessions](https://github.com/earendil-works/pi/blob/HEAD/packages/coding-agent/docs/sessions.md)).

**Routing, cost, evals.** `pi-ai` is a "Unified LLM API with provider collections, automatic auth resolution, token and cost tracking, and simple context persistence and hand-off to other models mid-session", covering OpenAI, Azure, Anthropic, Google/Vertex, Bedrock, Mistral, Groq, Cerebras, xAI, OpenRouter, Together, HF, Copilot, DeepSeek, NVIDIA NIM, Cloudflare, Moonshot, MiniMax, ZAI, Fireworks **plus "Any OpenAI-compatible API: Ollama, vLLM, LM Studio"**; `createProvider({ id, auth, models, api })` takes model-level `baseUrl` and an `OpenAICompletionsCompat` override matrix with URL-based auto-detection ([ai README](https://github.com/earendil-works/pi/blob/HEAD/packages/ai/README.md)). Assistant messages carry `usage.input/output/cacheRead/cacheWrite` and `usage.cost.total`, where `usage.cost.totalFromProvider` distinguishes provider-billed from catalog-estimated cost; telemetry records `pi.ai.tokens` and `pi.ai.cost`. `fauxProvider()` with `fauxAssistantMessage`/`fauxToolCall` and a scripted queue makes deterministic agent tests possible, and the monorepo defines a `@earendil-works/pi-evals` workspace via `npm run eval`.

**Known pain points (self-documented).** *"Pi does not include a built-in permission system for restricting filesystem, process, network, or credential access"* — containerisation is the recommended boundary; and *"New issues and PRs from new contributors are auto-closed by default."* The project also argues public OSS coding-agent session data beats "toy benchmarks" and publishes sessions to a Hugging Face dataset ([README](https://github.com/earendil-works/pi/blob/HEAD/README.md)).

---

## 3. OpenCode 2 — server-as-runtime

**Two products, one command.** V1 is `opencode-ai` 1.19.4 with `@opencode-ai/sdk` 1.19.4 and GitHub release tags on 1.x; V2 is published *only* under `@opencode/*` at **2.1.4** — a naming trap, since GitHub release tags track 1.x ([npm 1.x](https://www.npmjs.com/package/opencode-ai), [@opencode/sdk](https://www.npmjs.com/package/@opencode/sdk)). The two are "no longer installed side by side by default", and V2's three intentional breaks are a new plugin API, a new server API/client set, and CLI config moving from layered `tui.json(c)` to one global `~/.config/opencode/cli.json` ([migrate guide](https://github.com/anomalyco/opencode/blob/HEAD/services/www/src/docs/content/migrate-v1.mdx)). Distribution channels disagree on what they install — `brew install opencode` is V2 while `anomalyco/tap/opencode` is V1, Arch's `opencode` is V2 while AUR `opencode-bin` is V1 ([docs](https://opencode.ai/docs/)).

**Runtime shape.** `@opencode/sdk` "executes Server's assembled HTTP router in memory, opening no listener and adding no network hop", and `@opencode/client` is "derived directly from OpenCode's authoritative Effect `HttpApi`" with peer `effect 4.0.1` ([client](https://www.npmjs.com/package/@opencode/client)). The published API reference is **OpenAPI 3.1.0**, labelled "Experimental HttpApi surface for selected instance routes" (`/api/info`, `/api/pair`, `/auth/connect/{code}`, `/api/location`, `/api/location/reload`, agent, plugin) ([api](https://opencode.ai/v2/docs/api)). By default the CLI "discovers or starts one shared background server for your user account. Every local OpenCode client connects to that server, which owns sessions, configuration, integrations, permissions, and tool execution", overridable with `--standalone` / `--server http://localhost:4096` ([cli](https://opencode.ai/v2/docs/cli)). Embedding looks like `await using opencode = await OpenCode.create()`, then `opencode.sessions.create({ location: { directory: '/workspace' } })` and `opencode.events.subscribe()` ([build/sdk](https://opencode.ai/v2/docs/build/sdk)).

**Packaging a narrow agent.** `~/.config/opencode/agents/<name>.md` or `.opencode/agents/<name>.md`, where nested paths become the id (`team/reviewer`); frontmatter mirrors config (`description`, `mode`, `model`, `system`, `permissions`, `steps`, `hidden`, `disabled`, `request`). `mode` is `primary | subagent | all`; subagents run in fresh-context foreground/background child sessions gated by the parent's `subagent` permission. Crucially, *"Do not use legacy top-level fields such as temperature, top_p, prompt, permission, tools, disable, or maxSteps in new V2 agent configuration"* — use `request.body` or a model variant ([agents](https://opencode.ai/v2/docs/agents)).

**Config, per-directory resolution.** `experimental.location_idle_timeout` (default "60 minutes") governs how long a project **location** stays loaded — this is the per-directory runtime knob. Precedence: global `~/.config/opencode/opencode.json(c)` < project files merged farthest→closest < `.opencode/opencode.json(c)` < system dir (`/etc/opencode`, `/Library/Application Support/opencode`, `%ProgramData%\opencode`) < macOS managed `ai.opencode.managed.plist`; the system dir also loads `agents/`, `commands/`, `skills/`, `plugins/` for every user ([config](https://opencode.ai/v2/docs/config)). `AGENTS.md` loads global-first then workspace→home, with `instructions` adding files/globs/URLs after, and `OPENCODE_DISABLE_PROJECT_CONFIG=1` skipping project AGENTS.md ([instructions](https://opencode.ai/v2/docs/instructions)).

**Sharing tools and skills.** Plugins are `Plugin.define({ id, setup(ctx) })` from `@opencode/plugin`; `.opencode/plugins/` auto-loads and the `plugins` config accepts npm packages, `pkg@version`, scoped packages, `file://` dirs or `{ package, options }`. The context is "essentially an OpenCode server client" covering agent/provider/model/command/integration/credential/mcp/plugin/reference/skill/tool/vcs/worktree/session/permission/generate/storage plus `event.subscribe()`, with hooks `session.hook('prompt'|'context'|'compaction'|'generate'|'model.request'|'http.request'|'http.response'|'retry')`, `permission.hook('evaluate')`, `tool.hook('execute.before'|'execute.after')`, and tool registration via `ctx.tool.transform(editor => editor.add({ name, description, input, execute }))` ([build/plugins](https://opencode.ai/v2/docs/build/plugins)). Skills are `SKILL.md` directories discovered in `~/.config/opencode/skills`, `~/.claude/skills`, `~/.agents/skills` and the project equivalents, walking up to the project root, six levels deep, skipping hidden dirs and `node_modules`; ids are path-derived and case-sensitive (`<source>/teams/release/SKILL.md` → `release`), and the `skills` config is an ordered array that **combines** entries across files plus HTTP catalogs rather than replacing them ([skills](https://opencode.ai/v2/docs/skills)).

**Permissions.** One ordered array of `{action, resource, effect}` where "the last matching rule wins", effects `allow|deny|ask`, unmatched → `ask`; actions cover `read/edit/glob/grep/shell/subagent/skill/question/webfetch/websearch/external_directory/<server>_<tool>/execute`. Every agent starts from a base policy allowing all except `read *.env` (ask) and `*.env.example` (allow) — and `external_directory` is allowed by default, so V1's prompt-before-outside-project behaviour must be re-added. Approvals are `once|always|reject`; saved approvals are durable project-scoped allow rules that "never override a configured deny" ([permissions](https://opencode.ai/v2/docs/permissions)).

**Routing, telemetry, adoption.** The catalog comes from models.dev; custom OpenAI-compatible providers are declared under `providers` with `package: "@opencode/ai/providers/openai-compatible"` plus `settings.baseURL`, and native packages include `openai`, `openai/chat`, `openai/responses`, `openai-compatible`, `anthropic(-compatible)`, `google`, `google-vertex/*`, `azure/*`, `amazon-bedrock/*`, `openrouter`, `xai` ([providers](https://opencode.ai/v2/docs/providers)). V1's experimental `openTelemetry` setting is **ignored with a warning** in V2 — there is currently no documented OTel path in OpenCode 2, which is the biggest gap for this use case. Per-session cost appears in the CLI-plugin API surface ("list, lookup, hierarchy, cost, status…"), and the optional Console offers usage tracking and budget controls — both from snippets only. Third-party runtime adoption is real: Cloudflare's `OpenCodeHarness` "Run[s] OpenCode 2.0 in a plain Durable Object", installing `@opencode/sdk@2`/`@opencode/plugin@2` (range `^2.0.24`), prefixing tables with `opencode_`, and using alarms so *"If the object crashes or is evicted, an alarm restarts it, and OpenCode resumes interrupted work"* ([Cloudflare](https://developers.cloudflare.com/agents/harnesses/opencode/index.md)). V2 session storage/durability details beyond that remain partly unverified.

---

## 4. Claude Agent SDK — the harness is Claude Code

**Architecture.** Both SDKs are thin clients over a bundled Claude Code binary spawned as a subprocess, so capability is gated on the bundled CLI version (many features "require Claude Code v2.1.30x"). That single fact drives everything else: sessions live in the CLI's transcript store, skills must be files on disk, and permissions are the CLI's model.

**API.** TS `query({prompt, options})` returns a `Query` AsyncGenerator with `interrupt/rewindFiles/setPermissionMode/setModel/streamInput/supportedAgents/mcpServerStatus/getContextUsage/reloadPlugins/reloadSkills/close`, plus `startup()` prewarm — **no session-holding client class**; Python has both `query()` (new session per call) and `ClaudeSDKClient` (session-holding, interrupts, streaming input) ([typescript](https://code.claude.com/docs/en/agent-sdk/typescript), [python](https://code.claude.com/docs/en/agent-sdk/python)).

**Narrow agents.** Programmatic `agents: { name: AgentDefinition }` (recommended) or `.claude/agents/*.md`, programmatic winning on name clash; `AgentDefinition` carries `description`/`prompt` (required), `tools`, `disallowedTools` (supports `mcp__server__*`), `model`, `skills` (first 32 preloaded), `memory`, `mcpServers`, `maxTurns`, `background`, `effort`, `permissionMode`. A non-fork subagent gets its own system prompt, CLAUDE.md, preloaded skills and inherited tool definitions but **not** the parent conversation — only the Agent tool's prompt string crosses ([subagents](https://code.claude.com/docs/en/agent-sdk/subagents)). Note `allowedTools` is an auto-approve list, *not* a restriction: *"This does not restrict Claude to only these tools."*

**Skills.** Filesystem-only: *"The SDK doesn't provide a programmatic API for registering them"*; gated by `skills` (`'all'`, exact names, or `[]`, no wildcards; plugin skills as `plugin:skill`), discovered via `settingSources` (`'user'|'project'|'local'`, default all, `[]` disables) ([skills](https://code.claude.com/docs/en/agent-sdk/skills)).

**Tools.** MCP is the sharing mechanism: `mcpServers` stdio/sse/http or in-process servers via `createSdkMcpServer({ name, tools })` + `tool(name, description, zodSchema, handler)` (Python `create_sdk_mcp_server` + `@tool`); tools named `mcp__<server>__<tool>` with wildcard allowlists ([mcp](https://code.claude.com/docs/en/agent-sdk/mcp)). Scale caveats: a server without a cached tool list delays the first turn up to `MCP_TIMEOUT` (30s default), text results over 25,000 tokens spill to a file, and the SDK never runs an interactive OAuth flow.

**Sessions.** Transcripts auto-written to `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`; `continue` picks the latest in cwd, `resume` takes a UUID, `forkSession` copies the transcript, `persistSession: false` disables disk, and `SessionStore` adapters mirror transcripts for cross-host/serverless resume; helpers `listSessions/getSessionMessages/renameSession/tagSession/forkSession` exist in both SDKs, and `/compact` emits a `compact_boundary` message ([sessions](https://code.claude.com/docs/en/agent-sdk/sessions)).

**Telemetry, cost, licensing.** Python publishes an optional `otel` extra (`opentelemetry-api>=1.20`) ([PyPI](https://pypi.org/project/claude-agent-sdk/)); Claude Code exports OTel metrics, events and optional traces gated by `CLAUDE_CODE_ENABLE_TELEMETRY=1` with `OTEL_METRICS_EXPORTER`, including `claude_code.token.usage`, `claude_code.cost.usage` (USD) and `claude_code.session.count`. Cost caveats matter for many small agents: `maxBudgetUsd` is a client-side estimate that "can pass this value" and only counts the call's own spend (resumed-session totals don't count), and `getContextUsage()` in full detail issues token-counting requests that never appear in the message stream ([typescript](https://code.claude.com/docs/en/agent-sdk/typescript)). Licensing: use is governed by Anthropic's Commercial ToS; the npm package's licence field is the literal string "SEE LICENSE IN README.md" while the Python package is MIT ([npm](https://www.npmjs.com/package/@anthropic-ai/claude-agent-sdk), [overview](https://docs.claude.com/en/api/agent-sdk/overview)). Runaway fan-out is bounded by `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH` (3), `CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS` (20) and `maxBudgetUsd`. Plugins are local-path only (`{ type: 'local', path }`).

---

## 5. The rest of the field

**VoltAgent** (`@voltagent/core` 2.11.0) is the closest analogue to Mastra in TypeScript: `Agent({ name, instructions, model, tools, memory, subAgents, supervisorConfig, hooks })`; narrow agents via (a) `subAgents` which auto-injects a `delegate_task` tool and supports `createSubagent` wrappers and `onHandoff`/`onHandoffComplete` `bail()`, or (b) `agent.toTool()` in a coordinator's `tools` ([sub-agents](https://voltagent.dev/docs/agents/sub-agents/), [agents](https://voltagent.dev/docs/agents/overview/)). The `bail()` early-termination hook is documented as ~2,650 → ~560 tokens/request (79%, ~$0.020) and bailed runs get OTel span attributes. Workflows (`createWorkflowChain` + `.andThen/.andAgent/.andWhen/.andAll/.andRace/.andGuardrail`, `restart()`, `timeTravel()`) are explicitly **"in Preview"** and persist run history through Memory adapters ([workflows](https://voltagent.dev/docs/workflows/overview/)). It is the most OTel-native of the group — core depends on `@opentelemetry/sdk-trace-node` plus OTLP exporters, tool tags land in spans, and `execute()` receives an OperationContext with `traceContext` ([core](https://www.npmjs.com/package/@voltagent/core), [tools](https://voltagent.dev/docs/agents/tools/)); VoltOps is the console. Evals ship: `@voltagent/evals` 2.0.5 with `createExperiment`/`runExperiment`, scorers, `passCriteria`, `volt eval run` CLI and live scorers emitting `eval.scorer.*` spans ([evaluation](https://voltagent.dev/evaluation-docs/)). Routing is the Vercel AI SDK provider layer plus a `"provider/model"` resolver over a models.dev snapshot, with `@ai-sdk/openai-compatible` and per-provider `*_BASE_URL` overrides ([providers](https://voltagent.dev/docs/getting-started/providers-models/)). Drift warning: `@voltagent/vercel-ai` is still 1.0.0 (2025‑08‑15, peer `@voltagent/core ^0.1.71`) against a 2.x core.

**LangGraph** is a durable-execution *runtime*, not an agent-configuration framework: `langgraph` 1.2.18 with `langchain` 1.4.7 depending on `langgraph>=1.2.12`, and `langgraph-checkpoint-postgres` 3.2.0 for persistence ([PyPI](https://pypi.org/project/langgraph/)). The deployment product was renamed: *"LangGraph Platform has been renamed to LangSmith Deployment as of October 2025"* (and Studio → LangSmith Studio), with pricing/contracts unchanged ([changelog](https://docs.langchain.com/langsmith/changelog.md)). The Agent Server runtime is graphs + persistence + a task queue exposed as assistants/threads/runs/crons, deployable Cloud/Hybrid/self-hosted/standalone, and — relevant here — framework-agnostic: Strands, Claude Agent SDK and Google ADK agents can be deployed on it ([agent-server](https://docs.langchain.com/langsmith/agent-server.md), [deployment](https://www.langchain.com/langsmith/deployment)). Capabilities listed include crons, double-texting, durability across restarts, HITL, "Persistent checkpoints with up to 25 MB payloads", a memory store with semantic search, multi-task state isolation for subagents, webhooks, A2A/MCP endpoints and an agent registry.

**OpenAI Agents SDK** is the "library as harness" with the widest durability adapter set: sessions are pluggable — `SQLiteSession`, `AsyncSQLiteSession`, `RedisSession`, `SQLAlchemySession`, `MongoDBSession`, `DaprSession`, `OpenAIConversationsSession`, `OpenAIResponsesCompactionSession`, `AdvancedSQLiteSession` (branching + usage), `EncryptedSession`, plus a Protocol for custom backends — and **a session can be shared across different Agent instances** so many agents see one history ([sessions](https://openai.github.io/openai-agents-python/sessions/)). Multi-provider is `OpenAIResponsesModel` (recommended) vs `OpenAIChatCompletionsModel`, with `set_default_openai_client`, per-run `ModelProvider`, per-agent `model`, `MultiProvider` prefix routing, and LiteLLM/Any-LLM as *best-effort beta*; Responses-only features (tool search, deferred tools, programmatic tool calling, reasoning mode/context) are rejected elsewhere ([models](https://openai.github.io/openai-agents-python/models/)). MCP has four transports including `HostedMCPTool` and `MCPServerManager` ([mcp](https://openai.github.io/openai-agents-python/mcp/)). Tracing is on by default to OpenAI's dashboard (unavailable under ZDR) and extensible to ~30 processors such as Langfuse, Braintrust, Phoenix, MLflow, Datadog ([tracing](https://openai.github.io/openai-agents-python/tracing/)). There is no in-SDK eval framework; per-run usage lands on `RunResult`.

**Letta** has moved off the multi-agent server story: the FAQ says to use the **TypeScript Agent SDK**, not the lower-level REST API, there is no Python SDK, and the App Server protocol is bidirectional WebSocket (`--openai-api` exposes only a partial OpenAI-compatible surface) ([FAQ](https://docs.letta.com/reference/faq)). The `.af` AgentFile is documented under "V1 SDK (legacy)" and the current SDK does not support .af import/export ([agent-file](https://docs.letta.com/v1-sdk/concepts/agent-file)). Specialization is subagents: seven built-ins plus Markdown files in `.letta/agents/` with `name/description/tools/model/memoryBlocks/skills`, and any existing agent can be deployed as a subagent by `agent_id` — the closest thing to a many-agents runtime ([subagents](https://docs.letta.com/configuration/subagents/index.md)). Memory is now MemFS (git-tracked markdown, no vector index by default); skills follow the portable Agent Skills standard across four scopes ([skills](https://docs.letta.com/configuration/skills)). Routing uses `provider/model` handles with DeepSeek and a generic "OpenAI-compatible API" entry in the supported-provider table ([models](https://docs.letta.com/configuration/models/index.md)); the durable model splits agent/conversation/session and requires `resumeSession(conversationId)` after a drop, and **the SDK does not replay missed events** ([sessions](https://docs.letta.com/agent-sdk/sessions)).

**Goose** (repo now `aaif-goose/goose`, Apache‑2.0, 55,763★, v1.56.0) exposes recipes as reusable YAML with `extensions`, `parameters` and `sub_recipes`, and a "Summon" MCP extension that loads recipes/agent definitions to delegate to subagents — snippet-level only ([repo](https://github.com/block/goose), [recipe reference](https://goose-docs.ai/docs/guides/recipes/recipe-reference/), [summon](https://goose-docs.ai/docs/mcp/summon-mcp/)). **Amp** and **GitHub Copilot custom agents** were not researched.

---

## 6. Model routing to OpenAI-compatible endpoints (DeepSeek worked example)

**DeepSeek's current shape.** The official changelog for DeepSeek‑V4 states: *"The two legacy API model names, deepseek-chat and deepseek-reasoner, will be discontinued in three months (2026-07-24). During the current period, these two model names point to the non-thinking mode and thinking mode of deepseek-v4-flash"* ([updates](https://api-docs.deepseek.com/updates)). Current ids are `deepseek-flash` (served by DeepSeek‑V4.1‑Flash‑1017) and `deepseek-v4-pro`. **Sources disagree**: LiteLLM's DeepSeek page (read Oct 2026) still documents `deepseek/deepseek-chat` and `deepseek/deepseek-reasoner` as supported names alongside `deepseek-flash` and `deepseek-v4-pro` — either its page is stale or the aliases outlived the announced cutoff; unresolved ([LiteLLM](https://docs.litellm.ai/docs/providers/deepseek)).

| Router | How you point it at DeepSeek / any OpenAI-compatible endpoint |
|---|---|
| LiteLLM | provider-prefix `model: deepseek/<model>` + `api_key: os.environ/DEEPSEEK_API_KEY` in a keyed `model_list`; its cost map carries DeepSeek's peak/off-peak schedule and applies off-peak automatically from request UTC time — `deepseek-flash` per 1M: peak $0.30 in / $1.20 out / $0.006 cache hit; off-peak $0.15 / $0.60 / $0.003 ([LiteLLM](https://docs.litellm.ai/docs/providers/deepseek)) |
| Mastra | `deepseek/deepseek-flash` string with automatic `DEEPSEEK_API_KEY`, or the raw endpoint object `{ url: 'https://api.deepseek.com', id: 'deepseek/deepseek-flash', apiKey }`; provider options `thinking` and `reasoningEffort` ([DeepSeek page](https://mastra.ai/models/providers/deepseek)) |
| Vercel AI SDK | `@ai-sdk/openai-compatible` **3.0.79** (dist-tags `ai-v5` 1.0.59, `ai-v6` 2.0.87): `createOpenAICompatible({ name, apiKey, baseURL })` then `provider.completionModel('<id>')` — custom ids are positional strings, no registry update needed ([npm](https://www.npmjs.com/package/@ai-sdk/openai-compatible)) |
| OpenRouter | one OpenAI-compatible endpoint `https://openrouter.ai/api/v1` serving 31 DeepSeek ids (e.g. `deepseek/deepseek-v4.1-flash-1017`, alias `~deepseek/deepseek-flash-latest`) ([OpenRouter](https://openrouter.ai/deepseek)) |
| pi-ai | built-in provider via `DEEPSEEK_API_KEY`, or a custom `Model<'openai-completions'>` literal with `baseUrl`, a `cost: {input, output, cacheRead, cacheWrite}` table and `compat` flags — `thinkingFormat: 'deepseek'` sends `thinking: {type}` + `reasoning_effort`, and `requiresReasoningContentOnAssistantMessages` is auto-detected ([npm](https://www.npmjs.com/package/@mariozechner/pi-ai)) |

Practical implication for a platform: DeepSeek's token pricing is cheap enough that per-agent model tiering (small model for routing/classification agents, `deepseek-v4-pro` for reasoning agents) is the main cost lever, and every framework above supports it — but only Mastra, VoltAgent and pi-ai expose *cost per call* from the runtime itself.

---

## 7. Telemetry and OTel GenAI: not stable yet

The conventions now live in **`open-telemetry/semantic-conventions-genai`** (created 2026‑05‑05), whose README header reads `Status: [Development]` and whose `githubRepo` reports `latestRelease: null` — there is no spec release to pin ([README](https://github.com/open-telemetry/semantic-conventions-genai/blob/HEAD/docs/gen-ai/README.md), [repo](https://github.com/open-telemetry/semantic-conventions-genai)). Span shape: retrieval spans are CLIENT, named `{gen_ai.operation.name} {gen_ai.data_source.id}`, with `gen_ai.operation.name` Required, `gen_ai.request.model` Conditionally Required "If available", `gen_ai.retrieval.top_k` Recommended — all at Development stability, with only inherited attributes (`error.type`, `server.address`, `server.port`) Stable ([gen-ai-spans](https://github.com/open-telemetry/semantic-conventions-genai/blob/HEAD/docs/gen-ai/gen-ai-spans.md)). The `gen_ai.provider.name` enum **includes `deepseek`** alongside anthropic/openai/aws.bedrock/groq/mistral/moonshot_ai/x_ai. Per Dash0's mid-2026 reference, inference spans are named `{gen_ai.operation.name} {gen_ai.request.model}` (so a GPT‑4 call is literally `chat gpt-4`), attribute names can be renamed with no deprecation window, prompt/response content is not a span attribute (it goes in the opt-in `gen_ai.client.inference.operation.details` event), and Traceloop's OpenLLMetry shipped its own span shape before the conventions existed and hasn't fully converged — producing two vocabularies in one trace ([Dash0](https://www.dash0.com/knowledge/opentelemetry-genai-semantic-conventions-explained)).

Cost handling differs by design: **Mastra** derives cost from spans at span end; **pi-ai** returns `usage.cost.total` inline per message and emits `pi.ai.tokens`/`pi.ai.cost`; **LiteLLM** applies a built-in price table with time-of-day rules; **Langfuse** ships prices for popular models and infers cost from token counts or accepts explicit `usage_details` ([Langfuse](https://langfuse.com/docs/observability/features/token-and-cost-tracking)). For a multi-agent platform, export both a token metric and an explicit cost metric per agent id, because only Mastra and pi-ai guarantee one model-call span = one usage record — the others depend on the backend's price table.

---

## 8. Evals, CI gating, durability (what is actually verified)

**Evals/CI.** Verified shipping today: Mastra (Agent-level `scorers` with ratio sampling + `runEvals` with `gates`/thresholds + Studio trace scoring, so a CI gate is `verdict: 'failed'`), VoltAgent (`createExperiment`/`passCriteria` such as `passRate` min 0.95, `volt eval run` CLI), and Pi (`fauxProvider` scripted responses for deterministic tests plus the `@earendil-works/pi-evals` workspace). The OpenAI Agents SDK has no in-SDK eval framework, the Claude Agent SDK documents none, and LangSmith's evaluation API was not retrieved. If per-agent regression gating is a requirement, plan on adding external eval tooling on top of anything except Mastra/VoltAgent/Pi.

**Durability.** Verified mechanisms: SDK session stores + `SessionStore` adapters + fork (OpenAI `SQLite`/Redis/SQLAlchemy/Mongo/Dapr; Claude transcripts + `resume`/`forkSession`); JSONL session trees with fork/clone/compact and RPC `agent_settled` (Pi); workflow `resumeStream`/`restart` and `Memory` scoping (Mastra); `restart()`/`timeTravel()` with persisted run history (VoltAgent); checkpointers (`langgraph-checkpoint-postgres` 3.2.0, 25 MB checkpoints on the managed runtime); one shared background server owning sessions plus a Durable Object alarm that resumes interrupted work (OpenCode 2 + Cloudflare); and Letta's agent/conversation/session split, which explicitly **does not replay events missed while disconnected** — clients must reconcile with `listMessages()`/`bootstrapState()`. Temporal, Restate, Inngest and Trigger.dev were **not verified** in this run and no claims are made about them.

---

## 9. What people who actually consolidated learned

No source reviewed uses the phrase "modular monolith of agents"; two opposite patterns appear under that label.

**Pattern A — subtract agents.** Mario Zechner's write-up is the primary document: he left Claude Code because it *"turned into a spaceship with 80% of functionality I have no use for"* and *"the system prompt and tools also change on every release, which breaks my workflows and changes model behavior"*, then built Pi as 4 tools (read/write/edit/bash) with prompt + tool definitions *"below 1000 tokens"*, no MCP, no sub-agents, no plan mode, no compaction. His sharing pattern is the one worth stealing: instead of MCP servers — *"Playwright MCP (21 tools, 13.7k tokens) or Chrome DevTools MCP (26 tools, 18k tokens) … That's 7-9% of your context window gone before you even start working"* — keep a repo of CLI tools each with a README the agent reads on demand (progressive disclosure), and he calls parallel subagent spawning *"an anti-pattern in my book"* ([Zechner](https://mariozechner.at/posts/2025-11-30-pi-coding-agent/)). Armin Ronacher independently corroborates the design: pi has *"the shortest system prompt of any agent that I'm aware of"*, and his `/control` extension lets one Pi agent prompt another — *"a simple multi-agent system without complex orchestration"*; he also names the technical reason MCP fights cache reuse: tool definitions *"need to be loaded into the system context … on session start,"* which makes hot tool changes destructive ([Ronacher](https://lucumr.pocoo.org/2026/1/31/pi/)).

Numbers Station (published on Alation's blog) deleted *"most of the hierarchical multi-agent architecture we had built just a year earlier"* — a planner plus specialist subagents — for one reasoning agent, because there was no seam to fix and *"simply swapping in better models delivered no lift because the architecture couldn't tap their strengths"*. On their hardest SQL tasks: hierarchical 59.87% accuracy / 22.06 s; advanced-reasoning multi-agent 72.37% / 32.04 s; single o3 agent 77.63% / 39.91 s ([Alation](https://www.alation.com/blog/delete-all-the-code-why-we-ditched-our-multi-agent-architecture-for-a-leaner/)).

The most quantitative postmortem cut a conductor/generator/reviewer harness to one delivery agent plus one independent reviewer: median 19 role switches → 4, median **31.8M → 5.9M subagent tokens**, mean 2.4 h → median 79 min, 12,500 lines removed, instructions per agent 3,333 → 1,630, sensors 223 → 170, model contexts per issue from more than a dozen to between two and six. Its headline negative result: across 11 traces, the handoff protocols and "evidence rituals" caught **0 attributable defects**, while deterministic boundary scripts and the single fresh-context reviewer caught the real problems. It names the failure mode *"harness debt"* — rules are scars from old incidents, arrive faster than they leave — and lists model changes (Fable 5 / GPT‑5.6) pushing 30‑minute issues to 2+ hours as the trigger to re-measure ([multiagentai](https://blog.multiagentai.co/agents/harness-subtraction/)).

**Pattern B — centralize the runtime, keep many agents.** Cloudflare's 11-month account is the strongest enterprise case: one `opencode auth login` plus a `.well-known/opencode` discovery endpoint pushes providers, MCP servers, agents, commands and permissions to every engineer; agents/commands are markdown+YAML compiled into one JSON config so *"every new session picks up the latest version automatically"*; routing everything through a single proxy Worker "from day one" later enabled per-user attribution, model catalog management and permission enforcement without touching client configs. Measured: 3,683 active users (60% of the company, 93% of R&D) of ~6,100 employees, 47.95M AI messages, 295 teams, 20.18M AI Gateway requests / 241.37B tokens in 30 days, 4-week average merge requests from ~5,600 to over 8,700/week — **while** the AI Code Reviewer runs a multi-agent coordinator that classifies MRs by risk tier and delegates to code-quality, security, codex-compliance, documentation, performance and release-impact agents (100% reviewer coverage, 5.47M requests / 24.77B tokens in 30 days). The reusable-context lesson: their GitLab MCP server's 34 tools consumed *"roughly 15,000 tokens of context window per request"* (7.5% of a 200K window), so Code Mode collapsed 13 production MCP servers / 182+ tools into two client-visible tools; and a stale `AGENTS.md` *"can be worse than no file at all"* across ~3,900 repos ([Cloudflare](https://blog.cloudflare.com/internal-ai-engineering-stack/)).

Anthropic's two posts are not one consistent position. The 2024 guidance says the most successful implementations *"weren't using complex frameworks"*, that frameworks *"often create extra layers of abstraction"*, and to *"not hesitate to reduce abstraction layers"* ([building effective agents](https://www.anthropic.com/engineering/building-effective-agents)). The 2025 research-system post reports multi-agent beating single-agent by **90.2%** on their internal eval — at ~4× chat tokens for agents and ~**15×** for multi-agent systems — warns *"most coding tasks involve fewer truly parallelizable tasks than research"*, and gives the best evidence for shared tool libraries: a tool-testing agent rewriting a tool description produced *"a 40% decrease in task completion time for future agents"* ([multi-agent research system](https://www.anthropic.com/engineering/multi-agent-research-system)).

Secondary reporting frames the harness debate as partly economic: one six-harness comparison concluded *"I love Pi, but I can't use it"* because Claude subscription credits cannot be spent through third-party harnesses, and a Terminal-Bench 2.0 run across open-weight models put Pi-Code ahead of Cline on glm-5.1 (51.7% vs 49.4%) and minimax-m2.7 (46.0% vs 42.9%) but behind on kimi-k2.6 (45.5% vs 55.1%) and deepseek-v4-pro (52.9% vs 53.9%) — second-hand ([yage.ai](https://yage.ai/share/pi-coding-agent-locked-out-en-20260518.html)). In the portion of the Hacker News thread that was read, discussion centred on session-tree/context-reuse techniques (loading a `MIND_MAP.md` graph with inline citations to cut context waste) and on permission prompts as "security theater" versus OS-level sandboxing — not on agent-count consolidation ([HN](https://news.ycombinator.com/item?id=46844822)).

---

## 10. What breaks in practice

- **Prompt/tool churn is the top complaint** in the one first-person account: system prompt and tool definitions changing every release "breaks my workflows and changes model behavior" (Zechner). Any platform that centralizes prompts across dozens of agents inherits that risk — version the prompt bundle.
- **Tool definitions are a context tax**, not free reuse: 21-tool Playwright MCP = 13.7k tokens, 34-tool GitLab MCP ≈ 15k tokens/request; both Zechner and Cloudflare converge on indirection (README-on-demand / Code Mode) rather than dumping schemas per session.
- **MCP load-time and output ceilings** in the Claude Agent SDK (30 s `MCP_TIMEOUT` on uncached tool lists, 25,000-token result spill, no interactive OAuth) are the classic first-week surprise when a platform registers many servers.
- **Cost accounting silently under-reports** unless you know the trap: Claude's `maxBudgetUsd` is a client-side estimate and resumed sessions don't count; OpenAI's tracing is unavailable under ZDR; Mastra only records usage on chat spans; LiteLLM/any-LLM adapters may not populate usage unless `include_usage` is set.
- **Version/adoption traps**: OpenCode 2 is not `opencode-ai` (1.19.4 vs `@opencode/*` 2.1.4) and GitHub tags track 1.x; Pi's packages changed scope and the old `@mariozechner/*` names are deprecated; LangGraph Platform no longer exists under that name; Letta's repo release stream (0.16.8) and its CLI/Docker stream (0.34.x) use different numbering.
- **Governance gaps**: Pi has no permission system (containers required) and auto-closes new-contributor issues; OpenCode 2 dropped V1's `openTelemetry` setting and replaced per-field permissions with a single last-match-wins array where unmatched actions default to `ask` and `external_directory` is allowed by default; Claude's skills have no programmatic registration path; VoltAgent's workflows are labelled Preview.

---

## Unverified / not checked

Deployment and `mastra dev`/deployers, Mastra GitHub issue threads and community-reported pain points, the Mastra metrics reference (concrete metric names), the generated provider/model literal list, and Mastra's embedding custom-provider docs and OpenRouter page were not verified. Pi's `cli.md`, the full text of pi-ai's "Cross-Provider Handoffs"/"Context Serialization" sections, third-party agents built on pi-agent-core, and user-reported criticisms of Pi were not verified beyond the README's own limitations. OpenCode 2 session storage/durability internals, its share feature, and per-session cost beyond a snippet were not verified. Claude's OTel metric reference, the Agent SDK observability page, the SDK permissions page, the plugins/marketplace authoring reference, the enterprise deployment matrix, the LLM-gateway/non-Claude routing policy page, and the licence text behind "SEE LICENSE IN README.md" were not read. VoltOps/LangSmith pricing, LangGraph multi-agent patterns and `create_react_agent` vs `create_agent` naming, LangGraph persistence docs, LangSmith `evaluate()`, and independent third-party reviews of VoltAgent/LangGraph were not retrieved; no LangGraph Platform GA date is asserted because sources conflict. Goose recipe/summon mechanics rest on search snippets; Amp and GitHub Copilot custom agents were not researched at all. DeepSeek's own per-1M price table did not render, so its rates are taken from LiteLLM. OTel GenAI's client-inference, agent-span, metrics and events sections (beyond retrievals) were second-hand from Dash0, and OpenLLMetry/OpenInference/Braintrust/LangSmith/Phoenix cost-tracking specifics were not verified. Eval tooling other than Mastra/VoltAgent/Pi and durable-execution products (Temporal, Restate, Inngest, Trigger.dev) were not verified; a practitioner OpenCode multi-agent write-up (dotzlaw.com) and the Microsoft CAF single-vs-multi-agent guidance were not read; the HN thread was read only in part.


## Unverified

- Mastra observability/tracing docs (span hierarchy, OTel exporter config, token/usage metrics) as of the first pass — Not retrieved in full in that pass; only npm metadata for @mastra/observability was verifiable then, so no claims were made about OTel export, spans or metrics at that point. Later passes did retrieve the observability/OTel pages, which are what the report relies on.
- Mastra scores/observability/logs endpoint tables in the server routes reference — Retrieved only in part (truncated before the trailing sections); the agent, workflow, tool, memory, vector and dataset tables were read, later tables were not. (The page itself WAS retrieved elsewhere in this run and backs citations — this entry records an unverified topic, not an unusable source.)
- Mastra deployment docs, mastra dev CLI behaviour and deployers (Vercel/Netlify/Cloudflare/Mastra platform) — Not reached; deployers are known only as link titles in the docs index and were never read.
- Mastra GitHub issues on multi-agent tool reuse, version churn or server deployment (pain points) — Not reached; the repository page confirms 618 open issues but no issue thread was read, so no community pain-point claims are asserted.
- Mastra @mastra/observability internal barrels (config.ts, exporters/index.ts, span_processors/index.ts) — Fetch not executed before tool access ended; individual barrel export lists were not read.
- Mastra generated provider/model literal list — 404 at that path; the generated artifact is provider-types.generated.d.ts per references in provider-registry.ts, which was not read, so enumerated literals were not independently verified.
- Exact @mastra/core source at the 1.79.0 release tag — githubFile rejected the tag ref as invalid, so source-code claims rest on the repo default branch (HEAD), not the exact 1.79.0 tag.
- Mastra runEvals reference trailing sections — Page text was truncated at 15,288 of 18,332 characters, so the trailing sections were not read. (The page itself WAS retrieved elsewhere in this run and backs citations — this entry records an unverified topic, not an unusable source.)
- Mastra live scorer execution path and MastraScorers type in code — Tool access ended before this file could be read; the record shape and runtime dispatch/sampling implementation were not verified in code.
- pi-ai README sections 'Cross-Provider Handoffs' and 'Context Serialization' in full — The file was truncated at 80,000 of 107,467 characters, so only the table-of-contents presence and intro sentence were read. (The page itself WAS retrieved elsewhere in this run and backs citations — this entry records an unverified topic, not an unusable source.)
- Agent SDK observability page (three OTel signals, per-signal switches) — Not retrieved in full — only a search snippet was available, so telemetry details are provisional.
- Claude Code LLM gateway / routing to non-Claude models through a gateway — Not retrieved; the quoted policy sentence comes from a search snippet, not a fetched page, so the non-Claude routing claim is not asserted in the report.
- Enterprise deployment matrix (Bedrock / Claude Platform on AWS / Google Cloud Agent Platform / Microsoft Foundry) and provider base-URL variables — Only search snippets read; the full table and per-provider setup steps were not fetched.
- Claude Code plugins / marketplace authoring mechanics — Only a search snippet was read; the plugin authoring reference was not fetched.
- LangGraph multi-agent patterns (supervisor/swarm) and create_react_agent vs create_agent naming — URL identified from a fetched docs page but the fetch budget expired, so nothing about it is asserted.
- LangGraph persistence/checkpointer docs (thread_id, time travel, SqliteSaver/PostgresSaver) — Referenced by fetched docs but never retrieved; only package-level evidence (langgraph-checkpoint-postgres 3.2.0) was verified.
- LangSmith evaluate()/datasets evaluator API surface — No LangSmith evaluation docs page was retrieved before the budget expired; only langsmith package metadata was verified.
- LangSmith agent-server page partial read — Page truncated at 3,111 of 11,376 characters, so persistence/task-queue sections and anything after the 'Graphs' subsection were not read. (The page itself WAS retrieved elsewhere in this run and backs citations — this entry records an unverified topic, not an unusable source.)
- Independent third-party reviews of VoltAgent and LangGraph (pain points, lock-in, cost) — Several candidate review/comparison pages appeared in search results but none could be fetched before the tool budget expired; no third-party pain-point claims are made.
- LangGraph Platform GA date — Linked from a fetched marketing page but not retrieved; sources conflict, so no GA date is asserted.
- Goose recipe reference schema and Summon extension mechanics — Page fetch refused: page-text budget exhausted; only search snippets (field names extensions/parameters/sub_recipes) are available.
- Goose Summon extension (MCP) — delegating to subagents, recipes and agent definitions — Page fetch refused: page-text budget exhausted; details rest on search-result snippets only.
- Letta ADE (Agent Development Environment) current status — Only a search snippet was seen (it states the original ADE is deprecated and replaced by the ADE inside chat.letta.com); the page itself was not fetched.
- Letta vLLM provider type in the model endpoint enum — Only seen in search snippets, not fetched; the fetched models-configuration page lists DeepSeek and a generic 'OpenAI-compatible API' provider but does not name vLLM.
- DeepSeek official Models & Pricing table (per-model context windows and price rows) — Fetched but the rendered text returned only the docs' generic intro block rather than the pricing table, so concrete per-1M rates were taken from LiteLLM instead and DeepSeek's own figures are unverified.
- Evals tooling beyond Mastra/VoltAgent/Pi (LangSmith evaluators, Braintrust, promptfoo, OpenAI Evals, Inspect AI, DeepEval) — Tool access was revoked mid-run; no eval documentation or registry entry could be fetched, so no package name, version or capability claim is made.
- Durable execution platforms (Temporal, Restate, Inngest, Trigger.dev) — Tool access revoked; no documentation or registry lookup could be performed, so their durability guarantees are unverified and unreported rather than estimated.
- Vercel AI SDK createOpenAICompatible usage as documented on ai-sdk.dev — Citation dropped: this URL was never retrieved in the run, so the claim rests on the @ai-sdk/openai-compatible registry page only.
- Google ADK, Mastra, VoltAgent, LangGraph user stories and Reddit/Lobsters harness comparisons — Search engine quota was exhausted after six queries, so these sources could not be located at all. Absence of findings is a tooling limit, not evidence that such write-ups do not exist.
- Hacker News discussion thread on Zechner's pi post (later comments) — Truncated at roughly 14,047 of 51,900 characters; the majority of comments were not read, so no conclusion can be drawn about consolidation reports appearing later in the thread. (The page itself WAS retrieved elsewhere in this run and backs citations — this entry records an unverified topic, not an unusable source.)
- Alation / Numbers Station post publication date and named author — The fetched page text carried no visible byline or date; the 2025-09-01 date comes from search-result metadata only and the author is inferred from the post's first-person reference. (The page itself WAS retrieved elsewhere in this run and backs citations — this entry records an unverified topic, not an unusable source.)
- Claude Code exports OTel metrics, events and optional traces gated by CLAUDE_CODE_ENABLE_TELEMETRY=1, including claude_code.token.usage and claude_code.cost.usage in USD (search-snippet level). — Citation dropped: this run reported the same URL as unverifiable, so it cannot support a claim.
- Goose recipes package extensions, prompts and settings, with a field list containing extensions, parameters and sub_recipes (search-snippet level). — Citation dropped: this run reported the same URL as unverifiable, so it cannot support a claim.
- Per goose docs snippets, a 'Summon' MCP extension loads recipes and agent definitions to delegate to subagents, and v1.25.0 unified subagents and Skills into it. — Citation dropped: this run reported the same URL as unverifiable, so it cannot support a claim.


## Sources

- https://github.com/mastra-ai/mastra
- https://www.npmjs.com/package/@mastra/core
- https://registry.npmjs.org/%40mastra/core
- https://mastra.ai/docs/agents/overview
- https://mastra.ai/docs/agents/tools
- https://mastra.ai/reference/tools/create-tool
- https://mastra.ai/docs/workflows/overview
- https://mastra.ai/docs/memory/overview
- https://mastra.ai/docs/evals/built-in-scorers
- https://mastra.ai/llms.txt
- https://mastra.ai/docs/server/overview.md
- https://www.npmjs.com/package/@mastra/observability
- https://registry.npmjs.org/%40mastra/observability
- https://mastra.ai/reference/server/routes.md
- https://www.npmjs.com/package/@mariozechner/pi-agent-core
- https://registry.npmjs.org/%40mariozechner/pi-agent-core
- https://github.com/badlogic/pi-mono
- https://www.npmjs.com/package/@mariozechner/pi-ai
- https://registry.npmjs.org/%40mariozechner/pi-ai
- https://www.npmjs.com/package/@earendil-works/pi-agent-core
- https://registry.npmjs.org/%40earendil-works/pi-agent-core
- https://www.npmjs.com/package/@earendil-works/pi-ai
- https://registry.npmjs.org/%40earendil-works/pi-ai
- https://www.npmjs.com/package/@mariozechner/pi
- https://registry.npmjs.org/%40mariozechner/pi
- https://github.com/earendil-works/pi/blob/HEAD/package.json
- https://raw.githubusercontent.com/earendil-works/pi/HEAD/package.json
- https://github.com/earendil-works/pi/blob/HEAD/README.md
- https://raw.githubusercontent.com/earendil-works/pi/HEAD/README.md
- https://github.com/earendil-works/pi/blob/HEAD/packages/agent/README.md
- https://raw.githubusercontent.com/earendil-works/pi/HEAD/packages/agent/README.md
- https://github.com/earendil-works/pi/blob/HEAD/packages/ai/README.md
- https://raw.githubusercontent.com/earendil-works/pi/HEAD/packages/ai/README.md
- https://github.com/earendil-works/pi/blob/HEAD/packages/coding-agent/docs/sdk.md
- https://raw.githubusercontent.com/earendil-works/pi/HEAD/packages/coding-agent/docs/sdk.md
- https://github.com/earendil-works/pi/blob/HEAD/packages/coding-agent/docs/rpc.md
- https://raw.githubusercontent.com/earendil-works/pi/HEAD/packages/coding-agent/docs/rpc.md
- https://github.com/earendil-works/pi/blob/HEAD/packages/coding-agent/docs/extensions.md
- https://raw.githubusercontent.com/earendil-works/pi/HEAD/packages/coding-agent/docs/extensions.md
- https://github.com/earendil-works/pi/blob/HEAD/packages/coding-agent/docs/skills.md
- https://raw.githubusercontent.com/earendil-works/pi/HEAD/packages/coding-agent/docs/skills.md
- https://github.com/earendil-works/pi/blob/HEAD/packages/coding-agent/docs/sessions.md
- https://raw.githubusercontent.com/earendil-works/pi/HEAD/packages/coding-agent/docs/sessions.md
- https://www.npmjs.com/package/opencode-ai
- https://registry.npmjs.org/opencode-ai
- https://github.com/sst/opencode
- https://opencode.ai/docs/
- https://github.com/anomalyco/opencode/blob/HEAD/services/www/src/docs/content/migrate-v1.mdx
- https://raw.githubusercontent.com/anomalyco/opencode/HEAD/services/www/src/docs/content/migrate-v1.mdx
- https://opencode.ai/v2/docs
- https://www.npmjs.com/package/@opencode/client
- https://registry.npmjs.org/%40opencode/client
- https://www.npmjs.com/package/@opencode-ai/sdk
- https://registry.npmjs.org/%40opencode-ai/sdk
- https://opencode.ai/v2/docs/build/sdk
- https://opencode.ai/v2/docs/agents
- https://www.npmjs.com/package/@opencode/plugin
- https://registry.npmjs.org/%40opencode/plugin
- https://www.npmjs.com/package/@opencode/sdk
- https://registry.npmjs.org/%40opencode/sdk
- https://opencode.ai/v2/docs/skills
- https://opencode.ai/v2/docs/config
- https://opencode.ai/v2/docs/build/plugins
- https://opencode.ai/v2/docs/permissions
- https://opencode.ai/v2/docs/instructions
- https://opencode.ai/v2/docs/providers
- https://opencode.ai/v2/docs/cli
- https://developers.cloudflare.com/agents/harnesses/opencode/index.md
- https://opencode.ai/v2/docs/api
- https://pypi.org/project/claude-agent-sdk/
- https://pypi.org/pypi/claude-agent-sdk/json
- https://www.npmjs.com/package/@anthropic-ai/claude-agent-sdk
- https://registry.npmjs.org/%40anthropic-ai/claude-agent-sdk
- https://github.com/anthropics/claude-agent-sdk-typescript
- https://github.com/anthropics/claude-agent-sdk-python
- https://docs.claude.com/en/api/agent-sdk/overview
- https://code.claude.com/docs/en/agent-sdk/typescript
- https://code.claude.com/docs/en/agent-sdk/subagents
- https://code.claude.com/docs/en/agent-sdk/skills
- https://code.claude.com/docs/en/agent-sdk/mcp
- https://code.claude.com/docs/en/agent-sdk/sessions
- https://code.claude.com/docs/en/agent-sdk/python
- https://www.npmjs.com/package/@langchain/langgraph
- https://registry.npmjs.org/%40langchain/langgraph
- https://www.npmjs.com/package/@voltagent/core
- https://registry.npmjs.org/%40voltagent/core
- https://pypi.org/project/langchain/
- https://pypi.org/pypi/langchain/json
- https://pypi.org/project/langgraph/
- https://pypi.org/pypi/langgraph/json
- https://pypi.org/project/langgraph-checkpoint-postgres/
- https://pypi.org/pypi/langgraph-checkpoint-postgres/json
- https://pypi.org/project/langsmith/
- https://pypi.org/pypi/langsmith/json
- https://github.com/VoltAgent/voltagent
- https://github.com/langchain-ai/langgraph
- https://www.npmjs.com/package/@voltagent/server-core
- https://registry.npmjs.org/%40voltagent/server-core
- https://www.npmjs.com/package/@voltagent/vercel-ai
- https://registry.npmjs.org/%40voltagent/vercel-ai
- https://voltagent.dev/docs/agents/sub-agents/
- https://voltagent.dev/docs/workflows/overview/
- https://voltagent.dev/docs/getting-started/providers-models/
- https://voltagent.dev/observability-docs/
- https://voltagent.dev/docs/observability/overview/
- https://voltagent.dev/docs/agents/tools/
- https://voltagent.dev/docs/agents/overview/
- https://www.npmjs.com/package/@voltagent/evals
- https://registry.npmjs.org/%40voltagent/evals
- https://voltagent.dev/docs/evals/overview/
- https://docs.langchain.com/oss/python/langgraph/overview
- https://docs.langchain.com/langsmith/deployment
- https://docs.langchain.com/langsmith/changelog.md
- https://www.langchain.com/langsmith/deployment
- https://docs.langchain.com/llms.txt
- https://docs.langchain.com/langsmith/agent-server.md
- https://pypi.org/project/openai-agents/
- https://pypi.org/pypi/openai-agents/json
- https://pypi.org/project/letta/
- https://pypi.org/pypi/letta/json
- https://www.npmjs.com/package/@openai/agents
- https://registry.npmjs.org/%40openai/agents
- https://www.npmjs.com/package/@letta-ai/letta-client
- https://registry.npmjs.org/%40letta-ai/letta-client
- https://github.com/openai/openai-agents-python
- https://github.com/letta-ai/letta
- https://github.com/openai/openai-agents-js
- https://github.com/block/goose
- https://openai.github.io/openai-agents-python/sessions/
- https://openai.github.io/openai-agents-python/models/
- https://openai.github.io/openai-agents-python/tracing/
- https://openai.github.io/openai-agents-python/mcp/
- https://docs.letta.com/reference/faq
- https://docs.letta.com/v1-sdk/concepts/agent-file
- https://hub.docker.com/r/letta/letta
- https://hub.docker.com/v2/repositories/letta/letta/tags?page_size=25&ordering=last_updated
- https://www.npmjs.com/package/@letta-ai/letta-agent-sdk
- https://registry.npmjs.org/%40letta-ai/letta-agent-sdk
- https://docs.letta.com/configuration/models/index.md
- https://docs.letta.com/v1-sdk/memory/memory-blocks
- https://docs.letta.com/self-hosting/index.md
- https://docs.letta.com/agent-sdk/sessions
- https://docs.letta.com/configuration/subagents/index.md
- https://docs.letta.com/configuration/skills
- https://www.npmjs.com/package/@ai-sdk/openai-compatible
- https://registry.npmjs.org/%40ai-sdk/openai-compatible
- https://github.com/mastra-ai/mastra/blob/main/packages/_test-utils/README.md
- https://github.com/mastra-ai/mastra/blob/main/docs/src/content/en/models/embeddings.mdx
- https://github.com/mastra-ai/mastra/blob/main/docs/src/content/en/reference/configuration.mdx
- https://github.com/mastra-ai/mastra/blob/main/docs/src/content/en/models/gateways/custom-gateways.mdx
- https://ai-sdk.dev/providers/openai-compatible-providers
- https://ai-sdk.dev/providers/openai-compatible-providers/nim
- https://ai-sdk.dev/providers/openai-compatible-providers/clarifai
- https://api-docs.deepseek.com/quick_start/pricing
- https://api-docs.deepseek.com/guides/reasoning_model
- https://api-docs.deepseek.com/
- https://api-docs.deepseek.com/updates
- https://docs.litellm.ai/docs/providers/deepseek
- https://openrouter.ai/deepseek
- https://mastra.ai/models/providers/deepseek
- https://mastra.ai/models
- https://github.com/open-telemetry/semantic-conventions-genai/blob/HEAD/docs/gen-ai/README.md
- https://raw.githubusercontent.com/open-telemetry/semantic-conventions-genai/HEAD/docs/gen-ai/README.md
- https://www.dash0.com/knowledge/opentelemetry-genai-semantic-conventions-explained
- https://github.com/open-telemetry/semantic-conventions-genai
- https://github.com/open-telemetry/semantic-conventions-genai/blob/HEAD/docs/gen-ai/gen-ai-spans.md
- https://raw.githubusercontent.com/open-telemetry/semantic-conventions-genai/HEAD/docs/gen-ai/gen-ai-spans.md
- https://yage.ai/share/pi-coding-agent-locked-out-en-20260518.html
- https://mariozechner.at/posts/2025-11-30-pi-coding-agent/
- https://lucumr.pocoo.org/2026/1/31/pi/
- https://www.anthropic.com/engineering/multi-agent-research-system
- https://blog.cloudflare.com/internal-ai-engineering-stack/
- https://blog.multiagentai.co/agents/harness-subtraction/
- https://www.alation.com/blog/delete-all-the-code-why-we-ditched-our-multi-agent-architecture-for-a-leaner/
- https://www.anthropic.com/engineering/building-effective-agents
- https://news.ycombinator.com/item?id=46844822
- https://github.com/mastra-ai/mastra/blob/main/docs/src/content/en/docs/memory/semantic-recall.mdx
- https://mastra.ai/models/gateways/custom-gateways
- https://mastra.ai/blog/model-router
- https://github.com/mastra-ai/mastra/blob/HEAD/packages/core/src/llm/index.ts
- https://raw.githubusercontent.com/mastra-ai/mastra/HEAD/packages/core/src/llm/index.ts
- https://github.com/mastra-ai/mastra/blob/HEAD/packages/core/src/llm/model/shared.types.ts
- https://raw.githubusercontent.com/mastra-ai/mastra/HEAD/packages/core/src/llm/model/shared.types.ts
- https://github.com/mastra-ai/mastra/blob/HEAD/packages/core/src/llm/model/provider-registry.ts
- https://raw.githubusercontent.com/mastra-ai/mastra/HEAD/packages/core/src/llm/model/provider-registry.ts
- https://github.com/mastra-ai/mastra/blob/HEAD/packages/core/src/llm/model/resolve-model.ts
- https://raw.githubusercontent.com/mastra-ai/mastra/HEAD/packages/core/src/llm/model/resolve-model.ts
- https://github.com/mastra-ai/mastra/blob/HEAD/packages/core/src/llm/model/router.ts
- https://raw.githubusercontent.com/mastra-ai/mastra/HEAD/packages/core/src/llm/model/router.ts
- https://raw.githubusercontent.com/mastra-ai/mastra/HEAD/packages/core/src/agent/types.ts
- https://mastra.ai/blog/model-fallback
- https://github.com/mastra-ai/mastra/blob/HEAD/packages/core/src/agent/types.ts
- https://github.com/mastra-ai/mastra/blob/main/docs/src/content/en/models/index.mdx
- https://github.com/mastra-ai/mastra/blob/main/docs/src/content/en/models/providers/oci.mdx
- https://github.com/mastra-ai/mastra/blob/main/docs/src/content/en/reference/cli/mastra.mdx
- https://github.com/mastra-ai/mastra/blob/main/docs/src/content/en/models/providers/ebcloud.mdx
- https://github.com/mastra-ai/mastra/blob/main/docs/src/content/en/docs/evals/overview.mdx
- https://github.com/mastra-ai/mastra/blob/main/docs/src/content/en/reference/agents/listScorers.mdx
- https://github.com/mastra-ai/mastra/blob/main/explorations/ralph-wiggum-loop-integration.md
- https://github.com/mastra-ai/mastra/blob/main/docs/src/content/en/reference/evals/run-evals.mdx
- https://github.com/mastra-ai/mastra/blob/main/docs/src/content/en/reference/client-js/agents.mdx
- https://mastra.ai/docs/evals/overview
- https://mastra.ai/reference/agents/agent
- https://mastra.ai/reference/migrations/upgrade-to-v1/evals
- https://github.com/mastra-ai/mastra/blob/HEAD/packages/core/src/evals/types.ts
- https://raw.githubusercontent.com/mastra-ai/mastra/HEAD/packages/core/src/evals/types.ts
- https://mastra.ai/reference/agents/listScorers
- https://github.com/mastra-ai/mastra/blob/HEAD/packages/core/src/evals/index.ts
- https://raw.githubusercontent.com/mastra-ai/mastra/HEAD/packages/core/src/evals/index.ts
- https://mastra.ai/reference/evals/run-evals.md
- https://github.com/mastra-ai/mastra/blob/main/docs/src/content/en/reference/migrations/upgrade-to-v1/tracing.mdx
- https://github.com/mastra-ai/mastra/blob/main/docs/src/content/en/reference/observability/tracing/exporters/otel.mdx
- https://github.com/mastra-ai/mastra/blob/main/docs/src/content/en/integrations/observability/opentelemetry.mdx
- https://github.com/mastra-ai/mastra/blob/main/examples/inngest/README.md
- https://www.npmjs.com/package/@mastra/otel-exporter
- https://registry.npmjs.org/%40mastra/otel-exporter
- https://www.npmjs.com/package/@mastra/otel-bridge
- https://registry.npmjs.org/%40mastra/otel-bridge
- https://mastra.ai/integrations/observability/opentelemetry
- https://mastra.ai/reference/observability/tracing/bridges/otel
- https://mastra.ai/docs/observability/overview
- https://github.com/mastra-ai/mastra/blob/HEAD/package.json
- https://raw.githubusercontent.com/mastra-ai/mastra/HEAD/package.json
- https://unpkg.com/@mastra/observability@1.21.0/dist/index.d.ts
- https://mastra.ai/docs/observability/tracing/overview
- https://unpkg.com/@mastra/otel-exporter@1.4.9/dist/index.d.ts
- https://github.com/mastra-ai/mastra/tree/main/observability
- https://github.com/mastra-ai/mastra/blob/HEAD/observability/mastra/package.json
- https://raw.githubusercontent.com/mastra-ai/mastra/HEAD/observability/mastra/package.json
- https://github.com/mastra-ai/mastra/blob/HEAD/observability/mastra/src/index.ts
- https://raw.githubusercontent.com/mastra-ai/mastra/HEAD/observability/mastra/src/index.ts
