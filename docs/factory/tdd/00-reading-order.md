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
| State | SQLite ledger + statecharts | Postgres on the mini + a reconcile loop in Bun (DBOS evaluated, §6) |
| Argo | split mini / VPS | all on the mini |
| Dedup | rules only | rules + a decision-model judge + investigator merge/split + labels |
| Jobs | reconcilers, Renovate | small TypeScript jobs, zero tokens when green; agentic upgrade waves |
| Projects | `project.yaml` | `project.yaml` + one make contract + deploy mode + per-path autonomy |
| Plan | 14 waves, import first | 6 waves, safety floor first, the factory builds itself from W3 |
| Owner decisions | five | none open |
