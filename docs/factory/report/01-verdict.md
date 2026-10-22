# 1. Verdict

**Rebuild warden as level-triggered reconcilers over one ledger, describe every repo in one
manifest, take signals from their sources, and let verification — not the owner — gate every
ship. Adopt no heavy runtime: beads, a workflow engine and Keep's model each lost a measured spike,
and their designs are copied instead.** The factory's real cost today is owner attention, not tokens: 577
owner-facing notifications and 50 "continue" nudges, against $2.60 of agent spend on the ten worst
incidents.

## The target in ten lines

1. **One fresh ledger** (`ledger.db`, history imported once from the archived `warden.db`) with an append-only event log; eleven nouns, one writer each.
2. **One `project.yaml` per repo**; the per-repo AGENTS.md block, herdr groups, Argo's registry and reconciler policies are generated from it, and tool routing renders once into a global rules file.
3. **Signals from their primary sources** with source time; Slack intake stops at W1a and the adapters replace it from W3.
4. **Per-project reconcilers** open and close Conditions; a webhook only schedules a reconcile.
5. **A correlator** folds conditions by fingerprint, topology and time window into one incident per cause; closed incidents with a recipe are the known-error store.
6. **Tasks live in the ledger** with a blocker-aware ready queue; mothers (six fleet projects) and sessions (everything else) work them through one spawner, `rd`.
7. **Every agent runs in herdr**; engine by class — your own sessions and waves on Claude Code/Max, routine work and factory judgment (mother wakes) on OpenCode/IU, with Max used for factory work only where its capacity would lapse; the quota guard is a scheduler input; Witness resumes parked agents.
8. **A verification ladder per action class** authorises auto-ship; absent evidence fails closed to propose-only; rollback redeploys the last held Deployment and squash merges keep the git revert mechanical; a breaker counted per lineage stops runaway loops without paging anyone.
9. **The owner decides four things only** — product direction, spend, irreversible data loss, other people — each as a card with a default and an expiry; SLO: under 1 % of items reach him, stretch 0.1 %.
10. **Argo answers his 27 canonical questions, the brief's 3 and one about his own requests** from live read models on the mini; the VPS keeps the life pages and the off-site dead-man's switch.

## The numbers

{{asset:chart-baseline}}


| Metric | Baseline (evidence) | Target |
|-|-|-|
| Items with no owner touch, 14 d | **64.3 %** (`kpi/baseline`) | SLO ≥ 99 %, stretch 99.9 % |
| New items that reached the owner, 14 d | **32.2 %** (74 / 230); only 3.8 % of escalations genuinely his (golden set) | SLO < 1 %, stretch ≤ 0.1 % — business only |
| Owner-facing notifications | **≈ 62 per week** over 28 days; 577 all time, of which today's KPI sees 140 (`kpi/owner_pages`, `incidents/`) | ≤ 2 per week; present-human asks (credential renewals, ≤ 2 a month) are counted apart |
| Owner `continue` nudges to parked agents | **50** in 45 days (`questions/`) | 0 |
| Pages for the ten costliest incidents | **180** → ≈ 8 under the ideal path (`incidents/`) | — |
| Time to resolve, median / p90, 14 d | 0.7 h / 14.9 h | ≤ 0.5 h / ≤ 4 h |
| Reopen / regression rate | 10.4 % / 10.4 % | ≤ 5 % each |
| Automatic revert when post-deploy verify fails | **0 of 52** merges (rebase merges) | 100 % |
| Max load per week (30 d) | **120 %** (109–144) of a weekly window: owner-steered waves 74 %, interactive 32 %, agw review 14 % (`kpi/forecast`); burn rate across two resets, last 7 d: 204 % | factory work off Max unless capacity would lapse; owner interactive sessions blocked per cycle → 0 (measured from W4) |
| Max lapsed at the reset | p50 **4 %**, p90 30.6 % (`kpi/forecast`); 3 of 7 cycles peaked at 55–79 % (`kpi/quota`) | spent late in light cycles by the inverse rule, on the in-cycle projection of your burn (ADR-008) |
| Status questions asked outside Argo | ≈ 25 per week (`questions/`) | ≤ 5 per week |
| Signals arriving through Slack relays | **63.7 %** (`signals/`) | 0 % |
| Locked-model claims that held | 8 of 26 — enforced 7/7, prose 1/11 (`postmortem/`) | every invariant enforced or labelled `target` |
| Backtest, held-out, pre-registered thresholds | v1 rules: grouping F1 **0.889** vs warden 0.744; 5 of 8 pass — escalation and known-error matching fail (`golden/backtest`) | v2 rules: grouping accepted at W3 by a frozen-output regression and a blind replay; escalation and known-error matching are standing SLOs, first measured at W10's gate |

## Decisions taken

| ADR | Decision |
|-|-|
| 001 | Tasks live in the ledger with bd's verbs; beads' runtime is not adopted (cross-repo deps inert, 5-min fixed lease, work repos touched) |
| 002 | Durable execution = the ledger with explicit statecharts; no engine (DBOS strands flows on redeploy) |
| 003 | Correlation is deterministic (fingerprint, topology, window); judgment stays with the investigating agent; three escalation classes are guaranteed by capability limits; Keep not adopted |
| 004 | CLI-first: every tool a CLI on one agent contract, commands defined once in code, docs and routing generated; MCP only for research-gateway and chrome-devtools |
| 005 | Artifacts are ours: the `warden artifact` module — threads in the ledger, versions in git — with Argo's Artifacts view and a basalt-ui comment thread; plannotator only until W7; never a gate |
| 006 | One trace per item: derived trace id, `traceparent` where it travels, a resource attribute where it cannot |
| 007 | On-demand mothers (persistent identity, no resident context) for six fleet projects, sessions elsewhere, one spawner, the hook owns the work, Witness resumes |
| 008 | herdr always, engine by class, quota guard — Round 5's open question, decided with numbers |
| 009 | Argo split: factory read API on the mini, SPA and life data on the VPS, dead-man's switch on the VPS |
| 010 | One `project.yaml` per repo; everything about a project is generated from it |
| 011 | One ledger, one event log, one writer per entity |
| 012 | A verification ladder per action class replaces approval; rollback to the last held Deployment; squash merges; breaker without pages |
| 013 | Signals from their primary sources; Slack intake stops at W1a |
| 014 | The owner decides business questions only; every decision has a default and an expiry |
| 015 | Argo writes intents — submit, steer, pause, decide, comment, re-verify, stop — executed by reconcilers, never imperative calls |

## Open owner decisions

Five, all business, each with a default that applies if nobody answers — section 10.

1. **IU cash for factory-originated work** — default: A, 3 mother wakes per mother per day (≈ $294/week with the ≈ $28 base); the forecast's rate, 8 per mother per day, is ≈ $735/week.
2. **Claude subscription tier** — default: keep it; the spillover of owner-started work to IU (≈ $19–94 a week across the forecast range) is priced against the next tier's price, which you read from your account.
3. **Autonomy in work repos** — default: read, investigate and open PRs; never merge or deploy.
4. **Who defines "it works" for each product** — default: the project's mother drafts holdout scenarios from W5; each set binds 7 days after submission unless edited.
5. **Retention of agent transcripts and dead sessions** — default: archive to the homelab, delete local copies after 90 days.
