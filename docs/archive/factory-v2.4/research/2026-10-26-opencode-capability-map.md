# OpenCode capability map for headless desk agents (research-gateway job ee7442d7, deep, 2026-10-26)

> Status ok · 188 pages retrieved · 202 citations kept, 0 dropped · $0.40. Mostly pinned to v1.19.4; v2 facts marked. Token/cost and OTel were not covered: the measured v2 facts live in agent-gateway `docs/opencode-v2.md` and `spikes/06-telemetry/REPORT.md`.

## Bottom line

1. **`opencode serve` + `@opencode-ai/sdk`** — the headless surface is real and documented in v1.19.4: `opencode serve` starts a standalone server (default `127.0.0.1`, port `0` in source / `4096` in docs and in the SDK's spawn), HTTP Basic auth via `OPENCODE_SERVER_PASSWORD`, an OpenAPI 3.1 spec at `GET /doc`, REST session lifecycle (`POST /session`, `POST /session/:sessionID/message`, `…/prompt_async`, `…/fork`, `…/abort`, `DELETE /session/:sessionID`), history via `GET /session/:sessionID/message`, an SSE stream at `GET /event` (plus `GET /global/event`), and the SDK trio `createOpencodeClient()` / `createOpencodeServer()` / `createOpencode()`; session **sharing is discontinued** — the share route still exists but always returns HTTP 500 — and session export is a separate CLI command, `opencode export [sessionID]`, which prints `{info, messages}` JSON to stdout.
2. **`opencode run`** — one-shot/non-interactive mode exists in both CLI lines with `--agent`, `--model/-m`, `--session/-s`, `--continue/-c`, `--fork`, `--format default|json`; `--format json` is **NDJSON, one object per line** (types `text`, `reasoning`, `step_start`, `step_finish`, `tool_use`, `error`), never an array; piped stdin is merged into the message; without `--auto` (aliases `--yolo`, `--dangerously-skip-permissions`) permission requests are **auto-rejected**; v2 drops `--attach/-p/-u/--dir/--port/--variant/--command` in favour of global `--server`/`--standalone`.
3. **Agent definitions** — v1 uses the `agent` map in `opencode.json` and markdown files in `.opencode/agent/` *or* `.opencode/agents/` (plus global `~/.config/opencode/agents/`), with `description`, `model`, `variant`, `temperature`, `top_p`, `prompt`, `tools`, `permission`, `mode` (`subagent|primary|all`), `hidden`, `color`, `steps`/`maxSteps`, `options`, `disable`; v2 renames the block to `agents` and the fields to `system` / `disabled` / `steps` / `permissions`, and **no longer honours `temperature`, `top_p`, `prompt` or `tools`** there.
4. **Extension points** — custom tools live in `.opencode/tool(s)/*.ts` using `import { tool } from "@opencode-ai/plugin"` (Zod `args`, `execute(args, context)`); plugins load from `.opencode/plugin(s)/*.{ts,js}` or the `plugin` config array with a fixed hook set running in-process; skills are `<dir>/skills/<name>/SKILL.md` with progressive disclosure (`name` + `description` advertised, body loaded by the `skill` tool) gated by `permission.skill`; commands are `{command,commands}/**/*.md` templates, and **every v1 skill is also registered as a slash command**.
5. **Isolation on one host** — `OPENCODE_CONFIG` (file), `OPENCODE_CONFIG_DIR` (extra config dir), `OPENCODE_CONFIG_CONTENT` (inline JSON, used by the SDK), `OPENCODE_PERMISSION`, `OPENCODE_DB`, `OPENCODE_DISABLE_*`, and XDG roots (`XDG_CONFIG_HOME`/`XDG_DATA_HOME`/`XDG_CACHE_HOME`/`XDG_STATE_HOME`, each joined with `opencode`) give per-instance isolation; boolean flags accept only `"true"` or `"1"`; v1 gives one server per `opencode serve` process (`--port`, `--hostname`, `--mdns-domain`), while **v2 defaults to one shared background server per user** unless `--standalone`/`--server` is used.
6. **Provider config for OpenAI-compatible endpoints (DeepSeek etc.)** — v1: a `provider` entry with `"npm": "@ai-sdk/openai-compatible"`, `options.baseURL`, `options.apiKey: "{env:VAR}"`, and a `models` map where you must set `limit.context`/`limit.output` yourself because models.dev metadata only exists for known providers; model strings are `provider/model`; credentials from `/connect` land in `~/.local/share/opencode/auth.json`.
7. **v1 vs v2** — v2 is a second API generation: `/api/`-prefixed routes with brace params and cursor pagination, a new plugin API, `cli.json` replacing `tui.json`, `provider`→`providers` / `agent`→`agents` / `command`→`commands` / `plugin`→`plugins` / `permission`→`permissions` (rule array), LSP no longer run, several v1 fields accepted-but-ignored; both lines still use the singular `session` resource, and v1/v2 are no longer installed side by side by default.
8. **Token/cost accounting and OpenTelemetry — not researched in this run**; no findings are reported for that part of the query.

---

## 0. Which version this maps, and why it matters

Two shipping lines are live concurrently, and the query's "late 2026" lands on the boundary. **OpenCode 1** is npm `opencode-ai` `latest` = **1.19.4** (published 2026‑10‑26); **OpenCode 2** is npm `@opencode/cli` = **2.1.4**, published with bins `opencode` and `opencode2`. The GitHub repo behind `sst/opencode` now reports as **`anomalyco/opencode`**, MIT, default branch **`dev`**, and its latest *tagged release* is still **`v1.19.4`** (2026‑10‑22) even though `dev` carries v2. Docs split accordingly: `opencode.ai/docs` = v1, `opencode.ai/v2/docs` = v2. The JS SDK and plugin packages are pinned in lockstep: `@opencode-ai/sdk` `1.19.4` (last published 2026‑10‑26T05:09:52Z, dependency `cross-spawn 7.0.6`) and `@opencode-ai/plugin` `1.19.4` (depends on `zod 4.1.8`, `@opencode-ai/sdk 1.19.4`). Everything below is pinned to tag `v1.19.4` unless explicitly marked v2.

Practical consequence for a headless agent: build on v1.19.4 today (it is the only tagged release and the only documented server/SDK contract), and treat the v2 surface as a parallel, breaking API you should not mix into a v1 client.

## 1. `opencode serve` and `@opencode-ai/sdk`

### 1.1 Startup, flags, auth

`opencode serve` is declared in `packages/opencode/src/cli/cmd/serve.ts` as `command: "serve"`, `describe: "starts a headless opencode server"`, `builder: (yargs) => withNetworkOptions(yargs)`, `instance: false`; it logs `opencode server listening on http://<hostname>:<port>`. If no password is configured it prints `Warning: OPENCODE_SERVER_PASSWORD is not set; server is unsecured.` The same file notes that the server "loads instances per-request via x-opencode-directory header", so no ambient project context is needed at startup.

**Documented vs source disagreement on the port default.** The docs page renders usage `opencode serve [--port <number>] [--hostname <string>] [--cors <origin>]` with `--port` default **4096**, `--hostname` **127.0.0.1**, `--mdns` **false**, `--mdns-domain` **opencode.local**, `--cors` **[]**. The v1.19.4 source in `packages/opencode/src/cli/network.ts` declares `port: { …, default: 0 }` (ephemeral) with `config?.server?.port` as fallback, plus `mdns: { default: false }`, `"mdns-domain": { default: "opencode.local" }`, `cors: { … default: [] }`, and auto-sets hostname `0.0.0.0` when `mdns` is on. The 4096 you actually see comes from the SDK: `createOpencodeServer` spawns `opencode serve --hostname=… --port=4096` explicitly. Treat the repo default as `0` and 4096 as an SDK convention.

Auth is HTTP Basic on the server side (`packages/opencode/src/server/auth.ts`): `OPENCODE_SERVER_PASSWORD` (optional) and `OPENCODE_SERVER_USERNAME` (`withDefault("opencode")`), comparing `credentials.username` and the redacted password and emitting `Basic ${Buffer.from(username+":"+password).toString("base64")}`. The docs phrasing is identical in effect: "Set `OPENCODE_SERVER_PASSWORD` to protect the server with HTTP basic auth. The username defaults to `opencode`, or set `OPENCODE_SERVER_USERNAME` to override it." The server publishes an **OpenAPI 3.1** spec at `http://<hostname>:<port>/doc`. Running the bare `opencode` command starts TUI *and* server; `opencode serve` always starts a **new** standalone server.

### 1.2 Session endpoints

The route table in `packages/opencode/src/server/routes/instance/httpapi/groups/session.ts` uses the parameter name `:sessionID` (the docs render it as `:id`):

- `POST /session` (create; body `{ parentID?, title? }`), `GET /session`, `GET /session/status`
- `GET /session/:sessionID`, `PATCH /session/:sessionID`, `DELETE /session/:sessionID`
- `GET /session/:sessionID/message` (history, `query: limit?`), `GET /session/:sessionID/message/:messageID`
- `POST /session/:sessionID/message` — prompt **and wait**; `POST /session/:sessionID/prompt_async` — same payload, returns **204**
- `POST /session/:sessionID/fork` (body `{ messageID? }`, returns a Session), `POST /session/:sessionID/abort`
- also `children`, `todo`, `diff`, `init`, `summarize`, `command`, `shell`, `revert`, `unrevert`, `permissions/:permissionID`, `deleteMessage`, `deletePart`, `updatePart`
- OpenAPI identifiers are `session.list`, `session.create`, `session.get`, `session.delete`, `session.update`, `session.fork`, `session.abort`, `session.prompt`, `session.prompt_async`, `session.messages`, `session.message`, `session.share`, `session.unshare`; `permission.respond` is annotated `deprecated: true`.

### 1.3 The prompt payload (exact)

This is the field list a headless client actually sends, read from `packages/opencode/src/session/prompt.ts` at v1.19.4. `model` is **nested**, not top-level `modelID`:

```
PromptInput = {
  sessionID,                                  // path param on HTTP, omitted from the body
  messageID?, model?: { providerID, modelID }, agent?,
  noReply?, tools?, format?, system?, variant?,
  parts: [ TextPartInput | FilePartInput | AgentPartInput | SubtaskPartInput ]   // required
}
```

The HTTP body is `PromptPayload = Struct.omit(PromptInput.fields, ["sessionID"])`, so on the wire: `{ messageID?, model?: {providerID, modelID}, agent?, noReply?, tools?, format?, system?, variant?, parts }` — `sessionID` comes from the path.

- `noReply === true` persists the user message and **skips the assistant loop** (context injection without a completion).
- `system?: string` is copied onto the user message.
- `tools?: Record<string, boolean>` is **deprecated** ("tools and permissions have been merged"); the server converts each entry into a permission rule `{ permission: t, action: enabled ? "allow" : "deny", pattern: "*" }`.
- `format?: { type: "text" } | { type: "json_schema", schema, retryCount? }` — structured output, retry field named **`retryCount`** with decoding default `2`.
- `parts` union is discriminated on `type`: `text` (`text`), `file` (`mime`, `filename?`, `url?`, `source?`), `agent` (`name`), `subtask` (`prompt`, `description`, `agent`, `model?`, `command?`).

**Docs are stale/incomplete here.** The v1.19.4 `server.mdx` table lists the body as `{ messageID?, model?, agent?, noReply?, system?, tools?, parts }` — omitting `format` and `variant` — and the live SDK docs claim structured output is "only available on the client exported from @opencode-ai/sdk/v2". The repository schema accepts both `format` and `variant`, and the prompt loop reads `lastUser.format`; the schema is authoritative.

### 1.4 Event stream (SSE)

`GET /event` (`EventPaths.event = "/event"`, OpenAPI `event.subscribe`) returns `text/event-stream`; there is also `GET /global/event`. Docs: "First event is `server.connected`, then bus events". The v1 vocabulary in `packages/schema/src/v1/session.ts`:

- `session.created` / `session.updated` / `session.deleted` → `{ sessionID, info }`
- `message.updated` → `{ sessionID, info }`; `message.removed` → `{ sessionID, messageID }`
- `message.part.updated` → `{ sessionID, part, time }`; `message.part.delta` → `{ sessionID, messageID, partID, field, delta }`; `message.part.removed` → `{ sessionID, messageID, partID }`
- `session.diff`, `session.error` → `{ sessionID?, error }`
- `session.status` → `{ sessionID, status }` where status is `{type:"idle"} | {type:"retry", attempt, message, next, action?} | {type:"busy"}` — this is the turn-completion signal; `session.idle` still exists but is annotated `// deprecated`
- `permission.asked` → `{ id, sessionID, permission, patterns, metadata, always, tool?: {messageID, callID} }`; `permission.replied` → `{ sessionID, requestID, reply }` with `reply ∈ "once" | "always" | "reject"`

**Tool calls arrive as parts**: `ToolPart = { id ("prt…"), sessionID, messageID, type: "tool", callID, tool, state }` with `state.status ∈ pending | running | completed | error` (completed carries `input`, `output`, `title`, `metadata`, `time.start/end`). History rows are `{ info: User|Assistant, parts: Part[] }`.

A **second, durable vocabulary** also ships in v1.19.4 (`session.next.prompted`, `session.next.step.started/ended/failed`, `session.next.text.*`, `session.next.reasoning.*`, `session.next.tool.input.*`, `session.next.tool.called/progress/success/failed`, `session.next.shell.*`, `session.next.compaction.*`, `session.next.agent.switched`, `session.next.model.switched`, `session.next.retried`) and is merged into the SSE union via `event-manifest.ts`. A client that only listens for `message.part.updated` may therefore see a sparser stream than the full inventory.

**Operational caveat (provisional):** several issue reports describe `GET /event` / `GET /global/event` delivering only `server.connected`/`server.heartbeat` with no `message.*`/`session.status` events on 1.14.42, 1.14.48 and 1.18.25 — i.e. a client that waits on SSE for turn completion can appear to hang. The documented fallback is polling `GET /session/:id/message` and `GET /session/status`. Build that polling fallback into a production headless agent.

### 1.5 The JS/TS SDK

Install and import (docs verbatim): `npm install @opencode-ai/sdk`; `import { createOpencode, createOpencodeClient } from "@opencode-ai/sdk"`. The export map at v1.19.4 is `"."`, `"./client"`, `"./server"`, `"./v2"`, `"./v2/client"`, `"./v2/gen/client"`, `"./v2/server"`, `"./v2/types"`; types are generated with `@hey-api/openapi-ts 0.90.10`.

- `createOpencodeClient(config?: Config & { directory?: string })` — exported alongside `OpencodeClient` and `type Config as OpencodeClientConfig`. It sets `req.timeout = false`; when `config.directory` is set it adds header `x-opencode-directory: encodeURIComponent(directory)` (and, for GET/HEAD, moves it into a `?directory=` query param). Client options per docs: `baseUrl` (must be set explicitly; no default), `fetch`, `parseAs` (`auto`), `responseStyle` (`data` | `fields`), `throwOnError` (`false`).
- `createOpencodeServer({hostname, port, signal, timeout, config})` defaults `{ hostname: "127.0.0.1", port: 4096, timeout: 5000 }`; it spawns `opencode serve --hostname=… --port=…` with `OPENCODE_CONFIG_CONTENT: JSON.stringify(options.config ?? {})` injected into the env, resolves the URL by matching the `opencode server listening` line, and returns `{ url, close() }`.
- `createOpencode(options?)` returns `{ client, server }` — the one-call "spawn a private server and get a client" path, which is the cleanest isolation primitive on one host.
- Events: `const events = await client.event.subscribe(); for await (const event of events.stream) { … }`.
- Sessions via the client: `session.list()`, `session.get({path})`, `session.create({body})`, `session.delete({path})`, `session.update({path, body})`, `session.abort({path})`, `session.messages({path})`, `session.message({path})`, `session.prompt({path, body})`, `session.command`, `session.shell`, `session.revert`, `session.unrevert`, `postSessionByIdPermissionsByPermissionId({path, body})`. The docs' prompt example shows the nested model shape: `body: { model: { providerID: "anthropic", modelID: "claude-sonnet-5-5" }, parts: [{ type: "text", text: "Hello!" }] }`. The `/v2` client takes flat params instead (e.g. `client.session.prompt({ sessionID, parts, format })`).

### 1.6 Reading back history, export, share

- **History:** `GET /session/:sessionID/message` (or `session.messages()`); each row is `{ info, parts }` with tool parts carrying `state.input`/`state.output`.
- **Export:** `opencode export [sessionID]` **does exist** at v1.19.4 — `command: "export [sessionID]"`, `describe: "export session data as JSON"`, one optional positional and one option `--sanitize` ("redact sensitive transcript and file data"). It fetches the session and its messages and writes `JSON.stringify({ info, messages }, null, 2)` **to stdout** (progress lines like `Exporting session: <id>` and the interactive picker go to stderr; no file is created — redirect yourself). With no ID it lists sessions sorted by `time.updated` behind a "Select session to export" prompt; a bad ID fails with `Session not found: <id>`. `--sanitize` keeps the shape but substitutes `[redacted:text:<partID>]`-style placeholders and empties metadata to `{ redacted: "<kind>:<id>" }`. `opencode import <file>` consumes the same `{info, messages}` structure and now rejects `http(s)` arguments with "Importing from share URLs is no longer supported". Third-party corroboration of the shape: a Go implementation declares `ExportSession{ Info SessionInfo; Messages []ExportMessage }` / `ExportMessage{ Info MessageInfo; Parts []Part }` as "the top-level structure of `opencode export` output".
- **Sharing is dead.** `packages/opencode/src/share/session.ts` at v1.19.4: *"Session sharing was discontinued. The share endpoints stay for API compatibility: share fails and unshare only clears the local link."* The implementation is `return yield* Effect.fail(new Error("Session sharing has been discontinued"))`; the handler maps any failure to `HttpApiError.InternalServerError({})`, so `POST /session/:sessionID/share` **always returns HTTP 500** and never a URL. `unshare` works as a no-op that clears `share: undefined`. The route contract was *not* marked deprecated — it still advertises `success: Session.Info` and the description "Create a shareable link for a session, allowing others to view the conversation" — so OpenAPI/SDK metadata lies about this endpoint. Commit `d320177` deleted `share-next.ts` (the service that POSTed to `${baseUrl}/api/share` and returned `{id, secret, url}`), removed `ShareNext` from the layer graphs and share-URL import, and hard-disabled the TUI share menu (`const shareEnabled = () => false`). The route harness now asserts `.json(500, object, "status")` for share. Plan on file-based export, not share links.

## 2. `opencode run` (non-interactive)

### 2.1 v1 flags (verbatim from `packages/opencode/src/cli/cmd/run.ts` at v1.19.4, matching `/docs/cli`)

`run [message..]` — `--command`, `--continue`/`-c`, `--session`/`-s`, `--fork`, `--model`/`-m`, `--agent`, `--format` (`default` | `json`), `--file`/`-f` (array), `--title`, `--attach`, `--password`/`-p`, `--username`/`-u`, `--dir`, `--port`, `--variant`, `--thinking`, `--auto`; hidden `--share`, `--mini`, `--replay`, `--replay-limit`, `--interactive`/`-i`, `--yolo`, `--dangerously-skip-permissions`, `--demo`. Global: `--help/-h`, `--version/-v`, `--print-logs`, `--log-level`, `--pure`.

### 2.2 v2 flags (from `packages/cli/src/commands/commands.ts`, package `@opencode/cli` 2.1.4)

`--continue`/`-c`, `--session`/`-s` ("Session ID to continue, or to create if it does not exist"), `--fork`, `--model`/`-m` ("provider/model#variant"), `--agent`, `--format` (`default`|`json`), `--file`/`-f` (`Flag.atMost(100)`), `--title`, `--thinking`, `--auto`, hidden `--yolo`/`--dangerously-skip-permissions`. Globals: `--print-logs` ("Print logs to stderr (server logs require --standalone)"), `--standalone`, `--server <url>`.

**Removed in v2 run** (verified by reading the complete `commands.ts`): `--attach`, `--password`, `--username`, `--dir`, `--port`, `--variant`, `--command`. Remote targeting moved to the global `--server`/`--standalone` pair; the variant moved into `--model provider/model#variant`.

### 2.3 JSON output, stdin, permissions, exit codes, remote

- **JSON is NDJSON**, one object per line, never an array. Both versions write `JSON.stringify({ type, timestamp, sessionID, ...data }) + EOL`. v1 types: `text`, `reasoning`, `step_start`, `step_finish`, `tool_use` (each carrying a `part`), and `error` (`{ error }`). Text goes to stdout; `--format json` suppresses the formatted UI. There is **no versioned schema**; the docs say only "json (raw JSON events)".
- **Stdin:** v1 reads `await Bun.stdin.text()` when `!process.stdin.isTTY` and joins `message + "\n" + piped`; v2 does the same via `readStdin()`. Args after `--` are appended (v2: `[...input.message, ...process.argv.slice(slice + 1)]`). Empty message → `"You must provide a message"` (v2) / `"You must provide a message or a command"` (v1). `--file` sends base64 `data:` URLs capped at `ATTACH_FILE_MAX_BYTES` (10 MiB); v2 rejects directories.
- **Permissions:** `--auto` (or hidden `--yolo`/`--dangerously-skip-permissions`) replies `once`/`{decision:"once"}`; otherwise requests are **auto-rejected** (`reject`), and v2 additionally attaches a model-visible message ("This non-interactive run cannot ask the user for permission, so the request was rejected.") so the turn continues. New v1 sessions also get rules denying `question`, `plan_enter`, `plan_exit`.
- **Exit codes:** pre-flight failures call `process.exit(1)` (missing message, file not found, session not found, `--fork` without `--continue`/`--session`, failed chdir); runtime errors set `process.exitCode = 1` and, in JSON mode, emit an `error` line (`{"type":"error","timestamp":…,"sessionID":…,"error":{"type":"unknown","message":…}}` in v2).
- **Remote:** v1 uses `opencode run --attach http://localhost:4096 "…"` plus `--password`/`--username`; v2 uses `--server <url>` or `--standalone`.

Unverified for v2: the tail of `run/noninteractive.ts` was truncated, so whether v2 emits `tool_use`/`step_finish` events and what `usage`/`cost` they carry is unknown — do not assume parity with v1's event names.

## 3. Agent definitions

### 3.1 Locations and the V1/V2 split

`.opencode/agent/` (singular) still works. The config docs say the dirs "use **plural names** for subdirectories: `agents/`, `commands/`, `modes/`, `plugins/`, `skills/`, `tools/`, and `themes/`. Singular names (e.g., `agent/`) are also supported for backwards compatibility." The migration guide: "V1 agent files may use `agent/`, `agents/`, `mode/`, or `modes/`. V2 still discovers all four directories"; the preferred v2 path is `.opencode/agents/<name>.md` with global equivalent `~/.config/opencode/agents/<name>.md`. **File name = agent name**; nested paths become IDs (`team/reviewer.md` → `team/reviewer`). V1 `mode/` files were primary agents — moving one into `agents/` requires adding `mode: primary`.

Currently the live schema carries **both**: `agent`, `permission`, `tools`, `mode`, `provider`, `command`, `plugin` are flagged `"deprecated": true`, with `agents`, `permissions`, `commands`, `plugins`, `providers` as native v2 names. V1 config is still read (normalized in memory, never rewritten).

### 3.2 Fields

**V1 `AgentConfig`** (schema + `agents.mdx`): `description` (**required**), `mode` (`subagent` | `primary` | `all`), `model`, `variant`, `temperature`, `top_p`, `prompt`, `tools`, `disable`, `hidden`, `options`, `color`, `steps`, `maxSteps` (`"@deprecated Use 'steps' field instead."`), `permission`. Markdown frontmatter accepts the same keys; the body is the system prompt.

**V2 `Config.AgentEncoded`**: `model`, `request{headers, body}`, `system`, `description`, `mode`, `hidden`, `color` (hex `^#[0-9a-fA-F]{6}$` only), `steps`, `disabled`, `permissions` (ordered `{action, resource, effect}` array). Renames: `prompt`→`system`, `disable`→`disabled`, `permission`→`permissions`, `maxSteps`→`steps`. **No native `temperature`, `top_p`, `prompt`, `tools`, `disable` or `maxSteps`** — and the docs are blunt: "Agent `request.body` is kept but not sent to the model, so V1 `temperature`, `top_p`, and `options` have no effect there. Set them on a model variant instead." For a cheap-model agent that needs low temperature, that is the single most important v1→v2 behaviour change.

**Model strings.** V1: `provider/model-id` (`anthropic/claude-sonnet-5-5`). V2: `provider/model#variant` (`anthropic/claude-sonnet-5-5#high`), or expanded `{providerID, model, variant}`; schema pattern `^[^/#]+\/[^#]+(?:#[^#]+)?$`. V1 inheritance: "If you don't specify a model, primary agents use the model globally configured while subagents will use the model of the primary agent that invoked the subagent."

**Prompt inline vs file.** `"prompt": "{file:./prompts/code-review.txt}"`, resolved relative to the config file's directory (works for both global and project config). `{file:path}` is the general substitution form (relative to the config dir, or absolute `/`…`~`), with `{env:VAR}` as the env counterpart.

**Tools allowlist + wildcards (v1).** Per-tool booleans, deprecated in favour of permissions: "`true` is equivalent to `{"*": "allow"}` permission and `false` is equivalent to `{"*": "deny"}` permission." Wildcards match MCP namespaces: `"mymcp_*": false` disables all tools from that server. The V2 equivalent is order-sensitive: `{"action":"*","resource":"*","effect":"deny"}` then `{"action":"read","resource":"src/**","effect":"allow"}`, because "the last matching rule wins, so put broad rules before exceptions."

**Permissions (v1).** Each key takes `"ask"` / `"allow"` / `"deny"`; keys are `read`, `edit` (write/edit/apply_patch), `glob`, `grep`, `list`, `bash`, `task`, `todowrite`, `external_directory`, `webfetch`, `websearch`, `lsp`, `skill`, `question`, `doom_loop`. Per-command bash patterns are glob-based and last-match-wins: `"bash": {"*": "ask", "git status *": "allow"}` — "put the `*` wildcard first and specific rules after." Agent-level permission overrides are additive to the top-level `permission`; Plan's defaults "are applied before your top-level `permission` config", so a global `"edit": "allow"` leaks into Plan unless overridden under `agent.plan.permission`.

**`hidden`** hides a subagent from the `@` autocomplete ("only applies to `mode: subagent`" in v1) but "Hidden agents can still be invoked by the model via the Task tool if permissions allow"; v2 adds "This controls visibility, not security." **`color`** accepts hex or theme names (`primary`, `secondary`, `accent`, `success`, `warning`, `error`, `info`) in v1; v2 restricts it to hex only.

**`steps`** caps agentic iterations: "When the limit is reached, the agent receives a special system prompt instructing it to respond with a summarization of its work and recommended remaining tasks." This plus `permission` denial of `task` is the practical way to bound a cheap model's loop.

### 3.3 Selection and subagents

`default_agent` "determines which agent is used when none is explicitly specified"; it "must be a primary agent… If the specified agent doesn't exist or is a subagent, OpenCode will fall back to `"build"` with a warning" (v2 adds: "build, then the first visible primary-capable agent"). In the TUI, primary agents cycle with **Tab** or the `switch_agent` keybind; subagents are invoked automatically from their descriptions or manually by **@-mention**. CLI: `--agent` exists on both `opencode` (TUI) and `opencode run` ("Agent to use"), `--model`/`-m` is "Model to use in the form of provider/model"; `opencode agent list` lists loaded agents, `opencode debug agent <name>` dumps one's resolved config.

**Task tool** (`packages/opencode/src/tool/task.ts` at v1.19.2): params `description` ("A short (3-5 words) description of the task"), `prompt`, `subagent_type`, optional `task_id` (resume the same child session), optional `command`, optional `background` (requires `OPENCODE_EXPERIMENTAL_BACKGROUND_SUBAGENTS=true`). Depth is enforced by walking the `parentID` chain and failing with `Subagent depth limit reached (${cfg.subagent_depth ?? 1})` — default **1**, meaning primaries may launch subagents but those may not nest further; config docs: set `2` to allow, `0` to forbid subagent launches entirely. Independently of depth, the child gets hardcoded denies for `todowrite` and for `task` itself unless the subagent's rules already mention them, so recursion is blocked by default.

**Built-ins.** V1: primary `build` ("the default primary agent with all tools enabled"), `plan` ("Denies file edits, writes, and patches except Markdown plan files in `.opencode/plans/`"), plus hidden `compaction`, `title`, `summary`; subagents `general` ("full tool access except `todowrite`") and `explore` ("fast, read-only agent"). V2 lists `build`, `plan`, `general` ("cannot launch more subagents"), `explore`, the same hidden three, and states "V2 has no built-in scout agent"; a built-in is overridden "by using the same ID". The v1 page's own claim of "two built-in primary agents and three built-in subagents" contradicts its two-entry subagent list — don't rely on that sentence.

**Flagged disagreement:** V1 docs say `mode` "defaults to `all`"; V2 docs say "When omitted on a new custom agent, it defaults to `primary`." The schema simply enumerates the three values with no default, so behaviour is version-dependent — set `mode` explicitly.

## 4. Custom tools, plugins/hooks, skills, commands

### 4.1 Custom tools (`.opencode/tool/*.ts`)

Docs place them in `.opencode/tools/` and `~/.config/opencode/tools/`; the registry in source globs **both** singular and plural: `Glob.scanSync("{tool,tools}/*.{js,ts}", …)`, so `.opencode/tool/*.ts` loads too (the docs only mention `tools/`). Config dirs scanned include `Global.Path.config`, every project `.opencode` up to the worktree, `~/.opencode` and `OPENCODE_CONFIG_DIR`.

Definition, verbatim from `packages/plugin/src/tool.ts`:

```
import { tool } from "@opencode-ai/plugin"   // tool.schema = z  (zod 4.1.8)

export function tool<Args extends z.ZodRawShape>(input: {
  description: string
  args: Args
  execute(args: z.infer<z.ZodObject<Args>>, context: ToolContext): Promise<ToolResult>
}): typeof input
```

`ToolResult` = `string | { title?, output: string, metadata?, attachments?: ToolAttachment[] }`. `ToolContext` = `{ sessionID, messageID, agent, directory, worktree, abort: AbortSignal, metadata(input: {title?, metadata?}): void, ask(input: AskInput): Promise<void> }` — the docs only document `agent, sessionID, messageID, directory, worktree`, so `abort`, `metadata()` and `ask()` are available but undocumented (useful: `ask()` surfaces approval prompts from inside a tool).

**Naming:** `const namespace = path.basename(match, path.extname(match))`; the `default` export is registered bare, any other export becomes `` `${namespace}_${id}` `` — so `math.ts` with `add`/`multiply` yields `math_add`, `math_multiply`. Plugin-supplied tools use the object key verbatim. A custom tool with a built-in's name **wins** (built-ins registered first; the model-facing map is keyed by id). Only exports that carry `args`, `description`, `execute` are registered.

**How the schema reaches the model:** args are converted with `z.toJSONSchema(z.object(args), {io:"input"})` when every value carries `_zod`; otherwise each entry is treated as a raw JSON Schema property with all keys required. Each request then passes through `yield* plugin.trigger("tool.definition", { toolID }, output)`, so a plugin can rewrite `description`/`parameters` per call.

### 4.2 Plugins and hooks

Auto-discovery glob is `Glob.scan("{plugin,plugins}/*.{ts,js}", …)` — `.opencode/plugin/` **and** `.opencode/plugins/` (plus global equivalents and `~/.opencode/plugin`). The config array accepts `"pkg"`, `"pkg@1.2.3"`, `"./file.ts"`, and `["pkg", {options}]` tuples: `plugin?: Array<string | [string, PluginOptions]>`.

Type: `Plugin = (input: PluginInput, options?: PluginOptions) => Promise<Hooks>` with `PluginInput = { client, project, directory, worktree, experimental_workspace: { register }, serverUrl: URL, $: BunShell }`. Plugins run **in-process inside the OpenCode server** — `Plugin.trigger` loops the registered hooks sequentially (`for (const hook of s.hooks) { … fn(input, output) }`) and returns the *same* `output` object, which is how in-place mutation propagates. The model never runs plugin code; plugins are not sandboxed and can do anything the server can.

Full `Hooks` key list at v1.19.4 (source is authoritative; the `/docs/plugins` page lists *bus events* rather than this interface — there is no separate `/docs/hooks` page): `dispose`, `event`, `config`, `tool`, `auth`, `provider`, `"chat.message"`, `"chat.params"`, `"chat.headers"`, `"permission.ask"`, `"command.execute.before"`, `"tool.execute.before"`, `"tool.execute.after"`, `"shell.env"`, `"tool.definition"`, `"experimental.chat.messages.transform"`, `"experimental.chat.system.transform"`, `"experimental.provider.small_model"`, `"experimental.session.compacting"`, `"experimental.compaction.autocontinue"`, `"experimental.text.complete"`.

The payloads that give a plugin powers an agent/tool cannot have directly:

| hook | input | mutable output |
|---|---|---|
| `chat.params` | `{model, provider, message}` | `{ temperature, topP, topK, maxOutputTokens, options }` |
| `chat.headers` | `{model, provider, message}` | `{ headers }` |
| `chat.message` | `{model, message, parts}` | `{ message: UserMessage; parts: Part[] }` |
| `experimental.chat.system.transform` | `{model, provider, message}` | `{ system: string[] }` |
| `experimental.chat.messages.transform` | `{model, provider, message}` | `{ messages: {info, parts}[] }` |
| `tool.execute.before` | `{ tool, sessionID, callID }` | `{ args }` |
| `tool.execute.after` | `{ tool, sessionID, callID, args }` | `{ title, output, metadata }` |
| `permission.ask` | `Permission` | `{ status: "ask" \| "deny" \| "allow" }` |
| `shell.env` | `{ cwd, sessionID?, callID? }` | `{ env }` |

**Three caveats that bite:**
1. `"permission.ask"` is declared in the public type but has had **no call site since v1.3.0** — handlers typecheck and silently never fire. React to the `permission.asked` *event* instead.
2. The before-hook call site is `yield* plugin.trigger("tool.execute.before", {...}, { args }); const result = yield* item.execute(args, ctx)` — in-place mutation of `output.args.command` reaches the tool, but reassigning `output.args` to a new object does not.
3. An open request claims mutated `output.args` is discarded and exceptions thrown in `tool.execute.before` are swallowed, which would break the docs' own "throw to block" example. Source shows no try/catch around the trigger, so throwing appears to work — one source, unresolved.
4. Do not mix APIs: v2 uses a different package shape — `import { Plugin } from "@opencode/plugin"`, `Plugin.define({ id, setup(ctx) })`, namespaced registrations like `ctx.tool.hook("execute.before")`.

Kill-switches: `OPENCODE_PURE=1` skips external plugins, `OPENCODE_DISABLE_DEFAULT_PLUGINS=1` drops the bundled ones.

### 4.3 Skills (`SKILL.md`)

Locations (v1 docs): `.opencode/skills/<name>/SKILL.md`, `~/.config/opencode/skills/<name>/SKILL.md`, walking up to the git worktree, plus compat dirs `.claude/skills/`, `~/.claude/skills/`, `.agents/skills/`, `~/.agents/skills/`. Source disagrees with the docs on the singular form: v1.19.4 uses `const OPENCODE_SKILL_PATTERN = "{skill,skills}/**/SKILL.md"` over opencode config dirs, so `.opencode/skill/…` is in scope, while external dirs use the plural-only `"skills/**/SKILL.md"` — but user reports filed in the v1 era say the brace glob did not actually match the singular path, so treat the singular form as *provisional*, not as a supported layout.

Frontmatter: `name` (required, `^[a-z0-9]+(-[a-z0-9]+)*$`, must match the directory), `description` (required, 1–1024 chars), `license`, `compatibility`, `metadata` (string→string). Unknown fields are ignored. Code requires a `name` string plus optional `description`; a duplicate name logs a warning and the later one wins.

Injection is **progressive**: only `name` + `description` are advertised (`<available_skills><skill><name>…</name><description>…</description><location>…</location></skill>`, and skills without a description are dropped), and the body loads on demand via `skill({ name: "…" })`. Agent scoping: `permission.skill` pattern map (`allow`/`deny`/`ask`), e.g. `{ "permission": { "skill": { "*": "allow", "internal-*": "deny" } } }`, overridable per agent (`agent.plan.permission.skill`), plus `tools.skill: false` to omit `<available_skills>` entirely; code filters with `Permission.evaluate("skill", name, agent.permission)`. Extra paths/URLs come from `cfg.skills.paths` / `cfg.skills.urls` (undocumented on the skills page). Env: `OPENCODE_DISABLE_EXTERNAL_SKILLS`, `OPENCODE_DISABLE_CLAUDE_CODE_SKILLS`, `OPENCODE_DISABLE_CLAUDE_CODE`; `opencode debug skill` lists them.

### 4.4 Custom commands

v1: markdown in `.opencode/commands/` or `~/.config/opencode/commands/`; the loader globs `"{command,commands}/**/*.md"` per config dir, so `.opencode/command/*.md` **also works**. Frontmatter: `description`, `agent`, `model`, `subtask` ("force the command to trigger a subagent invocation"); body is the template. Placeholders: `$ARGUMENTS`, `$1..$n`, `` !`cmd` `` (executed in the project root), `@src/components/Button.tsx` (inlined). JSON config equivalent is `command` with a required `template`. The registry pre-registers `init` ("guided AGENTS.md setup") and `review` ("review changes [commit|branch|pr], defaults to uncommitted", `subtask: true`). `Command.Info` = `{ name, description?, agent?, model?, source?: "command"|"mcp"|"skill", template, subtask?, hints }`.

**The key skill↔command interaction:** every v1 skill is also exposed as a slash command — the command layer iterates `yield* skill.all()` and registers each with `source: "skill"` (skipped if a command of that name exists), appending "Base directory for this skill: …" to the template. Note it uses `skill.all()`, *not* the agent-filtered `available(agent)`.

**Non-interactive invocation:** `opencode run --command <name>` exists in v1 (documented as "The command to run, use message for args"), so a command template can be driven from a headless script; the exact argument-binding grammar is not documented anywhere and the v2 CLI page never mentions `--command`.

Documented TUI slash commands (the page's own "all available" list): `/connect`, `/compact` (alias `/summarize`), `/details`, `/editor`, `/exit` (`/quit`,`/q`), `/export`, `/help`, `/init`, `/models`, `/new` (`/clear`), `/redo`, `/sessions` (`/resume`,`/continue`), `/themes`, `/thinking`, `/undo`, `/update` — **`/share` is not there**. v2 commands move to `.opencode/commands/` ("the legacy singular directories `command/` are also discovered"), nested paths become names (`/team/review`), the frontmatter field is `subagent` ("`subtask` Deprecated alias"), `model` is `provider/model#variant`, and **"Stored templates do not expand @path"** — a real behaviour change from v1's `@file` inlining. v2 skills add `metadata: { opencode/autoinvoke: false }` or `disable-model-invocation: true` to keep a skill out of the model's list, `@skill-id` user mentions, and `permissions` arrays per agent.

## 5. Multiple isolated configs and instances on one host

### 5.1 Env vars and precedence (v1)

Documented env vars: `OPENCODE_CONFIG` ("Path to config file"), `OPENCODE_TUI_CONFIG`, `OPENCODE_CONFIG_DIR` ("Path to config directory"), `OPENCODE_CONFIG_CONTENT` ("Inline json config content"), `OPENCODE_PERMISSION` (inline JSON permissions), `OPENCODE_DB` ("Database path; relative paths resolve under the data directory"), `OPENCODE_DISABLE_PROJECT_CONFIG`, the `OPENCODE_DISABLE_*` / `OPENCODE_ENABLE_*` / `OPENCODE_EXPERIMENTAL_*` families (`…-AUTOUPDATE`, `-PRUNE`, `-AUTOCOMPACT`, `-DEFAULT_PLUGINS`, `-LSP_DOWNLOAD`, `-MODELS_FETCH`, `-MOUSE`, `-CLAUDE_CODE{,_PROMPT,_SKILLS}`, `-EXTERNAL_SKILLS`, `-EMBEDDED_WEB_UI`, `-FFF`), `OPENCODE_SERVER_PASSWORD`/`_USERNAME`, `OPENCODE_MODELS_URL`/`_PATH`, `OPENCODE_PURE`, `OPENCODE_CLIENT`.

**Boolean semantics are strict:** `flag.ts` implements `const value = process.env[key]?.toLowerCase(); return value === "true" || value === "1"` — `OPENCODE_DISABLE_AUTOUPDATE=yes` behaves as unset. `OPENCODE_CLIENT` defaults to `"cli"`; `OPENCODE_DISABLE_FFF` defaults true on `win32`. `OPENCODE_CONFIG_DIR`, `OPENCODE_PURE`, `OPENCODE_PERMISSION`, `OPENCODE_CLIENT` are getters evaluated at access time rather than module load.

**Load order** (`config.ts`, `loadInstanceState`, later wins): remote `.well-known/opencode` → global dir (`config.json` → `opencode.json` → `opencode.jsonc`) → the `OPENCODE_CONFIG` file → project `opencode.jsonc`/`opencode.json` walking cwd→worktree, outermost first, so within one dir `opencode.json` beats `opencode.jsonc` → `.opencode` dirs plus `OPENCODE_CONFIG_DIR` (loaded last in that list, and also supplying agents/commands/modes/plugins) → `OPENCODE_CONFIG_CONTENT` → Console/account org config → managed dir → macOS managed preferences → `OPENCODE_PERMISSION`. Two gaps to know: the docs' precedence table omits the account layer, and `globalConfigFile()` prefers/creates `opencode.jsonc` while the docs name `~/.config/opencode/opencode.json`. Merge semantics: `mergeDeep` for objects, `instructions` union-deduped, arrays deep-merged, `$schema` auto-injected as `https://opencode.ai/config.json`. Substitution: `{env:VAR}` (unset → empty string) and `{file:path}` (relative to config dir, or `/`/`~`).

Managed config sits at highest priority and can override your isolation: `/Library/Application Support/opencode/` (macOS), `/etc/opencode/` (Linux), `%ProgramData%\opencode` (Windows), plus the `ai.opencode.managed` macOS preference domain. v2 docs describe a different order (system config applied last; "every discovered `.opencode` config overrides every direct config").

### 5.2 Where state lives, and how to isolate

All roots are computed at module load as `path.join(xdg*, "opencode")` using the `xdg-basedir` package — so **set XDG vars before exec**:

- config `$XDG_CONFIG_HOME/opencode`
- data `$XDG_DATA_HOME/opencode` — contains `auth.json` (API keys/OAuth), `opencode.db` (SQLite: projects, sessions, messages), `log/`, `snapshot/`
- cache `$XDG_CACHE_HOME/opencode` — provider packages, `bin/`
- state `$XDG_STATE_HOME/opencode` — the flock
- tmp `$TMPDIR/opencode`

`opencode debug paths [selector]` prints them; `opencode debug paths <selector>` in v2 takes `db, home, data, config, cache, state, tmp, bin, log, repos`.

**Isolation recipes that actually separate state:** give each agent its own `XDG_DATA_HOME` (this alone splits credentials, DB and logs), its own `XDG_CONFIG_HOME` or `OPENCODE_CONFIG_DIR`, and `OPENCODE_DB` if you want two instances sharing a data dir but not a database. `OPENCODE_CONFIG_CONTENT` (what `createOpencodeServer` injects) gives you per-spawn config without touching disk.

### 5.3 N concurrent instances

v1: each `opencode serve` is a **new process with its own project context (process cwd)** and its own `--port`/`--hostname`; `opencode serve` never reuses a TUI's server. There is no documented `--directory` flag on `serve`, so set the cwd per process. For LAN discovery, set `server.mdnsDomain` / `--mdns-domain` — the docs note it is "Useful for running multiple instances on the same network". `opencode run --dir` and `opencode attach [url] --dir` exist for client side; `OPENCODE_PORT` appears only on the troubleshooting page (desktop app) and is **not** in the CLI env table.

v2 flips the model: by default OpenCode "discovers or starts one shared background server for your user account. Every local OpenCode client connects to that server, which owns sessions, configuration, integrations, permissions, and tool execution." For isolation use `--standalone` ("Run with a private server instead of the background service") or `--server <url>`, and `opencode service set disabled true` to stop the shared service.

**Migration:** v1→v2 key renames are `provider`→`providers` (with `settings`/`models`/`modelID`), `agent`→`agents`, `command`→`commands`, `plugin`→`plugins`, `permission`→`permissions` (ordered rule array), `disabled_providers`→`policies`, `snapshot`→`snapshots`, `autoupdate`→`update`, `attachment.image`→`media.image`, `mcp`→`mcp.servers`. V1 and V2 both use the `opencode` command and are "no longer installed side by side by default"; a package-managed v1 install must be removed before installing v2.

## 6. Provider config for OpenAI-compatible endpoints (DeepSeek and friends)

### 6.1 The v1 `provider` block (verbatim shape)

```json
{ "$schema": "https://opencode.ai/config.json",
  "provider": { "myprovider": {
    "npm": "@ai-sdk/openai-compatible",
    "name": "My AI Provider Display Name",
    "options": {
      "baseURL": "https://api.myprovider.com/v1",
      "apiKey": "{env:ANTHROPIC_API_KEY}",
      "headers": { "Authorization": "Bearer custom-token" }
    },
    "models": { "my-model-name": {
      "name": "My Model Display Name",
      "limit": { "context": 200000, "output": 65536 } } } } } }
```

Rules that matter for a cheap-model agent:

- **`npm` chooses the wire protocol**: `@ai-sdk/openai-compatible` for `/v1/chat/completions`; `@ai-sdk/openai` if the provider uses `/v1/responses`; overridable per model via `provider.npm`.
- **`limit.context` / `limit.output` are mandatory in practice for custom providers**: models.dev supplies them only for known providers, and OpenCode needs them "to know how much context is left". Omitting them on a DeepSeek-compatible endpoint breaks context accounting/compaction.
- **Timeouts**: provider `options` accept `timeout` (whole request, disabled by default), `headerTimeout` (default 300000 = 5 min), `chunkTimeout` (300000 ms in the v1 docs, though §7 treats that default as unconfirmed; aborts when no chunk arrives), and `setCacheKey`.
- **Model strings** are `provider/model` (e.g. `"model": "anthropic/claude-sonnet-5-5"`), also for `small_model`; v2 adds `#variant`.
- **Credentials**: `/connect` → **Other** → provider id → API key, stored in `~/.local/share/opencode/auth.json`; the prompt warns "This only stores a credential for myprovider - you will need to configure it in opencode.json"; verify with `opencode auth list`.
- **Cheap-model quirks verified**: reasoning deltas need `"reasoning": true` plus `"interleaved": { "field": "reasoning_content" }`; "DeepSeek only applies temperature with thinking off", so a temperature setting silently does nothing while reasoning is on; in v2, discovered **vLLM models start with tools disabled** because discovery can't infer tool support; v2's request compression defaults to zstd for ChatGPT sign-ins and "most providers and gateways reject compressed bodies" — set `settings.encoding` explicitly (`"zstd" | "gzip" | "none"`) or leave it off for a gateway.

Two things not verifiable from these sources: the authoritative types/defaults for per-model `tool_call`, `attachment`, `reasoning`, `temperature`, `id` (the config schema page could not be read; the names come only from the v2 migration list of ignored v1 fields), and an `opencode models` listing command (the CLI page could not be re-read in that pass).

### 6.2 v2 provider shape

Custom providers move under plural `providers` with `name`, `env` (ordered env var names for the credential), `package` (native packages, e.g. `@opencode/ai/providers/openai-compatible`, `/openai`, `/openai/chat`, `/openai/responses`, `/anthropic`, `/anthropic-compatible`, `/google`, `/google-vertex`, `/azure`, `/amazon-bedrock`, `/openrouter`, `/xai`; an npm package or `file://` URL also works), `canonical`, `compatibility`, `settings.baseURL`, `headers`, `body`, and `models` keyed by OpenCode model ID where `modelID` sets the ID sent upstream. AI SDK packages take an `aisdk:` prefix (`aisdk:@ai-sdk/openai-compatible`). Renames: `npm`→`package`, `api`→`settings.baseURL`, `id`→`modelID`, `tool_call`/`modalities`→`capabilities.tools`/`capabilities.input`/`capabilities.output`, `cache_read`/`cache_write`→`cache.read`/`cache.write`, `options.setCacheKey`→`compatibility.supportsPromptCacheKey`, `variants` object→array with `id`. **Silently ignored in v2 with a warning:** `release_date`, `attachment`, `reasoning`, `temperature`, `experimental`, a non-deprecated `status`, boolean `interleaved`, plus provider-level `id`, `whitelist`, `blacklist`. v2 adds a whole-request `settings.timeout` (no default), `headerTimeout`/`chunkTimeout` settable to `false`, a transport error when either is exceeded, and "OpenCode retries a timed-out request up to three times before giving up". It also has a baseURL templating quirk: "Cannot initialize provider/model: NAME is required to resolve the provider endpoint" means "A `${NAME}` placeholder remains in baseURL" — i.e. v2 resolves `${NAME}` in baseURL, while `{env:VAR}` elsewhere still works; their exact scoping is not documented.

## 7. Known limitations and v1-vs-v2 differences that will bite a headless agent

- **Two API generations.** v1 publishes OpenAPI 3.1 at `/doc` with colon params (`GET /session`, `POST /session/:id/message`). v2 documents "OpenAPI 3.1.0" under an **`/api/` prefix** with brace params and cursor pagination: `GET /api/session` (`limit`/`order`/`cursor`), `POST /api/session`, `GET|PATCH|DELETE /api/session/{sessionID}`, `/api/location`, `/api/info`, `/api/model`, `/api/credential`, `/api/session/{sessionID}/inbox`, `/interrupt`, `/revert/stage|commit|clear`, `/context`, `/diff`, `/form`. Both generations use the **singular** `session` resource — a `/session`→`/sessions` rename did not happen; the real change is the `/api/` prefix, brace params, cursor pagination and a durable inbox.
- **v2's three stated intentional breaking changes:** a new plugin API, new server API and clients (use `@opencode/client`), and a single global `~/.config/opencode/cli.json` replacing layered `tui.json(c)` (auto-migrated).
- **Dropped in v2:** LSP ("accepts and preserves `lsp` configuration but does not run language servers, expose LSP tools, or produce LSP diagnostics"); the `server` config field is ignored; `logLevel` is ignored in favour of `OPENCODE_LOG_LEVEL`; todos are off by default behind `experimental.todo`; `compaction.tail_turns`/`prune` ignored; top-level `subagent_depth` moves to `experimental.subagent_depth`; permission keys rename `bash`→`shell`, `task`→`subagent`, `write`/`patch`→`edit`; `azure-cognitive-services`→`azure`, `google-vertex-anthropic`→`google-vertex`; `reference`→`references`.
- **Disagreements to carry forward.** (a) `chunkTimeout` default: v1 config docs say 300000 ms (5 min), v2 provider docs say "up to five minutes for response headers and up to fifteen minutes between streamed response chunks" (and 30 min for WebSocket chunks) — no version qualifier reconciles them, so treat the 5-minute chunk default as unconfirmed. (b) `mode` default `all` (v1) vs `primary` (v2). (c) `serve` port default 4096 (docs) vs 0 (source). (d) The docs' prompt-body table omits `format`/`variant`; the schema has them. (e) Share: the OpenAPI contract advertises success, the implementation always 500s. (f) The v1 agents page miscounts its built-in subagents.
- **Migration guidance for API consumers:** "integrations calling the V1 server API must migrate to the V2 API and use the `@opencode/client` package"; `.opencode/` agent/command/skill files and supported server config fields are intended to keep working, and breakage there should be filed as a compatibility bug. The v2 docs index also warns the mise install path "requires mise 2026.10.9 or later; older versions install OpenCode 1", and Windows package managers are unsupported — an easy way to end up with the wrong line.
- **Unverified for v2:** no v2.0.0 release date or per-release changelog could be read; the Docker Hub tag listing returned zero tags (the only version-tag evidence is the docs' example `ghcr.io/anomalyco/opencode:2.0.0`), and whether `@opencode/cli` (2.1.4 on npm) ships an equivalent of every v1 run event is not confirmed.

## 8. Not researched in this run

Token/cost accounting (token fields on assistant messages, where cost comes from, `opencode stats`/usage endpoints, per-session and per-message cost in the API/SDK payloads, spend limits) and **OpenTelemetry support** (config key, emitted spans/metrics, exporter env vars, stability) were not investigated. Nothing in this report should be read as evidence about them, including the behaviour of cost when a custom OpenAI-compatible model is unknown to models.dev.


## Unverified

- opencode CLI export command (`packages/opencode/src/cli/cmd/export.ts`) — Fetch was never executed — the repository-file tool became unavailable at that point in the run, so the existence/flags of an `opencode export` command could not be verified. (The page itself WAS retrieved elsewhere in this run and backs citations — this entry records an unverified topic, not an unusable source.)
- Share service implementation (`packages/opencode/src/share/session.ts`) and the current behaviour of POST /session/:id/share — Fetch was never executed — tool unavailable before retrieval; only the docs statement ('Sharing has been discontinued; this endpoint returns an error') and the route definition could be confirmed. (The page itself WAS retrieved elsewhere in this run and backs citations — this entry records an unverified topic, not an unusable source.)
- Generated client typings (`Config` options, `event.subscribe` return type) in packages/sdk/js/src/gen/** — Not retrieved; the full option list for `createOpencodeClient` comes from the docs page plus the `client.ts` wrapper only.
- v2 JSON event shape beyond text/reasoning/step_start (tool_use, step_finish, usage, cost, finish reason) and end-of-run exit-code logic — Fetch truncated at 12,056 of 31,099 characters, so roughly the last two-thirds of the file (tool/step-finish handling and finalization) was not read; absence of those event types in my notes is a read limit, not evidence they are missing. (The page itself WAS retrieved elsewhere in this run and backs citations — this entry records an unverified topic, not an unusable source.)
- Tail of tool/task.ts source (portion after ~11.6k characters) — Truncated at 11592 of 14196 characters by the read budget; the remaining background-job plumbing was not read. (The page itself WAS retrieved elsewhere in this run and backs citations — this entry records an unverified topic, not an unusable source.)
- OpenCode 2 built-in slash command list / presence of /share — Fetch was cut off before the page was retrieved; the v2 built-in command list and any /share command could not be verified (only the OpenCode 1 TUI page was read).
- Brace-glob semantics behind `{skill,skills}/**/SKILL.md` and `{command,commands}/**/*.md` — Implementation file could not be retrieved, so whether the singular directory branch actually matches on disk remains unverified; the pattern string is confirmed but its runtime behaviour is not.
- Exact `opencode run --command` usage and argument binding — The v2 CLI page documents `opencode run` but never mentions `--command`; the v1 CLI page lists it only as a one-line flag description, so the invocation grammar could not be confirmed. (The page itself WAS retrieved elsewhere in this run and backs citations — this entry records an unverified topic, not an unusable source.)
- Whether the #8054 fix for singular `skill/` discovery ever merged — Issue text describes a fix "applied" by the reporter, but no merged commit or pull request confirming it was reachable, so its status is unverified. (The page itself WAS retrieved elsewhere in this run and backs citations — this entry records an unverified topic, not an unusable source.)
- Session/storage internals: exact SQLite filename per release channel and whether session blobs also live outside opencode.db — Tool access was lost before this file could be read; the data-dir listing (auth.json, opencode.db, log/, snapshot/) rests only on the troubleshooting docs, and OPENCODE_DB's resolution on the CLI env table.
- xdg-basedir fallback defaults (that an unset XDG_STATE_HOME yields ~/.local/state, XDG_CACHE_HOME yields ~/.cache) — The source imports { xdgData, xdgCache, xdgConfig, xdgState } from "xdg-basedir" and joins "opencode", but the package's own fallback rules were not read; the concrete default paths for state and cache are therefore inferred rather than quoted. (The page itself WAS retrieved elsewhere in this run and backs citations — this entry records an unverified topic, not an unusable source.)
- Docker Hub / GHCR tag list with push dates for anomalyco/opencode — Registry query returned zero tags (tagCount 0), so no tag/date evidence; the only version-tag evidence is the docs' example tag `2.0.0`.
- The v1 chunkTimeout 5-minute default vs v2 fifteen-minute statement — Both statements were retrieved from their respective doc trees but neither page versions or reconciles the other, so the conflict could not be resolved. (The page itself WAS retrieved elsewhere in this run and backs citations — this entry records an unverified topic, not an unusable source.)
- Generated TypeScript SDK request types (SessionPromptData) at v1.19.4 — The 3906-line generated file could only be partially read: the line filter returned the matching type-declaration header lines without their bodies, so the exact generated body type could not be quoted.
- Prompt handler implementation that merges the path `sessionID` into the payload — Fetch was truncated at ~10.9k of 17.6k characters before the `prompt` handler body, so the merge of `ctx.params.sessionID` into `SessionPrompt.prompt` was not directly observed (it is inferred from the payload omitting sessionID). (The page itself WAS retrieved elsewhere in this run and backs citations — this entry records an unverified topic, not an unusable source.)
- v1.19.4 release-notes body (changelog entries for that tag) — The page was fetched but returned only GitHub navigation chrome and the tag-comparison dropdown; the release body/changelog text was not present in the retrieved content (and the page was truncated), so no release-note claim could be sourced from it. (The page itself WAS retrieved elsewhere in this run and backs citations — this entry records an unverified topic, not an unusable source.)
- packages/opencode/CHANGELOG.md at v1.19.4 (to date when `--sanitize` was introduced) — 404 — no file at that path on that ref, so the introduction date of the `--sanitize` flag could not be established from the changelog.
- The share scenario inside packages/opencode/test/server/httpapi-exercise/index.ts at v1.19.4 (to read the exact `.json(500, ...)` assertion at the site rather than as a filtered diff hunk) — Fetch was truncated at ~59.5k of 68.5k characters (budget cut) before reaching the `session.share` scenario; the surrounding harness idioms were read, but the share block itself was not. (The page itself WAS retrieved elsewhere in this run and backs citations — this entry records an unverified topic, not an unusable source.)
- Sharing status in v1.19.4 — docs: "session.share({ path }) Share session — Sharing has been discontinued; this endpoint returns an error" and "session.unshare({ path }) Clear a stored share link — Returns Session". The route still exists in source (`SessionPaths.share = "/session/:sessionID/share"`, POST identifier `session.share`, description "Create a shareable link for a session…"), and the v1.19.4 tree's latest commit for the server dir is `fix(opencode): discontinue session sharing (#55718)` — so the endpoint is present but reportedly non-functional. The `/v2` client is separately documented as taking flat params (e.g. `client.session.prompt({ sessionID, parts, format })`). [unverified number: 55718 does not occur in the text retrieved from the cited page] — Number check: 55718, 55718 do not occur in the text retrieved from the cited page (https://opencode.ai/docs/sdk/) — the figure may be invented, taken from another page or the given background, or computed; confirm before relying on it.
- User reports (Jan 2026, v1 era) documented the singular path as broken: issue #8054 says discovery "ignores ~/.config/opencode/skill/ (singular)" because the brace glob `{skill,skills}/**/SKILL.md` "was not correctly matching", and #6177 (v1.0.201) reported the older `skill/**/SKILL.md` glob missing Claude's plural `skills/`. Both were filed as bugs, so the singular form's reliability is version-dependent even where the pattern lists it. [unverified number: 6177 does not occur in the text retrieved from the cited page] — Number check: 6177, 6177 do not occur in the text retrieved from the cited page (https://github.com/anomalyco/opencode/issues/8054) — the figure may be invented, taken from another page or the given background, or computed; confirm before relying on it.
- Commit d320177 (#55718) deleted packages/opencode/src/share/share-next.ts entirely — the ShareNext service that created/persisted/synced/removed shares and returned `{ id, secret, url }` against `${baseUrl}/api/share` — and removed ShareNext from the AppNodeBuilder/layer graphs, so nothing in v1.19.4 mints, syncs or deletes a share URL. [unverified number: 55718 does not occur in the text retrieved from the cited page] — Number check: 55718, 55718 do not occur in the text retrieved from the cited page (https://github.com/anomalyco/opencode/commit/d320177aa4cb93d63b6462acd6efca0ee037dedf.diff) — the figure may be invented, taken from another page or the given background, or computed; confirm before relying on it.


## Sources

- https://opencode.ai/docs/server/
- https://opencode.ai/docs/sdk/
- https://www.npmjs.com/package/@opencode-ai/sdk
- https://registry.npmjs.org/%40opencode-ai/sdk
- https://github.com/sst/opencode
- https://github.com/anomalyco/opencode/blob/v1.19.4/packages/opencode/src/cli/cmd/serve.ts
- https://raw.githubusercontent.com/anomalyco/opencode/v1.19.4/packages/opencode/src/cli/cmd/serve.ts
- https://github.com/anomalyco/opencode/blob/v1.19.4/packages/opencode/src/cli/network.ts
- https://raw.githubusercontent.com/anomalyco/opencode/v1.19.4/packages/opencode/src/cli/network.ts
- https://github.com/anomalyco/opencode/tree/v1.19.4/packages/sdk/js
- https://github.com/anomalyco/opencode/blob/v1.19.4/packages/sdk/js/package.json
- https://raw.githubusercontent.com/anomalyco/opencode/v1.19.4/packages/sdk/js/package.json
- https://github.com/anomalyco/opencode/tree/v1.19.4/packages/sdk/js/src
- https://github.com/anomalyco/opencode/blob/v1.19.4/packages/sdk/js/src/server.ts
- https://raw.githubusercontent.com/anomalyco/opencode/v1.19.4/packages/sdk/js/src/server.ts
- https://github.com/anomalyco/opencode/blob/v1.19.4/packages/sdk/js/src/index.ts
- https://raw.githubusercontent.com/anomalyco/opencode/v1.19.4/packages/sdk/js/src/index.ts
- https://github.com/anomalyco/opencode/blob/v1.19.4/packages/sdk/js/src/client.ts
- https://raw.githubusercontent.com/anomalyco/opencode/v1.19.4/packages/sdk/js/src/client.ts
- https://github.com/anomalyco/opencode/tree/v1.19.4/packages/opencode/src/server
- https://github.com/anomalyco/opencode/blob/v1.19.4/packages/opencode/src/server/event.ts
- https://raw.githubusercontent.com/anomalyco/opencode/v1.19.4/packages/opencode/src/server/event.ts
- https://github.com/anomalyco/opencode/blob/v1.19.4/packages/opencode/src/server/auth.ts
- https://raw.githubusercontent.com/anomalyco/opencode/v1.19.4/packages/opencode/src/server/auth.ts
- https://github.com/anomalyco/opencode/blob/v1.19.4/packages/schema/src/server-event.ts
- https://raw.githubusercontent.com/anomalyco/opencode/v1.19.4/packages/schema/src/server-event.ts
- https://github.com/anomalyco/opencode/tree/v1.19.4/packages/opencode/src/server/routes/instance/httpapi
- https://github.com/anomalyco/opencode/blob/v1.19.4/packages/opencode/src/server/routes/instance/httpapi/server.ts
- https://raw.githubusercontent.com/anomalyco/opencode/v1.19.4/packages/opencode/src/server/routes/instance/httpapi/server.ts
- https://github.com/anomalyco/opencode/blob/v1.19.4/packages/opencode/src/server/routes/instance/httpapi/api.ts
- https://raw.githubusercontent.com/anomalyco/opencode/v1.19.4/packages/opencode/src/server/routes/instance/httpapi/api.ts
- https://github.com/anomalyco/opencode/blob/v1.19.4/packages/opencode/src/server/routes/instance/httpapi/groups/session.ts
- https://raw.githubusercontent.com/anomalyco/opencode/v1.19.4/packages/opencode/src/server/routes/instance/httpapi/groups/session.ts
- https://github.com/anomalyco/opencode/blob/v1.19.4/packages/opencode/src/event-manifest.ts
- https://raw.githubusercontent.com/anomalyco/opencode/v1.19.4/packages/opencode/src/event-manifest.ts
- https://github.com/anomalyco/opencode/blob/v1.19.4/packages/opencode/src/server/routes/instance/httpapi/groups/event.ts
- https://raw.githubusercontent.com/anomalyco/opencode/v1.19.4/packages/opencode/src/server/routes/instance/httpapi/groups/event.ts
- https://github.com/anomalyco/opencode/blob/v1.19.4/packages/schema/src/event-manifest.ts
- https://raw.githubusercontent.com/anomalyco/opencode/v1.19.4/packages/schema/src/event-manifest.ts
- https://github.com/anomalyco/opencode/blob/v1.19.4/packages/schema/src/session-event.ts
- https://raw.githubusercontent.com/anomalyco/opencode/v1.19.4/packages/schema/src/session-event.ts
- https://github.com/anomalyco/opencode/blob/v1.19.4/packages/schema/src/legacy-event.ts
- https://raw.githubusercontent.com/anomalyco/opencode/v1.19.4/packages/schema/src/legacy-event.ts
- https://github.com/anomalyco/opencode/blob/v1.19.4/packages/schema/src/permission-v1.ts
- https://raw.githubusercontent.com/anomalyco/opencode/v1.19.4/packages/schema/src/permission-v1.ts
- https://github.com/anomalyco/opencode/blob/v1.19.4/packages/schema/src/v1/legacy-event.ts
- https://raw.githubusercontent.com/anomalyco/opencode/v1.19.4/packages/schema/src/v1/legacy-event.ts
- https://github.com/anomalyco/opencode/blob/v1.19.4/packages/schema/src/v1/permission.ts
- https://raw.githubusercontent.com/anomalyco/opencode/v1.19.4/packages/schema/src/v1/permission.ts
- https://github.com/anomalyco/opencode/blob/v1.19.4/packages/schema/src/session-v1.ts
- https://raw.githubusercontent.com/anomalyco/opencode/v1.19.4/packages/schema/src/session-v1.ts
- https://github.com/anomalyco/opencode/blob/v1.19.4/packages/schema/src/v1/session.ts
- https://raw.githubusercontent.com/anomalyco/opencode/v1.19.4/packages/schema/src/v1/session.ts
- https://github.com/anomalyco/opencode/blob/v1.19.4/packages/schema/src/prompt.ts
- https://raw.githubusercontent.com/anomalyco/opencode/v1.19.4/packages/schema/src/prompt.ts
- https://github.com/anomalyco/opencode/blob/v1.19.4/packages/schema/src/session-status-event.ts
- https://raw.githubusercontent.com/anomalyco/opencode/v1.19.4/packages/schema/src/session-status-event.ts
- https://opencode.ai/docs/cli
- https://github.com/anomalyco/opencode/blob/v1.19.4/packages/opencode/src/cli/cmd/run.ts
- https://raw.githubusercontent.com/anomalyco/opencode/v1.19.4/packages/opencode/src/cli/cmd/run.ts
- https://github.com/anomalyco/opencode/tree/dev/packages
- https://www.npmjs.com/package/opencode-ai
- https://registry.npmjs.org/opencode-ai
- https://github.com/anomalyco/opencode/tree/dev/packages/cli/src
- https://github.com/anomalyco/opencode/tree/dev/packages/cli/src/commands
- https://github.com/anomalyco/opencode/blob/HEAD/packages/cli/package.json
- https://raw.githubusercontent.com/anomalyco/opencode/HEAD/packages/cli/package.json
- https://github.com/anomalyco/opencode/tree/dev/packages/cli/src/commands/handlers
- https://github.com/anomalyco/opencode/blob/HEAD/packages/cli/src/commands/handlers/run.ts
- https://raw.githubusercontent.com/anomalyco/opencode/HEAD/packages/cli/src/commands/handlers/run.ts
- https://github.com/anomalyco/opencode/blob/HEAD/packages/cli/src/commands/commands.ts
- https://raw.githubusercontent.com/anomalyco/opencode/HEAD/packages/cli/src/commands/commands.ts
- https://github.com/anomalyco/opencode/blob/HEAD/packages/cli/src/run/run.ts
- https://raw.githubusercontent.com/anomalyco/opencode/HEAD/packages/cli/src/run/run.ts
- https://github.com/anomalyco/opencode/blob/HEAD/packages/cli/src/run/noninteractive.ts
- https://raw.githubusercontent.com/anomalyco/opencode/HEAD/packages/cli/src/run/noninteractive.ts
- https://opencode.ai/docs/agents
- https://opencode.ai/docs/config
- https://opencode.ai/config.json
- https://github.com/anomalyco/opencode/blob/HEAD/packages/web/src/content/docs/agents.mdx
- https://raw.githubusercontent.com/anomalyco/opencode/HEAD/packages/web/src/content/docs/agents.mdx
- https://opencode.ai/docs/config.md
- https://opencode.ai/v2/docs/agents/
- https://opencode.ai/v2/docs/migrate-v1
- https://github.com/anomalyco/opencode/blob/v1.19.2/packages/opencode/src/tool/task.ts
- https://raw.githubusercontent.com/anomalyco/opencode/v1.19.2/packages/opencode/src/tool/task.ts
- https://opencode.ai/docs/custom-tools
- https://opencode.ai/docs/plugins
- https://github.com/anomalyco/opencode/blob/v1.18.25/packages/plugin/src/index.ts
- https://raw.githubusercontent.com/anomalyco/opencode/v1.18.25/packages/plugin/src/index.ts
- https://www.npmjs.com/package/@opencode-ai/plugin
- https://registry.npmjs.org/%40opencode-ai/plugin
- https://github.com/anomalyco/opencode/blob/v1.19.4/packages/plugin/src/tool.ts
- https://raw.githubusercontent.com/anomalyco/opencode/v1.19.4/packages/plugin/src/tool.ts
- https://github.com/anomalyco/opencode/blob/v1.19.4/packages/plugin/src/index.ts
- https://raw.githubusercontent.com/anomalyco/opencode/v1.19.4/packages/plugin/src/index.ts
- https://github.com/anomalyco/opencode/blob/v1.19.4/packages/opencode/src/plugin/index.ts
- https://raw.githubusercontent.com/anomalyco/opencode/v1.19.4/packages/opencode/src/plugin/index.ts
- https://github.com/anomalyco/opencode/blob/v1.19.4/packages/opencode/src/tool/registry.ts
- https://raw.githubusercontent.com/anomalyco/opencode/v1.19.4/packages/opencode/src/tool/registry.ts
- https://github.com/anomalyco/opencode/blob/v1.19.4/packages/opencode/src/plugin/loader.ts
- https://raw.githubusercontent.com/anomalyco/opencode/v1.19.4/packages/opencode/src/plugin/loader.ts
- https://github.com/anomalyco/opencode/blob/v1.19.4/packages/opencode/src/config/plugin.ts
- https://raw.githubusercontent.com/anomalyco/opencode/v1.19.4/packages/opencode/src/config/plugin.ts
- https://raw.githubusercontent.com/anomalyco/opencode/v1.19.4/packages/opencode/src/config/config.ts
- https://github.com/anomalyco/opencode/blob/v1.19.4/packages/opencode/src/config/paths.ts
- https://raw.githubusercontent.com/anomalyco/opencode/v1.19.4/packages/opencode/src/config/paths.ts
- https://raw.githubusercontent.com/anomalyco/opencode/v1.19.4/packages/opencode/src/permission/index.ts
- https://raw.githubusercontent.com/anomalyco/opencode/v1.19.4/packages/opencode/src/session/prompt.ts
- https://github.com/anomalyco/opencode/issues/47654
- https://github.com/anomalyco/opencode/issues/25918
- https://raw.githubusercontent.com/anomalyco/opencode/v1.19.4/packages/opencode/src/session/processor.ts
- https://github.com/anomalyco/opencode/blob/v1.19.4/packages/core/src/plugin/skill/customize-opencode.md
- https://raw.githubusercontent.com/anomalyco/opencode/v1.19.4/packages/core/src/plugin/skill/customize-opencode.md
- https://opencode.ai/v2/docs/build/plugins
- https://raw.githubusercontent.com/anomalyco/opencode/v1.19.4/packages/opencode/src/session/llm.ts
- https://github.com/anomalyco/opencode/issues/52837
- https://raw.githubusercontent.com/anomalyco/opencode/v1.19.4/packages/opencode/src/session/tools.ts
- https://opencode.ai/docs/skills/
- https://opencode.ai/docs/commands/
- https://github.com/anomalyco/opencode/issues/8054
- https://github.com/anomalyco/opencode/issues/6177
- https://github.com/anomalyco/opencode/tree/dev
- https://opencode.ai/v2/docs/skills/
- https://www.npmjs.com/package/@opencode/cli
- https://registry.npmjs.org/%40opencode/cli
- https://opencode.ai/v2/docs/commands/
- https://opencode.ai/v2/docs/cli
- https://opencode.ai/docs/tui/
- https://github.com/anomalyco/opencode/tree/v1.19.4/packages
- https://github.com/anomalyco/opencode/blob/v1.19.4/packages/opencode/src/config/config.ts
- https://github.com/anomalyco/opencode/blob/v1.19.4/packages/opencode/src/skill/index.ts
- https://raw.githubusercontent.com/anomalyco/opencode/v1.19.4/packages/opencode/src/skill/index.ts
- https://github.com/anomalyco/opencode/blob/v1.19.4/packages/opencode/src/command/index.ts
- https://raw.githubusercontent.com/anomalyco/opencode/v1.19.4/packages/opencode/src/command/index.ts
- https://github.com/anomalyco/opencode/blob/v1.19.4/packages/opencode/src/tool/skill.txt
- https://raw.githubusercontent.com/anomalyco/opencode/v1.19.4/packages/opencode/src/tool/skill.txt
- https://github.com/anomalyco/opencode/blob/v1.19.4/packages/opencode/src/config/command.ts
- https://raw.githubusercontent.com/anomalyco/opencode/v1.19.4/packages/opencode/src/config/command.ts
- https://opencode.ai/docs/troubleshooting
- https://github.com/anomalyco/opencode
- https://github.com/anomalyco/opencode/blob/v1.19.4/packages/core/src/flag/flag.ts
- https://raw.githubusercontent.com/anomalyco/opencode/v1.19.4/packages/core/src/flag/flag.ts
- https://github.com/anomalyco/opencode/blob/v1.19.4/packages/core/src/global.ts
- https://raw.githubusercontent.com/anomalyco/opencode/v1.19.4/packages/core/src/global.ts
- https://opencode.ai/v2/docs/config
- https://github.com/anomalyco/opencode/tree/v1.19.4/packages/opencode/src
- https://api.github.com/repos/anomalyco/opencode/contents/packages?ref=dev
- https://api.github.com/repos/anomalyco/opencode/contents/packages/stats?ref=dev
- https://api.github.com/repos/anomalyco/opencode/contents/packages/schema?ref=dev
- https://api.github.com/repos/anomalyco/opencode/contents/packages/schema/src?ref=dev
- https://opencode.ai/docs/providers
- https://opencode.ai/v2/docs/providers
- https://opencode.ai/v2/docs
- https://hub.docker.com/r/anomalyco/opencode
- https://hub.docker.com/v2/repositories/anomalyco/opencode/tags?page_size=25&ordering=last_updated
- https://opencode.ai/v2/docs/api
- https://github.com/anomalyco/opencode/blob/v1.19.4/packages/opencode/src/session/prompt.ts
- https://github.com/anomalyco/opencode/blob/v1.19.4/packages/core/src/v1/session.ts
- https://raw.githubusercontent.com/anomalyco/opencode/v1.19.4/packages/core/src/v1/session.ts
- https://github.com/anomalyco/opencode/blob/v1.19.4/packages/web/src/content/docs/server.mdx
- https://raw.githubusercontent.com/anomalyco/opencode/v1.19.4/packages/web/src/content/docs/server.mdx
- https://github.com/anomalyco/opencode/blob/v1.19.4/packages/opencode/src/server/server.ts
- https://raw.githubusercontent.com/anomalyco/opencode/v1.19.4/packages/opencode/src/server/server.ts
- https://raw.githubusercontent.com/anomalyco/opencode/v1.19.4/packages/sdk/js/src/gen/types.gen.ts
- https://github.com/anomalyco/opencode/blob/v1.19.4/packages/opencode/src/server/routes/instance/httpapi/public.ts
- https://raw.githubusercontent.com/anomalyco/opencode/v1.19.4/packages/opencode/src/server/routes/instance/httpapi/public.ts
- https://github.com/anomalyco/opencode/blob/v1.19.4/packages/opencode/src/server/routes/instance/httpapi/handlers/session.ts
- https://raw.githubusercontent.com/anomalyco/opencode/v1.19.4/packages/opencode/src/server/routes/instance/httpapi/handlers/session.ts
- https://github.com/anomalyco/opencode/blob/v1.19.4/packages/opencode/src/cli/cmd/export.ts
- https://raw.githubusercontent.com/anomalyco/opencode/v1.19.4/packages/opencode/src/cli/cmd/export.ts
- https://github.com/anomalyco/opencode/blob/v1.19.4/packages/opencode/src/index.ts
- https://raw.githubusercontent.com/anomalyco/opencode/v1.19.4/packages/opencode/src/index.ts
- https://github.com/anomalyco/opencode/blob/v1.19.4/packages/opencode/src/cli/cmd/import.ts
- https://raw.githubusercontent.com/anomalyco/opencode/v1.19.4/packages/opencode/src/cli/cmd/import.ts
- https://opencode.school/lessons/sessions/
- https://huggingface.co/blog/marinarosa/agent-traces-codex-opencode
- https://pkg.go.dev/github.com/entireio/cli/cmd/entire/cli/agent/opencode
- https://github.com/anomalyco/opencode/releases/tag/v1.19.4
- https://github.com/anomalyco/opencode/blob/v1.19.4/packages/opencode/src/cli/effect-cmd.ts
- https://raw.githubusercontent.com/anomalyco/opencode/v1.19.4/packages/opencode/src/cli/effect-cmd.ts
- https://github.com/anomalyco/opencode/blob/v1.19.4/packages/opencode/src/share/session.ts
- https://raw.githubusercontent.com/anomalyco/opencode/v1.19.4/packages/opencode/src/share/session.ts
- https://github.com/anomalyco/opencode/commit/d320177aa4cb93d63b6462acd6efca0ee037dedf
- https://github.com/anomalyco/opencode/commit/d320177aa4cb93d63b6462acd6efca0ee037dedf.diff
- https://github.com/anomalyco/opencode/tree/v1.19.4/packages/opencode/src/cli/cmd
- https://github.com/anomalyco/opencode/blob/v1.19.4/packages/opencode/test/server/httpapi-exercise/index.ts
- https://raw.githubusercontent.com/anomalyco/opencode/v1.19.4/packages/opencode/test/server/httpapi-exercise/index.ts
