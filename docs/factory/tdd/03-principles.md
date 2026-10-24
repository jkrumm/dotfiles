# 3. Principles

Eight rules. A design choice that breaks one is wrong.

1. **Code, cheap models, Claude Code — in that order.** What a script can decide, a script decides.
   Everything else that needs judgment or words goes to a cheap model, freely. Implementation goes to
   Claude Code.
2. **Max writes code, IU API tokens think.** Claude Code on the `iu` and `me` Max accounts is the only
   thing that changes a repo, and it runs in herdr, where you can watch it. IU API tokens pay for
   gateways, OpenCode, Hermes, research and review. A full Max pool means waiting, never spilling.
3. **One loop, no side doors.** Every piece of work enters as an Issue or a Task and leaves through
   verification.
4. **Facts are stored, state is derived.** The database holds what happened: signals, commits, check
   results, decisions, session observations. "Working", "stuck", "ready to merge" are computed from
   facts on every tick, so they cannot drift.
5. **Done means observed.** A Task is done when its checks pass on the exact commit that merges and,
   after a deploy, when the running system says so. An agent saying "done" is a claim.
6. **Wait before acting, look before acting.** Every alert class has a grace window, a known fix runs
   before an investigation, and every action re-reads the current state of the world first.
7. **You decide business, nothing else.** Product direction, spend, irreversible data loss, other
   people. Anything else that reaches you is a defect in the loop.
8. **Plain words for humans.** What the factory writes to a human is short, verdict-first and free of
   internal names.

## Fixed boundaries

- **Security is the tailnet plus your GitHub user.** The factory opens no public endpoint. Sources it
  cannot reach directly are polled, or arrive through the Slack adapter.
- **No caps on an agent's work.** No turn limits, no wall-clock ceilings; the one liveness rule is the idle
  watchdog. Budgets stop runaway loops, not slow work.
- **AGENTS.md only.** No CLAUDE.md in any repo.
