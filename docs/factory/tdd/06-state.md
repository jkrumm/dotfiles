# 6. State and durable execution

## Postgres on the mini

One database, `factory`, on the Postgres 18 that already runs on the mini. Argo moves into the same
server as database `argo` at W5, with its own role and connection limit. Postgres because Argo reads it
directly (views, `LISTEN/NOTIFY` for live updates, no sync job), because JSONB, full-text search and
`SKIP LOCKED` come built in, and because you have hit SQLite locking before.

## DBOS, with short workflows

**Adopted.** DBOS Transact (TypeScript SDK, MIT, a library — no extra server) runs on Postgres and
gives the factory durable steps, queues with concurrency and priority, scheduled jobs and a recorded
history of every run, which Argo shows on *Factory*. Its TypeScript SDK runs on Node, not Bun, so the
factory service runs on Node 24. Your call was right twice: v1's spike used it wrong, and Node is no
reason to skip it.

**The one rule that makes it simple: workflows are short; waiting lives in tables.** Each workflow is
one stage — investigate an Issue, run a Task's checks and merge, deploy and verify — and finishes in
minutes. Anything that waits for hours or days (a grace window, a quota reset, a session building, a
decision) is a row with a `wake_at` time, and a scheduled workflow picks up whatever is due every
minute. The rule removes the concerns the design review raised about DBOS:

- **Deploys:** before the factory deploys itself, it drains — stops starting workflows and lets the
  running ones finish, which takes minutes. No workflow survives a code change, so no version patches.
- **Recovery:** a crash replays at most one short stage, and every step that touches the outside world
  first checks whether it already happened (the PR exists, the deploy is live).
- **One launcher:** only the service starts DBOS; the CLI, Argo and Hermes talk to its API.

W1 proves it before anything depends on it: kills mid-step, a deploy mid-flow, a restore from backup.
Zero duplicate effects. If DBOS fails that gate, the hand-written loop from v1's spike (75 of 75 runs)
is the fallback.

## Facts, not status

| Table | Holds |
|-|-|
| `projects` | the synced `project.yaml`, plus pause state |
| `signals` | one observation each: source, source time, subject, fingerprint, payload |
| `issues` | kind, title, root cause, fix recipe, `wake_at` |
| `issue_links` | signal → Issue, Issue → Issue (merged, split, regression of), who, why — the grouping labels |
| `tasks` + `task_deps` | done-definition, class, project, plan, branch, `wake_at` |
| `sessions` | herdr pane, account in effect, role, Task, Witness observations |
| `checks` | (head SHA, base SHA), kind, result, evidence link |
| `deploys` | project, target, artifact, change, held / bad |
| `decisions` | question, options, default, expiry, answer, who, when |
| `artifacts` + `comments` | plan or report as path@sha, comment threads |

"Working", "stuck", "ready to merge" are derived from these facts when read, never stored.

## Telemetry and money

- **Traces (from W5):** the factory, agent-gateway and headless sessions export OpenTelemetry to the
  VPS ClickStack over the tailnet, one trace per Issue.
- **Usage:** usage-tracker stays the record of tokens and cost; a session's id links its usage to its
  Task and Issue, so Argo shows cost per Issue and per project.

## Backups and retention

A nightly `pg_dump` to the homelab bucket and a weekly restore drill, from W1. Facts stay; agent
transcripts are archived to the homelab and the local copies kept. Warden's database is deleted at W1;
the golden set already holds what was worth learning from it.
