# 11. FAQ

**Why not just adopt beads, a workflow engine, or Keep?** Each was measured on our data. beads
v1.3.1 leaves cross-repo dependencies unenforced (0 of 9), fixes its lease at 5 minutes, and
touches work repos even in contributor mode (spike 1). DBOS on SQLite survived every kill but
strands flows on a redeploy and adds a second system of record (spike 2). Keep's model — fingerprint
fields plus attribute rules, no topology — scored F1 0.737 on the held-out golden set, no better than
leaving every event alone (0.740), against 0.889 for the proposed correlator (spike 3). What each does
well is copied: bd's verbs and ready semantics, durable primitives, Keep's candidate gate.

**Why not Mastra?** It was not run, and ADR-002 records why: it is TypeScript-only, the research
could not verify its durability, suspend/resume and timeout semantics, and it would add a TS runtime
and a second system of record beside a Python loop.

**What happened to the decision models?** There is no single-shot decision model in the loop. Yours
become the investigate worker on OpenCode/IU, making the judgment calls — which recipe, which
`decision_class` (ADR-003). Measured as a single shot, the decision model agreed 92 % with warden's
LLM triage but only 60 % with the true grouping (`kpi/decision_shadow`); deterministic rules group,
the worker judges.

**Is this a rewrite of warden?** Yes — rewrite and cutover, no co-running. The old loop stops when
W1 starts and its database is archived read-only; history enters a fresh ledger by one import. Each
rewritten piece goes live when it passes its own proof gate (backtest, gamedays, holdouts, the timed
Argo test). Only the build lane, your apps and their data, and the archived stores stay up throughout.

**Why mothers at all, and why only six?** A mother pays for itself where planned work arrives
continuously; the rule (≥ 10 planned units and ≥ 25 commits a week over 90 days) picks basalt-ui,
argo, weatherorb, shutterflow, dotfiles and warden. Everywhere else a session per task is cheaper
and enough. Scheduling stays in code; mothers spend tokens only on judgment.

**Will the factory eat my Max quota?** Not by design, and it will not waste it either. Routine work
stays on IU; the guard parks non-urgent Max work when the forecast for factory plus you reaches 100 %
at the reset, with your reserve derived from your own p90 share (ADR-008). The inverse rule spends
capacity that would lapse: 3 of 7 cycles peaked at 55–79 %, and when the forecast sits below 100 % −
reserve − margin, non-urgent IU-class work spawns on Max. Measured as owner sessions blocked per cycle
(target 0) and Max lapsed % (today p50 4 %, p90 30.6 %, `kpi/forecast`).

**What still needs me?** Product direction, spend, irreversible data loss, other people — as a card
with options, a default and an expiry. Today 6 of 156 decision-relevant events in the golden set
were genuinely yours; the SLO is under 1 % of items, the stretch 0.1 %.

**What happens when the mini is down?** Argo's VPS half says "mini unreachable since hh:mm"; the
VPS dead-man's switch pushes to the phone after 15 minutes. Kuma cannot do it — it shares the mini's
house and power.

**Why did every previous model drift, and why would this one hold?** Prose claims held 1 of 11;
claims that code runs held 7 of 7. Here every invariant is a capability limit with a test, a CI
check or a generated file — or it is labelled `target`. The doc-contradiction lint and the
generated AGENTS.md block make drift fail CI instead of failing silently.

**Can I still open a herdr tab and just work?** Yes. The manual Claude Code + herdr lane is a rule of
every wave, and `rd wave` keeps working after each one.

**Does Slack go away?** As an intake, at once — it stops with the old warden (W1) and the primary-source
adapters replace it (W3). As a human channel it stays until Argo's notifications (W6), Hermes'
briefings (W11) and the per-project changelogs (W13) replace what is posted there.

**What does Hermes become?** The conversational door: it answers from the factory's read models,
files briefs as Tasks, steers agents and asks `rd` for sessions — through the same verbs as Argo. It
loses every code tool (a capability limit with a test), its briefings are generated from the event log
and delivered as Argo threads with audio, and the daily "Project narratives" cron that posts to Slack
retires into per-project changelogs in the brain (W11, W13).

**MCP or CLIs?** CLIs, on one agent contract (ADR-004). Spike 4's only systematic CLI failure — headless polling on a long job, 95k tokens — was fixed by one policy sentence (2 calls, 38.9k tokens). Commands are defined once in code; help, docs, skill references and the AGENTS.md routing block are generated and drift-checked. MCP stays only for research-gateway (Claude Desktop) and chrome-devtools until a browser CLI exists.

**How do we know the design works before building it?** A golden set of 959 labelled events
with pre-registered thresholds, a backtest that never tuned on its held-out half, a baseline gameday
against today's system, and KPI scripts the loop cannot edit (section 7).

**How long does the rewrite take?** Fourteen waves in three lanes on a serial warden spine, ≈ 23
working days of wave time (`waves.md` Calendar); W1–W3 are fully specified and can start now (W1 and W2
in parallel). Raw alerts reach your Slack channel on days 1–5; verified shipping returns with W5
(day 11), full autonomous operation with W10 (day 23) — section 1b, *During the rewrite*.
