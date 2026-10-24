# ADR-001 — Tasks live in the ledger; beads' design is borrowed, not its runtime

> **v2 status (2026-10-24):** revised — `factory task`, our names, on Postgres (TDD v2 §4, §6). The text below is v1 history.

- Status: accepted · 2026-10-22 · revised after panel passes 1 and 2 (dat-1, dat-10, sim-3)
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

**The ledger is the only home of task state, and git never holds it.** Plan files remain plans
(Artifacts). A one-time projection turns each existing checklist into Tasks and leaves PLAN.md
holding task ids only — static, written once through a normal Change by the projecting agent. Task
state is never materialised in git: Argo's plan progress and `warden task list --plan <path>` render
it, so no transition writes a commit, dirties a live checkout or takes a train slot in a PR-required
repo. The doc lint rejects a checked box or a status marker in a plan file; `/wave` closes a task
with `warden task done`, and every Left-behind line of a wave close-out becomes a Task with an owner
(the postmortem's 55 % orphan rate) through `warden task add`.

Writers per verb (create, claim, heartbeat, done, re-drive, block) and the rule that a Task is
claimed only through the ready queue and `rd` are in `design/model.md` §1 (Task row). A Task has no
separate record for its attempts: they are its worker Agents, each carrying an optional `task_id`
and its hook.

### Consequences

- Good: tasks join with incidents, worker Agents and changes in one store; PLAN.md holds no state, so it cannot disagree with the ledger and no transition writes to git; one backup; IuRoot fits (the ledger sits outside every repo).
- Bad: about 300–400 lines to build (history, labels, comments, export); one SQLite file is one disk — W1b replicates its WAL off-box continuously (ADR-011).

### Confirmation and flip conditions

The spike's oracle (`spikes/01-beads/scripts/spike.py`) is the acceptance test. Revisit if a
stable beads release enforces `external:`, ships two minors without schema migration, exposes a
configurable lease over HTTP, or a second writer host appears.
