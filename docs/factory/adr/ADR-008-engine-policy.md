# ADR-008 — Engine policy: herdr always, engine by class, quota as a control input

- Status: accepted · 2026-10-22 (decides Round 5's one open question) · revised after panel pass 1 (cos-1…cos-8)
- Evidence: `evidence/kpi/engine_policy.out.md` (+ `.out.json` per-cycle calibration), `evidence/kpi/quota.out.md`, `evidence/kpi/cost.out.md`, `evidence/kpi/forecast.out.md` (cos-1), Round 5 `docs/waves/PLAN.md` §Open

## Context and problem statement

Code is written in herdr (fixed). Two engines exist: Claude Code on the Max subscription and
OpenCode on IU models. Which engine runs which work, and what happens near the quota?

## Numbers

| Fact | Value |
|-|-|
| Max 7-day utilisation p50 / p90 / max | 46 / 96 / 100 % (43.6 days, 12,441 samples) |
| Days with a 7-day peak ≥ 90 % | 12 of 45; Sep 16–20 effectively unavailable |
| Max share of agent cost / of tokens (90 d) | 97.8 % / 32 % |
| Max weekly window in list dollars | ≈ $32 per 1 % (median of 7 complete cycles; range $26.86–35.29, recalibrated weekly) |
| Max list-equivalent spend, last 30 d | $16,552 ≈ 120 % of one weekly window per calendar week — fitted only because 2 of 8 resets were unscheduled and Max was down Sep 16–20 |
| Owner-interactive Claude Code on Max, last 30 d | $4,364 ≈ 31.6 % of a weekly window per week (mean); per cycle normalised to 7 d: p50 33.5 %, p90 66 % (`forecast.out.json`, `owner_interactive_share_of_window_pct`) |
| 5-hour window, highest reading | 70 % (heartbeat), 30 % (fetch_usage) — never near a limit |
| Complete cycles that lapsed capacity | 3 of 7 peaked at 55–79 % |
| agent-gateway's OpenCode workload | $52/week on IU; $783/week at Sonnet list rates |
| That workload moved onto Max | +22–29 % of the weekly window (range over the 7 cycle calibrations) |
| Cost per resolved warden item, 14 d | IU $0.36 + Max-equivalent $1.08 — two regimes mixed; W43 (post-10-15, no Max review): IU $0.12, Max $0 |
| Max per week, today (30 d) → fully running, if mothers and leads ran on Max | **120 % (109–144)** → **142 % (130–170)** of the window; the last 7 days ran at 204 % (`forecast.out.md`) |
| Who fills Max today | owner-steered fleet waves 74 %, owner-interactive 32 %, agw review on Max 14 % |
| IU per week today | $147 (agw tools $91, agw OpenCode $28, research $18, Hermes $4) |
| Mother and lead wakes at the forecast's assumption | $707 list per week (mothers $442, leads $265; 336 wakes, ≈ $2.11 each) — an assumption, not a measurement |

## Considered options

- **A — Claude Code on Max for everything.** Exhausts the window every week (+22–29 % on a baseline already ≈ 120 %) and takes the owner's own sessions down with it.
- **B — herdr always, engine by class, quota guard** (Round 5's recommendation).
- **C — keep implementation in agent-gateway's OpenCode episodes outside herdr.** Violates the fixed rule (herdr is where code gets written) and leaves 326 episodes per 12 days invisible to the owner.

## Decision outcome

**Chosen: B.**

| Work class | Engine |
|-|-|
| Routine fixes (alert remediation, restarts, config, dependency bumps, small bugs), investigate, improve-loop chores | OpenCode on IU, in a herdr tab |
| Owner-started work: his interactive sessions, waves he starts or steers | Claude Code on Max |
| Factory judgment: mothers, leads, judgment-heavy fixes, attempt ≥ 3 escalations | **Max-eligible only when the forecast shows headroom after the owner's reserve; otherwise OpenCode on IU with a Claude-class model on the IU Anthropic route** |
| Anything non-urgent while the guard is tripped | OpenCode on IU, or deferred to after the reset |
| Non-urgent IU-class work while the forecast shows lapsing Max capacity (inverse rule) | Claude Code on Max |

**Capacity forecast** (cos-1). `evidence/kpi/forecast.py` maps per-class weekly tokens → engine →
Max %/week and IU $/week, today and fully running. Its verdict: owner-started work alone (fleet waves
74 % + interactive 32 %) already fills the window, so **Max has no standing room for factory work** —
putting mothers and leads on Max would take it to 142 % (130–170). Factory judgment therefore runs on
IU unless the forecast shows lapsing capacity (the inverse rule); its IU cost is the business decision
D1 (report §10). W4 acceptance: a per-mother token budget, enforced by the spawner.

**Quota guard** — a forecast check, level-triggered over every Max consumer (a scheduler input;
ADR-007's spawner and admission queue read it):

1. **Trip** when the burn-rate forecast of factory + owner projection reaches 100 % of the window
   at the reset. The forecast covers both the 7-day and the 5-hour window; there is no fixed 80 %
   or 5-hour 70 % trip (the 5-hour one never fired on data) (cos-2, cos-8).
2. **Owner reserve** derived from data: the owner-started share per cycle — interactive p50 33.5 %,
   p90 66 % of a 7-day window — plus the waves he steers; not a fixed 15 % (cos-2).
3. **At the trip** running non-urgent Max agents — waves, fan tabs and workers included, not only
   new spawns — checkpoint to their hook and park; mothers and leads restart on IU at their next
   wake; gateway calls on Max (agw review) follow the same class table (cos-3).
4. **Resume** goes through ADR-007's admission queue (incident > owner-started > fleet > improve)
   at a token rate the forecast sets — no burst at the reset, scheduled or unscheduled (cos-4).
5. **Inverse rule:** when the forecast at the reset is below 100 % − reserve − margin, non-urgent
   IU-class work spawns on Max; prepaid capacity is not left to lapse (cos-7).
6. **Calibration:** $/1 % recalibrated weekly; engine-move impacts are stated as ranges (cos-8).

Production incidents run on whichever engine has headroom. The IU budget meters factory-originated
(spawner-tagged), non-urgent IU cash; its default comes from the `forecast.py` projection (D1,
cos-5).

**Cost per resolved item** (cos-6) is reported per action class × engine, attributed through Agent
records, baseline from the post-10-15 regime; interim ceiling 3 × baseline p90 per class, fed to
the lineage budget (ADR-012).

### Consequences

- Good: the factory never starves the owner's own sessions, and prepaid Max capacity stops lapsing; IU cost rises by ≈ $52/week of work that moves into herdr, which is the same work agw runs today.
- Bad: two engines inside herdr to keep working (rd already spawns both; `--kind opencode`); quality differs by engine, so the verification ladder (ADR-012) carries the same evidence bar for both; the guard depends on `forecast.py` staying calibrated.

### Confirmation

Weekly KPIs: owner sessions blocked by the quota per cycle (→ 0), Max lapsed % at the reset
(today p50 4 %, p90 31 % lapsed at the reset; target p90 ≤ 5 % through the inverse rule), share of routine fixes on IU, cost per resolved
item per action class × engine against its ceiling, forecast error at the reset.
