# ADR-015 — Argo's write half: intent verbs, executed by reconcilers, never imperative calls

- Status: accepted · 2026-10-22 (owner intent: "Argo as a full control plane")
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

| Verb | Writes (noun) | Executor | Audit events | Phone affordance |
|-|-|-|-|-|
| **Submit** a brief or task to a project | Task (origin `owner`, brief, priority, optional plan) | planner → ready queue → `rd` | `task.created` | composer on the Project page; Hermes voice note |
| **Message / steer** a running agent | Agent message (text, expects-reply flag) | Witness delivers through `rd say` once, acknowledged | `agent.messaged`, `agent.message_delivered` | reply field on the agent row |
| **Pause / resume** automation — per project or global (the breaker's manual switch) | Decision of kind `automation.pause` (scope, reason, expiry; default on expiry: resume) | every reconciler and the spawner read open pauses before acting | `automation.paused`, `automation.resumed` | one toggle per project; a global switch on Home |
| **Decide / override** a Decision | Decision outcome (`decider: owner`) | the decide loop applies it; an override after a default re-runs the alternative if still reversible | `decision.decided`, `decision.overridden` | the Needs-you card's option buttons |
| **Comment** on an artifact | Artifact comment (anchor triple, text, thread) | the `rv` service; a waiting agent's `rv wait` returns `feedback` | `artifact.commented` | select text → comment |
| **Re-verify / retry** | Verification (`pending`) on a change, deployment or incident; or Task back to `ready` with the next attempt | the verifier reconciler; the spawner | `verification.requested`, `task.retried` | button on the incident and delivery views |
| **Stop / reap** an agent | Agent desired state `stopped` | Witness: `rd close` when clean and pushed, otherwise a message and a listed exception | `agent.stop_requested`, `agent.reaped` | stop on the Fleet row |

Seven verbs, no new noun: pause is a Decision with an expiry (the concept budget stays at twelve).
Verbs are defined once in the factory API's command definitions (ADR-004), so Argo, the `warden` CLI
and Hermes expose the same set — no hand-mirrored verb list.

### Consequences

- Good: no pull queue, no imperative side channel; every owner action is an auditable event and counts toward `owner_touch`; the phone does everything the desktop does.
- Bad: intents complete asynchronously — Argo shows *requested → applied* states (the lifecycle strip) instead of instant results.

### Confirmation

W6's gate exercises each verb end to end (intent → executor → audit event → visible state); a CI
check fails if Argo, the CLI and Hermes expose different verb sets.
