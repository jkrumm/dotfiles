# ADR-012 — Verification replaces approval: a ladder per action class, no owner gates

- Status: accepted · 2026-10-22 · revised after panel pass 1 (ver-1…ver-8, sre-4, int-4, cos-6)
- Evidence: `evidence/kpi/baseline.out.md` (warden revert 0 of 52 merges: all rebase merges, 3 failed verifications "cannot auto-revert"; reopen 10.4 %; regression 10.4 %, 5 of 48 evaluable fixes), `evidence/kpi/dora.out.md` (CFR 2.0 % attributed, recovery median 0.27 h; 1418 deploys in 90 d, mostly Actions-on-push), `evidence/signals/signals.md` (19 of 36 vps services without a Kuma monitor or push), `evidence/incidents/incidents.md` #2–#4 (the observer was wrong, not the service), `evidence/interventions/interventions.md` (4 of 20 genuine), `research/2026-10-21-dark-factory-landscape.md` §3 (agent review is a signal, deterministic checks gate), `research/2026-10-22-agents-durable-mcp-otel.md` §3 (StrongDM holdouts)

## Context and problem statement

The owner decides business questions only and wants ≤ 0.1 % of items to reach him. Self-approval
is principled only if the evidence that authorises a ship is named per kind of action, rollback is
automatic, and runaway loops stop themselves — without turning any of that into an owner gate.

## Decision outcome

**A ladder per action class** (restart, config, dependency, code fix, migration, infra): the
evidence that authorises auto-ship, the automatic rollback, and blast-radius and rate limits —
table in `design/loops.md` §3. The rung that applies is the **effective autonomy** per (project,
action class), computed by `factory manifest check` from which evidence producers exist; the
manifest's `autonomy` block can only lower it.

Rules that hold on every rung:
1. Deterministic evidence gates (checks, CI on the merge SHA, holdout scenarios, health and
   post-deploy verify, the incident's own condition resolving); agent review is a signal that can
   block but never approves alone.
2. **Fail closed on absent evidence** (ver-1): a rung whose evidence has no producer (no probe, no
   deployed app, no deploy record) is never passed vacuously — the Change is **propose-only**
   (opened and verified, not merged) and the gap is filed as a factory Task; it flips back when the
   producer exists. Not an owner gate: nobody approves it.
3. **`factory-self`** (ver-2): changes to the factory's own ship path, verifier, holdout runner,
   breaker, rollback, and to manifest `autonomy`/rate limits/holdout locations are their own action
   class, verified by the previously released factory (N-1 verifies N); an independent watchdog
   restores a pinned last-known-good release. No Change can raise its own gate.
4. **Rollback is a Deployment operation** (ver-3): redeploy the last `verified` Deployment by image
   digest, compose revision or previous launchd bundle (recorded per runtime); the git revert
   follows as an ordinary Change. Every agent-originated push lands as one train entry, so every
   agent Change has a revertible unit. Merges stay squash or merge commits, never rebase-merges of
   several commits — today's rebase merges made automatic revert impossible (0 of 52).
5. **Holdout scenarios** per fleet project live outside every agent-writable checkout (a private
   repo run by the verifier against the deployed app), scored on observed behaviour. They change
   only through a Change to the holdouts repo by a verifier-role agent that sees the approved plan
   Artifact, never the product diff (ver-7).
6. **Migrations** (ver-6): the auto rung allows only expand/contract migrations whose expand step
   keeps the previous release working, so rollback is code-only; a contract step that drops data is
   the data-loss class — an owner Decision by the fixed rule.
7. **Two observations before a restart** (sre-4): the restart recipe acts only when two independent
   observations agree (Kuma plus Docker state, a direct probe, or evidence of recent work);
   disagreement opens `probe.disagrees` on the monitor — a monitoring defect filed as a Task, no
   restart.
8. **Hold before reuse** (ver-8): the post-deploy hold per condition type is ≥ 2 × the
   fingerprint's historical median inter-occurrence gap, and ≥ 24 h for crash, OOM and flap types;
   a recipe is promoted to automatic reuse only after its hold confirms it.
9. **Product surfaces** (int-4): a Change touching a manifest `product_surfaces[]` entry (public
   routes, store listings, pricing, holdout scenarios, removed features) that does not trace to an
   owner-submitted brief or a reviewed plan Artifact is product-class and becomes a Decision with a
   reversible default (ADR-014).
10. **Rate limits and blast radius:** one change in flight per repo (merge train), restart caps per
    service and host, one infra action per host at a time, migrations never during an open incident.
11. **Runaway breaker** (ver-4): counts per **lineage** over 7 days — more than 3 automatic changes
    without resolution, or 2 rollbacks; restarts count as automatic changes; a revert writes a
    known-bad marker so the same version is not re-shipped. Tripping stops automatic shipping for
    that lineage and moves it to a stronger engine with full history. It shows in Argo as stuck.
    **It never pages the owner.**
12. **Budgets** (ver-5, cos-6): each Task and lineage carries a budget in attempts, IU dollars and
    Max percent (never wall clock — the owner's no-cap rule), interim ceiling 3 × the per-class
    baseline p90 cost (ADR-008); Witness auto-continues and re-drives count against it with
    backoff; exhaustion opens the breaker for that lineage.
13. Owner gates are not a safety mechanism; the only owner exits are business Decisions (ADR-014).

### Consequences

- Good: autonomy rises without lowering the evidence bar; every auto-ship has a queryable reason (its Verification records); a subject without evidence producers is visible as propose-only plus a Task, not silently auto-shipped; the factory cannot ship its own gate.
- Bad: holdouts must be written and kept honest per fleet project; squash merges lose intra-PR history (acceptable: the PR keeps it); per-runtime rollback targets must be recorded; N-1 verification keeps two factory releases deployable.

### Confirmation

KPIs: change failure rate (2.0 % baseline, attributed), rollback success when verification fails
(0 % → 100 %), breaker openings per month, reopen and regression rates (10.4 % each → ≤ 5 %),
propose-only Changes open and their gap Tasks, `probe.disagrees` per month.
Gamedays (`design/proof.md`) exercise each rung.
