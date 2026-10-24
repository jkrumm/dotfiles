# 6. State

## Postgres on the mini

One database, `factory`, on the Postgres 18 that already runs on the mini (Homebrew, always on).
Argo moves into the same server as database `argo` at W5, with its own role, a connection limit and a
statement timeout, so a slow dashboard query cannot starve the loop.

Postgres over SQLite because Argo reads it directly (views, and `LISTEN/NOTIFY` for live updates — no
sync job), because `FOR UPDATE SKIP LOCKED`, JSONB and full-text search cover the ready queue, raw
payloads and "seen this before" without extra machinery, and because you have hit SQLite locking
before.

## A reconcile loop, and why not DBOS

You suspected v1 used DBOS wrong. It did: the spike ran DBOS on SQLite with its default application
version — a hash of the workflow source — so a one-line redeploy stranded every queued flow; pinned,
it passed. Configured right, on Postgres, DBOS works.

v2 still does not adopt it, for a reason the spike did not test. The factory is a control plane: every
step must re-read the world before acting (does the PR exist, is the container up, is the session
alive). A reconcile loop does that natively. DBOS replays recorded step results instead, and the
design review found five ways that bites here — a parallel fan-out whose replay order is not stable,
any second process that launches DBOS stealing the daemon's in-flight work, recovery counters that
dead-letter long-waiting work after enough self-deploys, message waits that consume stale messages,
and the factory deploying itself through a workflow that its own deploy restarts. Each has a fix; a
reconcile loop has none of them. It also keeps the factory on Bun — DBOS's TypeScript SDK supports
Node only.

What the loop needs, Postgres provides: `wake_at` for timers, a `SKIP LOCKED` ready queue, facts plus
`NOTIFY` for waits, an advisory lock for the single process, and `(entity, generation, step)` keys for
effects. v1's spike measured this design — its option A, on SQLite — at 75 of 75 runs, crashes included.

**W1 proves it on Postgres** before anything depends on it: a kill mid-effect, a redeploy mid-settle,
a second process starting, a restore into adopt mode. W2 extends the suite to its own effects: a kill
mid-merge, two Tasks of one Issue with the factory killed between them, a late decision. Zero
duplicate effects, zero lost Tasks.

## Facts, not status

| Table | Holds |
|-|-|
| `projects` | the synced `project.yaml`, plus pause state |
| `signals` | one observation each: source, source time, subject, fingerprint, payload |
| `issues` | kind, title, generation, root cause, fix recipe, `wake_at` |
| `issue_links` | signal → Issue, Issue → Issue (merged, split, regression of), who, why — the grouping labels |
| `tasks` + `task_deps` | done-definition, class, project, plan, branch, generation, `wake_at` |
| `sessions` | herdr pane, epoch, account in effect, role, Task, Witness observations |
| `effects` | every action with its key, started / observed / failed |
| `checks` | (head SHA, base SHA), kind, result, evidence link |
| `deploys` | project, target, artifact, change, held / bad |
| `decisions` | question, options, default, expiry, answer, who, when |
| `artifacts` + `comments` | plan or report as path@sha, comment threads |

State is derived on every tick (§4); no table stores "working" or "stuck".

## Telemetry and money

- **Traces (from W5):** the factory, agent-gateway and headless Claude Code sessions export
  OpenTelemetry to the VPS ClickStack over the tailnet, one trace per Issue: `trace_id` sits on Issues, Tasks and sessions.
- **Usage:** usage-tracker stays the record of tokens and cost. A session's id links its usage rows to
  its Task and Issue, so Argo shows cost per Issue and per project without a second copy.

## Backups and restore

From W1, not later: a nightly `pg_dump` to the homelab bucket and a weekly restore drill, both part of
the infra job's first slice. A restored database is behind the world, so the factory starts in **adopt mode**: no
effects until every open Issue and Task has re-read the world once.

## Retention

Facts stay. Agent transcripts and dead sessions are archived to the homelab and the local copies are
kept; nothing is deleted. Warden's database is deleted at W1, as you
said; the golden set already holds what was worth learning from it.
