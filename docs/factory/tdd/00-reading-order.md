# 0. Reading order

This is the factory's technical design, version 2. It replaces the 2026-10-22 report (v1, still
buildable with `python3 -I report/build.py --v1` → `report-v1.html`). v2 folds in your 33 review
comments, the global reply and the brief of 2026-10-24. Every comment and where it landed is in §15.

**If you read three things:** §1 (verdict), §2 (what changes for you), §13 (the plan).

**If you read for the design:** §3 principles → §4 the loop → §5 capacity → §6 data → §7 projects →
§8 dedup → §9 jobs → §10 surfaces. §11 says what we took from which project, §12 how we know it
works, §14 every decision and what you may want to override.

## What changed since v1

| Topic | v1 (2026-10-22) | v2 (2026-10-24) | Why |
|-|-|-|-|
| Home of the loop | warden, rebuilt | a new `factory` repo and CLI; warden is switched off and its data archived, not imported | your comments 9, 13, global reply |
| Scope of the loop | incidents and hygiene | **all work**: incidents, bugs, hygiene, upgrades and feature requests take the same path | global reply |
| Who writes code | Claude Code/Max for your work, OpenCode/IU for routine mother wakes | **Claude Code on the two Max subscriptions only**, always in herdr; IU never writes code | comments 5, 27, brief |
| Factory judgment | inside herdr mothers | cheap models (Haiku 5.5, DeepSeek V4.1 Flash) in agent-gateway's OpenCode server — not herdr | comments 2, 23 |
| Quota | forecast guard, unattended waves spill to IU | two-account scheduler; non-urgent work waits for the reset; no spill | comment 27, brief |
| State | SQLite ledger + hand-written statecharts, no engine | **Postgres 18 on the mini + DBOS**, gated by a re-run of the spike that DBOS lost | comments 25, 29, global reply |
| Argo | split: API on the mini, SPA on the VPS | **all on the mini**, reading the same Postgres | comments 4, 28, 32 |
| Task system | ledger tasks with bd's verbs | `factory task`: beads' good ideas, our names | comments 3, 21, 24 |
| Dedup | deterministic only | deterministic gate + similarity over past issues + cheap judge for the residue + learning from every merge and split | comment 15 |
| Upgrades | Renovate | agentic upgrade waves from a deterministic scan | comment 17 |
| Recurring jobs | reconcilers | deterministic pipelines that spend zero tokens when nothing is found | comment 20 |
| Project contract | `project.yaml` | `project.yaml` + **one make contract** (`check`, `test`, `quality`, `deploy`, `verify`, `logs`, `status`) + autonomy per path | global reply, comments 6, 12 |
| Diagrams | hand-made SVG | Mermaid source rendered by pele | global reply |
| The plan | 14 waves, strangler-free but import-first | 11 waves, walking skeleton first, the factory builds itself from W2 | §13 |
| Owner decisions | five | one (a third subscription), with a measured trigger | §14 |

## What v2 keeps from v1

The evidence base (`evidence/`, frozen at 2026-10-22T08:00Z), the golden set and backtest, the
gameday catalogue, the KPI definitions, Argo's question-first method (`design/argo.md` §2), the
verification ladder (ADR-012), one trace per item (ADR-006), CLI-first (ADR-004), business-only owner
decisions (ADR-014) and Argo's intent verbs (ADR-015). v1's design files stay in `design/` and
`adr/` as history; §14 gives each ADR its v2 status.
