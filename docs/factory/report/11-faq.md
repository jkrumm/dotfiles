# 11. FAQ

**Why not just adopt beads, a workflow engine, or Keep?** Each was measured on our data. beads
v1.3.1 leaves cross-repo dependencies unenforced (0 of 9), fixes its lease at 5 minutes, and
touches work repos even in contributor mode (spike 1). DBOS on SQLite survived every kill but
strands flows on a redeploy and adds a second system of record (spike 2). Keep: section 7's
backtest. What each does well is copied: bd's verbs and ready semantics, durable primitives, Keep's
candidate gate.

**Is this a rewrite of warden?** No. The ledger evolves in place, new flows run in shadow beside the
old ones, and each old stage retires only after its replacement beats it on a Phase 6 metric (W9).

**Why mothers at all, and why only six?** A mother pays for itself where planned work arrives
continuously; the rule (≥ 10 planned units and ≥ 25 commits a week over 90 days) picks basalt-ui,
argo, weatherorb, shutterflow, dotfiles and warden. Everywhere else a session per task is cheaper
and enough. Scheduling stays in code; mothers spend tokens only on judgment.

**Will the factory eat my Max quota?** Not by design. Moving today's agent-gateway workload onto Max
would add ≈ 24 % of the weekly window (p90 96 % → 120 %), so routine work stays on IU, the guard
flips non-urgent spawns to IU at 80 %, and 15 % stays reserved for you.

**What still needs me?** Product direction, spend, irreversible data loss, other people — as a card
with options, a default and an expiry. Today 6 of 156 decision-relevant events in the golden set
were genuinely yours; the target is ≤ 0.1 % of items.

**What happens when the mini is down?** Argo's VPS half says "mini unreachable since hh:mm"; the
VPS dead-man's switch pushes to the phone after 15 minutes. Kuma cannot do it — it shares the mini's
house and power.

**Why did every previous model drift, and why would this one hold?** Prose claims held 1 of 11;
claims that code runs held 7 of 7. Here every invariant is a capability limit with a test, a CI
check or a generated file — or it is labelled `target`. The doc-contradiction lint and the
generated AGENTS.md block make drift fail CI instead of failing silently.

**Can I still open a herdr tab and just work?** Yes. The manual Claude Code + herdr lane is a rule of
every wave, and `rd wave` keeps working after each one.

**Does Slack go away?** As an intake, yes — each source switches to its direct path after 7 days of
shadow without a miss. As a human channel it stays until Argo's notification stream replaces it (W10).

**MCP or CLIs?** ⟨spike 4⟩

**How do we know the design works before building it?** A golden set of 959 labelled events
with pre-registered thresholds, a backtest that never tuned on its held-out half, a baseline gameday
against today's system, and KPI scripts the loop cannot edit (section 7).

**How long does the migration take?** Fourteen waves. W1–W3 are fully specified and can start now;
W1 and W2 run in parallel. The factory ships at every step.
