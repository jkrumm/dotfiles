# Factory design — brief

For a design session: Opus, max effort, herdr tab `factory` in the SourceRoot workspace,
cwd `~/SourceRoot`. Written 2026-10-22 by session `94025058` from the owner's prompt of
that day. Output folder: `~/SourceRoot/dotfiles/docs/factory/`. **dotfiles is a public
repo:** no hostnames, IPs, tokens or IuRoot content beyond repo names; `~` paths only.

## The ask

Design the next generation of my autonomous solo-dev factory from evidence, prove it,
and hand me a migration I can run. Depth over breadth: settle the dozen decisions
everything else hangs on, and defer the rest to waves with a named owner.

1. **Start from raw records, not summaries.** The warden ledger (1,752 events since
   April), agw jobs, the OpenCode and Hermes stores, 8.3k Claude Code transcripts, the
   human-queue, usage.db, every repo's git history, and the primary signals behind
   Slack. Measure the baseline, reconstruct the ten worst incidents and the twenty
   latest times I had to step in, and explain why every "locked" model since the
   September estate round drifted within days.
2. **Define the model once.** At most twelve nouns, exactly one system of record per
   entity, lifecycles as state machines, one event log, and a per-repo project
   manifest (committed in SourceRoot, gitignored in IuRoot) that generates AGENTS.md
   routing, Argo's project pages, warden policies, the Beads/TickTick/Obsidian
   projections and telemetry identity.
3. **Redesign warden as a self-healing loop:** level-triggered reconcilers;
   correlation by fingerprint, topology and time window; a known-error store that
   recognises regressions and reuses past fixes; a verification ladder per action class
   that makes self-approval principled; durable execution that survives crashes;
   recurring improvement and infra-healing jobs on the same path. One outage is one
   incident, not sixteen pages.
4. **Decide build vs adopt with spikes on real data** — beads, a durable engine,
   correlation, CLI vs MCP, artifact review, telemetry, agent topology — each ending in
   an ADR.
5. **Design Argo from my questions:** list what I ask every day, derive the read model
   that answers each, then the views; settle where Argo runs and what basalt-ui must
   gain.
6. **Prove it with evidence that is neither your opinion nor mine:** a labelled golden
   set scored with B-cubed, a backtest of escalation precision and recall, a gameday
   catalogue of real past failures with one run against today's system, KPIs from
   read-only scripts, holdout scenarios, a timed Argo test.
7. **Challenge it** with an expert panel at least twice and resolve every objection.
8. **Deliver one dense HTML report:** verdict, baseline, model, loops, decisions, Argo,
   proof, panel, a strangler migration as waves (the first three ready to run, Round 5
   dispositioned), at most five open business decisions with defaults, and an FAQ.

## Why it is shaped like this

- **What a top professional adds:** a postmortem of the previous rounds before any
  redesign; desired state plus level-triggered reconciliation as the keystone
  (self-healing, dedup and Argo's project page fall out of one diff); one system of
  record per entity; autonomy as an SLO whose evaluation harness exists before the
  system; a concept budget (delete before adding); boring tools for commodity work
  (Renovate, CrowdSec, an existing durable engine) and agents only where judgment is
  needed; a migration that never stops the factory, with no-regret fixes shipped now.
- **Rawest material:** the stores in `findings-2026-10-22.md` § *Raw material*, not
  the drawings, prose, AGENTS.md or Slack relays (63 % of warden's signals came through
  Slack).
- **Methods:** event storming, Harel statecharts, Kubernetes-style reconcilers,
  Sentry-style fingerprint refinement, topology and time-window correlation, a
  known-error store, entity-centric B-cubed scoring, shadow mode, holdout scenarios,
  gamedays, DORA's five metrics, SRE toil accounting, MADR ADRs off time-boxed spikes,
  a question inventory with exception-first dashboard design and timed tests.
- **Outside proof:** ledger replay, gamedays, read-only KPI scripts, holdouts, the
  timed Argo test, CI structural checks, convergence with mature prior art.

## Fixed — do not debate

- **Security boundary:** Tailscale plus the owner's GitHub identity. Do not raise auth,
  exposure or hardening questions. Detecting and blocking anomalies and attacks is in
  scope as an ops capability.
- **The owner decides business questions only** (product direction, spend,
  irreversible data loss, other people), target ≤ 0.1 % of items. Strong verification
  replaces human gates; never add an owner gate as a safety measure.
- herdr is where code gets written. Engines: Claude Code on Max, OpenCode on IU models.
  Gateways are tools.
- basalt-ui is Argo's UI framework and matures with it (its own commits and PRs).
- Anything may be rewritten or deleted: warden, Argo, Hermes, agw's role, rd and waves,
  MCP. Round 5's locked model is the baseline, not a constraint.
- Never break the lane used to fix things: the manual Claude Code + herdr path keeps
  working through every migration step.
- English artifacts; no model ids in prose (they live in `agw routing`).

## Read first — do not re-derive

1. `findings-2026-10-22.md` — raw-material inventory, baselines, owner inputs
   (drawings, MacBook artifact-review discussion), verified prior art.
2. The owner's own words: sessions `94025058…` (2026-10-22) and `b224d6e5…`
   (2026-10-21), first user message each (`find ~/.claude/projects -name '<id>*.jsonl'`).
3. `~/SourceRoot/dotfiles/docs/waves/PLAN.md` — Round 5: model, KPIs, *Established
   facts*. Cite them; do not re-measure.
4. `research/*.md` — five cited reports. New research goes through `/research`, never
   memory.
5. dotfiles `AGENTS.md`, `docs/agent-platform.md`, `docs/architecture.md`,
   `docs/global-reference.md` and every repo's AGENTS.md — claims to verify; Round 5
   found them contradicting each other.

## Method

**Phase 0 — stop the bleeding (first hour, in parallel).** Some Round 5 fixes survive
any redesign: W2's host read verbs for investigate (≈ 30 of 74 escalations), folding
co-firing alerts and auto-closing recovered `slack_alert`/Kuma items, closing terminal
non-questions, never dropping features, draining `awaiting_owner`; W3's herdr event
recorder (raw material lost daily) and the tab janitor. Launch exactly those that no
open decision here can invalidate, as `rd wave <repo>` tabs briefed from the plan's
wave text, and record what you launched and why.

**Phase 1 — evidence.** Every number comes from a re-runnable script in `evidence/`,
its output stored next to it.
- Baseline, one definition each: autonomy rate (owner touches / items),
  genuine-escalation share, time to resolve (median, p90), reopen and regression rate,
  revert rate, rework share per repo, DORA five where data allows, cost per resolved
  item, Max headroom, herdr hygiene.
- Postmortem: the archived plans (dotfiles and agent-gateway `docs/waves/archive/`),
  every *Left behind*, Round 5 and git history. Which parts of each locked model held,
  which drifted, and why. Design against the failure that repeats.
- Follow-the-item: the ten costliest incidents (pages, duration, tokens) and the twenty
  latest owner interventions (human-queue, `needs_decision` resolutions, owner messages
  in transcripts that correct or unblock an agent), raw signal to closure, each with
  what the ideal system would have done.
- Golden set: ≥ 400 warden events by entity-centric sampling, labelled with true
  incident group, root cause, genuine owner decision (y/n) and known fix (y/n). Derive
  labels from outcomes and fix commits; mark the uncertain ones.
- Toil: what the owner and agents repeat by hand (MacBook shell history, transcripts'
  Bash calls, recurring item types).

**Phase 2 — the model.**
- Glossary of ≤ 12 nouns (candidates: Project, Signal, Condition, Incident, Task,
  Attempt, Change, Deployment, Verification, Artifact, Agent, Decision). Per noun:
  system of record, statechart, invariants, id scheme.
- SoR table: one owner per entity. Beads, TickTick, Obsidian, Argo and AGENTS.md are
  projections with a named projector. No two-way sync without an ADR. Decompose
  warden's 65-column row as the worked example.
- One append-only event schema that every loop writes, carrying trace ids. Argo's read
  models and the briefings derive from it.
- The project manifest: schema (Backstage `Component` envelope — name, type,
  lifecycle, owner, repo slug — plus OpenSLO terms where an SLO exists), location
  (committed in SourceRoot, gitignored in IuRoot), contents (identity and class — fleet
  or session; runtime and deploy targets; health and SLO probes; maintenance policies;
  integration keys for Beads, TickTick, brain note, herdr workspace, OTel services, Kuma
  monitors, usage project; changelog target), everything generated from it, and the
  drift check. Map every repo in a table and classify fleet vs session from evidence
  (commit volume, open plans, incident load), not taste.

**Phase 3 — the loops.**
- **Reconcile:** per-project reconcilers compare desired (manifest) with observed
  (health, deployed sha, CI, dependency age, docs age, herdr state) and open or close
  Conditions. Webhooks and alerts only schedule a reconcile. Show the 10-17 outage
  (sixteen pages) becoming one incident.
- **Correlate:** fingerprints as refinements of a default (Sentry style), topology from
  the manifest (host → container → service → project), time windows, promotion from
  signal to candidate to incident (Keep's gate). A regression is a known fingerprint
  recurring after its fixing change. A known-error store holds fix recipes linked to
  commits and verification evidence and is consulted on every new incident.
- **Verify:** a ladder per action class (restart, config, dependency bump, code fix,
  migration, infra) naming the evidence that authorises auto-ship (checks, holdout
  scenarios, health and canary, post-deploy verify), the automatic rollback,
  blast-radius and rate limits, and the runaway-loop breaker.
- **Durable execution:** pick an engine, or none, for warden and fleet flows by crash
  semantics (an OpenCode restart kills episodes; herdr crashes; the mini reboots),
  idempotency keys, leases and heartbeats, timers, and await-decision with
  default-on-timeout. The current SQLite ledger with explicit statecharts is a valid
  answer.
- **Agents:** mother → lead → worker for fleet projects, sessions for the rest, Hermes
  as the conversational door. One spawner. Lifecycle including rotation, compaction,
  handover and reaping. Copy or reject Gas Town's roles explicitly (the hook owns the
  work; Witness and Deacon patrol; Refinery merges).
- **Improve and heal:** recurring jobs as reconcilers over scorecards — dependencies
  (Renovate for the mechanical part), docs drift, oversized files and duplication
  (`/analyze`), bloated Claude Code setups, basalt-ui dogfooding, performance and OTel
  regressions, GitHub issues; infra on mini, homelab and VPS (containers, databases,
  ClickHouse, disk, certs, backups); anomaly and attack detection. All of it enters
  through the same correlation and verification path.
- **Quota and cost are control inputs:** Max 5 h and 7 d windows and IU spend schedule
  non-urgent work. Decide Round 5's open engine question here, with numbers.

**Phase 4 — spikes, then ADRs.** At most 2 h each, on real data, in scratch
worktrees. Results go in `spikes/`, decisions in `adr/` (MADR).
1. beads as the task SoR: shared Dolt server vs per-repo; `bd ready` and claim leases
   driving a mother; IuRoot via contributor routing. Compare with extending the warden
   ledger.
2. Durable engine: one warden flow (alert → investigate → fix → verify) on the top two
   candidates, killed mid-step, recovery measured.
3. Correlation: the proposed grouping over the golden set, compared with Keep's model.
4. CLI vs MCP: three gateways (agw review/check, research, email). Measure tokens in
   context, calls to success, latency and failure modes. Design an AGENTS.md routing
   block generated from CLI schemas, plus its drift check.
5. Artifact review: plannotator on the mini vs the review-service sketch vs
   human-review. Criteria: Markdown, inbox, project grouping, comments agents read back
   durably, Argo integration.
6. Telemetry: Claude Code traces, OpenCode and the gateways into one ClickHouse; one
   trace from a warden item through a herdr worker to a gateway call.

**Phase 5 — Argo from questions.**
- Write ≥ 15 owner questions first. Examples: "Is anything broken?", "What shipped
  since yesterday, and did it stick?", "What needs me, and what happens if I ignore
  it?", "Is project X healthy (cost, traffic, deps)?", "Which agents are running, which
  are stuck, which are done but still open?", "What did warden fix alone this week?",
  "What burns quota?". Each → read model → view.
- IA: Home (cockpit), Project (start from the wireframe), Needs attention, Incidents,
  Fleet, Artifacts, Health/infra, Usage/cost, Traffic. Exception-first: when nothing is
  wrong, one line says so.
- Hosting (VPS, mini or split), decided by availability and data locality, with an
  off-box dead-man's switch for the mini whichever you choose.
- basalt-ui: the components that exist, the ones to build and upstream, and the
  dogfooding loop.
- Wireframes in the report, built from real Phase 1 numbers.

**Phase 6 — proof.**
- Backtest the triage and correlation design on the golden set: B-cubed precision and
  recall, escalation precision and recall (no genuine decision auto-closed), and the
  share that would have resolved without the owner. Fix the thresholds before running.
- Gameday catalogue: ≥ 10 failure modes from history (a power event leaving a disk
  unmounted, disk floor during builds, credential expiry, OpenCode server restart,
  herdr crash, quota exhaustion, failed deploy, broken dependency, flaky CI, crashed
  container). For each: injection method, expected path, pass criteria (zero owner
  touches, MTTR target). Run at least one reversible fault on a non-critical service
  against today's system now. If nothing heals it, restore it yourself and record the
  timings.
- KPIs and SLOs for the factory, from read-only scripts nothing in the loop can edit:
  baseline, target, error budget.
- Holdout scenarios per fleet project, stored outside agent-writable scope and run
  after deploy.
- Argo test: every question answered from Argo alone in ≤ 10 s, on phone and desktop.
  Instrument "left Argo to find out".
- CI structural checks: one SoR per entity, zero drift in generated docs, a
  doc-contradiction lint, the concept budget.

**Phase 7 — the panel.** The owner authorised multi-agent orchestration for this
("use docs, brain wiki, research-gateway, multiple tabs and agents however needed";
"mix of experts and different roles"). Each expert gets the draft and the evidence and
returns objections, each with a severity and the test that would settle it:
- **SRE:** would it have healed the last ten real incidents untouched?
- **Correlation scientist:** merge and split failures; precision and recall.
- **Durable-systems engineer:** a crash mid-step, idempotency, exactly-once side
  effects, leases.
- **Autonomy and verification engineer:** evidence per action class, rollback, runaway
  loops. Enable autonomy; never add owner gates.
- **Data architect:** one SoR per entity, every view computable from the log, manifest
  completeness.
- **Platform/DX engineer:** one-command onboarding, generated AGENTS.md, CLI vs MCP,
  skills.
- **Operator-UX designer:** the questions answered in ≤ 10 s, the quiet state, density
  without noise.
- **Cost and capacity planner:** cost per resolved item; behaviour at 90 % weekly
  quota.
- **Simplifier:** what was deleted, and can the owner draw the system from memory?
- **Migration lead:** the factory ships at every step; rollback per step.

Resolve every objection with a changed design, an explicit tradeoff, or an open
decision. Then run the panel again on the revision. Two full passes minimum. Finish
with `/review` of the report and ADRs as an independent cross-lab read.

**Phase 8 — migration.** Strangler: event log and manifest first, then one flow at a
time in shadow (the existing decision-shadow pattern) until it beats the old one on
Phase 6 metrics. A Round 5 disposition table (keep, merge or drop, per wave). A wave
plan in the `/wave` format, with acceptance criteria tied to Phase 6 metrics; the first
three waves fully specified and ready to run.

## Deliverables (`~/SourceRoot/dotfiles/docs/factory/`)

- `report.html` — self-contained, dark and light, dense. Sections:
  1. Verdict, on one screen: the target in ten lines, the decisions taken, the open
     owner decisions, the numbers.
  2. Baseline and postmortem.
  3. Model: glossary, SoR table, statecharts, event schema, manifest schema and repo
     mapping.
  4. Loops.
  5. Decisions: ADR index and spike results.
  6. Argo.
  7. Proof.
  8. Panel: each objection and its resolution.
  9. Migration and waves.
  10. Open decisions: business only, ≤ 5. Each has a question, two options, the
      tradeoff, a recommendation, and a default with expiry.
  11. FAQ: the obvious questions, answered.

  Diagrams via `/archify`, charts via `/dataviz`. Every claim links its evidence
  (file:line, query or citation). Write prose sections in the voice of
  `~/SourceRoot/brain/voice.md` and polish them with `/prose`.
- `adr/`, `evidence/` (scripts, outputs, golden set), `spikes/`, `waves.md`, and
  `STATUS.md` (checkpointed after every phase so a fresh context can resume).
- The SourceRoot memory note `factory-design`, updated to point at the report.

## Done when

- Every number in the report reproduces from `evidence/`, every decision has an ADR
  with evidence, the backtest ran and one baseline gameday ran.
- Both panel passes are resolved, with at most five open decisions, all business.
- The first three waves can start without another question.
- Committed and pushed (dotfiles is direct-to-master; `docs:` commits). The final
  message tells the owner how to open the report on the MacBook and lists the open
  decisions.

## Working rules

- Stay the orchestrator. Use Explore agents for sweeps, `/research` for prior art (deep
  where a decision rides on it), and workflows or parallel agents for labelling and the
  panel. Keep raw dumps out of your context.
- Check Max usage before large fan-outs. Prefer cheaper workers for bulk work whose
  output you verify.
- The only production changes in this session are the Phase 0 waves and the baseline
  gameday. The rebuild happens in the waves you plan.
- If context runs short, checkpoint `STATUS.md` and continue in a fresh tab through
  `/wave`. Never hand a plan back to the owner when the work was asked for.
- Write for the owner: dense, sharp, technical, no filler.
