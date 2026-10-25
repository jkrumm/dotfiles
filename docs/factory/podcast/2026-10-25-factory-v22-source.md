# Factory design v2.2 — the final tradeoffs (source for the episode, 2026-10-25)

Listener: Johannes, who designed this factory and commented on v2.1 this morning. He is driving.
He wants the decisions and their tradeoffs, not the basics. One decision is still his: durable
execution (DBOS or not). Everything else is decided unless he objects.

## 1. What his comments changed

- Claude Code is the smart actor end to end. One Claude Code session per Issue, the "lead", running
  in herdr on a Max subscription, does root cause, plan, build, test, review, ship, the production
  check, and reports back. The factory runs the lifecycle around it: intake, dedup by symptom,
  settle and runbooks, classify, queue and capacity, spawn, watch, learn. The factory never reasons
  about code or causes.
- Cheap models (DeepSeek, Haiku, the decision model, on IU API tokens) no longer investigate or plan.
  His point: a weaker model's guess at the cause can confuse the stronger one. They only sort and
  word: dedup judging, classification (routing only), card and briefing text, the changelog,
  learning write-ups, job summaries, and the review and research tools the lead calls.
- No automatic rollback. His career experience: you fix forward, and infra, dotfiles and data
  rarely roll back cleanly. The lead fixes forward; reverting is its call when that is fastest.
- One unit of work: the Issue. Tasks are gone; an initiative's waves are child Issues.
- Start after his sign-off, not on a fixed Monday.

## 2. The tradeoffs that came with that

**Quality over cheapness in reasoning.** Every Issue now costs Max capacity from the first minute,
because the lead investigates too. The answer is to size each lead: Haiku at low effort for
mechanical work, Sonnet at medium for most bugs and requests, Opus for large or novel work and
for a second attempt after a failure. A lead that stalls is re-spawned one tier up. A weekly tuning
job compares cost and outcome per tier.

**The brief carries facts, never a diagnosis.** The ask in his words or what the signals saw, the
raw evidence and how to pull logs and traces, similar past Issues with the cause their lead
verified (marked "past, may not apply"), the project's make contract, and what done means. The
tradeoff: the lead spends a few minutes orienting itself, and in return it is not anchored on a
wrong guess.

**Done means evidence.** `factory issue ship` is refused without the evidence its change needs: a
production screenshot for UI, error rate and p95 before and after for a service, logs for infra,
queries for data. After a 30-minute hold the factory runs `make verify` and the project's journey
probes itself.

**Forward fix needs other safety nets.** Without rollback, three things carry the risk: the hold
window with regressions going straight back to the same lead while its cache is warm; journey
probes that no lead writes (an idea from Cortex's DRIVE paper: tests a model wrote for its own
change can give false confidence); and "stop the line": while a project's production is red, it
gets only fixes, its features and upkeep wait. After three failed production checks on one Issue,
the project pauses and he gets one card.

**The steward is his "daddy orchestrator", but short.** It runs at 06:30 for exceptions, does a full
scorecard review on Mondays, and wakes on events: a lead without progress for two hours, an Issue
reopened twice, a normal Issue waiting a day for capacity, an account heading for more than 10 %
unused at its reset. It reorders, re-tiers, steers, splits or merges, pauses a project, or puts a
card to him. It never writes code. Short runs on Sonnet at medium instead of an always-on Opus
session: cheaper, no context rot; the price is that it reacts through events, not continuously.
During the rewrite, before the steward exists, one orchestrator tab (Opus, medium effort) plays
that part for the build waves, reading `claude-account usage` before every spawn.

**The 5-hour window on `me` binds first.** `me` is Max 5x: a third of weekly capacity, but its
5-hour window is a quarter of `iu`'s. So admission checks 5-hour headroom against the expected cost
of the lead's size before it starts anything, keeps 15 % of `iu`'s window free for his own sessions,
and holds one lead per repo plus one urgent. Snapshot this morning: `iu` at 90 % of its week until
Wednesday 16:00, `me` at 24 % until Thursday 06:00 — the imbalance the balance goal (less than 10 %
unused at each reset) is for. W1 and W2 therefore run on `me`.

**Dedup in two tiers.** He noticed the catch himself: true dedup needs the root cause, and the root
cause needs a smart model. So intake only merges obvious repeats of the same symptom (rules; F1
0.889 on the held-out golden set), and the lead merges or splits by cause. A possibly related signal
goes to the running lead as a note instead of starting a second lead. The cheap judge for ambiguous
pairs stays off until a W4 bake-off: the decision model with a context pack versus a DeepSeek
session that can look further itself, on labelled pairs. It must reach merge precision 0.95, because
a wrong merge hides work while a missed one costs one note.

**Learning is measured, not hoped for.** Four numbers on the scorecard: missed-at-intake rate (lead
merges), wrong-join rate (lead splits), seen-before hit rate, runbook share. A fix verified twice
becomes a runbook or a job check that code runs from then on — more deterministic over time, as he
asked, borrowing Swamp's idea that agents write the definition and code runs it. If none of the four
improves over two months, the steward opens an Issue saying so.

**Outcomes first on the scorecard** (from Cortex's DRIVE paper): change failure rate as the headline,
probes failing per project, urgent Issues per week, interrupts that reached him; then subscription
balance, dedup and learning, pipeline times, cost per Issue per tier. A factory that closes many
Issues while production gets worse is failing.

**The changelog** is no longer written from conventional commits. Each lead writes a three-line
summary on ship; a cheap model compiles them daily into the brain and Argo.

## 3. The DBOS story, honestly

The recommendation flipped twice today, and the evidence that settled it came from reading code.

- v2.0 declined DBOS with the claim "Node, not Bun". He was right that this was weak: DBOS is
  officially Node-only, but it runs on Bun.
- v2.1 adopted DBOS with short workflows and all waiting in tables.
- His comment today: not sure DBOS is needed; look at Cortex. Cortex's engineering blog, "A software
  factory is just a durable workflow", lists why cron plus a status column fails: retried jobs
  re-send prompts, every new step adds states and race conditions, deploys land mid-flight, inputs
  arrive twice. On that basis the draft first recommended one long-lived DBOS workflow per Issue.
- Then the engrams source (Cortex's open-source factory that runs Claude Code, AGPL, Bun plus DBOS).
  Its ADR 0119 says: an entity lifecycle that spans days must not be one long-lived run; the
  automation is stateful, no run is. Its ADR 0104 describes DBOS's version gating stranding runs in
  production — 253 unread messages, 15 orphaned runs — and a sweeper of about 2,000 lines to adopt
  them. Engrams uses DBOS only for step checkpoints, send and receive, and idempotent run ids; cron,
  concurrency claims, retries and recovery are their own code.
- So the recommendation now: no DBOS. Each Issue is a state machine in Postgres with an inbox. Every
  event — a repeated signal, the lead's report, a turn end from the lead's Stop hook, Witness seeing
  a dead pane, the hold timer, his intents — is an inbox row with a mandatory idempotency key. One
  worker handles one Issue at a time under a row lock, so events never race. Effects are
  attach-or-start by deterministic id: the lead's herdr name, prompt ids recorded before typing,
  markers on GitHub comments. Claims with join, queue and supersede hold one lead per repo. A golden
  test pins each path's transitions; a replay test crashes after every effect and must end with zero
  duplicates. What would change the recommendation: the lifecycle module passing about 500 lines, or
  a race the lock cannot close.
- Another engrams lesson: inferring turn ends from terminal output wedged their sessions, so they use
  explicit end-of-turn events. herdr's idle state is inferred, so the lead's Stop and SessionEnd hooks
  report turn ends into the inbox, and herdr's pane state becomes the backstop. Engrams runs Claude
  Code headless; the factory keeps leads interactive in herdr because he wants to watch and type into
  them.

## 4. The plan

- W1 spine: one lead takes a real request from `factory issue new` to a checked production change
  without him; warden is switched off, Kuma's Slack alerts stay until W2 so nothing goes unwatched.
- W2 intake and self-heal: Kuma, GitHub (his issues and `/factory` comments), TickTick; the restart
  runbook; rules dedup; classification.
- W3 capacity and the steward: 5-hour-aware admission, model and effort per lead, the steward,
  scorecard v0, review-depth gating.
- W4 projects, more intake, the judge bake-off, probes everywhere.
- W5 Argo on the mini, mobile first. W6 jobs, tooling, Hermes as the chat front.
- About nine build days on the critical path, then 14 days of observation. Cost: about 20 to 40
  percent of one `iu` week, likely the lower half now that the factory is smaller.

## 5. What is still his

1. DBOS or the Issue machine. Recommendation: the Issue machine.
2. Sign-off to start W1.
3. Worth a look: IU spend was $183 last week, $136 of it review; if the €500 is monthly, review-depth
   gating in W3 is what keeps it under.
