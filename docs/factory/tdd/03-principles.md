# 3. Principles

Eight rules. Every later section applies them; a design choice that breaks one is wrong.

1. **Deterministic before cheap before expensive.** If a script can decide it, a script decides it.
   If it needs judgment but no code, a cheap model decides it. Only writing code earns a Max session.
2. **Max writes code, IU thinks, nothing else.** Claude Code on the Max subscriptions is the only
   thing that changes a repo, and it runs only in herdr, where you can watch it. IU tokens pay for
   gateways, OpenCode, Hermes and research. A full Max pool means waiting, not spilling.
3. **One loop, no side doors.** Every piece of work enters as an Issue or a Task and leaves through
   verification. A fix that skips the loop is a bug in the loop.
4. **Facts are stored, status is derived.** The database holds what happened (signals, commits,
   check results, decisions). "Working", "stuck", "ready to merge" are computed when read, so they
   cannot drift from the facts.
5. **Done means observed.** A task is done when its checks pass on its exact commit and, after a
   deploy, when the running system says so. An agent saying "done" is a claim, not a state.
6. **Wait before acting.** Many failures heal by themselves. Every alert class has a grace window
   before anything runs, and a known fix runs before an investigation.
7. **You decide business, nothing else.** Product direction, spend, irreversible data loss, other
   people. Everything else has a policy, a default or a verification rung — or it is a defect.
8. **Plain words for humans.** Anything a human reads from the factory is short, verdict-first and
   free of internal names. Detail is one click away, never in the way.

## Boundaries that are not up for discussion

- **Security** is the tailnet plus your GitHub user. Inside that boundary the factory acts on
  verified intent. Public entry points exist only where a source cannot reach the tailnet (§10),
  and each one verifies a signature.
- **No caps on agent work.** No turn limits, no wall-clock ceilings; the one liveness rule is the
  idle watchdog (`rules/agent-limits.md`). Budgets exist per issue, in Max-window units, and stop
  runaway loops, not slow work.
- **AGENTS.md only.** No CLAUDE.md in any repo; the factory measures AGENTS.md size, skills and
  resident tool tokens, not CLAUDE.md.
