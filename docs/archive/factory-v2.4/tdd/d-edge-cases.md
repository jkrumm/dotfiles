# D. Edge cases, for the implementing waves

Handled once in code, so neither you nor a lead has to think about them again. Each line names the
wave that builds it.

| Case | Handling | Wave |
|-|-|-|
| The factory crashes or restarts while leads work | leads live in herdr and keep working; their hooks spool what the factory cannot take; unhandled inbox rows wait; every outside effect (spawn, prompt, GitHub comment, card) is attach-or-start by a deterministic id, so a replayed event does nothing twice | W1a |
| The factory deploys itself | stop, swap the release, start, health check; if the health check fails, the previous release starts again. Shipped changes are never rolled back automatically; this swap of the factory's own release is the one automatic revert, because a dead factory watches nothing. State lives in rows, so no run is in flight to strand; running leads never notice | W1a |
| The database is restored from a dump | every start reconciles: no effects until each open Issue has looked at the world (herdr, its worktree, GitHub, the sources) once; the Issue sequence moves past every id in pane names and the spool, and a lead reporting a lost Issue gets it rebuilt from the spool or parked | W1a |
| The mini was down | open deadlines move by the downtime, so a decision does not take its default the moment the mini returns; missed job slots run once | W1a |
| A second copy of the service starts | a Postgres advisory lock; the second copy exits | W1a |
| A lead stops with its Issue open and nothing reported | the Stop hook sends it back with the one-line reminder, unless it declared a wait, hit a usage limit, or answered you; a second unreported stop parks the Issue with a line for you, never a card, and from W3 is an orchestrator event | W1a |
| herdr restarts or crashes while leads work | the processes die; herdr resumes each Claude pane by session id, which brings back the conversation, not the turn in flight. Witness sees the server PID change, records the event, and sends each affected lead a note to check what took effect before it continues; a pane that does not come back is resumed by the factory from its session id | W1a |
| A herdr restart moves a session to the other account | Witness records the account in effect, so usage and balance stay correct | W1a |
| A change edits its own checks | the review is told to flag weakened tests or checks; the factory's own `make verify` and probes run against the deployed target after the hold, and probes change only through an Issue of their own | W1b |
| A source's recovery message is lost | sources are polled, so the next read sees the recovery | W2 |
| An issue on GitHub from someone else | ignored, unless you comment `/factory` on it | W2 |
| Two leads touch the same repo | each works in its own worktree; one lead per repo (or the manifest's `leads`) plus one urgent; each rebases and re-runs its checks before merging | W1a, W3 |
| A lead hits a usage wall | Witness marks it walled and resumes it at the reset, or on the other account when the wait passes an hour and that one has headroom (§5) | W1a |
| A pane dies repeatedly | three deaths in ten minutes without a new commit: orchestrator event | W3 |
| Production stays broken after several forward fixes | the line is already stopped (only fixes run, §5); after three failed production checks on one Issue, the orchestrator is woken and steers, re-tiers, splits or parks it; a card only if a business class is at stake | W3 |
| A merge absorbs an Issue a lead is working on | the absorbed lead pushes its work in progress to a branch and drops its Issue as merged; its notes go to the surviving lead | W1a |
| The judge is down or not yet trusted | ambiguous signals stay apart, linked as *possibly related*; intake never waits | W2 |
| The factory is down when a hook fires | the hook exits at once and appends its event to the spool, which the factory replays on start | W1a |
| A hook fires in your own session or a build session | it exits at once: hooks act only where `FACTORY_SESSION` is set | W1a |
| Something else types into a lead's pane | the factory alone owns `lead-*` panes; herdr-reap skips them, and the factory and orchestrator write only through `factory issue note` | W1a |
| A lead breaks a hook, the picker or `rd` in dotfiles | dotfiles and the factory repo have manifests with `deploy.mode: make`, a hold and a zero-token probe that runs each hook against a sample payload, so the break shows before the next lead starts | W1b |
| A machine opens a GitHub issue under your user | only the `factory` label or your `/factory` comment starts work; an `alert` issue is a signal and is deduplicated | W2 |
