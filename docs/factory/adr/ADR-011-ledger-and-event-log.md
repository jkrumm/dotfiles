# ADR-011 — One ledger, one event log, one writer per entity

- Status: accepted · 2026-10-22
- Evidence: `findings-2026-10-22.md` (65-column `triage_items`, 44 transition pairs, `working → working` 768), `evidence/kpi/baseline.out.md` §data quality (`fixed_by_pr`, `revert_pr`, `reverting_sha` never populated; signatures unique per row), `evidence/incidents/incidents.md` (577 owner-facing notifications, only 140 visible to the KPI), `evidence/signals/signals.md` (`slack_update` never ingested), Round 5 *Established facts* (Hermes reads `warden.db` directly), `design/model.md`

## Context and problem statement

Warden's lifecycle is implicit: sub-stages live in columns, so its own state machine cannot be
read, KPIs miss most owner pages, and other services read its database directly. The model
(`design/model.md`) has twelve nouns, each with one system of record. Where do they live, and how
does every view stay consistent?

## Decision outcome

1. **The ledger is `warden.db`**, evolved in place (strangler): new entity tables beside the old
   ones — conditions, incidents, tasks, task_deps, attempts, changes, deployments, verifications,
   decisions, agents, artifacts, operations, timers, leases — so dual-writes during migration are
   one transaction.
2. **One append-only `events` table** (schema in `design/model.md` §4) written by one `emit()`
   inside the transaction that changes the entity (transactional outbox). Signals are
   `signal.received` events. Every event carries `trace_id` (derived from the root incident or
   task id), `causation` and `correlation`.
3. **One writer per entity table.** Write functions for a noun live in one module; a CI check
   rejects writes from anywhere else. Readers (Argo's factory API, Hermes, KPI scripts) open the
   ledger read-only or use warden's API; nothing outside warden opens it for writing.
4. **Projections** (Argo read models, briefings, the brain project note, Beads-style exports,
   notifications) consume `events` by cursor and can be rebuilt from zero.
5. **Retention:** events forever (1.7k in six months; a hundredfold is still small); nightly
   off-box copy.

### Consequences

- Good: statecharts become explicit; every owner page is an event, so `owner_pages` is a query; Argo needs no snapshots.
- Bad: a migration with dual-writes until each old column is retired; the ledger becomes the single most important file on the mini (backup, integrity check in the heartbeat).

### Confirmation

CI: the one-writer check; a projection-rebuild test (drop a read model, rebuild from events,
compare); `PRAGMA integrity_check` in the heartbeat; KPI scripts in `evidence/` read only the
ledger and its snapshots.
