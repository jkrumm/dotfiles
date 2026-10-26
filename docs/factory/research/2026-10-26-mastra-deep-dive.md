# Mastra deep dive — capability-layer evaluation (research-gateway job 97fd9c95, deep, 2026-10-26)

> Status ok. Hands-on counterpart: `spikes/07-stations/capability/REPORT.md`.

## Bottom line

**createTool** — `createTool` returns a `Tool` whose schemas are consumed as Standard Schema / Standard JSON Schema (zod is only a peer dependency, `^3.25.0 || ^4.0.0`, verified working with Zod, Valibot and ArkType), the execute callback is `execute(inputData, context)` — **not** the 0.x `execute({ context })` shape — with `requestContext`, `abortSignal`, `observe`, `agent`, `workflow`, `mcp`, `workspace` and `writer` on the context, a failed `outputValidation` **returns** a `ValidationError` object rather than throwing, the same tool is callable from plain code with `tool.execute(input, ctx)` and over the Mastra server with `POST /api/tools/:toolId/execute`, and it can be exposed as an MCP server (stdio or Streamable HTTP) but only through an `MCPServer` plus a hand-written shebang entrypoint and `bin` field — no Mastra feature builds a single tool into its own CLI binary; `mastra api tool execute` and `mastra api mcp tool execute` are the only CLI tool paths, and both call a *running* server over HTTP.

**Agent** — `new Agent({ id, name, instructions, model })` from `@mastra/core/agent`, where `model` accepts a `provider/model` router string, a `{ id, url, apiKey, headers, api }` config object, or a provider instance; Mastra does ship a DeepSeek router entry (`deepseek/deepseek-flash`, `deepseek/deepseek-v4-pro`, keyed on `DEEPSEEK_API_KEY`) and custom OpenAI-compatible base URLs are set with `url` as the endpoint *base*, per-call sampling under `modelSettings` (`maxOutputTokens`, not `maxTokens`), reasoning under `providerOptions.<provider>.reasoningEffort`, `structuredOutput` with `errorStrategy: 'strict' | 'warn' | 'fallback'`, `maxSteps` still present (default 5) alongside `stopWhen`, and memory fully optional.

**Workflows** — `createStep({ id, inputSchema, outputSchema, execute, ... })` and `createWorkflow({ id, ... }).then(...).commit()`; suspend with `await suspend(payload)` and resume with `run.resume({ step, resumeData })` or `createRun({ runId })` + `resume()`; snapshots land in the `workflow_snapshots` table (LibSQLStore or PostgresStore), and **on process restart suspended runs are not auto-resumed** — only `running`/`waiting` runs are swept by `mastra.restartAllActiveWorkflowRuns()`, so a suspended run must be re-driven manually from its snapshot; runs are listed and inspected via `GET /api/workflows/:workflowId/runs[/:runId]`, `workflow.runById()`, and Studio.

**Evals** — `createScorer` and `runEvals` live in `@mastra/core/evals` (not `@mastra/evals`, whose root export is empty); the pipeline is `.preprocess` → `.analyze` → `.generateScore` (required) → `.generateReason`, built-in scorers ship from `@mastra/evals/scorers/prebuilt` plus 11 zero-LLM "Quick Checks" in `@mastra/evals/checks`, and CI gating is first-class via `gates` + per-scorer `threshold` producing `result.verdict`, with a Vitest subpath (`expectEvals`) and documented `process.exit(1)` pattern — no `mastra eval` CLI was verified.

**Observability** — configure `new Mastra({ observability: new Observability({ configs: { default: { ... spanOutputProcessors: [...] } } }) })` from `@mastra/observability`, ship spans to any OTLP endpoint with `new OtelExporter({ provider: { custom: { endpoint, headers, protocol } } })` from `@mastra/otel-exporter` supporting `grpc`, `http/protobuf`, `http/json` and `zipkin`, token metrics are emitted as `mastra_model_total_input_tokens` / `mastra_model_total_output_tokens` with cost fields, and pricing comes from a bundled models.dev snapshot refreshed every 6h — for models models.dev does not price (DeepSeek, self-hosted) you must supply `pricing` from a custom `MastraModelGateway.fetchProviders()` or a per-call `costContext`.

**Server** — it is Hono-based: `MastraServer` is an abstract class from `@mastra/server/server-adapter` (not `@mastra/core/server`) with official adapters for Elysia, Express, Hono, Fastify, Koa, NestJS, Next and TanStack Start, OpenAPI is generated for you at `/api/openapi.json` with Swagger UI at `/swagger-ui`, `mastra build` emits a self-contained `.mastra/output/` (`index.mjs`) runnable with `mastra start` or `node .mastra/output/index.mjs` on port 4111, auth is provider-based via `server.auth`, and only one fetched page claims runtime support "Node.js, Bun, or Deno" — Bun is documented as a CLI *runner* but no official Bun support statement or Bun-issue list could be verified.

**Release cadence** — extremely high-frequency and not lockstep: `@mastra/core` 1.79.0, `@mastra/memory` 1.39.0, `@mastra/mcp` 2.5.0, `@mastra/rag` 2.7.0, `@mastra/evals` 1.10.8 were all cut on 2026-10-26 within ~11 minutes of each other, stable batches land roughly weekly, hundreds of `0.0.0-<branch>-<timestamp>` snapshot tags are published continuously, `beta` dist-tags are stale and unusable, the repo carries 614 open issues, and 0.x→1.x brought a per-package breaking-change set (`runtimeContext`→`requestContext`, `telemetry:`→`observability:` into `@mastra/observability`, memory default changes, subpath-only core exports, MCP renames).

**AI SDK / MCP / adoption** — `@mastra/core` 1.x is built against the *provider-spec* generations of AI SDK v5/v6/v7 through aliased packages (`@ai-sdk/provider-v5`→`2.0.5`, `-v6`→`3.0.19`, `-v7`→`4.0.29`) rather than one `ai` version, and `@mastra/mcp` 2.5.0 serves only the MCP `2026-07-28` revision — the standalone HTTP+SSE transport is gone, suspend/resume replaces elicitation, and pre-2026 clients require staying on `@mastra/mcp` 1.x; **no named production adopter, multi-agent-shared-tool-layer write-up, or LangGraph / AI SDK-only / OpenAI Agents SDK comparison could be verified**.

---

## 1. createTool in `@mastra/core` 1.x

**Version and schema substrate.** `@mastra/core` `latest` is **1.79.0** (npm `lastPublished` 2026-10-26T21:11:25Z; GitHub release tag `@mastra/core@1.79.0` dated 2026-10-21), Apache-2.0, `engines.node >=22.13.0`. `zod` is a **peerDependency only** and exactly `"^3.25.0 || ^4.0.0"` — Zod is not a runtime dependency, so Zod 3.25+ and Zod 4 are both accepted. Schemas flow through Standard Schema: `@standard-schema/spec ^1.1.0` and `@mastra/schema-compat` are runtime deps, the docs state schemas may come from "any library that supports Standard JSON Schema… Zod, Valibot, and ArkType", and the server's tool handler explicitly special-cases ArkType ("ArkType types are callable but also implement StandardSchema via `~standard`") before serialising with `standardSchemaToJSONSchema`.

**Option surface** (the `Tool` class that `createTool` returns): `id`, `title?`, `description`, `inputSchema?`, `outputSchema?`, `suspendSchema?`, `resumeSchema?`, `requestContextSchema?`, `renderOnly?`, `strict?`, `outputValidation?` (`'strict' | 'warn'`, default `'strict'`), `toModelOutput?`, `transform?`, `requireApproval?`, `beforeApproval?`, `mcp?`, `providerOptions?`, `inputExamples?`, `background?`, and hooks `onInputStart` / `onInputDelta` / `onInputAvailable` / `onOutput`; runtime-populated fields are `mastra?` and `mcpMetadata?`.

**Docs/source disagreement worth knowing.** The reference page types `requireApproval?: boolean` only, while the source accepts **boolean or** `(input, ctx?: { requestContext?; workspace? }) => boolean | Promise<boolean>` — for per-call approval decisions (e.g. approve only destructive writes) the source is authoritative. The reference also never documents `mcp.toolType`, `mcpMetadata` or `needsApprovalFn`, all of which exist in source.

**Execute signature.** Exactly one signature: `ToolExecuteFunction = (inputData: TSchemaIn, context: ToolExecuteContext<TContext, TRequestContext>) => Promise<TSchemaOut | ValidationError | void>`. The first argument is the *validated input itself* — the 0.x `execute({ context: {...} })` form is wrong for 1.x. Context contents: `requestContext` (always present — an empty `RequestContext` is fabricated if the caller passes none), `abortSignal`, `observe`, `mastra`, `agent { agentId, toolCallId, messages, getMessages, suspend, threadId, resourceId, resumeData, suspendPayload, writableStream, isBackgroundTask }`, `workflow { workflowId, runId, state, setState, suspend, … }`, `mcp { extra, log, progress, protocolVersion }`, `workspace`, `browser`, `writer`, top-level `suspend` / `resumeData` / `suspendPayload`, `actor`; `tracingContext` arrives via `extends Partial<ObservabilityContext>`.

`observe` is **always provided** — `{ span(name, fn, attributes?) => Promise<T>; log(level: 'debug'|'info'|'warn'|'error'|'fatal', message, data?) }`, defaulting to a no-op implementation, so `await observe.span('db-query', () => db.query(...))` is safe with no wiring.

```ts
const weather = createTool({
  id: 'get-weather',
  inputSchema: z.object({ location: z.string(), units: z.enum(['c', 'f']).optional() }),
  outputSchema: z.object({ tempC: z.number() }),
  execute: async (input, { requestContext, abortSignal, observe }) => {
    await observe.span('geocode', async () => {/* … */});
    return { tempC: 21 };
  },
});
await weather.execute({ location: 'Berlin' }, {});   // direct, in-process
```

**Output validation does not throw.** On mismatch the tool logs `logger.warn(msg, { toolId })` and, unless `outputValidation === 'warn'`, **returns** `ValidationError`: `{ error: true, message: 'Tool output validation failed for <id>…', validationErrors: { errors: string[], fields } }`, with the offending output truncated to 200 characters and keys matching `password|secret|token|apiKey|api_key|auth|credential` redacted. Input and request-context failures return the same envelope (`Tool input validation failed…`, `Request context validation failed…`). `requestContextSchema`, when set, is validated before your `execute` runs.

**HTTP path.** `GET /api/tools`, `GET /api/tools/:toolId`, `POST /api/tools/:toolId/execute` with body `{ data: unknown; requestContext?: Record<string, unknown> }`. Errors come back as `{ error, details? }` with 400/401/403/404/500 (code list per the routes reference). The success envelope of the execute route could not be read, and whether `/api/tools` requires auth is likewise not established — treat both as open.

**MCP exposure and CLI.** `MCPServer` (`@mastra/mcp`) "provides the functionality to expose your existing Mastra tools and Agents as a Model Context Protocol (MCP) server". Registered on a Mastra instance it is served at `ALL /api/mcp/:serverId/mcp` (Streamable HTTP) plus legacy `/sse` + `/messages` for 1.x servers; all MCP routes declare `requiresAuth: true`, enforced only when `server.auth` is configured. For stdio you write your own entrypoint:

```ts
#!/usr/bin/env node
import { mcpServer } from './server';
mcpServer.startStdio().catch(e => { console.error(e); process.exit(1); });
```

then publish with `"bin": { "my-mcp-server": "dist/stdio.js" }, "files": ["dist"]` and consume it as `new MCPClient({ servers: { myServer: { command: 'npx', args: ['-y', '@your-org/my-mcp-server@1.0.0'] } } })`. Documented gotcha: stdio subprocesses inherit only the MCP SDK's curated env whitelist (`PATH`, `HOME`), not your shell — pass secrets via `env`. A **single tool as a standalone CLI binary is not a documented feature**; the CLI's only tool-invoking commands are `mastra api tool execute <toolId> '<json>'` and `mastra api mcp tool execute <serverId> <toolId> '<json>'`, which resolve a *running* server via `--url`, `localhost:4111`, or `.mastra-project.json`.

**0.x → 1.x signature history.** In the last 0.x release (`@mastra/core@0.22.2`) `execute` took one argument and `context` was a *property* of it (`execute: async ({ context }) => fetchWeather(context.location)`, with `ToolAction.execute?: (context, options?: MastraToolInvocationOptions)`); the second positional parameter was `options`, not `context`. Direct calls were therefore `tool.execute({ context: { inputData: data } })`, which the repo changelog's own migration example rewrites. The change landed inside the `1.0.0-beta` line (already present by `1.0.0-beta.27`) — changelog headings run `1.0.0` → `1.0.0-beta.27 … beta.0` → `0.22.2`, so no 0.x release carries it; the exact first beta could not be bisected. One v1 migration snippet also shows a flat `await getUserTool.execute({})` "before v1", contradicting the 0.22.2 types — the typed source is the stronger evidence.

## 2. Agent

Import: `import { Agent } from '@mastra/core/agent'`. `id` and `name` are required; `instructions` is `SystemMessage | ({ requestContext }) => SystemMessage | Promise<SystemMessage>` where `SystemMessage = string | string[] | CoreSystemMessage | CoreSystemMessage[] | SystemModelMessage | SystemModelMessage[]`; `model` is `MastraLanguageModel | ({ requestContext }) => …` — router string, config object, provider instance, fallback array, or function. Other constructor keys: `description`, `tools`, `agents?: Record<string, Agent>` (subagents / agents-as-tools), `workflows`, `memory?`, `scorers?: MastraScorers`, `hooks`, `inputProcessors`/`outputProcessors`, `defaultOptions`, `defaultGenerateOptionsLegacy`, `defaultStreamOptionsLegacy`, `scopes`, `requestContextSchema`, `notifications`, `voice`, `editor`.

**Default options rename (1.x).** There is no plain `defaultGenerateOptions` / `defaultStreamOptions` on the constructor; one `defaultOptions?: AgentExecutionOptions` covers both `generate()` and `stream()`, while the AI-SDK-v4 path keeps `defaultGenerateOptionsLegacy` / `defaultStreamOptionsLegacy` with `generateLegacy()` / `streamLegacy()`. The v1 migration guide frames this as renaming "to distinguish legacy (AI SDK v4) APIs from AI SDK v5+ APIs" — that wording comes from a search snippet of the migration page, so it is provisional.

**DeepSeek and custom OpenAI-compatible base URLs.** Mastra ships a DeepSeek router provider keyed on `DEEPSEEK_API_KEY`. Note the provider page is internally inconsistent — its intro says "Access 4 DeepSeek models" while the table footer says "2 available models" — and the IDs it lists are `deepseek/deepseek-flash` and `deepseek/deepseek-v4-pro` (a model ID list from the repo's `provider-registry.json` was not retrieved). `deepseek/deepseek-chat` is not among the listed IDs. Pricing shown there: `deepseek-flash` $0.15/$0.60 per 1M and `deepseek-v4-pro` $0.66/$2 per 1M, both at 1.0M context.

```ts
model: {
  id: 'deepseek/deepseek-flash',
  url: 'https://api.deepseek.com',          // base URL, NOT /chat/completions
  apiKey: process.env.DEEPSEEK_API_KEY,
  headers: { 'X-Custom-Header': 'value' },
}
```

`url` must be the endpoint base; custom URLs default to Chat Completions, `api: 'responses'` selects `/v1/responses` and switches provider-option reading from the `openai-compatible` namespace to `openai`. If you front the model with your own gateway, build it with `createOpenAICompatible({ name: providerId, apiKey, baseURL, supportsStructuredOutputs: true }).chatModel(modelId)` from **`@ai-sdk/openai-compatible-v5`**, returning a `LanguageModelV2`. Fallbacks: `model: [{ model, maxRetries, modelSettings?, providerOptions?, headers? }, …]` with precedence per-fallback > call-time > `defaultOptions`, `modelSettings` shallow-merging and `providerOptions` deep-merging.

**Per-call settings.** `modelSettings: { temperature (0–2), maxOutputTokens, topP (0–1), topK, presencePenalty, frequencyPenalty, stopSequences, toolChoice, maxRetries, timeout }` — the docs explicitly say "Use `maxOutputTokens` (not `maxTokens`) as per AI SDK v5 convention". Reasoning effort is *not* a `modelSettings` key; it goes through `providerOptions` (`{ openai: { reasoningEffort: 'high' } }`, or DeepSeek's own `providerOptions.deepseek`: `logprobs`, `topLogprobs`, `userId`, `strictJsonSchema` (default true), `thinking: { type: 'enabled'|'disabled'|'adaptive' }`, and `reasoningEffort: 'low'|'high'|'max'|'medium'|'xhigh'`), settable per call, per message, or on the system-message object.

**structuredOutput.** `{ schema (StandardJSONSchemaV1), model?, errorStrategy?: 'strict'|'warn'|'fallback', fallbackValue?, instructions?, jsonPromptInjection?: boolean|'system'|'inline'|'auto', logger?, providerOptions?, outputProcessors?, useAgent? }`. `strict` (default) throws; `warn` logs and continues; `fallback` substitutes `fallbackValue` and sets `result.usedFallbackValue === true`. `jsonPromptInjection` false/omitted = native `response_format`; `'inline'` = schema appended to the last user message; `true`/`'system'` = in the system message; `'auto'` = capability-based. Passing `model` spawns a separate internal structuring agent (two LLM calls); `useAgent: true` lets that model reuse the parent agent.

**Steps and memory.** `maxSteps?: number` is still on `AgentExecutionOptions` — "The default is 5" — and `stopWhen?: LoopOptions['stopWhen']` exists *alongside* it, not as a replacement. `memory` is optional: with none configured, `subscribeToThread` emits an empty history chunk, per-call `memory: { thread, resource, options }` supplies scoping, and `autoResumeSuspendedTools` "requires memory to be configured".

**Result shape.** `generate()` returns `{ text, object?, usedFallbackValue, toolCalls (payload-wrapped: `toolCall.payload.toolName`), toolResults, usage, finishReason ('stop'|'tool-calls'|'suspended'|'error'), steps[], response{ id, timestamp, modelId, headers }, messages, rememberedMessages, reasoning/reasoningText, sources, files, suspendPayload, runId, traceId, error?, tripwire? }`. Streaming exposes `stream.fullStream` (structured output arrives as a `type: 'object-result'` chunk), `stream.textStream`, and `stream.object` after completion; `.stream()` supports both Mastra's native format and AI SDK v5+ compatibility and throws if a V2 model is passed to V1 APIs.

## 3. Workflows

**createStep** takes `id`, `description`, `inputSchema`, `outputSchema`, `resumeSchema`, `suspendSchema`, `stateSchema`, `requestContextSchema`, `execute`, `scorers`, `retries`, `metadata` — `createStepFromParams` copies exactly these, and overloads also accept an Agent (step id = agent name), a Tool, a Classifier or a Processor. The step `execute` receives `inputData`, `resumeData`, `suspendData`, `mastra`, `getStepResult`, `getInitData`, `suspend(payload, { resumeLabel })`, `state`/`setState`, `runId`, `requestContext`, `retryCount`, `scorers`, `retries`.

**createWorkflow** takes `id`, `inputSchema`, `outputSchema`, optional `stateSchema`, `requestContextSchema`, `schedule` (cron/timezone/inputData/initialState/requestContext/metadata/options), and `options`: `tracingPolicy`, `validateInputs`, `autoRestartActiveRuns`, `shouldPersistSnapshot`, `pruneSnapshot`, `onStart`, `onFinish`, `onError`. `.commit()` terminates the chain; register with `new Mastra({ workflows: { testWorkflow } })`.

**Control flow in 1.x:** `.then()`, `.parallel([...])`, `.branch([[cond, step]])`, `.foreach(step, { concurrency })` (default 1), `.dountil()`, `.dowhile()`, `.map()` (helpers `getStepResult()`, `getInitData()`, `mapVariable()`), `.sleep(ms)`, `.sleepUntil(date)`, `.classifier()`, `.commit()`. No `.doloop()` or `.loop()` is listed. **Semantic change:** `.branch()` now runs *every* condition that returns true ("a run can execute more than one branch"); pass `perStep: true` for first-match-only. Every control-flow method accepts a trailing `{ id, description, metadata }` that survives serialisation into `serializedStepGraph` and affects presentation only.

**Suspend/resume.** `await suspend(payload)` inside `execute`; `suspendSchema` types the payload, `resumeSchema` types `resumeData`; on the resumed pass `execute` gets both `resumeData` and `suspendData`. Resume with `run.resume({ step, resumeData })` where `step` is the Step object (type-safe) or its id string, or omitted to resume the last suspended step. For a run you don't hold an instance for: `await workflow.createRun({ runId })` then `run.resume({ resumeData })`. `result.status === 'suspended'` exposes `result.suspended`, an array of step/nested-workflow paths (e.g. `['nested-workflow', 'step-1']`). `sleep()`/`sleepUntil()` are different: they pause at the *workflow* level and set status `waiting`, while `suspend()` sets `suspended`. No-arg `await suspend()` was not found in any retrieved page.

**Durability.** A snapshot is the serialisable run state — per-step status, outputs, execution path, suspended steps, remaining retries — held in the **`workflow_snapshots`** table keyed by `runId`, written by `persistWorkflowSnapshot()` on suspend and read by `loadWorkflowSnapshot()` on resume. Storage: `new LibSQLStore({ id: 'mastra-storage', url: 'file:./mastra.db' })` or, from `@mastra/pg`, `new PostgresStore({ id: 'mastra-storage', connectionString: process.env.DATABASE_URL })`. Use an absolute path so `mastra dev` and your app share the same libSQL file.

**Docs disagree on the default:** the snapshots page says snapshots "use libSQL by default", while the storage overview says the default in-memory store "loses data when the process exits" and lists "Workflows suspend and resume after a restart" as a reason to configure a persistent adapter. Treat the storage overview as the operational truth: configure storage explicitly.

**On process restart** — the key finding for a long-lived server: **suspended runs are recoverable but never auto-resumed.** Boot-time recovery sweeps only *active* runs (status `running` or `waiting`, from `workflow.listActiveWorkflowRuns()`); "When running the local mastra server, all active workflow runs will be restarted automatically when the server starts". APIs: `mastra.restartAllActiveWorkflowRuns()`, `workflow.restartAllActiveWorkflowRuns()`, `run.restart()` (from the last active step), concurrency `recovery.workflowConcurrency` (default 5), opt-out per workflow via `autoRestartActiveRuns: false`. A storage lease is held and renewed during execution; `restart()` refuses to take over an unexpired lease and throws `WORKFLOW_RESTART_RUN_OWNED`, and "storage adapters without run-ownership support keep the previous behavior and restart every active run" — so lease safety depends on the adapter. To recover a suspended run you must re-drive it yourself: `workflow.getWorkflowRunById(runId)` + `createWorkflowStateReader(state)` (`getSuspendedStep()`, `getResumeLabel()`), then `workflow.createRun({ runId })` + `run.resume({…})`.

**Listing/inspection.** `GET /api/workflows`, `GET /api/workflows/run-counts`, `GET /api/workflows/:workflowId`, `POST .../create-run`, `.../start-async`, `.../stream`, `.../resume`, `.../resume-async`, `GET /api/workflows/:workflowId/runs` (filters `fromDate`, `toDate`, `status`, `resourceId`) and `GET /api/workflows/:workflowId/runs/:runId` (returns snapshot first with in-memory fallback flagged `isFromInMemory: true`; supports a `fields` subset and `withNestedWorkflows=false`). HTTP resume body: `{ step?: string | string[]; resumeData?: unknown; requestContext?: Record<string, unknown> }`. Client SDK: `mastraClient.listWorkflowRunCounts()` → `Record<string, { running, suspended }>`, `workflow.runById(runId, { fields, withNestedWorkflows, requestContext })`, `run.resume`, `run.resumeAsync`, `run.cancel`. Studio gives a graph view with live per-step status plus time-travel replay of completed steps.

## 4. Evals

**Where things live.** `createScorer` and `runEvals` are exported from **`@mastra/core/evals`**. `@mastra/evals` is **1.10.8** and its root entry point is deliberately empty ("This package uses subpath exports"). Declared subpaths: `.`, `./scorers/prebuilt`, `./scorers/utils`, `./checks`, `./vitest`, `./vitest/setup`, `./package.json`. Its runtime deps are NLP/text libraries only (`compromise`, `keyword-extractor`, `sentiment`, `string-similarity`) — no LLM SDK — which is the structural reason the code-based scorers are free.

**createScorer.** Options: `id` (required), `name?` (defaults to `id`), `description` (required), `type?: 'agent'`, `judge?`, `prepareRun?`. There is **no top-level `outputSchema`** — it exists only on prompt-object `preprocess`/`analyze` steps (omit it on prompt-object `generateScore`, where Mastra requests `{ score: number }`). Pipeline, chainable and exact: `.preprocess` (optional) → `.analyze` (optional) → `.generateScore` (**required**) → `.generateReason` (optional); data threads as `results.preprocessStepResult`, `results.analyzeStepResult`, and `score` into `generateReason`. Each step is either a plain function (deterministic, no judge call) or a prompt object `{ description, createPrompt, outputSchema?, judge? }` that calls the judge. Also available: `filterRun()`, `prepareRun`, `notScorable()`.

The judge is fully configurable: `{ model (id string or instance), instructions, jsonPromptInjection?, inputProcessors?, outputProcessors?, errorProcessors?, maxProcessorRetries? }`, and any step can override it locally. **Cost model:** LLM-judged scorers cost one (or more) judge calls per scored item; code-based scorers and Quick Checks make no LLM calls — the docs say they "run instantly without an LLM" and "in microseconds".

**Built-ins.** `@mastra/evals/scorers/prebuilt` is a barrel over `../llm` and `../code`. LLM modules: answer-relevancy, answer-similarity, faithfulness, bias, hallucination, toxicity, tool-call-accuracy, context-relevance, context-precision, context-recall, multi-turn-judge, noise-sensitivity, prompt-alignment, rubric, summarization, trajectory. Code/deterministic modules: completeness, textual-difference, keyword-coverage, content-similarity, tone, tool-call-accuracy, trajectory, checks. Verified factory names include `createAnswerRelevancyScorer`, `createFaithfulnessScorer`, `createToxicityScorer`, `createCompletenessScorer`, `createKeywordCoverageScorer`, `createContentSimilarityScorer`, `createTextualDifferenceScorer`, `createToneScorer`, `createTrajectoryAccuracyScorerCode`, plus **two** tool-call scorers: `createToolCallAccuracyScorerCode({ expectedTool?, expectedToolOrder?, strictMode? })` (id `code-tool-call-accuracy-scorer`, deterministic, throws "Either expectedTool or expectedToolOrder must be provided") and `createToolCallAccuracyScorerLLM({ model, availableTools })` (id `llm-tool-call-accuracy-scorer`). A bare `createToolCallAccuracyScorer` does not exist.

**Quick Checks** = the `checks` object from `@mastra/evals/checks` with exactly 11 members: `includes`, `excludes`, `equals`, `matches`, `similarity`, `calledTool`, `didNotCall`, `toolOrder`, `maxToolCalls`, `usedNoTools`, `noToolErrors` — each a real `createScorer()` instance with a stable id (`check-includes`, …) using only `.preprocess` + `.generateScore`. Note the in-source JSDoc says `import { checks } from '@mastra/evals'`, which is stale; the package exports map and docs both say `/checks`.

**Attaching vs standalone.** Live, async, sampled: `new Agent({ scorers: { relevancy: { scorer, sampling: { type: 'ratio', rate: 0.5 }, filter } } })` and `createStep({ scorers: { key: { scorer, sampling: {…} } } })`; results persist to the `mastra_scorers` table. Batch: `runEvals` — signature uses **`target`** (singular) and **`requestContext`** (there is no `targets` and no `runtimeContext` in 1.x): `runEvals({ target, data, scorers?, gates?, targetOptions?, concurrency? (default 1), onItemComplete? })`, returning `{ scores, summary: { totalItems, notScorable? }, verdict?, gateResults?, thresholdResults?, turnResults? }` where `scores` holds per-scorer **averages** across items.

**CI gating exists and is official.** `gates: [ … ]` must average 1.0 or the run is `failed`; `scorers: [{ scorer, threshold: 0.7 }]` (or `{ min, max }` — use `max` for hallucination/toxicity where high is bad) produces `result.verdict` ∈ `passed | scored | failed`, and the docs' CI snippet calls `process.exit(1)` on `failed`. The recommended pattern is *any* ESM test runner (Vitest/Jest/Mocha) wrapping `runEvals` and asserting `result.scores['location-accuracy']`; a first-party Vitest integration ships as `@mastra/evals/vitest` exporting `expectEval`, `expectEvals`, `EvalPassRateError`, `evalMatchers`, `registerEvalMatchers`, `MastraEvalsReporter`, `toEvalMeta` (behaviour of these helpers is documented on a reference page that could not be read, so only their existence is verified). **No `mastra eval` CLI subcommand could be verified** — and note the CLI *does* document `mastra scorers`.

## 5. Observability

**Config shape — the shape in most blog posts is stale.** Current 1.x requires an `Observability` **class instance** and the processor key is **`spanOutputProcessors`**, not `processors`:

```ts
import { Observability, MastraStorageExporter, MastraPlatformExporter, SensitiveDataFilter } from '@mastra/observability';

new Mastra({
  observability: new Observability({
    configs: { default: {
      serviceName: 'mastra',
      sampling: { type: 'ratio', probability: 0.1 },
      exporters: [new MastraStorageExporter(), new MastraPlatformExporter()],
      spanOutputProcessors: [new SensitiveDataFilter()],
    } },
    default: { enabled: true },
  }),
});
```

Per-config fields: `serviceName`, `sampling` (defaults to always-on), `exporters`, `spanOutputProcessors`, `includeInternalSpans`, `excludeSpanTypes`, `spanFilter`, `requestContextKeys`, `serializationOptions`, `logging`; the registry adds `default?: { enabled? }`, `configs`, `configSelector`, `sensitiveDataFilter`. Sampling union: `{type:'always'} | {type:'never'} | {type:'ratio',probability} | {type:'custom',sampler}`. The docs say the `default` option enables the `MastraStorageExporter` + `MastraPlatformExporter` pair — the names that older docs and migration guides give as `DefaultExporter` / `CloudExporter`. Both name families exist in the exporters barrel (`default.ts`, `cloud.ts`, `console.ts`, `mastra-platform.ts`, `mastra-storage.ts`), but the implementation files were not read, so whether Default/Cloud survive as aliases is unconfirmed.

**Import paths.** `@mastra/observability` (exports map is `.` only) gives `Observability`, `MastraStorageExporter`, `MastraPlatformExporter`, `SensitiveDataFilter`, `chainFormatters`, `PricingRegistry`; `@mastra/core/observability` gives types and helpers (`SpanType`, `SpanOutputProcessor`, `AnySpan`, `CustomFormatter`, `nestUnderRun`) — complementary, not alternatives. Versions: `@mastra/observability` **1.21.0** (peer `@mastra/core >=1.16.0-0 <2.0.0-0`), `@mastra/otel-exporter` **1.4.9**, `@mastra/otel-bridge` **1.5.18** (separate package that bridges Mastra tracing into an existing OTel Node SDK; peer-depends on `@opentelemetry/sdk-node` and `@opentelemetry/auto-instrumentations-node`).

**OTLP to ClickHouse/HyperDX.** `new OtelExporter({ provider: { custom: { endpoint, headers: {…}, protocol: 'http/protobuf' } }, timeout?, batchSize?, resourceAttributes?, signals: { traces?, logs? } })`. `ExportProtocol = 'http/json' | 'http/protobuf' | 'grpc' | 'zipkin'`, so gRPC **and** HTTP/protobuf are both supported. Named providers exist for `dash0`, `signoz`, `newrelic`, `traceloop`, `laminar`; protocol-specific OTel packages (`exporter-trace-otlp-grpc`, `-http`, `-proto`, zipkin) plus `@grpc/grpc-js` are optional dependencies you install yourself. The exporter also re-exports GenAI-semantics helpers (`getAttributes`, `getSpanName`, `isModelCallSpan`), confirming spans are mapped onto semantic-convention attributes — but the exact `gen_ai.*` key set was not read. A Mastra-specific ClickHouse/HyperDX guide was not located; point the custom endpoint at your OTLP collector.

**Tokens and cost.** Metrics derive from *ended spans*, and only `MastraStorageExporter` (ClickHouse / DuckDB / Postgres-vnext) surfaces them. Token metric names: `mastra_model_total_input_tokens`, `mastra_model_total_output_tokens`, plus `mastra_model_input_text_tokens`, `_input_cache_read_tokens`, `_input_cache_write_tokens`, `_input_audio_tokens`, `_input_image_tokens`, `mastra_model_output_text_tokens`, `_output_reasoning_tokens`, `_output_audio_tokens`, `_output_image_tokens`, emitted from `MODEL_GENERATION` and `CLASSIFIER_EVALUATION` spans that carry provider usage. Tool calls get `mastra_tool_duration_ms` but **no token metrics**. Cost sits on the token metrics as `provider`, `model`, `estimatedCost`, `costUnit`, `costMetadata`.

**Cost estimation source for custom models — the critical answer for DeepSeek.** `@mastra/observability` bundles a **models.dev pricing snapshot** at `src/metrics/pricing-data.json`, regenerated by `scripts/generate-pricing.ts` every 6 hours. At runtime `PricingRegistry.getGlobal()` uses that bundled copy unless refresh is on (`MASTRA_DEV` or `MASTRA_AUTO_REFRESH_PRICING=true`), in which case it loads/refreshes a copy cached at `~/.cache/mastra/pricing-data.json` (at most once per 24h, hourly retries, 5s timeout) and is disabled entirely by `MASTRA_OFFLINE`. For models models.dev does not price — self-hosted models *and* the DeepSeek router IDs Mastra itself ships — the documented mechanism is a custom **`MastraModelGateway`** whose `fetchProviders()` returns ProviderConfig objects with `pricing?: Record<string, ModelPricing>`, i.e. "Prices per model ID in USD per 1 million tokens, with the same keys as a models.dev cost (input, output, cache_read, cache_write, reasoning, input_audio, output_audio)", which "`@mastra/observability` uses … for cost metrics when models.dev has no price for the model." A caller-supplied `costContext` outranks both provider-reported cost and registry estimates. So: **custom pricing is possible, but you supply it yourself** — there is no separate `TokenCost` API or cost package (a search for one surfaced nothing; that is unverified rather than proven absent).

## 6. Server and deploy

**Package reality (npm, authoritative):** `@mastra/core` 1.79.0, `@mastra/server` 1.79.0, `@mastra/deployer` 1.79.0, but **`@mastra/hono` 1.7.21** — the Hono adapter is *not* on 1.79.x, so the version skew is real and expected. CLI `mastra` 1.35.0. All require Node >= 22.13.0.

**MastraServer is not in `@mastra/core/server`.** It is an abstract class imported from **`@mastra/server/server-adapter`**: `MastraServer<TApp, TRequest, TResponse>` with constructor options `{ app, mastra, prefix='/api', openapiPath='', bodyLimitOptions, streamOptions={redact:true}, customRouteAuthConfig, tools, taskStore, mcpOptions }`, abstract methods `registerContextMiddleware`, `registerAuthMiddleware`, `registerRoute`, `getParams`, `sendResponse`, `stream`, and instance methods `init()`, `registerRoutes()`, `getApp()`, `registerOpenAPIRoute()`. `@mastra/server` has exactly one runtime dependency (`hono ^4.13.7`). `@mastra/hono` depends on `@mastra/server@1.79.0` plus `@hono/node-ws`, `fetch-to-node`, `ws`. `@mastra/deployer` is the **build** package (Rollup 4, esbuild, Babel), not an HTTP adapter.

**Official adapters:** `@mastra/elysia`, `@mastra/express`, `@mastra/hono`, `@mastra/fastify`, `@mastra/koa`, `@mastra/nestjs`, `@mastra/next`, `@mastra/tanstack-start`. Mount with `const server = new MastraServer({ app, mastra }); await server.init()` — `init()` runs context middleware → auth middleware → user middleware → routes (callable individually for custom ordering); `mastra.getServerApp()` and `server.getApp()` return the same app.

**Adapter gotchas that matter for a long-lived platform process:** adapters do **not** run file-based discovery and do **not** start background workers — call `mastra.startWorkers()` yourself or scheduled workflows and event listeners never run. They ignore `port`/`host`/`cors`/`timeout`/`apiRoutes` (dev/build-only) and read only `auth`, `bodySizeLimit`, `onError`, `middleware` from `mastra.getServer()`. `server.middleware` uses Hono's handler signature, so only Hono-based adapters mount it; Express/Fastify/Koa/Elysia/NestJS log a warning instead. Prefixing: `prefix: '/api/v2'`. Per-route auth: `customRouteAuthConfig: new Map` keyed `METHOD:PATH` with `true`/`false`. MCP is served at `/api/mcp/:serverId/mcp`, and `mcpOptions: { serverless: true }` switches to stateless mode for Cloudflare Workers / Vercel Edge.

**OpenAPI.** Built in and zero-config: `hono-openapi ^1.3.1` is a direct dependency of `@mastra/core`; `GET /api/openapi.json` and Swagger UI at `/swagger-ui`, both **disabled in production by default** unless `server.build.openAPIDocs` / `server.build.swaggerUI` are true. No hand-rolled zod-to-openapi needed.

**Auth.** Provider-based `server.auth` (with an optional separate `studio.auth` used exclusively by Studio's own requests) and built-in providers for JWT, Clerk, Supabase, Firebase, Auth0 and WorkOS plus a `MastraAuthProvider` base class for custom providers — this comes from docs search snippets rather than a fetched page, so treat it as provisional; `MASTRA_AUTH_TOKEN` could not be confirmed or ruled out.

**`mastra dev` / `build` / `start`.** `mastra build` emits `.mastra/.build/` plus a self-contained `.mastra/output/` containing `index.mjs` (the generated Hono server entry), `mastra.mjs`, `tools.mjs`, `tools/`, `package.json`, `node_modules/`, `.npmrc`, `public/`, and `playground/` with `--studio`. It discovers `{mastraDir}/tools/**/*.{js,ts}`, bundles with Rollup, generates `index.mjs`, then runs `npm install` in the output dir. Run it with `mastra start` (which also loads `.env.production`/`.env`) or `node .mastra/output/index.mjs`. Env: `PORT` (default 4111), `MASTRA_HOST` (default localhost), `MASTRA_STUDIO_PATH`, `MASTRA_SKIP_DOTENV`, `NODE_OPTIONS`. Endpoints: `GET /health`, `/api/openapi.json`, `/swagger-ui`. Built-in SIGINT/SIGTERM handling stops accepting connections, waits `server.drainTimeout` (default 5 s) for in-flight requests/streams, then calls `mastra.shutdown()`; a second signal exits immediately; disable with `server.handleShutdownSignals`. Build-time options (`bundler`, `deployer`, `server`) must be direct properties of the object passed to `new Mastra()`, not hidden behind a factory call or spread, or the build silently falls back to defaults.

**Node vs Bun vs Deno.** The only runtime-support statement found on a fetched page is that Mastra "compiles your application into a standalone Node.js server that can run on any platform supporting Node.js, Bun, or Deno" — that is a docs sentence, not a tested-support matrix. Bun is documented as a CLI runner (`bun x mastra dev`), and stdio MCP packaging was documented with `tsup` in the 1.x era. No official Bun-support statement, Bun-specific issue list, or Deno caveat set could be verified. **Install weight:** `@mastra/core` declares **30 runtime dependencies** (including `hono`, `hono-openapi`, `execa`, `posthog-node`, `ws`, `yaml`, `croner`, `re2js`, `xxhash-wasm`, two aliased A2A SDKs and six aliased `@ai-sdk/provider*` packages) — unpacked-size/bundlephobia figures were not retrievable, so budget from the dependency count rather than a number.

## 7. Release cadence, breaking changes, open issues

**Not lockstep.** Five stable packages were published on 2026-10-26 between 21:11Z and 21:22Z — a single changesets batch — spanning three major lines: core 1.79.0, memory 1.39.0, evals 1.10.8, mcp 2.5.0, rag 2.7.0. Peer ranges differ accordingly: memory accepts core `>=1.4.1-0`, evals `>=1.0.0-0`, but **mcp 2.5.0 requires core `>=1.79.0-0`** — the tightest coupling in the repo, so mcp and core must move together.

**Cadence.** Two layers: stable batches roughly weekly (the newest GitHub batch is timestamped 2026-10-21T11:57:33Z and bundles dozens of packages — mastracode@0.48.0, mastra@1.35.0, @mastra/weaviate@0.1.3, @mastra/voyageai@0.4.2, eight `voice-*` packages, all authored by the release bot), plus continuous per-branch snapshot publishing: `@mastra/core` carries several hundred `0.0.0-<branch>-<YYYYMMDDhhmmss>` dist-tags, from `0.0.0-storage-20250225005900` to `0.0.0-chart-table-1023-20261026195314`, with multiple distinct snapshots on single days (2026-10-23 alone: `playground-snapshot-20261023-114342`, `playground-main-1023`, `max-drawer-size`, `org-metrics`, `org-metrics-2`, `doctor-retest`). Practical consequence: `beta` tags are **stale and must not be used** (core `beta` = 1.1.0-alpha.2 vs latest 1.79.0; mcp `beta` = 1.0.0 vs 2.5.0), and per-month release counts could not be computed because the registry record exposes dist-tags but not a full version→time map.

**Repo state.** mastra-ai/mastra had 29,094 stars, 3,048 forks and **614 open issues** at observation, last push 2026-10-26T22:01:54Z, not archived.

**0.x → 1.x breaking changes** (a per-package migration guide exists at `/reference/migrations/upgrade-to-v1/*`: overview, mastra, memory, storage, tracing, client, mcp, cli; the overview says to upgrade to the latest 0.x first, i.e. a two-hop path). Verified or snippet-sourced items: `@mastra/core`'s index now exports only `Mastra` and `Config`, everything else is a subpath import; `telemetry:` → `observability:` with the new `@mastra/observability` package (failing to rename breaks telemetry); **`runtimeContext` → `requestContext` including the `mastra_scorers` DB column** (requires SQL migrations on `@mastra/pg` / `@mastra/libsql`); memory defaults changed — `lastMessages` 40 → 10, `semanticRecall` off by default, thread titles off; MCP `mastra.getMCPServers()` → `listMCPServers()` and `mcp.getTools()` → `listTools()`; client SDK `messages` became the first argument of `generate`/`stream`/`network`; `createTool`'s execute signature changed to `(inputData, context)`; new `mastra migrate` CLI for DB migrations. A separate "Upgrade to Latest 0.x" guide exists for pre-v1 history ("Migrate to v0.22 — Changed: Memo…"), indicating the 0.x line also carried numbered migration steps. Individual migration pages were reachable only as search snippets, so the list above is medium confidence; no workflow control-flow rename list could be verified.

**Community complaint themes: not established.** Issue labels, most-reacted issues, Discussions/Reddit/HN threads and any CHANGELOG-derived sentiment could not be sampled — the 614 open issues is the only repo-level signal obtained. Absence of a theme list here is absence of evidence, not evidence of calm.

## 8. AI SDK relationship, MCP, and adopters

**AI SDK.** `@mastra/core` 1.x does not pin a single `ai` package version; it pins three *provider-spec* generations as npm aliases — `@ai-sdk/provider-v5`→`@ai-sdk/provider@2.0.5`, `-v6`→`3.0.19`, `-v7`→`4.0.29` — with dev aliases `@ai-sdk/openai-compatible-v5`→`1.0.58`, `-v6`→`2.0.85` and `@ai-sdk/openai-v5`→`2.0.135`, `-v6`→`3.0.130`, `-v7`→`4.0.96`. Docs frame behaviour as "AI SDK v5+ compatible", and `stream()` is documented as supporting both Mastra's native format and AI SDK v5+ compatibility, throwing if a V2 model is passed to V1 APIs. What was **not** verified: the exact `ai` package range declared by `@mastra/core`, whether Mastra re-exports AI SDK primitives or merely consumes provider instances, and what breaks if you pin a different `ai` major. (Mastra also publishes `@mastra/ai-sdk`, but its contents were not read.)

**MCP client/server.** `@mastra/mcp` is now **2.5.0** and serves **only** the MCP `2026-07-28` revision — no `initialize` handshake, no session header, every request self-contained. `MCPClient` is `new MCPClient({ servers: { <name>: { url, protocolVersion?, enableServerLogs?, serverLogLevel?, logger?, inputRequests? } } })`; providing `command`+`args` selects stdio instead of Streamable HTTP, and the 2.x client probes with `server/discover`, falling back to `initialize`, unless you pin `protocolVersion: '2026-07-28'` (fails on legacy) or `'legacy'` (skips the probe). `MCPServer` is `new MCPServer({ name, version, tools, requestState: { key, ttlSeconds } })`.

**The 2.0 cliff.** `startSSE`, `startHonoSSE` and `connectSSE` plus the `/sse` + `/messages` routes are gone for 2.x servers (adapters 404 there); what was removed is the standalone SSE *transport*, not SSE framing — Streamable HTTP still streams SSE. Servers now expose resources (`listResources`, `getResourceContent`) and prompts (SDK `Prompt` type) and both can suspend. Server-initiated requests are gone: `context.mcp.elicitation.sendRequest`, `extra.sendRequest` and `extra.sendNotification` are deprecated and **throw** on a 2.x server, replaced by first-class `context.suspend(payload)` / `context.resumeData` validated against `suspendSchema`/`resumeSchema`, with the continuation carried as an opaque, **signed (HMAC, not encrypted)** `requestState` string (`ttlSeconds` default 600, per-process key if unset). `executeTool()` returns `{ status: 'completed', output } | { status: 'suspended', suspendPayload, resumeSchema }`, also exposed at `POST /api/mcp/:serverId/tools/:toolId/execute`. A `legacy: 'reject' | 'stateless'` switch serves 2025-era clients (Cursor, VS Code) in a sessionless mode that cannot use suspend/resume or `subscriptions/listen`. If your OpenCode-style runtime speaks an older revision, stay on `@mastra/mcp` 1.x — it "remains supported against current `@mastra/core`" and can coexist with 2.x servers in one instance (`mcpVersion` distinguishes them). One practical benefit of the 2.x design for a shared capability layer: because tools, workflows, resources and prompts all use the same suspend/resume vocabulary, "one createTool definition serves all three".

**Production adopters: nothing verified.** No named production user, case study, conference talk, or write-up of teams running many narrow single-purpose agents over a shared tool layer was retrieved, and no comparison against LangGraph, AI SDK alone, or the OpenAI Agents SDK was retrieved either. That part of the query remains open — the absence of findings here reflects the evidence gathered, not a judgement about adoption.

## Where sources disagree or leave gaps

- `requireApproval` is `boolean` per the reference, `boolean | function` per source — trust the source.
- The DeepSeek provider page contradicts itself on model count ("Access 4 DeepSeek models" vs "2 available models"); the authoritative registry file was not read.
- Snapshot storage default: "libSQL by default" (snapshots page) vs "the default in-memory store loses data when the process exits" (storage overview).
- Workflow `.branch()` semantics changed to multi-match in 1.x — older tutorials that assume first-match-only will silently run extra branches unless `perStep: true`.
- Exporter naming: `MastraStorageExporter`/`MastraPlatformExporter` (current docs) vs `DefaultExporter`/`CloudExporter` (older docs); both module families exist in source, alias status unconfirmed.
- 0.x direct-call shape: the migration page shows a flat `execute({})` while the 0.22.2 types and changelog show `execute({ context: … })`.
- Quick Checks import path: stale in-source JSDoc (`@mastra/evals`) vs package exports and docs (`@mastra/evals/checks`).
- `MastraServer`'s documented home is `@mastra/server/server-adapter`, while custom routes are `registerApiRoute` from `@mastra/core/server` — the two subpaths are not interchangeable, and only the latter was confirmed by snippet.


## Unverified

- Success envelope of POST /api/tools/:toolId/execute and whether /api/tools routes require auth — File retrieval was truncated at 4,604 of 13,590 characters, so the route definitions and the imported executeToolResponseSchema were never read; the routes reference gives only the request body and says nothing about auth for /api/tools. (The page itself WAS retrieved elsewhere in this run and backs citations — this entry records an unverified topic, not an unusable source.)
- Client-side tool.execute over HTTP (@mastra/client-js Tools API body and return value) — Page could not be read; only a search snippet showed tool.execute({ args, threadId, resourceId }).
- 0.x docs page for createTool execute signature — The v0 docs page was not retrieved; the 0.x signature in the report comes from the tagged source at @mastra/core@0.22.2 instead.
- Agent.stream() full Returns object shape — Page text truncated before the Returns section, so stream result fields were taken from the structured-output page instead.
- Memory reference: whether new Memory() works without storage and exact behaviour when memory is undefined — No memory docs page was retrieved.
- Mastra AI SDK integration page for 1.x (supported ai package version, re-export vs wrap) — Only the v0 version appeared in search results; no 1.x integration page was located or fetched, so the AI SDK claim rests on npm/package.json provider-spec aliases and doc phrasing ('AI SDK v5+').
- Source-of-truth DeepSeek model IDs in packages/core/src/llm/model/provider-registry.json — File not fetched; the DeepSeek ID list is taken from the rendered provider docs page, which is itself internally inconsistent ('Access 4 DeepSeek models' vs '2 available models').
- Repository listing of packages/core/src/workflows (to reach run/storage implementation files) — Fetch failed; individual source files for the run/storage API could not be opened, so those signatures rest on docs reference pages.
- Authoritative 1.x workflow rename/changelog list — No changelog or migration page covering workflow control-flow renames was retrieved, so no rename list is asserted.
- Documented behaviour of the @mastra/evals/vitest helpers (expectEvals, evalMatchers, MastraEvalsReporter) — Reference page was not retrieved; export names come from repo source only.
- Whether an official `mastra eval` CLI subcommand exists — Not checked; the CLI reference read covers other commands. Absence must not be inferred.
- MastraScorer base class .run() contract and exact method list — Appeared only as a search-result snippet; the page was not fetched.
- OtelExporter reference page: exact option table and custom-endpoint examples — Page could not be read; only a snippet showing CustomConfig { endpoint, protocol, headers } was seen.
- Mastra-specific ClickHouse/HyperDX (ClickStack) integration guide — No Mastra-specific ClickHouse/HyperDX tracing guide was located or retrieved.
- Whether DefaultExporter / CloudExporter survive as aliases of MastraStorageExporter / MastraPlatformExporter — Exporter implementation files were not opened; only barrels and docs were verified.
- Exact gen_ai.* semantic-convention attribute keys emitted by OtelExporter — Not read; only the existence of getAttributes/getSpanName/isModelCallSpan exports was verified.
- Existence of a TokenCost API or separate cost/pricing package — No such API or package surfaced in the npm registry, repo barrels or docs read; cannot be stated as absent, only unverified.
- Custom API routes / registerApiRoute reference and the exact export surface of @mastra/core/server — Not fetched; only snippets confirm registerApiRoute comes from @mastra/core/server.
- Official deployer list (@mastra/deployer-* packages for Vercel/Netlify/Cloudflare/Docker) — No deployer-list page was retrieved; only the generic standalone-server deployment page was read.
- Bun/Deno support status and known Bun-specific issues — No GitHub issue search could be performed; the only runtime-support evidence is one deployment-page sentence, and CLI dist-tag names were not read as sources.
- Install size / unpacked size of @mastra/core — Not retrievable; only dependency names and count came from the npm registry record, with no size figures.
- Exact historical publish timestamps and per-month release frequency for @mastra/core — The registry record exposes dist-tags but not a full version-to-time map, so monthly release counts could not be computed.
- GitHub issue list, labels, most-reacted issues and open-issue themes — Could not sample; only the aggregate open-issue count (614) came from the API call.
- Community discussion themes (GitHub Discussions, Reddit, Hacker News) — No community source could be read, so no community-complaint claims are made.
- Exact `ai` package dependency range declared by @mastra/core 1.x / 1.0.0 — Registry document was retrieved but its dependency block was not recoverable in readable form, so the ai major could not be quoted without guessing.
- Named production adopters, multi-agent/shared-tool-layer write-ups, and comparisons vs LangGraph / AI SDK alone / OpenAI Agents SDK — No adoption page, case study, talk or comparison post was read; absence of evidence in this run is not evidence of absence.
- @mastra/mcp 1.x-era documented protocol revisions and version-pinned MCP docs — No retrieved source enumerates the revisions 1.x negotiated, and no /docs/v1 MCP page was located.
- Real-world npm bin wiring in Mastra's own published stdio MCP server (@mastra/mcp-docs-server) — Could not be fetched, so the package.json bin field of that package was not directly verified.
- Tail of the mastra CLI reference (sections after `mastra api`, common flags) — Fetch truncated at 67,350 of 80,181 characters, so the remainder of the command list was not read. (The page itself WAS retrieved elsewhere in this run and backs citations — this entry records an unverified topic, not an unusable source.)
- @mastra/mcp changelog migration note (1.x elicitation to suspend) — Cited only from a search-result snippet; the file itself was not fetched.


## Sources

- https://github.com/mastra-ai/mastra
- https://www.npmjs.com/package/@mastra/core
- https://registry.npmjs.org/%40mastra/core
- https://github.com/mastra-ai/mastra/blob/HEAD/packages/core/src/tools/tool.ts
- https://raw.githubusercontent.com/mastra-ai/mastra/HEAD/packages/core/src/tools/tool.ts
- https://github.com/mastra-ai/mastra/blob/HEAD/packages/core/src/tools/types.ts
- https://raw.githubusercontent.com/mastra-ai/mastra/HEAD/packages/core/src/tools/types.ts
- https://mastra.ai/reference/tools/create-tool
- https://github.com/mastra-ai/mastra/blob/HEAD/packages/core/src/tools/validation.ts
- https://raw.githubusercontent.com/mastra-ai/mastra/HEAD/packages/core/src/tools/validation.ts
- https://mastra.ai/reference/server/routes
- https://mastra.ai/docs/agents/tools
- https://github.com/mastra-ai/mastra/blob/HEAD/packages/server/src/server/handlers/tools.ts
- https://raw.githubusercontent.com/mastra-ai/mastra/HEAD/packages/server/src/server/handlers/tools.ts
- https://mastra.ai/reference/agents/agent
- https://mastra.ai/models/providers/deepseek
- https://mastra.ai/models
- https://mastra.ai/models/gateways/custom-gateways
- https://github.com/mastra-ai/mastra/blob/HEAD/packages/core/package.json
- https://raw.githubusercontent.com/mastra-ai/mastra/HEAD/packages/core/package.json
- https://mastra.ai/reference/agents/generate
- https://mastra.ai/docs/agents/structured-output
- https://mastra.ai/reference/streaming/agents/stream
- https://mastra.ai/docs/workflows/overview
- https://mastra.ai/reference/workflows/workflow
- https://mastra.ai/docs/workflows/control-flow
- https://mastra.ai/docs/workflows/suspend-and-resume
- https://mastra.ai/reference/workflows/step
- https://mastra.ai/docs/workflows/snapshots
- https://mastra.ai/docs/storage/overview
- https://mastra.ai/reference/client-js/workflows
- https://github.com/mastra-ai/mastra/blob/HEAD/packages/core/src/workflows/workflow.ts
- https://raw.githubusercontent.com/mastra-ai/mastra/HEAD/packages/core/src/workflows/workflow.ts
- https://www.npmjs.com/package/@mastra/evals
- https://registry.npmjs.org/%40mastra/evals
- https://mastra.ai/docs/evals/overview
- https://mastra.ai/docs/evals/custom-scorers
- https://mastra.ai/reference/evals/create-scorer
- https://mastra.ai/docs/evals/built-in-scorers
- https://mastra.ai/docs/evals/gates-and-verdicts
- https://mastra.ai/reference/evals/run-evals
- https://github.com/mastra-ai/mastra/blob/HEAD/packages/evals/src/scorers/index.ts
- https://raw.githubusercontent.com/mastra-ai/mastra/HEAD/packages/evals/src/scorers/index.ts
- https://mastra.ai/docs/evals/running-in-ci
- https://github.com/mastra-ai/mastra/blob/HEAD/packages/evals/src/scorers/llm/index.ts
- https://raw.githubusercontent.com/mastra-ai/mastra/HEAD/packages/evals/src/scorers/llm/index.ts
- https://github.com/mastra-ai/mastra/blob/HEAD/packages/evals/package.json
- https://raw.githubusercontent.com/mastra-ai/mastra/HEAD/packages/evals/package.json
- https://github.com/mastra-ai/mastra/blob/HEAD/packages/evals/src/scorers/code/index.ts
- https://raw.githubusercontent.com/mastra-ai/mastra/HEAD/packages/evals/src/scorers/code/index.ts
- https://github.com/mastra-ai/mastra/blob/HEAD/packages/evals/src/scorers/prebuilt/index.ts
- https://raw.githubusercontent.com/mastra-ai/mastra/HEAD/packages/evals/src/scorers/prebuilt/index.ts
- https://github.com/mastra-ai/mastra/blob/HEAD/packages/evals/src/scorers/code/checks/index.ts
- https://raw.githubusercontent.com/mastra-ai/mastra/HEAD/packages/evals/src/scorers/code/checks/index.ts
- https://github.com/mastra-ai/mastra/blob/HEAD/packages/evals/src/index.ts
- https://raw.githubusercontent.com/mastra-ai/mastra/HEAD/packages/evals/src/index.ts
- https://github.com/mastra-ai/mastra/blob/HEAD/packages/evals/src/scorers/llm/answer-relevancy/index.ts
- https://raw.githubusercontent.com/mastra-ai/mastra/HEAD/packages/evals/src/scorers/llm/answer-relevancy/index.ts
- https://github.com/mastra-ai/mastra/blob/HEAD/packages/evals/src/scorers/code/completeness/index.ts
- https://raw.githubusercontent.com/mastra-ai/mastra/HEAD/packages/evals/src/scorers/code/completeness/index.ts
- https://github.com/mastra-ai/mastra/blob/HEAD/packages/evals/src/scorers/llm/tool-call-accuracy/index.ts
- https://raw.githubusercontent.com/mastra-ai/mastra/HEAD/packages/evals/src/scorers/llm/tool-call-accuracy/index.ts
- https://github.com/mastra-ai/mastra/blob/HEAD/packages/evals/src/scorers/code/keyword-coverage/index.ts
- https://raw.githubusercontent.com/mastra-ai/mastra/HEAD/packages/evals/src/scorers/code/keyword-coverage/index.ts
- https://github.com/mastra-ai/mastra/blob/HEAD/packages/evals/src/scorers/code/textual-difference/index.ts
- https://raw.githubusercontent.com/mastra-ai/mastra/HEAD/packages/evals/src/scorers/code/textual-difference/index.ts
- https://github.com/mastra-ai/mastra/blob/HEAD/packages/evals/src/scorers/code/content-similarity/index.ts
- https://raw.githubusercontent.com/mastra-ai/mastra/HEAD/packages/evals/src/scorers/code/content-similarity/index.ts
- https://github.com/mastra-ai/mastra/blob/HEAD/packages/evals/src/scorers/llm/toxicity/index.ts
- https://raw.githubusercontent.com/mastra-ai/mastra/HEAD/packages/evals/src/scorers/llm/toxicity/index.ts
- https://github.com/mastra-ai/mastra/blob/HEAD/packages/evals/src/scorers/code/tool-call-accuracy/index.ts
- https://raw.githubusercontent.com/mastra-ai/mastra/HEAD/packages/evals/src/scorers/code/tool-call-accuracy/index.ts
- https://github.com/mastra-ai/mastra/blob/HEAD/packages/evals/src/vitest/index.ts
- https://raw.githubusercontent.com/mastra-ai/mastra/HEAD/packages/evals/src/vitest/index.ts
- https://github.com/mastra-ai/mastra/blob/HEAD/packages/evals/src/scorers/llm/faithfulness/index.ts
- https://raw.githubusercontent.com/mastra-ai/mastra/HEAD/packages/evals/src/scorers/llm/faithfulness/index.ts
- https://github.com/mastra-ai/mastra/blob/HEAD/packages/evals/src/scorers/code/tone/index.ts
- https://raw.githubusercontent.com/mastra-ai/mastra/HEAD/packages/evals/src/scorers/code/tone/index.ts
- https://mastra.ai/docs/evals/quick-checks
- https://www.npmjs.com/package/@mastra/otel-exporter
- https://registry.npmjs.org/%40mastra/otel-exporter
- https://www.npmjs.com/package/@mastra/observability
- https://registry.npmjs.org/%40mastra/observability
- https://www.npmjs.com/package/@mastra/otel-bridge
- https://registry.npmjs.org/%40mastra/otel-bridge
- https://mastra.ai/docs/observability/tracing/overview
- https://mastra.ai/reference/observability/tracing/configuration
- https://github.com/mastra-ai/mastra/blob/HEAD/observability/mastra/package.json
- https://raw.githubusercontent.com/mastra-ai/mastra/HEAD/observability/mastra/package.json
- https://github.com/mastra-ai/mastra/blob/HEAD/observability/otel-exporter/package.json
- https://raw.githubusercontent.com/mastra-ai/mastra/HEAD/observability/otel-exporter/package.json
- https://github.com/mastra-ai/mastra/blob/HEAD/observability/mastra/src/index.ts
- https://raw.githubusercontent.com/mastra-ai/mastra/HEAD/observability/mastra/src/index.ts
- https://github.com/mastra-ai/mastra/blob/HEAD/observability/mastra/scripts/generate-pricing.ts
- https://raw.githubusercontent.com/mastra-ai/mastra/HEAD/observability/mastra/scripts/generate-pricing.ts
- https://github.com/mastra-ai/mastra/blob/HEAD/observability/mastra/src/metrics/pricing-registry.ts
- https://raw.githubusercontent.com/mastra-ai/mastra/HEAD/observability/mastra/src/metrics/pricing-registry.ts
- https://github.com/mastra-ai/mastra/blob/HEAD/observability/mastra/src/exporters/index.ts
- https://raw.githubusercontent.com/mastra-ai/mastra/HEAD/observability/mastra/src/exporters/index.ts
- https://github.com/mastra-ai/mastra/blob/HEAD/observability/otel-exporter/src/index.ts
- https://raw.githubusercontent.com/mastra-ai/mastra/HEAD/observability/otel-exporter/src/index.ts
- https://github.com/mastra-ai/mastra/blob/HEAD/observability/mastra/src/metrics/index.ts
- https://raw.githubusercontent.com/mastra-ai/mastra/HEAD/observability/mastra/src/metrics/index.ts
- https://github.com/mastra-ai/mastra/blob/HEAD/observability/otel-exporter/src/types.ts
- https://raw.githubusercontent.com/mastra-ai/mastra/HEAD/observability/otel-exporter/src/types.ts
- https://mastra.ai/docs/observability/metrics/overview
- https://mastra.ai/reference/core/mastra-model-gateway
- https://mastra.ai/reference/observability/metrics/automatic-metrics
- https://mastra.ai/docs/server/overview
- https://mastra.ai/docs/server/server-adapters
- https://mastra.ai/docs/deployment/mastra-server
- https://mastra.ai/reference/v1/server/mastra-server
- https://www.npmjs.com/package/@mastra/deployer
- https://registry.npmjs.org/%40mastra/deployer
- https://www.npmjs.com/package/@mastra/hono
- https://registry.npmjs.org/%40mastra/hono
- https://www.npmjs.com/package/@mastra/server
- https://registry.npmjs.org/%40mastra/server
- https://www.npmjs.com/package/mastra
- https://registry.npmjs.org/mastra
- https://www.npmjs.com/package/@mastra/mcp
- https://registry.npmjs.org/%40mastra/mcp
- https://www.npmjs.com/package/@mastra/rag
- https://registry.npmjs.org/%40mastra/rag
- https://www.npmjs.com/package/@mastra/memory
- https://registry.npmjs.org/%40mastra/memory
- https://github.com/mastra-ai/mastra/releases.atom
- https://registry.npmjs.org/@mastra/core/1.0.0
- https://www.npmjs.com/package/@mastra/ai-sdk
- https://registry.npmjs.org/%40mastra/ai-sdk
- https://mastra.ai/reference/tools/mcp-client/llms.txt
- https://mastra.ai/docs/connections/mcp
- https://mastra.ai/reference/migrations/mcp-v2
- https://github.com/mastra-ai/mastra/blob/main/docs/src/content/en/reference/tools/mcp-server.mdx
- https://github.com/mastra-ai/mastra/blob/main/docs/src/content/en/docs/connections/mcp.mdx
- https://github.com/mastra-ai/mastra/blob/main/docs/src/mastra-code/configuration.mdx
- https://mastra.ai/docs/mcp/publishing-mcp-server
- https://mastra.ai/reference/tools/mcp-server
- https://mastra.ai/reference/cli/mastra
- https://github.com/mastra-ai/mastra/blob/HEAD/packages/core/CHANGELOG.md
- https://raw.githubusercontent.com/mastra-ai/mastra/HEAD/packages/core/CHANGELOG.md
- https://mastra.ai/reference/migrations/upgrade-to-v1/tools
- https://mastra.ai/blog/announcing-mastra-1
- https://raw.githubusercontent.com/mastra-ai/mastra/%40mastra%2Fcore%400.22.2/packages/core/src/tools/tool.ts
- https://raw.githubusercontent.com/mastra-ai/mastra/%40mastra%2Fcore%400.22.2/packages/core/src/tools/types.ts
- https://raw.githubusercontent.com/mastra-ai/mastra/%40mastra%2Fcore%401.0.0-beta.27/packages/core/src/tools/tool.ts
- https://github.com/mastra-ai/mastra/pull/23875
- https://github.com/mastra-ai/mastra/releases/tag/@mastra/core@1.68.0
