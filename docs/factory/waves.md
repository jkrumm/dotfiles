# Factory migration — waves

The strangler plan for the factory design (`report.html`, ADRs in `adr/`). It replaces Round 5
(`docs/waves/PLAN.md` of 2026-10-21, dispositioned below). The runnable copy is
`docs/waves/PLAN.md` once Round 5 is archived; this file is the design record.

**Mode:** orchestrated, from an orchestrator tab in the `dotfiles` herdr workspace. Each wave is an
`RD_ORCHESTRATED=1 rd wave <repo>` tab in the repo it changes most; it commits to each repo it
touches separately (basalt-ui: its own PR). One active wave per repo. Model: `RD_WAVE_MODEL` default;
a wave that needs a stronger model says why in the spawn.

**Rules for every wave**
- The manual lane never breaks: Claude Code + herdr + `rd wave` keep working after every wave; a
  wave that touches `rd` or herdr proves `rd wave <repo>` and `rd agents` still work before close-out.
- New flows run in **shadow** beside the old one (the decision-shadow pattern: compute, record, do
  not act) until they beat it on the Phase 6 metric named in their exit; cutover is its own step.
- Gate: `make check`, `/review` on every non-trivial diff, `make deploy`, `make verify`; the KPI the
  wave moves is measured by a read-only script and written into **Left behind**.
- **Left behind is computed, not prose:** every open item becomes a Task with an owner (until W5:
  a `warden run` item), never a bare line.
- Rollback per wave: each wave's last bullet names how to revert it (feature flag, a revert commit,
  or "additive only").

## Order

```
W1 ledger + event log (warden) ─┬─ W3 primary signals + conditions, shadow (warden) ── W4 correlator + known errors, shadow (warden) ─┐
W2 project manifests (dotfiles) ┘                                                                                                ├─ W9 cutover: new path owns intake → incident → task
W5 tasks in the ledger (warden) ── W6 spawner + Witness (dotfiles, warden) ── W7 implementation into herdr (warden, agw, dotfiles) ┤
W8 verification ladder: squash merges, breaker, holdouts (warden, + per fleet repo) ──────────────────────────────────────────────┤
W10 decisions + Argo factory API on the mini + dead-man (warden, argo, basalt-ui, vps) ────────────────────────────────────────┘
W11 telemetry and gateway CLIs (agw, gateways, dotfiles) · W12 improve and heal reconcilers · W13 Hermes capability cut · W14 docs, brain, website — last
```

W1 and W2 can run in parallel (disjoint repos) from per-repo plan copies; W3 needs both.

---

## Wave 1 — The ledger records everything once            <!-- status: pending -->
Repo: warden. ADR-011. Additive only.

- [ ] `events` table exactly as `design/model.md` §4, one `emit()` in `scripts/ledger.py` used inside the same transaction as every state change. Migration with a snapshot (existing pattern).
- [ ] Dual-write: every `item_transitions` row, `operations` row, `dispatches` status change, card post, reminder and Argo action emits its event (`item.transitioned`, `operation.started|finished`, `dispatch.*`, `notification.sent` with tier, `owner.action`). `trace_id` = `sha256("warden-item:" + root item id)[:32]` (ADR-006).
- [ ] Owner pages become a query: `scripts/kpi/` gains read-only scripts for `escalated`, `owner_touch`, `owner_pages`, `autonomy_rate` reading `events` (definitions from `docs/factory/evidence/DEFINITIONS.md`).
- [ ] One-writer check in `make check`: entity writes only from their owning module (a test that greps the SQL write sites).
- [ ] Projection-rebuild test: drop and rebuild a read model from `events`, compare.
- [ ] `PRAGMA integrity_check` in `make verify`; nightly off-box copy of `warden.db` (homelab S3 via `hl`, or the existing backup job), restore tested once.
- [ ] Exit: 72 h live after deploy — events reconcile 100 % with `item_transitions` and `operations` (script); the event-based KPI scripts reproduce `docs/factory/evidence/kpi/baseline.out.json` for the overlapping window within ± 0; `owner_pages` per day recorded. Rollback: additive (stop emitting; the table stays).
**Left behind:**

## Wave 2 — Every project describes itself once            <!-- status: pending -->
Repo: dotfiles (+ one `docs:` commit per repo; basalt-ui by PR; IuRoot manifests in dotfiles-private). ADR-010.

- [ ] `config/factory/project.schema.json` (JSON Schema of `design/model.md` §6) and `scripts/factory.py` (stdlib): `manifest check`, `manifest gen`, `manifest draft <repo>`.
- [ ] `manifest draft` builds a first manifest per repo from what exists: AGENTS.md *Verify & Monitor*, Makefile targets, `config/herdr/groups.json`, `docs/factory/evidence/signals/topology.out.json` (runtime units, Kuma monitors), OTel service names; class from `docs/factory/evidence/projects/classify.out.json`. Review each draft, commit `project.yaml` to all 33 SourceRoot repos; IuRoot drafts in `dotfiles-private/projects/`, linked into each work repo and listed in its `.git/info/exclude`.
- [ ] Generated outputs v1: herdr `groups.json`; an AGENTS.md block between `<!-- factory:begin -->` / `<!-- factory:end -->` per repo (Role line, class, runtime, health URLs, monitors — replacing hand-written duplicates of the same facts); usage-tracker's project map.
- [ ] `manifest check` in dotfiles `make check` and as a daily `jobrun` job: schema, every integration key resolves (Kuma monitor, herdr workspace, brain note, OTel service seen in 7 d), generated blocks in sync, topology covers every running container, launchd job and Kuma monitor. Each blind spot (today 19 of 36 vps services unmonitored, 4 homelab containers) is filed with `warden run`.
- [ ] Exit: `manifest check` green on all repos; zero drift in generated blocks; 100 % of Kuma monitors and containers mapped to a project. Rollback: delete the generated blocks (hand-written text restored from git).
**Left behind:**

## Wave 3 — Signals from their sources, conditions in shadow            <!-- status: pending -->
Repo: warden (+ homelab, vps for the Docker event recorders). ADR-013, loops §1. Needs W1, W2.

- [ ] Signal envelope (`source, subject, kind, severity, fingerprint, occurred_at, raw`) emitted as `signal.received`; `subject` resolved through the manifests' topology; `occurred_at` is source time (Kuma heartbeat time, Slack message ts, Actions run time), never poll time.
- [ ] Adapters: Kuma webhook (pair Up with Down by monitor id), HyperDX webhook, RollHook deploys (job webhook or ClickStack deploy markers), GitHub Actions failures and issues (`gh` poll), Beszel (Shoutrrr webhook); Docker events recorder per host (homelab, vps) pushing to ingest.
- [ ] Health reconciler per project (desired = manifest probes and monitors; observed = latest signals and a direct probe) opening and closing Conditions — **shadow**: it writes Conditions and a daily shadow report against warden's items, it acts on nothing.
- [ ] Replays: the 2026-10-17 VPS reboot and the 2026-10-22 glance gameday streams through the shadow path (`docs/factory/evidence/incidents/`, `evidence/gameday/`).
- [ ] Exit: 7 days of shadow — every Kuma Down/Up pair yields exactly one Condition opened and closed; `occurred_at` within 60 s of the source; zero events missed against the Slack copy; the replays produce one condition set per host. Then switch Slack intake off for every source whose adapter passed (Kuma first). Rollback: shadow only until the Slack switch; the switch is one config line per source.
**Left behind:**

---

## Wave 4 — One cause, one incident (shadow)            <!-- status: pending -->
Repo: warden. ADR-003. Needs W3.
- [ ] Correlator per ADR-003: fingerprint refinement, topology fold, time window, candidate gate, known-error match, regression link; tuned only on the golden set's development chunks.
- [ ] Known-error store = closed incidents with recipe (root cause, fixing change, action class, verification evidence); backfilled from the ledger's resolved items with fix commits.
- [ ] Exit: held-out backtest meets `evidence/golden/PREREGISTRATION.md`; 7 days live shadow — owner pages the shadow path *would* have sent ≤ 10 % of the old path's; B-cubed on a fresh 100-event labelled sample ≥ the backtest's.

## Wave 5 — Tasks live in the ledger            <!-- status: pending -->
Repo: warden (+ dotfiles `/wave` skill). ADR-001.
- [ ] `tasks`, `task_deps`, ready CTE, claim / heartbeat / reclaim; `warden task` CLI with bd's verbs and JSON names; the spike oracle (`spikes/01-beads/scripts/spike.py`) as the acceptance test.
- [ ] Plan projector: `docs/waves/PLAN.md` checklists → Tasks; a wave close-out files every Left-behind item as a Task with an owner.
- [ ] Exit: all active plans projected; 0 Left-behind items without an owner after 2 weeks (baseline 55 % orphaned).

## Wave 6 — One spawner, and agents that do not wait for the owner            <!-- status: pending -->
Repos: dotfiles (`rd`), warden (Agent/Attempt records). ADR-007.
- [ ] `rd` writes Agent and Attempt records and tab metadata; hooks (worktree + branch + `.factory/attempt.md`); Hermes' herdr skill calls `rd`.
- [ ] Witness reconciler on the herdr event record: parked → resume at the quota reset (timer) or after an API-error backoff, or nudge with the plan's next step; stuck → re-drive from the hook; dead → resume by session id; finished-but-open → reap.
- [ ] Exit: 2 weeks with 0 owner `continue` nudges (baseline 50 in 45 days, measured by `evidence/questions/questions.py`); 0 spawns outside `rd`; gameday rows 7–9 pass.

## Wave 7 — Implementation moves into herdr            <!-- status: pending -->
Repos: warden, agent-gateway, dotfiles. ADR-008 (Round 5 W4, unblocked).
- [ ] Warden's implement stage spawns `rd` workers with the engine by class and the quota guard; agw's implement tier off, investigate stays read-only.
- [ ] Exit: one week of fixes landed through herdr workers, 0 agw implement jobs; Max 7-day ≥ 90 % on ≤ 2 days that month; cost per resolved item by engine recorded.

## Wave 8 — Verification replaces approval            <!-- status: pending -->
Repos: warden, + holdouts repo, + each fleet repo. ADR-012.
- [ ] Squash merges in the merge train; automatic revert on post-deploy failure; action-class ladder from the manifests; runaway breaker; rate limits.
- [ ] Private `holdouts` repo with ≥ 5 scenarios per fleet project, run by the verifier after each deploy.
- [ ] Exit: gameday rows 1, 10–12 pass; revert success 100 % on injected failures.

## Wave 9 — Cutover            <!-- status: pending -->
Repo: warden. Needs W4, W5, W8.
- [ ] The new path (signal → condition → incident → task → attempt → change → verify) owns intake; the old triage path and its 65-column stages are retired one at a time behind flags.
- [ ] Exit: 14 days — autonomy ≥ 99 % of items, genuine share of escalations ≥ 90 %, owner pages ≤ 2 per week, reopen ≤ 5 %.

## Wave 10 — Decisions and the cockpit            <!-- status: pending -->
Repos: warden, argo, basalt-ui (PR), vps. ADR-009, ADR-014, `design/argo.md`.
- [ ] Decision entity with options, reversible default, expiry; push tiers; drain the old queue into Decisions.
- [ ] Argo's factory read API on the mini; Home, Project, Needs you, Incidents, Fleet, Artifacts, Health, Usage views; delete the snapshot pushes; VPS dead-man's switch; basalt-ui: land event list, upstream status chip, decision card, entity card; build the lifecycle strip.
- [ ] Exit: the timed Argo test passes on phone and desktop; status questions outside Argo ≤ 5 per week for 2 weeks; gameday row 13 passes.

## Wave 11 — Telemetry and gateway access            <!-- status: pending -->
Repos: agent-gateway, research-, email-, audio-, image-gateway, warden, dotfiles. ADR-004, ADR-006.

## Wave 12 — Improve and heal on the same path            <!-- status: pending -->
Repos: warden (+ Renovate config per repo). Loops §6: deps (Renovate), docs drift, code health, setup bloat, basalt-ui dogfooding, performance, infra, CrowdSec.

## Wave 13 — Hermes holds no code tools            <!-- status: pending -->
Repo: hermes-agent. Round 5 W5's toolset cut as a capability limit with a test; reads the factory API only.

## Wave 14 — Docs, brain, website            <!-- status: pending -->
Repos: dotfiles, brain, jkrumm.com. Last. Generated docs replace hand-written restatements.

---

## Round 5 disposition

| Round 5 wave | Disposition | Where |
|-|-|-|
| W1 Constitution | **merge** — the model is generated from manifests and ADRs instead of hand-written; CodeRabbit removal kept as a chore | W2, W14 |
| W2 Escalation cut | **done in part** (Phase 0: agw W12, warden W8); timeout default → W10; improve loop → W12; shadow promotion → **drop** (the correlator and policy replace the decide lane; its replay set feeds W4's baseline); rebase-merge revert → W8; Argo `adopt` verb → **drop** (Decisions API) | Phase 0, W4, W8, W10, W12 |
| W3 Execution layer | **done in part** (Phase 0: recorder, janitor); tab metadata and one launcher → W6; overview truth → W10; Obsidian 1706 → drained by W8's policy | Phase 0, W6, W10 |
| W4 Implementation into herdr | **keep**, unblocked by ADR-008 | W7 |
| W5 Thin Hermes | **keep**, as a capability limit with a test | W13 |
| W6 Argo control plane | **keep**, redesigned from the owner's questions | W10 |
| W7 Slack retirement | **merge** — intake retires per source in W3; notifications move in W10 | W3, W10 |
| W8 Brain door | **merge** — the project note becomes a projection; one-writer door stays | W5 projections, W14 |
| W9 Observability | **keep** | W11 |
| W10 Docs and website | **keep**, last | W14 |
