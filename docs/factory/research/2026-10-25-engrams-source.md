# engrams source read (cortexapps/engrams, shallow clone 2026-10-25; code read only, AGPL-3.0-only — patterns, not code)

## 1. Repo map

- **Mixed stack.** Rust (390k LOC, ~55 crates: coordinator, host-agent, Firecracker/VZ backends, harnesses), a Bun/Hono/Drizzle **orchestrator** (`orchestrator/`: 74.6k prod TS, 71.4k test, 16.6k generated), React `web/` (110k). DBOS lives only in the orchestrator.
- **License:** `LICENSE` is GNU AGPL v3 (19 Nov 2007). SPDX `AGPL-3.0-only` (`Cargo.toml`, `orchestrator/package.json`). Four harness crates are Apache-2.0. Copying code means AGPL; patterns are free.
- **Versions:** `"@dbos-inc/dbos-sdk": "^4.21.6"`, resolved 4.21.6 in `orchestrator/bun.lock`. Bun pinned exactly in `.bun-version` (`1.4.3`) and `oven/bun:1.4.3-alpine`. No `engines` field.
- **Deploy:** README: "Production isolation is Firecracker on Linux with KVM, and there is no container mode." Two Helm releases on GKE/EKS via Terraform; Firecracker fleet on Intel nested-virt nodes; Cloud SQL/RDS, GCS/S3.
- **macOS:** "A macOS backend on Apple Virtualization exists for development only." It needs Apple Silicon, Tilt, Docker (postgres:16, registry, fake-gcs), Rust, musl-cross, a VZ codesign entitlement. A `Process` backend has zero isolation. No KVM needed, but it is a dev stack for a VM-sandbox product.

## 2. DBOS usage, exactly

Three registered workflows: `AutomationRunWorkflow`, `ToolExecWorkflow`, `SpecTicketSyncWorkflow`. No `WorkflowQueue`, `DBOS.sleep`, scheduled workflows, `DBOS.patch` or DBOS step retries (an engine attempt loop instead). Cron is `croner` plus a PG lease (`automations/scheduler.ts`).

`workflows/dbos.ts`:
```ts
DBOS.setConfig({ name: "engrams-orchestrator", systemDatabaseUrl: config.databaseUrl,
  systemDatabaseSchemaName: "dbos", executorID: dbosExecutorId(), runAdminServer: false, logger: dbosLogger });
await DBOS.launch();
```
`workflows/automation-run.ts`:
```ts
step: (fn, name) => DBOS.runStep(fn, { name }),
recv: (topic, timeoutSeconds) => DBOS.recv<AutomationInbox>(topic, timeoutSeconds),
await DBOS.startWorkflow(automationRunWorkflow, { workflowID: runId })({ runId, automationId });
export const automationRunWorkflow = DBOS.registerWorkflow(automationRunWorkflowImpl, { name: "AutomationRunWorkflow" });
```
`inbox.ts`: `DBOS.send<AutomationInbox>(runId, message, AUTOMATION_TOPIC, idempotencyKey)`. `sweep/production.ts` uses `DBOS.cancelWorkflow` and `DBOS.applicationVersion`.

**The body is deliberately thin:**
```ts
const ENGINE_STEP_CONTRACT = 4;
const engine = deps.engine ?? productionEngineDeps();
return interpretAutomation({ runId: input.runId, automationId: input.automationId,
  contract: ENGINE_STEP_CONTRACT }, engine);
```
DBOS hashes the registered function's source for `applicationVersion` and does not recurse into helpers. The interpreter evolves freely; bumping the literal rotates the version on purpose, so in-flight runs strand and the sweep fails them rather than replaying through changed semantics.

**Step names** (`engine/step-name.ts`): `step:<blockId[iter].child>:<attempt>`, plus `step:__snapshot__:0`, `__finalize__:0`, `.__cond__:0`, `.__bound__:0`, `[i].__until__:0`, `:clock:<n>`, `.__relay__:<n>`, `:wait`. Branch/loop decisions are step outputs, never re-evaluated; deadline time is checkpointed as `:clock:n` steps. **Golden test** (`interpreter.test.ts`, "ENGINE_STEP_CONTRACT 4"):
```ts
expect(h.names).toEqual(["step:__snapshot__:0","step:check:0","step:check:0:ledger","step:launch:0",
  "step:notify:0","step:notify:clock:1","step:notify:0:wait","step:cleanup:0","step:__finalize__:0"]);
```
`__tests__/replay-step.ts` journals steps and recv, simulates crash and replay, and throws on a step-name mismatch. CI diffs `dbos-workflow-hashes.json` (SDK version plus per-body MD5).

**Version-gating cost (ADR 0104):** any deploy changing a workflow body or the SDK strands every in-flight workflow (prod: 253 unconsumed notifications, 15 orphaned PENDING runs). The fix is ~2k lines in `sweep/` and `db/dbos-sweep.ts`: heartbeat table, ledger, lease, and raw SQL flipping `dbos.workflow_status` to `ENQUEUED` with `application_version = NULL`. Pinning `applicationVersion` was rejected: it forces `DBOS.patch` bookkeeping. `executorID` is the pod name; the default `"local"` made replicas double-run.

## 3. Agent session lifecycle

- **Start:** headless, persistent, in a microVM. `engram-harness-claude/src/main.rs`: `claude --print --input-format stream-json --output-format stream-json --verbose --include-partial-messages --settings <hooks> [--permission-mode plan] [--resume <id>] --mcp-config <p> --strict-mcp-config --append-system-prompt <role>`. A PreToolUse hook replaces `--dangerously-skip-permissions`.
- **Idle is an event.** ADR 0052: inferring turn ends from stdout caused wedged prod sessions. Held-open stdin yields an explicit `{"type":"result"}` per turn, mapped to `run_completed`/`run_interrupted`; EOF mid-turn is a crash, so `--resume` respawn. `listeners/automation-consumer.ts` turns these into `session_idle {runFailed?}` / `session_ended`, key `autorun:<sid>:idle:<eventIdx>`.
- **Signal tool** (`tools/automation.ts`, `taskTypes: ["automation"]`):
```ts
input: z.object({ signal: z.string().regex(/^[a-z][a-z0-9_]*$/).max(64),
                  payload: z.record(z.string(), z.unknown()).optional() }),
output: z.object({ delivered: z.boolean() })
```
  Payload capped at 16k chars; it is a `DBOS.send` keyed `autorun:<sid>:signal:<name>:<toolCallId>:<runId>`. Signal is authoritative; stream idle is "the run_end backstop". Review tools `submit_finding`, `finder_done`, `submit_verdict` follow the pattern.
- **Turn correlation** (`interpreter.ts` header): per session the Nth idle matches the Nth prompt; older idles/signals are "stale — dropped, never matched".
- **Follow-ups:** `sessions.sendPrompt(sessionId, promptId, text)`. Coordinator outbox `ON CONFLICT (prompt_id) DO NOTHING`; harness dedupes redelivery via `seen_prompt_ids`. Mid-turn prompts are written to stdin and attended at the next tool-step boundary (CLI >=2.1.237).
- **Prompt id:** `` `autorun:${ctx.runId}:${currentPath(ctx)}:${sessionId}` `` (frame path includes loop iteration, else later loop prompts are dropped).

## 4. Intake and dedup

- Run id = `autorun:<automationId>[:<entrypoint>][:i-<instance>]:<deliveryKey>`; delivery key `<provider>:<deliveryId>`, `cron:<epoch>` or `manual:<uuid>`. "Starting an existing running or terminal id returns its handle and never re-executes the body." Backed by unique index `automation_run_delivery_unique(automation_id, entrypoint_id, delivery_key)`.
- **"Same error joins the run in flight"** is the generic `concurrency: {keyTemplate, policy}` (`dispatch.ts`; `automation_concurrency_claim` PK `(automation_id, concurrency_key)`, INSERT ON CONFLICT + CAS + DELETE). `join` sends `{kind:"event", deliveryKey, payload}` to the holder, key `autorun-evt:<deliveryKey>:<runId>`; `queue` promotes the oldest pending run at holder finalize; `skip`; `supersede`. No Sentry-specific code; PR review keys on `html_url`.
- **Admission prelude** (`engine/admission.ts`) runs BEFORE the claim. Origin: an "LGTM" comment superseded a live review. A rejection writes a `filtered` row, no claim.
- **"Jev"** is TypeSafe's System One model via OpenRouter `POST /api/alpha/decisions` (`integrations/openrouter-decisions.ts`), default `typesafe/jev-1.13`, 5s timeout, used only by the `decide` block (typed `choice|score|yes_no` questions with calibrated probabilities that `branch` gates on). Sole real use: Slack profile routing, `state: {message: <thread>}`, "Which profile should handle this request?", `onError: "undecided"` falls back to the default profile. Not used for error dedup.

## 5. PR review (`builtins/pr-review.ts`, `orchestrator/reviewers/*.md`)

- Graph: facts -> admit -> `open_review_pass` -> pinned status comment -> finder session -> clone -> stage -> `send_prompt` (waitFor signal `finder_done`, 2h) -> branch on `candidate_count > 0` -> verifier (same shape) -> settle gate -> post review or clean status.
- **Finder** (`finder.md`): orient, parallel Sonnet subagents per lens (6 in `lenses/`), triage. A finding needs a traced failure, named trigger and class `routine|plausible-fault|compound-fault|operator-misuse`.
- **Verifier** (`verifier.md`): refute-to-drop with staleness, duplicate, evidence gates and a "below-bar" verdict; reasoning must cite files it read; silence means unverified.
- **New push:** `supersede` concurrency on the PR url. `beginReviewPass` marks the predecessor `superseded` in the same transaction as the insert (partial unique index: one active review per target). The old run gets `{kind:"supersede"}`, throws `RunEnd("superseded")`, and an `onFinalize` hook tears down workers.

## 6. Data model (`db/schema.ts`)

`automation_version` (pinned definition), `automation_run` (id = workflow id), `automation_step_run` (observability ledger), `automation_session` (session to run mailbox binding), `automation_concurrency_claim`, `automation_state` (KV with CAS), `automation_instance`/`_handle`/`_drop` (workstream per PR/thread), `task`, `review`/`review_finding`/`review_verdict`/`review_event`, `pr_ref`, `session_listeners` + `consumer_cursor` (durable event cursors), `dbos_version_heartbeats`/`dbos_sweep_ledger`/`dbos_sweep_lease`, `integration_event`, `profile`. The Rust coordinator owns `session_outbox` and the session event log.

## 7. Verdict

**(a) Adopt: no.** Rust, Firecracker, AGPL, Kubernetes-shaped; sessions are headless stream-json claude in microVMs on org API credentials, not herdr panes on Max seats. Mine it for patterns.

**(b) Transferable patterns**
1. **Deterministic run id** `issue:<fingerprint>`; `INSERT ... ON CONFLICT DO NOTHING` is attach-or-start. Check for an existing lead session before spawning a pane.
2. **Inbox per Issue with a mandatory non-empty idempotency key**: `issue_inbox(issue_id, idem_key UNIQUE, kind, payload)`. `factory issue ship|ask|block|close` are signals keyed `(issue, name, callId)`.
3. **Concurrency claim table with join/queue/supersede.** "Same error joins the lead" is `join` on the fingerprint, delivered as a prompt to the lead. Run the noise filter before the claim.
4. **Turn-correlated idle** for the Witness: count prompts vs idle observations per pane, drop stale idles. The `factory` signal is authoritative, pane idle/dead the backstop, with per-wait deadlines.
5. **Deterministic prompt ids** (`issue:<id>:<phase>:<n>`) recorded before typing into the pane, so a replayed tick never double-prompts.
6. **Finalize exactly once from every exit path**: terminal status, release claim, promote the queued successor outside the transaction; hooks for failed/halted/superseded.
7. **Findings as tool writes** ("Anything not submitted through this tool does not exist") plus finder/verifier refute-to-drop for the review phase.
8. **Replay-journal runner and golden step-sequence snapshot**, useful as the ticker's idempotency test even without DBOS.

**(c) Against his design / caution**
- **DBOS is costly for hours-long agents.** Version-gating plus recv-parking forced ADR 0104 (~2k-line sweeper) and a manual contract integer. They use DBOS only for checkpoints, `recv/send` and workflowID idempotency, and built their own scheduler, claims, retries and recovery. Their ADR 0119 D9: "an entity lifecycle that spans days ... must NOT be one long-lived run ... The automation is stateful; no run is." That is an Issue-row state machine with short steps, which Postgres plus a ticker gives without version gating. One Mac mini has no multi-pod recovery to buy.
- **Headless over interactive.** They left inferred turn boundaries for explicit `result` events because inference wedged sessions. herdr working/idle/blocked is the inferred kind, so the Witness needs signals and deadlines as ground truth. They also get stdin steering and schema-validated MCP tools; a `factory` CLI via Bash is looser, so validate server-side.
