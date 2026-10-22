# Model

Revised against Phase 1 evidence, spikes 1, 2, 6, panel passes 1 and 2 (`panel/pass1-resolutions.md`,
`panel/pass2-resolutions.md`) and the cross-lab review (`panel/review-resolutions.md`). Each fact is
stated here or in `loops.md` once; ADRs and report sections link to it. Report section 3 is built
from this file.

## 1. Eleven nouns

Rule: every noun has exactly one system of record (SoR) and exactly one writer module. Everything
else that shows the noun is a projection with a named projector, rebuilt from the event log. The
Writer column lists every command source; each goes through the noun's one write module, so the
one-writer CI check tests what the table claims.

| # | Noun | Is | SoR | Writer | Id |
|-|-|-|-|-|-|
| 1 | **Project** | a repo or infra unit, described by its manifest | configuration: `project.yaml` in the repo (git; IuRoot: source in dotfiles-private, linked in, `.git/info/exclude`d). Runtime state (pause override, last reconcile, effective autonomy): the **project runtime record**, the ledger's `project_runtime` table. Each attribute has exactly one SoR | manifest: the owner or an agent, through a Change (§6 names the `factory-self` fields). Runtime record: the pause verb (owner; ADR-015), the reconcilers, `warden manifest check` | `metadata.uid` (stable across renames; every event's `project` holds it); `metadata.name` = repo dir name, the display key |
| 2 | **Signal** | one external observation, immutable (alert fired/recovered, deploy started/finished, default-branch merge, CI result, issue, request, herdr event, job run, update available, observed config) | event log | ingest adapters, one per source (ADR-013) | `sig_<ulid>` + `fingerprint` |
| 3 | **Condition** | level state "observed ≠ desired" for one `(project, type, subject, fingerprint class)`; the class is the kind of failure the normalised fingerprint names (a crash or an OOM, a flaky test or a regression), so two causes on one subject are two Conditions | ledger | that project's reconciler, only; the `lineage.breaker` type (subject = lineage) by a factory-self reconciler | `cond_<ulid>`; unique open key `(project, type, subject, fingerprint class)` |
| 4 | **Incident** | signals and conditions with one cause; carries root cause and fix recipe. Closed incidents with a recipe **are** the known-error store | ledger | correlator, including its logged, reversible `split` and `merge` (`design/loops.md` §2) | `inc_<ulid>` + fingerprint set |
| 5 | **Task** | a unit of work with a done-definition and dependencies (the `task_deps` table); the ledger is its only home of state — PLAN.md holds task ids only and state is never written to git (ADR-001) | ledger (ADR-001: beads' verbs, not its runtime) | `tasks` module, called by: planner, owner submit and wave close-out (create); the spawner and `rd` (claim — a Task is claimed only through the ready queue and `rd`, whoever asked: planner, a mother wake or the owner); the worker Agent with its epoch (heartbeat, done); `/wave` (`warden task done`); Witness (re-drive → ready); decide step (blocked → ready, cancelled) | `task_<ulid>` |
| 6 | **Change** | commits proposed to or merged into a default branch (a PR, or a direct push) | git / GitHub; the ledger mirrors refs | `changes` module, called by the ship loop (train state) and on the ref adapter's `merged` Signal for every new default-branch sha, which it records as `change.merged` (actor push, renovate or train) | `chg_<ulid>`; unique `(project uid, pr number or sha)` |
| 7 | **Deployment** | a version running on a target, identified by its immutable artifact reference (image digest, compose revision or bundle hash; `runtime[].artifact`, §6) | ledger | the deploy reconciler, only — it consumes started / deployed / failed Signals from every source (`make deploy` wrapper, RollHook, WUD, CI) keyed target + artifact, change optional; a container replaced with no recorded intent is an unplanned Deployment | `dep_<ulid>` |
| 8 | **Verification** | one piece of evidence about a subject: check, review, holdout, health, canary, post-deploy; a known-bad version is a `fail` on (target, artifact digest) | ledger | the verifier that ran it | `ver_<ulid>` |
| 9 | **Artifact** | a reviewable document version (plan, report) and its comment threads | threads and state: the ledger (Artifact entity plus comment events, ADR-005); versions: git, `path@sha` | the `warden artifact` module (submit, comment, resolve; it never commits); versions: the submitting agent, through the normal Change path | `art_<ulid>` |
| 10 | **Agent** | a running or resumable agent session with role, engine and project; a worker carries an optional `task_id` and its **hook** (worktree + branch + base sha + epoch + message inbox). A Task's attempts are its worker Agents | ledger: `spec` by the spawner, `status` by the herdr observer, the `idle.parked{reason, resume_at}` substate by Witness only, `agent.replied` by the agent's own `warden agent reply` | spawner / observer / Witness / the agent's reply call, one field set or event each | `agt_<ulid>`; herdr pane, session id and last output (herdr record) are observed attributes |
| 11 | **Decision** | a question with options, a default, an expiry, a decider and an outcome | ledger | decide step; outcome by the decider (policy, agent, owner, timeout) | `dec_<ulid>` |

Not nouns, on purpose: *Attempt* (a worker Agent with a `task_id`), *job* (a gateway call is a
tool use inside an Agent's work or a Verification), *wave* and *plan* (an Artifact whose tasks are
Tasks), *lead* (a mother wake scoped to one plan, ADR-007), *notification* and *briefing*
(projections of the log), *known error* (a closed Incident with a recipe), *candidate* (an Incident
state), *holdout scenario* (a Verification spec), *agent message* and *artifact comment* (events on
the Agent and the Artifact), *intent* (an owner event on its target entity with the lifecycle
requested → applied | rejected | expired, ADR-015; `intents_recent` folds them), *pause* (a field
of the project runtime record, never a Decision), *breaker* (the Condition `lineage.breaker`,
subject = lineage, opened and closed on observation by a factory-self reconciler; limits and close
rule in ADR-012), *budget* (a fold over the charge events the spawner and Witness emit per Task and
lineage; units and ceilings in ADR-012), *known-bad version* (a `fail` Verification on (target, artifact digest)
that the ship loop checks before deploying), *lineage* (fingerprint set + `regression_of` chain +
topology subject as a deterministic id stamped on events, never a stored row), *policy* (manifest
and policy files), *host/container/service* (manifest topology), *owner todo* (TickTick is its own
SoR, read-only to the factory).

**Plumbing, exempt from the noun count:** `events`, `operations`, `timers`, `leases`,
`deliveries` — infrastructure tables owned by the ledger module, with no lifecycle of their own
that the owner sees. **Noun-owned tables:** `task_deps` (Task) and `project_runtime` (Project's
runtime record) belong to their noun's one write module and count with it, so every ledger table
maps to a noun or to this list (the concept-budget check, `design/proof.md` §6).

## 2. Statecharts

{{asset:statecharts}}


```
Condition   (none) ─observe(bad)→ open{firing ⇄ suppressed} ─observe(ok) ≥ hold→ resolved
            resolved ─observe(bad) within reopen window→ open (same id, flaps++)
            closes only on an observation, never on a click
            lineage.breaker: the same lifecycle (limits and close rule: ADR-012)

Incident    candidate ─promote rule→ open{triaging → mitigating → verifying; awaiting_decision}
            candidate ─no promotion in window→ dismissed (kept, scored as noise)
            open ─every member's Condition resolved ∧ verification pass→ resolved ─hold→ closed
            open ─split: every other member resolved, one still open past its type's hold→
                  that member becomes a new incident, timeline kept
            open ─merge: late host evidence→ open child incidents fold under the host incident
                  (split and merge are logged and reversible; rules in loops §2)
            closed ∧ recipe → known error; same fingerprint after the fixing change deployed
            → new incident with regression_of = <closed id>

Task        open ─deps done→ ready ─claim(lease, epoch)→ claimed ─worker Agent working→ in_progress
            in_progress ─change merged ∧ verified→ done   (`warden task done`; state is never
                         written to PLAN.md)
            in_progress ─worker Agent failed | dead→ ready (next worker Agent, stronger engine,
                         new epoch) | blocked
            blocked ─decision→ ready | cancelled;  any ─superseded→ cancelled

Change      branch → proposed → checking → reviewing → queued → merged → (reverted)
            checking|reviewing ─fail→ revising (next worker Agent on the Task's branch
                         `factory/<task>`; `factory/<task>-<k>` when the predecessor could not be
                         confirmed dead — the superseding branch closes the old PR in the same operation)
            any before merged ─superseded→ closed
            a push to the default branch outside the train enters at `merged` (ref adapter)

Deployment  pending → deploying → deployed → verifying → verified → held
            deploying = the target's deploy lock is held, not stale (ADR-002);  deploying ─fail→ failed
            verifying ─fail→ rolling_back → rolled_back
            verified ─hold fails→ rolling_back → rolled_back
            verified = post-deploy checks passed;  held = its hold confirmed it (ADR-012)
            rollback target = the last `held` Deployment, never a merely `verified` one; a hold
            failure is attributed by redeploying the digests since that target in order (bisect),
            and the known-bad Verification lands on the attributed change only

Verification  pending → running → pass | fail | error   (error = infra, retried; fail = evidence)
              a `fail` on (target, artifact digest) is the known-bad marker the ship loop checks

Decision    open{options, default, expiry} ─decider→ decided → applied
            open ─expiry→ defaulted (reversible default taken; else re-push once and hold)
            open ─moot→ withdrawn

Agent       spawning ─brief delivered→ working ⇄ idle ⇄ blocked → done → reaped
            spawning ─no ack→ failed_to_start
            idle.parked{reason: quota | api_error | turn_end | waiting, resume_at}
              written only by Witness; agent.parked / agent.resumed events
            messages go to the hook inbox (agent.messaged); Witness nudges the pane once with the
              message id; the agent answers with `warden agent reply`, the one producer of agent.replied
            done (worker) carries the result contract {change | no_change | blocked}
            working ─context ≥ rotation mark→ handing_over → (successor running) → reaped
            any ─pane gone→ dead → resumed | reaped (worker: its Task → ready)
            successor takes the same hook only once the predecessor is confirmed dead, else a fresh
              branch (ADR-007 §6)

Artifact    submitted → in_review → resolved | superseded (new version) | expired (default: proceed)

Project     experimental → production → deprecated → archived;  class: fleet | session
            runtime record: automation running ⇄ paused — an owner override of desired state,
            defined once in ADR-015; never a Decision
```

## 3. Invariants (each one a CI check or a ledger constraint)

1. One writer per entity table: write functions live in one module per noun; a CI check
   rejects writes from anywhere else. Adapters write Signals only.
2. Every state change emits its event in the same transaction (transactional outbox).
3. Conditions close only on an observation.
4. An Incident closes only after a `pass` Verification linked to it.
5. A Decision with decider `owner` exists only for product direction, spend, irreversible
   data loss or other people, and always has a default and an expiry. Pause is not a Decision.
6. A worker Agent has a hook before it runs; one live worker Agent per Task, fenced by its lease
   epoch (ADR-002): a stale epoch is rejected on every ledger call, push and merge, and `rd` fails
   closed for any spawn that carries a `task_id` (ADR-007 §3); one writer per checkout.
7. Every merge the factory makes goes through the train and only when its action class's
   verification ladder is satisfied. A merge outside the train (the owner's direct push) is never
   gated; the ref adapter records it and it counts in regression and change-failure accounting.
8. Every pure read model is a fold over the event log. Every loop decision is itself an event
   carrying its outcome and reason (§4), so a rebuild replays decisions and never re-evaluates
   policy against a manifest, rule or calibration that has since changed. A read model with no
   event source is a **live probe**: labelled so in `design/argo.md`, rendered with `as_of`, never
   feeding a KPI or a control input. Effectors send through `deliveries(event_id, channel)`
   (ADR-011): an accepted delivery is never re-sent, a decision or heads-up push is retried until
   accepted, and an effector skips events with actor `import`.
9. Every event carries `correlation` = its lineage root; `emit()` enforces it, and planner,
   spawner and decide inherit it. The root is an Incident, or the Task an owner brief or the planner
   created — or, until correlated, the Signal itself (`correlation` = the signal id). Attaching a
   Signal emits `incident.member_added`, which records the merge of roots; nothing already written
   is rewritten. The autonomy KPI counts per root, and items count only Incident and Task roots, so
   a Signal root is never an item (`evidence/DEFINITIONS.md`).

## 4. One event log

```
events(
  id          TEXT PRIMARY KEY,   -- evt_<ulid>
  ts          TEXT NOT NULL,      -- RFC 3339 UTC, ms
  type        TEXT NOT NULL,      -- <noun>.<past-tense verb>: condition.opened, incident.promoted,
                                  --   task.claimed, agent.parked, change.merged, decision.defaulted …
  entity      TEXT NOT NULL,      -- id of the entity that changed
  project     TEXT,               -- project uid (metadata.uid), never the name
  actor       TEXT NOT NULL,      -- loop:<name> | agent:<id> | owner | source:<adapter> | import
  trace_id    TEXT, span_id TEXT, -- W3C; trace_id = sha256("<noun>:" + root id)[:32] (ADR-006)
  causation   TEXT,               -- event that caused this one
  correlation TEXT NOT NULL,      -- lineage root: an Incident, the originating Task, or the Signal's own id until correlated (invariant 9); emit() enforces it
  manifest_sha TEXT,              -- default-branch manifest blob read, on manifest-influenced events (audit, replay-diffing)
  idem        TEXT UNIQUE,        -- idempotency key of a side effect
  data        TEXT NOT NULL,      -- JSON, schema per type
  v           INTEGER NOT NULL DEFAULT 1
)
```

Signals are `signal.received` events; the Signal table is a view. Agent messages and artifact
comments are events on their Agent and Artifact; an owner intent is an owner event on its target
entity that ends in `applied`, `rejected` or `expired` (ADR-015). Every loop decision is an event
with its outcome and reason (invariant 8): `incident.member_added{rule, ancestor}`,
`agent.spawn_decided{engine, guard_verdict}`, `change.ladder_evaluated{rungs, effective_autonomy}`.
Argo's read models, briefings, KPIs and every projection consume the log by cursor; effectors
(push, vault write) follow invariant 8. Reconcilers read default-branch manifests only, never a
working tree. The ledger's schema carries a stamp and changes by expand/contract migrations only
(ADR-011 item 7).

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
  lifecycle: production                # experimental | production | deprecated | archived
  owner: jkrumm
  class: fleet                         # fleet: a mother identity per project (a lead is a mother wake
                                       #   scoped to one plan), workers claim from the ready queue;
                                       #   session: plain agents
  dependsOn: [<project ref>]           # Backstage relations; consumers derive from providesApis
  providesApis: [<api name>]
  provides:
    clis: []                           # [{name, contract: agent | passthrough}]: the conformance suite's
                                       #   scope (ADR-004); passthrough = a shim for someone else's CLI
  runtime:
    - host: vps                        # an infra project ref, not a bare string
      kind: compose
      containers: [weatherorb-api, weatherorb-web]
      launchd: []                      # launchd job labels, for mini and MacBook units
      artifact: {image: <registry/repo>, compose: <compose file>, launchd: <plist label>}
                                       # what a Deployment records and a rollback redeploys: digest,
                                       #   compose revision, bundle hash
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
                                       # derived per type (route trees, store-metadata directories,
                                       #   pricing files, public doors); this field only adds or excludes
  maintenance:
    deps: {renovate: true, minimumReleaseAge: 14d}   # Renovate opens PRs; the train merges them (ADR-012)
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
    traffic: {service: weatherorb-web}   # the OTel service whose request volume the Traffic page and B2 read (a live probe)
    kuma: {monitors: ["WeatherOrb API", "WeatherOrb Web"]}
    usage: {project: weatherorb}
    changelog: {target: brain}
```

Reconcilers and the correlator read the **default-branch** manifest only, never a working tree,
and stamp its blob sha as `manifest_sha` on every event the manifest influenced (§4: audit and
replay-diffing; read models fold the decisions, invariant 8). Files rendered from manifests (below)
read only the blobs pinned in `config/factory/manifests.lock`, committed with every render
(ADR-010). Pause, last reconcile and effective autonomy are not manifest fields: they live in the
project runtime record. A Change to an evidence-producer field (probes, monitors, `commands.verify`,
`runtime[].artifact`) is `factory-self` (ADR-010 §6).

### 6.1 The directory contract

Every repo has the same structure, so repo-specific things have one fixed home. The contract
fixes **locations** and creates nothing empty: a path exists only once it holds something, and the
drift check (`warden manifest check` — `factory` folded into the one factory CLI) enforces the
location only.

| Path | Holds | SourceRoot | IuRoot |
|-|-|-|-|
| `project.yaml` | identity, class, relations, runtime, data, doors, commands, health, policy, product surfaces, maintenance, autonomy, integrations | committed | linked from `dotfiles-private/projects/<name>/`, excluded |
| `AGENTS.md` (factory block) | the generated block between `<!-- factory:begin -->` and `<!-- factory:end -->`: manifest facts only (role, class, runtime, health, monitors, `commands`, directory map); tool routing renders once into the global rules file (ADR-004) | committed, inside the repo's AGENTS.md | a linked, excluded file beside the manifest source; the work repo's tracked AGENTS.md or CLAUDE.md is never edited, and how each harness loads the file is ADR-010's loading test |
| `docs/waves/PLAN.md`, `docs/waves/archive/` | the active plan in wave format; each checklist line holds a task id and nothing else, written once through a normal Change — task state is never written to git, Argo and `warden task list --plan <path>` render it (ADR-001); closed plans | committed | linked, excluded |
| `docs/adr/NNNN-title.md` | architecture decisions (MADR) | committed | linked, excluded |
| `docs/artifacts/<slug>/` | artifact versions (`vN.md` or `vN.html`), committed by the submitting agent; threads live in the ledger (ADR-005) | committed | linked, excluded |
| `docs/notes/` | repo-specific notes for agents and the owner | committed | linked, excluded |
| `CHANGELOG.md` | only when `changelog.target` includes `repo` (libraries with release notes); otherwise the changelog lives in the brain note | committed, generated | — |
| `.factory/` | worker Agent hooks (`.factory/attempt.md`, carrying the lease epoch, and the hook's message inbox, inside the worker's worktree), caches | ignored | ignored |
| holdouts | **never in the repo**: `maintenance.holdouts` names the private location the verifier reads | — | — |

IuRoot: the sources of every row marked *linked* live in `dotfiles-private/projects/<name>/` (the
display key; identity joins on `metadata.uid`, so a rename moves the directory in the Change that
emits `project.renamed` and breaks no history); the work repo gets symlinks listed in
`.git/info/exclude`, so nothing tracked changes there. A path the work repo already tracks (for
example `docs/waves/`) is never linked over: the tracked path stays the location and the factory
adds nothing to it. Drift check: required paths exist (`project.yaml`; any other row only when it
has content — no placeholder files, no empty directories), forbidden ones do not (holdouts, hand
edits inside generated files), `.factory/` is ignored, IuRoot links resolve and are excluded.

Factory-wide files are not per repo: dotfiles `config/factory/` holds `project.schema.json` (the
`factory/v1` schema), `manifests.lock` (ADR-010) and `policy.yaml` — the decider policy ADR-014
reads: the decider and expiry per owner-question class, plus one line per retired class.

Generated, never hand-edited: the AGENTS.md factory block (above), herdr `groups.json`, Argo's
project registry, reconciler policies, OTel resource attributes (`project.name`), usage-tracker's
project map, the task-export/TickTick/brain projection headers. Drift check (`warden manifest
check`, in CI and `make doctor`) fails when:

- the schema is invalid, or a generated file differs from a re-render of the pinned manifests;
- a production runtime has no availability SLO (or explicit `slo: none`), or cannot be read for
  what runs (`version` or `artifact` — the in-doubt deploy probe of ADR-002 needs one for every
  runtime that has a deploy command);
- a project with a public door has an empty derived-plus-declared `product_surfaces` set and does
  not declare `product_surfaces: none`;
- a `commands` entry does not parse (`make -n`, params declared);
- a runtime entry does not exist, or a running container, launchd job or Kuma monitor is not
  declared (`warden manifest draft` proposes the difference as a Change, ADR-010);
- an integration key does not resolve (Kuma monitor, herdr workspace, TickTick list, brain note;
  an OTel service seen in the last 7 days is a Condition while the project is `experimental` and a
  check failure from `production`, ADR-010).

A production runtime without `commands.restart` gets no restart recipe; the check files that gap as
a Task instead of failing.

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
