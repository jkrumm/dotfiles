# ADR-008 — Engine policy: herdr always, engine by class, quota as a control input

- Status: accepted · 2026-10-22 (decides Round 5's one open question)
- Evidence: `evidence/kpi/engine_policy.out.md`, `evidence/kpi/quota.out.md`, `evidence/kpi/cost.out.md`, Round 5 `docs/waves/PLAN.md` §Open

## Context and problem statement

Code is written in herdr (fixed). Two engines exist: Claude Code on the Max subscription and
OpenCode on IU models. Which engine runs which work, and what happens near the quota?

## Numbers

| Fact | Value |
|-|-|
| Max 7-day utilisation p50 / p90 / max | 46 / 96 / 100 % (43.6 days, 12,441 samples) |
| Days with a 7-day peak ≥ 90 % | 12 of 45; Sep 16–20 effectively unavailable |
| Max share of agent cost / of tokens (90 d) | 97.8 % / 32 % |
| Max weekly window in list dollars | ≈ $32 per 1 % (median of 7 complete cycles) |
| agent-gateway's OpenCode workload | $52/week on IU; $783/week at Sonnet list rates |
| That workload moved onto Max | ≈ +24 % of the weekly window: p50 46 → 70 %, p90 96 → 120 % |
| Cost per resolved warden item today | IU $0.36 + Max-equivalent $1.08 (14 d) |

## Considered options

- **A — Claude Code on Max for everything.** Exhausts the window every week (p90 → 120 %) and takes the owner's own sessions down with it.
- **B — herdr always, engine by class, quota guard** (Round 5's recommendation).
- **C — keep implementation in agent-gateway's OpenCode episodes outside herdr.** Violates the fixed rule (herdr is where code gets written) and leaves 326 episodes per 12 days invisible to the owner.

## Decision outcome

**Chosen: B.**

| Work class | Engine |
|-|-|
| Routine fixes (alert remediation, restarts, config, dependency bumps, small bugs), investigate, improve-loop chores | OpenCode on IU, in a herdr tab |
| Features, waves, fleet mothers and leads, judgment-heavy fixes, attempt ≥ 3 escalations | Claude Code on Max |
| Anything non-urgent while the guard is tripped | OpenCode on IU, or deferred to after the reset |

**Quota guard** (a scheduler input, ADR-007's spawner reads it): new Max spawns for non-urgent
classes flip to IU when the 7-day window ≥ 80 %, the 5-hour window ≥ 70 %, or the burn-rate forecast
exhausts the window before the reset; 15 % of the 7-day window stays reserved for the owner's own
sessions. Production incidents run on whichever engine has headroom. Parked agents resume at the
reset by timer (ADR-007). A daily IU budget caps non-urgent IU work.

### Consequences

- Good: the factory never starves the owner's own sessions; IU cost rises by ≈ $52/week of work that moves into herdr, which is the same work agw runs today.
- Bad: two engines inside herdr to keep working (rd already spawns both; `--kind opencode`); quality differs by engine, so the verification ladder (ADR-012) carries the same evidence bar for both.

### Confirmation

Weekly KPIs: days with the 7-day window ≥ 90 % (baseline 12 of 45 → ≤ 2 per month), owner
sessions blocked by the quota (→ 0), share of routine fixes on IU, cost per resolved item by engine.
