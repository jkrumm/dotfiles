# Factory design — status

Checkpoint for a fresh context. Read `BRIEF.md` first, then this file, then the newest
artifacts it names. Orchestrator: herdr tab `factory` (SourceRoot workspace), Opus, max
effort. Started 2026-10-22 07:40 UTC.

## Phases

| Phase | State | Artifacts |
|-|-|-|
| 0 — stop the bleeding | running: agent-gateway-w12, warden-w8, dotfiles-w3 (08:2x UTC), usage-tracker-w1 (10:40) | see *Phase 0* below |
| 1 — evidence | 8 workers running: kpi (warden), kpi (delivery/DORA/quota/herdr), postmortem, incidents, interventions, golden sampling, toil, signals | `evidence/` (conventions `evidence/README.md`, metric definitions `evidence/DEFINITIONS.md`) |
| 2 — model | pending | |
| 3 — loops | pending | |
| 4 — spikes → ADRs | spikes 1 (beads), 2 (durable: ledger vs DBOS-Python-on-SQLite), 4 (CLI vs MCP), 5 (artifact review), 6 (telemetry) running; 3 (correlation) waits on the golden set | `spikes/`, `adr/` |
| 5 — Argo | pending | |
| 6 — proof | pending | |
| 7 — panel ×2 | pending | |
| 8 — migration | pending | `waves.md` |
| report | pending | `report.html` |

## Fixed inputs

- `AS_OF = 2026-10-22T08:00:00Z`. Frozen snapshots of the mutable stores (warden.db,
  agw jobs.db, usage.db, research jobs) in `~/.local/share/factory/snapshots/2026-10-22/`
  (`evidence/snapshot.sh`, read-only files, never in git).
- Max quota at start: 5 h 3 %, 7 d 14 % — fan-out is affordable.
- Every evidence output passes `evidence/lib/redact.py --check` before commit (public repo).

## Phase 0 — what was launched and why

Rule from the brief: launch only Round 5 fixes that no open decision in this design can
invalidate. Each runs as an orchestrated `rd wave` tab from its repo's own plan.

| Wave | Repo / plan | Scope | Why it survives any redesign |
|-|-|-|-|
| agw Wave 12 | agent-gateway `docs/waves/PLAN.md` | host read verbs in `agw-readonly`; host-access gap as a structured verdict field; `_common.md` policy lines | whatever runs investigate must read the host; the policy lines encode the fixed owner-decision rule |
| warden Wave 8 | warden `docs/waves/PLAN.md` | brief tells the truth; recovered `slack_alert`/Kuma auto-close; co-firing fold (15 min window); terminal non-questions closed; features kept open on the ledger; drain `needs_decision` | level-triggered recovery, folding and "never drop a feature" are properties of every candidate design; the drain empties a queue that no redesign keeps |
| Round 5 Wave 3 (cut) | dotfiles `docs/factory/phase0/docs/waves/PLAN.md` (own plan: the gate needs a `done` predecessor and Round 5 W1–W2 are pending) | herdr event recorder (raw JSONL, no consumers) + `rd reap` janitor | raw agent-lifecycle material is lost daily; reaping finished tabs is needed under any agent topology |
| usage-tracker Wave 1 (added 10:40) | usage-tracker `docs/waves/PLAN.md` | collect agw's OpenCode v2 store (all IU OpenCode spend missing since 10-14, collector stale yet reporting ok); staleness fails loudly | cost is a control input in every design; raw material lost daily, same rationale as the herdr recorder |

Deliberately **not** launched (an open decision here owns them): timeout default
(durable await-decision design), improve loop job (Phase 3 improve), shadow promotion
(decide lane), feature store as GitHub issues (task SoR spike), herdr POST fan-out and
poll removal (event log design), tab metadata (Agent id scheme), one launcher (spawner),
overview truth, Obsidian 1706, Round 5 W1 and W4–W10 (dispositioned in `waves.md`).

Shared checkout: the dotfiles wave and this session both write the dotfiles checkout —
this session commits only `docs/factory/**` with explicit paths.

## Log

- 07:51 snapshots frozen; evidence conventions and definitions written.
- 08:20 Phase 0 waves launched (orchestrated). 08:25 Phase 1 workers ×8 launched (background subagents, sonnet).
- 08:35 research jobs (local research-gateway, `job` table): 19fe9e52 known-error store + regression detection (deep), 9235cd92 durable await semantics + SQLite-capable engines (deep), 382ddeb9 small-host healing/attack detection (standard). Export each to `research/` when done.
- 08:40 spikes 1, 4, 5, 6 launched.
- 09:05 research exported: `research/2026-10-22-known-error-regression.md`, `research/2026-10-22-durable-await-sqlite.md`, `research/2026-10-22-small-host-healing.md`. Spike 2 launched. Phase 1 adds: owner-question inventory (`evidence/questions/`), Argo/basalt-ui inventory (Explore).
- 09:40 golden frame done (959 packets = 404 sampled + 555 context; 21 chunks; 105 of 114 ever-escalated items; 50 homelab-private entities withheld by the self-contained rule). Labelling workflow `golden-labels` (run wf_f5b1aefd-ccf) launched: 21 labellers + second opinion on chunks 05, 13, 19 → `labels/`, `labels_b/`.
- Flag for the owner (doc contradiction, not fixed here): the global CLAUDE.md lists *security policy* as an owner decision; the brief's fixed rule (business only: product direction, spend, irreversible data loss, other people) excludes it. This design follows the brief; a migration wave aligns the global file.
- 10:35 kpi baseline done (`evidence/kpi/baseline.*`, `cost.*`): autonomy 64.3 % (14d) / 52.2 % (30d); escalated 32.2 % / 28.8 %; reopen 10.4–17.5 %; regression 10.4 % (5/48); cost per resolved item IU $0.36 + Max-equivalent $1.08 (14d). Found: usage-tracker blind to agw OpenCode since 10-14 → Phase 0 wave added.
- 10:50 incidents done (`evidence/incidents/`): ten costliest = 180 pages → ≈ 8 under the ideal path; 10-17 = a 7.9-min VPS kernel reboot (20:49–20:56) that became 18 pages via Slack duplicates; relay lag median 16 min; agent spend negligible, owner attention is the cost; 577 owner-facing notifications vs 140 decision entries → `owner_pages` metric added.
