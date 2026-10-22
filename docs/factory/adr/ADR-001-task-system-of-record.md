# ADR-001 — Tasks live in the ledger; beads' design is borrowed, not its runtime

- Status: accepted · 2026-10-22
- Evidence: `spikes/01-beads/REPORT.md` (210 real tasks, 17 scripts, crash and race tests), `research/2026-10-22-agents-durable-mcp-otel.md` §1, `evidence/postmortem/postmortem.md` (55 % of 293 open Left-behind items name no owner)

## Context and problem statement

The mother → lead → worker model needs one blocker-aware ready queue across about 34 personal repos
and a few work repos that must stay untouched, with atomic claims, leases, heartbeat and reclaim
after a crash, and read paths for Argo, warden and Hermes. Today work lives in plan files, warden
items, GitHub issues and Left-behind lists, and much of it dies there.

## Considered options

- **A — beads per repo, embedded Dolt.** **B — beads with one shared Dolt server.**
- **C — extend the warden ledger** with `tasks`, `task_deps`, a recursive-CTE ready query and lease columns.

## Decision outcome

**Chosen: C.** Measured on the same oracle, races and kill tests:

| | A embedded | B shared | C ledger |
|-|-|-|-|
| `ready` matches the oracle | yes | yes | yes |
| cross-repo dependency blocks `ready` | no (0/9, unreleased fix) | no (0/9) | yes |
| reclaim after `kill -9` | 305 s, TTL not configurable | 309 s | 30 s, configurable |
| CPU per CLI call | 276–483 ms | 94–120 ms | 31–36 ms |
| work repo left untouched | only `BEADS_DIR` outside + `--stealth` | same | yes, by construction |
| self-recovery after a crash | yes | server never restarted by `bd` (3/3) | yes |
| new processes and binaries | 138 MB binary | + Dolt server (pin 3 minors behind) | none |

The ledger gets `tasks`, `task_deps`, task events in the event log (ADR-011), the ready CTE, and
claim / heartbeat / reclaim as conditional updates; a thin `warden task …` CLI keeps bd's verbs and
JSON field names, so agents written against bd lose nothing and a later swap stays cheap.

**The ledger is the only home of task state.** Plan files remain plans (Artifacts). A one-time
projection turns each existing checklist into Tasks; from then on the PLAN.md checklist is a
marker block generated from the ledger and drift-checked like the AGENTS.md routing block.
Hand-ticking a box or a status marker is banned by the doc lint; `/wave` closes a task with
`warden task done`, and every Left-behind line of a wave close-out becomes a Task with an owner
(the postmortem's 55 % orphan rate) through `warden task add`.

| Task write | Command source | Write module |
|-|-|-|
| create | planner, owner submit, wave close-out (`warden task add`) | `tasks` |
| claim, heartbeat, release | spawner; the worker Agent with its epoch (`warden task heartbeat`) | `tasks` |
| done | the worker Agent or `/wave` (`warden task done`) | `tasks` |
| ready again, blocked, cancelled | Witness (re-drive), decide step, planner (supersede) | `tasks` |

A Task has no Attempt record: its attempts are its worker Agents, each carrying an optional
`task_id` and its hook (`design/model.md` §1).

### Consequences

- Good: tasks join with incidents, worker Agents and changes in one store; PLAN.md can no longer disagree with the ledger; one backup; IuRoot fits (the ledger sits outside every repo).
- Bad: about 300–400 lines to build (history, labels, comments, export); one SQLite file is one disk — add a nightly off-box copy (Litestream or the existing snapshot job) in the same wave.

### Confirmation and flip conditions

The spike's oracle (`spikes/01-beads/scripts/spike.py`) is the acceptance test. Revisit if a
stable beads release enforces `external:`, ships two minors without schema migration, exposes a
configurable lease over HTTP, or a second writer host appears.
