# Factory rewrite — waves

The rewrite-and-cutover plan for the factory design (`report.html`, ADRs in `adr/`). It
replaces Round 5 (`docs/waves/PLAN.md` of 2026-10-21, dispositioned below). The runnable copy is
`docs/waves/PLAN.md` once Round 5 is archived; this file is the design record.

**Rewrite, not co-run** (owner, 2026-10-22). The old factory layer — warden's loop, agent-gateway's
dispatch role, Argo's factory pages and snapshot pushes, Hermes' factory crons, Slack intake — stops
when its rewrite starts. Nothing runs beside the old path. A rewrite goes live when it passes its
own proof gate (held-out regression check, gamedays, holdouts, conformance suite, timed Argo test).
Shadow survives only as a proof method: replaying recorded history. Every wave names a
**Rollback** — a tested way back, not co-running.

**What stays up the whole time** — the construction crane, not legacy:
- **The build lane:** herdr, Claude Code, `rd`, `/check`, `/review`, git, the CI runners, `make deploy`, and agw `dispatch` until W4's worker profiles pass (it stops at the W4 cutover). Each piece is replaced in one cutover that leaves it working: the new binary or skill installs beside the old one and switches by one symlink flip after its gate, the old one kept for one wave (`rd` in W4, `/check` and `/review` in W8); a wave that touches one proves it still works before close-out.
- **The owner's apps and their data:** weatherorb, shutterflow, free-planning-poker, rollhook, jkrumm.com, Argo's life pages and their Postgres, the homelab and vps services.
- **Every historical store, archived read-only:** `warden.db`, agw's job store, both OpenCode stores, Hermes' `state.db`, usage.db, the human-queue, transcripts. They seed the new ledger (one-time import), the known-error store and the golden set.

**Mode:** orchestrated from an orchestrator tab in the `dotfiles` herdr workspace; each wave is an
`RD_ORCHESTRATED=1 rd wave <repo>` tab in the repo it changes most, committing to each repo it
touches separately. One active wave per repo; three lanes.
- **warden is the serial spine** (lane A): one warden wave at a time. Parallel warden work (W2, W9, W13) runs only in a separate worktree with a declared merge order, stated in its wave.
- **Every spawn names its engine:** lane A on Claude Code/Max (`RD_WAVE_MODEL` default); lanes B and C on OpenCode/IU (`rd wave --kind opencode`). A wave that needs a stronger model says why in the spawn.
- **Quota rule:** at a 7-day Max reading ≥ 80 % only lane A runs; B and C resume below it. The 7-day reading sat at ≥ 82 % a quarter of the time over 45 days (p75, `evidence/kpi/quota.out.md`), so the calendar counts quota-available days, not calendar days.

**Rules for every wave**
- Gate: `make check`, `/review` on every non-trivial diff, `make deploy`, `make verify`, and the wave's **proof gate** — a measured exit, never a waiting period.
- **Rollback:** every wave states one, below its gate.
- **Left behind is computed:** every open item becomes a Task with an owner (W1's `warden task add` from day one), never a bare line. An item with no named owner defaults to the project's mother (fleet class) or the planner queue (session class).
- **homelab-private stays self-contained:** its manifest and topology live inside homelab-private; every generated output (groups, usage map, AGENTS.md blocks, rendered registries, Argo) excludes it.
- **PR-required repos go by PR** (`config/pr-required-repos.json`: basalt-ui, free-planning-poker, rollhook, rollhook-action); every other SourceRoot repo direct to its default branch.
- New CLIs and services follow the agent-CLI contract (ADR-004) from their first commit.
- Every invariant a wave adds is enforced (test, CI check, generated file) or labelled `target` (postmortem rule).

## What stops when

| Old component | Stops | Replaced by |
|-|-|-|
| warden loop (intake, triage, the `decision_shadow` decide lane, merge train, notify, reminders), its push monitors and the jobrun canary's warden leg | W1 start: LaunchAgents unloaded (plists kept on disk), tag `warden-legacy`, `warden.db` archived read-only | W1 ledger, W3 intake → incidents, W4 tasks and agents, W5 ship |
| `warden run` lane (global CLAUDE.md lane table, `rd` help, the wave skill) | W1, one commit | `warden task add` |
| agent-gateway `dispatch` (implement, investigate) | W4 cutover — it counts as build lane until W4's worker profiles pass | herdr workers through `rd` (W4); investigate as a read-only worker profile on OpenCode/IU |
| agw `decide`, `triage`, `narrative`, `investigate` tools | before W8 (W8's first bullet) | correlator (W3), investigate worker (W4), W13's changelog rendering |
| Slack intake (warden's poller) | W1 start, with warden | primary-source adapters (W3); raw Kuma alerts, and HyperDX re-pointed at the Slack webhook, reach the owner's Slack channel on days 1–5, until W3 opens Conditions |
| Argo `/agents`, `/warden`, overview and snapshot pushes, warden action queue | W1: frozen (stale, no writes); W6 start: deleted | the factory read API and write verbs (W6) |
| agent-overview pane (`make agent-overview`) | W6 | Argo's Fleet view |
| Hermes factory crons (narratives, briefing reads of `warden.db`, watchdog summary) | W1 for the `warden.db` reads (stale data); W11 for the rest | renderings of the one digest projection (W11, W13) |
| agent-gateway's MCP server and deferred-tool path | W8 cutover | CLIs + skills (W8) |
| plannotator interim backend | W7 cutover | `warden artifact` (the factory CLI and API) and Argo's Artifacts view (W7) |

## Calendar

{{asset:rewrite-plan}}


```
day  1   2   3   4   5   6   7   8   9   10  11  12  13  14  15  16  17  18  19  20  21  22  23
A    W1  W1  W3  W3  W3  W4  W4  W4  W5  W5  W5  W6  W6  W6  W6  W6  W7  W7  W7  W10 W10 W10 W10  warden spine (Max)
B    W2  W2  ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   W11 W11 W11 W13 W13 ·   ·    manifests, Hermes, brain (IU)
C    ·   ·   ·   ·   ·   ·   ·   ·   W8  W8  W8  W8  W8  W12 W12 W12 W9  W9  ·   ·   ·   W14 W14  tooling, dotfiles, telemetry, docs (IU)
```

≈ 23 working days on the warden spine (W1 2 + W3 3 + W4 3 + W5 3 + W6 5 + W7 3 + W10 4), counted
in quota-available days of wave time, not owner time; a gate that fails extends its wave, never
skips it. Lanes B and C idle where every free wave would touch dotfiles while W4 holds it (days
6–8) or needs a spine wave first: W8 needs W4's cutover (agw's investigate tool goes before it),
W11 needs W6's read API. Warden worktrees merge in this order: W2's `warden manifest` after W1's
close-out (day 2), W9's after W7's (day 19), W13's after W10's (day 23).

What returns when: raw alerts in Slack on days 1–5; Conditions and the restart recipe at W3 (day
5); investigation and fixes through workers at W4 (day 8); verified shipping at W5 (day 11) —
incident-to-ship autonomy; improve and heal at W10 (day 23) — full autonomous operation.

---

## Wave 1 — A fresh ledger, history imported, the factory's own CLI            <!-- status: pending -->
Repo: warden (new code tree; the old loop is stopped first). ADR-011, ADR-002, ADR-004. Days 1–2, lane A.

- [ ] **Consumer inventory first:** a generated list of every consumer of the old warden (grep of all SourceRoot repos and `docs/architecture.md` for warden, its API port and its ingest paths), each with a disposition, committed before anything stops. Known dispositions: HyperDX re-pointed at the Slack webhook for days 1–5; the two warden Kuma push monitors and the jobrun canary's warden leg removed; Hermes' `warden.db` reads stopped; Argo's warden page and action queue frozen; jobrun alert sources re-pointed. A consumer the list misses is a gate failure, not a Left-behind line.
- [ ] **Stop the old loop:** tag the warden repo `warden-legacy`; unload warden's LaunchAgents and keep the plists on disk; record the final state (open items, queue, open PRs, in-flight deploys, operations with no outcome) as an import input; archive `~/.warden/warden.db` read-only (`chmod 444`, plus a copy in the homelab bucket via `hl`). The manual build lane is untouched.
- [ ] **Retire the `warden run` lane** in one commit: the global CLAUDE.md lane table, `rd` help and the wave skill point at `warden task add` instead. agw `dispatch` stays in the lane table until W4.
- [ ] **Fresh ledger** `~/.warden/ledger.db` with `synchronous=FULL`: tables for the eleven nouns of `docs/factory/design/model.md` (§1), the `events` log (§4), and the plumbing of ADR-002 — `operations` with generation keys (`<entity>:<kind>:<generation>`, the generation read from ledger state in the same transaction), `timers`, `leases`, `deliveries`, decisions with absolute deadlines. One write module per noun; `emit()` inside every state-changing transaction.
- [ ] **Epochs:** every lease grant (task claim, agent, merge slot) issues a monotonic epoch, written into the hook; every mutating call carries it and a stale epoch is rejected. Git effects are fenced by `push --force-with-lease=<ledger sha>` and merge `sha=`.
- [ ] **Effect registry:** every external side effect goes through one module that records an `operations` row and declares its strategy — native key; natural key + lookup on conflict (PR by head branch `factory/<task>/<agent>`, merge with GitHub's expected-head `sha=`, revert branch `revert/<change>`); probe before retry (deploy: read the deployed version; restart: read the container's start time); at-most-once with receipt (push notifications). A CI check rejects external calls that bypass it.
- [ ] **One-time import** (`warden import --from <archived warden.db>`), a pure function into a new file swapped in by rename, with deterministic ids (`inc_` + hash of the old id, likewise per noun): events → Signals (source time where the payload has it, fingerprints recomputed); items → closed Incidents with root cause, fix commits and verification evidence where present (the known-error seed); transitions and notifications → historical events; the open `needs_decision` items (2 after Phase 0's drain) → Decisions with defaults (ADR-014); open work items, the four features closed as "a feature, not a fix" (1708, 1709, 1711, 1712 — Phase 0 did not re-open them) and the open Left-behind lines of every plan → Tasks with an owner (default per *Rules for every wave*). The golden-set labels (`docs/factory/evidence/golden/labels/`) attach to the imported incidents.
- [ ] **Adoption pass:** probes the external state of every non-terminal old item — open PRs, in-flight deploys, in-doubt operations — and sets the new entity from what it finds (an open PR becomes a Change, a NULL-outcome operation is resolved by its probe), so the first tick spawns nothing for work already in flight.
- [ ] **`warden` CLI — the one factory CLI** — on the agent-CLI contract (cyclopts + pydantic; ADR-004): `warden signal|condition|incident|task|decision|event list/show`, `warden task add|claim|heartbeat|done` (bd's verbs and JSON names, ADR-001), `warden schema [cmd]`; generated `REFERENCE.md`; conformance suite. `warden manifest …` (W2) and `warden artifact …` (W7) join it as modules; every loop runs as a phase of the one warden process.
- [ ] **Checks in `make check`:** one-writer (entity writes only from their module), effect-registry bypass check, projection rebuild (drop a read model, rebuild from `events`, compare), spike 2's kill harness (tests a–f, h) against the primitives plus a stale-epoch call, `PRAGMA integrity_check` in `make verify`; nightly off-box copy of `ledger.db`. **Restore is an adopt mode:** effects are refused until the adoption pass has probed every in-doubt operation.
- [ ] **Proof gate:** import reconciliation — every archived event, item and transition accounted for (script, 100 %); the import run twice from one archive yields identical ids and row counts; the KPI scripts in `docs/factory/evidence/kpi/` re-pointed at `ledger.db` reproduce `baseline.out.json` for the archived window exactly; kill harness green; kill tests b, b_deploy and h re-run against real-shaped adapters (a scratch GitHub repo returning real 422s, counting fakes for deploy and restart) — every target counts exactly one effect; restore of the off-box copy in adopt mode — 0 re-executed effects; the dormant legacy restore (below) run once and timed.
- **Rollback:** check out `warden-legacy`, copy the archive back writable, re-load the kept plists; the old `warden run` lines return with a revert of the lane commit. Tested once in the gate, then the legacy stays dormant — a way back, not co-running.
**Left behind:**

## Wave 2 — Every project describes itself once, in one structure            <!-- status: pending -->
Repo: dotfiles (+ one `docs:` commit per repo, PR-required repos by PR; IuRoot sources in dotfiles-private; homelab-private's manifest inside homelab-private) and a warden worktree for the `warden manifest` module, merged after W1's close-out. ADR-010. Days 1–2, parallel with W1, lane B.

- [ ] `config/factory/project.schema.json` (`design/model.md` §6, `factory/v1` with `runtime[]`, `spec.commands`, `slo` or `slo: none`, `policy.prRequired`, `product_surfaces[]`) and the `warden manifest draft|check|gen` module on the agent-CLI contract.
- [ ] **`warden project new <name> --type …`** writes `project.yaml` from a per-type template and renders every generated file. `integrations` are desired state: a reconciler creates what it can (herdr workspace, brain note stub, Kuma monitor via its API, TickTick list, runner sync, PR-required entry) and verifies what it can only observe. A new repo is green on `warden manifest check` from that one command plus name and type.
- [ ] **Directory contract** (`design/model.md` §6.1) for every repo: `project.yaml`, `docs/waves/`, `docs/adr/`, `docs/artifacts/`, `docs/notes/`, `.factory/` ignored; holdouts never in the repo. The contract fixes locations and creates nothing empty; `manifest draft` moves nothing that tools depend on without updating them.
- [ ] **`spec.commands{check, verify, deploy, restart, logs}`** per project, validated by the drift check (`make -n` parses, params declared) and rendered into the per-repo block. A production runtime without `restart` gets no restart recipe; the gap is filed with `warden task add`.
- [ ] Drafts for all 33 SourceRoot repos from what exists (AGENTS.md *Verify & Monitor*, Makefile, `config/herdr/groups.json`, `docs/factory/evidence/signals/topology.out.json`, OTel service names; class from `docs/factory/evidence/projects/classify.out.json`); review and commit each. homelab-private's manifest and topology are committed inside homelab-private and excluded from every generated output. IuRoot: drafts in `dotfiles-private/projects/<repo>/`, linked into each work repo, listed in its `.git/info/exclude`.
- [ ] Generated outputs v1: herdr `groups.json`; the AGENTS.md block between `<!-- factory:begin -->` / `<!-- factory:end -->` (role, class, runtime, health, monitors, commands, directory map); usage-tracker's project map; and the registries that today live outside the manifest — `config/pr-required-repos.json`, `docs/architecture.md`'s repo and LaunchAgent tables, the `config/Caddyfile` app blocks, the runner list behind `make gh-runner-sync`.
- [ ] **Proof gate:** `warden manifest check` green on every repo — schema, every integration key resolves, every declared command parses, generated blocks and rendered registries byte-equal to a re-render, the directory contract holds, topology covers every running container, launchd job and Kuma monitor (each blind spot filed with `warden task add`, e.g. 19 of 36 vps services unmonitored); `warden project new` on a scratch repo reaches green with zero hand-typed facts beyond name and type; no generated output names a homelab-private entity.
- **Rollback:** revert the manifest and generated-block commits per repo (PR-required repos by revert PR); the rendered registries fall back to their last hand-edited versions in git; the warden worktree is not merged.
**Left behind:**

## Wave 3 — Signals to incidents: intake, reconcilers, correlator, known errors            <!-- status: pending -->
Repo: warden (+ homelab, vps for the Docker event recorders). ADR-013, ADR-003, loops §1–2. Needs W1, W2. Days 3–5, lane A.

- [ ] Signal envelope (`source, subject, kind, severity, fingerprint, occurred_at, raw`); `subject` resolved through the manifests' topology; `occurred_at` is source time, never poll time.
- [ ] Adapters: Kuma webhook (pairs Up with Down by monitor id), HyperDX webhook (HyperDX moves off the days-1–5 Slack webhook onto it), RollHook deploys (job webhook or ClickStack deploy markers), GitHub Actions failures and issues (`gh` poll), Beszel (Shoutrrr webhook); a Docker events recorder per host (homelab, vps) pushing to ingest. Watchtower notifications retire (archived upstream).
- [ ] **Log adapter:** reads HyperDX/ClickStack alert rules on the structured severity field (never substring matches), fingerprints logger + normalised message, and drops output from the factory's own workers by provenance (ADR-006's resource attribute).
- [ ] **Git/GitHub ref adapter:** emits `change.merged` for every new default-branch sha, whatever the actor (owner push, Renovate, train); the ship loop (W5) owns only train state.
- [ ] Health reconciler per project. Desired = manifest runtime minus in-flight Deployments and declared maintenance; RollHook, WUD and `make deploy` record intent before stopping anything. Observed = signals plus a direct probe plus container-level state (`docker ps` on resync, so a lost recorder edge is still caught). Opens and closes Conditions; resync timer plus signal-scheduled runs.
- [ ] Correlator per ADR-003 with the parameters frozen by the backtest; known-error match against imported and new closed incidents; regression link. No single-shot decision model anywhere in the loop: judgment calls (recipe choice, `decision_class`) belong to the investigate worker on OpenCode/IU (W4), backed by `decision_shadow` — 92.4 % agreement with LLM triage, 60.1 % with the gold (`evidence/kpi/decision_shadow.out.md`).
- [ ] Restart recipe (known error *container down, manual stop or crash*): `spec.commands.restart` from the project's manifest (W2), verified by health green and the condition resolving; rate-limited per ADR-012; never fired on a target with an in-flight Deployment or declared maintenance.
- [ ] **Proof gate:**
  - (a) the frozen held-out numbers reproduce exactly on the live code (`backtest.py --verify`) — a byte-level regression check of the correlator code; the held-out is spent, for grouping as well as escalation;
  - (b) the three grouping thresholds of `docs/factory/evidence/golden/PREREGISTRATION.md` (B-cubed precision ≥ 0.90, recall ≥ 0.80, F1 strictly above today's warden) pass on the fresh post-cutover sample, labelled from blind packets (raw signal text, source time, topology only) with cross-burst gold (labellers join groups across adjacent chunks using `entity.peers`), under the labelled, detach and join readings; hinted packets are a second, reported reading;
  - (c) gameday rows 1–2 pass: glance stopped live — one incident, restart recipe, health green, closed on observation, 0 owner touches, MTTR ≤ 5 min; the 2026-10-17 VPS reboot replay — one incident candidate and 0 pages;
  - (d) ≥ 10 injected Down/Up pairs on a test Kuma monitor each yield exactly one Condition open and close;
  - (e) the 152 recorded `hermes_log` rows (`evidence/signals/signals.md`) replayed through the adapters: the checkpoint-store race and the egress outage each produce a Condition, the factory's own diagnostic lines produce none.
  - Escalation and known-error matching are not W3 gates: they become standing SLOs measured after W5 on the same fresh sample, blind and hinted readings reported.
- **Rollback:** stop the new intake and point Kuma and HyperDX back at the Slack webhook (the days-1–5 state); the ledger keeps the Signals already recorded.
**Left behind:**

---

## Wave 4 — Tasks, one spawner, agents that never wait for the owner            <!-- status: pending -->
Repos: warden, dotfiles (`rd` — one cutover). ADR-001, ADR-007, ADR-008. Days 6–8, lane A.
- [ ] Ready queue, claim leases with epochs, plan projector. After its one-time projection the ledger is the only home of task state: PLAN.md checklists are generated from it (marker block, drift-checked), and `/wave` closes tasks with `warden task done`.
- [ ] `rd` writes Agent records (optional `task_id`, its hook under `.factory/` per `design/model.md` §6.1 — a Task's attempts are its worker Agents), sets tab metadata; Hermes' herdr skill calls `rd`. `rd` joins the agent-CLI contract. Its ledger writes fail open (spool to JSONL, replay). The new `rd` installs beside the old one and switches by one symlink flip after the gate; the old binary is kept for one wave.
- [ ] **Worker profiles** (implement, investigate) on OpenCode/IU; the investigate worker makes the judgment calls (root cause, recipe choice, `decision_class`). agw `dispatch` stops at this cutover and leaves the global CLAUDE.md lane table.
- [ ] **Mothers and leads:** one mother identity per fleet project — persistent identity and continuity in its hook, run as on-demand sessions: the planner wakes it when a Condition has no recipe, a submitted brief needs breaking into tasks, or a plan needs re-sequencing; between wakes no context is resident. Leads spawn workers; handover and rotation go through the hook. Each mother runs under a token budget enforced by the spawner (one wake ≤ 0.25 × the median wave session ≈ 4.8M tokens, `evidence/kpi/forecast.out.md`; the weekly per-mother cap follows D1's default).
- [ ] Witness: resume at the quota reset, auto-continue after transient API errors, re-drive stuck or dead agents from the hook — a successor only after the predecessor's process is confirmed dead or its lease fenced — reap finished tabs (absorbs Phase 0's janitor); writes `idle.parked{reason, resume_at}`.
- [ ] **Quota guard and admission:** engine by class; the guard is level-triggered over all Max consumers — at the trip, running non-urgent Max agents checkpoint to their hook and park, mothers and leads restart on IU at their next wake. Every resume and spawn goes through one admission queue ordered incident > owner-started > fleet > improve, admitted at a token rate set by the forecast — no burst at the reset.
- [ ] **MacBook agents:** the Phase 0 herdr event recorder also runs on the MacBook and pushes to the mini's ingest when online; agents there carry `host_asleep since hh:mm` while the laptop is closed. shutterflow's fleet stays on the MacBook (Mac-only work), observed, not moved.
- [ ] Gate: spike 1's oracle; gameday rows 6–9; a gameday that kills and rotates a mother mid-plan — 0 lost or duplicated tasks, 0 owner nudges; SIGSTOP an agent past its TTL, re-drive, SIGCONT — every stale call rejected, 0 of its commits land; `rd wave`/`rd agents` proven, and `rd wave` still spawns with `ledger.db` unreadable (spool path); MacBook agents visible in the ledger; per-mother budget enforced; 0 spawns outside `rd`.
- **Rollback:** flip the `rd` symlink back to the kept old binary; re-add agw `dispatch` to the lane table; spooled JSONL replays once the ledger is back.

## Wave 5 — Ship: verification replaces approval            <!-- status: pending -->
Repos: warden, holdouts (new, private), each fleet repo. ADR-012. Days 9–11, lane A.
- [ ] Merge train with squash merges and automatic revert; deploy and post-deploy verify; ladder per action class from the manifests; runaway breaker; rate limits; ≥ 5 holdout scenarios per fleet project (drafted per open decision D4).
- [ ] Gate: gameday rows 1, 10–12; revert success 100 % on injected failures. Incident-to-ship autonomy resumes; escalation and known-error matching start as standing SLOs; improve and heal wait for W10.
- **Rollback:** switch the train off — every Change is opened and verified but not merged, and merges through the build lane; the last `verified` Deployment stays live.

## Wave 6 — Decisions and Argo as the control plane            <!-- status: pending -->
Repos: warden, argo, basalt-ui (PR), vps. ADR-009, ADR-014, ADR-015, `design/argo.md`. Days 12–16, lane A (after W4: steer and stop execute through `rd`'s Agent records).
- [ ] Decision entity with options, reversible default, expiry; push tiers; the imported decisions drained under ADR-014.
- [ ] Factory read API on the mini (read models of `design/argo.md` §2) and the write verbs of ADR-015, each writing an intent entity executed by a reconciler or `rd`; delete the frozen snapshot pushes and the action queue; VPS dead-man's switch, its heartbeat payload carrying an egress probe so the VPS tells "mini dead" from "mini alive, egress dead".
- [ ] Views: situation-adaptive Home, capability-composed Project pages, Needs you, Incidents, Fleet, Artifacts (read side), Health, Usage, Traffic; basalt-ui lands the event list, upstreams status chip, decision card and entity card, builds the lifecycle strip.
- [ ] Gate: the timed Argo test on phone and desktop; every write verb exercised end to end with its audit event; gameday row 13.
- **Rollback:** redeploy Argo's last `verified` Deployment (the frozen pages); the read API and verbs stop with it; basalt-ui changes revert by PR.

## Wave 7 — Artifacts are ours            <!-- status: pending -->
Repos: warden (`warden artifact`, a module of the factory CLI and API), argo, basalt-ui (PR: comment-thread export). ADR-005. Days 17–19, lane A.
- [ ] `warden artifact submit|wait|status|comment` — ADR-005's `rv` contract — on the agent-CLI contract. The ledger is the only SoR for threads: Artifact entities plus comment events carrying the anchor triple (quote + prefix + suffix); no `threads.jsonl`. Artifact versions stay in git as `path@sha` under `docs/artifacts/<slug>/`, committed by the submitting agent through the normal Change path; the artifact module never commits. plannotator's semantics kept (supersedes, wait-for-reply, global sequence).
- [ ] Argo Artifacts view with anchored threads, project-grouped inbox, phone layout; basalt-ui gains the comment thread as a package export in its own PR.
- [ ] Gate: the spike-5 `rv` contract suite against `warden artifact`; a review round trip from phone and desktop; a thread rebuilt from events alone; plannotator retired.
- **Rollback:** plannotator's Inbox stays installed until the gate passes; flipping back re-points the contract at it, and threads recorded meanwhile stay in the ledger.

## Wave 8 — CLI-first tooling (the former W11)            <!-- status: pending -->
Repos: agent-gateway, email-, audio-, image-gateway, dotfiles (skills). ADR-004. Days 9–13, lane C (after W4's cutover).
- [ ] **First:** agw's `decide`, `triage`, `narrative` and `investigate` tools deleted. agw's role, one line: a bounded tool server, no loop.
- [ ] **Entry gate:** every exposed route of each gateway has input and output schemas (Elysia route schemas — Zod or TypeBox — exported to JSON Schema); a gateway that fails it gets the schemas first.
- [ ] Contract libraries: Python (cyclopts + pydantic) and the TS/Bun equivalent chosen in ADR-004; TS CLIs generated from the HTTP contract; one conformance suite for both. Contract scope = every factory binary on PATH (`~/.local/bin`) plus the gateway CLIs, enumerated by the suite: `hl`, `secrets-run`, `ask-human`, `jobrun`, `imgcli` and the research CLI join here (`rd` joined in W4).
- [ ] CLIs for agw (review, check, prose, read_image, read_drawing), email, audio and image gateways; generated help, `REFERENCE.md`, each skill's `references/cli.md`, the AGENTS.md routing block; CI drift check.
- [ ] Skills move onto the CLIs in one cutover each, shipped under new names and switched by one symlink flip after the gate (old skill kept for one wave): `/check`, `/review`, `/otel`, `/prose`, `/excalidraw-diagram`; dispatch-era skills retired; agw's MCP server and the deferred-tool path removed; MCP registration shrinks to research-gateway (plus chrome-devtools until a browser CLI replaces it).
- [ ] Gate: conformance suite green on every CLI in scope; `/check` and `/review` proven on two repos after the cutover; the long-job policy sentence in every routing block.
- **Rollback:** flip the skill symlinks back to the old names and re-register agw's MCP server (kept on disk for one wave).

## Wave 9 — One trace per item            <!-- status: pending -->
Repos: warden (worktree, merged after W7's close-out), agent-gateway, research-, email-, audio-gateway, dotfiles. ADR-006. Days 17–18, lane C.
- **Rollback:** revert the telemetry commits per repo; traces already exported stay in ClickHouse.

## Wave 10 — Improve and heal on the same path            <!-- status: pending -->
Repos: warden (+ Renovate config per repo, landed on days 20–21 before W14 opens dotfiles; CrowdSec on homelab, vps). Loops §6, proof §2. Days 20–23, lane A.
- [ ] One recurring job per loops §6 row, each a reconciler on a schedule whose Conditions flow through correlate → plan → spawn → verify:
  - dependencies — Renovate (patch/minor automerge behind CI, 14 d age); the reconciler watches its failures and majors → `deps.*`;
  - docs drift — generated blocks, doc-contradiction lint, age → `docs.*`;
  - code health — `/analyze` weekly over thresholds → `code.health` (batched);
  - Claude Code setup — CLAUDE.md/AGENTS.md size, skill count, resident tool-definition tokens → `setup.bloat`;
  - basalt-ui dogfooding — components duplicated in consumers → `ui.upstream`;
  - performance, OTel — p95/error-rate regressions per service vs baseline → `perf.regression`;
  - GitHub issues on owned repos → Signals → Tasks;
  - infra — the runbooks below → `infra.*`;
  - attacks, anomalies — CrowdSec on the public hosts, auth/log anomalies → `security.anomaly`.
- [ ] **Infra runbooks per host** (mini, homelab, vps), code-only where the cause is known: disk (disk-sweep), mount (mount, verify, restart dependents), certs, backups, restart loops, DB/ClickHouse health, and `infra.egress` for the factory host — network-independent (flush the DNS cache, restart mDNSResponder, fail over to a secondary resolver); attempt failures during an open egress condition are classed infra. A runbook that fails on a physical cause (device absent, power, no shutdown record) ends in `needs_hands` on the heads-up tier.
- [ ] Gate: gameday rows 3, 4, 5, 14 and 15 (resolver blackhole) pass at their proof §2 targets, 0 owner touches. Full autonomous operation.
- **Rollback:** pause a job through its project's runtime record (pause override); Renovate and CrowdSec configs revert per repo.

## Wave 11 — Hermes becomes the door            <!-- status: pending -->
Repo: hermes-agent. Days 17–19, lane B (after W6's read API).
- [ ] Capability limit with a test: no file, code-execution or code-writing terminal tools; a terminal allowlist of factory CLIs.
- [ ] Reads only the factory read API and CLIs; files Tasks and asks `rd` for sessions; briefings (morning, evening) are a rendering of the one digest projection — Home and the per-project changelogs (W13) are its other two, no second pipeline — delivered as Argo threads with audio; the "Project narratives" cron retires (its job moves to W13's changelog rendering); Slack posting exits.
- [ ] Gate: 7 days of `state.db` with zero file or commit tool calls; briefings reproduce from events.
- **Rollback:** redeploy Hermes' previous release; the capability limit stays.

## Wave 12 — dotfiles rewired            <!-- status: pending -->
Repo: dotfiles. Days 14–16, lane C.
- [ ] Generated routing everywhere (manifests + CLI contract); skills diet (each skill = when to use + judgment, flags generated); launchers consolidated; global CLAUDE.md and AGENTS.md generated blocks; doc-contradiction lint, which also bans hand-ticked task checklists (PLAN.md checklists come from the ledger, W4); concept-budget check over a generated inventory with caps (processes per host, CLIs, stores); the security-policy line aligned with ADR-014; the telemetry settings fix (ADR-006).
- [ ] Gate: doc-contradiction lint and drift checks green across all repos; no hand-maintained project registry left (`config/pr-required-repos.json`, `docs/architecture.md`'s repo and LaunchAgent tables, the Caddyfile app blocks, the runner list all byte-equal to a re-render from the manifests); `make check` green on both machines.
- **Rollback:** revert the generated-block and routing commits; the renderers stay, their outputs return to the W2 state.

## Wave 13 — Brain projections and per-project changelogs            <!-- status: pending -->
Repos: brain, warden (projector, worktree merged after W10's close-out). Days 20–21, lane B.
- [ ] Each project's brain note gains generated sections (status, links, changelog) from the manifest and the event log; the changelog is a rendering of the one digest projection (W11); `changelog.target` honoured (brain by default, repo for libraries with release notes); one writer for the vault.
- [ ] Gate: every project note re-renders from events; no Slack changelog left.
- **Rollback:** revert the vault commits of the generated sections; hand-written note content outside them is never touched.

## Wave 14 — Archive, retention, docs, website            <!-- status: pending -->
Repos: dotfiles, brain, jkrumm.com. Days 22–23, lane C. Last.
- [ ] Historical stores archived under open decision D5's default; retention jobs; generated docs replace hand-written restatements; jkrumm.com's guide rewritten from the new model.
- **Rollback:** archives are copies — restore a store from its archive; retention jobs unload; doc and site changes revert by commit.

---

## Round 5 disposition

| Round 5 wave | Disposition | Where |
|-|-|-|
| W1 Constitution | **merge** — the model is generated from manifests and ADRs; CodeRabbit removal kept as a chore | W2, W12 |
| W2 Escalation cut | **done in part** (Phase 0: agw W12; warden W8 closed early — the rewrite stops the old loop); timeout default → W6; improve loop → W10; shadow promotion → **drop** (no single-shot decision model in the loop; judgment in the investigate worker on OpenCode/IU, ADR-003); rebase-merge revert → W5; Argo `adopt` verb → **drop** (write verbs, ADR-015) | Phase 0, W3, W4, W5, W6, W10 |
| W3 Execution layer | **done in part** (Phase 0: recorder, janitor); recorder on the MacBook, tab metadata and one launcher → W4; overview truth → W6; Obsidian 1706 → imported as a Decision with a default | Phase 0, W1, W4, W6 |
| W4 Implementation into herdr | **keep**, unblocked by ADR-008; widened: worker profiles replace agw `dispatch`, on-demand mothers and leads for fleet projects | W4 |
| W5 Thin Hermes | **keep**, widened: Hermes becomes the door | W11 |
| W6 Argo control plane | **keep**, redesigned from the owner's questions plus write verbs | W6, W7 |
| W7 Slack retirement | **merge** — intake stops with warden (W1); human posting exits in W6, W11, W13 | W1, W6, W11, W13 |
| W8 Brain door | **merge** | W13 |
| W9 Observability | **keep** | W9 |
| W10 Docs and website | **keep**, last | W14 |
