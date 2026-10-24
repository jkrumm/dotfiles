# ADR-015 — Argo's write half: intent verbs, executed by reconcilers, never imperative calls

> **v2 status (2026-10-24):** kept (TDD v2 §10). The text below is v1 history.

- Status: accepted · 2026-10-22 (owner intent: "Argo as a full control plane") · revised after panel pass 1 (ux-4, ux-5, dur-7, dat-6, sim-3) and pass 2 (ux-1, ux-4, ux-5, ux-6, dur-8, dat-9; carry-through of pass-1 dat-2, dur-1 and sim-5). In the body, `p2` marks a pass-2 id.
- Evidence: the owner's prompt; `evidence/questions/questions.md` (50 `continue` nudges, 15 needless approvals, 9 "which tabs can close"); `evidence/interventions/interventions.md`; Argo inventory (today's verbs: implement, merge, dismiss, reinvestigate, retry, note — pulled by warden from a queue); ADR-009, ADR-011, ADR-014

## Context and problem statement

Deriving Argo from questions yields its read half. A control plane also writes — and today's
writes are a queue that warden pulls every few minutes, one verb list hand-mirrored between two
repos (Round 5 found `adopt` missing). What may the owner do from Argo, and how does it execute?

## Decision outcome

**Every write is an intent recorded in the ledger through the factory API (ADR-009) and executed by
a reconciler or the spawner. Argo never calls a service imperatively.** An intent is an owner event
with a lifecycle on its target entity — no new noun, no table (p2 dat-9): the click is an event with
actor `owner` on the target, and the executor writes the end state on the same entity. Intents are
level-triggered like everything else: a restarted executor finds the intent and finishes it; a
repeated click is the same intent (idempotency key = verb + subject + client nonce, minted per
rendered form, ADR-004).

**Every intent ends in one of three states** (ux-4): `applied`, `rejected(reason)` or
`expired(budget)`, against a per-verb budget; the lifecycle strip shows exactly these. An `expired`
intent opens a Condition on the factory itself — the executor missed its budget — and flows through
the loop as a capability gap (ADR-014 rule 5). The `intents_recent` read model (`design/argo.md`
§2) folds the owner's intents of the last 7 days with their end states; each non-applied end state
appears once in *Since you left*, and the full list is a drill-down on Home (p2 ux-6).

| Verb | Writes (noun) | Executor | Audit events | Budget → end state | Phone affordance |
|-|-|-|-|-|-|
| **Submit** a brief or task to a project | Task (origin `owner`, brief, priority, optional plan) | planner → ready queue → `rd` | `task.created` | shows `claimed` or its queue position (incl. an admission deferral, ADR-007 §3); planner rejection is `rejected(reason)` | composer on the Project page; Hermes voice note |
| **Message / steer** a running agent | Agent message event (text, expects-reply flag) in the agent's hook inbox | Witness nudges the pane once with the message id (`rd say`, probe-before-retry on that id, ADR-007 §5); the agent answers with `warden agent reply`, the one writer of `agent.replied` (p2 dur-8, ux-5) | `agent.messaged`, `agent.message_delivered`, `agent.replied` | delivered ≤ 10 s (the id is in the pane record); reply ≤ 2 min, shown on the agent row; the strip reads delivered → replied or `expired`, never a silent *delivered* | reply field on the agent row |
| **Pause / resume** automation — per project or global (the owner's manual brake) | Desired-state override in the project runtime record (scope, reason, optional `until`) | every reconciler and the spawner read the override before acting | `automation.paused`, `automation.resumed` | applied when every reconciler has acknowledged, ≤ 60 s; otherwise `expired`; mini unreachable: `rejected(unreachable)` | one ambient term on line 1 (`paused until Thu 18:00`, or `paused 3 d` without an `until`); one toggle per project; a global switch on Home |
| **Decide / override** a Decision | Decision outcome (`decider: owner`, `decided_at` = server receipt time) | the decide loop applies it; an answer after the deadline is an override intent with its own generation keys, which re-runs the alternative if still reversible | `decision.decided`, `decision.overridden` | applied or `rejected(irreversible)` | the Needs-you card's option buttons |
| **Comment** on an artifact | Artifact comment event (anchor triple, text, thread) | the `warden artifact` module of the warden process (ADR-005); a waiting agent's `warden artifact wait` returns `feedback` | `artifact.commented` | applied on ledger write | select text → comment |
| **Re-verify / retry** | Verification (`pending`) on a change, deployment or incident; or Task back to `ready` with a new worker Agent | the verifier reconciler; the spawner | `verification.requested`, `task.retried` | applied when the Verification or the worker starts; a spent budget is `rejected(budget)` | button on the incident and delivery views |
| **Stop / reap** an agent | Agent desired state `stopped` | Witness: `rd close` when clean and pushed, otherwise a message to the agent and `rejected(dirty or unpushed)` listed on its Fleet row | `agent.stop_requested`, `agent.reaped` | ≤ 60 s | stop on the Fleet row |

**Pause stops actions only** (p2 ux-4): reconcilers and the spawner stop shipping, restarting and
spawning for the scope, while observation, Conditions and incidents continue, so a paused project's
open Conditions still show on Home. An optional `until` ends it by itself and shows on line 1;
without one, line 1 shows its age. It is a field of the project runtime record: never a card, a
Decision or an owner touch (ADR-014). Pressed while the mini is unreachable, it ends
`rejected(unreachable)` on the strip: a VPS-side inbox would be a second writer of the override,
and nothing runs on the mini while it is down; on its return the factory runs from its last
recorded state, so the owner presses pause again.

**Where an intent runs** (p2 ux-1). Resume, steer and stop run where the agent lives. On the mini:
Witness and `rd`. On the MacBook (shutterflow's fleet): the MacBook actuator (ADR-007 §8), whose
acknowledgement moves the intent to `applied`. While the laptop sleeps the strip reads
`queued · host_asleep since hh:mm` and the intent expires on its budget.

Seven verbs, no new noun (`design/model.md` §1): pause is a field of the project runtime record,
messages and comments are events. Verbs are defined once in the factory API's command definitions
(ADR-004), so Argo, the `warden` CLI and Hermes expose the same set — no hand-mirrored verb list.

### Consequences

- Good: no pull queue, no imperative side channel; every owner action is an auditable event and every non-applied end state surfaces once; owner touches count per lineage root, excluding `*.created` and pause (ADR-014 rule 0); the phone does everything the desktop does, MacBook agents included.
- Bad: intents complete asynchronously — Argo shows *requested → applied / rejected / expired* (the lifecycle strip) instead of instant results; a steer to a sleeping MacBook expires instead of waiting; the MacBook actuator is a second small component; a pause pressed while the mini is down must be pressed again.

### Confirmation

W6's gate exercises each verb end to end (intent → executor → audit event → visible end state
within its budget), including both non-applied end states: a steer to an agent that is mid-tool-call
ends delivered → replied or `expired`, never a silent *delivered*; with one reconciler killed, pause
ends `expired` within 60 s and opens a Condition on the factory; with the mini stopped, the global
pause from the phone ends `rejected(unreachable)`; resume, steer and stop against a MacBook agent
run through the actuator and end `applied` on its acknowledgement; `intents_recent` answers "did my
last three requests land?" from Home, rejected and expired ones included. A CI check fails if Argo,
the CLI and Hermes expose different verb sets, or if `agent.replied` has any writer but
`warden agent reply`.
