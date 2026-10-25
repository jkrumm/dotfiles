# 6. State and durable execution

## Postgres on the mini

One database, `factory`, on the Postgres 18 that already runs on the mini. Argo moves into the same
server as database `argo` at W5, with its own role and connection limit. Postgres because Argo reads it
directly (views, `LISTEN/NOTIFY` for live updates, no sync job), because JSONB, full-text search and
`SKIP LOCKED` come built in, and because you have hit SQLite locking before.

## Durable execution: your one open decision

**My recommendation: no DBOS. Each Issue is a state machine in Postgres, driven by an inbox.** The
reason is Cortex's engrams, an open-source software factory that runs Claude Code on DBOS on Bun.
Its blog argues for durable workflows; its code and ADRs argue the other way for exactly our case
(`research/2026-10-25-engrams-source.md`):

| Cortex's blog | engrams' code and ADRs |
|-|-|
| "A software factory is just a durable workflow" | ADR 0119: "an entity lifecycle that spans days … must NOT be one long-lived run … The automation is stateful; no run is." |
| DBOS runs the factory | three workflows, using DBOS only for step checkpoints, `send`/`recv` and idempotent workflow ids; cron (croner + a Postgres lease), concurrency claims, retries and recovery are their own code |
| "every run resumes where it was" | DBOS ties recovery to an application version hashed from workflow source, and deploys stranded production runs (253 unread messages, 15 orphaned runs). The fix is a ≈ 2,000-line sweeper (ADR 0104); pinning the version was rejected because it forces patch bookkeeping |

An Issue lives for hours or days, so engrams' own rule applies: the Issue is stateful, and no run
is. What DBOS would add on top is checkpointing for steps that last seconds, which a deterministic
id does as well, and the price is version gating on every deploy. On one Mac mini there is no
multi-pod recovery to buy. v2.1's instinct (short runs, state in tables) was right; engrams arrived
at the same place the hard way.

## The Issue machine

- **One writer.** `issues.state` changes in one module, a transition table over the states in §4.
- **One inbox.** Everything that concerns an Issue is a row in `issue_inbox` with a mandatory,
  unique idempotency key:

| Event | Sent by | Key |
|-|-|-|
| `signal` | dedup: a repeat or regression | the source's own event id |
| `admitted` | the admission tick | `admit:<issue>:<attempt>` |
| `phase`, `ship`, `close`, `block`, `ask`, `drop` | the lead, via `factory issue` | `<issue>:<verb>:<call id>` |
| `turn_ended`, `session_ended` | the lead's Stop and SessionEnd hooks | session id + turn number |
| `pane_dead`, `walled` | Witness | pane id + observation time |
| `hold_over` | a timer row | `hold:<issue>:<attempt>` |
| `steer`, `pause`, `stop`, `answer` | you or the steward | the intent's id |

- **One Issue at a time.** A worker takes an Issue's oldest unhandled rows under a row lock
  (`FOR UPDATE SKIP LOCKED`), so two events for one Issue never race. `LISTEN/NOTIFY` wakes it at
  once, and a tick every few seconds catches the rest.
- **Effects are attach-or-start by deterministic id.** The lead's herdr name is
  `lead-<issue>-<attempt>`, and spawning again attaches to that pane. A prompt id
  (`issue:<id>:<phase>:<n>`) is recorded before anything is typed into a pane. A GitHub comment
  carries a marker, a card a key. A replayed tick never spawns, prompts or posts twice.
- **Claims** (engrams' concurrency table): `repo:<name>` holds one lead per repo, plus a second claim
  for one urgent Issue (§5). Policies: *join*
  (the same symptom becomes a note to the running lead), *queue* (waits for the holder to finish),
  *supersede* (a newer request replaces one not yet started).
- **Finalize once,** from every exit path: terminal state, release the claim, promote the next
  queued Issue.
- **Schedules:** croner plus a Postgres lease; `job_runs` is unique per (job, slot), and a missed slot
  runs once after downtime.
- **Tests, from engrams without its engine:** a golden test pins each path's sequence of transitions
  and effects; a replay test crashes after every effect and replays, and must end with zero
  duplicates.

**What would change my mind:** the lifecycle module passing ≈ 500 lines, or the replay test finding a
race the per-Issue lock cannot close. Then DBOS in engrams' short-run form, sweeper included. The
runtime decides nothing either way: Cortex runs DBOS on Bun 1.4.3, and the factory stays on Bun.

## Facts, not status

| Table | Holds |
|-|-|
| `projects` | the synced `project.yaml`, plus pause state |
| `signals` | one observation each: source, source time, subject, fingerprint, payload |
| `issues` + `issue_deps` | kind, class, title, the lead's root cause and fix, summary, `wake_at`; an initiative's waves are child Issues |
| `issue_links` | Signal → Issue, Issue → Issue (merged, split, related, regression of), who, why: the grouping labels |
| `sessions` | herdr pane, role, account in effect, model, effort, Issue, Witness observations |
| `issue_inbox` | every event for an Issue, with its idempotency key and when it was handled |
| `claims` | key, holder, policy, queued Issues |
| `events` | phases, notes, steward actions, state changes: the history Argo shows |
| `evidence` | per Issue: kind, link or payload, at, from whom |
| `decisions` | question, options, default, expiry, answer, who, when |
| `job_runs` | job, slot, result, tokens spent (the scorecard reads it) |
| `artifacts` + `comments` | plan or report as path@sha, comment threads |

"Working", "stuck", "waiting" are derived from these facts when read, never stored.

## Telemetry and money

- **Traces (from W5):** the factory and agent-gateway export OpenTelemetry to the VPS ClickStack over
  the tailnet, one trace per Issue.
- **Usage:** usage-tracker stays the record of tokens and cost. A session's id links its usage to its
  Issue, so Argo shows cost per Issue, per project and per model tier.

## Backups and retention

A nightly `pg_dump` to the homelab bucket and a weekly restore drill, from W1. Facts stay; lead
transcripts are archived to the homelab and the local copies kept. Warden's database is deleted at W1;
the golden set already holds what was worth learning from it.
