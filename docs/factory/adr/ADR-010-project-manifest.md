# ADR-010 — One project manifest per repo; everything about a project is generated from it

- Status: accepted · 2026-10-22
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
   evidence rule in `evidence/projects/classify.py`), `runtime` (targets, services, deploy mode —
   the topology the correlator walks), `health` (probes, OpenSLO terms only where an SLO exists),
   `maintenance` (deps, docs, analyze, holdouts location), `autonomy` (per action class),
   `integrations` (beads-compatible task prefix, TickTick list, brain note, herdr workspace and
   group, OTel services, Kuma monitors, usage project, changelog target). Schema in `design/model.md` §6.
2. **Location.** SourceRoot: committed. IuRoot: the source lives in `dotfiles-private/projects/`,
   is linked to `<repo>/project.yaml` and excluded through `.git/info/exclude` — nothing tracked
   changes in a work repo.
3. **Generated, never hand-edited:** the AGENTS.md routing block between markers, herdr
   `groups.json`, Argo's project registry, reconciler policies, OTel resource attributes
   (`project.name`), usage-tracker's project map, the projection headers of the brain note.
4. **Drift check** (`factory manifest check`; CI and the daily reconciler): schema valid; every
   integration key resolves (Kuma monitor exists, herdr workspace exists, brain note exists, OTel
   service seen in 7 days); generated files in sync; topology covers every running container,
   launchd job and Kuma monitor (today: 19 of 36 vps services have no monitor).

### Consequences

- Good: one place to add a project; topology for correlation; a project page that assembles itself.
- Bad: 33 + 20 manifests to write once — the first migration wave generates drafts from today's AGENTS.md, Makefile, herdr groups, Kuma names and the topology evidence, then an agent reviews each.

### Confirmation

CI: drift check green on every repo; a lint fails any hand edit inside a generated block; Argo's
project list equals the set of manifests.
