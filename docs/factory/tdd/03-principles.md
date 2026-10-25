# 3. Principles

Eight rules. A design choice that breaks one is wrong.

1. **The factory runs the lifecycle; Claude Code does the thinking.** What a script can decide, a
   script decides. Routine words and routine judgments (is this the same symptom, which project, how
   big) go to cheap models. Anything that needs understanding a problem or code goes to a lead.
2. **Max reasons about code, IU API tokens do the routine.** Claude Code on the `iu` and `me` Max
   accounts is the only thing that diagnoses or changes a repo, and it runs in herdr, where you can
   watch it. IU API tokens pay for gateways, OpenCode, Hermes and the tools leads call. A full Max
   pool means waiting, never spilling.
3. **Hand over the problem, not a conclusion.** A brief holds facts, evidence and verified history.
   A weaker model's guess at the cause is noise a stronger model has to unlearn.
4. **One lifecycle, no side doors.** Every piece of work enters as an Issue and leaves with evidence or
   a stated reason.
5. **Facts are stored, state is derived.** The database holds what happened: signals, phases,
   evidence, decisions, session observations. "Working", "stuck", "waiting" are computed from facts
   when read, so they cannot drift.
6. **Done means observed in production.** A lead saying "done" is a claim; the evidence and the
   factory's own `make verify` after the hold are the proof. Wrong in production means fix forward.
7. **A self-improving platform, as code.** Agents find the fix; once a fix is verified twice, it
   becomes a runbook or a job check that code runs from then on. Every rule, runbook, probe, policy
   threshold and prompt lives in a repo, and changes only through an Issue a lead ships with evidence.
   That includes the factory's own code: a scorecard measure off target for two weeks becomes an
   Issue in the `factory` repo. The factory gets cheaper and better as it learns.
8. **You decide business, nothing else.** Product direction, spend, irreversible data loss, other
   people. Anything else that reaches you is a defect. Everything written for you is short,
   verdict-first and free of internal names.

## Fixed boundaries

- **Security is the tailnet plus your GitHub user.** The factory opens no public endpoint. Sources it
  cannot reach directly are polled, or arrive through the Slack adapter. On GitHub, only your user's
  issues and comments start work.
- **No caps on a lead's work.** No turn limits, no wall-clock ceilings; the one liveness rule is the
  idle watchdog, and the steward handles a lead that stops making progress.
- **AGENTS.md only.** No CLAUDE.md in any repo.
