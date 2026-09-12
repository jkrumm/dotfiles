# Agent Limits: None

Agent workers — anything that spawns `claude -p`, `claude_iu`, a sideclaw
episode, a Hermes tool loop, a research run, a Codex/Droid run, or an Agent
SDK `query()` — run **as long as the work takes**.

- **No turn limit.** Never pass `--max-turns`; never add a `maxTurns` /
  `max_steps` / `maxIterations` budget to a session, tier, tool or loop.
- **No wall-clock ceiling.** No `timeoutMs`, `AbortSignal.timeout`,
  `subprocess.run(timeout=…)`, `setTimeout(kill)` or `deadline` around an
  agent run. A slow episode is not a stuck one — glm-class models spend
  minutes per turn on hard work by design.
- **The one liveness rule is an idle watchdog:** no output for N minutes
  (sideclaw: 5 min of no stdout) means wedged, and only then is the worker
  killed. Ledger lifecycle deadlines (an item waiting on a human for 7 days)
  are a different fact and stay.
- **A redeploy never discards an episode.** Drain waits for running work;
  a killed worker is resumed on the next boot from its persisted session id.

**Why:** every cap ever added here turned a working episode into a failure
(warden item 1007: killed at turn 26 of 25 after eleven minutes of real
progress, misreported as a model error). The owner has said so repeatedly;
this rule exists so it is never re-introduced "for safety". Measured in
`warden/docs/history/state-log.md` §64–§66.

**Not covered:** plain HTTP request timeouts to non-LLM APIs, git/CLI helper
timeouts, database busy timeouts, LaunchAgent intervals, spend caps (a
per-job research-call budget, `maxBudgetUsd`), a per-shell-command tool
timeout inside an agent (Hermes `terminal.timeout`), and modelpick's
benchmark harness (deliberately bounded — it measures, it does not work).

**A single non-agentic LLM request** (one completion, no tool loop) is not a
worker, but a short timeout on it still turns a slow answer into a failure:
stream it and apply the idle rule to the token stream; if the client cannot
stream, the timeout is a hang guard of at least 30 minutes, never a budget.
