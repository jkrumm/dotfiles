# ADR-014 — The owner decides business questions only; every decision has a default and an expiry

- Status: accepted · 2026-10-22 · revised after panel pass 1 (dat-6, sre-1, int-4, ux-5, ux-7, dur-7)
- Evidence: `evidence/kpi/baseline.out.md` (escalated 32.2 % of new items, 14 d; autonomy 64.3 %), `evidence/interventions/interventions.md` (4 of the latest 20 genuine), `evidence/incidents/incidents.md` (577 owner-facing notifications vs 140 decision entries; #9, the disconnected drive, is the one legitimate page), `evidence/DEFINITIONS.md` (item, owner touch), `evidence/golden/` (genuine share on the labelled set), `BRIEF.md` §Fixed

## Context and problem statement

The fixed rule: the owner decides product direction, spend, irreversible data loss and other
people — his own number is "sub 1 %" of items: SLO < 1 %, stretch ≤ 0.1 % (the pre-registration's
long-run target) — and strong verification replaces human gates. Today a third of
new items reach him, most of them obstacle reports and choices an agent could make.

## Decision outcome

0. **What is counted** (dat-6). *Item* = an Incident, or a Task the owner did not originate.
   *Owner touch* = an event with actor `owner` on an item he did not originate, excluding
   `*.created`; pause is excluded. The SLO is owner-touched items ÷ items.
1. **Decider by class.** `policy` (a written rule), `agent` (the investigating or leading agent
   picks and records why), `owner` (only the four business classes). Security policy is not an
   owner class; this follows the brief and contradicts the global CLAUDE.md, which a migration wave
   aligns. **Product direction is structural, not the agent's judgment** (int-4): a Change touching
   a manifest `product_surfaces[]` entry that does not trace to an owner-submitted brief or a
   reviewed plan Artifact is product-class and becomes a Decision with a reversible default
   (ADR-012).
2. **Every Decision carries options, a reversible default and an expiry** (48 h unless the class
   says otherwise). On expiry the default is taken if it is reversible; otherwise the card is
   re-pushed once and holds. Ack stops re-pushes but does not resolve. Timing (dur-7):
   `decided_at` is the factory API's server receipt time; an answer counts only if received before
   the deadline (ADR-002); an answer after the deadline is an override intent with its own
   generation keys, never a decision; a deadline is extended by the factory API's measured downtime
   across it, so a mini outage never fires a default the owner could not answer.
   **Pause is not a Decision** (ux-5): it is a desired-state override in the project runtime record
   (ADR-015) — never a card, never an owner touch, never in the defaulted-on-expiry KPI.
3. **Every genuine escalation retires a class:** the wave that answers it writes the policy line
   (agent-gateway's `_common.md` today, the policy file of the new loop later), so the same
   question never reaches him twice.
4. **Push tiers:** *decision* (blocking, business only, phone push), *heads-up* (a user-facing SLO
   burning while automation is stuck, or a `needs_hands` outcome — information, no action asked),
   *digest* (everything else, in Argo). Reminders exist only for the decision tier and stop on ack.
   One channel carries every phone push (ux-7): Argo as a Home-Screen PWA with web push sent from
   the VPS half (ADR-009), each push body self-contained.
5. Obstacle reports ("needs access", "manual host work", "which of two PRs") are never decisions:
   they are capability gaps, filed as Tasks against the factory itself.
6. **`needs_hands`** (sre-1): when a host runbook fails and the observed cause is physical (device
   absent, power, no shutdown record), the outcome is typed `needs_hands` and sent on the heads-up
   tier; it asks for nothing and needs no SLO (incident #9's disconnected drive).

### Consequences

- Good: the owner's queue holds only his questions; each one shrinks the next week's queue; the one legitimate page class (physical host faults) still reaches him, as information.
- Bad: defaults must be written per class; a wrong default costs a revert — acceptable because defaults are reversible by rule; `product_surfaces[]` must be declared per project for the product class to fire.

### Confirmation

KPIs: owner-touch share < 1 % of items as the SLO, ≤ 0.1 % as the stretch (baseline 35.7 % touched, 14 d; item and touch per rule 0 and `evidence/DEFINITIONS.md`), genuine share of escalations
≥ 90 % (golden set), `owner_pages` per week, decisions defaulted on expiry, repeated escalation of a
retired class (→ 0), `needs_hands` sent per month.
