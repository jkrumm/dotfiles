# Loops

Numbers from `evidence/`; correlation parameters from the backtest (`evidence/golden/backtest.out.md`).
Report section 4 is built from this file. Each fact has one home and is linked from everywhere else:
nouns, Condition keys, statecharts and invariants in `model.md`; the durable primitives in ADR-002; the
correlation decision and its evidence in ADR-003; roles and the spawner in ADR-007; the quota guard in
ADR-008; the ladder rules in ADR-012; the intake in ADR-013. This file says what each loop does with them.

## 0. The shape in one picture

{{asset:architecture}}


```
 primary sources ──ingest──► Signal ──schedules──► RECONCILE(project) ──► Condition open/close
 (Kuma, Docker, HyperDX,                               ▲ desired = manifest      │
  GitHub, deploys, logs,                               │ observed = probes       ▼
  herdr)                                          resync timer            CORRELATE ──► Incident
                                                                          (fingerprint ·      │ known error? recipe
                                                                           topology · window) ▼
                     improve / heal jobs, owner & Hermes requests ─────► PLAN ──► Task (+ Decision, business only)
                                                                                    │ ready queue
                                                                                    ▼
                                             ADMIT + SPAWN (rd, one spawner) ──► worker Agent in its hook (herdr)
                                                                                    │ Change
                                                                                    ▼
                                         VERIFY ladder per action class ──► merge train ──► Deployment ──► verify
                                                                                    │ pass: conditions resolve → incident closes
                                                                                    │ fail: rollback to the last held Deployment → next worker
```

Every arrow writes an event, and every decision on an arrow is itself an event carrying its outcome
and reason (`model.md` §3, invariant 8; the correlator's are in §2). Every box is a loop with one
owner, idempotent, restartable from the ledger alone.

## 1. Reconcile — desired vs observed, level-triggered

A reconciler is a pure function `reconcile(project, observed) → condition updates`, run
per project on a resync timer and whenever a Signal for that project arrives. Signals never
open work directly; they only schedule a reconcile (Kubernetes' controller pattern).
Running it twice gives the same result; it holds no memory between runs.

- **Desired state** = the manifest runtime minus in-flight Deployments and declared maintenance.
  A deploy path (`make deploy`, RollHook, WUD) announces itself with a `started` Signal before it
  stops anything; the deploy reconciler (the only Deployment writer, `model.md` §1) turns `started`,
  `deployed` and `failed` into Deployment transitions, so the in-flight window the health reconciler
  subtracts is derived, not declared, and a deploy draining replicas or a deliberate stop is not a
  fault. A container replaced with no `started` Signal is an unplanned Deployment, recorded from
  Docker events — not a fault to restart. The health reconciler reads container-level state
  (`docker ps` / inspect) on every resync; Docker events only wake it. Restarts call
  `spec.commands.restart`.
- **`availability: intermittent`** runtime targets (the MacBook): output-age conditions replace
  liveness heartbeats (a vault backup older than its policy opens `infra.backup`); no investigation
  runs while the host is known asleep (#5, a 4.5-day missing heartbeat, `evidence/incidents/incidents.md`).
- **Kuma group monitors are topology parents.** Their state derives from their children (22 of the
  120 monitors; two parents sat red for 59.2 h as derived state, `evidence/incidents/incidents.md` #4),
  so they never open a Condition of their own and never hold a recipe; the drift check
  (`warden manifest check`) maps each group to its children.
- **Log-sourced Conditions resolve by quiet.** A log fingerprint has no Up: a `health.degraded`
  Condition opened by a log alert rule resolves when no new occurrence arrives for its type's hold
  (ADR-012 §8). Log lines that trip no rule stay Signals without a Condition (§2.5).

| Observer | Desired (manifest) | Condition types |
|-|-|-|
| health | `health.probes`, Kuma monitors, containers/launchd jobs in `runtime`; no log alert rule firing for the project's services (ADR-013) | `health.down`, `health.degraded`, `slo.burn` |
| deploy | default-branch head deployed within N min of merge | `deploy.behind`, `deploy.failed` |
| CI | default branch green | `ci.red` |
| deps | `maintenance.deps` policy | `deps.stale`, `deps.vulnerable` |
| docs | generated blocks in sync, age ≤ `maxAgeDays`, no contradiction lint hit | `docs.drift`, `docs.stale` |
| agents | no agent stuck or finished-but-open | `agent.stuck`, `agent.finished_open` |
| infra (host projects) | disk floor, certs, backups age, container restarts, DB/ClickHouse health, mounts and attached devices present ("device absent" arrives from the HomeLab WatchDog, ADR-013), factory-host egress | `infra.disk`, `infra.cert`, `infra.backup`, `infra.restart_loop`, `infra.mount`, `infra.egress` …, `auth.expired` (7 days ahead) |
| security | CrowdSec decisions, auth anomalies | `security.anomaly` |
| lineage (`factory-self`) | automatic changes, rollbacks, restarts and budget inside the breaker's limits (ADR-012 §11) | `lineage.breaker` |

**The 2026-10-17 outage under this loop.** A clean VPS kernel-update reboot (shutdown 20:49:07, boot
20:56:42) took eighteen monitors down for 7.9 min. Today: the Slack relay delivered the Kuma Downs
22–30 min late, briefs anchored on the poll time ("since 21:22"), and warden sent 18 owner pages,
while the webhook copies of the same alerts auto-quieted (`evidence/incidents/incidents.md` #6).
Under the reconcile loop, in event order:

1. Kuma webhooks carry source time — first Down 20:52:02, eighteen monitors Down by 20:56:37 — so
   `health.down` Conditions open on the vps-hosted projects. No host-level evidence exists yet, so
   each child is a service/project incident.
2. Every child restart recipe stays held: the host fails its direct reachability check (§3), so no
   restart is planned at an unreachable host.
3. The boot record (20:56:42) arrives; a logged `merge` folds the open child incidents under the host
   incident, whose open condition holds child recipes for the host's hold window.
4. Every monitor reports Up by 20:59:54; each member's Condition resolves on observation; the incident
   closes with no action taken.

Owner pages: 0. Recorded: one incident with its timeline, its `merge` and the held recipes.

{{asset:outage-1017}}


## 2. Correlate — one cause, one incident

1. **Fingerprint** = a default per source (source + monitor/check id + normalised message)
   with per-source refinements written as `{{default}} + field` rules (Sentry's model): a
   rule refines, never replaces.
2. **Dedup**, by source kind. *Stateful* sources, whose recovery signal closes the episode (Kuma,
   Beszel): subject state — a firing repeated while no Up was seen stays in its incident within
   `w_open`, a re-fire right after an Up rejoins within `w_reopen`, and the recovery closes the
   episode. *Stateless* sources (CI failures, log lines, issues, chat): the same refined fingerprint
   inside `w_dedup`, also while an incident is open; a later occurrence starts a new candidate. The
   Condition key includes the fingerprint class (`model.md` §1), so two causes on one subject are two
   Conditions, each a member that close-by-member and split can act on.
3. **Topology**: the manifests give `host → container/job → service → project`. Signals
   whose subjects share an ancestor inside `w_topo` fold under the ancestor's incident;
   deployments of that subtree inside the look-back window attach as suspects. A fold reaches the
   host only on host-level evidence — a boot record, a Beszel host-down, a Docker daemon event, or
   ≥ 50 % of the host's monitored subjects firing; otherwise it stops at service/project. That
   evidence usually lands after the children (a boot record exists only once the host is back), so
   when it arrives a logged, reversible **`merge`** folds the open child incidents under the host
   incident. Kuma group monitors are parents in this tree, never subjects (§1).
4. **Parameters** (table below): v1's values, frozen on the golden set's development half
   (`backtest.out.md` §3); v2 changes the two bold rows and links the families that have no condition
   type only through explicit edges (step 5). A window is never the only key (a pure time window
   merges unrelated incidents — research `ops-correlation` §5). The held-out numbers describe v1
   only (ADR-003).

| Parameter | Value | Acts on | v2 |
|-|-|-|-|
| `w_topo` | 45 min | topology fold | unchanged |
| `w_open` | 360 min | stateful: firing repeated with no Up seen | unchanged |
| `w_reopen` | 10 min | stateful: re-fire after an Up (flap) | unchanged |
| `w_rec` | 7 d | stateful: look-back that pairs an Up with its Down | unchanged |
| `w_dedup` | v1: 720 min | stateless: same refined fingerprint | **bounded in every case**; value from the development re-score (ADR-003) |
| host fold | v1: two distinct infrastructure subjects inside `w_topo` (`k_host` 2) | host-level ancestors | **host-level evidence, plus `merge`** (step 3) |
| `w_chat` | 30 min | consecutive chat messages | value unchanged |
| `th_sim` / `w_sim` | 0.2 / 240 min | ticket and brief titles | values unchanged |
| gate `T` / `N` | 30 min / 1 | candidate gate (step 7) | unchanged |
| known-error θ | 0.9 | token-similarity fallback after an exact fingerprint miss | unchanged |

5. **Close by member**: an incident closes only when every member's own Condition has resolved.
   **Split**: when every other member has resolved and one is still open after its type's hold, it
   splits into a new incident and its timeline carries over. Members with no condition type — chat,
   requests, issues, log lines below an alert rule — have no Condition to hold an incident open, so
   they join an incident only by an explicit, reversible edge (the investigator's, a known-error
   match or a shared deploy suspect).
6. **Act per incident**: while a topology ancestor has an open host condition (boot, mount,
   reachability), child recipes are held for the host's hold window, and they stay held until the
   host answers a direct reachability check and its mounts are present; the host runbook runs first.
7. **Candidate gate** (Keep's promotion): a candidate becomes an incident when it persists
   ≥ `T`, or reaches `N` signals, or matches a known error, or its severity is critical;
   otherwise it expires as noise, recorded and scored.
8. **Known errors**: a closed incident with a recipe (root cause, fixing change, action
   class, verification evidence); the fixing Change is attached at closure, never inferred from
   notes. Every new incident is matched against them on a fingerprint normalised across sources
   through the topology subject, so a Kuma monitor, its relay and a HyperDX alert share priors
   (ADR-003): exact fingerprint on a promoted recipe → reuse it within its action class's ladder;
   similar, or a recipe not yet promoted → the recipe goes into the investigator's brief. A recipe
   is promoted to automatic reuse only after its post-deploy hold confirms it (ADR-012 §8). The
   judgment calls — root cause, recipe choice, `decision_class` — belong to the investigate worker
   on OpenCode/IU; no single-shot decision model sits anywhere in this loop (ADR-003).
9. **Regression**: a fingerprint recurring after its fixing change was deployed opens a new
   incident with `regression_of`, and the fixing change is the first suspect; a promoted recipe
   that regresses is demoted (ADR-012 §8).

Every grouping decision is an event that names its rule: `incident.member_added{rule, ancestor}`,
`incident.split`, `incident.merged`.

## 3. Verify — the ladder that makes self-approval principled

Agent review is a signal; deterministic evidence is the gate (research `dark-factory` §3).
No rung is an owner gate. The rules that hold on every rung — propose-only and its substitute
producers, `factory-self`, rollback, holdouts, the two-observation restart rule, hold before reuse,
the breaker, budgets — are ADR-012's; this table is the per-class matrix they apply to. The
factory's own services (agent-gateway, Hermes, warden) get verified evidence producers first, in W3b
(`waves.md`), so their fixes ride the ladder instead of sitting propose-only.

| Action class | Evidence that authorises auto-ship | Automatic rollback | Blast radius and rate |
|-|-|-|-|
| restart | condition open; two observations by different mechanisms agree (ADR-012 §7) — disagreement opens `probe.disagrees` on the monitor, filed as a Task, no restart; the host answers a direct reachability check, its mounts are present and no host condition is open on an ancestor; recipe or investigate names a restart; post: health green within 5 min and the condition resolves (crash, OOM and flap types: only after the hold, ADR-012 §8) | none needed; 2 failed restarts → escalate to code fix / infra | ≤ 2 per service per hour, ≤ 5 per host per hour |
| config | `make check`; tool validation (compose config, caddy validate, plutil); review without blocking findings; post-deploy `make verify` + health | redeploy the last `held` Deployment (compose revision or config bundle) | one config change in flight per service |
| dependency | CI green; release age ≥ 14 d; not 0.x; no known-bad `fail` Verification on the artifact; holdouts pass (fleet); post-deploy verify — Renovate only opens the PR, the train merges it through this rung | redeploy the last `held` Deployment (image digest) | Renovate grouping; one per repo per run |
| code fix | `make check` + CI green on the merge SHA; review without blocking findings; holdouts pass (fleet); post-deploy verify; the incident's own condition stays resolved through its post-deploy hold (ADR-012 §8) | redeploy the last `held` Deployment | one change in flight per repo; ≤ 6 automatic merges per repo per day |
| migration | expand/contract only (ADR-012 §6); backup taken and test-restored; dry run on a copy; checks green | code-only: redeploy the last `held` Deployment | one per project per day; never during an open incident on that project |
| infra | runbook from the known-error store with dry-run output; pre/post health | per runbook | one infra action per host at a time |

Rollback is a Deployment operation to the last `held` Deployment, with bisect attribution and the
known-bad marker (ADR-012 §4; the states are `model.md` §2). The runaway breaker — the Condition
`lineage.breaker`, folded by a `factory-self` reconciler (limits, counting and close rule: ADR-012
§11) — and the per-action limits in the last column gate shipping; spawning is gated by the
admission module (§5).

## 4. Durable execution

**The ledger with explicit statecharts, no engine** (ADR-002, spike 2). Constraints it meets: an
OpenCode restart kills its episodes; herdr crashes; the mini reboots (power events). The primitives
— the effect registry, generation keys, epochs, timers, leases, decisions with deadlines — are
specified once, in ADR-002. What the loops rely on: every loop is a pure function of the ledger plus
fresh observations, so crash recovery is "run the reconcilers again"; every external side effect goes
through the registry; timers and leases are ledger rows, not process memory.

## 5. Agents

The roles (mother, lead, worker, session, Hermes), the one spawner `rd`, the admission module,
Witness (the agent reconciler, `agents` in §1), the hook, rotation and the Gas Town decisions are
ADR-007; the engine-by-class table and the quota guard are ADR-008; budgets are ADR-012 §12; the
Agent noun and its statechart are `model.md` §1–2. Two loop-level facts:

- **One module admits.** The admission module in warden (`warden admit`, called by `rd`, ADR-007) is the only place that can refuse,
  defer or re-engine a spawn or a resume, and it records each verdict as an event with its inputs.
  The breaker and the per-action limits of §3 gate shipping, not spawning.
- **Parked agents resume by themselves.** Witness resumes a parked agent through the admission
  module and re-drives a stuck or dead one from its hook; the owner never types `continue`.

## 6. Improve and heal — the same path

Recurring jobs are reconcilers on schedules; their Conditions flow through correlate → plan →
spawn → verify like any outage.

| Job | Mechanism | Condition |
|-|-|-|
| dependencies | Renovate opens the PRs (release age ≥ 14 d; automerge is off fleet-wide); the train merges them through the dependency rung (§3); the reconciler watches Renovate's failures and majors | `deps.*` |
| docs drift | generated blocks + doc-contradiction lint + age | `docs.*` |
| code health | `/analyze` weekly: oversized files, duplication, dead code over thresholds | `code.health` (batched) |
| Claude Code setup | CLAUDE.md/AGENTS.md size, skill count, resident tool-definition tokens | `setup.bloat` |
| basalt-ui dogfooding | components duplicated in consumers | `ui.upstream` |
| performance, OTel | p95/error-rate regressions per service vs baseline | `perf.regression` |
| bugs | weekly correctness sweep: `/code-review` over each repo's merged diffs since the last sweep, plus new OTel error clusters per service | `code.bug` |
| GitHub issues | open issues on owned repos | Signals → Tasks |
| infra | disk, certs, backups, mounts and devices, containers, databases, ClickHouse per host | `infra.*` with runbooks |
| factory-host egress | a network-independent runbook and the heartbeat's egress probe (ADR-009); gameday row 15 (resolver blackhole) | `infra.egress` (#1: a 7-hour outbound outage, `evidence/incidents/incidents.md`) |
| attacks, anomalies | CrowdSec on the public hosts; auth/log anomalies | `security.anomaly` |

## 7. Quota and cost are control inputs

ADR-008 is the only statement of the quota guard, the engine-by-class table, the owner's in-cycle
projection, the admission order and the numbers behind them. `quota.sampled` and
`usage.recorded` arrive as events (ADR-013), so the admission module (§5) replays from the log and
never from usage.db or the herdr socket.
