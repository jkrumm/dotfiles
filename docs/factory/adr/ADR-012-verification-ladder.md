# ADR-012 — Verification replaces approval: a ladder per action class, no owner gates

- Status: accepted · 2026-10-22 · revised after panel pass 1 (ver-1…ver-8, sre-4, int-4, cos-6) and pass 2 (ver-1…ver-7, sim-4, sim-5, sre-5, int-8, dat-9, dat-12, cos-15). In the body, `p2` marks a pass-2 id.
- Evidence: `evidence/kpi/baseline.out.md` (warden revert 0 of 52 merges: all rebase merges, 3 failed verifications "cannot auto-revert"; reopen 10.4 %; regression 10.4 %, 5 of 48 evaluable fixes), `evidence/kpi/dora.out.md` (CFR 2.0 % attributed, recovery median 0.27 h; 1418 deploys in 90 d, mostly Actions-on-push), `evidence/signals/signals.md` (19 of 36 vps services without a Kuma monitor or push), `evidence/incidents/incidents.md` #2–#4 (the observer was wrong, not the service), `evidence/interventions/interventions.md` (4 of 20 genuine), `research/2026-10-21-dark-factory-landscape.md` §3 (agent review is a signal, deterministic checks gate), `research/2026-10-22-agents-durable-mcp-otel.md` §3 (StrongDM holdouts)

## Context and problem statement

The owner decides business questions only and wants ≤ 0.1 % of items to reach him. Self-approval
is principled only if the evidence that authorises a ship is named per kind of action, rollback is
automatic, and runaway loops stop themselves — without turning any of that into an owner gate.

## Decision outcome

**A ladder per action class** (restart, config, dependency, code fix, migration, infra): the
evidence that authorises auto-ship, the automatic rollback, and blast-radius and rate limits —
table in `design/loops.md` §3. The rung that applies is the **effective autonomy** per (project,
action class), computed by `warden manifest check` from which evidence producers exist; the
manifest's `autonomy` block can only lower it. Every ladder evaluation is an event carrying the
rungs it checked and the effective autonomy it read (`change.ladder_evaluated`, p2 dat-12), so a
rebuild replays verdicts and never re-evaluates policy. Where each rule is built and gated:
`waves.md` W3–W5.

Rules that hold on every rung:
1. Deterministic evidence gates (checks, CI on the merge SHA, holdout scenarios, health and
   post-deploy verify, the incident's own condition resolving); agent review is a signal that can
   block but never approves alone.
2. **Fail closed on absent evidence** (ver-1, p2 ver-2, p2 ver-3): a rung whose evidence has no
   producer (no probe, no deployed app, no deploy record) is never passed vacuously — the Change is
   **propose-only** (opened and verified, not merged) and the gap is filed as a factory Task; it
   flips back when the producer exists. Not an owner gate: nobody approves it. A producer counts
   only after the verifier has watched it fail: a fault injected in a canary or scratch window
   turns it red, recorded as a Verification. Where a deployed app cannot exist, a substitute
   producer stands in — library: consumer-build holdouts; infra: dry run plus plan diff; tooling
   without a runtime: the test suite plus a canary run. A propose-only Change whose gap stays open
   closes after 14 days with its Task kept — never merged by the owner.
3. **`factory-self`** (ver-2, p2 ver-2): changes to the factory's own ship path, verifier, holdout
   runner, breaker and rollback, to manifest `autonomy`/rate limits/holdout locations, and any
   Change that adds, removes or weakens an evidence producer (probes, monitors, verify commands,
   rollback references) are their own action class. N-1 verification is a CI job: the previous
   release's verifier and holdout suite run against the Change; no second release stays installed
   (p2 sim-5, tradeoff below). A small watchdog outside the warden process restores warden's last
   `held` release. No Change can raise its own gate.
4. **Rollback is a Deployment operation** (ver-3, p2 ver-1): a Deployment is `verified` when its
   post-deploy checks pass and `held` when its hold (rule 8) confirms it. The rollback target is
   the last `held` Deployment, redeployed by image digest, compose revision or previous launchd
   bundle (the immutable reference each Deployment records, `design/model.md` §6). A failure at
   post-deploy verify or during a hold rolls back to that target; a hold failure is attributed
   across the Deployments since the target by redeploying their digests in order (bisect), and the
   known-bad marker (rule 11) lands only on the attributed change. The git revert follows as an
   ordinary Change. Every agent-originated push lands as one train entry, so
   every agent Change has a revertible unit. Merges stay squash or merge commits, never
   rebase-merges of several commits — today's rebase merges made automatic revert impossible
   (0 of 52).
5. **Holdout scenarios** per fleet project live outside every agent-writable checkout (a private
   repo run by the verifier against the deployed app), scored on observed behaviour. They change
   only through a Change to the holdouts repo by a verifier-role agent that sees the approved plan
   Artifact, never the product diff (ver-7). Each Verification that gates a deploy records the
   holdouts sha it ran against; holdout churn and the fail→update rate are KPIs, so a holdout
   weakened by an agent leaves a trail. Drafted holdouts run from W5; their binding date (open
   decision D4) gates only a project's switch from propose-only to auto-ship.
6. **Migrations** (ver-6): the auto rung allows only expand/contract migrations whose expand step
   keeps the previous release working, so rollback is code-only; a contract step that drops data is
   the data-loss class — an owner Decision by the fixed rule.
7. **Two independent observations before a restart** (sre-4, p2 sre-5): the restart recipe acts
   only when two observations by different mechanisms agree. A Kuma docker monitor and the
   container's own healthcheck count as one — both read the same HEALTHCHECK (incident #2); the
   second must be a functional probe or evidence of recent work. Disagreement opens
   `probe.disagrees` on the monitor — a monitoring defect filed as a Task, no restart.
8. **Hold before reuse** (ver-8, p2 ver-5): the post-deploy hold per condition type is ≥ 2 × the
   fingerprint's historical median inter-occurrence gap, and ≥ 24 h for crash, OOM and flap types.
   A recipe is promoted to automatic reuse only after its hold confirms it, and demoted
   automatically when a `regression_of` points at it. For crash, OOM and flap types a restart
   counts as resolution only if the condition stays resolved for the hold; a restart that clears
   the condition each time is not a fix.
9. **Product surfaces** (int-4, p2 int-8): a Change touching a manifest `product_surfaces[]` entry
   (public routes, store listings, pricing, holdout scenarios, removed features) is product-class
   and becomes a Decision with a reversible default (ADR-014) unless it traces to the owner — a
   ledger fact, defined in ADR-014 rule 1.
10. **Rate limits and blast radius:** one change in flight per repo (merge train), restart caps per
    service and host, one infra action per host at a time, migrations never during an open
    incident. Renovate automerge is off fleet-wide (p2 ver-4): Renovate opens PRs and the train
    merges them through the dependency rung — holdouts, the known-bad check, a train slot — so the
    breaker counts every dependency ship.
11. **Runaway breaker** (ver-4, p2 ver-5, p2 ver-7, p2 dat-9): a Condition `lineage.breaker`
    (subject = **lineage**), opened and closed on observation by a factory-self reconciler that
    folds change, rollback and budget events. Over 7 days it opens on more than 3 automatic
    changes without resolution, 2 rollbacks, or ≥ 3 restarts in the lineage (restarts count as
    automatic changes, and rule 8 gives a restart no credit until its hold passes). Open, it stops
    automatic shipping for that lineage and routes it to investigation on a stronger engine with
    full history; it shows in Argo as stuck. **It never pages the owner.** It closes only on a
    `held` fix or on the lineage's conditions resolving — never on silence. A revert writes a
    known-bad marker: a `fail` Verification on (target, artifact digest) that the ship loop checks
    before deploying, so the same version is not re-shipped. Egress-classed failures
    (`infra.egress`, ADR-009) count against the lineage budget but not as task failures.
12. **Budgets** (ver-5, cos-6, p2 cos-15, p2 dat-9, p2 sim-4): each Task and lineage carries a budget
    in attempts and engine-tagged tokens, counted per session from the harness's usage output
    (`usage.recorded`, ADR-013) — never wall clock, the owner's no-cap rule. Max % and dollars are
    display only. Counters are folded from events (worker Agents per Task, usage per session), not
    stored; the admission module (ADR-007 §3) enforces them before a spawn or resume. The ceiling
    per class is ADR-008's. Witness auto-continues and re-drives count against it with backoff;
    exhaustion opens `lineage.breaker`.
13. Owner gates are not a safety mechanism; the only owner exits are business Decisions (ADR-014).

### Tradeoff: N-1 in CI, one watchdog kept (p2 sim-5)

The simplifier proposed generic rollback plus a pinned CI job for `factory-self`, and last-known-good
restore folded into the existing heartbeat. Kept: N-1 verification as a CI job that runs the
previous release's verifier and holdout suite — no second installed release. Kept against the
proposal: a small watchdog outside the warden process that rolls warden back to its last `held`
release, because a bad warden deploy cannot be trusted to roll itself back. Given up: an
always-warm second release as verifier.

### Consequences

- Good: autonomy rises without lowering the evidence bar; every auto-ship has a queryable reason (its Verification records); a subject without evidence producers is visible as propose-only plus a Task that closes on a clock, not silently auto-shipped; the factory cannot ship its own gate, and a producer cannot be faked into one; rollback never lands on a version that has not held.
- Bad: holdouts must be written and kept honest per fleet project; squash merges lose intra-PR history (acceptable: the PR keeps it); per-runtime rollback targets must be recorded, and the target trails the head by at least one hold; every new probe needs a scratch-window failure test; the previous release's verifier and holdout suite must stay runnable in CI, and the watchdog is one process outside warden.

### Confirmation

KPIs: change failure rate (2.0 % baseline, attributed), rollback success when verification or a
hold fails (0 % → 100 %), breaker openings per month, reopen and regression rates (10.4 % each →
≤ 5 %), propose-only Changes open and their gap Tasks (none older than 14 days), `probe.disagrees`
per month, lineages with ≥ 3 restarts in 7 days, Renovate merges outside the train (→ 0), holdout
churn and fail→update rate.
Gamedays (`design/proof.md`) exercise each rung, plus: a failure that arrives during a hold rolls
back to the last `held` Deployment and puts the known-bad marker on the bisected change, not on the
target; a probe added to a scratch project that never goes red leaves its rung propose-only; a
`factory-self` Change that weakens the verifier is rejected by the N-1 CI job; a container that
OOMs every 20 h trips its lineage breaker within 7 days instead of closing clean each time.
