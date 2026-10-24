# ADR-010 — One project manifest per repo; everything about a project is generated from it

> **v2 status (2026-10-24):** revised — + make contract, deploy mode, migrations, per-path autonomy (TDD v2 §7). The text below is v1 history.

- Status: accepted · 2026-10-22 (revised after panel pass 1: dx-1, dx-2, dx-3, dx-7, dat-2, dat-8, sre-1, sre-7, int-4, int-5, mig-8, sim-1; after pass 2: dx-1, dx-2, dx-3, dx-6, dx-7, dat-7, dat-14, ver-2, int-8, dur-1, mig-4)
- Evidence: `findings-2026-10-22.md` §Project identity has no system of record, `evidence/postmortem/postmortem.md` (lane text hand-copied into 19 files; prose claims held 1 of 11), `evidence/signals/topology.out.json` (117 runtime units, blind spots), `evidence/projects/classify.out.md`, `research/2026-10-22-ops-correlation-catalog-eval.md` §4, `panel/pass1/dx.json` dx-3 (IuRoot measured: 1 repo tracks AGENTS.md, 6 track CLAUDE.md, 1 tracks `docs/waves`)

## Context and problem statement

A project's identity lives in nine places that disagree: brain (two folders, overlapping names),
herdr workspaces and groups, warden's free-text `repo`, usage-tracker's cwd-derived `project`,
Argo's per-project TickTick query, OTel service names, Kuma monitor names, AGENTS.md prose. The
correlator needs topology, the reconcilers need desired state, Argo needs a project page, and
nothing can join them.

## Decision outcome

1. **`project.yaml` at each repo root**, Backstage `Component` envelope (`metadata.uid` — the id
   events and history join on, stable across renames, a rename emits `project.renamed`;
   `metadata.name` = repo dir, the display key; `spec.type`, `spec.lifecycle`, `spec.owner`,
   `github.com/project-slug`), plus factory fields: `class` (fleet | session, decided by the
   evidence rule in `evidence/projects/classify.py`), `maintenance` (deps, docs, analyze, holdouts
   location), `autonomy` (per action class), and the `factory/v1` fields below. The schema is
   `design/model.md` §6; this table says who reads what.

   | Field | Read by |
   |-|-|
   | `runtime[].{host, containers[], launchd[], version, availability}` | the correlator's topology walk, the health and deploy reconcilers. `host` is a ref to an infra project. `availability: intermittent` marks a host that sleeps (the MacBook): output-age conditions (e.g. `infra.backup` age > `maxAge`) replace liveness heartbeats, and nothing is investigated while the host is known asleep |
   | `runtime[].artifact {image, compose, launchd}` | rollback (dat-14): the registry image, compose file and launchd label from which the deploy reconciler records the immutable reference — digest, compose revision, bundle hash — on each Deployment; ADR-012's rollback redeploys that reference |
   | `spec.dependsOn`, `spec.providesApis` | correlator, Argo's library page (consumers derived from the relations) |
   | `spec.provides.clis[{name, contract: agent \| passthrough}]` | ADR-004: the conformance suite's scope and the concept-budget count of agent-facing CLIs |
   | `data.{databases[], backups{target, maxAge}}` | migration ladder, `infra.backup` age conditions |
   | `doors[]` | Caddyfile app blocks (rendered); public doors seed `product_surfaces` |
   | `commands{check, verify, deploy, restart, logs}` | the per-repo block; recipes call `spec.commands.restart` and never construct make lines |
   | `health.probes` | the health reconciler; an evidence producer (item 6) |
   | `slo` or explicit `slo: none` | heads-up tier (ADR-014); required on every production runtime |
   | `policy.prRequired` | `config/pr-required-repos.json` (rendered), which `hooks/protect-branches.ts` and `scripts/github-config.sh` read |
   | `product_surfaces[]` | derived per `spec.type` — route trees, store-metadata directories, pricing files, public `doors[]` — and the manifest field only adds or excludes (dx-6); the ladder reads it (ADR-012, product surfaces). Editing the field is itself a Change touching a product surface |
   | `integrations` | `tasks: {prefix}` (the ledger's task id prefix — beads' verbs, not its runtime, ADR-001), TickTick list, brain note, herdr workspace and group, OTel services, Kuma monitors (an evidence producer, item 6), usage project, changelog target — the integrations reconciler (item 4), projectors |
2. **Location and the directory contract.** SourceRoot: committed. IuRoot: the sources live in
   `dotfiles-private/projects/<repo>/`, are linked into the work repo and excluded through
   `.git/info/exclude` — nothing tracked changes in a work repo. Links are per file, so a tracked
   parent directory does not collide (one IuRoot repo already tracks `docs/waves`); a link whose
   exact path is already tracked is skipped, and the drift check accepts the tracked file.
   **homelab-private** keeps its manifest and topology inside homelab-private, and every generated
   output excludes it. Every repo has the same structure beside `project.yaml`: the directory
   contract of `design/model.md` §6.1, which fixes locations and creates nothing empty. *Added
   2026-10-22 (owner intent: "a hard structure for each repo").*
3. **Generated, never hand-edited; renders are pinned.**
   - **The per-repo AGENTS.md block** between markers: manifest facts only (role, runtime,
     `commands`, monitors, directory map). Tool routing is not in it; it renders once into the
     global generated rules file (ADR-004). **IuRoot:** the block never lands in a tracked AGENTS.md
     or CLAUDE.md; it renders to a linked, excluded file beside the sources. Which file name each
     harness loads, per case (the repo tracks AGENTS.md, tracks CLAUDE.md, tracks neither), is fixed
     by one loading test in W2b: a Claude Code and an OpenCode session in an IuRoot repo of each case
     load the block while `git status` stays clean.
   - **The registries:** herdr `groups.json`, Argo's project registry, reconciler policies, OTel
     resource attributes (`project.name`), usage-tracker's project map, the projection headers of
     the brain note, `config/pr-required-repos.json` (from `policy.prRequired`), architecture.md's
     repo and LaunchAgent tables (from `runtime[].launchd`), the Caddyfile app blocks (from
     `doors[]`) and the self-hosted runner list.
   - **Pinned inputs** (dx-2). `config/factory/manifests.lock` maps each repo to the default-branch
     blob sha of its `project.yaml` (an IuRoot project pins the dotfiles-private blob;
     homelab-private has no entry) and is committed with every render. A render reads only the
     blobs the lock names, fetched by sha, and `make check` verifies outputs = render(lock): the
     same answer on the MacBook and the mini, and no red check when a manifest merges elsewhere.
     The integrations reconciler is the one actor that advances the lock — when a default-branch
     blob changes it commits lock and outputs together (an effect-registry write: natural key
     `render:<lock-hash>`, lookup on conflict). A lock behind a default-branch blob is a Condition,
     not a red `make check`.
4. **Onboarding is one command; drift is proposed, not discovered.** `warden project new <name>
   --type …` (the former `factory` CLI, folded into warden — ADR-004) writes `project.yaml` from a
   per-type template, creates the directory contract's paths that hold content (nothing empty) and renders every generated file. The same
   template writes the repo's `Makefile` with one target per declared `commands` entry, so
   `make -n` parses on a fresh repo (a Makefile that holds targets is not an empty placeholder), and
   the CI workflow (self-hosted runner for a private repo, hosted for a public one).
   `integrations` are **desired state**: the integrations reconciler creates what it can — for a
   SourceRoot repo the GitHub repo and its branch protection (`scripts/github-config.sh`), plus the
   herdr workspace, brain note stub, Kuma monitor via its API, the project's TickTick list (titles
   only — the factory never writes the owner's todos), runner sync and the PR-required entry — and
   verifies what it can only observe (an OTel service seen). Every create is an effect-registry
   write with *natural key + lookup on conflict*, keyed on the object's name, so a retried
   reconcile never makes a second monitor, list or workspace.
   **`warden manifest draft` is a standing reconcile mode** (dx-3), not a migration tool: it
   observes compose labels (`factory.project`), launchd labels and Kuma monitors and proposes the
   difference to `runtime[]` and the monitor lists as a manifest Change, so a renamed container or
   a new monitor surfaces as a proposed Change instead of a stale entry.
5. **Drift check** (`warden manifest check`; CI and the daily reconciler): schema valid; every
   integration key resolves (Kuma monitor exists, herdr workspace exists, brain note exists); every
   `commands` entry is valid (`make -n` parses, params declared) and every production runtime
   declares `restart` (a gap is a filed Task, and no restart recipe runs on that runtime); every
   production runtime has an availability SLO or an explicit `slo: none`; generated files in sync
   with the lock and free of homelab-private entities; the directory contract holds; topology
   covers every running container, launchd job and Kuma monitor (today: 19 of 36 vps services have
   no monitor). Keys the factory can only observe — an OTel service seen in 7 days — are Conditions
   while `lifecycle: experimental` and check failures from `production`. **One checker owns
   topology** (dx-2): `scripts/architecture-check.sh` folds into this check as its machine-local
   leg — every launchd label loaded on the machine and every owned plist on disk is declared in the
   rendered tables, on the script's allowlist — and `make doctor` calls it, still exiting 1 on an
   unmapped label.
6. **Evidence producers are `factory-self`** (ver-2). `health.probes`, `integrations.kuma.monitors`,
   `commands.verify` and `runtime[].artifact` (the rollback reference) decide which rungs a project
   can auto-ship on (effective autonomy, ADR-012). A Change that adds, removes or weakens one is
   class `factory-self`, so an agent cannot raise its own rung with a config Change; a producer
   counts only after the verifier has watched it fail (ADR-012).

### Consequences

- Good: one place and one command to add a project; topology for correlation; a project page that assembles itself; heads-up is never silently impossible (`slo` is explicit); product direction is caught by diff paths derived from the repo's own routes, pricing files and doors, not by agent judgment or a hand-typed list; every declared runtime has an addressable rollback reference; a manifest merge in another repo never reddens dotfiles' `make check`; a Change cannot raise its own gate by editing a probe.
- Bad: the integrations reconciler, per-type templates, the lock and the standing draft mode to build (W2b); 33 + 20 manifests to write once — W2a generates drafts for the repos with production runtime units and W2b for the rest, from today's AGENTS.md, Makefile, herdr groups, Kuma names and the topology evidence, then an agent reviews each; the draft mode proposes Changes for as long as the fleet changes, each reviewed on the ladder; the IuRoot block's file name stays open until W2b's loading test.

### Confirmation

CI: drift check green on every repo; a lint fails any hand edit inside a generated block; `make
check` verifies outputs = render(lock) on both machines; Argo's project list equals the set of
manifests. **W2a:** `warden manifest check` green on every repo with a production runtime unit
(schema, commands, topology). **W2b:** a scratch repo reaches a green check and appears in Argo,
herdr groups and usage-tracker from `warden project new` alone — zero facts typed beyond name and
type; adding a repo with a door, a launchd job and PR-required status edits only `project.yaml`; a
merged `doors[]` change in one repo leaves dotfiles' `make check` green until the reconciler
advances the lock, and the re-render then lands without a human; renaming one compose service
surfaces as a proposed manifest Change; the IuRoot loading test passes for all three cases; a
worker's config Change adding `health.probes: [GET /robots.txt]` to a project with no probe is
`factory-self` and leaves `code_fix` propose-only; a public route added to a new project by a Change with no owner event in its lineage is
product-class.
