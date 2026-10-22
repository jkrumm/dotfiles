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

## During the rewrite

Rewrite and cutover, no co-running: the old loop stops when W1 starts, so days 1–5 are worse than
today's post-Phase-0 state. Days are working days of wave time from the `waves.md` Calendar (≈ 23 on
the warden spine).

| Capability | From day 1 until it returns | Returns |
|-|-|-|
| Alerts | raw Kuma alerts, and HyperDX re-pointed at the Slack webhook, in your existing Slack channel; no folding | W3 (day 5): Conditions from primary sources, one incident per cause |
| Healing | none; the manual herdr lane (`c`, `rd wave`) is the fix path | W3 (day 5): the *restart* recipe; W4 (day 8): investigation and fixes through workers |
| Parked agents | you nudge them, as today | W4 (day 8): Witness resumes them |
| Ship | merges and deploys as today, by hand or from your sessions | W5 (day 11): verified shipping — incident-to-ship autonomy |
| Argo cockpit | the old `/agents` and `/warden` pages frozen (stale, no writes) | W6 (day 16): read models, Home, write verbs |
| Hermes | briefings without `warden.db` reads | W11 (day 19): the door, briefings from the event log |
| Improve and infra healing | none | W10 (day 23): infra runbooks per host, improve jobs — full autonomous operation |

## What you stop doing

- Nudging agents, closing tabs, re-asking status, approving choices an agent can make.
- Reading Slack relays to find out what broke.
- Steering warden through its action queue.

## What you still see and do

- Argo: Home, Needs you, Projects, Incidents, Fleet, Artifacts, Health, Usage, Traffic — and seven write verbs (submit, steer, pause, decide, comment, re-verify, stop).
- Phone pushes only for business decisions, a production SLO burning while automation is stuck (heads-up), or the mini going dark (dead-man).
- One batched weekly ask when a credential needs your fingerprint.
- herdr, Claude Code and `rd` exactly as now — the build lane never breaks.
