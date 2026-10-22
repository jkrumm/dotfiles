# ADR-011 — One ledger, one event log, one writer per entity

- Status: accepted · 2026-10-22
- Evidence: `findings-2026-10-22.md` (65-column `triage_items`, 44 transition pairs, `working → working` 768), `evidence/kpi/baseline.out.md` §data quality (`fixed_by_pr`, `revert_pr`, `reverting_sha` never populated; signatures unique per row), `evidence/incidents/incidents.md` (577 owner-facing notifications, only 140 visible to the KPI), `evidence/signals/signals.md` (`slack_update` never ingested), Round 5 *Established facts* (Hermes reads `warden.db` directly), `design/model.md`

## Context and problem statement

Warden's lifecycle is implicit: sub-stages live in columns, so its own state machine cannot be
read, KPIs miss most owner pages, and other services read its database directly. The model
(`design/model.md`) has eleven nouns, each with one system of record. Where do they live, and how
does every view stay consistent?

## Decision outcome

1. **A fresh ledger, `~/.warden/ledger.db`**, with the model's schema: one table per noun
   (conditions, incidents, tasks, task_deps, changes, deployments, verifications, decisions,
   agents, artifacts) plus the project runtime record and the **plumbing** tables `events`,
   `operations`, `timers`, `leases`, `deliveries` — named infrastructure, exempt from the noun
   count. `PRAGMA synchronous=FULL` (the spike ran FULL, the old ledger NORMAL; under WAL, NORMAL
   can drop the last commits on power loss — `spikes/02-durable/REPORT.md`). The old `warden.db`
   stops with the old loop and is archived read-only; history enters the new ledger by **one
   import** (signals, closed incidents with recipes, decisions, tasks), never by dual-writes.
   *Amended 2026-10-22 (owner: rewrite, not co-run) — "evolved in place" no longer binds.*
   - **The import is a pure function** of the archived snapshot into a new file, swapped in by
     rename; ids are deterministic (`inc_` + hash of the old id, likewise per noun), so a re-run
     yields the same rows.
   - **Adoption pass.** Before the first effect, every non-terminal old item has its external state
     probed — open PRs, in-flight deploys, in-doubt operations — and the new entity is set from what
     the probe finds (a Change adopting the open PR, a Deployment at the observed version, a
     resolved operation), so the spawner duplicates nothing.
   - **Restore is an adopt mode.** After restoring the off-box copy or failing an integrity check,
     the ledger refuses effects until the adoption pass has probed every in-doubt operation.
2. **One append-only `events` table** (schema in `design/model.md` §4) written by one `emit()`
   inside the transaction that changes the entity (transactional outbox). Signals are
   `signal.received` events. Every event carries `trace_id` (derived from the root incident or
   task id), `causation` and `correlation`; an event a manifest influenced carries `manifest_sha`
   (the default-branch blob the reconciler or correlator read — reconcilers never read a working
   tree), so a rebuild evaluates old events against the manifest that was in force.
3. **One writer per entity table.** Write functions for a noun live in one module; a CI check
   rejects writes from anywhere else. Deployment has one writer, the deploy reconciler: it consumes
   deployed/failed Signals from every source (the `make deploy` wrapper, RollHook, CI) and turns
   them into Deployment transitions keyed change + target. Readers (Argo's factory API, Hermes,
   KPI scripts) open the ledger read-only or use warden's API; nothing outside warden opens it for
   writing.
4. **Projections** consume `events` by cursor, in two kinds:
   - **pure read models** (Argo read models, the digest, Beads-style exports) can be rebuilt from zero;
   - **effectors** (push, Argo thread, vault write such as the brain project note, Slack) record
     `deliveries(event_id, channel)` before sending, so rebuilding a projection or replaying
     imported events never re-sends.
5. **One process, capped inventory.** Every loop (reconcilers, correlator, planner, spawner,
   Witness, merge train, deploy reconciler, projectors) runs as a phase of one warden process, not
   as a service of its own; `factory` and `rv` fold into the one factory CLI (`warden manifest …`,
   `warden artifact …`). The concept-budget check covers a generated inventory with caps:
   processes per host, CLIs, stores.
6. **Retention:** events forever (1.7k in six months; a hundredfold is still small); nightly
   off-box copy.

### Consequences

- Good: statecharts become explicit; every owner page is an event, so `owner_pages` is a query; Argo needs no snapshots; no legacy column survives into the new schema.
- Bad: an import to write and reconcile once; the ledger becomes the single most important file on the mini (backup, integrity check in the heartbeat).

### Confirmation

CI: the one-writer check; a projection-rebuild test (drop a read model, rebuild from events,
compare; effectors rebuilt alongside send 0 messages); the inventory caps check;
`PRAGMA integrity_check` in the heartbeat; an import reconciliation that accounts for every
archived event, item and transition, and an identical second run from the same snapshot; a
restore test — yesterday's copy wired to a world that already ran the effects re-executes 0 of
them; KPI scripts in `evidence/` reproduce the baseline from the imported events.
