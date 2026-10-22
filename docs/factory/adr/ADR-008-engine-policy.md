# ADR-008 — Engine policy: herdr always, engine by class, quota as a control input

- Status: accepted · 2026-10-22 (decides Round 5's one open question) · revised after panel pass 1 (cos-1…cos-8) and pass 2 (cos-7, cos-9…cos-16, dat-12). In the body, `p2` marks a pass-2 id.
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
| agent-gateway's OpenCode workload | $52/week on IU and $783/week at Sonnet list rates over the last 7.8 days (`engine_policy.out.md`); $28/week on IU over 30 days, the D1 base (`forecast.out.md`) |
| That workload moved onto Max | +22–29 % of the weekly window (range over the 7 cycle calibrations) |
| Cost per resolved warden item, 14 d | IU $0.36 + Max-equivalent $1.08 — two regimes mixed; W43 (post-10-15, no Max review): IU $0.12, Max $0 |
| Max per week, today (30 d) → fully running, if mothers and leads ran on Max | **120 % (109–144)** → **142 % (130–170)** of the window (`forecast.out.md`) |
| Burn rate across two resets | 204 % (187–245) over the last 7 calendar days, which span the 10-17 (unscheduled) and 10-21 (scheduled) resets — a burn-rate signal, not a window reading (`forecast.out.md` notes) |
| Who fills Max today | owner-steered fleet waves 74 %, owner-interactive 32 %, agw review on Max 14 % |
| IU per week today | $147 (agw tools $91, agw OpenCode $28, research $18, Hermes $4) |
| Mother and lead wakes at the forecast's assumption | $707 list per week (mothers $442, leads $265; 336 wakes, ≈ $2.11 each) — an assumption, not a measurement; W4b replaces the per-wake cost and the wake rate with measured values (p2 cos-14) |

## Considered options

- **A — Claude Code on Max for everything.** Exhausts the window every week (+22–29 % on a baseline already ≈ 120 %) and takes the owner's own sessions down with it.
- **B — herdr always, engine by class, quota guard** (Round 5's recommendation).
- **C — keep implementation in agent-gateway's OpenCode episodes outside herdr.** Violates the fixed rule (herdr is where code gets written) and leaves 326 episodes per 12 days invisible to the owner.

## Decision outcome

**Chosen: B.**

| Work class | Engine |
|-|-|
| Routine fixes (alert remediation, restarts, config, dependency bumps, small bugs), investigate, improve-loop chores | OpenCode on IU, in a herdr tab |
| Owner-started work: his interactive sessions, waves he starts or steers, the rewrite program's lane A (unattended owner work, p2 cos-12) | Claude Code on Max |
| Factory judgment: mothers (lead wakes included), judgment-heavy fixes, attempt ≥ 3 escalations | **Max only under the inverse rule's condition (guard item 4: headroom at the reset); otherwise OpenCode on IU with a Claude-class model on the IU Anthropic route** |
| Gateway tool calls (agw review, check, prose, read_image, read_drawing) | Max while the projection allows, IU otherwise (cos-3) |
| Non-urgent IU-class work in the last hours of a light cycle (inverse rule) | Claude Code on Max |

What a trip does to each class is the victim order below, not a row here.

**Capacity forecast** (cos-1). `evidence/kpi/forecast.py` maps per-class weekly tokens → engine →
Max %/week and IU $/week, today and fully running. Its verdict: owner-started work alone (fleet waves
74 % + interactive 32 %) already fills the window, so **Max has no standing room for factory work** —
putting mothers and leads on Max would take it to 142 % (130–170). Factory judgment therefore runs on
IU unless the projection shows lapsing capacity (the inverse rule). Its IU cost is business decision
D1 and the owner-started spillover to IU is D2 (report §10). W4b sets the per-wake token budget at
the first week's measured p90 × 1.5 and replaces the forecast's wake rate with the planner's
measured trigger rate; D1 is re-issued from both (p2 cos-14).

**Quota guard.** This section is the only statement of the guard (p2 cos-11); other documents link
here. It is a forecast, level-triggered over every Max consumer and evaluated by the spawner's
admission module (ADR-007 §3). Its parameters — owner-rate percentile, margin, evaluation
interval — live once in warden's admission config and a generated block (built in W4b) renders them
here; W4b's gate tests this version.

1. **Projection, not reserve** (cos-2, cos-8, p2 cos-10). Each evaluation projects window use at the
   next reset: the current reading + the owner's in-cycle burn (p90 rate × hours to the reset) +
   the burn of running and admitted agents. The owner term shrinks toward the reset, so the rule
   that holds factory work early in a cycle admits it late in a light cycle. It covers the 7-day
   and the 5-hour window; there is no fixed 80 % or 5-hour 70 % trip (the 5-hour one never fired
   on data) and no fixed reserve — a reserve sized to the owner's p90 (interactive 66 %) plus the
   waves he steers (74 %) is already over the window. Inputs are `quota.sampled` and
   `usage.recorded` events (ADR-013).
2. **Trip and victim order** (p2 cos-9, cos-3). The guard trips when the projection reaches 100 % of
   the window at the reset and sheds from the bottom of this table — running agents (waves, fan
   tabs, workers) as well as new spawns. The same order admits resumes (item 3).

   | Priority | Class | At a trip |
   |-|-|-|
   | 1 | Production incident work | never shed; runs on whichever engine has headroom |
   | 2 | Owner interactive sessions | stay on Max |
   | 3 | Waves he is attending (he has messaged the wave in its current session; `owner.message`, ADR-013) | stay on Max |
   | 4 | Unattended owner waves, the rewrite program's lane A included | checkpoint to the hook and continue on IU with a Claude-class model — not parked |
   | 5 | Fleet work: mothers (lead wakes included), workers, gateway calls on Max | move to IU (mothers at their next wake) or checkpoint to the hook and park |
   | 6 | Improve-loop chores | park |

   When rows 1–3 alone project past 100 %, nothing further can be shed; the blocked hours are the
   trigger D2 watches (report §10).
3. **Resume** goes through the admission module in that priority order, at a token rate equal to the
   projected headroom ÷ hours to the next reset (converted to tokens by the weekly calibration),
   recomputed each evaluation. No timer fires at a reset, scheduled or unscheduled, so resumes
   never burst (cos-4).
4. **Inverse rule** (cos-7, p2 cos-10): when the projection at the reset is below 100 % − margin,
   non-urgent IU-class work spawns on Max; prepaid capacity is not left to lapse. The owner term
   shrinks toward the reset, so the rule fires in the last hours of a light cycle (3 of 7 complete
   cycles peaked at 55–79 %).
5. **Two IU meters, tagged by the spawner** (cos-5, p2 cos-13): *factory-originated* IU — D1, base
   ≈ $28/week of agw OpenCode work (`forecast.out.md`), stated in mother wakes per day — and
   *spillover*, owner-started work paid in IU cash: unattended owner waves moved at a trip, gateway
   calls moved off Max, the rewrite program's IU spend (p2 mig-3). Spillover is D2's and is never
   charged to D1.
6. **Budgets are tokens, not Max %** (p2 cos-15): per-Task, per-lineage and per-wake budgets count
   engine-tagged tokens (ADR-012 rule 12); the guard's Max % and the $/1 % calibration are forecast
   inputs and display, never a budget unit. $/1 % is recalibrated weekly and engine-move impacts
   are stated as ranges (cos-8).
7. **Every verdict is an event** (p2 dat-12): `agent.spawn_decided{engine, guard_verdict, forecast}`
   carries the inputs it read, so a rebuild replays verdicts and a recalibration changes later
   ones, never recorded ones.

**Cost per resolved item** (cos-6) is reported per action class × engine, attributed through Agent
records, baseline from the post-10-15 regime. The interim ceiling is 3 × baseline p90 per class in
engine-tagged tokens (p2 cos-15), so a class that runs on Max has one although its Max dollar
baseline is $0; it is fed to the lineage budget (ADR-012 rule 12). A class with no baseline
(mother wakes, herdr OpenCode tabs) starts at its first week's measured p90 × 1.5 (p2 cos-14); the
8-week revisit in `design/proof.md` §3 tightens both.

### Consequences

- Good: the owner's interactive sessions and attended waves are never shed, and unattended owner work continues on IU instead of parking; prepaid Max capacity stops lapsing in the last hours of light cycles; routine work moves into herdr at no change in cost (≈ $52/week on IU over the last 7.8 days, the same work agw runs today); the IU cash the design adds is metered twice, factory judgment (D1) and spillover (D2).
- Bad: two engines inside herdr to keep working (rd already spawns both; `--kind opencode`); quality differs by engine, so the verification ladder (ADR-012) carries the same evidence bar for both; the guard depends on `forecast.py` staying calibrated; the guard now spends IU cash on owner-started work in code — declared in the victim order and priced in D2 instead of left implicit.

### Confirmation

Before W4b ships the guard, `forecast.py` replays the 7 complete cycles through it (quota samples
plus per-class burn from usage.db): trip time, hours parked and hours moved to IU per class,
owner-interactive minutes blocked at 100 %, inverse-rule firings and the lapsed % they recover. The
result goes to `evidence/kpi/forecast.out.md` and sets the margin and the lapsed target (p2 cos-10).
On one W4b gameday Task the budget check fires from live usage within one tool turn of the cap
(p2 cos-15). Gameday row 8 (`design/proof.md`) asserts the behaviour: running non-urgent Max
agents park or move to IU, owner-interactive spawns are still admitted, and post-reset admission
stays at or below the forecast token rate with no burst.

Weekly KPIs: owner interactive sessions blocked by the quota per cycle (→ 0); unattended owner
waves parked by the guard (→ 0, they move to IU); spillover IU cash per week (D2 meter) and
factory-originated IU cash per week with mother wakes per day (D1 meter); Max lapsed % at the reset
(today p50 4 %, p90 31 %; the target is fixed by the backtest, not asserted); share of routine
fixes on IU; cost per resolved item per action class × engine against its ceiling; forecast error
at the reset.
