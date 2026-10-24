# FAQ

**Can I still just use Claude Code in herdr?** Yes. Your sessions are outside the loop unless you hand
work to it, and the picker keeps choosing the account.

**Both Max accounts are walled and production is down — then what?** Settle, restart, rollback and
runbooks still run; they need no model. Code waits for the first reset. No IU fallback, by your rule.

**Why does review run on IU API tokens if IU must not write code?** Review reads code and changes
nothing. A reviewer with a DeepSeek adversary is a second pair of eyes from another model family.

**Why DBOS after all?** v1's spike used it wrong, and Node is fine. With short workflows and waiting in
tables, it gives queues, schedules and a run history for free without its replay pitfalls (§6).

**What do I lose during the rewrite?** Warden's triage, for the two days W1 takes. Raw alerts keep
reaching Slack until each source's adapter lands.

**What does it cost?** No new subscription. Cheap models are used freely within your €500; review is the
line to watch, and depth gating keeps it in bounds. The rewrite costs ≈ 20–40 % of one `iu` week.

**How do I steer something in flight?** Argo intents (steer, pause, stop), a comment on its plan in
*Artifacts*, Hermes, or `factory issue|task` from any shell.

**What will I notice first?** After W1, a container that stops comes back on its own, and you read
one line about it in the morning instead of an alert in Slack.
