# ADR-015 — Argo's write half: intent verbs, executed by reconcilers, never imperative calls

- Status: accepted · 2026-10-22 (owner intent: "Argo as a full control plane") · revised after panel pass 1 (ux-4, ux-5, dur-7, dat-6, sim-3)
- Evidence: the owner's prompt; `evidence/questions/questions.md` (50 `continue` nudges, 15 needless approvals, 9 "which tabs can close"); `evidence/interventions/interventions.md`; Argo inventory (today's verbs: implement, merge, dismiss, reinvestigate, retry, note — pulled by warden from a queue); ADR-009, ADR-011, ADR-014

## Context and problem statement

Deriving Argo from questions yields its read half. A control plane also writes — and today's
writes are a queue that warden pulls every few minutes, one verb list hand-mirrored between two
repos (Round 5 found `adopt` missing). What may the owner do from Argo, and how does it execute?

## Decision outcome

**Every write is an intent recorded in the ledger through the factory API (ADR-009) and executed by
a reconciler or the spawner. Argo never calls a service imperatively.** Intents are level-triggered
like everything else: a restarted executor finds the intent and finishes it; a repeated click is
the same intent (idempotency key = verb + subject + client nonce).

**Every intent ends in one of three states** (ux-4): `applied`, `rejected(reason)` or
`expired(budget)`, against a per-verb budget; the lifecycle strip shows exactly these.

| Verb | Writes (noun) | Executor | Audit events | Budget → end state | Phone affordance |
|-|-|-|-|-|-|
| **Submit** a brief or task to a project | Task (origin `owner`, brief, priority, optional plan) | planner → ready queue → `rd` | `task.created` | shows `claimed` or its queue position (incl. quota-guard deferral); planner rejection is `rejected(reason)` | composer on the Project page; Hermes voice note |
| **Message / steer** a running agent | Agent message event (text, expects-reply flag) | Witness delivers through `rd say` once, acknowledged | `agent.messaged`, `agent.message_delivered`, `agent.replied` | delivered ≤ 10 s; reply ≤ 2 min, shown on the agent row | reply field on the agent row |
| **Pause / resume** automation — per project or global (the breaker's manual switch) | Desired-state override in the project runtime record (scope, reason); no expiry, no default | every reconciler and the spawner read the override before acting | `automation.paused`, `automation.resumed` | applied when every reconciler has acknowledged | one ambient term on line 1; one toggle per project; a global switch on Home |
| **Decide / override** a Decision | Decision outcome (`decider: owner`, `decided_at` = server receipt time) | the decide loop applies it; an answer after the deadline is an override intent with its own generation keys, which re-runs the alternative if still reversible | `decision.decided`, `decision.overridden` | applied or `rejected(irreversible)` | the Needs-you card's option buttons |
| **Comment** on an artifact | Artifact comment event (anchor triple, text, thread) | the `rv` service; a waiting agent's `rv wait` returns `feedback` | `artifact.commented` | applied on ledger write | select text → comment |
| **Re-verify / retry** | Verification (`pending`) on a change, deployment or incident; or Task back to `ready` with a new worker Agent | the verifier reconciler; the spawner | `verification.requested`, `task.retried` | applied when the Verification or the worker starts; a spent budget is `rejected(budget)` | button on the incident and delivery views |
| **Stop / reap** an agent | Agent desired state `stopped` | Witness: `rd close` when clean and pushed, otherwise a message to the agent and `rejected(dirty or unpushed)` listed on its Fleet row | `agent.stop_requested`, `agent.reaped` | ≤ 60 s | stop on the Fleet row |

Seven verbs, no new noun: pause is a field of the project runtime record, not a Decision — never a
card, never a Decision, never an owner touch (ux-5); messages and comments are events. The concept
budget is eleven nouns (Attempt dropped, ADR-007).
Verbs are defined once in the factory API's command definitions (ADR-004), so Argo, the `warden` CLI
and Hermes expose the same set — no hand-mirrored verb list.

### Consequences

- Good: no pull queue, no imperative side channel; every owner action is an auditable event; `owner_touch` counts only owner events on items he did not originate, excluding `*.created` and pause (ADR-014 rule 0); the phone does everything the desktop does.
- Bad: intents complete asynchronously — Argo shows *requested → applied / rejected / expired* (the lifecycle strip) instead of instant results.

### Confirmation

W6's gate exercises each verb end to end (intent → executor → audit event → visible end state
within its budget); a CI check fails if Argo, the CLI and Hermes expose different verb sets.
