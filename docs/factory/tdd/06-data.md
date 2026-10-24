# 6. Data and durable execution

## Postgres 18 on the mini

One database, `factory`, on the Postgres 18 that already runs on the mini (Homebrew, KeepAlive,
`127.0.0.1:5433`). Argo moves into the same server as database `argo` at W6.

Why Postgres over v1's SQLite, in order of weight:

1. **DBOS is production-grade on Postgres only.** Its SQLite system database logs "for development
   and testing" (spike 2, `_sys_db.py:699`), and spike 2's own reopen condition was "state moves to
   Postgres".
2. **Argo reads it directly.** Same box, same server; read models are views, live updates are
   `LISTEN/NOTIFY` → server-sent events. No snapshot push, no sync job.
3. **pgvector** for "have we seen this before" (§8), next to the facts it ranks.
4. **`FOR UPDATE SKIP LOCKED`, JSONB, partial indexes, full-text search** — the ready queue, raw
   payloads and the search box in Argo without extra machinery.
5. You have hit SQLite locking problems before; Postgres removes the class.

Backups: `pg_dump` nightly to the homelab bucket plus WAL archiving (restore drill in the gameday
catalogue, §12).

## DBOS for durable work

DBOS Transact (TypeScript SDK, MIT, a library — no daemon, no broker) keeps each workflow's progress
in a `dbos` schema next to the factory's tables. Steps run once; a crash or redeploy resumes at the
first unfinished step. What the factory uses:

| DBOS feature | Factory use |
|-|-|
| workflows + steps | one workflow per Issue, one child per Task, one per job run |
| durable `sleep` / `recv` with timeout | grace windows, waiting for a session's `done`, decision expiries, waiting for a quota reset |
| queues with concurrency, priority, partition key | `implement` (admission), `merge` (one per repo), `cognition` (rate limit on agent-gateway) |
| scheduled workflows | recurring jobs, with a name + time idempotency key |
| `send` / `setEvent` | Witness → task workflow; workflow progress → Argo |
| fork, rewind, resume, cancel | operator repair from Argo or the CLI |

**Why DBOS now, when it lost spike 2.** It lost on configuration, not design. The spike ran DBOS
Python 3.3 on SQLite with the default application version — a hash of the workflow source — so a
one-comment-line redeploy stranded every queued flow (0/5). With the version pinned it passed 5/5.
The TypeScript source (2026-10-22) confirms the intended path: a pinned `applicationVersion`, then
`DBOS.patch()` / `DBOS.deprecatePatch()` for an edit that changes a running workflow's steps, and
`rewindWorkflow` / `forkWorkflow` to re-target anything already stranded. Overall DBOS passed 75 of 90
runs against the ledger's 75 of 75; its 15 failures were the redeploy (pinning), an incompatible edit
(patching) and a late answer consumed by `recv` (fixed in the spike by a timestamp rule). On crashes
both were equal: 10/10 chaos runs each, 0 duplicates.

**What the factory does about the known hazards:**

- **Version:** `applicationVersion` is a constant in code, bumped only by a migration that drains
  (`listWorkflows({ applicationVersion, status: ["ENQUEUED", "PENDING"] })` reaches zero first).
  Compatible edits keep the version; incompatible ones use `DBOS.patch`.
- **Replay trusts recorded steps:** every effect step observes the world before acting (does the PR
  exist, is the deploy live), so a replay never double-acts and never trusts a stale result.
- **Dead-letter after 100 recoveries:** a crash loop surfaces as a `stuck` Issue about the factory
  itself, not a silent stop.
- **Node only:** the DBOS TypeScript SDK supports Node ≥ 20, not Bun (`node:async_hooks`). The factory
  runs on Node 24; bun stays the package manager.

**Acceptance gate (W1).** The spike 2 harness is ported to DBOS TS on Postgres: kill chaos, a
compatible redeploy, an incompatible edit under `DBOS.patch`, a late decision. All must pass before
anything else builds on it. If one fails and cannot be fixed in a day, the fallback is v1's own
design (ledger + statecharts + leases, `spikes/02-durable/option_a_ledger`) ported to Postgres —
measured, already written, and equal on crashes.

## Facts, not status

Tables hold facts; status is a view. That keeps Argo, the CLI and the agents from ever disagreeing.

| Table | Holds | Written by |
|-|-|-|
| `projects` | the synced `project.yaml` + runtime (paused, last seen) | project sync, `factory project pause` |
| `signals` | one observation each: source, source time, subject, fingerprint, payload | intake adapters, jobs |
| `issues` | kind, title, root cause, fix recipe, embedding | dedup (create), investigation (cause, recipe) |
| `issue_links` | signal ↔ issue, issue ↔ issue (merge, split, regression of), actor, reason | dedup, investigation, you |
| `tasks` + `task_deps` | done-definition, priority, project, plan reference, branch | planner, you, wave plans |
| `sessions` | herdr pane, account, role, task, started / exited | spawner, Witness |
| `changes` | repo, PR or SHA, head SHA | ship step, git adapter |
| `checks` | subject (head SHA or deploy), kind, result, evidence link | each verifier |
| `deploys` | project, target, artifact digest, change, good / bad | deploy wrapper, ship step |
| `decisions` | question, options, default, expiry, outcome, who decided | decide step, you |
| `artifacts` + `comments` | plan or report path@sha, threads | the authoring agent, you |
| `job_runs` | job, inputs hash, findings | job runner |
| `events` | every write above, append-only | a trigger on each table |

Derived, never stored: issue state (§4 diagram, from links, checks and workflow progress), session
state (working / idle / blocked / dead, from Witness facts and herdr), "ready to merge" (all required
checks pass on the current head SHA), capacity (from quota samples).

## Retention

Facts stay. Agent transcripts and dead sessions are archived to the homelab and the local copies
kept; deleting local copies after 90 days waits for your yes (v1 D5, you answered "ok").
