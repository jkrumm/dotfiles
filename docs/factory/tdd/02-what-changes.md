# 2. What changes for you

## Day to day, once it runs

- **You keep working in herdr exactly as now.** `c`, `rd wave`, `/wave` and your own sessions stay.
  The picker already balances `iu` and `me`; nothing you start ever lands on IU tokens.
- **You ask for work in one sentence.** "Add X to weatherorb" in Argo, to Hermes in Slack, or
  `factory issue new weatherorb "…"`. The factory plans it, puts it in the queue, a Claude Code
  session builds it in herdr, verification ships it. You see it in the morning briefing.
- **You look at one place.** Argo on the mini: *Now* (anything that needs you — usually nothing),
  *Projects*, *Factory* (what runs, what waits for capacity), *Health*, *Usage*, *Traffic*,
  *Artifacts*, *Briefing*.
- **You get pinged for two things.** A decision card that is genuinely yours, and the 07:00 briefing.
  The briefing is an Argo page with an optional audio version; there is no evening briefing.
- **Every text the factory writes to you is three lines.** What happened, what the factory did, what
  you decide (usually nothing). No ids, no internal names; details sit behind an expander. A lint
  blocks any card that breaks this.
- **You comment on plans and reports in Argo.** The comment reaches the agent that wrote it. Until
  W7 that is the plannotator Inbox you used for v1.
- **Work repos stay yours.** IuRoot is not monitored. Sessions and mothers there start only when you
  start them. prometheus-scripts and the StudentEnrolment data-analysis paths may auto-merge;
  domain code opens PRs and stops there.

## During the rewrite

- **Warden, its Slack relay and Hermes' project narratives go dark at W0.** Kuma, Beszel and HyperDX
  keep posting raw alerts to Slack as they do today, so nothing goes unseen; nothing heals itself
  until W1 lands (≈ day 3).
- **Argo keeps running on the VPS until W6**, then moves to the mini in one cutover. Its factory
  pages may show stale warden data in between; ignore them.
- **No data migration.** `warden.db` and Hermes' state are archived read-only to the homelab with a
  checksum. The v1 evidence snapshots stay where they are.
- **The rewrite runs as waves in herdr on Max.** From W2 on, the remaining waves are queued in the
  factory itself, so the factory builds the rest of the factory.

## What you stop doing

| Today | After |
|-|-|
| Typing `continue` into parked agents | Witness resumes them at the next window |
| Reading warden escalations in Slack | Nothing — or a three-line card in Argo |
| Switching Claude accounts by hand | Never; the picker chooses at spawn |
| Running a Claude session every few weeks to upgrade dependencies | A weekly scan opens upgrade waves; a mother ships them |
| Restarting a stopped container | The runbook does it; you read about it in the briefing |
| Wondering what the agents are doing | Argo → *Factory* |
