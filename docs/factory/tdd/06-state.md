# 6. State and durable execution

## Postgres on the mini

One database, `factory`, on the Postgres 18 that already runs on the mini. Argo moves into the same
server as database `argo` at W5, with its own role and connection limit. Postgres because Argo reads it
directly (views, `LISTEN/NOTIFY` for live updates, no sync job), because JSONB, full-text search and
`SKIP LOCKED` come built in, and because you have hit SQLite locking before.

## Durable execution: no DBOS

**Decided (you left it to me on 25 October): no DBOS. Each Issue is a state machine in Postgres,
driven by an inbox.** The reason is Cortex's engrams, an open-source software factory that runs
Claude Code on DBOS on Bun. Its blog argues for durable workflows; its code and ADRs argue the other way for exactly our case
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
| `phase`, `wait`, `ship`, `close`, `block`, `ask`, `drop` | the lead, via `factory issue` | `<issue>:<verb>:<call id>` |
| `session_started`, `turn_ended`, `session_ended` | the lead's SessionStart, Stop and SessionEnd hooks, live or replayed from the spool | session id + turn number |
| `pane_dead`, `walled` | Witness | pane id + observation time |
| `hold_over`, `wake` | the tick, when `issues.wake_at` passes (the one timer) | `hold:<issue>:<attempt>`, `wake:<issue>:<at>` |
| `note`, `stop`, `answer`, `prio`, `dep`, `retier`, `park` | you or the orchestrator | the intent's id |

- **One Issue at a time.** A worker takes an Issue's oldest unhandled rows under a row lock
  (`FOR UPDATE SKIP LOCKED`), so two events for one Issue never race. `LISTEN/NOTIFY` wakes it at
  once, and a tick every few seconds catches the rest.
- **Effects are attach-or-start by deterministic id.** The lead's herdr name is
  `lead-<issue>-<attempt>`, and spawning again attaches to that pane. A prompt id
  (`issue:<id>:<phase>:<n>`) is recorded before anything is typed into a pane. A GitHub comment
  carries a marker, a card a key. A replayed tick never spawns, prompts or posts twice.
- **Claims** (engrams' concurrency table, without its policies): `repo:<name>` admits as many leads as
  the repo's `leads` allows (one by default), plus one urgent (§5); everything else queues in order.
  A repeat of the same symptom is a note to the running lead (§4), not a policy.
- **Finalize once,** from every exit path: terminal state, release the claim, remove the worktree,
  promote the next queued Issue.
- **Every start reconciles.** Before any effect, each open Issue looks at the world once (herdr, its
  worktree, GitHub, the sources), and the spool is replayed. There is no separate adopt mode.
- **Ids survive a restore.** After a restore the Issue sequence moves past every id seen in pane names
  and the spool, so a new Issue never attaches to a running lead's pane. A lead reporting an Issue the
  dump lost gets that Issue rebuilt from the spool, or parked.
- **Schedules:** croner plus a Postgres lease; `job_runs` is unique per (job, slot), and a missed slot
  runs once after downtime.
- **Tests, from engrams without its engine:** a golden test pins each path's sequence of transitions
  and effects; a replay test crashes after every effect and replays, and must end with zero
  duplicates.

**What would change my mind:** the lifecycle module passing ≈ 500 lines, or the replay test finding a
race the per-Issue lock cannot close. Then DBOS in engrams' short-run form, sweeper included. The
runtime decides nothing either way: Cortex runs DBOS on Bun 1.4.3, and the factory stays on Bun.

## Where sessions run, and looking back

**Postgres owns the work; herdr only hosts the process.** Every Claude Code session the factory starts
is an ordinary interactive session in a herdr tab, which keeps the brain's verdict on herdr ("keep it
as the pane you look through; do not let it own the work"). Weighed against the alternatives (`research/2026-10-25-claude-code-runtimes.md`,
`research/2026-10-25-session-runtimes.md`):

| Runtime | On your Max subscription | You can watch and type into it | After a crash or restart | Verdict |
|-|-|-|-|-|
| herdr pane, interactive `claude` | the plainest sanctioned use | yes, from the MacBook or the phone, beside your own sessions | a herdr restart kills the process; herdr re-runs `claude --resume <id>`, so the conversation is back and the turn in flight is lost | **used from W1a** |
| Claude Code background sessions (`claude --bg`, agent view) | yes, the same login | `claude attach` from any terminal, herdr included; peek and reply | Anthropic's supervisor restarts crashed sessions and survives any UI; a machine restart stops them, and so does an hour idle and unattached | research preview; the second adapter once the preview label goes |
| headless `claude -p`, stream-json | yes, but each token costs about 1.8× as much of the 5-hour window as in an interactive session ([claude-code#97074](https://github.com/anthropics/claude-code/issues/97074), open, reproduced on four accounts) | no; a message waits for the turn to end | the turn is lost; resume by id | not for leads; that alone would nearly halve their capacity |
| Agent SDK | Anthropic's pages contradict each other on subscription use | only through a UI we would build | resume by id, which its own docs say not to rely on | not used |

The factory starts and follows sessions through one port, `Runner` (start, state, note, stop,
resume), so herdr is one adapter. A model or effort change applies at the next spawn. Witness records herdr's server PID, so a herdr restart is an event,
not a silent loss: each affected lead resumes by session id with a note that a turn was cut off.
When background sessions leave research preview, or #97074 closes, they get a spike through the
same gamedays (both accounts, hooks, kill the supervisor, sleep and wake, an idle lead woken with a
note) that also reads the transcript `entrypoint` and the 5-hour share per token, so the headless rate
cannot slip in. If they pass, leads move there and herdr becomes only the view: about a day of adapter,
not a redesign.

**Where a lead works.** Each attempt gets its own worktree on `factory/<issue>-<attempt>`, made the way
`rd fan` makes them, so a lead never touches your checkout or another lead's, and your uncommitted work
stays yours. The lead merges by rebasing and pushing to the default branch, or through a pull request
it reviews and merges itself where `ship` says `pr` (always in the PR-required repos). Finalize removes
the worktree; pull to see the change in your own checkout.

**The session id is the durable handle, not the pane:**

- The lead's SessionStart hook reports its `session_id` and transcript path into the inbox, and the
  `sessions` row of that attempt keeps both.
- At close, the factory copies each attempt's transcript, its subagents' included, into the archive
  (W1b). Claude Code deletes its own after 30 days by default (the oldest on the mini today is from
  28 September), so the archive is the record.
- `factory issue resume <id>` (W6) opens an attempt in a new herdr tab with
  `claude --resume <archived transcript> --fork-session`: you can ask the lead that did the work why,
  months later, while the archived record stays as it was. Until W6, `claude --resume <session id>`
  does the same within the 30 days.
- Both accounts share one transcript store, so a session resumes on either account; that is what lets
  a walled lead move (§5).
- The transcript format is internal to Claude Code and changes between versions, so the factory
  stores, links and full-text searches transcripts but never parses them for decisions. What it acts
  on comes from hooks and the lead's `factory` reports. The scorers, once built (§9), read transcripts
  for labels only.

## Facts, not status

| Table | Holds |
|-|-|
| `projects` | every repo under `~/SourceRoot`: its synced `project.yaml` or the defaults, plus a pause flag |
| `signals` | one observation each: source, source time, subject, fingerprint, payload |
| `issues` + `issue_deps` | kind, class, title, parent (an initiative's waves are its child Issues), the lead's root cause and fix, summary, `wake_at` |
| `issue_links` | Signal → Issue, Issue → Issue (merged, split, related, regression of), who, why, and whether it acted (the judge's shadow verdicts do not): the grouping labels |
| `sessions` | herdr pane, worktree, Claude session id, archived transcript, role, account in effect, model, effort, Issue, Witness observations |
| `issue_inbox` | every event for an Issue, with its idempotency key and when it was handled |
| `claims` | key, holders, queued Issues |
| `events` | phases, notes, orchestrator actions, state changes: the history Argo shows |
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

A nightly `pg_dump` to the homelab bucket and a weekly restore drill, from W1a. Facts stay; lead
transcripts are archived to the homelab and the local copies kept. Warden is switched off at W1a and
its database deleted at W2; the golden set already holds what was worth learning from it.
