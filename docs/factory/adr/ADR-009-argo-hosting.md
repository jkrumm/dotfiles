# ADR-009 — Argo runs split: the factory read API on the mini, the SPA and life data on the VPS

- Status: accepted · 2026-10-22
- Evidence: Argo/basalt-ui inventory (Explore, 2026-10-22; `design/argo.md` §4), `evidence/questions/questions.md`, `last reboot` on the mini (2 reboots since 2026-08-29), `evidence/signals/signals.md` (Kuma is one instance, on the homelab)

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
  ledger (read-only), herdr's live state and usage.db; owner actions write Decisions through the
  same API (no pull queue).
- Deleted: agw's overview push, warden's snapshot push and action queue, usage-tracker's record
  push to Argo, the hermes narrative push (each becomes a read of the ledger or its projections).
- When the mini is unreachable the cockpit says so — "mini unreachable since 20:49" — from the VPS
  half, never stale numbers.
- **Dead-man's switch on the VPS:** a receiver expects the mini's 5-minute heartbeat and the
  homelab's, and pushes to the phone after 15 minutes of silence. Kuma on the homelab cannot do it:
  same house, same power.

### Consequences

- Good: every cockpit question is answered from live data; four push paths and their failure modes disappear.
- Bad: two backends behind one SPA (two base URLs, two bearer secrets — inside the tailnet boundary); the factory API is new code on the mini.

### Confirmation

The timed Argo test (`design/argo.md` §6) passes from the phone and the desktop; a gameday that
stops the mini shows the dead-man push within 15 minutes and the "unreachable since" line in Argo.
