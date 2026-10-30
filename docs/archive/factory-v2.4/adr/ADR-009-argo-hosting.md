# ADR-009 — Argo runs split: the factory read API on the mini, the SPA and life data on the VPS

> **v2 status (2026-10-24):** superseded — Argo all on the mini (TDD v2 §10). The text below is v1 history.

- Status: accepted · 2026-10-22 · revised after panel pass 1 (ux-1, ux-3, ux-7, sre-3), pass 2 (ux-1, dur-4, dat-13, ver-7; carry-through of pass-1 dat-5) and the cross-lab review (R13, I4, T2). In the body, `p2` marks a pass-2 id; `R`, `I` and `T` ids are rows of `panel/review-resolutions.md`.
- Evidence: Argo/basalt-ui inventory (Explore, 2026-10-22; `design/argo.md` §4), `evidence/questions/questions.md` (Q1: 41 of 50 nudges from the MacBook), `last reboot` on the mini (2 reboots since 2026-08-29), `evidence/signals/signals.md` (Kuma is one instance, on the homelab), `evidence/incidents/incidents.md` #1 (the mini's recurring DNS/egress failure: 7 h night, 31 alerts)

## Context and problem statement

Argo today runs on the VPS (Elysia/Bun API, Postgres 18, static SPA, tailnet-only). Everything
the cockpit needs is born on the mini — the ledger, herdr, OpenCode, usage.db, Hermes — and
reaches the VPS as snapshots every 10–15 minutes; warden is loopback-only, so owner actions go
through a pull queue; live agent state is impossible. The owner's most frequent questions are
about live agents ("parked?", "stuck or done?", "where are we?"). Argo also hosts the life pages
(Garmin, strength, body, reading, walking pad), whose data and crons live on the VPS.

The owner asked whether Argo should "move to local mini instead of needing APIs for everything".
Measured against that criterion:
- **Today:** Argo depends on four push paths (agw overview, warden snapshot and action queue,
  usage-tracker records, hermes narratives) plus a pull queue for actions.
- **C:** replaces all of them with one read API on the mini, which reads the ledger in place.
- **B:** would remove that last API as well, but the mini would then take the life pages down with it.

## Decision drivers

Fewer APIs (the owner's criterion); answer from live data where it lives; keep the life pages up when the mini is down; never show
stale numbers as current; delete pushes rather than add relays; an off-site dead-man's switch.

## Considered options

- **A — all on the VPS (today).** Every factory answer pays a 10-minute relay; actions go through a pull queue.
- **B — all on the mini.** Live data, but a mini outage takes the whole of Argo, life pages included; the mini shares power with the homelab and rebooted twice since Aug 29.
- **C — split.** The SPA and the life API stay on the VPS; a factory read API runs on the mini beside the ledger; the browser (MacBook, phone — both reach the mini over the tailnet) composes them.

## Decision outcome

**Chosen: C.**
- The factory read API on the mini serves the read models of `design/argo.md` §2 from the ledger
  alone (read-only): herdr state, quota and usage reach it as events through ADR-013's adapters, so
  it never opens the herdr socket or usage.db (dat-5). A read model with no event source is a
  labelled live probe, not a projection (`design/argo.md`): it renders with `as_of` and feeds no
  KPI or control input (p2 dat-13). Owner actions write intents through the same API (no pull
  queue; ADR-015).
- **Both herdr hosts** (ux-1, p2 ux-1): the MacBook herdr observer pushes to the mini's ingest when
  online, so MacBook agents (shutterflow's fleet) appear in the same read models, and its actuator
  makes resume, steer and stop work on them (ADR-007 §8); while the laptop is closed they render
  `host_asleep since hh:mm`, never `0 parked`.
- **Freshness per source** (ux-3): every read model returns `as_of` and its cadence; a stale source
  renders as a stale term in place of its value; "all up" needs every health source fresh.
- Deleted: agw's overview push, warden's snapshot push and action queue, usage-tracker's record
  push to Argo, the hermes narrative push (each becomes a read of the ledger or its projections).
- When the mini is unreachable the cockpit says so — "mini unreachable since 20:49" — from the VPS
  half, never stale numbers.
- **Dead-man's switch on the VPS:** a receiver expects the mini's 5-minute heartbeat and the
  homelab's, and pushes to the phone after 15 minutes of silence. Kuma on the homelab cannot do it:
  same house, same power.
- **Egress probe in the heartbeat** (sre-3): the mini's heartbeat payload carries the result of an
  egress probe (DNS resolution and an outbound fetch), so the VPS tells "mini dead" (silence) from
  "mini alive, egress dead" (heartbeat arrives, probe failed). The latter is the `infra.egress`
  condition for the factory host, healed by a network-independent runbook on the mini (flush the
  DNS cache, restart mDNSResponder, fail over to a secondary resolver); attempt failures during an
  open egress condition are classed infra, not task failures (how they count: ADR-012 rule 11).
- **One push channel** (ux-7): Argo installed as a Home-Screen PWA, web push sent from the VPS half;
  every push body is self-contained.
  - **What works with the mini dark** (R13): the dead-man push, and only that — it originates on the
    VPS. Decision and heads-up pushes originate on the mini (its effector records the delivery, the
    VPS half sends it), so none is sent while the mini is dark, and open Decisions' deadlines are
    extended by the downtime (ADR-014 rule 2).
  - Decision and heads-up pushes are **at-least-once** (p2 dur-4): the delivery state in
    `deliveries` goes `pending` → `accepted` (the push service took it) and is retried until
    accepted, egress outages included; the phone de-duplicates on the event id. Acceptance only ends
    the retries; it does not start a Decision's clock (I4, ADR-014 rule 2). The other pushes (the
    briefing) stay at-most-once with a receipt (ADR-002).
  - **A push that is never accepted does not stay pending silently** (I4): a permanent failure — the
    push service rejecting the subscription or the sender's key, as against an outage — opens
    `push.channel_dead`, a factory-self Condition filed as a Task against the factory; it closes when
    the push service accepts a push again. The Decisions behind such pushes still default at their
    expiry (ADR-014).
  - Fallback if PWA push proves unreliable: a self-hosted push service on the VPS.

### Consequences

- Good: every cockpit question is answered from live data, MacBook agents included; four push paths and their failure modes disappear; a dead collector shows as stale, not as a confident "all up"; a Decision card is not lost to an outage between the ledger and the phone, and a dead push channel is a Condition, not a silent pending.
- Bad: two backends behind one SPA (two base URLs, two bearer secrets — inside the tailnet boundary); the factory API is new code on the mini; iOS web push requires the Home-Screen install; the MacBook actuator is a second small component to keep alive; with the mini dark only the dead-man push is sent, and the decision and heads-up pushes wait for the mini's return.

### Confirmation

The timed Argo test (`design/argo.md` §6) passes from the phone and the desktop; gameday row 13
(`design/proof.md`, T2) darkens the mini with a Decision open and asserts the dead-man push within
15 minutes as the only push sent, and the "unreachable since" line in Argo (the same run asserts the
Decision's extended deadline, ADR-014); gameday row 15 (resolver blackhole on the mini) shows "egress
dead" on the VPS, opens `infra.egress` and heals it by runbook with 0 owner touches; a stopped
collector renders as stale within one cadence. Push delivery: a Decision created during the
blackhole, and separately the effector killed between the `deliveries` insert and the send, 20
times, ends with the push accepted after the egress heals and shown once on the device (p2 dur-4);
a push the push service rejects permanently opens `push.channel_dead` while its Decision still
defaults at its expiry from creation (I4).
