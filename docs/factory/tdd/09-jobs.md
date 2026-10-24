# 9. Upkeep jobs

A job is a small TypeScript module, not an agent. Code does the looking; a model is called only when
the code found something worth a sentence. Swamp's ideas, without its runtime: typed steps in code,
assertions as first-class steps, nothing spent when everything is fine.

```ts
// factory/jobs/deps.ts
export default job({
  schedule: "0 6 * * 1",
  projects: (p) => p.jobs.includes("deps"),
  async run({ project, probe, summarize, open }) {
    const outdated = await probe.outdated(project);            // bun outdated --json, release ages
    const due = outdated.filter((d) => d.ageDays >= (d.major ? 14 : 3));
    if (due.length === 0) return;                               // green: zero tokens
    const notes = await probe.releaseNotes(due);                // changelogs + migration guides, cached
    const plan = await summarize("group-upgrades", { due, notes }); // one Haiku call
    await open({ kind: "upkeep", class: "upkeep", title: plan.title, plan });
  },
});
```

A job never edits a repo. Code changes become Tasks and go through the loop.

## First jobs

| Job | Lands | Probe | Opens |
|-|-|-|-|
| **deps** | W6 | outdated packages, release age, changelogs and migration guides | one upgrade Issue per group of packages that move together; majors wait ≥ 14 days and come with what to adopt, not just a bump |
| **docs and agent setup** | W6 | generated AGENTS.md blocks vs a fresh render; AGENTS.md size, skill count, resident tool tokens | upkeep when drifted or over budget |
| **code health** | W6 | `make quality` over the week's changes | one batched upkeep Issue per project |
| **infra** | W1: backups and the restore drill; W6: the rest | disks, certs, backup age and a weekly restore test, containers, databases, ClickHouse, the mini's memory and swap | an incident with its runbook |
| **briefing** | W5, with *Now* | the night's closed, stuck and waiting Issues, decisions, capacity | the 07:00 Argo briefing and push — a template, no model; audio through audio-gateway if enabled |

The *changelog* is not a job of its own: the brain page section is written from conventional commits
on each merge (§7).

## Next, each when it has a consumer

| Job | Trigger to build it |
|-|-|
| basalt-ui upstream: duplicates across consumers, and pieces consumers built that basalt-ui lacks | the first consumer-built component that another app needs |
| perf: p95 and error rate per service against a 14-day baseline | a regression that reached you |
| traffic: Umami `/stats` and `/events/series` against a rolling baseline (Umami has no anomaly endpoint) | Umami events and goals wired into the apps |
| security audit: Cloudflare's security-audit skill, `quick` profile | per fleet repo once its changes since the last audit pass ~2,000 lines, on upkeep capacity |
| herdr hygiene: compact or rotate idle mothers (W2 already closes finished workers' tabs) | the first mother idle past a day |

**Security** also has a runbook class from W4: CrowdSec decisions arrive as signals, and the runbooks
block an address, stop an exposed container or mark a leaked secret for rotation; one gameday proves it.

## Upgrades

You upgrade in a full Claude session every few weeks because an upgrade is rarely a version bump:
packages move together, majors need their migration guide, and the point is to use what is new. The
job does the deterministic part and one grouping call; the Issue becomes a planned upgrade wave —
research, migrate, adopt, verify — that a worker or the project's mother ships on upkeep capacity.
Renovate is not used.
