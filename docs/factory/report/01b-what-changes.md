# 1b. What changes for you

## Your day, before and after

| Moment | Today (evidence) | After the rewrite |
|-|-|-|
| Morning | a Slack briefing you read and then ask your agents about anyway (37 asks in classes it covers) | Argo Home: one status line; if quiet, *Since you left* and *Fixed alone* — nothing to do |
| An outage | up to 18 pages for a 7.9-minute reboot (10-17), each anchored on the wrong time | 0 pages when it recovers; one incident card if it does not, with cause, suspects and what automation is doing |
| A parked agent | you type `continue` — 50 times in 45 days, 26 of them after an API error | Witness resumes it at the quota reset or after a backoff; you see it only if resuming failed |
| "Where are we? Is it done and live?" | ask a session; 48 s and 5 tool calls to rebuild the answer | Project page and delivery view, answered in ≤ 10 s on the phone |
| A decision | 32 % of new items reach you, 4 of the latest 20 genuinely yours | a card only for product direction, spend, irreversible data loss or other people — with a default that applies on expiry |
| A plan or report to review | read files in the terminal; comments die with the session | Argo's Artifacts view: comment in place, the agent reads it back durably |
| Finished tabs | close them by hand (20 open, 2 older than a day) | reaped automatically; Fleet shows only what the janitor would not touch |
| Starting work | `c`, `rd wave`, Hermes typing into panes | submit a brief to a project (Argo, Hermes or `rd`) — or open a herdr tab and work, exactly as today |

## What you stop doing

- Nudging agents, closing tabs, re-asking status, approving choices an agent can make.
- Reading Slack relays to find out what broke.
- Steering warden through its action queue.

## What you still see and do

- Argo: Home, Needs you, Projects, Incidents, Fleet, Artifacts, Health, Usage, Traffic — and seven write verbs (submit, steer, pause, decide, comment, re-verify, stop).
- Phone pushes only for business decisions, a production SLO burning while automation is stuck (heads-up), or the mini going dark (dead-man).
- One batched weekly ask when a credential needs your fingerprint.
- herdr, Claude Code and `rd` exactly as now — the build lane never breaks.
