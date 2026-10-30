# Research: 2026-10-22-durable-await-sqlite

Job `9235cd92-854e-471d-b4c6-8a109b14c59d` · depth deep · status partial

**Query:** Durable execution for an AI-agent ops loop on one machine, verified as of October 2026: (1) which durable-execution libraries can use SQLite as their persistence (DBOS Transact Python/TypeScript SQLite system database support, Mastra workflows with libSQL storage, Absurd, pgflow, Hatchet lite, Restate embedded store, LiteFS-style options) — exact versions and docs; (2) the exact semantics of "wait for an external decision with a timeout and a default" in each: Temporal signals + workflow.wait_condition timeout, DBOS recv/send/setEvent with timeout, Absurd awaitEvent timeout, Restate awakeables/durable promises with timeout, Mastra suspend/resume — what happens on crash during the wait, on timeout, and to exactly-once side effects (idempotency keys, step checkpoints); (3) published crash-recovery behaviour when the worker process is killed mid-step (step re-executed vs resumed), and how long-running (hours) LLM agent steps are handled (heartbeats, leases).

> **Partial result — evidence was lost during this run.** 1 claim(s) were dropped because the pages backing them could not be retrieved; 1 citation(s) had their confidence lowered to match the evidence actually retrieved. Anything below that is not backed by an entry in `citations` is unconfirmed; see `unverified` for what could not be checked.

## Bottom line

- **SQLite persistence:** **DBOS Transact Python (`dbos` 3.3.0) is the only surveyed library that uses SQLite as a supported — indeed default — system database.** DBOS TypeScript (`@dbos-inc/dbos-sdk` 5.3.0) is Postgres-only (SQLite exists as unmerged PR #1288); Absurd 0.5.1, pgflow 0.17.2 and Hatchet v0.110.5 all require Postgres (Hatchet's "embedded mode" bundles an *embedded Postgres*, not a SQLite store); Temporal supports SQLite "only for development and testing, not production usage"; Restate 1.8.1's single-binary store is RocksDB + a Bifrost WAL in `restate-data`, not SQLite; LiteFS and Litestream are asynchronous replication/disaster-recovery overlays, not synchronous durability. **Mastra's durability, suspend/resume and timeout semantics could not be verified in this run — no source was retrieved.**
- **"Wait for an external decision with a timeout and a default":** **no surveyed library has a first-class "return this default on timeout".** Temporal Python raises `asyncio.TimeoutError` from `workflow.wait_condition(..., timeout=)` while TypeScript's `condition(fn, timeout)` returns a boolean, so the default is your own `except`/`if` branch; DBOS `recv`/`getEvent` return `None`/`null` on timeout (60 s default); Absurd's `awaitEvent(name, {timeout})` throws `TimeoutError` and — in the TypeScript SDK source — writes **no checkpoint** on that path, so the timeout is not recorded as a null step result; Restate has no awakeable deadline at all and tells you to race the awakeable or signal against a durable timer (`orTimeout` rejects with `TimeoutError`; `restate.select(..., timeout=ctx.sleep(...))` in Python), with durations documented as **a lower bound**.
- **Crash mid-step:** all four replay from the top and short-circuit completed units; the *in-flight* unit is re-executed, not resumed. Temporal redoes the Activity attempt unless your code reads `heartbeatDetails`; DBOS retries the step; Restate re-runs the open `ctx.run`; Absurd re-runs the step with "brief overlapping execution" possible. Only Temporal (heartbeat `details`) and Absurd (`ctx.heartbeat`) offer mid-step progress mechanisms; DBOS timeouts are cooperative and carry no progress; Restate uses a 1-minute **inactivity timeout** rather than heartbeats and explicitly warns to raise it for long `ctx.run` blocks.

---

## 1. Which of these can keep its state in SQLite

### 1.1 DBOS Transact Python (`dbos` 3.3.0) — yes, SQLite is the default

**Version.** PyPI `dbos` latest is **3.3.0** (MIT, `requires-python >=3.10`, sdist `dbos-3.3.0.tar.gz` and wheel uploaded Oct 15, 2026); GitHub tag `3.3.0` was published 2026-10-15T17:25:47Z. The Python line is 3.x — 5.3.0 is the TypeScript line, not a Python version.

**Config surface.** `system_database_url: Optional[str]` on `DBOSConfig`, with the SQLite form printed verbatim as `sqlite:///[path to database file]` (example `sqlite:///dbos_example.sqlite`). With no URL configured, DBOS uses `sqlite:///[application_name].sqlite`, "any dashes in the application name replaced by underscores, and an underscore prepended if the name starts with a digit".

**No driver install.** Base dependencies include `sqlalchemy[asyncio]>=2.0.43`; `aiosqlite>=0.20.0` is only in the `aiosqlite` optional extra, and that extra is for `AsyncSQLAlchemyDatasource` with a `sqlite+aiosqlite:///app.sqlite` URL — not for the system database. The SQLite system database builds a **synchronous** engine (`sa.create_engine`) and async system-DB calls are offloaded with `asyncio.to_thread`. Note also there is **no `AsyncDBOS` class** in the package; async usage is `DBOS` with coroutine workflows and `_async` method variants.

**Implementation details.** `SQLiteSystemDatabase` sets `dbapi_conn.isolation_level = "IMMEDIATE"`, `PRAGMA busy_timeout=30000`, `PRAGMA foreign_keys=ON`; it sets **no journal-mode pragma** (no WAL) — the repo's own test fixture pre-creates each SQLite file with `PRAGMA journal_mode=WAL` because "under the default rollback journal a writer holds an exclusive lock across its commit, stalling the notification poller for seconds". The notification listener is polling-only.

**Documented limitations.** "Because a SQLite database is just a file on disk, it can't be used in a distributed setting where an application runs on multiple servers. Therefore, for production, we recommend using Postgres." `use_listen_notify` is "Ignored in SQLite, which always uses polling" (`notification_listener_polling_interval_sec` default 1.0); `dbos_system_schema`, `observability_query_timeout_sec`, `sys_db_idle_transaction_timeout_sec` are Postgres-specific; `run_migrations: false` with a missing SQLite file fails launch with `DBOSInitializationError`; and the SQLite backend raises "Filtering workflows by attributes is not supported on SQLite." At runtime it logs "The SQLite system database is for development and testing. PostgreSQL is recommended for production use." Crash recovery still works on SQLite: the Python programming guide's Ctrl+C-and-restart demo resumes at the last completed step under the default SQLite configuration.

**CLI, migrations and reset (this matters for co-locating an existing ledger).**
- `dbos start` is backend-agnostic: it loads `dbos-config.yaml`, runs each `runtimeConfig.start` command in a subprocess (own process group on Unix, signals forwarded, exit code propagated) and never connects to a database — the repo's own `test_cli.py` exercises it with a config containing only `name` and `runtimeConfig`.
- `dbos migrate` works on SQLite: URL resolution is `--sys-db-url` → yaml `system_database_url` → `sqlite:///<app>.sqlite`, and `SQLiteSystemDatabase.run_migrations` creates `dbos_migrations` in `sqlite_master` and applies statements one at a time. `--print-migrations` is Postgres-only and exits 1 on a `sqlite` URL.
- `dbos reset` on SQLite **deletes the database file** (`os.remove`), and the programmatic truncating reset `DELETE`s from every table in the file except `dbos_migrations`, the datasource migrations table and `sqlite_*`. Because SQLite system tables are **unqualified** (no `dbos.` schema — "None for SQLite = unqualified"), putting your ledger in the same file means either reset mode destroys ledger data.
- **There is no `dbos schema` command** — the CLI registers only `version`, `postgres start/stop`, `start`, `init`, `migrate`, `reset`, `rename-application` and the `workflow`/`queue` groups; the newer `dbosctl sysdb` group is explicitly documented as managing "the Postgres system database directly".

**Schedules and Kafka on SQLite.** Both are documented as first-class with no SQLite exclusion: "Schedules are stored in the database" and `DBOS.apply_schedules`/`create_schedule`/`backfill_schedule` are documented without caveat; `@DBOS.kafka_consumer` durably enqueues messages onto DBOS queues, deduped by topic/partition/group/offset, and the implementation files contain no SQLite branch. Both are exercised by a CI matrix of Python 3.10–3.14 × `SQLITE`/`POSTGRES` with a live Kafka broker. The practical costs on SQLite: everything polls (notification 1.0 s, scheduler 30 s default with a 1 s fast poll for the first 60 s, Kafka internal queues every 1 s), single-process only, and attribute filtering unavailable.

### 1.2 DBOS Transact TypeScript (`@dbos-inc/dbos-sdk` 5.3.0) — no SQLite

npm `latest` is **5.3.0** (dist-tags also `preview: 5.4.5-preview`, `test: 5.3.7-test.961f803`); GitHub release `v5.3` was published 2026-10-15T17:26:43Z. *Sources disagree on the npm publish date*: the version page shows 5.3.0 as "7 days ago" at a late-Oct fetch while one registry reading reports `lastPublished` 2026-10-22 — that later timestamp appears to belong to a preview/test publish, so the GitHub date (2026-10-15) is the safer anchor.

`systemDatabaseUrl` is documented only for Postgres ("A connection string to a Postgres database in which DBOS can store internal state… `postgresql://[username]:[password]@[hostname]:[port]/[database name]`", default `postgresql://postgres:dbos@localhost:5432/[application name]_dbos_sys`), the programming guide states "DBOS requires a Postgres database", and `package.json` lists `commander`, `pg`, `serialize-error`, `superjson`, `yaml` — no SQLite driver. SQLite support exists only as open, unmerged PR #1288 ("Add SQLite support, bring parity with dbos-transact-py", opened Jun 30, "Review required", +2,606/−578) proposing a `better-sqlite3` adapter "for local development and tests" with "Postgres remains the recommended production system database". A DBOS maintainer states the position plainly: "DBOS Python supports SQLite, DBOS Typescript does not, DBOS Go got it recently."

*Staleness signal:* the Python repo README (mirrored into the PyPI description) still says DBOS provides durable workflows "built on top of Postgres" and checkpoints "in Postgres", and the docs FAQ still says "an isolated system database in your Postgres database server" — both are out of date relative to the configuration and database-connection pages, which state SQLite is the default.

### 1.3 Absurd 0.5.1 — Postgres only

Apache-2.0, release `0.5.1` published 2026-10-20, one SQL file (`sql/absurd.sql`). Everything is Postgres tables: checkpoints, events (`e_`), waits (`w_`), and an `i_` idempotency table for partitioned queues. No SQLite path is documented. Its own SDK README at the pinned tag carries "Warning: this is an early experiment and should not be used in production."

### 1.4 pgflow 0.17.2 — Postgres + pgmq only

All packages at **0.17.2**, published 2026-10-02: `pgflow` (CLI), `@pgflow/core` (Apache-2.0, depends on `postgres ^3.4.5`), `@pgflow/dsl`, `@pgflow/edge-worker`, `@pgflow/client`. (`@pgflow/cli` does not exist on npm — registry 404; the CLI is the `pgflow` package.) Storage is Postgres with the pgmq extension: install applies migrations creating the `pgflow` and `pgmq` schemas via `psql $DATABASE_URL -f …`; self-hosting means self-hosted Supabase (pgmq 1.5.0+, Supavisor pooler, `EDGE_WORKER_DB_URL`) or Node/Bun workers against Postgres. No SQLite or local mode.

### 1.5 Hatchet v0.110.5 — Postgres mandatory; "embedded" means embedded Postgres

Latest release **v0.110.5** (2026-10-06). Three self-hosting modes are documented — **Hatchet Lite** ("Single docker image with bundled engine and API (development, testing, or low-throughput production)"), Docker Compose, Kubernetes/Helm — and the database component is "PostgreSQL for storing workflow state and metadata", with RabbitMQ optional. **Lite is one Hatchet container but still needs an external Postgres**: its compose file runs `postgres:15.6` and passes `DATABASE_URL` to `ghcr.io/hatchet-dev/hatchet/hatchet-lite:latest`. The repo's dev compose lists postgres:15.6, pgbouncer, rabbitmq:4.2.8-management and nats:2.14.3-alpine — no SQLite service or volume.

The one no-Docker mode is **Embedded Mode**: "you get a full Hatchet engine running locally without any external dependencies including Postgres. By default it uses embedded-postgres", persisting in `~/.hatchet-embedded/<hash of working dir>`, "which also persists across restarts". **No SQLite or embedded non-Postgres store appears in the documentation read.**

### 1.6 Restate 1.8.1 — embedded single-node store, but not SQLite

Latest release **v1.8.1** (2026-10-21); one binary. A single node keeps all state in `restate-data` (base dir, relative to the working directory), layered as a built-in Raft metadata server, the Bifrost durable log, and RocksDB partition state ("This cache can always be rebuilt from the log, so durability is not critical here"). "Restate fsyncs committed data to disk before acknowledging network messages", and "In case of a node or Restate process crash, you won't lose data, but you will experience a short window of unavailability while the process restarts." Durability of a single node is rated "Good (when using durable disk)"; backups are "Currently only for single-node deployments".

The store provider is chosen by `[bifrost] default-provider` / `RESTATE_BIFROST__DEFAULT_PROVIDER`, default `"replicated"`; `"local"` is "A local rocksdb-backed loglet" with a `[bifrost.local]` section. The local loglet and local metadata server were the default only up to **v1.3.2** and are described as "suitable for development and single-node deployments"; from v1.4.0 existing logs/metadata migrate to the replicated equivalents, and v1.8 documents exactly three metadata providers (Replicated, Etcd, Amazon S3) — no local option. So on 1.8.1 you run the replicated loglet on a single node rather than a legacy local store. There is no SQLite option anywhere.

### 1.7 Temporal — SQLite is dev/test only

Server persistence supports Cassandra 3.11/4.0/5.0.4+, PostgreSQL 13.18/14.15/15.10/16.6 and MySQL 5.7/8.0.19+; "Temporal also supports SQLite v3.x persistence, but this is meant only for development and testing, not production usage." Current Python SDK on PyPI is **1.34.0** (requires Python >=3.10).

### 1.8 LiteFS / Litestream — not synchronous durability overlays

**LiteFS** latest release **v0.5.14 (2025-04-22)**, last push 2026-05-11, Apache-2.0, not archived — roughly 18 months without a release. Its README says "This project is actively maintained but is currently in a beta state"; Fly's docs page says "LiteFS is stable and running in production environments. The project is still pre-1.0 so APIs may change" — a genuine disagreement between the repo and the vendor docs. Mechanically it is a FUSE passthrough filesystem recording per-transaction LTX files, with asynchronous replication ("there can be a short window of data loss if the primary dies unexpectedly"), a Consul lease (10 s TTL) for failover, and FUSE write throughput "to about 100 transactions per second". LiteFS's own FAQ contrasts it with Litestream as a single-node alternative that "does not support automatic failover". A support caveat banner ("We are not able to provide support or guidance for this product. Use with caution.") appears in search metadata for the Fly docs but not in the extracted page body.

**Litestream** latest release **v0.5.17 (2026-08-31)**, last push 2026-10-22 — actively developed. It defines itself as "a standalone disaster recovery tool for SQLite" that replicates incrementally to a file or S3, and it creates an internal `_litestream_lock` table (so the database is not byte-identical to its pre-Litestream state). Its durability limit is explicit: replication "every second… a catastrophic crash on your server will result in the loss of data in that time window… Synchronous replication is on the Litestream roadmap but has not yet been implemented", and it *recommends* `PRAGMA synchronous = NORMAL` "in exchange for durability". v0.5 recovery is an explicit `restore` replaying TXID-based LTX files, with restore points at LTX boundaries rather than per-transaction.

**Net:** neither makes a single-machine SQLite ledger crash-durable. On one machine, durability comes from SQLite's own WAL plus `synchronous=FULL`; LiteFS/Litestream add off-machine copies and bounded-loss recovery, not synchronous commit.

### 1.9 Mastra — unverified

Every Mastra source in this run (npm registry and package pages for `mastra`, `@mastra/core`, `@mastra/libsql`; the suspend-and-resume, snapshots, control-flow and human-in-the-loop docs pages; the libSQL storage adapter, its workflows domain and `packages/core/src/storage/constants.ts`) was blocked, so **no version string, snapshot table name, suspend/resume signature, timeout semantic or retry guarantee is asserted here.** Treat Mastra as an unpopulated column in this comparison rather than as a fit or non-fit.

---

## 2. "Wait for an external decision, with a timeout and a default" — exact semantics

| | Primitive | Result on timeout | Where the default lives | Late/early decision |
|---|---|---|---|---|
| **Temporal** | Python `await workflow.wait_condition(fn, *, timeout=…)`; TS `condition(fn, timeout): Promise<boolean>` | Python raises `asyncio.TimeoutError`; TS returns `false` | your `except` / `if (!ok)` branch | Signal is recorded in Event History; handler runs on wake |
| **DBOS** | `recv<T>(topic?, {timeoutSeconds})`, `getEvent<T>(workflowID, key, {timeoutSeconds})`; Python `DBOS.recv(topic=None, timeout_seconds=60.0)` | `None` / `null` | your `if x is None:` branch | message stays unconsumed in `dbos.notifications`, so a later recv can take it |
| **Absurd** | `awaitEvent(name, {stepName?, timeout?})` / `await_event(name, timeout=…)` | throws `TimeoutError`; **no checkpoint written** on the timeout path (TS source) | nothing in the API — the exception *is* the branch | events live in `e_`, first-emit-wins; a pre-emit is returned immediately |
| **Restate** | awakeable / signal raced against `ctx.sleep` | `orTimeout` rejects with `TimeoutError`; `restate.select` returns the `timeout` branch | a match/case or catch branch | resolution stored durably until the invocation receives it |
| **Mastra** | not verified | — | — | — |

### 2.1 Temporal

**Signatures.** Python: `await workflow.wait_condition(fn, *, timeout=timedelta|float|None, timeout_summary=None, event_groups=None) -> None`, returning normally when the condition holds and raising `asyncio.TimeoutError` otherwise; the canonical "timeout takes the default" shape is `try: await workflow.wait_condition(lambda: self._pending_decision is not None, timeout=sla_timeout)` … `except asyncio.TimeoutError: return await self._handle_escalation(...)`. TypeScript: `condition(fn, timeout): Promise<boolean>` — "@returns a boolean indicating whether the condition was true before the timeout expires" — implemented as `Promise.race([sleep(timeout).then(() => false), conditionInner(fn).then(() => true)])` inside a `CancellationScope`. *Version caveat from the SDK source:* before 1.5.0, `condition(fn, 0)` was treated as `condition(fn, undefined)`.

**Crash during the wait.** The wait does not consume a worker: "the Worker returns the current task to the Temporal Server and becomes idle… The Workflow's state is persisted and suspended on the Server. When a Signal arrives or a timeout fires, the Server schedules a new Workflow Task, the Worker replays the Event History to reconstruct the Workflow's state, and execution resumes from the `wait_condition` call" — durably, whether the wait is seconds or months. A Workflow Task failure causes the server to "retry Workflow Tasks indefinitely".

**Signals.** The client call "returns when the server accepts the Signal; it does *not* wait for the Signal to be delivered", and `WorkflowExecutionSignaled` "appears in the Workflow's Event History" — retention is server-side. You can only signal executions that haven't closed. Dedup: "For Updates, Temporal handles this for you on the server, by deduplicating according to the Update ID… For Signals, you should use a custom idempotency key that you send as part of your own signal inputs".

**Exactly-once.** Workflow code must be deterministic (`workflow.now()`, `workflow.uuid4()`, `workflow.random()`, no I/O; divergence raises `NondeterminismError`). Side effects belong in Activities, and "Activities may be retried if a Worker crashes mid-execution. Each Activity must be designed so that executing it twice with the same inputs produces the same outcome", with idempotency keys that "Include the Workflow Id and a step identifier in every external API call". Default retry policy retries **forever**, so an Activity only fails its caller "if you change the default Activity Retry Policy".

### 2.2 DBOS

**Signatures.** Reference page: `recv<T>(topic?: string, options?: RecvOptions): Promise<T|null>` with `RecvOptions { timeoutSeconds?, deadlineEpochMS?, pollingIntervalMs? }`, and "If no timeout is specified, a 60-second timeout is used"; `setEvent<T>(key, value, options?)` / `getEvent<T>(workflowID, key, options?: GetEventOptions)` returning `null` on timeout; `send<T>(destinationID, message, topic?, idempotencyKey?, options?)`. Python: `DBOS.recv(topic: Optional[str] = None, timeout_seconds: float = 60,)`, `DBOS.get_event(workflow_id, key, timeout_seconds: float = 60,)`, `DBOS.get_all_events`, `DBOS.set_event`, `DBOS.send(destination_id, message, topic=None) -> None`.

*Documented disagreement:* the TypeScript **tutorial** page still shows the older positional forms — `DBOS.recv<T>(topic?, timeoutSeconds?)` and `DBOS.getEvent<string>(handle.workflowID, PAYMENT_URL, 300)` — which contradicts the reference page's options objects. The Python page has an internal inconsistency of its own: the prose says "you can pass an `idempotency_key` to `DBOS.send` to guarantee exactly-once delivery" while the printed signature has no such parameter.

**Crash while blocked in recv.** There is no "resume at the receive". Recovery "restarts each interrupted workflow by calling it with its checkpointed inputs", and "as the workflow re-executes, it checks before each step if that step's output is checkpointed… If there is a checkpoint, the step returns the checkpointed output instead of executing". On a single server, "each time you restart your application's process, DBOS recovers all workflows that were executing before the restart (all PENDING workflows)", so a workflow blocked in `recv` re-executes from its start and re-issues the `recv`. Messages persist in `dbos.notifications` with `consumed` and `consumed_by_function_id` columns, so an unconsumed message survives and a later `recv` can take it — that is an inference from the schema, not an explicit doc statement. Whether a *completed* or *timed-out* `recv` is itself checkpointed in `operation_outputs` is **not stated** (the system-tables page names only `sleep` and `send` as recorded steps).

**Exactly-once.** Step outputs live in `dbos.operation_outputs` (`workflow_uuid`, `function_id`, `output`, `error`, `child_workflow_id`, timestamps). "Steps are tried at least once but are never re-executed after they complete"; "If a workflow fails while executing a step, it retries the step during recovery"; therefore "Steps should be idempotent". A crash after an external side effect but before the checkpoint commits re-runs that step. De-duplication is documented at three levels only: workflow IDs ("An assigned workflow ID acts as an idempotency key", with `workflowIDReusePolicy: 'reject'`), `send` idempotency keys / `dbos.send_message(..., message_id)`, and queue `deduplicationID`. No generic idempotency-key or outbox mechanism for arbitrary external HTTP calls is documented.

**Long-running waits and steps.** `StepConfig.timeoutMS` per attempt fails with `DBOSStepTimeoutError`, but "Step timeouts are cooperative: DBOS does not forcibly terminate a running step… A step that does not observe this signal keeps running in the background, but its result is discarded". Python's `@DBOS.step(timeout_seconds=30)` is "only supported for async steps, because Python provides no way to preempt a running synchronous function". Workflow-level timeouts are start-to-completion and "durable: they are stored in the database and persist across restarts, so workflows can have very long timeouts". There is an ownership token (`owner_xid`, "used to detect concurrent executions") but **no heartbeat or lease-expiry semantics** are documented; without Conductor there is no liveness detection of a hung executor — only restart-time recovery, and Conductor, when connected, "signals another executor to recover its workflows" when it "detects that an executor is unhealthy".

### 2.3 Absurd 0.5.1

**Signature.** TypeScript: `async awaitEvent(eventName: string, options?: { stepName?: string; timeout?: number }): Promise<JsonValue>` — "Waits for an event by name and returns its payload; optionally sets a custom step name and timeout (seconds)", "@throws TimeoutError If the event is not received before the timeout"; default checkpoint name `$awaitEvent:<eventName>`. Python: `ctx.await_event(event_name, step_name=None, timeout=None)`; Go: `absurd.AwaitEvent[ShipmentEvent](ctx, "order.shipped", absurd.AwaitEventOptions{Timeout: 24 * time.Hour})`. Negative timeouts are rejected by the SQL function (`'timeout must be non-negative'`). **There is no default/fallback-value parameter in any SDK** — "If the event doesn't arrive before the timeout expires, a `TimeoutError` is thrown."

**Crash while awaiting.** The wait is a row in the `w_` table: the run goes `sleeping` with `wake_event` set; a new worker replays cached checkpoints, re-issues the await, UPSERTs the same wait and suspends again. Completed steps "will never execute again — even across process restarts or retries", while "Code **outside** steps may execute multiple times across retries. Keep side-effects inside steps." A missed event is not lost: events land in `e_`, first-emit-wins, so an emit before the await is returned immediately.

**On timeout.** The run resumes as `running`, the expired wait row is deleted, and a repeat call returns `should_suspend=false, payload=NULL` without re-sleeping or creating a wait (regression test `test_await_event_timeout_does_not_recreate_wait`). The TypeScript SDK then throws `TimeoutError` and returns **before any checkpoint write**, so the timeout is *not* persisted as a null step result; conversely, if a checkpoint already exists for the step name, `awaitEvent` returns the cached value without waiting. Awaiting the same event twice yields distinct checkpoints (`name`, `name#2`, …), with delivery to the second unspecified in docs.

**Exactly-once.** Deliberately hedged: "The practical promise is not magical perfection… Durable execution gives you something close to \"exactly once\" behavior". For a side effect inside a step that then fails, derive an idempotency key from `ctx.taskID` (documented example ``const idempotencyKey = `${ctx.taskID}:payment`;``, "the key should come from something stable… not from the current time"). Spawn-time `idempotencyKey` dedups tasks (`SpawnResult.created === false` on a hit).

**Leases/heartbeats.** "The lease (claim timeout) is automatically extended whenever a checkpoint is written. If a worker crashes or fails to make progress before the lease expires, the task becomes available for another worker to pick up. This means brief overlapping execution is possible — design your steps to tolerate it." `ctx.heartbeat(seconds?)` extends the lease for long steps that don't checkpoint; worker options document `claimTimeout: 120` seconds and `fatalOnLeaseTimeout: true` ("exit process if task exceeds 2x lease"); client `defaultMaxAttempts` 5;`maxDuration` and `maxDelay` cancel policies are detected "at the next step(), heartbeat(), or awaitEvent() call". *Caveat:* the SQL claim function declares `p_claim_timeout integer default 30`, while the SDK docs show a 120-second `claimTimeout` — the SDK passes its own value explicitly, so 30 s is the SQL-level default only; verify per language.

### 2.4 Restate 1.8.1

**Primitives and signatures.** TypeScript `Context`: `awakeable<T>(serde?: Serde<T>): { id: string; promise: RestatePromise<T> }`, `resolveAwakeable<T>(id, payload?, serde?)`, `rejectAwakeable(id, reason)`, `signal<T>(name, serde?)`, `sleep(duration, name?)`. Documented sample: `const { id, promise } = ctx.awakeable<string>();` … `const review = await promise;`. Python returns a **tuple**, not an object: `id, promise = ctx.awakeable(type_hint=str)` … `review = await promise`, with `ctx.resolve_awakeable(name, review)` / `ctx.reject_awakeable(name, "Cannot be reviewed")`. Workflow promises are a `WorkflowContext` method, not `Context` — cross-invocation coordination uses **signals** (`ctx.signal<boolean>("approval")`), whose resolutions are stored durably until received. (The `awakeable` docstring references a non-existent `ctx.completeAwakeable(...)` — stale name; the real methods are `resolveAwakeable`/`rejectAwakeable`.)

**Timeout-with-default.** There is **no awakeable-level deadline**: "For long waits, combine the primitive with a durable timer to implement a timeout." TypeScript uses `RestatePromise.race([...])` or `.orTimeout({minutes:5})` — "If the timeout is fired, this Promise will be rejected with a TimeoutError" — with the documented caveat that the duration "is a lower-bound". Python uses `match await restate.select(result=ctx.workflow_call(...), timeout=ctx.sleep(timedelta(minutes=5))):` with `case ["result", result]"` / `case _: print("Order processing timed out")`.

**Kill while suspended.** Journal replay: the server "persists the request and creates a new execution journal"; on failure "the Restate Server will send a retry request to the service, including the latest journal", and the SDK "checks the journal for the last recorded result. If it finds a previous result, it skips executing that action". Suspension is zero-cost: "Handlers consume no resources while sleeping and resume at exactly the right time, even across restarts."

**Exactly-once.** Not absolute, and stated as such: "There is a small window where an action may be re-run, if a failure occurred between a successful run and persisting the result", and "at most one run will be re-executed on replay (the latest…)". Ingress dedup via the `idempotency-key` header ("Duplicate requests will return the same result as the original"); outbound keys from `ctx.request().id`, `ctx.rand.uuidv4()` / `ctx.uuid()` (seeded by the invocation ID, "so they return the same result on retries") or `rpc.opts({ idempotencyKey })`.

**Long steps.** No mid-`ctx.run` checkpoint; instead an inactivity timeout: "If Restate doesn't receive new journal entries from a service for more than one minute (by default), it will automatically suspend the invocation and retry it. However, some business logic can take longer to complete — for example, an LLM call that takes up to 3 minutes… you can adjust the service's inactivity timeout and abort timeout settings." Abort timeout defaults to 10 minutes. `ctx.run` accepts a retry policy (`maxRetryAttempts`, `maxRetryDuration`, …) ending in `TerminalError`. Server default retry policy is `initial-interval 500ms`, `exponentiation-factor 2`, `max-interval 1m`, **`max-attempts 70`**, `on-max-attempts "pause"`. Hazard for approval waits: "if you wait for an awakeable in an exclusive handler in a Virtual Object, all other calls to this object will be queued" — a lock held for hours.

---

## 3. Crash mid-step and multi-hour LLM agent steps

**Same model everywhere:** re-invoke the durable function from the top, short-circuit completed units, re-execute the unit that was in flight.

| | Re-executed on crash | Checkpoint unit | In-flight work | Mid-step progress mechanism |
|---|---|---|---|---|
| **Temporal** | Workflow replayed from Event History; "A completed Activity isn't executed again when the Workflow replays" | One history entry per Activity completion (per Workflow Task) | Activity attempt redone from scratch unless code reads `heartbeatDetails` | `heartbeat({details})`; next attempt reads it and skips ahead |
| **DBOS 5.3 / 3.3** | Whole workflow function, checkpointed steps return recorded output | One DB write per step, plus two per workflow | Step retried ("If a workflow fails while executing a step, it retries the step during recovery") | none — cooperative `timeoutMS` only |
| **Restate 1.8** | Handler replayed from journal, "skipping completed steps" | Journal entry per `ctx.run`/context action | Open `ctx.run` closure re-executed from its beginning | none — inactivity timeout (1 min) suspends instead |
| **Absurd 0.5.1** | Task re-runs as a new run; completed checkpoints replayed | Checkpoint row per step in Postgres | Step re-executed; brief overlap possible | `ctx.heartbeat(seconds)` extends the lease only |
| **Mastra** | not verified | — | — | — |

**Temporal, long steps.** Heartbeating is the only intra-Activity checkpoint: "A Heartbeat can include an application layer payload that can be used to save Activity Execution progress. If an Activity Task Execution times out due to a missed Heartbeat, the next Activity Task can access and continue with that payload." Guidance: heartbeat every 10–30 s, heartbeat timeout 2–3× the interval, applicable to "any Activity running longer than 30 seconds"; pitfalls include "Not resuming from heartbeat progress on retry" and "Heartbeat details have size limits". Heartbeat Timeout "is also capped at the Start-To-Close Timeout" and `0s` disables it; heartbeats are throttled to the smaller of `heartbeatTimeout*0.8` and 60 s; "Activities that don't Heartbeat can't receive a Cancellation". Start-To-Close "has no default of its own" — if neither Start-To-Close nor Schedule-To-Close is set the service rejects the Activity; Schedule-To-Close defaults to infinite. Crucially, "the Temporal Server doesn't detect failures when a Worker loses communication with the Server or crashes. Therefore… relies on the Start-To-Close Timeout to force Activity retries." Workflow Task Timeout defaults to 10 s, max 120 s. Default retry policy: initial 1 s, coefficient 2.0, max interval 100×initial, **unlimited attempts**; Workflows are not retried by default. For a multi-hour agent run, **Event History is capped at 51,200 events or 50 MB** (warnings at ~10,240 events/10 MB; "hitting either hard limit terminates the Workflow"), and Continue-As-New is the reset mechanism — directly relevant when each timer or signal costs ~4 events.

**Absurd, long steps.** Lease-only: `claimTimeout` default 120 s, auto-extended on checkpoint writes, `fatalOnLeaseTimeout: true` exits at 2× lease, and the docs warn of overlap. Two-phase stepping (`ctx.beginStep(name)` + `ctx.completeStep(handle, value)`) is documented for agent event loops. `maxDuration` ("Cancel task after N seconds total lifetime") and `maxDelay` ("Cancel task if no checkpoint written for N seconds") bound runaway sessions. The project positions itself for tasks that "may run for minutes, days, or years without losing state".

**DBOS, long steps.** No heartbeat. `StepConfig` defaults: `retriesAllowed` false, `intervalSeconds` 1, `maxAttempts` 3, `backoffRate` 2. Cancellation "preempts its execution at the beginning of its next step" — there is no mid-step interruption point. So a multi-hour agent step is either one long step whose entire progress is lost on crash, or must be decomposed into many checkpointed steps.

**Restate, long steps.** The documented LLM answer is configuration, not heartbeating: raise the service's `inactivityTimeout`/`abortTimeout` (defaults 1 min / 10 min), because "Otherwise, this timeout might kill the ongoing execution". A worker dying mid-`ctx.run` does not lose journaled progress; the open run is re-executed.

---

## 4. Disagreements and caveats to carry forward

- **Retry bound, Restate:** the Error Handling guide frames retries as going through "the regular retry cycle of suspension and re-invocation" until success, while the server-config reference publishes `max-attempts 70` with `on-max-attempts "pause"`, and the AI error-handling page confirms "a limited set of retries… after which the invocation will be paused". Treat 70/pause as the configured 1.8.x default.
- **Absurd lease default:** 30 s in the SQL function signature vs 120 s documented `claimTimeout` in the SDK.
- **DBOS step semantics:** "never re-executed after they complete" coexists with "retries the step during recovery" — the distinction is completed-and-checkpointed vs in-flight.
- **DBOS recv signature:** reference page (options object) vs tutorial page (positional timeout); the Python page documents an `idempotency_key` its own signature lacks.
- **DBOS documentation staleness:** README/PyPI description and the FAQ still describe Postgres-only checkpointing although SQLite is the default system database.
- **DBOS npm date:** 5.3.0 `latest` with GitHub release 2026-10-15, while a 2026-10-22 registry timestamp belongs to a preview/test publish.
- **LiteFS status:** repo README "beta state" vs Fly docs "stable and running in production… still pre-1.0".
- **Temporal SDK asymmetry:** Python raises, TypeScript returns a boolean — the same logical construct has different control flow, and TS `condition(fn, 0)` changed meaning in 1.5.0.
- **Restate docstring bug:** `awakeable` claims resolution via a non-existent `ctx.completeAwakeable`.

## 5. What this implies for a Python + SQLite ledger with long-lived agent workers

Only **DBOS Python** gives you SQLite-backed durable execution today without swapping the store: `pip install dbos`, `system_database_url="sqlite:///…"`, and step-level checkpoints in `operation_outputs` inside the same file — but note that system tables are unqualified in that file, `dbos reset` and the truncating reset both reach your own tables, `dbos migrate`/`dbos start` work fine against SQLite, there is no `dbos schema` command, notifications are poll-only at 1 s, attribute filtering is unavailable, and DBOS does not enable WAL for you. **Restate 1.8.1** is the strongest non-SQLite single-machine alternative (one binary, fsynced local log, journal replay, zero-cost suspension) if the state store can move off SQLite and you accept the replicated-loglet default. **Absurd 0.5.1** has the cleanest wait-for-event model but needs Postgres and is self-described as experimental. **Temporal** gives the most complete timeout/heartbeat semantics at the cost of a server and a dev-only SQLite backend. Because workers here are long LLM sessions that die with their host, the decisive question is mid-step recoverability: only Temporal's `heartbeatDetails` and Absurd's lease heartbeat give any intra-step progress; DBOS and Restate instead expect you to decompose the work into checkpointed steps or raise inactivity timeouts.

## 6. Open items

Mastra's versions (`mastra`, `@mastra/core`, `@mastra/libsql`), snapshot table schema, suspend/resume signatures, timeout primitive and retry/idempotency caveats remain unverified — no Mastra page was read. Also unverified: Absurd's comparison doc and its Python/Go SDK implementations (Absurd Python timeout behaviour rests on docs, not source); the full `absurd.sql` function bodies; Hatchet's engine configuration reference (that `DATABASE_URL` is the only storage knob); Temporal's execution-limits page (numeric timeout maxima); Restate's Python durable-timers page; DBOS's TypeScript `system_database.ts` recv/checkpoint paths; and LiteFS Cloud's retirement status.

## Citations

- [https://pypi.org/project/dbos/](https://pypi.org/project/dbos/) — confidence high
- [https://github.com/dbos-inc/dbos-transact-py](https://github.com/dbos-inc/dbos-transact-py) — confidence high
- [https://docs.dbos.dev/python/tutorials/database-connection](https://docs.dbos.dev/python/tutorials/database-connection) — confidence high
- [https://github.com/dbos-inc/dbos-docs/blob/HEAD/docs/python/reference/configuration.md](https://github.com/dbos-inc/dbos-docs/blob/HEAD/docs/python/reference/configuration.md) — confidence high
- [https://github.com/dbos-inc/dbos-transact-py/blob/HEAD/dbos/_sys_db_sqlite.py](https://github.com/dbos-inc/dbos-transact-py/blob/HEAD/dbos/_sys_db_sqlite.py) — confidence high
- [https://github.com/dbos-inc/dbos-transact-py/blob/HEAD/dbos/_sys_db_sqlite.py](https://github.com/dbos-inc/dbos-transact-py/blob/HEAD/dbos/_sys_db_sqlite.py) — confidence high
- [https://github.com/dbos-inc/dbos-transact-py/blob/HEAD/pyproject.toml](https://github.com/dbos-inc/dbos-transact-py/blob/HEAD/pyproject.toml) — confidence high
- [https://docs.dbos.dev/python/tutorials/transaction-tutorial](https://docs.dbos.dev/python/tutorials/transaction-tutorial) — confidence high
- [https://github.com/dbos-inc/dbos-transact-py/blob/HEAD/dbos/__init__.py](https://github.com/dbos-inc/dbos-transact-py/blob/HEAD/dbos/__init__.py) — confidence high
- [https://github.com/dbos-inc/dbos-transact-py/blob/HEAD/dbos/cli/cli.py](https://github.com/dbos-inc/dbos-transact-py/blob/HEAD/dbos/cli/cli.py) — confidence high
- [https://github.com/dbos-inc/dbos-transact-py/blob/HEAD/dbos/cli/cli.py](https://github.com/dbos-inc/dbos-transact-py/blob/HEAD/dbos/cli/cli.py) — confidence high
- [https://github.com/dbos-inc/dbos-transact-py/blob/HEAD/dbos/cli/cli.py](https://github.com/dbos-inc/dbos-transact-py/blob/HEAD/dbos/cli/cli.py) — confidence medium
- [https://github.com/dbos-inc/dbos-transact-py/blob/HEAD/dbos/_sys_db_sqlite.py](https://github.com/dbos-inc/dbos-transact-py/blob/HEAD/dbos/_sys_db_sqlite.py) — confidence high
- [https://raw.githubusercontent.com/dbos-inc/dbos-transact-py/HEAD/dbos/_sys_db.py](https://raw.githubusercontent.com/dbos-inc/dbos-transact-py/HEAD/dbos/_sys_db.py) — confidence high
- [https://github.com/dbos-inc/dbos-transact-py/blob/HEAD/dbos/_sys_db_sqlite.py](https://github.com/dbos-inc/dbos-transact-py/blob/HEAD/dbos/_sys_db_sqlite.py) — confidence high
- [https://docs.dbos.dev/conductor/reference/dbosctl](https://docs.dbos.dev/conductor/reference/dbosctl) — confidence high
- [https://github.com/dbos-inc/dbos-transact-py/blob/HEAD/tests/conftest.py](https://github.com/dbos-inc/dbos-transact-py/blob/HEAD/tests/conftest.py) — confidence high
- [https://docs.dbos.dev/python/tutorials/scheduled-workflows.md](https://docs.dbos.dev/python/tutorials/scheduled-workflows.md) — confidence high
- [https://docs.dbos.dev/python/tutorials/kafka-integration.md](https://docs.dbos.dev/python/tutorials/kafka-integration.md) — confidence high
- [https://github.com/dbos-inc/dbos-transact-py/blob/HEAD/.github/workflows/unit-test.yml](https://github.com/dbos-inc/dbos-transact-py/blob/HEAD/.github/workflows/unit-test.yml) — confidence high
- [https://docs.dbos.dev/python/reference/configuration.md](https://docs.dbos.dev/python/reference/configuration.md) — confidence high
- [https://www.npmjs.com/package/@dbos-inc/dbos-sdk](https://www.npmjs.com/package/@dbos-inc/dbos-sdk) — confidence high
- [https://github.com/dbos-inc/dbos-transact-ts](https://github.com/dbos-inc/dbos-transact-ts) — confidence high
- [https://docs.dbos.dev/typescript/reference/configuration](https://docs.dbos.dev/typescript/reference/configuration) — confidence high
- [https://docs.dbos.dev/typescript/programming-guide](https://docs.dbos.dev/typescript/programming-guide) — confidence high
- [https://github.com/dbos-inc/dbos-transact-ts/blob/HEAD/package.json](https://github.com/dbos-inc/dbos-transact-ts/blob/HEAD/package.json) — confidence high
- [https://github.com/dbos-inc/dbos-transact-ts/pull/1288](https://github.com/dbos-inc/dbos-transact-ts/pull/1288) — confidence high
- [https://github.com/dbos-inc/dbos-transact-java/issues/405](https://github.com/dbos-inc/dbos-transact-java/issues/405) — confidence high
- [https://github.com/dbos-inc/dbos-transact-py/blob/HEAD/README.md](https://github.com/dbos-inc/dbos-transact-py/blob/HEAD/README.md) — confidence medium
- [https://docs.dbos.dev/typescript/reference/methods](https://docs.dbos.dev/typescript/reference/methods) — confidence high
- [https://docs.dbos.dev/typescript/tutorials/workflow-communication](https://docs.dbos.dev/typescript/tutorials/workflow-communication) — confidence high
- [https://docs.dbos.dev/python/tutorials/workflow-communication](https://docs.dbos.dev/python/tutorials/workflow-communication) — confidence high
- [https://docs.dbos.dev/architecture](https://docs.dbos.dev/architecture) — confidence high
- [https://docs.dbos.dev/explanations/system-tables](https://docs.dbos.dev/explanations/system-tables) — confidence high
- [https://docs.dbos.dev/typescript/tutorials/workflow-tutorial](https://docs.dbos.dev/typescript/tutorials/workflow-tutorial) — confidence high
- [https://docs.dbos.dev/typescript/tutorials/step-tutorial](https://docs.dbos.dev/typescript/tutorials/step-tutorial) — confidence high
- [https://docs.dbos.dev/python/tutorials/step-tutorial](https://docs.dbos.dev/python/tutorials/step-tutorial) — confidence high
- [https://docs.dbos.dev/production/workflow-recovery](https://docs.dbos.dev/production/workflow-recovery) — confidence high
- [https://raw.githubusercontent.com/earendil-works/absurd/0.5.1/sdks/typescript/src/index.ts](https://raw.githubusercontent.com/earendil-works/absurd/0.5.1/sdks/typescript/src/index.ts) — confidence high
- [https://raw.githubusercontent.com/earendil-works/absurd/0.5.1/docs/sdks/typescript.md](https://raw.githubusercontent.com/earendil-works/absurd/0.5.1/docs/sdks/typescript.md) — confidence high
- [https://raw.githubusercontent.com/earendil-works/absurd/0.5.1/docs/sdks/python.md](https://raw.githubusercontent.com/earendil-works/absurd/0.5.1/docs/sdks/python.md) — confidence high
- [https://raw.githubusercontent.com/earendil-works/absurd/0.5.1/docs/concepts.md](https://raw.githubusercontent.com/earendil-works/absurd/0.5.1/docs/concepts.md) — confidence high
- [https://raw.githubusercontent.com/earendil-works/absurd/0.5.1/docs/concepts.md](https://raw.githubusercontent.com/earendil-works/absurd/0.5.1/docs/concepts.md) — confidence high
- [https://raw.githubusercontent.com/earendil-works/absurd/0.5.1/docs/concepts.md](https://raw.githubusercontent.com/earendil-works/absurd/0.5.1/docs/concepts.md) — confidence high
- [https://raw.githubusercontent.com/earendil-works/absurd/0.5.1/tests/test_events.py](https://raw.githubusercontent.com/earendil-works/absurd/0.5.1/tests/test_events.py) — confidence high
- [https://raw.githubusercontent.com/earendil-works/absurd/0.5.1/tests/test_events.py](https://raw.githubusercontent.com/earendil-works/absurd/0.5.1/tests/test_events.py) — confidence high
- [https://raw.githubusercontent.com/earendil-works/absurd/0.5.1/sdks/typescript/src/index.ts](https://raw.githubusercontent.com/earendil-works/absurd/0.5.1/sdks/typescript/src/index.ts) — confidence high
- [https://raw.githubusercontent.com/earendil-works/absurd/0.5.1/docs/sdks/typescript.md](https://raw.githubusercontent.com/earendil-works/absurd/0.5.1/docs/sdks/typescript.md) — confidence high
- [https://raw.githubusercontent.com/earendil-works/absurd/0.5.1/sql/absurd.sql](https://raw.githubusercontent.com/earendil-works/absurd/0.5.1/sql/absurd.sql) — confidence low
- [https://github.com/earendil-works/absurd/tree/0.5.1/sdks/typescript](https://github.com/earendil-works/absurd/tree/0.5.1/sdks/typescript) — confidence high
- [https://github.com/earendil-works/absurd](https://github.com/earendil-works/absurd) — confidence high
- [https://restatedev.github.io/sdk-typescript/interfaces/_restatedev_restate-sdk.Context.html](https://restatedev.github.io/sdk-typescript/interfaces/_restatedev_restate-sdk.Context.html) — confidence high
- [https://docs.restate.dev/develop/ts/external-events.md](https://docs.restate.dev/develop/ts/external-events.md) — confidence high
- [https://docs.restate.dev/develop/python/external-events.md](https://docs.restate.dev/develop/python/external-events.md) — confidence high
- [https://restatedev.github.io/sdk-typescript/types/_restatedev_restate-sdk.RestatePromise.html](https://restatedev.github.io/sdk-typescript/types/_restatedev_restate-sdk.RestatePromise.html) — confidence high
- [https://docs.restate.dev/foundations/actions.md](https://docs.restate.dev/foundations/actions.md) — confidence high
- [https://docs.restate.dev/guides/request-lifecycle.md](https://docs.restate.dev/guides/request-lifecycle.md) — confidence high
- [https://restatedev.github.io/sdk-typescript/interfaces/_restatedev_restate-sdk.Context.html](https://restatedev.github.io/sdk-typescript/interfaces/_restatedev_restate-sdk.Context.html) — confidence high
- [https://docs.restate.dev/foundations/key-concepts.md](https://docs.restate.dev/foundations/key-concepts.md) — confidence high
- [https://docs.restate.dev/develop/ts/durable-steps.md](https://docs.restate.dev/develop/ts/durable-steps.md) — confidence high
- [https://docs.restate.dev/guides/error-handling](https://docs.restate.dev/guides/error-handling) — confidence high
- [https://docs.restate.dev/references/server-config](https://docs.restate.dev/references/server-config) — confidence high
- [https://docs.restate.dev/server/overview](https://docs.restate.dev/server/overview) — confidence high
- [https://docs.restate.dev/references/server-config](https://docs.restate.dev/references/server-config) — confidence high
- [https://docs.restate.dev/guides/local-to-replicated](https://docs.restate.dev/guides/local-to-replicated) — confidence high
- [https://docs.restate.dev/server/snapshots](https://docs.restate.dev/server/snapshots) — confidence high
- [https://github.com/restatedev/restate](https://github.com/restatedev/restate) — confidence high
- [https://docs.restate.dev/develop/ts/external-events.md](https://docs.restate.dev/develop/ts/external-events.md) — confidence high
- [https://docs.temporal.io/guides/reliable-document-approvals.md](https://docs.temporal.io/guides/reliable-document-approvals.md) — confidence high
- [https://raw.githubusercontent.com/temporalio/sdk-typescript/main/packages/workflow/src/workflow.ts](https://raw.githubusercontent.com/temporalio/sdk-typescript/main/packages/workflow/src/workflow.ts) — confidence high
- [https://docs.temporal.io/guides/reliable-document-approvals.md](https://docs.temporal.io/guides/reliable-document-approvals.md) — confidence high
- [https://docs.temporal.io/develop/python/workflows/message-passing.md](https://docs.temporal.io/develop/python/workflows/message-passing.md) — confidence high
- [https://docs.temporal.io/handling-messages.md](https://docs.temporal.io/handling-messages.md) — confidence high
- [https://docs.temporal.io/encyclopedia/detecting-activity-failures.md](https://docs.temporal.io/encyclopedia/detecting-activity-failures.md) — confidence high
- [https://docs.temporal.io/design-patterns/long-running-activity](https://docs.temporal.io/design-patterns/long-running-activity) — confidence high
- [https://docs.temporal.io/evaluate/features/timeouts-and-retries](https://docs.temporal.io/evaluate/features/timeouts-and-retries) — confidence high
- [https://docs.temporal.io/encyclopedia/retry-policies](https://docs.temporal.io/encyclopedia/retry-policies) — confidence high
- [https://docs.temporal.io/guides/reliable-document-approvals.md](https://docs.temporal.io/guides/reliable-document-approvals.md) — confidence high
- [https://docs.temporal.io/temporal-service/persistence.md](https://docs.temporal.io/temporal-service/persistence.md) — confidence high
- [https://pypi.org/project/temporalio/](https://pypi.org/project/temporalio/) — confidence high
- [https://github.com/hatchet-dev/hatchet](https://github.com/hatchet-dev/hatchet) — confidence high
- [https://docs.hatchet.run/self-hosting](https://docs.hatchet.run/self-hosting) — confidence high
- [https://docs.hatchet.run/llms/self-hosting/hatchet-lite.md](https://docs.hatchet.run/llms/self-hosting/hatchet-lite.md) — confidence high
- [https://docs.hatchet.run/v1/embedded](https://docs.hatchet.run/v1/embedded) — confidence high
- [https://docs.hatchet.run/v1/running-locally](https://docs.hatchet.run/v1/running-locally) — confidence high
- [https://www.npmjs.com/package/@pgflow/core](https://www.npmjs.com/package/@pgflow/core) — confidence high
- [https://www.npmjs.com/package/@pgflow/edge-worker](https://www.npmjs.com/package/@pgflow/edge-worker) — confidence high
- [https://www.pgflow.dev/get-started/installation/](https://www.pgflow.dev/get-started/installation/) — confidence high
- [https://www.pgflow.dev/deploy/supabase/self-hosted/](https://www.pgflow.dev/deploy/supabase/self-hosted/) — confidence high
- [https://github.com/superfly/litefs](https://github.com/superfly/litefs) — confidence high
- [https://github.com/superfly/litefs/blob/HEAD/README.md](https://github.com/superfly/litefs/blob/HEAD/README.md) — confidence high
- [https://docs.fly.io/litefs](https://docs.fly.io/litefs) — confidence high
- [https://docs.fly.io/litefs/faq](https://docs.fly.io/litefs/faq) — confidence high
- [https://github.com/benbjohnson/litestream](https://github.com/benbjohnson/litestream) — confidence high
- [https://github.com/benbjohnson/litestream/blob/HEAD/README.md](https://github.com/benbjohnson/litestream/blob/HEAD/README.md) — confidence high
- [https://litestream.io/tips/](https://litestream.io/tips/) — confidence high
- [https://litestream.io/how-it-works/](https://litestream.io/how-it-works/) — confidence high
- [https://docs.sqlalchemy.org/en/20/dialects/sqlite.html](https://docs.sqlalchemy.org/en/20/dialects/sqlite.html) — confidence medium

## Unverified (as reported by the job)

- {"topic": "Mastra libSQL storage adapter package identity and version on npm", "url": "https://registry.npmjs.org/%40mastra/libsql", "reason": "Page content was not retrieved in this run; no registry metadata (name, version, dist-tags, publish dates) was available to read."}
- {"topic": "Mastra libSQL storage adapter package page", "url": "https://www.npmjs.com/package/@mastra/libsql", "reason": "Page content was not retrieved in this run; could not confirm the published package name or version string from the package page."}
- {"topic": "mastra package version on npm", "url": "https://registry.npmjs.org/mastra", "reason": "Page content was not retrieved in this run; no version/dist-tag data available."}
- {"topic": "mastra package page on npm", "url": "https://www.npmjs.com/package/mastra", "reason": "Page content was not retrieved in this run."}
- {"topic": "@mastra/core package version on npm", "url": "https://registry.npmjs.org/%40mastra/core", "reason": "Page content was not retrieved in this run; no version/dist-tag data available."}
- {"topic": "@mastra/core package page", "url": "https://www.npmjs.com/package/@mastra/core", "reason": "Page content was not retrieved in this run."}
- {"topic": "Mastra documented suspend/resume API names, signatures and resume-data semantics", "url": "https://mastra.ai/docs/workflows/suspend-and-resume", "reason": "Docs page was not read, so no wording or signatures could be quoted."}
- {"topic": "What Mastra workflow state is persisted, where, and whether it survives restart", "url": "https://mastra.ai/docs/workflows/snapshots", "reason": "Docs page was not read, so persistence claims and any documented-vs-code table naming could not be verified."}
- {"topic": "Mastra control-flow primitives (sleep/until/branching) usable to emulate a timeout branch", "url": "https://mastra.ai/docs/workflows/control-flow", "reason": "Docs page was not read; whether a built-in wait-with-timeout primitive exists remained unverified."}
- {"topic": "Mastra human-in-the-loop semantics and retry/idempotency guidance", "url": "https://mastra.ai/docs/workflows/human-in-the-loop", "reason": "Docs page was not read; retry and at-least-once side-effect caveats could not be verified."}
- {"topic": "Mastra snapshot table/column constants in core", "url": "https://raw.githubusercontent.com/mastra-ai/mastra/HEAD/packages/core/src/storage/constants.ts", "reason": "Repository file was not read, so the exact table name and schema constants could not be confirmed against the docs prose."}
- {"topic": "Mastra libSQL adapter workflows domain (table creation, per-step snapshot writes)", "url": "https://raw.githubusercontent.com/mastra-ai/mastra/HEAD/stores/libsql/src/storage/domains/workflows/index.ts", "reason": "Repository file was not read; per-step snapshot persistence and schema could not be confirmed."}
- {"topic": "Mastra libSQL storage adapter entry point (supported domains)", "url": "https://raw.githubusercontent.com/mastra-ai/mastra/HEAD/stores/libsql/src/storage/index.ts", "reason": "Repository file was not read."}
- {"topic": "Whether DBOS Python sets SQLite journal_mode / WAL, and the literal table names created by sqlite_migrations", "url": "https://raw.githubusercontent.com/dbos-inc/dbos-transact-py/3.3.0/dbos/_sys_db.py", "reason": "Retrieval was interrupted partway through the run, so the grep for journal_mode/WAL and the literal CREATE TABLE names could not be completed; the 'no WAL pragma' conclusion rests on the full read of _sys_db_sqlite.py plus the conftest WAL comment."}
- {"topic": "Whether any DBOS CLI command named `dbos schema` exists in older releases or the TypeScript CLI", "url": null, "reason": "The web search for 'dbos schema' could not be issued; the negative finding rests only on the complete dbos/cli/cli.py, the docs CLI reference and the dbosctl reference."}
- {"topic": "DBOS TypeScript recv / message-consumption and step-checkpoint implementation", "url": "https://raw.githubusercontent.com/dbos-inc/dbos-transact-ts/v5.3/src/system_database.ts", "reason": "Only the head of the 80,182-character file was returned; the recv, checkOperationOutput/recordOperationResult and recovery paths were never read, so whether a completed or timed-out recv is checkpointed could not be confirmed from source."}
- {"topic": "DBOS Python SDK implementation of recv/send/get_event and its step checkpointing", "url": null, "reason": "Source files at tag 3.3.0 (e.g. dbos/_sys_db.py, dbos/_core.py) were never fetched, so Python recv semantics rest on the docs pages only. (The page itself WAS retrieved elsewhere in this run and backs citations \u2014 this entry records an unverified topic, not an unusable source.)"}
- {"topic": "Full body of absurd.await_event(...) and the lease/heartbeat SQL functions", "url": null, "reason": "Only a keyword-filtered, per-line-truncated subset of this 3,157-line file could be retrieved, so the exact control flow of await_event, claim_task and extend_claim is inferred from SDK source and tests rather than quoted. (The page itself WAS retrieved elsewhere in this run and backs citations \u2014 this entry records an unverified topic, not an unusable source.)"}
- {"topic": "Absurd Python SDK implementation of its await_event timeout path", "url": "https://github.com/earendil-works/absurd/tree/0.5.1/sdks/python", "reason": "The package's source file paths could not be listed and no second fetch was possible; Python timeout behaviour is documented from docs/sdks/python.md only, not from source."}
- {"topic": "Temporal Durable Execution overview page", "url": "https://docs.temporal.io/encyclopedia/durable-execution.md", "reason": "Truncated mid-page; only the definition of Durable Execution was read."}
- {"topic": "Python SDK API reference signature of workflow.wait_condition (keyword arguments timeout_summary, event_groups)", "url": "https://python.temporal.io/temporalio.workflow.html", "reason": "Page fetched but rendered only the module index/TOC, not the function body; the exact keyword-argument signature came from curated SDK docs rather than a readable API page."}
- {"topic": "Temporal prose evidence for a hard maximum Activity duration", "url": null, "reason": "Temporal documents no intrinsic maximum Activity duration (Start-To-Close has no default and Schedule-To-Close defaults to infinite); no absolute cap was found. (The page itself WAS retrieved elsewhere in this run and backs citations \u2014 this entry records an unverified topic, not an unusable source.)"}
- {"topic": "Restate docs index (to locate a restate-server CLI reference page for provider/base-dir flags)", "url": "https://docs.restate.dev/llms.txt", "reason": "Retrieved but truncated at 3,008 of 33,748 characters, so the CLI reference entry could not be located."}
- {"topic": "LiteFS Cloud retirement date and current support-status wording from Fly's own pages", "url": "https://docs.fly.io/litefs/cloud-backups.md", "reason": "Only seen as a search-result snippet stating the docs are deprecated and refer to a product retired on October 15, 2024; the page itself was never fetched, so it cannot support a finding."}
- {"topic": "SQLAlchemy aiosqlite dialect section explicitly stating the aiosqlite package must be installed", "url": null, "reason": "Page truncated at ~12k of 63.6k characters; the DBAPI-support summary was read but the per-dialect aiosqlite section that names the package requirement was below the cut. (The page itself WAS retrieved elsewhere in this run and backs citations \u2014 this entry records an unverified topic, not an unusable source.)"}
- {"topic": "At runtime DBOS logs 'Using SQLite as a system database. The SQLite system database is for development and testing. PostgreSQL is recommended for production use.'", "url": "https://github.com/dbos-inc/dbos-transact-py/blob/HEAD/dbos/_sys_db.py", "reason": "Citation dropped: this URL was never retrieved in this run, so the claim is unsupported by evidence gathered here."}
- {"topic": "Absurd's SQL claim function declares p_claim_timeout integer default 30, differing from the SDK's documented 120-second claimTimeout.", "url": null, "reason": "Number check: 120 does not occur in the text retrieved from the cited page (https://raw.githubusercontent.com/earendil-works/absurd/0.5.1/sql/absurd.sql) \u2014 the figure may be invented, taken from another page or the given background, or computed; confirm before relying on it."}
