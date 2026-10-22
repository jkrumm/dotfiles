# Loops — draft 1 (Phase 3)

Status: structure written before Phase 1 returned; every `⟨n⟩` is filled from `evidence/`
in draft 2. Report section 4 is built from this file.

## 0. The shape in one picture

```
 primary sources ──ingest──► Signal ──schedules──► RECONCILE(project) ──► Condition open/close
 (Kuma, Docker, HyperDX,                               ▲ desired = manifest      │
  GitHub, deploys, herdr,                              │ observed = probes       ▼
  owner/Hermes requests)                          resync timer            CORRELATE ──► Incident
                                                                          (fingerprint ·      │ known error? recipe
                                                                           topology · window) ▼
                     improve / heal jobs = more reconcilers ───────────► PLAN ──► Task (+ Decision, business only)
                                                                                    │ ready queue
                                                                                    ▼
                                                     SPAWN (rd, one spawner) ──► Attempt in a hook (herdr worker)
                                                                                    │ Change
                                                                                    ▼
                                         VERIFY ladder per action class ──► merge train ──► Deployment ──► verify
                                                                                    │ pass: conditions resolve → incident closes
                                                                                    │ fail: automatic rollback → next attempt
```

Every arrow writes an event. Every box is a loop with one owner, idempotent, restartable
from the ledger alone.

## 1. Reconcile — desired vs observed, level-triggered

A reconciler is a pure function `reconcile(project, observed) → condition updates`, run
per project on a resync timer and whenever a Signal for that project arrives. Signals never
open work directly; they only schedule a reconcile (Kubernetes' controller pattern).
Running it twice gives the same result; it holds no memory between runs.

| Observer | Desired (manifest) | Condition types |
|-|-|-|
| health | `health.probes`, Kuma monitors, containers/launchd jobs in `runtime` | `health.down`, `health.degraded`, `slo.burn` |
| deploy | default-branch head deployed within N min of merge | `deploy.behind`, `deploy.failed` |
| CI | default branch green | `ci.red` |
| deps | `maintenance.deps` policy | `deps.stale`, `deps.vulnerable` |
| docs | generated blocks in sync, age ≤ `maxAgeDays`, no contradiction lint hit | `docs.drift`, `docs.stale` |
| agents | no agent stuck or finished-but-open | `agent.stuck`, `agent.finished_open` |
| infra (host projects) | disk floor, certs, backups age, container restarts, DB/ClickHouse health | `infra.disk`, `infra.cert`, `infra.backup`, `infra.restart_loop` … |
| security | CrowdSec decisions, auth anomalies | `security.anomaly` |

The 2026-10-17 outage under this loop: ⟨reconstruction from `evidence/incidents/`⟩.

## 2. Correlate — one cause, one incident

1. **Fingerprint** = a default per source (source + monitor/check id + normalised message)
   with per-source refinements written as `{{default}} + field` rules (Sentry's model): a
   rule refines, never replaces.
2. **Dedup**: same fingerprint while its condition or incident is open → an occurrence.
3. **Topology**: the manifests give `host → container/job → service → project`. Signals
   whose subjects share an ancestor inside the window fold under the ancestor's incident;
   deployments of that subtree inside the look-back window attach as suspects.
4. **Time window**: ⟨window from the golden-set dev split⟩, never the only key (a pure
   time window merges unrelated incidents — research `ops-correlation` §5).
5. **Candidate gate** (Keep's promotion): a candidate becomes an incident when it persists
   ≥ T, or reaches N signals, or matches a known error, or its severity is critical;
   otherwise it expires as noise, recorded and scored.
6. **Known errors**: a closed incident with a recipe (root cause, fixing change, action
   class, verification evidence). Every new incident is matched against them: exact
   fingerprint → reuse the recipe within its action class's ladder; similar → the recipe
   goes into the investigator's brief.
7. **Regression**: a fingerprint recurring after its fixing change was deployed opens a new
   incident with `regression_of`, and the fixing change is the first suspect.

## 3. Verify — the ladder that makes self-approval principled

Agent review is a signal; deterministic evidence is the gate (research `dark-factory` §3).
No rung is an owner gate.

| Action class | Evidence that authorises auto-ship | Automatic rollback | Blast radius and rate |
|-|-|-|-|
| restart | condition open; recipe or investigate names a restart; post: health green within 5 min and the condition resolves | none needed; 2 failed restarts → escalate to code fix / infra | ≤ 2 per service per hour, ≤ 5 per host per hour |
| config | `make check`; tool validation (compose config, caddy validate, plutil); review without blocking findings; post-deploy `make verify` + health | revert commit + redeploy | one config change in flight per service |
| dependency | CI green; release age ≥ 14 d; not 0.x for automerge; holdouts pass (fleet); post-deploy verify | revert PR | Renovate grouping; one per repo per run |
| code fix | `make check` + CI green on the merge SHA; review without blocking findings; holdouts pass (fleet); post-deploy verify; the incident's own condition resolves in its window | revert through the merge train | one change in flight per repo; ≤ ⟨n⟩ merges per repo per day |
| migration | backup taken and test-restored; dry run on a copy; down-migration or written forward fix; checks green | restore / down-migration | one per project per day; never during an open incident on that project |
| infra | runbook from the known-error store with dry-run output; pre/post health | per runbook | one infra action per host at a time |

**Runaway breaker.** Per project and action class: > 3 automatic changes for one incident in
24 h without resolution, or ≥ 2 rollbacks in 24 h, opens the breaker — automatic shipping
stops for that scope, the incident goes to a stronger engine with the full history, Argo
shows it as stuck. The breaker never pages the owner; it closes on a verified fix or 24 h
quiet.

## 4. Durable execution

⟨ADR-002 after spike 2⟩. Constraints the answer must meet: an OpenCode restart kills its
episodes; herdr crashes; the mini reboots (power events). Requirements: idempotency keys on
every side effect (PR per attempt, deploy per change+target, restart per condition+window),
leases with heartbeats for attempts and merge-train slots, durable timers (retry, expiry,
hold windows), await-decision with default-on-timeout, and crash recovery that is "run the
reconcilers again".

## 5. Agents

- **Roles.** *Mother* — one per fleet project, lean: turns the project's new Conditions,
  requests and plan items into Tasks and keeps its ready queue honest; never edits code.
  *Lead* — one per active plan or epic: sequences tasks, spawns workers, handles rebases and
  merge-train returns. *Worker* — one per Attempt: implements, verifies, hands back a Change.
  *Session* — a plain agent for session-class projects and ad-hoc work. *Hermes* — the
  conversational door: answers from read models, files Tasks, asks the spawner for sessions;
  never edits code.
- **One spawner.** `rd` is the only code path that creates an agent: it writes the Agent and
  Attempt records, cuts the hook, delivers the brief, sets tab metadata.
- **The hook owns the work** (Gas Town): worktree + branch + base sha + task notes. A dead or
  rotated agent's successor resumes from the hook, not from a re-prompt.
- **Lifecycle.** spawn → work → done → reap (janitor). Rotation at the context mark: the
  agent writes its handover into the hook; the spawner starts the successor; the old one is
  reaped. Mothers rotate daily.
- **Gas Town, explicitly.** Copy: the hook, Witness (the agent reconciler: stuck, zombie,
  finished-but-open), Refinery (the merge train that already exists), Deacon (reconcilers on
  patrol — as code). Reject: a global Mayor LLM (scheduling is code), idle LLM patrols
  (cost), convoys (Task dependencies suffice), tmux (herdr).

## 6. Improve and heal — the same path

Recurring jobs are reconcilers on schedules; their Conditions flow through correlate → plan →
spawn → verify like any outage.

| Job | Mechanism | Condition |
|-|-|-|
| dependencies | Renovate does the mechanical part (patch/minor automerge behind CI, 14 d age); the reconciler watches Renovate's failures and majors | `deps.*` |
| docs drift | generated blocks + doc-contradiction lint + age | `docs.*` |
| code health | `/analyze` weekly: oversized files, duplication, dead code over thresholds | `code.health` (batched) |
| Claude Code setup | CLAUDE.md/AGENTS.md size, skill count, resident tool-definition tokens | `setup.bloat` |
| basalt-ui dogfooding | components duplicated in consumers | `ui.upstream` |
| performance, OTel | p95/error-rate regressions per service vs baseline | `perf.regression` |
| GitHub issues | open issues on owned repos | Signals → Tasks |
| infra | disk, certs, backups, containers, databases, ClickHouse per host | `infra.*` with runbooks |
| attacks, anomalies | CrowdSec on the public hosts; auth/log anomalies | `security.anomaly` |

## 7. Quota and cost are control inputs

⟨numbers from `evidence/kpi/quota.*` and `cost.*`⟩. The scheduler orders the ready queue by
urgency, then cost class: production incidents always run; non-urgent work runs when Max
7-day < ⟨x⟩ % and 5-hour < ⟨y⟩ %, else on the IU engine within a daily IU budget. Engine
policy (Round 5's open question): ⟨ADR-008 with numbers⟩.
