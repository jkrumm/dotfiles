# D. Edge cases, for the implementing waves

Handled once in code, so neither you nor a lead has to think about them again. Each line names the
wave that builds it.

| Case | Handling | Wave |
|-|-|-|
| The factory crashes or restarts while leads work | leads live in herdr and keep working; unhandled inbox rows wait; every outside effect (spawn, prompt, GitHub comment, card) is attach-or-start by a deterministic id, so a replayed event does nothing twice | W1 |
| The factory deploys itself | stop, swap the release, start, health check; if the health check fails, the previous release starts again. That is the one revert in the design, because a dead factory watches nothing. State lives in rows, so no run is in flight to strand; running leads never notice | W1 |
| The database is restored from a dump | the factory starts in adopt mode: no effects until each open Issue has looked at the world (herdr, GitHub, the sources) once | W1 |
| The mini was down | open deadlines move by the downtime, so a decision does not take its default the moment the mini returns; missed job slots run once | W1 |
| A second copy of the service starts | a Postgres advisory lock; the second copy exits | W1 |
| A lead stops with its Issue open and nothing reported | the Stop hook sends it back once per stop with the one-line reminder; a lead that stops again unreported is a card to you until W3, a steward event after | W1 |
| A herdr restart moves a session to the other account | Witness records the account in effect, so usage and balance stay correct | W1 |
| A change edits its own checks | the review is told to flag weakened tests or checks; the factory's own `make verify` and probes run against the deployed target after the hold, and probes change only through an Issue of their own | W1 |
| A source's recovery message is lost | sources are polled, so the next read sees the recovery | W2 |
| An issue on GitHub from someone else | ignored, unless you comment `/factory` on it | W2 |
| Two leads touch the same repo | one lead per repo plus one urgent; each rebases and re-runs its checks before merging | W3 |
| A lead hits a usage wall | Witness marks it walled and resumes it on the same account after the reset | W3 |
| A pane dies repeatedly | three deaths in ten minutes without a new commit: steward event | W3 |
| Production stays broken after several forward fixes | the line is already stopped (only fixes run, §5); after three failed production checks on one Issue, the steward is woken and you get one card | W3 |
| A merge absorbs an Issue a lead is working on | the absorbed lead is stopped and its notes go to the surviving lead | W1 |
| The judge is down or not yet trusted | ambiguous signals stay apart, linked as *possibly related*; intake never waits | W2 |
