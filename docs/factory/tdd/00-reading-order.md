# 0. Reading order

The factory's technical design, version 2.3 — the source of truth for the rewrite and, later, for the
public guide on jkrumm.com. It replaces the report of 2026-10-22 (v1, still in `report-v1.html`).

**Four sections carry the decision:** §1 verdict, §4 the loop and its two layers, §6 state and where
sessions run, §12 the plan. The design is §2–§11; §13 lists what you may want to override, and no
decision is open. Appendix A maps each of your comments, replies and briefs to where it landed; B says
what was taken from which project; C says what happened to v1; D lists the edge cases and the wave
that handles each; E places this factory among the others and in the field's vocabulary.

## v1 → v2 in one table

| Topic | v1 | v2 |
|-|-|-|
| Home | warden, rebuilt | new `factory` repo and CLI; warden switched off and deleted |
| Scope | incidents and hygiene | all work, feature requests included, on one path |
| Who writes code | Claude Code on Max, plus OpenCode on IU API for routine wakes | Claude Code on the two Max accounts only, in herdr |
| Reasoning | inside herdr sessions | the lead, one Claude Code session per Issue, end to end; cheap models only sort and word |
| Quota | forecast guard, spill to IU API | three admission classes on the picker; wait, never spill |
| State | SQLite ledger + statecharts | Postgres on the mini; an Issue state machine with an inbox; DBOS your call (§6) |
| Argo | split mini / VPS | all on the mini |
| Dedup | rules only | symptom at intake (rules, a judge once proven), cause in the lead, labels (§8) |
| Jobs | reconcilers, Renovate | small TypeScript jobs, zero tokens when green; agentic upgrade waves |
| Projects | `project.yaml` | `project.yaml` + one make contract + deploy mode + per-path autonomy |
| Plan | 14 waves, import first | 6 waves, one lead end to end first, the factory builds itself from W3 |
| Owner decisions | five | one: durable execution (§6) |

## v2.1 — after your reply to the podcast (superseded by v2.2 where they differ)

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

## v2.2 — after your comments of 25 October

| You said | Now |
|-|-|
| Claude Code should do it all: cause, plan, build, verify, ship, verify again, report | the lead owns each Issue end to end; the factory runs the lifecycle around it (§4) |
| Cheap models must not investigate or plan; their claims confuse the smart model | the brief carries facts, never a diagnosis; cheap models only sort and word (§3, §4) |
| Not sure DBOS is needed; look at Cortex | engrams, read in source: an Issue state machine with an inbox, not DBOS; your decision (§6) |
| Rollback rarely works; fix forward | the lead fixes forward; no automatic rollback (§4) |
| Dedup needs the root cause; the judge needs testing | two tiers; the judge runs in shadow from W2 and acts only once it earns trust (§8) |
| A daddy orchestrator watching tokens, limits and `me`'s 5-hour window | the steward; 5-hour-aware admission; model and effort per lead (§5) |
| Sharp changelog, self-monitoring, more deterministic paths | leads' summaries, the scorecard, fixes verified twice become runbooks (§8, §9) |
| GitHub issues as requests; TickTick for human tasks | §7, §10 |
| Start after my review | §12 |

## v2.3 — after your voice note of 25 October

| You said | Now |
|-|-|
| Two layers, not three: an orchestrator and the implementers | an orchestrator over the leads; mothers and the steward merged into it; a fresh session per event (§4) |
| herdr, or `claude -p` / the Agent SDK? Old chats retrievable | interactive sessions in herdr behind a `Runner` port, Postgres owns the work; headless costs ≈ 1.8× the 5-hour window per token; transcripts archived, `factory issue resume`; a `claude --bg` spike in W3 (§6) |
| Plain sessions for the simple repos | repos without a manifest stay outside the factory (§7) |
| DBOS: I don't care | no DBOS (§6) |
| The dedup strategy was confusing | one judge, shadow then trusted (§8) |
| Warp, the field's language, solo versus company | appendix E; scorers, autonomy KPIs, manifest schema adopted (§7, §9); the brain's field guide |

