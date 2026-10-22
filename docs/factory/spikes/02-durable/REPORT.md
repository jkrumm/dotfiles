# Spike 2: durable execution for warden flows

Input to ADR-002. Status: proposed. Date: 2026-10-22. Work took about 1 h 15 of the 2 h box. Code is in `common/`, `option_a_ledger/`, `option_b_dbos/`, `harness/`; raw per-run evidence and the aggregate are in `results/full/`.

## Context and problem statement

Warden's flows (alert, investigate, fix, verify) must survive three things that happen to this host:
- an OpenCode server restart, which kills attached episodes;
- a herdr crash, which restores panes (Claude Code panes resume by session id; shells die);
- a Mac mini reboot after a power event.

The long steps are LLM episodes of minutes to hours. They run outside the loop, as an agent-gateway job or a herdr pane, and are observed by polling. The loop itself is a level-triggered reconciler.

The ledger already carries part of the answer:
- `operations` rows are written before the external call, and an unresolved row is reconciled first on every pass (`~/SourceRoot/warden/scripts/ledger.py:285`, `scripts/loop/work.py:1438`).
- Stages are compare-and-set hops with a claim expiry in `retry_at` (`scripts/loop/train.py:40`).
- `state_deadline` names when a state stops being allowed to sit (`ledger.py:196`).

Question: what gives warden's flows durable execution?
- **A:** the SQLite ledger with explicit statecharts plus hand-rolled timers, leases, heartbeats and idempotency keys. Stdlib only.
- **B:** DBOS Transact Python 3.3.0 with SQLite as its system database.

## Decision drivers

1. Loop, episode or whole-machine `kill -9` loses no flow and creates no duplicate side effect.
2. Owner rule: no turn limit or wall-clock cap on agent work, only an idle watchdog; a redeploy never discards an episode.
3. Fits level-triggered reconcilers and one system of record per entity.
4. Smallest footprint on one Mac mini: no new service, no second source of truth.
5. A read-only script can derive every flow's state for Argo without the loop running.
6. Maturity of what we depend on.

## Considered options

| Option | Durability model | Persisted in | New dependency |
|-|-|-|-|
| A. Ledger + statecharts | state rows, CAS transitions, intent-before-call operations, deterministic idempotency keys | `warden.db` (existing) | none |
| B. DBOS 3.3.0 on SQLite | replay of a workflow function over checkpointed step outputs | its own system DB | `dbos` + 11 packages |

Not run, reasons from `research/2026-10-22-durable-await-sqlite.md`:
- Temporal: needs a server, and SQLite is dev/test only.
- Restate: BUSL server, non-SQLite store.
- Absurd, pgflow: Postgres only.
- Mastra: unverified.
- XState: no persistence or scheduler.

Every one of them re-executes the in-flight step after a crash, and none has a first-class default on timeout.

## Spike design

One flow, built twice:

    alert -> investigate (episode) -> await decision (180 s, default approve) -> implement (episode)
          -> [per-repo merge slot: open_pr -> deploy (503 twice, durable backoff) -> verify] -> fixed

A reject ends in `rejected` with no PR and no deploy. The default on expiry is `approve`, because the PR it opens is revertible and verify decides whether it sticks.

Shared fixtures are identical under both options:
- **Stub API** (HTTP over SQLite): it records every call and honours an `Idempotency-Key`. It can hold a response after the side effect committed, which is the in-doubt window. It answers 503 to the first two deploy calls per flow. It survives every kill, as GitHub would.
- **Episode** (detached subprocess): 12 units of 5–10 s, a heartbeat every second, a session checkpoint per unit, an atomic result file. A kill loses the in-flight unit; the re-driven attempt resumes after the last finished unit.
- **Observer**: liveness is heartbeat staleness only (the idle watchdog), with no deadline on the work. A launch marker per attempt makes "start attempt N" idempotent.

**Option A** (164 code lines):
- One `flows` row per flow, a handler per state, a 1 s tick.
- Transitions are `UPDATE .. WHERE id=? AND rev=?`.
- The `operations` row is written before the call; the call carries `flow:kind` as its key; the outcome and transition commit together.
- Timer is `retry_at`.
- Decision is an absolute `state_deadline` plus a `decisions` row; a human answer counts only if `decided_at <= deadline`.
- Lease is a `slots` row with TTL, renewed each tick.

**Option B** (150 code lines):
- Workflow `flow` plus a child `merge_section` on a queue with `partition_concurrency=1` keyed by repo.
- One step per effect, and one long observer step per episode (re-running it after a crash only re-attaches).
- Backoff is `DBOS.sleep`; the decision is `DBOS.recv(timeout)` plus an `if None` branch.
- Intake and decisions go through `DBOSClient` from another process.
- The system DB is pre-created in WAL mode, because DBOS does not set it.
- `application_version` is DBOS's default (a hash of the workflow source) unless a test says otherwise.

Scaled values: idle limit 15 s (production 300 s), tick 1 s, backoff 5 s then 10 s with a 30 s cap, lease TTL 30 s, verify window 60 s, outage after a kill 3–8 s. Run *i* uses the same seeded workload for A and B. Each test ran at least 5 times per option. The harness has a 25 min safety net per run; flows have none.

## Results

### Kill tests

Pass means: final state correct, 0 duplicate and 0 missing side effects, decision source correct, episode resumed rather than restarted. Recovery is the time from loop spawn to the first live action of the flow.

| Test | Opt | Runs | Pass | Dup | Recovery med / max (s) | Measured |
|-|-|-|-|-|-|-|
| a | A | 5 | 5/5 | 0 | 0.08 / 0.13 | implement episode kept running and re-attached 5/5; 0 extra launches |
| a | B | 5 | 5/5 | 0 | 1.55 / 1.63 | same |
| b | A | 5 | 5/5 | 0 | 0.10 / 0.15 | in-doubt window hit in 5/5 (A's read-only snapshot while the loop was dead showed `ops_in_doubt=1`); key replayed 5 calls |
| b | B | 5 | 5/5 | 0 | 1.87 / 1.92 | key replayed 5 calls |
| b_deploy | A / B | 5 / 5 | 5/5 each | 0 | 0.07 / 1.63 | same on the deploy call, 5 replays each |
| b_nokey (control) | A / B | 5 / 5 | - | 5 / 5 | - | a second PR was created in 5/5 runs of each option |
| c1 (decide while down, restart before expiry) | A / B | 5 / 5 | 5/5 each | 0 | 0.17 / 2.66 | human reject honoured 5/5 |
| c2 (no decision, restart before expiry) | A / B | 5 / 5 | 5/5 each | 0 | 0.17 / 2.85 | default taken at the original deadline: +0.59 s (max 1.14) A, +0.18 s (0.21) B |
| c3 (down across expiry) | A / B | 5 / 5 | 5/5 each | 0 | 0.07 / 1.68 | default taken 0.07 s (A) and 1.7 s (B) after restart |
| c4 (decided before expiry, down across it) | A / B | 5 / 5 | 5/5 each | 0 | 0.07 / 1.70 | human reject honoured 5/5 |
| c5 (answer after expiry, still down) | A | 5 | 5/5 | 0 | 0.17 | late answer ignored, default taken |
| c5 | B | 5 | 0/5 | 0 (10 missing) | 1.74 | late reject consumed at wake; flow `rejected`, no PR or deploy |
| c5s (c5 with a timestamp rule) | B | 5 | 5/5 | 0 | 1.83 | default taken, like A |
| d | A / B | 5 / 5 | 5/5 each | 0 | - | re-drive detected 14.0–15.4 s (A), 14.2–14.7 s (B) after the kill; in-flight unit wasted 2.8–6.7 s; no finished unit redone 5/5 |
| e | A / B | 5 / 5 | 5/5 each | 0 | 0.08 / 1.53 | phases investigate, decision, implement, deploy backoff, verify all ok; episode re-drive 14.1–15.1 s after kill |
| f | A / B | 5 / 5 | 5/5 each | 0 | 0.06 / 1.54 | 0 slot overlaps; 0 early timer calls; timer lateness 0.12–0.87 s (A, tick-quantised), 0.03–0.18 s (B) |
| h chaos | A / B | 10 / 10 | 10/10 each | 0 | 0.07 / 1.56 | 29 kills each (13 whole-machine, 16 loop-only); 12 episode re-drives each; max recovery 0.19 / 2.43 s |
| g | A | 5 | 5/5 | 0 | 0.07 | code change applies at the next tick |
| g | B | 5 | 0/5 | 0 | 2.33 | flows stranded, see failure modes |
| g_pinned | B | 5 | 5/5 | 0 | 1.46 | recovered with `application_version` pinned |
| g_break | B | 5 | 0/5 | 0 (10 missing) | - | engine status `ERROR` |

Totals excluding controls: A 75 runs, 75 passed, 0 duplicates, 0 missing. B 90 runs, 75 passed; the 15 failures are exactly the predicted c5, g and g_break rows, with 0 duplicates. About 90 (A) and 110 (B) loop kill/restart cycles plus 5 episode-only kills each.

Happy-path nominal wall time: A 154–226 s, B 151–222 s. A is 3.7 s slower on average (3.0–4.1 s), because it takes one tick per hop.

### Idempotency proof

The stub, not the flow, counted calls.
- Windows hit: 10 per option (b and b_deploy).
- In every window the call had committed at the stub and the caller had not recorded it. A's snapshot taken while the loop was dead showed the operation in doubt in 10/10.
- With a deterministic key, the retry was replayed 10 times per option and 0 duplicates were created.
- Without the key, the same kill produced a duplicate PR in 5/5 runs of each option.

So the zero is the key's doing. Neither engine provides idempotency for external calls; DBOS re-executed the in-flight step in 10/10, exactly as documented.

### Long agent steps

No engine feature helps here. The observer, heartbeat file, idle watchdog and re-drive by session are the same code under both options. DBOS wraps them in one long observer step; re-executing it after a crash just re-attaches. Nothing in either option has a deadline on agent work. Detection took about 15 s, the idle limit, counted from the last heartbeat. At most one unit (under 7 s here) was lost.

## Side by side

| Need | A: ledger | B: DBOS 3.3.0 |
|-|-|-|
| Flow state | row in `flows` (`state`, `rev`) | recorded prefix of `operation_outputs` |
| Idempotent effect | intent row, call with deterministic key, outcome + transition in one transaction | deterministic key in the step; the step may run again |
| Durable timer | `retry_at` | `DBOS.sleep`, absolute wake time (`_sys_db.py:3698`) |
| Await decision | `state_deadline` written at the transition | `recv` timeout recorded as an absolute wake time (`_sys_db.py:3288`), so a restart does not extend it |
| Default on timeout | own branch | own branch (`recv` returns `None`) |
| Late answer | ignored by rule | consumed if unconsumed at wake (observed) |
| Merge-slot lease | `slots` row with TTL, renewed per tick | partitioned queue, concurrency 1 per key, no TTL exercised |
| Concurrency | one thread, one tick | a thread per workflow |
| Code change in flight | next tick; a renamed state needs an `UPDATE` | source-hash version; a changed source strands the flow; a reordered step errors |
| Crash loops | no counter | dead-letter after `max_recovery_attempts` (default 100) |

## Footprint

| | A | B |
|-|-|-|
| Flow module / status script / total code lines | 164 / 25 / **189** | 150 / 31 / **181** |
| Shared fixtures / harness (identical) | 209 / 820 | 209 / 820 |
| Dependencies added | 0 | `dbos` + click, croniter, greenlet, psycopg, psycopg-binary, python-dateutil, pyyaml, six, sqlalchemy, typing-extensions, tzdata |
| Installed size / import | stdlib / 0.04 s | 35–45 MB (sqlalchemy 17.1, unused psycopg-binary 16.8) / 0.54 s |
| Files | existing `warden.db` | a second SQLite file, created in `journal_mode=delete` unless pre-created |
| Schema | one more entry in warden's migration map; +5 tables | 12 tables, 35 indexes, `workflow_status` 39 columns; 123 migration slots owned by the library |
| Rows per flow / DB bytes incl. WAL | 12 / 276 KB | 53–57 / 0.84–1.05 MB |
| Loop RSS / threads (median at first kill) | 15.8 MB / 1–3 | 37.2 MB / 10–13 |
| Average CPU over loop lifetime (`ps`, n=10 each, sampled mid-run) | 0.15% | 1.3% |
| Operator tooling | `sqlite3`, status script | `dbos` CLI; `reset` deletes the DB file, so the engine DB cannot share a file with the ledger |

Line counts are a wash.
- A's 164 lines are about 67 of schema and machinery (schema, connect, CAS `move`, backoff, lease, operation protocol) plus about 49 of handlers. The machinery is written once and shared; warden's ledger already has parts of it.
- B's 150 lines are about 113 of steps and workflows. 23 of them are step wrappers that exist only to log, audit or finish, because nondeterminism is not allowed in a workflow body.
- Marginal cost per extra flow: about 50 lines in A, about 110 in B.

## Observability

Both status scripts are read-only, ran in 40–250 ms against a dead loop, and produced a snapshot in 70/70 (A) and 85/85 (B) runs.

**A** is one query: state, deadline, timer, lease, in-doubt operations, transition count. In-doubt operations are visible, which lets a reconciler query the world before retrying an API with no key.

**B** is SQL only, with no `dbos` import and no pickle. Findings:
- Readable: workflow status, version, recovery attempts, the business state when the workflow publishes it with `set_event(serialization_type=PORTABLE)`, step names, and durable timers (absolute epochs).
- Opaque: step outputs and results are `py_pickle`, so a TypeScript Argo cannot read the PR number or deploy id.
- Invisible: an in-flight step. At kill time the DB showed no trace of the in-doubt `POST /pr`.
- Fragile: my first `status_b.py` missed the decision deadline while a flow waits in `recv` (DBOS writes the `recv` row only when the wait ends; only the timeout `DBOS.sleep` row exists). It also missed timers inside the child workflow (found by the id convention `<flow>:merge`). I fixed both after the runs and verified on fast-mode runs. The stored B snapshots in `results/full` are from the first version, and `results.json` meta says so.

## Fit with a level-triggered reconcile design

- **A is the reconcile loop.** A tick is a reconcile, a handler is observe, decide, CAS. No handler contains a resume branch; recovery is the next tick (0.06–0.5 s here). The ledger holds only what cannot be re-observed: owner intent (decision, deadline), idempotency intent, the lease, timers and counters, the transition log. Episode status, health and "did the PR open" are re-observed.
- **B is event-sourced replay.** Recovery re-runs the function and trusts the recorded prefix; a recorded `open_pr` result is never re-checked against the world. Level-triggering exists only in the observer steps I wrote, which is why external long steps worked.
- **A reconciler would sit above DBOS.** It would start flows idempotently by workflow id and cancel them. The flow's position then becomes a second state machine next to the item's ledger state, which collides with "one system of record per entity" unless item state moves into the DBOS file.
- **Desired-state change mid-flight** (the alert clears while the flow waits) is one guard at the top of a handler in A. In B the flow is parked in `recv`, a sleep or a step, and needs a message or a cancel from outside.
- **Timer resolution in A is the tick.** Today's warden pass is 10 minutes, and A advances one hop per tick, so durable flows need a resident short tick of 1–5 s, an event nudge, or chained hops (warden's train already allows 6 per pass).

## Failure modes observed

1. **B: a late answer wins (c5, 5/5).** `recv` returns whatever is unconsumed at wake, so the outcome of a late owner decision depends on whether the engine was alive at the deadline. A one-line rule (message carries its timestamp, compare to the deadline) fixes it (c5s 5/5).
2. **B: redeploy strands flows (g, 0/5).**
   - The default version is a hash of the workflow source, and the new process registers it as latest. The engine logs only "Current version … is not the latest version".
   - Relaunching the old code alone did not free them within 60 s: the queued child has an unset version and is dequeued only by the latest registered version (`_dbos.py:1382`).
   - `set_latest_application_version` freed them; they finished about 23 s later with 1 PR and 1 deploy.
   - Pinning `application_version` makes compatible edits survive (g_pinned 5/5).
   - An incompatible edit (a new step ahead of recorded ones) ends `ERROR` with `DBOSUnexpectedStepError ... Check that your workflow is deterministic` (g_break 0/5).
   - This conflicts with "a redeploy never discards an episode". A has no replay, so a code change applies at the next tick.
3. **B: crash loops dead-letter flows.**
   - Each recovery counts against `max_recovery_attempts` (default 100, `_registrations.py:10`, check at `_core.py:1243`).
   - Drill with the limit lowered to 3: after 6 kills the flow was `MAX_RECOVERY_ATTEMPTS_EXCEEDED`; `resume_workflow` finished it with 1 PR and 1 deploy.
   - At launchd's default 10 s respawn throttle, 100 recoveries is about 17 minutes of crash-looping (arithmetic, not measured).
   - A completed the same drill with no operator action.
4. **B: in-flight step invisible** (see Observability).
5. **B: SQLite caveats.**
   - A fresh DBOS SQLite DB is `journal_mode=delete` (verified; no WAL pragma at `_sys_db_sqlite.py:45`). The spike pre-created WAL, as DBOS's own test fixture does.
   - The runtime logs "The SQLite system database is for development and testing" (`_sys_db.py:699`). This confirms an item the research had marked unverified.
   - DBOS 3.3.0 no longer allows `Queue(...)`; queues are registered in the DB with `DBOS.register_queue`. Older docs and examples are stale.
6. **B: slower and heavier.** Recovery 1.4–2.6 s against 0.06–0.5 s, about 9x the idle CPU. Neither matters at warden's timescales.
7. **A: one hop per tick** (3.7 s slower end to end) and **one sequential tick**: a slow external call delays all flows by up to its HTTP timeout.
8. **Both:** an episode kill wastes the in-flight unit (2.8–6.7 s). B's `verify` step restarts its window after a crash; A keeps its green count and deadline.

## Decision outcome

**Chosen: A.** Extend the warden ledger with explicit flow statecharts and a small set of shared primitives:
- a CAS `move`;
- operations with deterministic idempotency keys `<flow>:<kind>`;
- `retry_at` timers;
- a decisions table with an absolute deadline and the `decided_at <= deadline` rule;
- a TTL lease table;
- a heartbeat idle watchdog and re-drive by session for external episodes.

No engine.

**Confidence: about 75%** for the next six months. About 95% that crash survival is not the differentiator, since both options passed every crash test.

| | A | B |
|-|-|-|
| For | zero dependencies; one system of record; native level-triggered; in-doubt operations visible; any SQL or TypeScript reader can derive state; fast recovery; no version hazard | linear, readable flow code; durable sleep, recv and queues built in; thread per workflow; fork, resume, cancel, rewind tooling |
| Against | hand-written machinery (shared and tested here); single-threaded tick; you own CAS and lease correctness; state renames need migrations; no replay tooling | second system of record and DB file; 12 packages; vendor labels SQLite dev/test; pickled outputs; version strand; dead-letter counter; late-answer semantics; in-flight step invisible |

**What would flip it to B:**
1. Six or more flow types, or flows with fan-out, child flows or compensation, where hand-written handlers pass about 150 lines or show bugs that replay would avoid.
2. Warden's state moves to Postgres, or flows must run on more than one host.
3. DBOS makes SQLite production-supported and ships a documented in-flight version migration plus portable step outputs.
4. Two or more duplicate or lost-work incidents in a quarter that come from the hand-rolled machinery.

**Consequences and build list:**
- Mandatory deterministic idempotency key on every side effect.
- A resident 1–5 s tick (or event nudge) next to the 10-minute pass.
- Chained hops per tick.
- An episode contract: heartbeat, idle limit, resume by persisted session id.
- A decision table with a per-action-class default.
- Status views for Argo.
- Keep this harness as a regression suite: a new flow ships only if it passes tests a through f and h.

## What was not tested

- Power loss and OS crash. `kill -9` cannot lose committed SQLite data. A used `synchronous=FULL`; warden's ledger uses `NORMAL`. Deterministic keys make a lost intent row cost only a re-send.
- Two loop processes at once (CAS plus lease in A, `owner_xid` in DBOS).
- Hours-long flows, DB growth, hundreds of flows.
- DBOS datasource transactions on SQLite and `fork_workflow(application_version=...)`.
- Temporal, Restate, Absurd, Mastra.
- The stub honours idempotency keys. GitHub does not for PRs, but it enforces one open PR per head branch, which is the same effect by a natural key.
- Bias: A was written by the spike author knowing which windows the tests aim at, and B from the installed source. The chaos test (h) exists to reduce that bias.

## Reproduce

    SCRATCH=~/.local/share/factory/spikes/02-durable
    uv venv --python 3.13 $SCRATCH/venv
    uv pip install --python $SCRATCH/venv/bin/python 'dbos==3.3.0'   # pinned in results/pip-freeze.txt
    SPIKE=~/SourceRoot/dotfiles/docs/factory/spikes/02-durable; PY=$SCRATCH/venv/bin/python
    $PY $SPIKE/harness/killtest.py batch --tests happy,a,b,c1,d,e,f,g --runs 1 --fast            # about 2 min
    $PY $SPIKE/harness/killtest.py batch --tests happy,a,b,b_nokey,b_deploy,c1,c2,c3,c4,c5,c5s,d,e,f,g,g_pinned,g_break --runs 5 --parallel 45   # about 20 min
    $PY $SPIKE/harness/killtest.py batch --tests h --runs 10 --parallel 20
    $PY $SPIKE/harness/killtest.py collect
    $PY $SPIKE/harness/report_tables.py full; $PY $SPIKE/harness/extra_stats.py; $PY $SPIKE/harness/crashloop.py
