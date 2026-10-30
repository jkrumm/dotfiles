# Cortex DRIVE / OpEx review: extract (Ganesh Datta, "Operational Excellence for the AI Software Factory", PDF, 2026)

Source: drive.txt (Ganesh Datta). Page = footer number. Extraction dropped letters in tables, so some thresholds are [garbled], not guessed.

## 1. What DRIVE is

Five pillars (p.8). Rollup rule: never average, use binary/raw counts (p.19). Incidents counter gamed SLOs (p.11); SLOs and incidents counter a gamed innovation % (p.14).

|Pillar (question)|Critical metrics as written|Secondary|
|-|-|-|
|D Delivery "Are we shipping fast, and is it sustainable?" (p.9-10)|Deploy frequency (per team per week, flag vs own 4-week trailing average). Lead time for changes (commit to production, p50/p95). On-call pager volume (sum of pages per shift per team; red = teams over threshold, p.19 example "> 5/shift")|PR cycle time, lead time by stage, flaky test rates|
|R Reliability "Are we delivering on our promises to customers?" (p.10-11)|Curated functional SLOs pass/fail ("do not average SLOs", red = any breached). Sev0/Sev1 count (red = Sev0 [garbled, presumably >0] or Sev1 trending up)|MTTR, change failure rate, SLO coverage (% of Tier 1 services), error budget burn rate (50% used in 10 days of 30 = 1.5x)|
|I Initiatives "Are our org-wide engineering investments making progress?" (p.11-12)|Tier 1 non-product initiative milestone completion rate (per initiative, compute from raw totals). OpEx action item completion rate|Tier 2+ initiatives, age of OpEx action items|
|V Vigilance "Are we actively defending our systems and managing our acceptable risk?" (p.12-13)|Open Critical/High fixable CVEs (red = past [N] days/SLA). Assets not meeting minimum compliance/security bar ("usually a scorecard"). Orphaned assets (no valid owner; unverified counts as orphaned)|Open Medium/Low CVEs, vulns breaching SLA, unverified assets (owner not re-verified within e.g. 6 months)|
|E Efficiency "Are we allocating resources to the right problems?" (p.14)|Cloud spend vs budget (raw and %). AI/LLM token costs (internal agent spend; "You do want this to be non-zero"). % capacity on innovation vs KTLO|Infra utilization rate|

Factory-spectrum metrics (§3.4, p.16-17): total diffs / R&D members (team level only); % PRs merged with no human review; change failure rate OR PR revert rate; defect backlog OR Medium+ bug resolution time. Adoption (p.15): start with Delivery + Reliability.

**OpEx review** (§4.2, p.20-23):
- Cadence: weekly or biweekly, "cannot be moved or cancelled". Startup format 60 min; local team format 30 min.
- Inputs: automated DRIVE report (red/yellow/green rollup, raw numbers, drill-down). Needs mappings service to team, domain, tier, SLOs, repo, deployments, security project, cost tag (§4.1.1, p.17).
- Attendees: VP Eng, EMs, Staff+, off-going on-call, facilitator as "auditor".
- Agenda: wins (5), prior action audit + upcoming changes (10), scorecard exceptions + Sev0/1 readouts + pager noise (25), on-call sentiment (10), action items and owners (10).
- Outputs: owned action items, "tactical resource re-allocation (time, people, money)".

## 2. Claims and numbers

Almost no data of its own.
- "The Cortex 2026 Engineering Benchmark Report found that as PR throughput increased, incident volume rose in parallel." No figures. Human code review is "already becoming unsustainable" (§1, p.2).
- Fin (Intercom) "saw a 3x improvement" in diffs per R&D member (§3.4, p.16). The cited post is titled "2x - nine months later".
- "Teams of 50 are producing the same volume of code as a team of 100+" (§5, p.24).
- Enterprise format from "roughly 150-250 engineers" (§4.2.3, p.23).

## 3. Mechanisms worth borrowing

1. **Stop-the-line** (jidoka/andon, §1.1, p.3) → steward gate. If any functional SLO is red, a Sev0-class Issue is open, or reverts in 7 days exceed N, the queue dispatches only heal/fix Issues and upkeep pauses.
2. **Binary functional SLOs** (§3.2.3) → `slos:` list of user-journey probes in `project.yaml`. Scorecard: count of failing repos (worst-case).
3. **Incident count as Goodhart guard** (p.11) → pair "Issues closed" with "recurred or reopened within 7 days". Tests dedup and learning quality, uncovered by DRIVE.
4. **Revert rate / change failure rate grades the gates** (§3.4) → % of lead-shipped changes followed by a revert or hotfix Issue within hold window and 7 days. Headline metric.
5. **Defect resolution time, lead time p95, deploy frequency** (§3.4, §3.2.2) → open Issues by age, p50/p95 time from signal to production-check-passed per class (healed, led), deploys per repo per week. The 4-week baseline is noise at low volume; add a minimum-count guard.
6. **Pager volume** (§3.2.2) → human-interrupt count per week. **Paging-event audit** (Google, §2.3) → steward lists missed alerts and noisy monitors, feeding dedup labels.
7. **Action item completion + age** (§3.2.4, "guards against the OpEx process becoming just a metrics review") → steward findings stored as action items (owner, due) in Postgres. Scorecard: open count, oldest age. Best fit.
8. **Initiative completion** (§3.2.4) → upkeep campaigns: done/total repos per campaign, `tier` field.
9. **Baseline conformance, orphans** (§3.2.5) → scorecard checks each repo against the make contract and `project.yaml` schema. "Unverified = orphaned" becomes `verified_at`: no passing `make verify` in N days.
10. **Capacity efficiency** (§3.2.6) → window utilization. Too low is wasted Max capacity, too high is throttling (paper: "non-zero"). Label Issues by class for an innovation vs KTLO share.
11. **Facilitator cross-checks** (§4.2.2, p.20: SLOs healthy yet a 15-minute outage reported) → steward contradiction queries: monitor green but Issues open, closed without evidence.
12. **Exceptions-only** (p.22) → daily steward report lists red items and wins only.

**Does not transfer:** team/domain/VP rollups, the 150-250 split, open invites, the Wheel, rotating chairs, sentiment surveys, human owner re-verification. Diffs per member (Fin 3x) is unsuitable because the measured agent writes the diffs, so Goodhart bites hardest. "% PRs with no human review" is about 100% by design.

## 4. How Cortex is built

The paper says nothing about DBOS, any workflow or durable-execution engine, Postgres or agent architecture. Only marketing-level claims:
- "Engineering Operations Platform that runs mission control for the AI Software Factory" (p.26).
- Service catalogs with "native data mapping and ownership", ownership reassignment, validation and recurring verification (§4.1.1, p.18).
- Scorecards evaluating assets against compliance baselines (§3.2.5); a dashboard "powered by a catalog-like system" with recursive rollups (§4.1.2).
- No implementation detail on initiatives or scorecards.

## 5. Challenges to the factory design

- **Human review.** The OpEx review is "one of the only human-in-the-loop backpressure mechanisms", and the main defense against Goodhart is "humans actively interrogating the data" (§3.1, §4.2). The steward is an agent grading its own factory. Feed it independent data (monitors, git, billing, not lead self-reports) and give Johannes a weekly exceptions digest.
- **Verification.** "AI makes it easier to write automated tests that give you a false sense of confidence" (§3.2.3, p.10). `make verify` is repo-authored; add journey probes the lead does not write.
- **Metrics.** DRIVE grades outcomes (SLOs, Sev0/1), not process counts. Auto-heal and runbook counts are vanity unless tied to recurrence and revert rates.
- **Speed and intake.** "'Slow down and be careful with AI' is the wrong response" (§5). The factory's only brake is subscription windows; the paper notes capacity used to throttle "ship everything" desires (§3.2.1.1) and that DRIVE does not judge "the right thing", so request intake needs its own gate.
- **Cadence and cost.** The paper wants a fixed weekly rhythm; a daily steward risks noise, so run daily exceptions and a weekly full scorecard. Token spend is framed as runaway risk; under flat subscriptions the risk is exhausted or idle windows.
