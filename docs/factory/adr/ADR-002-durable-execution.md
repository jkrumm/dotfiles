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
- Not run: Temporal (server; SQLite dev-only), Restate (BUSL server, RocksDB store), Absurd and pgflow (Postgres only), XState (no persistence or scheduler).
- Not run: **Mastra** (named by the owner) — TypeScript-only; its durability, suspend/resume and timeout semantics could not be verified (`research/2026-10-22-durable-await-sqlite.md` §1.9: every source blocked; `research/2026-10-22-agents-durable-mcp-otel.md`: registry metadata only), and it would add a TS runtime and a second system of record beside a Python loop, failing drivers 3 and 4 before any kill test.

## Decision outcome

**Chosen: A.** Crash survival does not separate the options — both passed every kill test with 0
duplicates and 0 lost work over about 200 kills — so the tie-breakers decide: A keeps one system
of record, is level-triggered by construction, shows in-doubt operations to a read-only reader,
adds no dependency, and has no version-strand hazard.

Primitives, each written once in the ledger module and tested by the spike harness:
- compare-and-set transition `move(entity, from, to, rev)`;
- the **effect registry**: every external side effect goes through one module that writes an `operations` row before the call and declares one strategy (table below); a CI check rejects external calls that bypass it;
- **generation keys** `<entity>:<kind>:<generation>`, the generation read from ledger state in the same transaction that writes the `operations` row — `dep:<change>:<target>:<sha>`, `restart:<condition>:<flap#>`, `revert:<change>:<n>` — so a legitimate repeat (a rollback's redeploy, a second restart after a flap) is a new key and the rate limit, not the key, stops the next one; this scheme is the only one;
- durable timers in `retry_at`; leases with a TTL renewed per tick, each grant issuing an **epoch** (below);
- decisions with an absolute deadline and a per-action-class default; `decided_at` is the server's receipt time; an answer after the deadline is an override intent with its own generation keys, never a decision; a deadline is extended by the factory API's measured downtime across it (ADR-014, ADR-015);
- the episode contract: heartbeat, idle watchdog, re-drive by persisted session id from the hook (ADR-007);
- mutating agent-CLI calls carry `--idempotency-key` (ADR-004); the server keeps `(verb, subject, key)` unique and answers a repeat with the original result.

| Effect registry strategy | Effects | In-doubt resolution |
|-|-|-|
| native key | targets that honour an idempotency key | resend the same generation key |
| natural key + lookup on conflict | PR by head branch `factory/<task>/<agent>`; merge with GitHub's expected-head `sha=`; revert branch `revert/<change>` | on a 422 or conflict, look up the existing object and adopt it |
| probe before retry | deploy (read the deployed version); restart (read the container's start time) | the probe decides done or not-done; never a blind retry |
| at-most-once with receipt | push notifications | a recorded receipt (`deliveries`, ADR-011) means sent |

**Epochs.** Every lease grant — task claim, Agent, merge slot — issues a monotonic epoch written
into the hook; every mutating call carries it and the CAS rejects a stale one. Git effects are
fenced by `push --force-with-lease=<ledger sha>` and merge `sha=`. A re-drive successor is granted
only after the predecessor's process is confirmed dead or its lease fenced, and a slot passes to
the next holder only after the previous holder's in-doubt operation is probed.

### Consequences

- Good: zero dependencies; crash recovery is "run the reconcilers again" (0.06–0.5 s in the spike); any SQL reader sees every flow.
- Bad: we own CAS and lease correctness; the loop needs a resident 1–5 s tick or an event nudge; every loop runs as a phase of that one warden process, never a second loop process (ADR-011); state renames need migrations; no replay tooling.

### Confirmation

The spike's kill harness (tests a–f and h) becomes a regression suite: a new flow type ships only
when it passes it in CI, with one case per effect-registry entry. The spike's 0 duplicates came
from a stub that honours the key (`spikes/02-durable/REPORT.md`), so W1's gate re-runs kill tests
b, b_deploy and h against real-shaped adapters — a scratch GitHub repo returning real 422s,
counting fakes for deploy and restart — pass = every target counts exactly one effect. Fencing
gameday (W1, W4): SIGSTOP an agent past its TTL, re-drive, SIGCONT → every stale call rejected,
0 commits land. KPI: duplicate or lost side effects = 0 per quarter.

### What would flip it to B

Six or more flow types with fan-out or compensation past about 150 handler lines; the ledger
moving to Postgres or multiple hosts; DBOS making SQLite production-supported with in-flight
version migration; two duplicate or lost-work incidents in a quarter traced to the hand-rolled machinery.

## Pros and cons of the options

| | A — ledger | B — DBOS on SQLite |
|-|-|-|
| Kill tests a–f, h | all pass, recovery median 0.08 s | all pass, recovery median 1.55 s |
| Late owner answer after expiry, loop down | default taken; the late answer becomes an override intent | late answer wins unless a timestamp rule is added (0/5 without) |
| Redeploy with changed code | applies at the next tick | flows strand on the source-hash version (0/5); pinning fixes compatible edits only |
| Crash loop | completes | dead-letters after `max_recovery_attempts` until resumed by hand |
| Footprint | 0 packages, +5 tables in `warden.db`, 16 MB RSS | 12 packages, second SQLite file (12 tables, pickled outputs), 37 MB RSS; vendor labels SQLite "development and testing" |
