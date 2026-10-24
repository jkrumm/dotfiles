# ADR-002 — Durable execution: the ledger with explicit statecharts, no engine

> **v2 status (2026-10-24):** kept in substance on Postgres; DBOS re-evaluated and declined for a different reason (TDD v2 §6). The text below is v1 history.

- Status: accepted · 2026-10-22 · revised after panel passes 1 and 2 (dur-1…dur-8, int-6) and the cross-lab review (`panel/review-resolutions.md`: R10, R14, R16, I3, T1)
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
- **generation keys** `<entity>:<kind>:<generation>`, the generation read from ledger state in the same transaction that writes the `operations` row and ending in a per-entity attempt counter `<n>` (the earlier `operations` rows of the same entity and kind, plus one) — `dep:<target>:<artifact>:<n>`, `restart:<condition>:<flap#>:<n>`, `revert:<change>:<n>`, where `<artifact>` is the immutable reference deployed (image digest, compose revision or bundle hash: `runtime[].artifact`, `design/model.md` §6), so a Deployment with no Change has a key too. A legitimate repeat — a deploy retried after `failed` on the same sha, a second restart in one flap, a second revert — is a new key, and the rate limit, not the key, stops the next one; this scheme is the only one;
- durable timers in `retry_at`, cleared in the same transaction that writes the timer's `operations` row, so after a crash the open operation is probed and never re-fired; leases with a TTL renewed per tick, each grant issuing an **epoch** (below);
- decisions with an absolute deadline and a per-action-class default (timing rules: ADR-014);
- the episode contract: heartbeat, idle watchdog, re-drive by persisted session id from the hook (ADR-007);
- agent-CLI mutations are idempotent by key (ADR-004).

| Effect registry strategy | Effects | In-doubt resolution |
|-|-|-|
| native key | targets that honour an idempotency key | resend the same generation key |
| natural key + lookup on conflict | PR by head branch `factory/<task>` (`factory/<task>-<k>` after a forced fresh branch; a superseding branch closes the old PR in the same operation, so a Task has one open PR); merge with GitHub's expected-head `sha=`; revert branch `revert/<change>-<n>`; integrations creates (herdr workspace, Kuma monitor, TickTick list, brain note stub, runner sync) by their manifest name; `hl` copies by destination key | on a 422 or conflict, look up the existing object and adopt it |
| probe before retry | deploy; restart (the container's start time against the operation row); spawn (a herdr tab whose metadata carries `agent=<id>`); pane message — steer, Witness resume, continue and nudge (the message id in the herdr pane record; flow: ADR-007 §5); `rd close` (the tab is gone) | the probe decides done or not-done; never a blind retry |
| at-least-once, de-duplicated | decision and heads-up pushes | the `deliveries` row (ADR-011) moves pending → accepted and is retried until the push service accepts; the phone de-duplicates by event id |
| at-most-once with receipt | the briefing push | a recorded receipt (`deliveries`) means sent; a lost one costs nothing, the digest is in Home |

**Deploys.** A deploy runs detached under `jobrun`, holding a per-target lock with a start record
(key, artifact) that names its holder by pid, boot id and start time. The lock is **stale** when
the holder is dead (no live process with that pid and start time) or the boot id differs from the
current boot. The probe reads the lock first: held → wait; stale → read the deployed artifact and
decide; only then is a retry possible. A `deploy: ci` target's effect is the merge and
its probe is the workflow run for the merge sha. Every runtime with a deploy command declares how
to read what runs (`version` or `artifact`; drift check, `design/model.md` §6.1), so no in-doubt
deploy is unresolvable.

**Epochs.** Every lease grant — task claim, Agent, merge slot — issues a monotonic epoch written
into the hook; every mutating call carries it and the CAS rejects a stale one. The epoch also fences
the agent's own git: a per-worktree pre-push hook calls `warden lease check --epoch` and rejects a
stale epoch; commits carry `Factory-Agent` and `Factory-Epoch` trailers; the merge train accepts
only heads pushed under the current epoch. At the ledger, git effects are fenced by
`push --force-with-lease=<ledger sha>` and merge `sha=`. A re-drive successor is granted the same
hook (worktree and branch) only after the predecessor is confirmed dead — its pane process tree
killed and verified through herdr and `ps`; otherwise it gets a fresh worktree on a new branch
`factory/<task>-<k>` cut from the ledger-recorded sha. A merge slot passes to the next holder only
after the previous holder's in-doubt operation is probed. A spawn that carries a `task_id` needs a
lease, so `rd` fails closed without one (ADR-007 §3).

### Consequences

- Good: zero dependencies; crash recovery is "run the reconcilers again" (0.06–0.5 s in the spike); any SQL reader sees every flow.
- Bad: we own CAS and lease correctness; the loop needs a resident 1–5 s tick or an event nudge; every loop runs as a phase of that one warden process, never a second loop process (ADR-011); state renames need migrations (expand/contract only, under the ledger's schema stamp, ADR-011); no replay tooling.

### Confirmation

The spike's kill harness (tests a–f and h) becomes a regression suite: a new flow type ships only
when it passes it in CI, with one case per effect-registry entry — spawn, pane message, `rd close`,
integrations create and `hl` copy included. The spike's 0 duplicates came from a stub that honours
the key (`spikes/02-durable/REPORT.md`), so W1b's gate re-runs kill tests b, b_deploy and h against
real-shaped adapters — a scratch GitHub repo returning real 422s, counting fakes for deploy and
restart — pass = every target counts exactly one effect. W1b's gate also runs ADR-011's restore
test (a restored copy re-executes 0 effects). Added by pass 2:

- **Key uniqueness**, generated from the statecharts (`design/model.md` §2): every path that
  repeats an effect (two restarts in one flap, a deploy retried after `failed`, a second revert)
  gets a distinct key and runs; only the rate limit stops a third restart.
- **Deploy kills**: kill warden at three points of a deploy against a counting fake, on a compose
  target, a launchd target and a `deploy: ci` target; pass = exactly one deploy per key, never two
  overlapping, and each in-doubt operation resolves without a blind retry; a live holder's lock
  reads held, while a killed holder or a reboot (a new boot id) turns it stale.
- **Pane messages**: kill warden between `rd say` and the timer-clear commit across resume,
  continue, nudge and steer; pass = each message appears once in the pane transcript and a resume
  admitted before the crash is not admitted again.
- **Fencing gameday** (W1b, W4b): SIGSTOP an agent past its TTL, re-drive, SIGCONT, and have the
  zombie run raw `git commit -am x && git push && gh pr create` in its pane; pass = the successor's
  tree never holds the zombie's edits, the push is rejected, no PR from the zombie survives, and the
  train merges no head that was not pushed under the current epoch.

KPI: duplicate or lost side effects = 0 per quarter.

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
