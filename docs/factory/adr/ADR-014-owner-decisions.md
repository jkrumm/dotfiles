# ADR-014 — The owner decides business questions only; every decision has a default and an expiry

- Status: accepted · 2026-10-22 · revised after panel pass 1 (dat-6, sre-1, int-4, ux-5, ux-7, dur-7), pass 2 (dat-11, dat-12, dur-4, int-8, int-12, ux-4, sim-6) and the cross-lab review (R13, R17, I4, T2). In the body, `p2` marks a pass-2 id; `R`, `I` and `T` ids are rows of `panel/review-resolutions.md`.
- Evidence: `evidence/kpi/baseline.out.md` (escalated 32.2 % of new items, 14 d; autonomy 64.3 %), `evidence/interventions/interventions.md` (4 of the latest 20 genuine), `evidence/incidents/incidents.md` (577 owner-facing notifications vs 140 decision entries; #9, the disconnected drive, is the one legitimate page), `evidence/DEFINITIONS.md` (item, owner touch), `evidence/golden/` (genuine share on the labelled set), `BRIEF.md` §Fixed

## Context and problem statement

The fixed rule: the owner decides product direction, spend, irreversible data loss and other
people — his own number is "sub 1 %" of items: SLO < 1 %, stretch ≤ 0.1 % (the pre-registration's
long-run target) — and strong verification replaces human gates. Today a third of
new items reach him, most of them obstacle reports and choices an agent could make.

## Decision outcome

0. **What is counted** (dat-6, p2 dat-11, R17). *Item* and *owner touch* are defined once, in
   `evidence/DEFINITIONS.md`, per **lineage root**: every event carries `correlation` = its root id
   (an Incident or the originating Task — or, until it is correlated, the Signal itself,
   `design/model.md` §3 invariant 9), enforced by `emit()`, so his decide, steer, stop and
   re-verify events count on the item they act on and a brief the planner decomposes into N Tasks is
   one root, not N items. Only Incident and Task roots are items. The SLO is owner-touched items ÷
   items; pause (ADR-015) and rule 7's physical-presence asks are outside it.
1. **Decider by class.** `policy` (a written rule), `agent` (the investigating agent or the mother
   wake picks and records why), `owner` (only the four business classes). Security policy is not an
   owner class; this follows the brief and contradicts the global CLAUDE.md, which a migration wave
   aligns. **Product direction is structural, not the agent's judgment** (int-4, p2 int-8): a
   Change touching a manifest `product_surfaces[]` entry is product-class and becomes a Decision
   with a reversible default (ADR-012 rule 9) unless it traces to the owner. *Traces to the owner*
   is a ledger fact: the lineage holds an event with actor `owner` — a submitted brief, or a
   comment or resolve on the plan Artifact; a plan only an agent reviewed does not trace. The
   default applies on expiry, so this is not a gate. Every Decision outcome records the policy line
   or the agent's reason that decided it (p2 dat-12), so a rebuild replays decisions without
   re-reading the policy file.
2. **Every Decision carries options, a reversible default and an expiry** (48 h unless the class
   says otherwise). On expiry the default is taken if it is reversible; otherwise the card is
   re-pushed once and holds. Ack stops re-pushes but does not resolve. Timing (dur-7, p2 dur-4,
   I4, R13): the 48 h clock starts at the card's **creation**; the push service's acceptance
   (ADR-009) only ends that push's retries, so a push that is never accepted cannot hold a card open
   silently — a permanent push failure opens `push.channel_dead` (ADR-009). `decided_at` is the
   factory API's server receipt time; an answer counts only if received before the deadline
   (ADR-002); an answer after the deadline is an override intent with its own generation keys,
   never a decision; a deadline is extended by the factory API's measured downtime across it, and a
   dark mini sends no decision or heads-up push (ADR-009), so a mini outage never fires a default
   the owner could not answer.
   **Pause is not a Decision** (ux-5, p2 ux-4): ADR-015 defines it once; it never enters the
   defaulted-on-expiry KPI.
3. **Every genuine escalation retires a class:** the wave that answers it writes the policy line
   (agent-gateway's `_common.md` today, the policy file of the new loop later), so the same
   question never reaches him twice.
4. **Push tiers:** *decision* (blocking, business only, phone push), *heads-up* (a user-facing SLO
   burning while automation is stuck, or a `needs_hands` outcome — information, no action asked),
   *digest* (everything else, in Argo; the morning and evening briefing is the Home digest plus one
   push carrying an audio link, p2 sim-6). Reminders exist only for the decision tier and stop on
   ack. Every phone push uses the one channel of ADR-009 (ux-7), at-least-once on the decision and
   heads-up tiers, each body self-contained.
5. Obstacle reports ("needs access", "manual host work", "which of two PRs") are never decisions:
   they are capability gaps, filed as Tasks against the factory itself.
6. **`needs_hands`** (sre-1): when a host runbook fails and the observed cause is physical (device
   absent, power, no shutdown record), the outcome is typed `needs_hands` and sent on the heads-up
   tier; it asks for nothing and needs no SLO (incident #9's disconnected drive). The observers are
   the infra reconciler's host reachability, boot-record and mount checks and the host watchdog's
   drive-disconnected report (incident #9, `evidence/incidents/incidents.md`).
7. **Physical presence is not a decision** (p2 int-12, tradeoff below). A biometric credential
   renewal needs a person at a device, not a judgment. It is one ask per credential expiry,
   scheduled from the 7-day lead time and coalesced across credentials, and counted as its own
   KPI — present-human asks per month, ≤ 2 — outside the decision SLO.

### Tradeoff: biometric renewals outside the SLO (p2 int-12)

A weekly batched ask would be ≈ 0.9 % of items (one ask a week against 230 items in 14 days,
`evidence/kpi/baseline.out.md`), nearly the whole < 1 % budget, spent on a class this ADR says never
reaches him. Kept: the ask itself, because only a present human can renew; scheduled by expiry and
coalesced, so it falls to the ≤ 2 a month target. Given up: the SLO no longer counts every owner
interruption; the separate KPI carries that part.

### Consequences

- Good: the owner's queue holds only his questions; each one shrinks the next week's queue; the one legitimate page class (physical host faults) still reaches him, as information; a product change with no owner event in its lineage cannot ship on an agent's judgment.
- Bad: defaults must be written per class; a wrong default costs a revert — acceptable because defaults are reversible by rule; `product_surfaces[]` must be declared per project for the product class to fire; a reversible Decision whose push is never accepted still defaults at its expiry, on a card the owner may never have seen — counted apart as never-acked, with `push.channel_dead` open (ADR-009) — and an irreversible one holds, visible in Needs you; the SLO no longer counts biometric renewals.

### Confirmation

KPIs: owner-touch share < 1 % of items as the SLO, ≤ 0.1 % as the stretch (baseline 35.7 % touched, 14 d; item and touch per rule 0 and `evidence/DEFINITIONS.md`), genuine share of escalations
≥ 90 % (golden set), `owner_pages` per week, decisions defaulted on expiry — split into acked and never-acked cards, so a default taken on a card he never saw is counted (ux-7) — repeated escalation of a
retired class (→ 0), `needs_hands` sent per month, present-human asks per month (≤ 2, rule 7).
Tests: replaying incident #9 yields exactly one `needs_hands`; a Decision created during an
injected egress blackhole has its push accepted once after the egress heals and no default earlier
than 48 h after its creation (ADR-009, I4); with the mini dark and a Decision open (gameday row 13,
T2) no default fires during the downtime and the deadline is extended by the measured downtime; a
Change that edits a declared public route and traces only to a plan Artifact reviewed by an agent
becomes a Decision, one traced to a submitted brief ships.
