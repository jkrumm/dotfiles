# 9. Upkeep jobs

A job is a small TypeScript module, not an agent. Code does the looking; a cheap model writes up and
groups what it found; a lead does whatever needs understanding. Swamp's ideas, without its runtime:
typed steps in code, assertions as first-class steps, nothing spent when everything is fine. Jobs are
also where the factory grows more deterministic: a check a lead keeps doing by hand becomes a job
assertion.

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
    const groups = await summarize("group-upgrades", { due, notes }); // one cheap call: grouping, not a plan
    for (const g of groups) await open({ kind: "upkeep", title: g.title, evidence: g }); // a lead plans it
  },
});
```

A job never edits a repo. Anything that needs a change becomes an Issue and goes to a lead.

## First jobs

| Job | Lands | Probe | Opens |
|-|-|-|-|
| **deps** | W6 | outdated packages, release age, changelogs and migration guides | one upgrade Issue per group of packages that move together; majors wait ≥ 14 days and come with what to adopt, not just a bump |
| **docs and agent setup** | W6 | generated AGENTS.md blocks vs a fresh render; AGENTS.md size, skill count, resident tool tokens | upkeep when drifted or over budget |
| **code health** | W6 | `make quality` over the week's changes | one batched upkeep Issue per project |
| **infra** | W1a: backups and the restore drill; W6: the rest | disks, certs, backup age and a weekly restore test, containers, databases, ClickHouse, the mini's memory and swap | an incident with its runbook |
| **briefing** | W5, with *Now* | the night's closed, stuck and waiting Issues, decisions, the orchestrator's actions, capacity | the 07:00 Argo briefing and push, written by a cheap model under the three-line rule; audio through audio-gateway if enabled |
| **changelog** | W2: brain (homelab-private excluded); W5: Argo | the day's closed Issues and their leads' three-line summaries | per project, one sharp entry per change in the brain page's *Changelog* section and on Argo's project page, compiled by a cheap model from what the leads wrote, never from commit messages |
| **scorecard** | W3: v0; W6: in full | the factory's own facts, plus monitors, git and usage, never the leads' own reports alone | the numbers below, on *Factory* and in the orchestrator's status; the 07:00 briefing carries its exceptions; a measure off target for two weeks opens an upkeep Issue |

## The scorecard: the factory measuring itself

Outcomes first: a factory that closes many Issues while production gets worse is failing.

| Area | Measures |
|-|-|
| **Outcomes** | §11's six numbers; change failure rate (shipped changes followed by a regression or fix Issue within 7 days); probes failing per project; urgent Issues per week; non-business interrupts (target 0) and decision cards; autonomy (Issues closed with no touch from you) and touches per Issue |
| **Subscriptions** | unused capacity at each reset per account; account changes of running leads; 5-hour walls mid-work; your sessions' wait on walls |
| **Dedup and learning** | missed-at-intake rate, wrong-join rate, the judge's precision and recall against the leads' labels, in shadow and once trusted, seen-before hit rate, runbook share (§8); golden-set F1 on every rule change |
| **Pipeline** | time from Issue to lead, lead to ship, ship to close (p50 and p90); Issues without progress; Issues the orchestrator opened, still open, and their age |
| **Cost** | Max share and IU dollars per Issue, per project, per lead tier and per size band; tokens spent by green job runs (target 0) |

## Next, each when it has a consumer

| Job | Trigger to build it |
|-|-|
| basalt-ui upstream: duplicates across consumers, and pieces consumers built that basalt-ui lacks | the first consumer-built component that another app needs |
| perf: p95 and error rate per service against a 14-day baseline | a regression that reached you |
| traffic: Umami `/stats` and `/events/series` against a rolling baseline (Umami has no anomaly endpoint) | Umami events and goals wired into the apps |
| security audit: Cloudflare's security-audit skill, `quick` profile | per repo with a manifest once its changes since the last audit pass ~2,000 lines, on upkeep capacity |
| scorers: each closed Issue's lead transcripts, read by a cheap model against a few pass/fail rubrics: success declared without evidence, tests that check nothing new, the brief's history ignored, a question asked that was the lead's to decide; Warp's open `skill-doctor` rubrics are the start; a label per rubric on the Issue. A rubric failing five times, or a failure unreviewed for 7 days, opens an upkeep Issue that links the runs behind it. Calibrated against your own read of the first ten; about 3 % of token cost at Warp | 50 closed Issues, so the rubrics have something to grade |
| tuning: a cheap model reads cost and outcome per tier and size and the picker's decisions, and proposes new defaults as an upkeep Issue (§5) | 50 closed Issues with measured cost |
| herdr hygiene: tabs left over by crashed or abandoned sessions (the factory already closes leads' tabs after verify) | the first leftover tab a day old |

**Security** also has a runbook class from W4: CrowdSec decisions arrive as signals, and the runbooks
block an address, stop an exposed container or mark a leaked secret for rotation; one gameday proves it.

## Upgrades

You upgrade in a full Claude session every few weeks because an upgrade is rarely a version bump:
packages move together, majors need their migration guide, and the point is to use what is new. The
job does the deterministic part and one grouping call; the upgrade Issue is planned by its lead —
research, migrate, adopt, verify — and shipped on upkeep capacity.
Renovate is not used.
