# FAQ

**Can I still just use Claude Code in herdr?** Yes. Your sessions are outside the loop unless you hand
work to it, and the picker keeps choosing the account.

**Can I hand work in the brain or my website to the factory?** Yes. Every repo under `~/SourceRoot`
takes requests without a `project.yaml`: one lead per request, one at a time, no orchestrator. A
manifest adds signals, the hold, probes and more leads at once (§7).

**Both Max accounts are walled and production is down — then what?** Settle and runbooks still run;
they need no model. Leads wait for the first reset: usually a 5-hour one, the weekly one when a week
is spent. No IU fallback, by your rule.

**Why does review run on IU API tokens if IU must not reason about code?** The lead calls it as a
tool and weighs the findings; the review decides nothing. A reviewer from another model family sees
what the lead's own family misses.

**DBOS or not?** No (§6); you left it to me. Cortex's engrams runs a Claude Code factory
on DBOS, and its own ADR says a lifecycle that spans days must not be one long-lived run; DBOS's
version gating stranded their runs in production. We take engrams' patterns (an inbox per Issue,
deterministic ids, claims, replay tests) and leave the engine.

**What do I lose during the rewrite?** Warden's triage, from W1a. Raw alerts keep reaching Slack until
each source's adapter lands, Kuma's in W2; job failures go to Slack until W4 (§2).

**What does it cost?** No new subscription. Cheap models are used freely within your €500; review is the
line to watch, and depth gating keeps it in bounds. The rewrite costs ≈ 20–40 % of one `iu` week.

**How do I steer something in flight?** Type into the lead's tab in herdr, or use Argo intents (steer,
pause, stop), a comment on its plan (in plannotator until W5, in *Artifacts* after), Hermes, or
`factory issue` from any shell.

**What will I notice first?** After W1b, a one-line request becomes a shipped change with a production
screenshot and a three-line summary, without you touching it. After W2, a container that stops comes
back on its own, and you read one line about it in the morning instead of an alert in Slack.

**Why two layers and not three?** There are two: the orchestrator decides (initiatives into waves,
stuck leads, priorities, the accounts) and the leads do the work end to end (§4). The factory is code,
not an agent, and a lead's subagents or `rd fan` worktrees are its own tools. v2.2's mothers and the
steward are both the orchestrator now. It runs as short sessions, one per event, so its context never
rots. Building the factory is different: it touches nearly every repo, so until W3 a build orchestrator
runs over one wave orchestrator per wave, the orchestrator of orchestrators you meant (§12).

**Why herdr, and not the Agent SDK or `claude -p`?** Every Claude Code session the factory starts is
an ordinary interactive session in herdr: the plainest use of Max, one you and the orchestrator can
watch and type into. herdr does not own the work: Postgres does, and the session id is the handle, so
a herdr restart costs one turn. `claude -p` cannot be steered mid-turn and, by an open Claude Code bug
reproduced on four accounts, costs about 1.8× the 5-hour window per token. The Agent SDK's
subscription use is contested. Claude Code's own background sessions fit best, with herdr only the
view, but they are a research preview: they become the second adapter behind the same port once that
label goes (§6).

**Can I read an old lead's conversation?** Yes, and continue it. Each attempt keeps its session id,
and the factory archives the transcript at close (W1b), because Claude Code deletes its own after 30
days. `factory issue resume <id>` (W6) opens it in a herdr tab as a fork, so you can ask the lead why
it did what it did; until then `claude --resume <session id>` works within the 30 days (§6).

**Is a factory on one Mac mini a real factory?** Warp says "you can't have a local software factory
because you can't have automations running off your laptops." The mini is not a laptop: it is always
on, and Warp's own self-hosted workers run on customer machines too. What makes it a factory is the
loop that measures and improves itself, not where it runs (appendix E).
