# 2. What changes for you

## Once it runs

- **You keep working in herdr exactly as now.** `c`, `rd wave`, `/wave` and your own sessions stay;
  the picker balances the `iu` and `me` accounts, and nothing you start runs on IU API tokens.
- **You ask for work in one sentence** — in Argo, to Hermes, as a TickTick item tagged `#factory`, or
  `factory issue new weatherorb "…"`. It is planned, queued, built in herdr, verified and shipped; you
  read about it in the morning briefing.
- **You look at one place:** Argo on the mini — *Now* (anything that needs you; usually nothing),
  *Projects*, *Factory* (what runs, what waits for capacity and until when), *Usage*, *Artifacts* —
  all of it on the phone as on the computer, with mobile layouts.
- **Push notifies you of two things:** a decision card that is genuinely yours, and the 07:00 briefing.
  Everything else is in Argo when you look.
  No evening briefing. Slack stops being an alert inbox; the one alert left there is "the mini or the
  factory is down".
- **Every text the factory writes to you is three lines:** what happened, what it did, what you decide
  (usually nothing). No ids, no internal names; detail sits behind an expander. A lint rejects a card
  that breaks this before you see it.
- **You comment on plans and reports in Argo's *Artifacts*;** the comment reaches the agent that wrote
  it. Until W5 lands, plannotator stays the review surface.
- **Work repos stay yours.** IuRoot is never monitored and the factory never starts work there.

## What you stop doing

| Today | After |
|-|-|
| Typing `continue` into parked agents | Witness resumes them when their window opens |
| Reading raw alerts and warden escalations in Slack | Nothing; Kuma and the others report to the factory |
| Restarting a stopped container | The runbook does it; you read one line about it |
| Running a Claude session every few weeks to upgrade dependencies | A weekly scan opens an upgrade wave; a worker or the project's mother ships it |
| Wondering what the agents are doing | Argo → *Factory* |

## During the rewrite

- **W1 switches warden off and deletes it,** together with its Slack relay and Hermes' project
  narratives, as you said. The same wave brings the first self-heal (a stopped container restarts
  itself), so the blind window is the time W1 takes, about two days. Kuma's raw Slack alerts stop at
  W1; the other sources' stop as their adapters land in W4.
- **Argo stays on the VPS until W5**, then moves to the mini in one cutover.
- **The rewrite runs as waves in herdr on Max.** From W3 on, the remaining waves are queued in the
  factory, so the factory builds the rest of itself.
