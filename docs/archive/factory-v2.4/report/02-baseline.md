# 2. Baseline and postmortem

Every number below reproduces from a script in `evidence/` (definitions fixed first in
`evidence/DEFINITIONS.md`; `AS_OF` 2026-10-22 08:00 UTC; mutable stores read from frozen snapshots —
`warden.db` as of 07:51:56 UTC, before Phase 0's last warden work drained the live `needs_decision` queue (43 at the snapshot) from 25 to
2 by 09:56 UTC, so W1a imports that snapshot plus a recorded delta).

## 2.1 The loop today

| Metric | 14 d | 30 d | all | Source |
|-|-|-|-|-|
| Items (duplicates excluded) | 230 | 364 | 556 | `kpi/baseline` |
| Reached the owner (`needs_decision`) | 32.2 % | 28.8 % | 20.5 % | same |
| No owner touch at all (autonomy) | 64.3 % | 52.2 % | 52.5 % | same |
| Resolved | 65.7 % | 76.9 % | 81.3 % | same |
| Time to resolve, median / p90 | 0.7 h / 14.9 h | 1.1 h / 49 h | 1.7 h / 107 h | same |
| Reopened after a terminal state | 10.4 % | 15.3 % | 17.5 % | same |
| Fixes whose fingerprint recurred ≤ 30 d | — | — | 10.4 % (5 / 48) | same |
| Agent cost per resolved item | IU $0.36 + Max-equivalent $1.08 | IU $0.41 + $1.22 | IU $0.31 + $0.88 | `kpi/cost` |

Round 5's "74 / 228 = 32 %" and the findings' "114 / 597" both reproduce exactly; the unified
definition gives 74 / 230 (`kpi/baseline.out.md` §Reconciliation). The cost row mixes two regimes
(Max review carried most of it until 10-15): the cost baseline is the post-10-15 regime, IU $0.12 and
Max $0 per resolved item (W43, `kpi/cost`).

**Delivery (DORA, 90 d, `kpi/dora`):** 1,418 deploys (110 per week) across 18 repos; lead time median
0.53 h; change failure rate 2.0 % when each item is charged to the latest deploy (18.4 % under the
literal 24-hour rule — the definition is now fixed); failed-deployment recovery median 0.27 h.
Rework: 25.6 % of commits fix something touched in the previous 7 days (argo 51.8 %, research-gateway
39.4 %). Revert: 14 commits in 90 days; warden auto-reverted 0 of its 52 merges, because its
merges were rebase merges (48 receipts record `rebase`, none `squash`).

{{asset:chart-rework}}


**Capacity (`kpi/quota`, `kpi/engine_policy`):** Max's 7-day window p50 46 %, p90 96 %, ≥ 90 % on 12

{{asset:chart-quota}}

of 45 days, effectively unavailable Sep 16–20. Max is 97.8 % of agent cost at list price but 32 %
of tokens; 1 % of the weekly window ≈ $32. Who fills it (`kpi/forecast`): owner-steered fleet waves
74 %, owner-interactive sessions 32 % and agw review 14 % — 120 % (109–144) of a weekly window per
week over 30 days. 3 of 7 complete cycles peaked at 55–79 % and lapsed the rest (p50 4 %, p90 30.6 %
at the reset). The last 7 days burned at 204 % across two resets: a burn rate, not a window reading.

**herdr (`kpi/herdr_hygiene`, live 08:55):** 29 workspaces, 50 tabs, 25 agents; 20 finished-but-open
tabs; two dead `claude --bg` sessions, 705 h and 387 h old.

## 2.2 Where the owner's attention goes

{{asset:chart-attention}}


**Ten costliest incidents (`incidents/`)** — 180 pages; under the ideal path ≈ 8:

| Incident | Pages | Duration | What would have handled it |
|-|-|-|-|
| Mini DNS/outbound failures, 05-08 | 31 | 7 h + 1,284 h of reminders | known error, reconcile, correlate |
| garmin-sync healthcheck false positive, 04-30 | 20 | 124 h | reconcile, verify |
| Kuma monitor sync with unresolved `${VAR}`, 08-01 | 20 | 11.4 h | correlate, verify, reconcile |
| Deploy churn, derived group monitors paging, 09-08 | 19 | 78.5 h | correlate, reconcile |
| Laptop job heartbeat missing, 07-04 | 18 | 108 h | reconcile, correlate |
| **Clean VPS kernel reboot, 10-17** | 18 | 7.9 min of impact | correlate, reconcile, known error |
| Poller false positives + checkpoint race, 09-15 | 16 | 4.7 h | correlate, verify |
| Checkpoint log noise, 23 implement re-runs, 10-04 | 15 | 140 h | known error, correlate, verify, durable |
| Homelab hard reset, drive left unmounted, 10-21 | 12 | 16 h | correlate, owner (the one legitimate page) |
| Hermes crash + loop paging on its own grep, 10-01 | 11 | 3.1 h | known error, correlate, reconcile |

The ledger holds 577 owner-facing notifications: 281 legacy posts, 156 reminders and only 140
decision entries — the only ones today's escalation KPI counts. Agent spend on all ten: $2.60.

**The latest twenty interventions (`interventions/`, 40 hours):** 4 were genuinely the owner's
(business), 16 were removable — 5 infra waiting for a present human, 4 agents that stopped or asked
needlessly, 3 missing capabilities, 2 wrong outputs, 2 other. 26 owner messages in 21 days are
"continue" typed after a transient API error stopped an agent (median stall 1.2 h, max 23.4 h).

**What he asks (`questions/`, 1,111 owner messages):** 199 of 211 status questions went to a Claude
Code session and 12 to Hermes (2 of Hermes' 77 owner messages came through Argo's chat). Each answer is rebuilt from scratch: median 48 s
and 5 tool calls. The #1 owner action is not a question but 50 `continue` nudges (41 of them, and 352 of the messages, come from MacBook transcripts read from a private dump taken over ssh: they reproduce only with that dump).

**Toil (`toil/`):** the owner types the `c` launcher 479 times a month and `claude --resume` 123
times; agents ran 5,782 `sleep` calls and 3,499 poll loops in 30 days, and 530 commands failed on
macOS-vs-GNU syntax. The design answers the polls with the CLI's `--wait` default and the
GNU-syntax failures with a PreToolUse rewrite in W12 (ADR-004, `waves.md`).

## 2.3 Signals arrive second-hand

{{asset:chart-signals}}


63.7 % of warden's signals (1,121 of 1,761) are Slack relays (`signals/`). The relay keeps text and
poll time only: 89 of 128 Slack alert items had no repo; an Up never closes its Down; the median lag
is 15.7 min while 79.6 % of Kuma outages end inside one poll; each poll reads the newest 50
messages; since 10-16, 37 of 40 Kuma Downs via Slack duplicate the live webhook. 713 `#updates` rows
(669 of them RollHook deploy notices) are never ingested, and since 10-11 the notice stream has collapsed — deploys are invisible.

## 2.4 Why every locked model drifted

{{asset:chart-drift}}


Six "locked" models since the September estate round, 26 checkable claims (`postmortem/`): 18 were
false at `AS_OF`, 15 of them within 7 days of their lock (median 0.9 days); 9 were false on the day
they were locked.

| Lock | First claim to fail |
|-|-|
| Estate round 2, 09-10 | 0.3 d (Hermes read path); "un-overridable" self-pin broken in 4.7 d |
| Agent platform, 10-02 | 0 d (its own no-model-ids rule); Hermes never-codes broken in 2.1 d |
| Setup round 4, 10-10 | the `/wave` skill and the platform doc disagreed from the lock |
| OpenCode v2, 10-14 | `agw-readonly` contradicted warden's brief 1.5 h after the lock; ≈ 30 of 74 escalations |
| Background jobs, 10-16 | reversed by Round 5 after 5.1 d |
| Round 5, 10-21 | 3 of 3 never-lists false at lock |

**The failure that repeats:** only claims that code runs held — enforced 7 of 7, prose 1 of 11,
cross-repo promises 0 of 2. Targets were written as facts. One model was hand-copied into 19 files.
Cross-repo promises had no shared test. Locks outran feedback (median wave 2.4 h), and 55 % of 293
open Left-behind items name no owner, so they die.

**Design rule taken from it:** every invariant in this design is either enforced by a capability
limit with a test, a CI check or a generated file — or labelled `target`. Every Left-behind item
becomes a Task with an owner.

## 2.5 Defects found on the way

| Found | Effect | Status |
|-|-|-|
| usage-tracker read OpenCode's old store since 10-14 and reported ok | all IU OpenCode spend missing from usage.db and Argo | **fixed** (Phase 0, usage-tracker W1: 33,414 rows, $58.08 at `AS_OF`; 33,652 rows, $58.47 once the backfill finished at 08:42Z; stale collectors now fail verify) |
| `settings.template.json` sets `CLAUDE_CODE_ENABLE_TELEMETRY=0` | all Claude Code telemetry silently off | migration W9 |
| RollHook notice stream collapsed since 10-11 | deploys invisible to warden | migration W3 (primary-source adapter) |
| `fixed_by_pr`, `revert_pr`, `reverting_sha` never populated | regressions invisible in the ledger | migration W1a (event log), W3b (known errors) |
| `rd say` text is recorded as owner-typed | 61 % of "owner" transcript entries are agent-authored; every transcript KPI must filter | measurement rule in `evidence/`; from W4 steer messages are ledger events with their own actor (ADR-015) |
| Watchtower is archived upstream (last release 2023-11) | an unmaintained tool in the deploy path, stopping containers without recorded intent | migration W3 retires it for factory-managed containers (RollHook or WUD with recorded intent); a container replaced without intent is recorded as an unplanned Deployment from Docker events |
