# 11. FAQ

## You and the rewrite

### What still needs me?

Four things: product direction, spend, irreversible data loss and other people. Each reaches you as a card with options, a default and an expiry.

- **Today:** 6 of 156 decision-relevant events in the golden set were genuinely yours.
- **SLO:** under 1 % of items. Stretch: 0.1 %.
- **Product direction is found by structure, not opinion.** A card comes from a change to a declared product surface whose lineage holds no event from you. Events that count as yours are a brief you submitted, or a comment or resolve on the plan. The card carries a reversible default.
- **Credentials:** outside the cards, you get one present-human ask when a credential needs your fingerprint. There is one per expiry, scheduled 7 days ahead and coalesced, at most 2 a month. These asks are counted outside the SLO.

### How long does the rewrite take?

≈ 26 working days of wave time at the planned rate. The plan is re-set from W1a's measured rate (`waves.md` Calendar).

- **Shape:** fourteen waves in three lanes on a serial warden spine. W1 to W4 each split in two.
- **Readiness:** W1–W3 are fully specified. W1a and W2a can start now.

| When | What you get |
|-|-|
| Days 1–8 | Raw alerts reach your Slack channel |
| From day 5 | `warden status --json` and a stub page show the factory |
| W5 (day 14) | Verified shipping returns for restarts and producer-backed config. Fleet code fixes follow project by project, as their holdouts bind on measurement |
| After W10 (day 26) | Full autonomous operation, once its gate passes |

Details: section 1b, *During the rewrite*.

### Will the factory eat my Max quota?

Not by design, and it will not waste it either. Max demand is already 120 % (109–144) of a weekly window per week before any factory judgment (`kpi/forecast`). So routine work and mother wakes run on IU.

- **Guard:** projects your burn for the rest of the cycle as p90 rate × hours to the reset.
- **Park order:** when the projection reaches 100 %, the guard parks improve first, then fleet, then your unattended waves. Unattended waves continue on IU with a Claude-class model.
- **Protected:** your interactive sessions and the waves you attend are never victims (ADR-008).
- **Resume:** parked work returns through the admission queue at the forecast's token rate, never in a burst.
- **Inverse rule:** late in light cycles, the factory spends capacity that would lapse. 3 of 7 cycles peaked at 55–79 %.

| Metric | Target / today |
|-|-|
| Owner interactive sessions blocked per cycle | Target 0 |
| Max lapsed % | Today p50 4 %, p90 30.6 % (`kpi/forecast`) |
| IU price of the spillover | D2 |

### Can I still open a herdr tab and just work?

Yes. The manual Claude Code + herdr lane is a rule of every wave, and `rd wave` keeps working after each one.

### Does Slack go away?

- **As an intake:** at once. It stops with the old warden (W1a), and the primary-source adapters replace it (W3a).
- **As a human channel:** it stays until three things replace what is posted there: Argo's notifications (W6), Hermes' briefings (W11) and the per-project changelogs (W13).

### What happens when the mini is down?

You get one push, from the VPS dead-man's switch.

- **Status:** Argo's VPS half says "mini unreachable since hh:mm".
- **Push:** the VPS dead-man's switch pushes to the phone after 15 minutes. Kuma cannot do it, because it shares the mini's house and power.
- **Everything else waits:** decision and heads-up pushes originate on the mini. Open decisions wait, with their expiries extended by the downtime (gameday row 13, `design/proof.md` §2).

## The design

### Is this a rewrite of warden?

Yes: rewrite and cutover, no co-running.

- **Cutover:** the old loop stops when W1a starts, and its database is archived read-only. History enters a fresh ledger by one import.
- **Go-live:** each rewritten piece goes live when it passes its own proof gate (backtest, gamedays, holdouts, the timed Argo test).
- **Up throughout:** only the build lane, your apps and their data, and the archived stores.
- **Rollback:** the legacy loop is a way back only until the new ledger performs its first external effect. The ledger records that moment. After it, a failure is fixed forward in the new ledger, never by restarting the old loop (`waves.md` W1a, *Rollback*).

### How do we know the design works before building it?

Four checks, all in section 7:

- **Golden set:** 959 labelled events with pre-registered thresholds.
- **Backtest:** it never tuned on its held-out half. Its numbers are v1's. The revised rules are accepted by W3b's frozen-output regression and blind replay.
- **Baseline gameday:** run against today's system.
- **KPI scripts:** the loop cannot edit them.

### Why did every previous model drift, and why would this one hold?

Prose claims held 1 of 11. Claims that code runs held 7 of 7.

So here every invariant is a capability limit with a test, a CI check or a generated file. Otherwise it is labelled `target`. The doc-contradiction lint, the generated blocks and the routing file make drift fail CI instead of failing silently.

### Why mothers at all, and why only six?

A mother pays for itself where planned work arrives continuously.

- **Rule:** ≥ 10 planned units and ≥ 25 commits a week over 90 days.
- **Picks:** basalt-ui, argo, weatherorb, shutterflow, dotfiles and warden.
- **Everywhere else:** a session per task is cheaper and enough.
- **Division of labour:** scheduling stays in code. Mothers spend tokens only on judgment.

### What does Hermes become?

The conversational door.

- **Does:** answers from the factory's read models, files briefs as Tasks, steers agents and asks `rd` for sessions. It uses the same verbs as Argo.
- **Loses every code tool:** a test enforces it, since a code-tool call is refused. W11 proves it by replaying the last 30 days of your requests to Hermes through the new Hermes, with zero file, code or commit tool calls.
- **Briefings:** generated from the event log. You get the Home digest plus one push with an audio link.
- **Retires:** the daily "Project narratives" cron that posts to Slack. Per-project changelogs in the brain take its place (W11, W13).

### What happened to the decision models?

There is no single-shot decision model in the loop. Yours become the investigate worker on OpenCode/IU. It makes the judgment calls, such as which recipe and which `decision_class` (ADR-003).

- **Why:** as a single shot, the decision model agreed 92 % with warden's LLM triage but only 60 % with the true grouping (`kpi/decision_shadow`).
- **Split:** deterministic rules group. The worker judges.

## Tooling choices

### Why not just adopt beads, a workflow engine, or Keep?

Each was measured on our data, and what each does well is copied.

| Tool | Measured result | Source | Copied |
|-|-|-|-|
| beads v1.3.1 | Cross-repo dependencies unenforced (0 of 9). Lease fixed at 5 minutes. Touches work repos even in contributor mode | spike 1 | beads' verbs and ready semantics |
| DBOS on SQLite | Survived every kill, but strands flows on a redeploy and adds a second system of record | spike 2 | durable primitives |
| Keep | Model is fingerprint fields plus attribute rules, no topology. F1 0.737 on the held-out golden set, no better than leaving every event alone (0.740). The proposed correlator's v1 rules scored 0.889 | spike 3 | Keep's candidate gate |

### Why not Mastra?

It was not run, and ADR-002 records why:

- It is TypeScript-only.
- The research could not verify its durability, suspend/resume and timeout semantics.
- It would add a TS runtime beside a Python loop, plus a second system of record, the same cost as DBOS.

### MCP or CLIs?

CLIs, on one agent contract (ADR-004).

- **The one failure:** spike 4's only systematic CLI failure was headless polling on a long job, at 95k tokens. One policy sentence fixed it (2 calls, 38.9k tokens).
- **Now in the CLI:** that behaviour moved into `--wait`, so the sentence is gone. `--wait` blocks to a budget the harness sets and exits `pending` with the exact resume command.
- **Single source:** commands are defined once in code. Help, docs, skill references and the global routing rules file are generated and drift-checked.
- **MCP remains** only for research-gateway (Claude Desktop) and chrome-devtools, until a browser CLI exists.
