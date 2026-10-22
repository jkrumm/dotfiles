# ADR-012 — Verification replaces approval: a ladder per action class, no owner gates

- Status: accepted · 2026-10-22
- Evidence: `evidence/kpi/baseline.out.md` (warden revert 0 of 52 merges: all rebase merges, 3 failed verifications "cannot auto-revert"; reopen 10.4 %; regression 10.4 %), `evidence/kpi/dora.out.md` (CFR 2.0 % attributed, recovery median 0.27 h), `evidence/interventions/interventions.md` (4 of 20 genuine), `research/2026-10-21-dark-factory-landscape.md` §3 (agent review is a signal, deterministic checks gate), `research/2026-10-22-agents-durable-mcp-otel.md` §3 (StrongDM holdouts)

## Context and problem statement

The owner decides business questions only and wants ≤ 0.1 % of items to reach him. Self-approval
is principled only if the evidence that authorises a ship is named per kind of action, rollback is
automatic, and runaway loops stop themselves — without turning any of that into an owner gate.

## Decision outcome

**A ladder per action class** (restart, config, dependency, code fix, migration, infra): the
evidence that authorises auto-ship, the automatic rollback, and blast-radius and rate limits —
table in `design/loops.md` §3, carried into each project's manifest `autonomy` block.

Rules that hold on every rung:
1. Deterministic evidence gates (checks, CI on the merge SHA, holdout scenarios, health and
   post-deploy verify, the incident's own condition resolving); agent review is a signal that can
   block but never approves alone.
2. **Merges are revertible by construction:** squash or merge commits, never rebase-merges of
   several commits — today's rebase merges made automatic revert impossible (0 of 52).
3. **Holdout scenarios** per fleet project live outside every agent-writable checkout (a private
   repo run by the verifier against the deployed app), scored on observed behaviour.
4. **Rate limits and blast radius:** one change in flight per repo (merge train), restart caps per
   service and host, one infra action per host at a time, migrations never during an open incident.
5. **Runaway breaker:** more than 3 automatic changes for one incident in 24 h without resolution,
   or 2 rollbacks in 24 h, stops automatic shipping for that scope and moves the incident to a
   stronger engine with full history. It shows in Argo as stuck. **It never pages the owner.**
6. Owner gates are not a safety mechanism; the only owner exits are business Decisions (ADR-014).

### Consequences

- Good: autonomy rises without lowering the evidence bar; every auto-ship has a queryable reason (its Verification records).
- Bad: holdouts must be written and kept honest per fleet project; squash merges lose intra-PR history (acceptable: the PR keeps it).

### Confirmation

KPIs: change failure rate (2.0 % baseline, attributed), revert success when verification fails (0 %
→ 100 %), breaker openings per month, reopen and regression rates (10.4 % each → ≤ 5 %).
Gamedays (`design/proof.md`) exercise each rung.
