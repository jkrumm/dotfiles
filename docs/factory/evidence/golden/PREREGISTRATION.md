# Backtest pre-registration

Committed before any golden-set label existed (2026-10-22, see `git log` of this file).
The backtest (`evidence/golden/backtest.py`, Phase 6) is judged against these thresholds
and nothing else. Changing a threshold after labels exist requires a new dated section
that states why, and the report shows both.

## What is scored

The proposed intake path — fingerprint refinement → topology and time-window
correlation → candidate gate → known-error match → escalation policy — runs over the
golden set's events in time order, seeing only data with `first_seen` ≤ the event's own
time (no look-ahead). Its output per event: incident group, escalate (y/n), known-error
match (incident id or none). The same scoring runs on today's warden behaviour
(its recorded `duplicate_of`/attach links and `needs_decision` transitions) as the
baseline.

## Estimators

- Grouping: entity-centric B-cubed precision and recall (per-element, averaged over
  sampled elements, inverse-probability weighted by the sampling design in
  `sample.out.json`), plus pairwise and cluster metrics for reference only.
- Escalation: precision and recall against `genuine_owner_decision = y`, over escalated
  and non-escalated items alike.
- Uncertain labels: scored both ways (as labelled, and flipped); a threshold passes only
  if it passes under both.

## Thresholds

| Metric | Pass | Baseline must be reported |
|-|-|-|
| B-cubed precision (grouping) | ≥ 0.90 | yes |
| B-cubed recall (grouping) | ≥ 0.80 | yes |
| B-cubed F1 vs today's warden | strictly higher | — |
| Escalation recall (genuine owner decisions escalated) | 1.00 — no genuine decision auto-closed; one miss allowed only if its label is `uncertain` | yes |
| Escalation precision (escalations that are genuine) | ≥ 0.80 | yes |
| Owner-touch share of items, sampling-weighted | ≤ 1 % (long-run target 0.1 %) | yes |
| Known-error match on `known_fix = y` items | ≥ 0.50 matched to the right prior incident | yes |
| Known-error false match on `known_fix = n` items | ≤ 0.05 | yes |

## Not allowed

- Tuning rules on the full golden set. Rules are fitted on a development split (the
  chunks whose index is even) and scored once on the held-out odd chunks; the report
  gives both numbers.
- Dropping events from scoring after seeing results.

## Amendment 2026-10-22 — the join reading for uncertain grouping labels

Thresholds above are unchanged. Why: the panel (pass 1, cor-5) showed the uncertain-label rule
covers one direction only. A grouping-uncertain event is flipped by detaching it into a singleton
(`backtest.py`, `flipped_gold_groups`), which tests "gold over-merged" and never "gold
under-merged"; with 185 uncertain labels (`agreement.out.md`) that is not the worst case, and the
held-out flipped recall rising to 0.881 against 0.846 labelled (`backtest.out.md` §1) is partly
an artefact of shrinking gold groups.

- **Future samples** (the fresh post-cutover sample and every later one) score grouping under
  three readings: *labelled*, *detach* (the existing flip) and *join* — each group-uncertain event
  joins the alternative group its `why_uncertain` names, or, where none is named, the nearest gold
  group in time. A grouping threshold passes only if it passes under all three.
- **The current held-out pass** (`backtest.out.md`, held-out passes recorded: 1) holds under the
  labelled and detach readings only. It is not re-scored under *join*: the held-out is spent.
- `backtest.out.md` and the report show the readings side by side.
