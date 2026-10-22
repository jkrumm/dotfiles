# ADR-002 — Durable execution: the ledger with explicit statecharts, no engine

- Status: accepted · 2026-10-22
- Evidence: `spikes/02-durable/REPORT.md` (175 scripted kill runs), `research/2026-10-22-durable-await-sqlite.md`, `research/2026-10-22-agents-durable-mcp-otel.md` §5

## Context and problem statement

Warden's flows (signal → investigate → fix → verify → deploy) must survive what happens to this
host: an OpenCode server restart kills attached episodes; herdr crashes and restores panes
(Claude Code resumes by session id, shells die); the mini reboots after power events. Long steps
are agent episodes of minutes to hours that run outside the loop process. The owner's rule
forbids turn limits and wall-clock caps on agent work; the only liveness rule is an idle
watchdog. What gives these flows durable execution?

## Decision drivers

1. No lost flow and no duplicate side effect on a `kill -9` of the loop, an episode or the machine.
2. No deadline on agent work; a redeploy never discards an episode.
3. Level-triggered reconcilers and one system of record per entity (ADR-011).
4. Nothing new to operate on one mini.
5. Any read-only script (Argo's factory API) can derive every flow's state.

## Considered options

- **A — the warden ledger with explicit statecharts** and a small set of shared primitives, stdlib only.
- **B — DBOS Transact Python 3.3.0 on SQLite**, the only surveyed library that supports SQLite as its system database.
- Not run: Temporal (server; SQLite dev-only), Restate (BUSL server, RocksDB store), Absurd and pgflow (Postgres only), Mastra (unverified), XState (no persistence or scheduler).

## Decision outcome

**Chosen: A.** Crash survival does not separate the options — both passed every kill test with 0
duplicates and 0 lost work over about 200 kills — so the tie-breakers decide: A keeps one system
of record, is level-triggered by construction, shows in-doubt operations to a read-only reader,
adds no dependency, and has no version-strand hazard.

Primitives, each written once in the ledger module and tested by the spike harness:
- compare-and-set transition `move(entity, from, to, rev)`;
- an `operations` row written before every external call, keyed `<flow>:<kind>` and sent as the idempotency key (or the natural key — one open PR per head branch);
- durable timers in `retry_at`; leases with a TTL renewed per tick;
- decisions with an absolute deadline, a per-action-class default, and the rule "an answer counts only if `decided_at ≤ deadline`";
- the episode contract: heartbeat, idle watchdog, re-drive by persisted session id from the hook (ADR-007).

### Consequences

- Good: zero dependencies; crash recovery is "run the reconcilers again" (0.06–0.5 s in the spike); any SQL reader sees every flow.
- Bad: we own CAS and lease correctness; the loop needs a resident 1–5 s tick or an event nudge beside today's 10-minute pass; state renames need migrations; no replay tooling.

### Confirmation

The spike's kill harness (tests a–f and h) becomes a regression suite: a new flow type ships only
when it passes it in CI. KPI: duplicate or lost side effects = 0 per quarter.

### What would flip it to B

Six or more flow types with fan-out or compensation past about 150 handler lines; the ledger
moving to Postgres or multiple hosts; DBOS making SQLite production-supported with in-flight
version migration; two duplicate or lost-work incidents in a quarter traced to the hand-rolled machinery.

## Pros and cons of the options

| | A — ledger | B — DBOS on SQLite |
|-|-|-|
| Kill tests a–f, h | all pass, recovery median 0.08 s | all pass, recovery median 1.55 s |
| Late owner answer after expiry, loop down | default taken (by rule) | late answer wins unless a timestamp rule is added (0/5 without) |
| Redeploy with changed code | applies at the next tick | flows strand on the source-hash version (0/5); pinning fixes compatible edits only |
| Crash loop | completes | dead-letters after `max_recovery_attempts` until resumed by hand |
| Footprint | 0 packages, +5 tables in `warden.db`, 16 MB RSS | 12 packages, second SQLite file (12 tables, pickled outputs), 37 MB RSS; vendor labels SQLite "development and testing" |
