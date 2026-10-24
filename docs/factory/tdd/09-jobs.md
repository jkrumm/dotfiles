# 9. Recurring jobs — self-improving at zero tokens when green

A job is a small pipeline, not an agent. Code does the looking; a model is called only when the code
found something worth a sentence. The idea is Swamp's: typed steps in code, definitions as data,
`assert` as a first-class step (`research/2026-10-24-factories-landscape.md` §a).

## Shape

```yaml
# factory/jobs/deps.yaml
name: deps
schedule: "0 6 * * 1"            # Monday 06:00
for_each: projects(jobs contains deps)
steps:
  - probe: outdated               # bun outdated / npm-check-updates --jsonUpgraded → JSON, per repo
  - probe: release-notes          # changelog + migration guide URLs for each candidate, fetched, cached
  - assert: "candidates.filter(c => c.ageDays >= 14).length > 0"
  - summarize:                    # only if the assert found something; Haiku 5.5, one call
      prompt: group-upgrades      # which packages move together, which majors wait, what is worth adopting
  - open: { kind: upgrade, priority: P3 }
```

Step kinds: `probe` (deterministic, JSON out), `assert` (an expression over probe output; a false
assert ends the run green), `summarize` (one cheap call, structured output), `open` (Signal → the
loop), `act` (a deterministic action, for runbook-style jobs). A job never edits a repo itself; code
changes become Tasks and go through §4.

## Catalogue

| Job | Cadence | Probe | Opens | Green cost |
|-|-|-|-|-|
| **deps** | weekly | outdated packages, release age, changelogs and migration guides | one upgrade Issue per coherent group; majors wait for maturity (≥ 14 days, ecosystem adoption) and come with what to adopt, not just a bump | 0 |
| **docs drift** | daily | generated AGENTS.md blocks vs a fresh render; links; docs older than the code they describe | `hygiene` | 0 |
| **code health** | weekly | `make quality` over the week's changes: oversized files, duplication, dead code | one batched `hygiene` per project | 0 |
| **agent setup** | weekly | AGENTS.md size, skills count, resident tool-definition tokens per repo and globally | `hygiene` when over budget | 0 |
| **basalt-ui upstream** | weekly | components duplicated across consumers, and pieces consumers built that basalt-ui lacks | an Issue on basalt-ui per candidate | 0 |
| **bug sweep** | weekly | new OTel error clusters per service; agent-gateway review over the week's merged diffs (light depth) | `bug` | ≈ $2–5 / week |
| **perf** | daily | p95 and error rate per service vs its 14-day baseline | `bug` on regression | 0 |
| **traffic** | daily | Umami `/stats` and `/events/series` per app vs a rolling baseline (Umami has no anomaly endpoint) | `incident` on a drop | 0 |
| **infra** | 5 min – daily | disks, certs, backups (age and restore test), containers, databases, ClickHouse, the mini's memory and swap | `incident` with a runbook | 0 |
| **security** | daily / quarterly | CrowdSec decisions and auth anomalies daily; Cloudflare's security-audit skill, `quick` profile, per fleet repo quarterly | `incident` / `hygiene` | quarterly audit on lapsing Max capacity only (P3) |
| **GitHub** | 10 min | open issues and failed checks on owned repos | Signals | 0 |
| **herdr hygiene** | hourly | tabs done or idle > 24 h, mothers past their context budget | closes finished tabs, compacts or rotates mothers; never touches a tab you are in | 0 |
| **changelog** | daily | `git log` since the last run per project | one dated entry in the *Changelog* section of the project's brain page (`brain/Projects/<project>.md`), shown in Argo | ≈ $0.01 / project-day |
| **morning briefing** | 07:00 | the night's closed, stuck and waiting Issues, decisions, capacity | the briefing page + push + optional audio | ≈ $0.05 |

Hermes' "Project narratives" cron (daily 06:30 → Slack) is replaced by *changelog* and the briefing.

## Upgrades, specifically

You upgrade in a full Claude session every few weeks because upgrades are rarely a version bump:
packages move together, majors need their migration guide, and the point is to use what is new.
The job therefore does the deterministic part (what is outdated, how old, which notes) and one cheap
grouping call; the Issue goes to the project's mother as a planned upgrade wave — research, migrate,
adopt, verify — at P3, so it runs on capacity that would otherwise lapse. Renovate is not adopted.

## Writing a new job

A job is a YAML file plus, if needed, a probe in TypeScript. An agent can write the YAML from a
one-line request; the factory validates it against the step schema and dry-runs it once before
scheduling it. A job that spends tokens on a green run is a defect the job catalogue check flags.
