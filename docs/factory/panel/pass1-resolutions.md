# Panel pass 1 — resolutions

85 objections (18 blockers, 57 majors, 10 minors) from eleven roles, run on IU Opus (raw outputs in
`panel/pass1/`). Every objection is resolved here by a **changed design**, an **explicit tradeoff**, or an
**open decision**; "→" names where the change lands. New terms are defined once in §0.

## 0. Terms introduced by this pass

- **Effect registry** — every external side effect goes through one module that records an `operations` row and declares one strategy: *native key* (target honours an idempotency key), *natural key + lookup on conflict* (PR by head branch `factory/<task>/<agent>`, merge with GitHub's expected-head `sha=`, revert branch `revert/<change>`), *probe before retry* (deploy: read the deployed version; restart: read the container's start time), or *at-most-once with receipt* (push notifications). A CI check rejects external calls that bypass it.
- **Generation key** — idempotency key `<entity>:<kind>:<generation>`, the generation read from ledger state in the same transaction (`dep:<change>:<target>:<sha>`, `restart:<condition>:<flap#>`, `revert:<change>:<n>`).
- **Epoch** — a monotonic number issued with every lease grant (task claim, agent, merge slot), written into the hook; every mutating call carries it; a stale epoch is rejected. Git effects are fenced by `push --force-with-lease=<ledger sha>` and merge `sha=`.
- **Deliveries** — effectors (push, Argo thread, vault write, Slack) record `deliveries(event_id, channel)` before sending; rebuilding a projection never re-sends.
- **Project runtime record** — the ledger's per-project runtime state (pause override, last reconcile, effective autonomy). The manifest stays the SoR for configuration; each attribute has exactly one SoR.
- **Effective autonomy** — computed per (project, action class) by `factory manifest check` from which evidence producers exist; the manifest's `autonomy` can only lower it.
- **Propose-only** — a Change is opened and verified but not merged, because a rung's evidence has no producer; the gap is filed as a factory Task. Not an owner gate: nobody approves it; it merges when the producer exists.
- **`factory-self`** — the action class for changes to the factory's own ship path, verifier, holdout runner, breaker, rollback, and to manifest `autonomy`/rate limits/holdout locations; verified by the previously released factory (N-1 verifies N), with a pinned last-known-good release restored by an independent watchdog.
- **Lineage** — fingerprint set + `regression_of` chain + topology subject; the unit the breaker and budgets count over (7-day window).
- **`needs_hands`** — a typed outcome when a host runbook fails and the observed cause is physical (device absent, power, no shutdown record); sent on the heads-up tier; asks for nothing.
- **`idle.parked{reason, resume_at}`** — Agent substate written only by Witness (reason: quota, api_error, turn_end, waiting).

## 1. Correlation (correlation scientist)

| Id | Resolution | Lands in |
|-|-|-|
| cor-1 B | **Changed.** ADR-003 claims recall only for incidents inside one burst. Cross-burst gold is built for the fresh sample (labellers join groups across adjacent chunks using `entity.peers`), and grouping acceptance moves there. | ADR-003, PREREGISTRATION amendment, W3 |
| cor-2 B | **Changed.** Long windows only for stateful sources whose recovery signal closes the episode (Kuma Up, Beszel recovery); stateless sources (CI failures, log lines, issues) get dedup ≤ 30 min and open ≤ 60 min. A longer link is an explicit, undoable edge the investigator proposes. | ADR-003, loops §2 |
| cor-3 | **Changed.** An incident closes only when every member's own Condition has resolved; a `split` operation detaches a member whose condition outlives the group. | ADR-003, model §2 (Incident), loops §2 |
| cor-4 | **Changed.** Fold to a host only on host-level evidence (boot record, Beszel host-down, Docker daemon event, or ≥ 50 % of the host's monitored subjects firing); otherwise fold no higher than service/project. | ADR-003, loops §2 |
| cor-5 | **Changed.** Dated PREREGISTRATION amendment adds the *join* reading for uncertain labels on future samples; ADR-003 states the current pass holds under the *detach* reading only. | PREREGISTRATION, ADR-003 |
| cor-6 | **Changed.** The fresh sample uses blind packets (raw text, source time, topology only); hinted packets become a second, reported reading. | ADR-003, W3/W5 SLO measurement |
| cor-7 | **Changed.** The frozen held-out becomes a byte-level regression check of the correlator code; grouping acceptance moves to the fresh post-cutover blind sample; the held-out is declared spent for grouping too. | ADR-003, waves W3 gate |

## 2. Cost and capacity (cost planner)

| Id | Resolution | Lands in |
|-|-|-|
| cos-1 B | **Changed.** `evidence/kpi/forecast.py`: per-class weekly tokens → engine → Max %/week and IU $/week, today and fully running; capacity table in report §2 and ADR-008. W4 acceptance gets a per-mother token budget enforced by the spawner. | evidence, ADR-008, report §2, W4 |
| cos-2 | **Changed.** The owner reserve is derived from data — the p90 owner-interactive share per cycle (≈ 30–35 %), not 15 %; the fixed 80 % flip becomes a forecast check (factory + owner projection < 100 % at the reset). | ADR-008 |
| cos-3 | **Changed.** The guard is level-triggered over all Max consumers: at the trip, running non-urgent Max agents checkpoint to their hook and park; mothers and leads restart on IU at their next wake. | ADR-008, W4 |
| cos-4 | **Changed.** Resume goes through an admission queue ordered incident > owner-started > fleet > improve, admitted at a token rate set by the forecast — no burst at the reset. | ADR-007, ADR-008, W4 |
| cos-5 | **Changed.** D1 restated: factory-originated (spawner-tagged), non-urgent IU cash; measured baseline and projected range from `forecast.py`; default from the projection. | report §10 |
| cos-6 | **Changed.** Cost per resolved item becomes per action class × engine, attributed through Agent records, baseline from the post-10-15 regime; interim ceiling 3 × baseline p90 per class, fed to the lineage budget. | ADR-008, ADR-012, proof §3 |
| cos-7 | **Changed.** Inverse rule: when the forecast at the reset is below 100 % − reserve − margin, non-urgent IU-class work spawns on Max (prepaid capacity is not wasted). KPIs: owner sessions blocked per cycle (→ 0), Max lapsed %. | ADR-008, proof §3 |
| cos-8 | **Changed.** No fixed 5-hour trip (it never fired on data); the burn-rate forecast covers both windows; the engine-move impact is a range (+22–29 %); $/1 % recalibrated weekly. | ADR-008 |

## 3. Data (data architect)

| Id | Resolution | Lands in |
|-|-|-|
| dat-1 B | **Changed.** The ledger is the only home of task state. After the one-time projection, PLAN.md checklists are generated from the ledger (marker block, drift-checked); hand-ticking is banned by the doc lint; `/wave` closes tasks with `warden task done`. | ADR-001, model §1, W4, W12 |
| dat-2 B | **Changed.** The ledger (Artifact + comment events with the anchor triple) is the only SoR for threads; artifact versions stay in git as `path@sha`, committed by the submitting agent through the normal Change path; `threads.jsonl` is dropped; `rv` never commits and becomes a module of the factory CLI and API. | ADR-005, model §6.1, W7 |
| dat-3 | **Changed.** A git/GitHub ref adapter emits `change.merged` for every new default-branch sha (actor push / renovate / train); the ship loop owns only train state. | ADR-011, ADR-013, W3 |
| dat-4 | **Changed.** One Deployment writer, the deploy reconciler, consuming deployed/failed Signals from every source (wrapper, RollHook, CI), keyed change + target. | model §1, ADR-011 |
| dat-5 | **Changed.** Adapters for `quota.sampled`, `usage.recorded` (per session, with `factory.root`), `owner.message` (classified), agent heartbeat and last output (herdr record), so invariant 8 holds. | ADR-013, model §4 |
| dat-6 | **Changed.** *Item* = an Incident, or a Task the owner did not originate. *Owner touch* = an event with actor `owner` on an item he did not originate, excluding `*.created`; pause is excluded. DEFINITIONS amended. | DEFINITIONS, ADR-014 |
| dat-7 | **Changed.** Events influenced by a manifest carry `manifest_sha`; reconcilers read default-branch manifests only; `metadata.uid` is stable across renames. | model §4, §6 |
| dat-8 | **Changed.** `factory/v1` gains `runtime[].{host (infra project ref), containers[], launchd[], version, availability}`, `spec.dependsOn`/`providesApis`, `data.{databases[], backups{target, maxAge}}`, `doors[]`, `commands{check, verify, deploy, restart, logs}`, `slo` or explicit `slo: none`, `policy.prRequired`, `product_surfaces[]`. | model §6, ADR-010 |

## 4. Durability (durable-systems engineer)

| Id | Resolution | Lands in |
|-|-|-|
| dur-1 B | **Changed.** The effect registry (§0); W1's gate re-runs kill tests b, b_deploy and h against real-shaped adapters (a scratch GitHub repo returning real 422s, counting fakes for deploy and restart). | ADR-002, W1 |
| dur-2 B | **Changed.** Epochs on every lease (§0); a re-drive successor is granted only after the predecessor's process is confirmed dead or its lease fenced; gameday: SIGSTOP an agent past its TTL, re-drive, SIGCONT → every stale call rejected, 0 commits land. | ADR-002, ADR-007, W1, W4 |
| dur-3 | **Changed.** Generation keys (§0). | ADR-002 |
| dur-4 | **Changed.** Pure read models stay rebuildable; effectors use deliveries (§0). | ADR-011, model §4 |
| dur-5 | **Changed.** The import is a pure function into a new file swapped in by rename, with deterministic ids (`inc_` + hash of the old id); an adoption pass probes the external state of every non-terminal old item (open PRs, in-flight deploys, in-doubt operations) and sets the new entity from what it finds. | ADR-011, W1 |
| dur-6 | **Changed.** `synchronous=FULL` on `ledger.db`; restore is an adopt mode — effects are refused until the adoption pass has probed every in-doubt operation. | ADR-011, W1 |
| dur-7 | **Changed.** `decided_at` = server receipt time; an answer after the deadline is an override intent (own generation keys), never a decision; a deadline is extended by the factory API's measured downtime across it. | ADR-014, ADR-015 |
| dur-8 | **Changed.** `--idempotency-key` joins the agent-CLI contract, required on mutating commands called by agents; Hermes derives it from the message id; Argo mints one per rendered form. | ADR-004, ADR-015 |

## 5. Platform and DX

| Id | Resolution | Lands in |
|-|-|-|
| dx-1 B | **Changed.** `factory project new <name> --type …` writes `project.yaml` from a per-type template and renders every generated file; `integrations` become desired state with a reconciler that creates what it can (herdr workspace, brain note stub, Kuma monitor via its API, TickTick list, runner sync, PR-required entry) and verifies what it can only observe. | ADR-010, W2 |
| dx-2 | **Changed.** pr-required-repos.json, architecture.md's repo and LaunchAgent tables, the Caddyfile app blocks and the runner list are rendered from manifest fields. | ADR-010, W2, W12 |
| dx-3 | **Changed.** Tool routing renders once into a global generated rules file (Claude rules + OpenCode `instructions`); the per-repo block holds only manifest facts. | ADR-004, ADR-010 |
| dx-4 | **Changed.** `<cli> schema --all --format json` is the cross-language IR, committed and CI-checked in each CLI's repo; dotfiles renders from those snapshots by repo@sha and stamps the header. | ADR-004 |
| dx-5 | **Changed.** TS CLIs are generated from the HTTP contract (Elysia route schemas — Zod or TypeBox — exported to JSON Schema); "every exposed route has input and output schemas" is W8's entry gate. | ADR-004, W8 |
| dx-6 | **Changed.** Long-job behaviour moves into the CLI: `--wait` is the default and blocks until a budget read from an env var the harness sets (session hook, OpenCode plugin, cron default), then exits with the domain code `pending` and the exact resume command. The policy sentence becomes redundant. | ADR-004 |
| dx-7 | **Changed.** `spec.commands{check, verify, deploy, restart, logs}` validated by the drift check (`make -n` parses, params declared) and rendered into the per-repo block; recipes call `spec.commands.restart`. | ADR-010, model §6, W2, W3 |
| dx-8 | **Changed.** Contract scope = every factory binary on PATH (`~/.local/bin`) plus the gateway CLIs, enumerated by the conformance suite; `rd` joins in W4, the rest (`hl`, `secrets-run`, `ask-human`, `jobrun`, `imgcli`, research) in W8. | ADR-004, W4, W8 |

## 6. Owner intent (advocate)

| Id | Resolution | Lands in |
|-|-|-|
| int-1 B | **Changed.** W4 builds mothers and leads explicitly — one mother identity per fleet project, leads spawning workers, handover and rotation through the hook — gated by a gameday that kills and rotates a mother mid-plan (0 lost or duplicated tasks, 0 owner nudges). Shape per the tradeoff in sim-7. | waves W4, ADR-007 |
| int-2 | **Changed.** W10 specified like W1–W3: one bullet per loops §6 job, infra runbooks per host (disk, mount, certs, backups, restart loops, DB/ClickHouse, egress), CrowdSec on the public hosts, gated by gameday rows. | waves W10 |
| int-3 | **Changed (one answer everywhere).** No single-shot decision model in the loop. The owner's "decision models" become the investigate worker on OpenCode/IU making the judgment calls (recipe choice, `decision_class`), backed by the `decision_shadow` numbers (92 % agreement with LLM triage, 60 % with the truth). | ADR-003, W3, report §4b, FAQ |
| int-4 | **Changed.** Product direction becomes structural: the manifest declares `product_surfaces[]` (public routes, store listings, pricing, holdout scenarios, removed features); a Change touching one that does not trace to an owner-submitted brief or a reviewed plan Artifact is product-class and becomes a Decision with a reversible default. | ADR-014, ADR-012, model §6 |
| int-5 | **Changed.** `beads:` → `tasks: {prefix}`; the integrations reconciler ensures a TickTick list per project (titles only — the factory never writes his todos); the brain project note is the Obsidian projection (W13). | model §6, ADR-010 |
| int-6 | **Changed.** ADR-002 gains a Mastra row with its reason: TypeScript-only, its durability and timeout semantics could not be verified by the research, and it would add a TS runtime and a second system of record to a Python loop. | ADR-002, FAQ |
| int-7 | **Changed.** §1b gains *During the rewrite*: what he sees on days 1–11 and the day each capability returns. | report §1b |

## 7. Migration (migration lead)

| Id | Resolution | Lands in |
|-|-|-|
| mig-1 B | **Changed.** W3's gate: (a) the frozen held-out numbers reproduce exactly on the live code; (b) the three grouping thresholds pass; (c) gameday rows 1–2 pass; (d) ≥ 10 injected Down/Up pairs on a test Kuma monitor each yield exactly one Condition open and close. Escalation and known-error matching become standing SLOs measured after W5. | waves W3, ADR-003 |
| mig-2 B | **Changed.** agw `dispatch` counts as build lane until W4's worker profiles pass and stops at the W4 cutover; W1 retires `warden run` from the global CLAUDE.md lane table, `rd` help and the wave skill in the same commit, replaced by `warden task add`. | waves W1, W4 |
| mig-3 | **Changed.** W1's first bullet is a generated consumer inventory of the old warden with a disposition each (HyperDX pointed back to the Slack webhook for days 1–5; warden push monitors and canary removed; Hermes' `warden.db` reads stopped; Argo's warden page and action queue frozen; jobrun alert sources re-pointed). | waves W1 |
| mig-4 | **Tradeoff.** warden is the serial spine; parallel warden work only in separate worktrees with a declared merge order. The honest calendar is ≈ 23 working days, not 17. | waves Calendar |
| mig-5 | **Changed.** Every spawn names its engine: lanes B and C default to OpenCode/IU; lane A on Max; at a 7-day reading ≥ 80 % only lane A runs; the calendar counts quota-available days. | waves Mode |
| mig-6 | **Changed.** `rd`'s ledger writes fail open (spool to JSONL, replay); the new `rd` installs beside the old one and switches by one symlink flip after its gate, the old binary kept for one wave; W8's skills ship under new names and flip the same way. | waves W4, W8 |
| mig-7 | **Changed.** Every wave gets a Rollback line. W1: tag `warden-legacy`, keep the plists on disk, and test the dormant restore once as part of W1's gate — a tested way back, not co-running. | waves (all) |
| mig-8 | **Changed.** The answers W1–W3 needed are written into waves.md: homelab-private's manifest and topology stay inside homelab-private and every generated output excludes it; PR-required repos go by PR; an unowned Left-behind item defaults to the project's mother (fleet) or the planner queue (session). | waves |

## 8. Simplifier

| Id | Resolution | Lands in |
|-|-|-|
| sim-1 | **Changed.** The concept-budget check covers a generated inventory with caps (processes per host, CLIs, stores). `factory` and `rv` fold into the one factory CLI (`warden manifest …`, `warden artifact …`); all loops run as phases of one warden process. | ADR-004, ADR-011, proof §6 |
| sim-2 | **Changed.** Infrastructure tables (events, operations, timers, leases, deliveries) are named plumbing, exempt from the noun count; pause is a field of the project runtime record (also ux-5); agent messages and artifact comments are events; the candidate is an Incident state; a holdout scenario is a Verification spec. | model §1 |
| sim-3 | **Changed.** Attempt is dropped: an Agent carries an optional `task_id` and its hook; a Task's attempts are its worker Agents. **Eleven nouns.** | model §1–2, ADR-001, ADR-007 |
| sim-4 | **Changed** (= int-3). | ADR-003, W3, §4b |
| sim-5 | **Changed** (= dat-2). | ADR-005 |
| sim-6 | **Changed.** Before W8, agw's `decide`, `triage`, `narrative` and `investigate` tools are deleted; W8 wraps review, check, prose, read_image, read_drawing. agw's role, one line: a bounded tool server, no loop. | ADR-007, W8 |
| sim-7 | **Tradeoff** (with int-1). Mothers keep a persistent identity and continuity in their hook but run as **on-demand sessions**: the planner wakes a project's mother when a Condition has no recipe, a submitted brief needs breaking into tasks, or a plan needs re-sequencing; between wakes no context is resident. Gas Town's "persistent identity, ephemeral sessions" — the owner's shape without an idle resident. | ADR-007, W4 |
| sim-8 | **Tradeoff.** (a) One digest projection; Home, the morning/evening briefings (kept: the owner asked for them in Argo) and the per-project changelogs are three renderings of it, not three pipelines. (b) The directory contract fixes locations and creates nothing empty. | ADR-011, model §6.1, W11, W13 |

## 9. SRE

| Id | Resolution | Lands in |
|-|-|-|
| sre-1 B | **Changed.** `needs_hands` (§0) on the heads-up tier, no SLO needed; the drift check requires an availability SLO or an explicit `slo: none` on every production runtime. | ADR-014, ADR-010, model §6 |
| sre-2 B | **Changed.** A log adapter reads HyperDX/ClickStack alert rules on the structured severity field (never substring matches), fingerprints logger + normalised message, and drops output from the factory's own workers by provenance (the resource attribute of ADR-006); W3's gate replays the 152 `hermes_log` rows (the checkpoint race and the egress outage must each produce a Condition). | ADR-013, W3 |
| sre-3 B | **Changed.** `infra.egress` for the factory host with a network-independent runbook (flush the DNS cache, restart mDNSResponder, fail over to a secondary resolver); the heartbeat payload carries an egress probe so the VPS tells "mini dead" from "mini alive, egress dead"; attempt failures during an open egress condition are classed infra. New gameday row 15 (resolver blackhole). | loops §6, ADR-009, proof §2 |
| sre-4 | **Changed.** The restart recipe needs two independent observations to agree (Kuma plus Docker state, a direct probe, or evidence of recent work); disagreement opens `probe.disagrees` on the monitor — a monitoring defect filed as a Task, no restart. | ADR-012, loops §3 |
| sre-5 | **Changed.** Actions are chosen per incident: while a topology ancestor has an open host condition (boot, mount, reachability), child recipes are held for the host's hold window and the host runbook runs first. | ADR-003, loops §2–3 |
| sre-6 | **Changed.** Desired state = manifest runtime minus in-flight Deployments and declared maintenance; RollHook, WUD and `make deploy` record intent before stopping anything; the health reconciler reads container-level state; restarts use `spec.commands.restart`. | loops §1, W3 |
| sre-7 | **Changed.** `availability: intermittent` on runtime targets (the MacBook): output-age conditions replace liveness heartbeats; no investigation while the host is known asleep. | model §6, loops §1 |

## 10. Operator UX

| Id | Resolution | Lands in |
|-|-|-|
| ux-1 B | **Changed.** The Phase 0 herdr event recorder also runs on the MacBook and pushes to the mini's ingest when online; agents there carry `host_asleep since hh:mm` when the laptop is closed; shutterflow's fleet stays on the MacBook (Mac-only work) and is observed, not moved. | ADR-007, ADR-009, W4 |
| ux-2 | **Changed.** All 27 canonical questions stay in the table (none replaced); read models added: `deployments_by_env`, `job_runs`, `regressions`, `updates`, `config_state`, `fixed_alone`, `freshness`. | Argo §2 |
| ux-3 | **Changed.** Every read model returns `as_of` and its cadence; a stale source renders as a stale term in place of its value; "all up" needs every health source fresh. | Argo §3, ADR-009 |
| ux-4 | **Changed.** Every intent ends in `applied`, `rejected(reason)` or `expired(budget)` with a per-verb budget (steer delivered ≤ 10 s, reply ≤ 2 min; stop ≤ 60 s; submit shows `claimed` or its queue position). | ADR-015 |
| ux-5 | **Changed.** Pause is a desired-state override in the project runtime record, shown as one ambient term on line 1; never a card, never a Decision, never an owner touch. | ADR-015, ADR-014, model |
| ux-6 | **Changed.** Each entity renders in exactly one Home slot by precedence (decision > broken > parked > in flight); *Fixed alone* is a count with drill-down. | Argo §3 |
| ux-7 | **Changed.** One push channel: Argo installed as a Home-Screen PWA with web push sent from the VPS half (works with the mini dark); the push body is self-contained. Fallback if PWA push proves unreliable: a self-hosted push service on the VPS. | ADR-009, ADR-014 |
| ux-8 | **Changed.** `idle.parked{reason, resume_at}` (§0), `agent.parked`/`agent.resumed` events; last output from the herdr record. | model §2, ADR-007 |

## 11. Verification

| Id | Resolution | Lands in |
|-|-|-|
| ver-1 B | **Changed.** Fail closed on absent evidence: effective autonomy (§0); a rung whose evidence has no producer drops to propose-only and files the gap as a factory Task; it flips back when the producer exists. | ADR-012, ADR-010 |
| ver-2 B | **Changed.** `factory-self` (§0); the manifest's `autonomy` can only lower effective autonomy, so no Change can raise its own gate. | ADR-012 |
| ver-3 B | **Changed.** Rollback is a Deployment operation — redeploy the last `verified` Deployment by image digest, compose revision or previous launchd bundle (recorded per runtime); the git revert follows as an ordinary Change; every agent-originated push lands as one train entry. | ADR-012, model §1 |
| ver-4 | **Changed.** The breaker counts per lineage over 7 days; restarts count as automatic changes; a revert writes a known-bad marker so the same version is not re-shipped. | ADR-012 |
| ver-5 | **Changed.** Each Task and lineage carries a budget in attempts, IU dollars and Max percent (never wall clock — the owner's no-cap rule); Witness auto-continues and re-drives count against it with backoff; exhaustion opens the breaker for that lineage. | ADR-012, ADR-007 |
| ver-6 | **Changed.** The auto rung allows only expand/contract migrations whose expand step keeps the previous release working, so rollback is code-only; a contract step that drops data is the data-loss class — an owner Decision by the fixed rule. | ADR-012 |
| ver-7 | **Changed.** Holdouts change only through a Change to the holdouts repo by a verifier-role agent that sees the approved plan Artifact, never the product diff. | ADR-012 |
| ver-8 | **Changed.** The post-deploy hold per condition type is derived from the fingerprint's historical inter-occurrence time (≥ 2 × the median gap, ≥ 24 h for crash, OOM and flap types); a recipe is promoted to automatic reuse only after its hold confirms it. | ADR-012, ADR-003 |

## 12. Tradeoffs and open decisions from this pass

- **Tradeoffs:** mig-4 (a serial warden spine, ≈ 23 days), sim-7 with int-1 (on-demand mothers with persistent identity), sim-8 (one digest, three renderings).
- **Open decisions:** none added — every objection was resolved by the design; the five business decisions stand (D1 restated per cos-5).
