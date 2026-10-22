# ADR-010 — One project manifest per repo; everything about a project is generated from it

- Status: accepted · 2026-10-22 (revised after panel pass 1: dx-1, dx-2, dx-3, dx-7, dat-2, dat-8, sre-1, sre-7, int-4, int-5, mig-8, sim-1)
- Evidence: `findings-2026-10-22.md` §Project identity has no system of record, `evidence/postmortem/postmortem.md` (lane text hand-copied into 19 files; prose claims held 1 of 11), `evidence/signals/topology.out.json` (117 runtime units, blind spots), `evidence/projects/classify.out.md`, `research/2026-10-22-ops-correlation-catalog-eval.md` §4

## Context and problem statement

A project's identity lives in nine places that disagree: brain (two folders, overlapping names),
herdr workspaces and groups, warden's free-text `repo`, usage-tracker's cwd-derived `project`,
Argo's per-project TickTick query, OTel service names, Kuma monitor names, AGENTS.md prose. The
correlator needs topology, the reconcilers need desired state, Argo needs a project page, and
nothing can join them.

## Decision outcome

1. **`project.yaml` at each repo root**, Backstage `Component` envelope (`metadata.name` = repo dir
   = project id everywhere; `spec.type`, `spec.lifecycle`, `spec.owner`,
   `github.com/project-slug`), plus factory fields: `class` (fleet | session, decided by the
   evidence rule in `evidence/projects/classify.py`), `maintenance` (deps, docs, analyze, holdouts
   location), `autonomy` (per action class), and the `factory/v1` fields below. Schema in
   `design/model.md` §6.

   | Field | Carries | Read by |
   |-|-|-|
   | `runtime[].{host, containers[], launchd[], version, availability}` | deploy targets; `host` is a ref to an infra project; `availability: intermittent` marks a host that sleeps (the MacBook) | the correlator's topology walk, the health and deploy reconcilers |
   | `spec.dependsOn`, `spec.providesApis` | Backstage relations; consumers derived from them | correlator, Argo's library page |
   | `data.{databases[], backups{target, maxAge}}` | stores and backup policy | migration ladder, `infra.backup` age conditions |
   | `doors[]` | dev and public doors | Caddyfile app blocks (rendered) |
   | `commands{check, verify, deploy, restart, logs}` | the repo's verbs | the per-repo block; recipes call `spec.commands.restart` and never construct make lines |
   | `slo` or explicit `slo: none` | OpenSLO terms; required on every production runtime | heads-up tier (ADR-014) |
   | `policy.prRequired` | PR-required flag | `pr-required-repos.json` (rendered) |
   | `product_surfaces[]` | public routes, store listings, pricing, holdout scenarios, removed features | the ladder (ADR-012): a Change touching one that does not trace to an owner-submitted brief or a reviewed plan Artifact is product-class and becomes a Decision with a reversible default (ADR-014) |
   | `integrations` | `tasks: {prefix}` (the ledger's task id prefix — beads' verbs, not its runtime, ADR-001), TickTick list, brain note, herdr workspace and group, OTel services, Kuma monitors, usage project, changelog target | the integrations reconciler (§4), projectors |

   **`availability: intermittent`:** output-age conditions (e.g. `infra.backup` age > `maxAge`)
   replace liveness heartbeats, and nothing is investigated while the host is known asleep.
2. **Location and the directory contract.** SourceRoot: committed. IuRoot: the sources live in
   `dotfiles-private/projects/<repo>/`, are linked into the work repo and excluded through
   `.git/info/exclude` — nothing tracked changes in a work repo. **homelab-private** keeps its
   manifest and topology inside homelab-private, and every generated output excludes it. Every repo has the same structure
   beside `project.yaml` (`design/model.md` §6.1): plans in `docs/waves/`, ADRs in `docs/adr/`,
   artifact versions in `docs/artifacts/` (their threads live only in the ledger, ADR-005), notes in `docs/notes/`, the changelog where
   `changelog.target` says (brain by default), attempt hooks and caches in an ignored `.factory/`,
   holdouts never in the repo. *Added 2026-10-22 (owner intent: "a hard structure for each repo").*
3. **Generated, never hand-edited:** the per-repo AGENTS.md block between markers — manifest
   facts only (role, runtime, `commands`, monitors, directory map); tool routing renders once into
   the global generated rules file (ADR-004) — herdr `groups.json`, Argo's project registry,
   reconciler policies, OTel resource attributes (`project.name`), usage-tracker's project map, the
   projection headers of the brain note, `config/pr-required-repos.json` (from `policy.prRequired`),
   architecture.md's repo and LaunchAgent tables (from `runtime[].launchd`), the Caddyfile app blocks
   (from `doors[]`) and the self-hosted runner list.
4. **Onboarding is one command.** `warden project new <name> --type …` (the former `factory` CLI,
   folded into warden — ADR-004) writes `project.yaml` from a per-type template, creates the
   directory contract and renders every generated file. `integrations` are **desired state**: the
   integrations reconciler creates what it can (herdr workspace, brain note stub, Kuma monitor via
   its API, the project's TickTick list — titles only, the factory never writes the owner's todos —
   runner sync, the PR-required entry) and verifies what it can only observe (an OTel service seen).
5. **Drift check** (`warden manifest check`; CI and the daily reconciler): schema valid; every
   integration key resolves (Kuma monitor exists, herdr workspace exists, brain note exists, OTel
   service seen in 7 days); every `commands` entry is valid (`make -n` parses, params declared);
   every production runtime has an availability SLO or an explicit `slo: none`; generated files in
   sync and free of homelab-private entities; the directory contract holds; topology covers every running container,
   launchd job and Kuma monitor (today: 19 of 36 vps services have no monitor).

### Consequences

- Good: one place and one command to add a project; topology for correlation; a project page that assembles itself; heads-up is never silently impossible (`slo` is explicit); product direction is caught by diff paths, not agent judgment.
- Bad: the integrations reconciler and per-type templates to build (W2); 33 + 20 manifests to write once — the first migration wave generates drafts from today's AGENTS.md, Makefile, herdr groups, Kuma names and the topology evidence, then an agent reviews each.

### Confirmation

CI: drift check green on every repo; a lint fails any hand edit inside a generated block; Argo's
project list equals the set of manifests. W2: a scratch repo reaches a green `warden manifest check`
and appears in Argo, herdr groups and usage-tracker from `warden project new` alone — zero facts
typed beyond name and type; adding a repo with a door, a launchd job and PR-required status edits
only `project.yaml`.
