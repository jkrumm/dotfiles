# FAQ

**Can I still just use Claude Code in herdr?** Yes. Your sessions are outside the loop unless you hand
work to it, and the picker keeps choosing the account.

**Both Max accounts are walled and production is down — then what?** Settle and runbooks still run;
they need no model. Leads wait for the first reset, which on the 5-hour window is never more than five
hours away. No IU fallback, by your rule.

**Why does review run on IU API tokens if IU must not reason about code?** The lead calls it as a
tool and weighs the findings; the review decides nothing. A reviewer from another model family sees
what the lead's own family misses.

**DBOS or not?** Your call (§6). My recommendation is no. Cortex's engrams runs a Claude Code factory
on DBOS, and its own ADR says a lifecycle that spans days must not be one long-lived run; DBOS's
version gating stranded their runs in production. We take engrams' patterns (an inbox per Issue,
deterministic ids, claims, replay tests) and leave the engine.

**What do I lose during the rewrite?** Warden's triage, from W1. Raw alerts keep reaching Slack until
each source's adapter lands, Kuma's in W2.

**What does it cost?** No new subscription. Cheap models are used freely within your €500; review is the
line to watch, and depth gating keeps it in bounds. The rewrite costs ≈ 20–40 % of one `iu` week.

**How do I steer something in flight?** Type into the lead's tab in herdr, or use Argo intents (steer,
pause, stop), a comment on its plan (in plannotator until W5, in *Artifacts* after), Hermes, or
`factory issue` from any shell.

**What will I notice first?** After W1, a one-line request becomes a shipped change with a production
screenshot and a three-line summary, without you touching it. After W2, a container that stops comes
back on its own, and you read one line about it in the morning instead of an alert in Slack.

**Is the steward the "daddy orchestrator"?** Yes. It is short runs rather than an always-on session,
so its context never rots and it costs minutes a day. During the rewrite, the build orchestrator
plays the same part (§5, §12).
