# ADR-011 — One ledger, one event log, one writer per entity

- Status: accepted · 2026-10-22 · revised after panel passes 1 and 2 (dat-3, dat-4, dat-9, dat-12, dat-13, dur-4…dur-6, sim-2, sim-6)
- Evidence: `findings-2026-10-22.md` (65-column `triage_items`, 44 transition pairs, `working → working` 768), `evidence/kpi/baseline.out.md` §data quality (`fixed_by_pr`, `revert_pr`, `reverting_sha` never populated; signatures unique per row), `evidence/incidents/incidents.md` (577 owner-facing notifications, only 140 visible to the KPI), `evidence/signals/signals.md` (`slack_update` never ingested), Round 5 *Established facts* (Hermes reads `warden.db` directly), `design/model.md`

## Context and problem statement

Warden's lifecycle is implicit: sub-stages live in columns, so its own state machine cannot be
read, KPIs miss most owner pages, and other services read its database directly. The model
(`design/model.md`) has eleven nouns, each with one system of record. Where do they live, and how
does every view stay consistent?

## Decision outcome

1. **A fresh ledger, `~/.warden/ledger.db`**, with the model's schema: one table per noun that
   has ledger state (conditions, incidents, tasks, changes, deployments, verifications, decisions,
   agents, artifacts), the two noun-owned tables `task_deps` (Task) and `project_runtime`
   (Project's runtime record), and the **plumbing** tables `events`, `operations`, `timers`,
   `leases`, `deliveries` — named infrastructure, exempt from the noun count. Signals are a view
   over `events`; a Project's configuration lives in git. Owner intents, the runaway breaker,
   budgets and known-bad versions need no table of their own (`design/model.md` §1). A table that
   is neither a noun's, noun-owned nor plumbing fails the concept-budget check
   (`design/proof.md` §6). `PRAGMA synchronous=FULL` (the spike ran FULL, the old ledger NORMAL;
   under WAL, NORMAL can drop the last commits on power loss — `spikes/02-durable/REPORT.md`). The
   old `warden.db` stops with the old loop and is archived read-only; history enters the new ledger
   by **one import** (signals, closed incidents with recipes, decisions, tasks), never by
   dual-writes. *Amended 2026-10-22 (owner: rewrite, not co-run) — "evolved in place" no longer
   binds.*
   - **The import is a pure function** of the frozen snapshot plus the delta recorded at the stop,
     into a new file swapped in by rename; ids are deterministic (`inc_` + hash of the old id,
     likewise per noun), so a re-run yields the same rows. The archive is a `sqlite3 .backup` taken
     after the old loop is stopped and nothing holds the file open (W1a). Imported events carry
     actor `import`; an imported open Decision's deadline is anchored at go-live plus its class
     expiry (ADR-014), never at its original creation.
   - **Adoption pass.** Before the first effect, every non-terminal old item has its external state
     probed — open PRs, in-flight deploys, in-doubt operations — and so does the work that keeps
     running after the old loop stops: agent-gateway jobs still in flight (each result adopted by
     its old item id when it lands, so the job's PR becomes that item's Change with no extra
     worker), live herdr tabs (recorded as observed Agents) and the Argo action queue (each entry
     ends applied or rejected, with an event). The new entity is set from what the probe finds (a
     Change adopting the open PR, a Deployment at the observed version, a resolved operation), so
     the spawner duplicates nothing.
   - **Restore is an adopt mode.** After restoring the off-box copy or failing an integrity check,
     the ledger refuses effects, and `rd` refuses every spawn (ADR-007 §3), until the adoption pass
     has probed every in-doubt operation.
2. **One append-only `events` table** (schema in `design/model.md` §4) written by one `emit()`
   inside the transaction that changes the entity (transactional outbox). Signals are
   `signal.received` events. Every event carries `trace_id` (derived from the root incident or
   task id), `causation` and `correlation` (the lineage root, enforced by `emit()`). Every decision
   a loop takes is itself an event carrying its outcome and reason, so a rebuild replays decisions
   and never re-evaluates policy against a manifest, rule or calibration that has since changed; an
   event a manifest influenced also carries `manifest_sha` for audit and replay-diffing
   (`design/model.md` §3 invariants 8 and 9, §4).
3. **One writer per entity table.** Write functions for a noun live in one module; a CI check
   rejects writes from anywhere else. Adapters write Signals only; the Writer column of
   `design/model.md` §1 names each noun's module, including how a ref-adapter merge reaches the
   Change module and how started / deployed / failed Signals from every source reach the one
   Deployment writer. Readers (Argo's factory API, Hermes, KPI scripts) open the ledger read-only or
   use warden's API; nothing outside warden opens it for writing.
4. **Projections** consume `events` by cursor, in two kinds:
   - **pure read models** (Argo read models, the digest, Beads-style exports) are folds that can be
     rebuilt from zero. A read model with no event source is a **live probe**, not a projection:
     `design/argo.md` labels it, it renders with `as_of`, and it feeds no KPI or control input;
   - **effectors** (push, vault write such as the brain project note) record
     `deliveries(event_id, channel)` before sending, so rebuilding a projection never re-sends.
     Decision and heads-up pushes are at-least-once: the delivery moves pending → accepted, is
     retried until the push service accepts it, and the phone de-duplicates by event id. Every
     effector starts at a go-live cursor and skips events with actor `import`, so replaying the
     imported history sends nothing.
5. **One process, capped inventory.** Every loop (reconcilers, correlator, planner, spawner,
   Witness, merge train, deploy reconciler, projectors), ingest, the factory read API and the write
   verbs run as phases of one warden process, not as services of their own — apart from ADR-012's
   independent watchdog; `factory` and `rv` fold into the one factory CLI (`warden manifest …`,
   `warden artifact …`). The concept-budget check covers a generated inventory of processes per
   host, agent-facing CLIs and stores; its terms and caps (today's measured count minus the cuts
   this design claims, measured in W12) are in `design/proof.md` §6.
6. **Retention:** events forever (1.7k in six months; a hundredfold is still small); nightly
   off-box copy.

### Consequences

- Good: statecharts become explicit; every owner page is an event, so `owner_pages` is a query; Argo needs no snapshots; no legacy column survives into the new schema.
- Bad: an import to write and reconcile once; the ledger becomes the single most important file on the mini (backup, integrity check in the heartbeat).

### Confirmation

CI: the one-writer check; a projection-rebuild test (drop a read model, rebuild from events,
compare; effectors rebuilt alongside re-send nothing already accepted, and every effector started
from cursor 0 sends 0 for imported events); the inventory caps check; `PRAGMA integrity_check` in
the heartbeat; an import reconciliation that accounts for every archived event, item and
transition, and an identical second run from the same snapshot; an adoption test — a snapshot
holding a live agent-gateway job, a live herdr tab, an Argo queue entry and an open Decision older
than its class expiry yields the job's PR adopted as the item's Change with 0 extra workers, the
tab as an observed Agent, the queue entry ended with an event and the Decision's deadline at
go-live plus its expiry, identical across two runs; a restore test — yesterday's copy wired to a
world that already ran the effects re-executes 0 of them; KPI scripts in `evidence/` reproduce the
baseline from the imported events.
