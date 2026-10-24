# 14. Decisions

## The one open business decision

**O1 — A third subscription.** You mentioned buying another Claude or OpenAI subscription. Default:
not now. From W2 the scheduler measures hours that admitted-class Tasks (P0–P2) wait for capacity.
When that exceeds 10 hours a week for two weeks in a row, a card comes back with the measured gap,
the candidate plans and their prices, and which lanes would move. A ChatGPT plan would add Codex as a
second code engine — a different model family, useful for verification — but it needs its own
launcher and picker lane; a third Claude account is a registry entry.

## Choices you may want to override

Each is decided and the design runs on it; each is cheap to flip before its wave starts.

| Choice | Decided | Alternative | Tradeoff |
|-|-|-|-|
| Language of the factory | TypeScript on Node 24, oRPC + trpc-cli | Python with cyclopts + DBOS Python | Python gives the CLI you like best and DBOS' flagship SDK; TypeScript shares types and the database with Argo and matches every other service you run |
| Durable execution | DBOS on Postgres, gated by W1 | v1's ledger + statecharts on Postgres | DBOS removes hand-written leases, timers and queues; the ledger has no version hazard. W1 decides on evidence |
| CLI name | `factory` (short alias `f`), with `wave`, `task`, `issue` underneath | `wave` as the top-level name | `wave` is one noun of many; the CLI also covers issues, jobs, projects and decisions |
| Push channel | Argo web push; the mini-dark alert through Kuma | ntfy | one app fewer; ntfy is the fallback if iOS web push proves unreliable |

## Your v1 answers

| v1 decision | Your comment | Now |
|-|-|-|
| D1 IU cash for mother wakes (≈ $294/week) | factory judgment on cheap models; implementation on Max mothers | gone: mothers run on Max; judgment and review add ≈ $50–95/week of IU |
| D2 Claude tier | you bought a second subscription | done: `iu` + `me`; a third is O1 |
| D3 autonomy in work repos | prometheus-scripts and StudentEnrolment data-analysis may auto-merge; domain code careful; not monitored | policy in §7 |
| D4 who writes holdout scenarios | "don't understand what you want here" | not a decision: mothers write them, you may edit (§12) |
| D5 retention | "ok" | archive to the homelab, keep local copies; deleting them waits for your yes |

## v1's ADRs in v2

| ADR | v1 | v2 status |
|-|-|-|
| 001 task system | ledger tasks with bd's verbs | **revised** — `factory task` with beads' ideas and our names, on Postgres (§4, §6) |
| 002 durable execution | ledger + statecharts, no engine | **superseded** — DBOS on Postgres, gated by W1; ADR-002's design is the fallback (§6) |
| 003 correlation | deterministic only | **revised** — deterministic gate + similarity + judge + labels (§8) |
| 004 CLI vs MCP | CLI-first, MCP for research-gateway and chrome-devtools | **kept** — generated from one router (§10) |
| 005 artifact review | own service, plannotator interim behind `rv` | **revised** — built into Argo at W7; no `rv` shim; plannotator as-is until then |
| 006 telemetry | one trace per item | **kept** |
| 007 agent topology | mothers for six projects, OpenCode/IU mother wakes in herdr | **revised** — herdr is Claude Code on Max only; five fleet mothers; dotfiles is a session project; judgment in agent-gateway's OpenCode (§4, §5) |
| 008 engine policy | engine by class, forecast guard, IU spill | **superseded** — no IU for code; two-account admission; wait, never spill (§5) |
| 009 Argo hosting | split mini / VPS | **superseded** — all on the mini (§10) |
| 010 project manifest | `project.yaml` | **revised** — + make contract, deploy mode, autonomy per path (§7) |
| 011 ledger + event log | fresh SQLite, one-time import | **revised** — Postgres, facts + derived status, no import (§6) |
| 012 verification ladder | ladder per action class, squash, rollback, breaker | **kept** — checks keyed by head SHA (§4) |
| 013 signal intake | primary sources, Slack intake stops | **revised** — Slack stays as a fallback adapter; Funnel `/ingest` for outside sources (§10) |
| 014 owner decisions | business only, default + expiry | **kept** — plus the three-line writing rule |
| 015 Argo write verbs | intents | **kept** |

The ADR files carry a status line pointing here; their text is unchanged history.
