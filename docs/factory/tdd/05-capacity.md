# 5. Engines and capacity

## Who pays for what

| Engine | Paid by | Used for |
|-|-|-|
| Deterministic code | nothing | intake, dedup rules, settle, runbooks, merge, deploy, rollback, green jobs |
| Cheap models through agent-gateway | IU API tokens | triage scores, investigations, plans, review, job summaries |
| Claude Code in herdr | the `iu` Max account (20x) and the `me` Max account (5x) | all code: workers, mothers, your sessions |

**IU API tokens never write code.** Enforced since 2026-10-24: `rd` pauses instead of spilling and the
IU launchers (`ca`, `cap`, `cdf`, `cdp`) are gone; agent-gateway's `implement` lane runs on Max with no
IU fallback (Phase 0, §12). That lane is headless and only warden calls it; W1 removes its only caller
and W6 removes the lane.

**The factory never holds a model key.** Every model call goes through agent-gateway, so routing,
model choice and spend stay in one place.

## The pool

| Account | Plan | Share of the pool, weekly | Home |
|-|-|-|-|
| `iu` | Max 20x | ⅔ | your interactive sessions, headless runs |
| `me` | Max 5x | ⅓ | waves, fan-outs, factory workers and mothers |

Over the last 30 days your own work used 120 % of one `iu` week (v1 `kpi/forecast`). Against today's
pool that is ≈ 80 %, so the factory's own code work fits into ≈ 20 % plus whatever would otherwise
lapse at a reset. The picker (`claude-account pick`) already decides per spawn: eligibility, a pace
guard, 5-hour balancing, and expiring capacity first.

## Admission: three classes

The factory asks the picker with a class and gets back an account or a time to wait until. One rule
set, in the picker; the factory only waits.

| Class | Examples | Gets an account when |
|-|-|-|
| **urgent** | an owner app is down, data at risk | any account is eligible; bypasses the limit on parallel sessions |
| **normal** | bugs, your requests, planned waves | the picker finds an account under its weekly pace and below 85 % of its 5-hour window, and your `iu` window keeps ≥ 15 % free |
| **upkeep** | upgrades, docs, code health, security | the picker's expiring-capacity rule holds (an account resets within 24 h with room to spare) — and every fleet project still gets one upkeep Task a week at the *normal* bar, so upkeep cannot starve |

Waiting Tasks are rows, not running work: they hold no slot, and an urgent Task never queues behind
them. When your own `iu` 5-hour window passes 85 %, normal and upkeep sessions running on `iu` are parked at
their next idle point and resumed later.

**Both accounts walled, production down:** the deterministic parts still run — settle, restart,
rollback, runbooks. Code waits for the first reset.

## The prompt cache

Two Max accounts are two organisations; a cache never crosses them.

- **The account is fixed at spawn** and kept on resume while the cache is warm (under an hour since the
  last turn) or the wall lifts within the hour. After a longer wall the cache is cold anyway, and the
  Task goes back through the picker instead of waiting days for one account.
- **Witness records the account actually in effect**, so a session that a herdr restart moved to the
  other account is accounted correctly.
- **Briefs are stable** at the front, so the standing orders are cache hits on every spawn.

## What it costs

| Line | Measured | Source |
|-|-|-|
| Review | $0.10 a job over 30 days to 2026-10-22; **$2.43 a job** last week, after OCR and the DeepSeek adversary joined ($136 / 56) | `evidence/kpi/cost.out.md`, `evidence/kpi/iu-2026-10-24.md` |
| Investigation | $0.02 a job over 30 days (340 jobs) | `cost.out.md` |
| Decision-model score | $0.0001 a call | `cost.out.md` |
| All personal IU API work | $183 last week | `iu-2026-10-24.md` |

The factory adds 2–6 investigations and 2–4 shipped Tasks a day (estimate; measured from W2).
Investigations are noise in cost. Review is not: at last week's price a full review on every Task is
$35–70 a week. So agent-gateway's review-depth gating — logged since 2026-10-23, off — is switched on
in W2: no LLM review before the make targets pass; none for lockfile, docs or generated-only diffs;
light by default; full for urgent Tasks and for deploy, auth, migration and verification-surface
changes; after a fix-up, only the new delta. Expected IU add-on: **≈ $10–40 a week.**

## Measured from W2

- **Shipped per window:** Tasks verified and held, per 1 % of weekly capacity, per account.
- **Waiting:** hours Tasks waited for capacity, per class, upkeep included.
- **Cache:** cache-read share per account; a cold wake that could have been a warm follow-up is counted.
- **You blocked:** minutes your interactive session waited on a wall. Target 0.
