# 1. Verdict

**Rebuild warden as level-triggered reconcilers over one ledger, describe every repo in one
manifest, take signals from their sources, and let verification — not the owner — gate every
ship. Adopt no heavy runtime: beads, a workflow engine and Keep each lost a measured spike; their
designs are copied instead.** The factory's real cost today is owner attention, not tokens: 577
owner-facing notifications and 50 "continue" nudges, against $2.60 of agent spend on the ten worst
incidents.

## The target in ten lines

1. **One ledger** (`warden.db`, evolved in place) with an append-only event log; twelve nouns, one writer each.
2. **One `project.yaml` per repo**; AGENTS.md routing, herdr groups, Argo's registry and reconciler policies are generated from it.
3. **Signals from their primary sources** with source time; Slack intake retires source by source.
4. **Per-project reconcilers** open and close Conditions; a webhook only schedules a reconcile.
5. **A correlator** folds conditions by fingerprint, topology and time window into one incident per cause; closed incidents with a recipe are the known-error store.
6. **Tasks live in the ledger** with a blocker-aware ready queue; mothers (six fleet projects) and sessions (everything else) work them through one spawner, `rd`.
7. **Every agent runs in herdr**; engine by class (routine on OpenCode/IU, judgment on Claude Code/Max); quota is a scheduler input; Witness resumes parked agents.
8. **A verification ladder per action class** authorises auto-ship; squash merges make automatic revert possible; a breaker stops runaway loops without paging anyone.
9. **The owner decides four things only** — product direction, spend, irreversible data loss, other people — each as a card with a default and an expiry.
10. **Argo answers his 23 recurring questions** from live read models on the mini; the VPS keeps the life pages and the off-site dead-man's switch.

## The numbers

| Metric | Baseline (evidence) | Target |
|-|-|-|
| Items with no owner touch, 14 d | **64.3 %** (`kpi/baseline`) | ≥ 99.9 % |
| New items that reached the owner, 14 d | **32.2 %** (74 / 230) | ≤ 0.1 %, business only |
| Owner-facing notifications, all time | **577** — today's KPI sees 140 (`incidents/`) | ≤ 2 per week |
| Owner `continue` nudges to parked agents | **50** in 45 days (`questions/`) | 0 |
| Pages for the ten costliest incidents | **180** → ≈ 8 under the ideal path (`incidents/`) | — |
| Time to resolve, median / p90, 14 d | 0.7 h / 14.9 h | ≤ 0.5 h / ≤ 4 h |
| Reopen / regression rate | 10.4 % / 10.4 % | ≤ 5 % each |
| Automatic revert when post-deploy verify fails | **0 of 52** merges (rebase merges) | 100 % |
| Days with Max 7-day window ≥ 90 % | **12 of 45** (`kpi/quota`) | ≤ 2 per month |
| Status questions asked outside Argo | ≈ 25 per week (`questions/`) | ≤ 5 per week |
| Signals arriving through Slack relays | **63.7 %** (`signals/`) | 0 % |
| Locked-model claims that held | 8 of 26 — enforced 7/7, prose 1/11 (`postmortem/`) | every invariant enforced or labelled `target` |
| Backtest, held-out, against pre-registered thresholds | ⟨spike 3⟩ | pass |

## Decisions taken

| ADR | Decision |
|-|-|
| 001 | Tasks live in the ledger with bd's verbs; beads' runtime is not adopted (cross-repo deps inert, 5-min fixed lease, work repos touched) |
| 002 | Durable execution = the ledger with explicit statecharts; no engine (DBOS strands flows on redeploy) |
| 003 | ⟨correlation, spike 3⟩ |
| 004 | Gateways by job length and definition size: agw deferred MCP + `--json` CLI, research and email inline MCP; routing block generated with a drift check |
| 005 | Artifact review = plannotator's Inbox behind our own `rv submit/wait/status`; never a gate |
| 006 | One trace per item: derived trace id, `traceparent` where it travels, a resource attribute where it cannot |
| 007 | Mothers for six fleet projects, sessions elsewhere, one spawner, the hook owns the work, Witness resumes |
| 008 | herdr always, engine by class, quota guard — Round 5's open question, decided with numbers |
| 009 | Argo split: factory read API on the mini, SPA and life data on the VPS, dead-man's switch on the VPS |
| 010 | One `project.yaml` per repo; everything about a project is generated from it |
| 011 | One ledger, one event log, one writer per entity |
| 012 | A verification ladder per action class replaces approval; squash merges; breaker without pages |
| 013 | Signals from their primary sources; Slack intake retires |
| 014 | The owner decides business questions only; every decision has a default and an expiry |

## Open owner decisions

Five, all business, each with a default that applies if nobody answers — section 10.

1. **IU budget for non-urgent factory work** — default: $30/day.
2. **Claude subscription tier** — default: keep it; the quota guard routes non-urgent work to IU.
3. **Autonomy in work repos** — default: read, investigate and open PRs; never merge or deploy.
4. **Who defines "it works" for each product** — default: leads draft holdout scenarios; binding after 7 days unless edited.
5. **Retention of agent transcripts and dead sessions** — default: archive to the homelab, delete local copies after 90 days.
