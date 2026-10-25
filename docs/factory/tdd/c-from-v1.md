# C. From v1

## Your answers to v1's open decisions

| v1 decision | Your answer | Now |
|-|-|-|
| D1 IU API budget for mother wakes (≈ $294/week) | cheap models judge; Max mothers implement | gone; leads on Max do the reasoning, cheap models the routine within your €500; review is the line to watch (§5) |
| D2 Claude tier | you added a second subscription | done; a third is yours whenever (§13) |
| D3 autonomy in work repos | some IuRoot paths auto-merge; not monitored | §7 |
| D4 who writes holdout scenarios | "don't understand" | not a question: the lead proves its change with production evidence (§4) |
| D5 retention | "ok" | §6 |

## v1's ADRs

| ADR | v1 | v2 |
|-|-|-|
| 001 task system | ledger tasks with bd's verbs | revised: one unit, the Issue (`factory issue`), in Postgres |
| 002 durable execution | ledger + statecharts, no engine | revised: an Issue state machine with an inbox in Postgres, engrams' own conclusion; no DBOS (§6) |
| 003 correlation | deterministic only | revised: two tiers, symptom at intake and cause in the lead; a judge only after a shadow run; labels (§8) |
| 004 CLI vs MCP | CLI-first | kept: generated from one router |
| 005 artifact review | own service, plannotator behind `rv` | revised: *Artifacts* in Argo at W5, no `rv` |
| 006 telemetry | one trace per item | kept: OpenTelemetry to ClickStack |
| 007 agent topology | six mothers, OpenCode/IU wakes in herdr | revised: two layers on Max in herdr, an orchestrator woken per event over one lead per Issue (§4, §5) |
| 008 engine policy | engine by class, spill to IU | superseded: three admission classes, wait never spill |
| 009 Argo hosting | split | superseded: all on the mini |
| 010 project manifest | `project.yaml` | revised: + make contract, deploy mode, migrations, per-path autonomy |
| 011 ledger | fresh SQLite, one-time import | revised: Postgres, no import |
| 012 verification ladder | ladder per action class | revised: the lead ships with production evidence and fixes forward; the factory re-runs `make verify` after the hold (§4) |
| 013 signal intake | primary sources, Slack stops | revised: polling + a Slack adapter, no public endpoint |
| 014 owner decisions | business only | kept, plus the three-line rule |
| 015 Argo write verbs | intents | kept |

Each ADR file carries this status in its first lines.

## v1's weak spots

| Weak spot | Now |
|-|-|
| known-fix match 0.479 < 0.50 | full-text "seen before" + runbook recipes + labels; embeddings on a measured trigger (§8) |
| escalation recall failed on 6 real decisions in 959 | escalation is four business classes the lead raises through `factory issue ask`, not keyword rules |
| no canary, so code fixes stayed propose-only | the lead checks production itself; hold window; the factory's re-verify (§4) |
| the `glance` gameday never healed | W2's gate |
| pre-registration amended, `--verify` fails | a fresh pre-registration is frozen before the first rule change in W3 |
| warden and Hermes backups failing | warden deleted; the infra job checks every remaining backup's age and a restore |
| review door hand-started | retired at W5 |

## v1's plan

Superseded. Kept and re-homed: the manifest schema (W4), intake adapters (W2, W4), Argo pages (W5),
artifacts (W5), jobs (W6), gamedays and SLOs (§11). Moved into the lead: merge and deploy. Dropped: the
history import, the shadow replay, the Argo split, the IU engine for mothers, the effect registry on
SQLite, automatic rollback.
