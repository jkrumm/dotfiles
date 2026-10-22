# Model — draft 2 (Phase 2)

Revised against Phase 1 evidence and spikes 1, 2, 6. Report section 3 is built from this file.

## 1. Twelve nouns

Rule: every noun has exactly one system of record (SoR) and exactly one writer. Everything
else that shows the noun is a projection with a named projector, rebuilt from the event log.

| # | Noun | Is | SoR | Writer | Id |
|-|-|-|-|-|-|
| 1 | **Project** | a repo or infra unit, described by its manifest | `project.yaml` in the repo (git). IuRoot: source in dotfiles-private, linked in, `.git/info/exclude`d | the owner or an agent, through a Change | `metadata.name` = repo dir name |
| 2 | **Signal** | one external observation, immutable (alert fired/recovered, deploy notice, CI result, issue, request, herdr event) | event log | ingest adapters, one per source | `sig_<ulid>` + `fingerprint` |
| 3 | **Condition** | level state "observed ≠ desired" for one `(project, type, subject)` | ledger | that project's reconciler, only | `cond_<ulid>`; unique open key `(project, type, subject)` |
| 4 | **Incident** | signals and conditions with one cause; carries root cause and fix recipe. Closed incidents with a recipe **are** the known-error store | ledger | correlator | `inc_<ulid>` + fingerprint set |
| 5 | **Task** | a unit of work with a done-definition and dependencies | ledger (ADR-001: beads' verbs, not its runtime) | planner (create), spawner (claim) | `task_<ulid>` |
| 6 | **Attempt** | one agent execution of a task inside a *hook* (worktree + branch + base sha) | ledger | spawner; status by the herdr observer | `att_<ulid>` |
| 7 | **Change** | commits proposed to or merged into a default branch (a PR, or a direct push) | git / GitHub; the ledger mirrors refs | ship loop (merge train) | `chg_<repo>_<pr|sha>` |
| 8 | **Deployment** | a version running on a target | ledger | deployer (`make deploy` wrapper; Watchtower/RollHook adapters) | `dep_<ulid>` |
| 9 | **Verification** | one piece of evidence about a subject: check, review, holdout, health, canary, post-deploy | ledger | the verifier that ran it | `ver_<ulid>` |
| 10 | **Artifact** | a reviewable document version (plan, report) and its comment threads | review store (ADR-005); content stays in git as `path@sha` | submitter; comments by reviewers | `art_<ulid>` |
| 11 | **Agent** | a running or resumable agent session with role, engine and project | ledger: `spec` by the spawner, `status` by the herdr observer | spawner / observer | `agt_<ulid>`; herdr pane + session id are observed attributes |
| 12 | **Decision** | a question with options, a default, an expiry, a decider and an outcome | ledger | decide step; outcome by the decider (policy, agent, owner, timeout) | `dec_<ulid>` |

Not nouns, on purpose: *job* (a gateway call is a tool use inside an Attempt or a
Verification), *wave* and *plan* (an Artifact whose tasks are Tasks), *notification* and
*briefing* (projections of the log), *known error* (a closed Incident with a recipe),
*policy* (manifest and policy files), *host/container/service* (manifest topology),
*owner todo* (TickTick is its own SoR, read-only to the factory).

## 2. Statecharts

```
Condition   (none) ─observe(bad)→ open{firing ⇄ suppressed} ─observe(ok) ≥ hold→ resolved
            resolved ─observe(bad) within reopen window→ open (same id, flaps++)
            closes only on an observation, never on a click

Incident    candidate ─promote rule→ open{triaging → mitigating → verifying; awaiting_decision}
            candidate ─no promotion in window→ dismissed (kept, scored as noise)
            open ─members resolved ∧ verification pass→ resolved ─hold→ closed
            closed ∧ recipe → known error; same fingerprint after the fixing change deployed
            → new incident with regression_of = <closed id>

Task        open ─deps done→ ready ─claim(lease)→ claimed ─attempt running→ in_progress
            in_progress ─change merged ∧ verified→ done
            in_progress ─attempt failed→ ready (next attempt, stronger engine) | blocked
            blocked ─decision→ ready | cancelled;  any ─superseded→ cancelled

Attempt     spawning ─brief delivered→ running ─result contract→ finished{change|no_change|blocked}
            running ─heartbeat lost→ stalled ─resume→ running | abandoned (task → ready)
            spawning ─no ack→ failed_to_start

Change      branch → proposed → checking → reviewing → queued → merged → (reverted)
            checking|reviewing ─fail→ revising (next attempt on the same branch)
            any before merged ─superseded→ closed

Deployment  pending → deploying → deployed → verifying → verified
            verifying ─fail→ rolling_back → rolled_back;  deploying ─fail→ failed

Verification  pending → running → pass | fail | error   (error = infra, retried; fail = evidence)

Decision    open{options, default, expiry} ─decider→ decided → applied
            open ─expiry→ defaulted (reversible default taken; else re-push once and hold)
            open ─moot→ withdrawn

Agent       spawning → working ⇄ idle ⇄ blocked → done → reaped
            working ─context ≥ rotation mark→ handing_over → (successor running) → reaped
            any ─pane gone→ dead → resumed | reaped

Artifact    submitted → in_review → resolved | superseded (new version) | expired (default: proceed)

Project     experimental → production → deprecated → archived;  class: fleet | session
```

## 3. Invariants (each one a CI check or a ledger constraint)

1. One writer per entity table: write functions live in one module per noun; a CI check
   rejects writes from anywhere else.
2. Every state change emits its event in the same transaction (transactional outbox).
3. Conditions close only on an observation.
4. An Incident closes only after a `pass` Verification linked to it.
5. A Decision with decider `owner` exists only for product direction, spend, irreversible
   data loss or other people, and always has a default and an expiry.
6. An Attempt has a hook before it runs; one active Attempt per Task; one writer per checkout.
7. A Change merges only when its action class's verification ladder is satisfied.
8. Every projection can be rebuilt from the event log plus the manifests.

## 4. One event log

```
events(
  id          TEXT PRIMARY KEY,   -- evt_<ulid>
  ts          TEXT NOT NULL,      -- RFC 3339 UTC, ms
  type        TEXT NOT NULL,      -- <noun>.<past-tense verb>: condition.opened, incident.promoted,
                                  --   task.claimed, attempt.stalled, change.merged, decision.defaulted …
  entity      TEXT NOT NULL,      -- id of the entity that changed
  project     TEXT,               -- manifest name
  actor       TEXT NOT NULL,      -- loop:<name> | agent:<id> | owner | source:<adapter>
  trace_id    TEXT, span_id TEXT, -- W3C; trace_id = sha256("<noun>:" + root id)[:32] (ADR-006)
  causation   TEXT,               -- event that caused this one
  correlation TEXT,               -- root incident or task id
  idem        TEXT UNIQUE,        -- idempotency key of a side effect
  data        TEXT NOT NULL,      -- JSON, schema per type
  v           INTEGER NOT NULL DEFAULT 1
)
```

Signals are `signal.received` events; the Signal table is a view. Argo's read models,
briefings, KPIs and every projection consume the log by cursor.

## 5. Warden's 65-column row, decomposed

| Columns today | Becomes |
|-|-|
| `event_id`, `signature`, `occurrences`, `first_seen`, `last_seen`, `occurrence_mark`, `duplicate_of`, `root_cause`, `fixed_by_pr`, `close_reason` | **Incident** (id, fingerprint set, members, root cause, resolution) — counts derive from the log |
| `origin`, `origin_channel`, `origin_thread_ts` | **Signal** source reference |
| `repo`, `max_tier` | **Project** (manifest: autonomy per action class) |
| `verb`, `triage_job`, `triage_job_at` | **Decision** (decider `agent`: attach / new / fixed_by / ignore) |
| `state` | split across Incident, Task, Attempt, Change, Deployment |
| `brief`, `revision_count`, `stalled_rounds` | **Task** (brief, attempts, convergence) |
| `dispatch_job`, `implement_job`, `liveness_deadline`, `strikes`, `retry_at`, `failure_class`, `redrive_json`, `redrives` | **Attempt** (job, lease, retry timer, failure class) |
| `pr_url`, `artifact_url`, `train_stage`, `train_sha`, `train_job`, `reviewed_sha`, `train_evidence`, `train_rewinds`, `train_pushed_at`, `train_base_sha`, `merged_sha`, `merge_method`, `blocked_sha`, `revert_pr` | **Change** (merge-train state) |
| `deploy_expect_json`, `reverting_sha`, `revert_json` | **Deployment** (expectation, rollback) |
| `validation_job`, `verify_started_at`, `verify_mark`, `verify_failures`, `verify_result`, `verify_baseline`, `ci_rerun_sha` | **Verification** records |
| `sweep_pr`, `sweep_job`, `sweep_job_at`, `sweep_attempts`, `sweep_candidates` | gone: the fixed-by sweep becomes level-triggered — a condition resolves when its reconciler observes it healthy after a deploy |
| `card_channel`, `card_ts`, `card_hash`, `note`, `created_at`, `updated_at` | projector state (notifications) and the event log |

## 6. Project manifest

`project.yaml` at the repo root. Envelope: Backstage `Component` (name, type, lifecycle,
owner, `github.com/project-slug`); SLOs in OpenSLO terms, only where one exists.

```yaml
apiVersion: factory/v1
kind: Project
metadata:
  name: weatherorb                     # = repo dir = project id everywhere
  title: WeatherOrb
  annotations: {github.com/project-slug: jkrumm/weatherorb}
  links: [{title: app, url: <app-url>}, {title: store, url: <store-url>}]
spec:
  type: service                        # service | website | library | infra | tool | knowledge
  lifecycle: production                # experimental | production | deprecated
  owner: jkrumm
  class: fleet                         # fleet: mother → lead → workers; session: plain agents
  runtime:
    - {target: vps, kind: compose, services: [weatherorb-api, weatherorb-web], deploy: ci}
  health:
    probes: [{kuma: "WeatherOrb API"}, {http: <health-url>, expect: 200}]
    slo: [{name: availability, sli: {kuma: "WeatherOrb API"}, objective: 0.995, window: 28d}]
  maintenance:
    deps: {renovate: true, automerge: [patch, minor], minimumReleaseAge: 14d}
    docs: {maxAgeDays: 30}
    analyze: weekly
    holdouts: <outside the repo>        # read by the verifier, never by implementers
  autonomy: {restart: auto, config: auto, dependency: auto, code_fix: auto, migration: auto, infra: auto}
  integrations:
    beads: {prefix: wo}
    ticktick: {list: WeatherOrb}
    brain: {note: Projects/WeatherOrb.md}
    herdr: {workspace: weatherorb, group: APPS}
    otel: {services: [weatherorb-api, weatherorb-web]}
    kuma: {monitors: ["WeatherOrb API", "WeatherOrb Web"]}
    usage: {project: weatherorb}
    changelog: {target: brain}
```

### 6.1 The directory contract

Every repo has the same structure, so repo-specific things have one fixed home. The drift check
(`factory manifest check`) enforces it.

| Path | Holds | SourceRoot | IuRoot |
|-|-|-|-|
| `project.yaml` | identity, class, runtime, health, maintenance, autonomy, integrations | committed | linked from `dotfiles-private/projects/<repo>/`, excluded |
| `docs/waves/PLAN.md`, `docs/waves/archive/` | the active plan in wave format; closed plans | committed | linked, excluded |
| `docs/adr/NNNN-title.md` | architecture decisions (MADR) | committed | linked, excluded |
| `docs/artifacts/<slug>/` | artifact versions (`v1.md`, `v2.html`) and `threads.jsonl` — written by the `rv` service (ADR-005) | committed | linked, excluded |
| `docs/notes/` | repo-specific notes for agents and the owner | committed | linked, excluded |
| `CHANGELOG.md` | only when `changelog.target` includes `repo` (libraries with release notes); otherwise the changelog lives in the brain note | committed, generated | — |
| `.factory/` | attempt hooks (`.factory/attempt.md` inside attempt worktrees), caches | ignored | ignored |
| holdouts | **never in the repo**: `maintenance.holdouts` names the private location the verifier reads | — | — |

IuRoot: the sources of every row marked *linked* live in `dotfiles-private/projects/<repo>/`; the
work repo gets symlinks listed in `.git/info/exclude`, so nothing tracked changes there. Drift
check: required paths exist (`project.yaml`; `docs/waves/` when the project has plans), forbidden
ones do not (holdouts, hand edits inside generated files), `.factory/` is ignored, IuRoot links
resolve and are excluded.

Generated from the manifests, never hand-edited: the AGENTS.md routing block (between
markers), herdr `groups.json`, Argo's project registry, reconciler policies, OTel resource
attributes (`project.name`), usage-tracker's project map, the Beads/TickTick/brain
projection headers. Drift check (`factory manifest check`, in CI and `make doctor`): schema
valid; every integration key resolves (Kuma monitor, herdr workspace, brain note, OTel
service seen in the last 7 days); generated files in sync.

## 7. Repo mapping

Classified by a rule fixed before the data was read (`evidence/projects/classify.py`): **fleet ⇔
≥ 10 planned units closed in 90 days (done waves, or fleet-phase merges) and ≥ 25 commits/week.**
Incident load is shown, not decisive — incidents reach warden for every class.

| Project | Class | Commits 90 d | Planned units 90 d | Items 30 d |
|-|-|-|-|-|
| basalt-ui | fleet | 1,884 | 49 | 0 |
| argo | fleet | 1,140 | 53 | 1 |
| weatherorb | fleet | 984 | 63 | 96 |
| shutterflow | fleet | 818 | 286 (fleet/ handoff phases) | 1 |
| dotfiles | fleet | 558 | 45 | 15 |
| warden | fleet | 528 | 12 | 55 |
| brain, hermes-agent, research-gateway, agent-gateway, vps, homelab, … (27 more) | session | 2–493 | 0–17 | 0–33 |
| IuRoot repos (20, names only) | session | ≤ 140 | ≤ 8 | — |

The owner's guess named prometheus-scripts as a fleet candidate; the rule says session (92 commits
in 90 days, no waves). hermes-agent has incident load (33 items in 30 days) but little planned work:
session, with warden handling its incidents.
