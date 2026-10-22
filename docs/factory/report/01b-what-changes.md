# 1b. What changes for you

The rewrite ends most of your manual loop. The cost is the cutover: there is no co-running, so the old loop stops when W1a starts, and **days 1–8 are worse than today's post-Phase-0 state**. The first table shows the end state. The second shows what you get each day until then. The last two sections list what you stop doing and what you keep.

## Your day, before and after

| Moment | Today (evidence) | After the rewrite |
|-|-|-|
| Morning | a Slack briefing you read and then ask your agents about anyway (37 asks in classes it covers) | Argo Home: one status line; if quiet, *Since you left* and *Fixed alone* — nothing to do |
| An outage | up to 18 pages for a 7.9-minute reboot (10-17), each anchored on the wrong time | 0 pages when it recovers; one incident card if automation cannot close it within its budget, with cause, suspects and what automation did |
| A parked agent | you type `continue` — 50 times in 45 days, 26 of them after an API error | Witness resumes it at the quota reset or after a backoff — MacBook agents too, while the laptop is awake; a scheduled resume is one count on line 1, and you see an agent only if resuming failed |
| "Where are we? Is it done and live?" | ask a session; 48 s and 5 tool calls to rebuild the answer | Project page and delivery view, answered in ≤ 10 s on the phone |
| A decision | 32 % of new items reach you, 4 of the latest 20 genuinely yours | a card only for product direction, spend, irreversible data loss or other people — with a default that applies on expiry |
| A plan or report to review | read files in the terminal; comments die with the session | Argo's Artifacts view: comment in place, the agent reads it back durably |
| Finished tabs | close them by hand (20 open, 2 older than a day) | reaped automatically; Fleet shows only what the janitor would not touch |
| Starting work | `c`, `rd wave`, Hermes typing into panes | submit a brief to a project (Argo, Hermes or `rd`) — or open a herdr tab and work, exactly as today |

## During the rewrite

Days are working days of wave time from the `waves.md` Calendar (≈ 26 on the warden spine). They get re-planned from W1a's measured rate.

| Capability | From day 1 until it returns | Returns |
|-|-|-|
| Alerts | raw Kuma alerts, and HyperDX re-pointed at the Slack webhook, in your existing Slack channel; no folding. The dev-host heartbeat carries a liveness component for the new warden from day 1, so the new loop is never unwatched | W3b (day 8): Conditions from primary sources, one incident per cause |
| Job and log failures | unwatched: the heartbeat's jobs component still shows failed jobs as a WARN, but nothing pages or fixes; Hermes log errors have no reader, because the file poller that read them stops with the old warden | W3a (day 5): jobrun runs enter as `job.ran` events, and the mini's logs (launchd, Hermes, agent-gateway) reach the VPS ClickStack for the log adapter |
| Healing | none; the manual herdr lane (`c`, `rd wave`) is the fix path | W3b (day 8): the *restart* recipe; W4a (day 9): investigation and fixes through workers |
| Parked agents | you nudge them, as today | W4b (day 11): Witness resumes them, MacBook agents through an actuator while the laptop is awake |
| Ship | merges and deploys as today, by hand or from your sessions | W5 (day 14): restarts and producer-backed config ship automatically; fleet code fixes project by project, as each project's holdouts bind on measurement, never on a timer — until then they are propose-only: opened and verified, not merged |
| Argo cockpit | the old `/agents` and `/warden` pages frozen (stale, no writes) | W3a (day 5): `warden status --json` and one stub page — open incidents, decisions, freshness; no push before W6. W6 (day 19): read models, Home, push, write verbs |
| Hermes | briefings without `warden.db` reads | W11 (day 22): the door, briefings from the event log |
| Improve and infra healing | none | W10 (day 26): infra runbooks per host, improve jobs and attack blocking — full autonomous operation once its gate passes: gameday rows 3, 4, 14 and 16 and one shipped item per improve class. Escalation recall and known-error matching are read as standing SLOs when the fresh sample reaches its size, not at the gate |

## What you stop doing

- Nudging agents, closing tabs, re-asking status, approving choices an agent can make.
- Reading Slack relays to find out what broke.
- Steering warden through its action queue.

## What you still see and do

- **Argo:** Home, Needs you, Projects, Incidents, Fleet, Artifacts, Health, Usage, Traffic. Seven write verbs: submit, steer, pause, decide, comment, re-verify, stop.
- **Phone pushes**, only for:
  - business decisions
  - a production SLO burning while automation is stuck (heads-up)
  - a host fault only hands can fix (`needs_hands`, information only)
  - the mini going dark (dead-man)
- **Credential expiry:** one ask per expiry that needs your fingerprint, at most 2 a month. Asks are scheduled from the 7-day lead and coalesced across credentials. This is physical presence, not a decision, so it does not count toward the decision SLO.
- **herdr, Claude Code and `rd`:** exactly as now — the build lane never breaks.
