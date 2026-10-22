# ADR-014 — The owner decides business questions only; every decision has a default and an expiry

- Status: accepted · 2026-10-22
- Evidence: `evidence/kpi/baseline.out.md` (escalated 32.2 % of new items, 14 d; autonomy 64.3 %), `evidence/interventions/interventions.md` (4 of the latest 20 genuine), `evidence/incidents/incidents.md` (577 owner-facing notifications vs 140 decision entries), `evidence/golden/` (genuine share on the labelled set), `BRIEF.md` §Fixed

## Context and problem statement

The fixed rule: the owner decides product direction, spend, irreversible data loss and other
people — target ≤ 0.1 % of items — and strong verification replaces human gates. Today a third of
new items reach him, most of them obstacle reports and choices an agent could make.

## Decision outcome

1. **Decider by class.** `policy` (a written rule), `agent` (the investigating or leading agent
   picks and records why), `owner` (only the four business classes). Security policy is not an
   owner class; this follows the brief and contradicts the global CLAUDE.md, which a migration wave
   aligns.
2. **Every Decision carries options, a reversible default and an expiry** (48 h unless the class
   says otherwise). On expiry the default is taken if it is reversible; otherwise the card is
   re-pushed once and holds. An answer counts only if it arrives before the deadline (ADR-002). Ack
   stops re-pushes but does not resolve.
3. **Every genuine escalation retires a class:** the wave that answers it writes the policy line
   (agent-gateway's `_common.md` today, the policy file of the new loop later), so the same
   question never reaches him twice.
4. **Push tiers:** *decision* (blocking, business only, phone push), *heads-up* (a user-facing SLO
   burning while automation is stuck — information, no action asked), *digest* (everything else, in
   Argo). Reminders exist only for the decision tier and stop on ack.
5. Obstacle reports ("needs access", "manual host work", "which of two PRs") are never decisions:
   they are capability gaps, filed as Tasks against the factory itself.

### Consequences

- Good: the owner's queue holds only his questions; each one shrinks the next week's queue.
- Bad: defaults must be written per class; a wrong default costs a revert — acceptable because defaults are reversible by rule.

### Confirmation

KPIs: owner-touch share ≤ 0.1 % of items (baseline 35.7 % touched, 14 d), genuine share of escalations
≥ 90 % (golden set), `owner_pages` per week, decisions defaulted on expiry, repeated escalation of a
retired class (→ 0).
