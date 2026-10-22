# ADR-009 — Argo runs split: the factory read API on the mini, the SPA and life data on the VPS

- Status: accepted · 2026-10-22 · revised after panel pass 1 (ux-1, ux-3, ux-7, sre-3)
- Evidence: Argo/basalt-ui inventory (Explore, 2026-10-22; `design/argo.md` §4), `evidence/questions/questions.md` (Q1: 41 of 50 nudges from the MacBook), `last reboot` on the mini (2 reboots since 2026-08-29), `evidence/signals/signals.md` (Kuma is one instance, on the homelab), `evidence/incidents/incidents.md` #1 (the mini's recurring DNS/egress failure: 7 h night, 31 alerts)

## Context and problem statement

Argo today runs on the VPS (Elysia/Bun API, Postgres 18, static SPA, tailnet-only). Everything
the cockpit needs is born on the mini — the ledger, herdr, OpenCode, usage.db, Hermes — and
reaches the VPS as snapshots every 10–15 minutes; warden is loopback-only, so owner actions go
through a pull queue; live agent state is impossible. The owner's most frequent questions are
about live agents ("parked?", "stuck or done?", "where are we?"). Argo also hosts the life pages
(Garmin, strength, body, reading, walking pad), whose data and crons live on the VPS.

## Decision drivers

Answer from live data where it lives; keep the life pages up when the mini is down; never show
stale numbers as current; delete pushes rather than add relays; an off-site dead-man's switch.

## Considered options

- **A — all on the VPS (today).** Every factory answer pays a 10-minute relay; actions go through a pull queue.
- **B — all on the mini.** Live data, but a mini outage takes the whole of Argo, life pages included; the mini shares power with the homelab and rebooted twice since Aug 29.
- **C — split.** The SPA and the life API stay on the VPS; a factory read API runs on the mini beside the ledger; the browser (MacBook, phone — both reach the mini over the tailnet) composes them.

## Decision outcome

**Chosen: C.**
- The factory read API on the mini serves the read models of `design/argo.md` §2 straight from the
  ledger (read-only), herdr's live state and usage.db; owner actions write intents through the
  same API (no pull queue; ADR-015).
- **Both herdr hosts** (ux-1): the MacBook's herdr event recorder pushes to the mini's ingest when
  online, so MacBook agents (shutterflow's fleet) appear in the same read models; while the laptop
  is closed they render `host_asleep since hh:mm`, never `0 parked`.
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
  open egress condition are classed infra, not task failures.
- **One push channel** (ux-7): Argo installed as a Home-Screen PWA, web push sent from the VPS half,
  so decision, heads-up and dead-man pushes work with the mini dark; every push body is
  self-contained. Fallback if PWA push proves unreliable: a self-hosted push service on the VPS.

### Consequences

- Good: every cockpit question is answered from live data, MacBook agents included; four push paths and their failure modes disappear; a dead collector shows as stale, not as a confident "all up".
- Bad: two backends behind one SPA (two base URLs, two bearer secrets — inside the tailnet boundary); the factory API is new code on the mini; iOS web push requires the Home-Screen install.

### Confirmation

The timed Argo test (`design/argo.md` §6) passes from the phone and the desktop; a gameday that
stops the mini shows the dead-man push within 15 minutes and the "unreachable since" line in Argo;
gameday row 15 (resolver blackhole on the mini) shows "egress dead" on the VPS, opens
`infra.egress` and heals it by runbook with 0 owner touches; a stopped collector renders as stale
within one cadence.
