# Model — draft 2 (Phase 2)

Revised against Phase 1 evidence, spikes 1, 2, 6 and panel pass 1 (`panel/pass1-resolutions.md`). Report section 3 is built from this file.

## 1. Eleven nouns

Rule: every noun has exactly one system of record (SoR) and exactly one writer module. Everything
else that shows the noun is a projection with a named projector, rebuilt from the event log. The
Writer column lists every command source; each goes through the noun's one write module, so the
one-writer CI check tests what the table claims.

| # | Noun | Is | SoR | Writer | Id |
|-|-|-|-|-|-|
| 1 | **Project** | a repo or infra unit, described by its manifest | configuration: `project.yaml` in the repo (git; IuRoot: source in dotfiles-private, linked in, `.git/info/exclude`d). Runtime state (pause override, last reconcile, effective autonomy): the **project runtime record** in the ledger. Each attribute has exactly one SoR | manifest: the owner or an agent, through a Change. Runtime record: the pause verb (owner), the reconcilers, `factory manifest check` | `metadata.uid` (stable across renames); `metadata.name` = repo dir name, the display key |
| 2 | **Signal** | one external observation, immutable (alert fired/recovered, deploy notice, CI result, issue, request, herdr event) | event log | ingest adapters, one per source | `sig_<ulid>` + `fingerprint` |
| 3 | **Condition** | level state "observed ≠ desired" for one `(project, type, subject)` | ledger | that project's reconciler, only | `cond_<ulid>`; unique open key `(project, type, subject)` |
| 4 | **Incident** | signals and conditions with one cause; carries root cause and fix recipe. Closed incidents with a recipe **are** the known-error store | ledger | correlator | `inc_<ulid>` + fingerprint set |
| 5 | **Task** | a unit of work with a done-definition and dependencies; the ledger is its only home of state — PLAN.md checklists are generated from it (ADR-001) | ledger (ADR-001: beads' verbs, not its runtime) | `tasks` module, called by: planner, owner submit and wave close-out (create); spawner (claim); the worker Agent with its epoch (heartbeat, done); `/wave` (`warden task done`); Witness (re-drive → ready); decide step (blocked → ready, cancelled) | `task_<ulid>` |
| 6 | **Change** | commits proposed to or merged into a default branch (a PR, or a direct push) | git / GitHub; the ledger mirrors refs | ship loop (merge train) | `chg_<repo>_<pr|sha>` |
| 7 | **Deployment** | a version running on a target | ledger | the deploy reconciler, only — it consumes deployed/failed Signals from every source (`make deploy` wrapper, RollHook, CI) keyed change + target | `dep_<ulid>` |
| 8 | **Verification** | one piece of evidence about a subject: check, review, holdout, health, canary, post-deploy | ledger | the verifier that ran it | `ver_<ulid>` |
| 9 | **Artifact** | a reviewable document version (plan, report) and its comment threads | review store (ADR-005); content stays in git as `path@sha` | submitter; comments by reviewers | `art_<ulid>` |
| 10 | **Agent** | a running or resumable agent session with role, engine and project; a worker carries an optional `task_id` and its **hook** (worktree + branch + base sha + epoch). A Task's attempts are its worker Agents | ledger: `spec` by the spawner, `status` by the herdr observer, the `idle.parked{reason, resume_at}` substate by Witness only | spawner / observer / Witness, one field set each | `agt_<ulid>`; herdr pane, session id and last output (herdr record) are observed attributes |
| 11 | **Decision** | a question with options, a default, an expiry, a decider and an outcome | ledger | decide step; outcome by the decider (policy, agent, owner, timeout) | `dec_<ulid>` |

Not nouns, on purpose: *Attempt* (a worker Agent with a `task_id`), *job* (a gateway call is a
tool use inside an Agent's work or a Verification), *wave* and *plan* (an Artifact whose tasks are
Tasks), *notification* and *briefing* (projections of the log), *known error* (a closed Incident
with a recipe), *candidate* (an Incident state), *holdout scenario* (a Verification spec),
*agent message* and *artifact comment* (events on the Agent and the Artifact), *pause* (a field of
the project runtime record, never a Decision), *policy* (manifest and policy files),
*host/container/service* (manifest topology), *owner todo* (TickTick is its own SoR, read-only to
the factory).

**Plumbing, exempt from the noun count:** `events`, `operations`, `timers`, `leases`,
`deliveries` — infrastructure tables owned by the ledger module, with no lifecycle of their own
that the owner sees.

## 2. Statecharts

{{asset:statecharts}}


```
Condition   (none) ─observe(bad)→ open{firing ⇄ suppressed} ─observe(ok) ≥ hold→ resolved
            resolved ─observe(bad) within reopen window→ open (same id, flaps++)
            closes only on an observation, never on a click

Incident    candidate ─promote rule→ open{triaging → mitigating → verifying; awaiting_decision}
            candidate ─no promotion in window→ dismissed (kept, scored as noise)
            open ─members resolved ∧ verification pass→ resolved ─hold→ closed
            closed ∧ recipe → known error; same fingerprint after the fixing change deployed
            → new incident with regression_of = <closed id>

Task        open ─deps done→ ready ─claim(lease, epoch)→ claimed ─worker Agent working→ in_progress
            in_progress ─change merged ∧ verified→ done   (`warden task done`; PLAN.md regenerated)
            in_progress ─worker Agent failed | dead→ ready (next worker Agent, stronger engine,
                         new epoch) | blocked
            blocked ─decision→ ready | cancelled;  any ─superseded→ cancelled

Change      branch → proposed → checking → reviewing → queued → merged → (reverted)
            checking|reviewing ─fail→ revising (next worker Agent on the same branch)
            any before merged ─superseded→ closed

Deployment  pending → deploying → deployed → verifying → verified
            verifying ─fail→ rolling_back → rolled_back;  deploying ─fail→ failed

Verification  pending → running → pass | fail | error   (error = infra, retried; fail = evidence)

Decision    open{options, default, expiry} ─decider→ decided → applied
            open ─expiry→ defaulted (reversible default taken; else re-push once and hold)
            open ─moot→ withdrawn

Agent       spawning ─brief delivered→ working ⇄ idle ⇄ blocked → done → reaped
            spawning ─no ack→ failed_to_start
            idle.parked{reason: quota | api_error | turn_end | waiting, resume_at}
              written only by Witness; agent.parked / agent.resumed events
            done (worker) carries the result contract {change | no_change | blocked}
            working ─context ≥ rotation mark→ handing_over → (successor running) → reaped
            any ─pane gone→ dead → resumed | reaped (worker: its Task → ready)
            successor granted only after the predecessor is confirmed dead or its lease fenced

Artifact    submitted → in_review → resolved | superseded (new version) | expired (default: proceed)

Project     experimental → production → deprecated → archived;  class: fleet | session
            runtime record: automation running ⇄ paused{until} — an owner override of desired
            state, shown as one ambient term on Argo's line 1; never a card, a Decision or an
            owner touch
```

## 3. Invariants (each one a CI check or a ledger constraint)

1. One writer per entity table: write functions live in one module per noun; a CI check
   rejects writes from anywhere else.
2. Every state change emits its event in the same transaction (transactional outbox).
3. Conditions close only on an observation.
4. An Incident closes only after a `pass` Verification linked to it.
5. A Decision with decider `owner` exists only for product direction, spend, irreversible
   data loss or other people, and always has a default and an expiry. Pause is not a Decision.
6. A worker Agent has a hook before it runs; one live worker Agent per Task, fenced by its lease
   epoch (a stale epoch is rejected); one writer per checkout.
7. A Change merges only when its action class's verification ladder is satisfied.
8. Every pure read model can be rebuilt from the event log plus the manifests at each event's
   `manifest_sha`; effectors send each `(event_id, channel)` at most once, recorded in
   `deliveries` before the send, so a rebuild never re-sends.

## 4. One event log

```
events(
  id          TEXT PRIMARY KEY,   -- evt_<ulid>
  ts          TEXT NOT NULL,      -- RFC 3339 UTC, ms
  type        TEXT NOT NULL,      -- <noun>.<past-tense verb>: condition.opened, incident.promoted,
                                  --   task.claimed, agent.parked, change.merged, decision.defaulted …
  entity      TEXT NOT NULL,      -- id of the entity that changed
  project     TEXT,               -- manifest name
  actor       TEXT NOT NULL,      -- loop:<name> | agent:<id> | owner | source:<adapter>
  trace_id    TEXT, span_id TEXT, -- W3C; trace_id = sha256("<noun>:" + root id)[:32] (ADR-006)
  causation   TEXT,               -- event that caused this one
  correlation TEXT,               -- root incident or task id
  manifest_sha TEXT,              -- default-branch manifest blob read, on manifest-influenced events
  idem        TEXT UNIQUE,        -- idempotency key of a side effect
  data        TEXT NOT NULL,      -- JSON, schema per type
  v           INTEGER NOT NULL DEFAULT 1
)
```

Signals are `signal.received` events; the Signal table is a view. Agent messages and artifact
comments are events on their Agent and Artifact. Argo's read models, briefings, KPIs and every
projection consume the log by cursor. Pure read models are rebuildable; effectors (push, Argo
thread, vault write, Slack) record `deliveries(event_id, channel)` before sending. Reconcilers read
default-branch manifests only, never a working tree.

## 5. Warden's 65-column row, decomposed

| Columns today | Becomes |
|-|-|
| `event_id`, `signature`, `occurrences`, `first_seen`, `last_seen`, `occurrence_mark`, `duplicate_of`, `root_cause`, `fixed_by_pr`, `close_reason` | **Incident** (id, fingerprint set, members, root cause, resolution) — counts derive from the log |
| `origin`, `origin_channel`, `origin_thread_ts` | **Signal** source reference |
| `repo`, `max_tier` | **Project** (manifest: autonomy per action class) |
| `verb`, `triage_job`, `triage_job_at` | **Decision** (decider `agent`: attach / new / fixed_by / ignore) |
| `state` | split across Incident, Task, Agent, Change, Deployment |
| `brief`, `revision_count`, `stalled_rounds` | **Task** (brief, worker Agents as its attempts, convergence) |
| `dispatch_job`, `implement_job`, `liveness_deadline`, `strikes`, `retry_at`, `failure_class`, `redrive_json`, `redrives` | **Agent** with role worker (job, lease + epoch, retry timer, failure class) |
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
  uid: <stable id>                     # survives a rename; events and history join on it
  name: weatherorb                     # = repo dir; display key (a rename emits project.renamed)
  title: WeatherOrb
  annotations: {github.com/project-slug: jkrumm/weatherorb}
  links: [{title: app, url: <app-url>}, {title: store, url: <store-url>}]
spec:
  type: service                        # service | website | library | infra | tool | knowledge
  lifecycle: production                # experimental | production | deprecated
  owner: jkrumm
  class: fleet                         # fleet: mother → lead → workers; session: plain agents
  dependsOn: [<project ref>]           # Backstage relations; consumers derive from providesApis
  providesApis: [<api name>]
  runtime:
    - host: vps                        # an infra project ref, not a bare string
      kind: compose
      containers: [weatherorb-api, weatherorb-web]
      launchd: []                      # launchd job labels, for mini and MacBook units
      version: {http: <version-url>, jsonPath: sha}   # or {image_label: org.opencontainers.image.revision}
      availability: always             # always | intermittent (the MacBook)
      deploy: ci
  data:
    databases: [<db name>]
    backups: {target: <backup target>, maxAge: <age>}
  doors: [<public or tailnet door>]
  commands: {check: make check, verify: make verify, deploy: make deploy, restart: make restart, logs: make logs}
  health:
    probes: [{kuma: "WeatherOrb API"}, {http: <health-url>, expect: 200}]
    slo: [{name: availability, sli: {kuma: "WeatherOrb API"}, objective: 0.995, window: 28d}]   # or slo: none, explicitly
  policy: {prRequired: false}
  product_surfaces: [<public route>, <store listing>, <pricing>, <holdout scenario>, <removed feature>]
  maintenance:
    deps: {renovate: true, automerge: [patch, minor], minimumReleaseAge: 14d}
    docs: {maxAgeDays: 30}
    analyze: weekly
    holdouts: <outside the repo>        # read by the verifier, never by implementers
  autonomy: {restart: auto, config: auto, dependency: auto, code_fix: auto, migration: auto, infra: auto}
                                       # can only lower the effective autonomy warden computes
  integrations:                        # desired state; the integrations reconciler ensures each
    tasks: {prefix: wo}                # ledger task-id prefix (bd's verbs, not beads' runtime)
    ticktick: {list: WeatherOrb}       # list ensured per project; titles only, never his todos
    brain: {note: Projects/WeatherOrb.md}   # the Obsidian projection
    herdr: {workspace: weatherorb, group: APPS}
    otel: {services: [weatherorb-api, weatherorb-web]}
    kuma: {monitors: ["WeatherOrb API", "WeatherOrb Web"]}
    usage: {project: weatherorb}
    changelog: {target: brain}
```

Reconcilers and the correlator read the **default-branch** manifest only, never a working tree,
and stamp its blob sha as `manifest_sha` on every event the manifest influenced (§4). Pause, last
reconcile and effective autonomy are not manifest fields: they live in the project runtime record.

### 6.1 The directory contract

Every repo has the same structure, so repo-specific things have one fixed home. The contract
fixes **locations** and creates nothing empty: a path exists only once it holds something, and the
drift check (`warden manifest check` — `factory` folded into the one factory CLI) enforces the
location only.

| Path | Holds | SourceRoot | IuRoot |
|-|-|-|-|
| `project.yaml` | identity, class, relations, runtime, data, doors, commands, health, policy, product surfaces, maintenance, autonomy, integrations | committed | linked from `dotfiles-private/projects/<repo>/`, excluded |
| `docs/waves/PLAN.md`, `docs/waves/archive/` | the active plan in wave format, its checklist a marker block generated from the ledger (never hand-ticked); closed plans | committed | linked, excluded |
| `docs/adr/NNNN-title.md` | architecture decisions (MADR) | committed | linked, excluded |
| `docs/artifacts/<slug>/` | artifact versions (`v1.md`, `v2.html`) and `threads.jsonl` — written by the `rv` service (ADR-005) | committed | linked, excluded |
| `docs/notes/` | repo-specific notes for agents and the owner | committed | linked, excluded |
| `CHANGELOG.md` | only when `changelog.target` includes `repo` (libraries with release notes); otherwise the changelog lives in the brain note | committed, generated | — |
| `.factory/` | worker Agent hooks (`.factory/attempt.md`, carrying the lease epoch, inside the worker's worktree), caches | ignored | ignored |
| holdouts | **never in the repo**: `maintenance.holdouts` names the private location the verifier reads | — | — |

IuRoot: the sources of every row marked *linked* live in `dotfiles-private/projects/<repo>/`; the
work repo gets symlinks listed in `.git/info/exclude`, so nothing tracked changes there. Drift
check: required paths exist (`project.yaml`; any other row only when it has content — no
placeholder files, no empty directories), forbidden ones do not (holdouts, hand edits inside generated files), `.factory/` is ignored, IuRoot links
resolve and are excluded.

Generated, never hand-edited: the AGENTS.md routing block (between markers), PLAN.md checklist
blocks (from the ledger), herdr `groups.json`, Argo's project registry, reconciler policies, OTel
resource attributes (`project.name`), usage-tracker's project map, the task-export/TickTick/brain
projection headers. Drift check (`warden manifest check`, in CI and `make doctor`): schema valid;
every production runtime has an availability SLO or an explicit `slo: none`; `commands` parse;
every integration key resolves (Kuma monitor, herdr workspace, TickTick list, brain note, OTel
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
