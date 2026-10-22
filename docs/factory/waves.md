# Factory rewrite — waves

The rewrite-and-cutover plan for the factory design (`report.html`, ADRs in `adr/`). It
replaces Round 5 (`docs/waves/PLAN.md` of 2026-10-21, dispositioned below). The runnable copy is
`docs/waves/PLAN.md` once Round 5 is archived; this file is the design record.

**Rewrite, not co-run** (owner, 2026-10-22). The old factory layer — warden's loop, agent-gateway's
dispatch role, Argo's factory pages and snapshot pushes, Hermes' factory crons, Slack intake — stops
when its rewrite starts. Nothing runs beside the old path. A rewrite goes live when it passes its
own proof gate (held-out backtest, gamedays, holdouts, conformance suite, timed Argo test).
Shadow survives only as a proof method: replaying recorded history.

**What stays up the whole time** — the construction crane, not legacy:
- **The build lane:** herdr, Claude Code, `rd`, `/check`, `/review`, git, the CI runners, `make deploy`. Each piece is replaced in one cutover that leaves it working (`rd` in W4, `/check` and `/review` in W8); a wave that touches one proves it still works before close-out.
- **The owner's apps and their data:** weatherorb, shutterflow, free-planning-poker, rollhook, jkrumm.com, Argo's life pages and their Postgres, the homelab and vps services.
- **Every historical store, archived read-only:** `warden.db`, agw's job store, both OpenCode stores, Hermes' `state.db`, usage.db, the human-queue, transcripts. They seed the new ledger (one-time import), the known-error store and the golden set.

**Mode:** orchestrated from an orchestrator tab in the `dotfiles` herdr workspace; each wave is an
`RD_ORCHESTRATED=1 rd wave <repo>` tab in the repo it changes most, committing to each repo it
touches separately (basalt-ui: its own PR). One active wave per repo; three lanes in parallel.
Model: `RD_WAVE_MODEL` default; a wave that needs a stronger model says why in the spawn.

**Rules for every wave**
- Gate: `make check`, `/review` on every non-trivial diff, `make deploy`, `make verify`, and the wave's **proof gate** — a measured exit, never a waiting period.
- **Left behind is computed:** every open item becomes a Task with an owner (W1's `warden task add` from day one), never a bare line.
- New CLIs and services follow the agent-CLI contract (ADR-004) from their first commit.
- Every invariant a wave adds is enforced (test, CI check, generated file) or labelled `target` (postmortem rule).

## What stops when

| Old component | Stops | Replaced by |
|-|-|-|
| warden loop (intake, triage, dispatch, merge train, notify, reminders) | W1 start: LaunchAgents unloaded, `warden.db` archived read-only | W1 ledger, W3 intake → incidents, W4 tasks and agents, W5 ship |
| agent-gateway `dispatch` (implement, investigate) | W1 start (its only caller stops) | herdr workers through `rd` (W4); investigate as a read-only worker profile |
| Slack intake (warden's poller) | W1 start, with warden | primary-source adapters (W3); raw Kuma/HyperDX alerts still reach the owner's Slack channel until W6 |
| decide lane (`decision_shadow`) | W1 start | deterministic correlator + a decision-model step only on its ambiguous residue (W3, ADR-003) |
| Argo `/agents`, `/warden`, overview and snapshot pushes, warden action queue | W6 start | the factory read API and write verbs (W6) |
| agent-overview pane (`make agent-overview`) | W6 | Argo's Fleet view |
| Hermes factory crons (narratives, briefing reads of `warden.db`, watchdog summary) | W1 for the `warden.db` reads (stale data); W11 for the rest | briefings and changelogs projected from the event log (W11, W13) |
| agent-gateway's MCP server and deferred-tool path | W8 cutover | CLIs + skills (W8) |
| plannotator interim backend | W7 cutover | the `rv` service and Argo's Artifacts view (W7) |

## Calendar

```
day   1  2  3  4  5  6  7  8  9 10 11 12 13 14 15 16 17
A     W1 W1 W3 W3 W3 W4 W4 W4 W5 W5 W5 W10 W10 W10 W10 W14 W14     core loop
B     W2 W2 ·  ·  ·  W6 W6 W6 W6 W6 W7 W7 W7 W11 W11 W11            control plane, artifacts, Hermes
C     ·  ·  W8 W8 W8 W8 W8 W12 W12 W12 W9 W9 W13 W13                 tooling, telemetry, dotfiles, brain
```

Days are working days of wave time, not owner time; a gate that fails extends its wave, never skips
it. The factory is back to full autonomous operation when W5 passes (day 11); the old loop's
coverage gap (days 1–5) is covered by raw alerts in the owner's existing Slack channel.

---

## Wave 1 — A fresh ledger, history imported, the factory's own CLI            <!-- status: pending -->
Repo: warden (new code tree; the old loop is stopped first). ADR-011, ADR-002, ADR-004. Days 1–2.

- [ ] **Stop the old loop:** unload warden's LaunchAgents, record the final state (open items, queue) as an import input, archive `~/.warden/warden.db` read-only (`chmod 444`, plus a copy in the homelab bucket via `hl`). The manual build lane is untouched.
- [ ] **Fresh ledger** `~/.warden/ledger.db`: tables for the twelve nouns of `docs/factory/design/model.md` (§1), the `events` log (§4), and ADR-002's primitives (`operations` with idempotency keys, `timers`, `leases`, decisions with absolute deadlines). One write module per noun; `emit()` inside every state-changing transaction.
- [ ] **One-time import** (`warden import --from <archived warden.db>`): events → Signals (source time where the payload has it, fingerprints recomputed); items → closed Incidents with root cause, fix commits and verification evidence where present (the known-error seed); transitions and notifications → historical events; the 43 open `needs_decision` items → Decisions with defaults (ADR-014); open work items and the open Left-behind lines of every plan → Tasks with an owner. The golden-set labels (`docs/factory/evidence/golden/labels/`) attach to the imported incidents.
- [ ] **`warden` CLI on the agent-CLI contract** (cyclopts + pydantic; ADR-004): `warden signal|condition|incident|task|decision|event list/show`, `warden task add|claim|heartbeat|done` (bd's verbs and JSON names, ADR-001), `warden schema [cmd]`; generated `REFERENCE.md`; conformance suite.
- [ ] **Checks in `make check`:** one-writer (entity writes only from their module), projection rebuild (drop a read model, rebuild from `events`, compare), spike 2's kill harness (tests a–f, h) against the primitives, `PRAGMA integrity_check` in `make verify`; nightly off-box copy of `ledger.db`, restore tested once.
- [ ] **Proof gate:** import reconciliation — every archived event, item and transition accounted for (script, 100 %); the KPI scripts in `docs/factory/evidence/kpi/` re-pointed at `ledger.db` reproduce `baseline.out.json` for the archived window exactly; kill harness green.
**Left behind:**

## Wave 2 — Every project describes itself once, in one structure            <!-- status: pending -->
Repo: dotfiles (+ one `docs:` commit per repo; basalt-ui by PR; IuRoot sources in dotfiles-private). ADR-010. Days 1–2, parallel with W1.

- [ ] `config/factory/project.schema.json` (`design/model.md` §6) and `scripts/factory.py` on the agent-CLI contract: `factory manifest draft|check|gen`.
- [ ] **Directory contract** (`design/model.md` §6.1) for every repo: `project.yaml`, `docs/waves/`, `docs/adr/`, `docs/artifacts/`, `docs/notes/`, `.factory/` ignored; holdouts never in the repo. `manifest draft` creates what is missing (empty dirs get a one-line README), moves nothing that tools depend on without updating them.
- [ ] Drafts for all 33 SourceRoot repos from what exists (AGENTS.md *Verify & Monitor*, Makefile, `config/herdr/groups.json`, `docs/factory/evidence/signals/topology.out.json`, OTel service names; class from `docs/factory/evidence/projects/classify.out.json`); review and commit each. IuRoot: drafts in `dotfiles-private/projects/<repo>/`, linked into each work repo, listed in its `.git/info/exclude`.
- [ ] Generated outputs v1: herdr `groups.json`; the AGENTS.md block between `<!-- factory:begin -->` / `<!-- factory:end -->` (role, class, runtime, health, monitors, directory map); usage-tracker's project map.
- [ ] **Proof gate:** `factory manifest check` green on every repo — schema, every integration key resolves, generated blocks byte-equal to a re-render, the directory contract holds, topology covers every running container, launchd job and Kuma monitor (each blind spot filed with `warden task add`, e.g. 19 of 36 vps services unmonitored).
**Left behind:**

## Wave 3 — Signals to incidents: intake, reconcilers, correlator, known errors            <!-- status: pending -->
Repo: warden (+ homelab, vps for the Docker event recorders). ADR-013, ADR-003, loops §1–2. Needs W1, W2. Days 3–5.

- [ ] Signal envelope (`source, subject, kind, severity, fingerprint, occurred_at, raw`); `subject` resolved through the manifests' topology; `occurred_at` is source time, never poll time.
- [ ] Adapters: Kuma webhook (pairs Up with Down by monitor id), HyperDX webhook, RollHook deploys (job webhook or ClickStack deploy markers), GitHub Actions failures and issues (`gh` poll), Beszel (Shoutrrr webhook); a Docker events recorder per host (homelab, vps) pushing to ingest. Watchtower notifications retire (archived upstream).
- [ ] Health reconciler per project (desired = manifest probes and monitors; observed = signals plus a direct probe) opening and closing Conditions; resync timer plus signal-scheduled runs.
- [ ] Correlator per ADR-003 with the parameters frozen by the backtest; known-error match against imported and new closed incidents; regression link; the decision-model step only for the ambiguous residue ADR-003 names, on IU.
- [ ] Restart recipe (known error *container down, manual stop or crash*): `make -C <project> restart svc=<name>`, verified by health green and the condition resolving; rate-limited per ADR-012.
- [ ] **Proof gate:** the held-out golden-set backtest passes `docs/factory/evidence/golden/PREREGISTRATION.md` on the live code (replay of recorded history); the 2026-10-17 VPS reboot replay produces one incident candidate and 0 pages; gameday row 1 (glance stopped) live: one incident, restart recipe, health green, closed on observation, 0 owner touches, MTTR ≤ 5 min; 48 h of live operation with every Kuma Down/Up pair producing exactly one Condition open and close.
**Left behind:**

---

## Wave 4 — Tasks, one spawner, agents that never wait for the owner            <!-- status: pending -->
Repos: warden, dotfiles (`rd` — one cutover). ADR-001, ADR-007, ADR-008. Days 6–8.
- [ ] Ready queue, claim leases, plan projector; `rd` writes Agent and Attempt records, cuts hooks (`.factory/attempt.md`), sets tab metadata; Hermes' herdr skill calls `rd`.
- [ ] Witness: resume at the quota reset, auto-continue after transient API errors, re-drive stuck or dead agents from the hook, reap finished tabs (absorbs Phase 0's janitor); engine by class and the quota guard.
- [ ] Gate: spike 1's oracle; gameday rows 6–9; `rd wave`/`rd agents` proven; 0 spawns outside `rd`.

## Wave 5 — Ship: verification replaces approval            <!-- status: pending -->
Repos: warden, holdouts (new, private), each fleet repo. ADR-012. Days 9–11.
- [ ] Merge train with squash merges and automatic revert; deploy and post-deploy verify; ladder per action class from the manifests; runaway breaker; rate limits; ≥ 5 holdout scenarios per fleet project (drafted per open decision D4).
- [ ] Gate: gameday rows 1, 10–12; revert success 100 % on injected failures. Full autonomous operation resumes.

## Wave 6 — Decisions and Argo as the control plane            <!-- status: pending -->
Repos: warden, argo, basalt-ui (PR), vps. ADR-009, ADR-014, ADR-015, `design/argo.md`. Days 6–10 (lane B).
- [ ] Decision entity with options, reversible default, expiry; push tiers; the imported decisions drained under ADR-014.
- [ ] Factory read API on the mini (read models of `design/argo.md` §2) and the write verbs of ADR-015, each writing an intent entity executed by a reconciler or `rd`; delete the snapshot pushes and the action queue; VPS dead-man's switch.
- [ ] Views: situation-adaptive Home, capability-composed Project pages, Needs you, Incidents, Fleet, Artifacts (read side), Health, Usage, Traffic; basalt-ui lands the event list, upstreams status chip, decision card and entity card, builds the lifecycle strip.
- [ ] Gate: the timed Argo test on phone and desktop; every write verb exercised end to end with its audit event; gameday row 13.

## Wave 7 — Artifacts are ours            <!-- status: pending -->
Repos: warden (`rv` service and CLI), argo, basalt-ui (PR: comment-thread export). ADR-005. Days 11–13.
- [ ] `rv submit|wait|status|comment` on the agent-CLI contract; Artifact entities in the ledger; versions stored per repo in `docs/artifacts/<slug>/`, threads as anchored comments (quote + prefix + suffix); plannotator's semantics kept (supersedes, wait-for-reply, global sequence).
- [ ] Argo Artifacts view with anchored threads, project-grouped inbox, phone layout; basalt-ui gains the comment thread as a package export in its own PR.
- [ ] Gate: the spike-5 `rv` contract suite against the new service; a review round trip from phone and desktop; plannotator retired.

## Wave 8 — CLI-first tooling (the former W11)            <!-- status: pending -->
Repos: agent-gateway, email-, audio-, image-gateway, warden, dotfiles (skills). ADR-004. Days 3–7 (lane C).
- [ ] Contract libraries: Python (cyclopts + pydantic) and the TS/Bun equivalent chosen in ADR-004; one conformance suite for both.
- [ ] CLIs for agw (review, check, prose, narrative, read_image, read_drawing, decide), email, audio and image gateways; generated help, `REFERENCE.md`, each skill's `references/cli.md`, the AGENTS.md routing block; CI drift check.
- [ ] Skills move onto the CLIs in one cutover each: `/check`, `/review`, `/otel`, `/prose`, `/excalidraw-diagram`, dispatch-era skills retired; agw's MCP server and the deferred-tool path removed; MCP registration shrinks to research-gateway (plus chrome-devtools until a browser CLI replaces it).
- [ ] Gate: conformance suite green on every CLI; `/check` and `/review` proven on two repos after the cutover; the long-job policy sentence in every routing block.

## Wave 9 — One trace per item            <!-- status: pending -->
Repos: warden, agent-gateway, research-, email-, audio-gateway, dotfiles. ADR-006. Days 11–12 (lane C).

## Wave 10 — Improve and heal on the same path            <!-- status: pending -->
Repos: warden (+ Renovate config per repo). Loops §6. Days 12–15.

## Wave 11 — Hermes becomes the door            <!-- status: pending -->
Repo: hermes-agent. Days 14–16 (lane B).
- [ ] Capability limit with a test: no file, code-execution or code-writing terminal tools; a terminal allowlist of factory CLIs.
- [ ] Reads only the factory read API and CLIs; files Tasks and asks `rd` for sessions; briefings (morning, evening) generated from the event log, delivered as Argo threads with audio; the "Project narratives" cron retires (its job moves to W13's changelog projection); Slack posting exits.
- [ ] Gate: 7 days of `state.db` with zero file or commit tool calls; briefings reproduce from events.

## Wave 12 — dotfiles rewired            <!-- status: pending -->
Repo: dotfiles. Days 8–10 (lane C).
- [ ] Generated routing everywhere (manifests + CLI contract); skills diet (each skill = when to use + judgment, flags generated); launchers consolidated; global CLAUDE.md and AGENTS.md generated blocks; doc-contradiction lint; concept-budget check; the security-policy line aligned with ADR-014; the telemetry settings fix (ADR-006).
- [ ] Gate: doc-contradiction lint and drift checks green across all repos; `make check` green on both machines.

## Wave 13 — Brain projections and per-project changelogs            <!-- status: pending -->
Repos: brain, warden (projector). Days 13–14 (lane C).
- [ ] Each project's brain note gains generated sections (status, links, changelog) from the manifest and the event log; `changelog.target` honoured (brain by default, repo for libraries with release notes); one writer for the vault.
- [ ] Gate: every project note re-renders from events; no Slack changelog left.

## Wave 14 — Archive, retention, docs, website            <!-- status: pending -->
Repos: dotfiles, brain, jkrumm.com. Days 16–17. Last.
- [ ] Historical stores archived under open decision D5's default; retention jobs; generated docs replace hand-written restatements; jkrumm.com's guide rewritten from the new model.

---

## Round 5 disposition

| Round 5 wave | Disposition | Where |
|-|-|-|
| W1 Constitution | **merge** — the model is generated from manifests and ADRs; CodeRabbit removal kept as a chore | W2, W12 |
| W2 Escalation cut | **done in part** (Phase 0: agw W12; warden W8 closed early — the rewrite stops the old loop); timeout default → W6; improve loop → W10; shadow promotion → **drop** (the decision model keeps only the correlator's ambiguous residue, ADR-003); rebase-merge revert → W5; Argo `adopt` verb → **drop** (write verbs, ADR-015) | Phase 0, W3, W5, W6, W10 |
| W3 Execution layer | **done in part** (Phase 0: recorder, janitor); tab metadata and one launcher → W4; overview truth → W6; Obsidian 1706 → imported as a Decision with a default | Phase 0, W1, W4, W6 |
| W4 Implementation into herdr | **keep**, unblocked by ADR-008 | W4 |
| W5 Thin Hermes | **keep**, widened: Hermes becomes the door | W11 |
| W6 Argo control plane | **keep**, redesigned from the owner's questions plus write verbs | W6, W7 |
| W7 Slack retirement | **merge** — intake stops with warden (W1); human posting exits in W6, W11, W13 | W1, W6, W11, W13 |
| W8 Brain door | **merge** | W13 |
| W9 Observability | **keep** | W9 |
| W10 Docs and website | **keep**, last | W14 |
