# 0. Reading order

The factory's technical design, version 2 — the source of truth for the rewrite and, later, for the
public guide on jkrumm.com. It replaces the report of 2026-10-22 (v1, still in `report-v1.html`).

**Three sections carry the decision:** §1 verdict, §2 what changes for you, §12 the plan.
The design is §3–§11. §13 lists what you may want to override — nothing is waiting on you.
Appendix A maps each of your 33 review comments, the global reply and the brief of 2026-10-24 to
where it landed; B says what was taken from which project; C says what happened to v1.

## v1 → v2 in one table

| Topic | v1 | v2 |
|-|-|-|
| Home | warden, rebuilt | new `factory` repo and CLI; warden switched off and deleted |
| Scope | incidents and hygiene | all work, feature requests included, on one path |
| Who writes code | Claude Code on Max, plus OpenCode on IU API for routine wakes | Claude Code on the two Max accounts only, in herdr |
| Judgment | inside herdr sessions | cheap models through agent-gateway (OpenCode sessions, single calls) |
| Quota | forecast guard, spill to IU API | three admission classes on the picker; wait, never spill |
| State | SQLite ledger + statecharts | Postgres on the mini + DBOS with short workflows, on Node (§6) |
| Argo | split mini / VPS | all on the mini |
| Dedup | rules only | rules + a decision-model judge + investigator merge/split + labels |
| Jobs | reconcilers, Renovate | small TypeScript jobs, zero tokens when green; agentic upgrade waves |
| Projects | `project.yaml` | `project.yaml` + one make contract + deploy mode + per-path autonomy |
| Plan | 14 waves, import first | 6 waves, safety floor first, the factory builds itself from W3 |
| Owner decisions | five | none open |

## v2.1 — after your reply to the podcast

| You said | Now |
|-|-|
| DBOS: Node is fine if that is the blocker | adopted on Node, with short workflows (§6) |
| IU API tokens are avoided too hard; use them for all the stupid work | cheap models do everything that needs a model except implementation (§5) |
| Watch that both subscriptions fill up balanced, with few but smart switches | a balance goal with its own measures and a weekly tuning job (§5) |
| Too many odd worries; classify and order, then let Claude Code do its thing | §4 now centres on what a session gets; edge cases moved to appendix D |
| Slack barely needed; briefing in Argo, not Slack | §10 |
| Argo fully on the phone, no limits | §2, §10 |
| Hermes needs restructuring | W6 (§10, §12) |
| We can build on `me` | W1 starts on `me` (§12) |
