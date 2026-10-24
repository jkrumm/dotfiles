# D. Edge cases, for the implementing waves

Handled once in code, so neither you nor Claude Code has to think about them again. Each line names the
wave that builds it.

| Case | Handling | Wave |
|-|-|-|
| The factory crashes or redeploys mid-step | DBOS repeats at most one short stage; every outside effect checks first whether it already happened | W1 |
| The factory deploys itself | a small deploy script outside DBOS drains running workflows, swaps the release, waits for health and one synthetic Issue, and swaps back on failure | W1 |
| The database is restored from a dump | the factory starts in adopt mode: no effects until each open Issue and Task has looked at the world once | W1 |
| The mini was down | open deadlines move by the downtime, so a decision does not take its default the moment the mini returns | W1 |
| A source's recovery message is lost | sources are polled, so the next read sees the recovery | W1, W4 |
| A second copy of the service starts | only the service launches DBOS; a database lock makes a second copy exit | W1 |
| Two Tasks merge onto the same repo | merges run one at a time per repo, rebased onto the current tip and re-checked; the default branch moves only to the checked commit | W2 |
| A session keeps pushing after "done" | done needs five quiet minutes; the pane is stopped before verification starts | W2 |
| A session hits a usage wall | Witness marks it walled, the idle watchdog pauses until the reset, and the Task goes back through the picker | W2 |
| A herdr restart moves a session to the other account | Witness records the account in effect, so usage and balance stay correct | W2 |
| A pane dies repeatedly | three deaths in ten minutes without a new commit send the Task back to planning | W2 |
| A change edits its own checks | checks come from the base branch; a change to Makefile, CI or test config gets a full review that asks whether it weakens verification, and test counts may not drop | W2 |
| A rollback fails | the project is paused and you get one card | W2 |
| Merged Issues keep working twice | merging stops the absorbed Issue's Tasks and sessions | W3 |
| The decision model is down | ambiguous signals stay apart; intake never waits on it | W3 |
