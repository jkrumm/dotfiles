# 5. Engines and capacity

## Who does what

| Engine | Paid by | Does |
|-|-|-|
| Claude Code in herdr | the `iu` (Max 20x) and `me` (Max 5x) subscriptions | **all implementation**: workers, mothers, your sessions |
| Cheap models — DeepSeek V4.1 Flash, Haiku 5.5, the decision model — through agent-gateway (OpenCode sessions, AI SDK calls) | IU API tokens, company-paid | **everything else that needs a model**: dedup, root-cause search, linking signals and jobs, structured JSON, wave planning, naming, every message and briefing, job summaries, review, research, the gateways, Hermes |
| Plain code | nothing | intake, rules, timers, runbooks, merge, deploy, rollback |

**The one rule: IU API tokens never implement.** Everything else is welcome to use them — that is what
they are cheap for, and the factory should lean on them rather than save them. Enforced since
2026-10-24: `rd` pauses instead of spilling, the IU launchers are gone, and agent-gateway's `implement`
lane runs on Max only (Phase 0, §12).

**Budget.** Your €500 covers it. One number to watch: last week's personal IU spend was $183 (≈ $790 a
month at that pace), and $136 of it was review. If the €500 is monthly, agent-gateway's review-depth
gating (W2) brings review back under it — light review for small diffs, full review where it matters —
and leaves room for everything else above.

**The factory never holds a model key.** Every model call goes through agent-gateway, so routing,
model choice and spend stay in one place.

## The pool

| Account | Plan | Share of weekly capacity | Home |
|-|-|-|-|
| `iu` | Max 20x | ⅔ | your interactive sessions, headless runs |
| `me` | Max 5x | ⅓ | waves, fan-outs, factory workers and mothers |

Your own work used ≈ 80 % of today's pool over the last 30 days, so factory code work fits into the
rest plus whatever would otherwise lapse at a reset. The picker (`claude-account pick`) decides per
spawn: eligibility, the pace guard, 5-hour balancing, expiring capacity first.

## Admission: three classes

The factory asks the picker with a class and gets an account or a time to wait until.

| Class | Examples | Gets an account when |
|-|-|-|
| **urgent** | an owner app is down, data at risk | any account is eligible |
| **normal** | bugs, your requests, planned waves | an account is under its weekly pace and your `iu` 5-hour window keeps ≥ 15 % free |
| **upkeep** | upgrades, docs, code health, security | capacity would otherwise lapse at the next reset — and every fleet project still gets one upkeep Task a week |

Otherwise the Task waits for its time; nothing spills to IU API tokens. With both accounts walled, the
runbooks and rollbacks still run — they need no model — and code waits for the first reset.

## Balance: both windows full, few switches

The goal for the two subscriptions: **both weekly windows end close to full, and sessions rarely
change account.**

- **Switching happens only at spawn.** A session keeps its account while its cache is warm, so the cache
  is never thrown away mid-work.
- **The picker steers new spawns** toward the account that is behind its pace, and spends capacity
  that would lapse first.
- **It is tuned from data, not guessed.** A weekly job has a cheap model read the picker's decisions and
  the quota history and propose threshold changes as an upkeep Task. Measured on *Usage*:

| Measure | Target |
|-|-|
| capacity left unused at each weekly reset, per account | < 10 % |
| account changes of a running piece of work | 0 |
| minutes your interactive session waited on a wall | 0 |
| Tasks shipped per 1 % of weekly capacity, per account | rising |
| hours Tasks waited for capacity, per class | visible, drives a third subscription |
