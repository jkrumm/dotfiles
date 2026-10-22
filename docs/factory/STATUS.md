# Factory design — status

Checkpoint for a fresh context. Read `BRIEF.md` first, then this file, then the newest
artifacts it names. Orchestrator: herdr tab `factory` (SourceRoot workspace), Opus, max
effort. Started 2026-10-22 07:40 UTC.

## Phases

| Phase | State | Artifacts |
|-|-|-|
| 0 — stop the bleeding | launched | see *Phase 0* below |
| 1 — evidence | in progress | `evidence/` (conventions `evidence/README.md`, metric definitions `evidence/DEFINITIONS.md`) |
| 2 — model | pending | |
| 3 — loops | pending | |
| 4 — spikes → ADRs | pending | `spikes/`, `adr/` |
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
| Round 5 Wave 3 (cut) | dotfiles `docs/waves/PLAN.md` | herdr event recorder (raw JSONL, no consumers) + `rd reap` janitor | raw agent-lifecycle material is lost daily; reaping finished tabs is needed under any agent topology |

Deliberately **not** launched (an open decision here owns them): timeout default
(durable await-decision design), improve loop job (Phase 3 improve), shadow promotion
(decide lane), feature store as GitHub issues (task SoR spike), herdr POST fan-out and
poll removal (event log design), tab metadata (Agent id scheme), one launcher (spawner),
overview truth, Obsidian 1706, Round 5 W1 and W4–W10 (dispositioned in `waves.md`).

Shared checkout: the dotfiles wave and this session both write the dotfiles checkout —
this session commits only `docs/factory/**` with explicit paths.

## Log

- 07:51 snapshots frozen; evidence conventions and definitions written.
