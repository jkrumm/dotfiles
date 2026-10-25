# 5. Engines and capacity

## Who does what

| Engine | Paid by | Does |
|-|-|-|
| **Claude Code in herdr**: leads, their workers, the orchestrator, your own sessions | the `iu` (Max 20x) and `me` (Max 5x) subscriptions | everything that needs understanding: root cause, plan, code, tests, verification, ship, the production check, the close report |
| **Cheap models** through agent-gateway: DeepSeek Flash, Haiku, the decision model (ids live in `agw routing`) | IU API tokens, company-paid | the routine around it: dedup judging, classification, card and briefing wording, the changelog, learning write-ups, job summaries; and the tools a lead calls, such as review and research; Hermes; the gateways |
| **Plain code** | nothing | intake, rules, timers, runbooks, admission, Witness, the evidence check, re-verify |

**The rule: IU API tokens never implement and never diagnose for a lead.** A review or research
result is input the lead weighs, not a verdict. Enforced in code since 2026-10-24: `rd` pauses
instead of spilling, the IU launchers are gone, and agent-gateway's `implement` lane runs on Max only.

**Budget.** Last week's personal IU spend was $183 (≈ $790 a month at that pace), $136 of it review.
If the €500 is monthly, review-depth gating in agent-gateway (a side change, §12) brings review back
under it: light review for small diffs, full review where it matters. The factory never holds a model key; every
model call goes through agent-gateway.

## The pool

| Account | Plan | Weekly share | 5-hour window | Now (Sun 25 Oct, 11:00) |
|-|-|-|-|-|
| `iu` | Max 20x | ⅔ | 4 × `me`'s | week 90 %, resets Wed 28 Oct 16:00 · 5 h 2 % |
| `me` | Max 5x | ⅓ | ¼ of `iu`'s | week 24 %, resets Thu 29 Oct 06:00 · 5 h 54 % |

**On `me` the 5-hour window binds before the week does.** It is a quarter of `iu`'s while its weekly
share is a third, so one heavy lead can fill it. Today's snapshot also shows the imbalance the
balance goal is for: `iu` is nearly full with three days left, while `me` would lapse more than half
unused unless work moves there.

## Admission

The factory asks the picker for an account with a class and an expected size, and gets an account
or a time to wait until.

| Class | Examples | Gets an account when |
|-|-|-|
| **urgent** | an owner app is down, data at risk | any account is eligible |
| **normal** | bugs, your requests, initiative waves | an account is under its weekly pace |
| **upkeep** | upgrades, docs, code health, security | capacity would otherwise lapse at the next reset; every repo with a manifest still gets one upkeep Issue a week |

- **5-hour headroom.** A lead starts on an account only if that account's 5-hour headroom covers a
  fixed share per model tier, set from W1a's measured cost per session; leads admitted but not yet
  measured count against it. Otherwise it goes to the other account, otherwise it waits for the
  earlier reset: usually a 5-hour one, the weekly one when a week is spent.
- **Your reserve.** On both accounts, 15 % of the 5-hour window and the last 5 % of the week stay free
  for your own sessions.
- **Concurrency.** One lead per repo unless its manifest's `leads` allows more, plus one urgent; an initiative's waves run in dependency order.
- **Stop the line.** While a project's production is red (a failing probe or an open urgent Issue), it
  gets only fixes; its features and upkeep wait. Cortex's DRIVE paper calls this the andon cord.
- **Never spill.** With both accounts walled, settle and runbooks still run (they need no model), and
  leads wait for the first reset.

## Model and effort per lead

Classification picks the lead's model and effort from size and kind; the launcher passes them on.

| Work | Lead | Effort |
|-|-|-|
| xs, mechanical: a rename, docs, a patch bump | Haiku | low |
| s–m: most bugs and requests | Sonnet | medium |
| l–xl, novel design, security | Opus | medium |

A second attempt goes one tier up with its predecessor's notes; a second attempt on Opus runs at high
effort. Until W3 the factory applies this rule itself, once, then parks the Issue; from W3 the
orchestrator decides. Only the orchestrator sets maximum effort, and its changes apply at the next
spawn. The lead picks its own workers' models by the same table. A tuning job that proposes new
defaults from cost and outcome per tier waits until 50 Issues have closed (§9).

## The orchestrator

The layer above the leads (§4). Besides planning initiatives, it has one job: keep the whole factory
moving without wasting either subscription.

- **When,** one list (the factory raises these events; it never re-tiers or splits on its own after W3):
  - an initiative to plan, or one of its waves shipped (§4)
  - a stalled lead: two hours of work time with no commit, no phase change and no declared wait
  - a lead that stops unreported a second time, or a pane that dies three times in ten minutes
  - three failed production checks on one Issue, or an Issue reopened twice
  - a decision about to take its default
  - 06:30 daily, for exceptions only
- **Reads:** `factory status --format md`: queue, leads, capacity forecast, scorecard (§9). Never raw
  logs. An Issue waiting more than 24 hours and an account heading for more than 10 % unused are
  lines in its status and in your briefing, not wakes.
- **Does,** through `factory`: reorder within a class (`issue prio`), set a dependency (`issue dep`),
  steer a lead (`issue note`), give a stalled Issue a stronger model (`issue retier`) or split it,
  merge Issues, park one (`issue park`, a line for you), pause a project (`project pause`), put a
  card to you for the four business classes only, and open an upkeep Issue for a policy change
  (picker thresholds, tier defaults). Each finding it acts on becomes one of these, so its follow-ups
  live in the queue like any other work.
- **Never** writes code, touches a repo, or starts work the queue does not hold.
- **Runs** on the account with the most slack: Opus for initiatives and wave reviews, Sonnet at
  medium for everything else; a typical routine wake takes minutes.

Until W3 builds it, the build orchestrator does this job for the rewrite itself (§12).

## Balance: both windows full, few switches

The goal: **both weekly windows end close to full, and work rarely changes account.**

- **Switching happens at spawn,** with one exception: a walled lead that would wait more than an hour
  resumes on the other account if it has headroom, counted as a switch. Its prompt cache is gone after
  such a wait anyway, and both accounts share the transcript store (§6).
- **The picker steers new spawns** toward the account behind its pace, spends capacity that would
  lapse first, and checks 5-hour headroom before it starts anything.
- **Tuned from data, later:** once 50 Issues have closed, a tuning job has a cheap model read the
  picker's decisions and the quota history and propose threshold changes; the orchestrator turns the
  ones worth trying into upkeep Issues, and a lead ships each like any other change.

| Measure, on *Usage* | Target |
|-|-|
| capacity left unused at each weekly reset, per account | < 10 % |
| account changes of a running lead | walls only |
| minutes your own sessions waited on a wall | 0 |
| leads that hit a 5-hour wall mid-work | falling |
| Issues shipped per 1 % of weekly capacity, per account and tier | rising |
| hours Issues waited for capacity, per class | visible; the number that justifies a third subscription |
