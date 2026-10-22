# Proof — draft 1 (Phase 6)

Evidence that is neither the owner's opinion nor the designer's. Revised against panel pass 1 and
pass 2 (`panel/pass1-resolutions.md`, `panel/pass2-resolutions.md`). Report section 7 is built from
this file.

## 1. Backtest on the golden set

Pre-registered before any label existed (`evidence/golden/PREREGISTRATION.md`, committed first):
grouping B-cubed P ≥ 0.90 and R ≥ 0.80 and F1 above today's warden; escalation recall 1.00 on
genuine owner decisions, precision ≥ 0.80; owner-touch share ≤ 1 %; known-error match ≥ 0.50 with
≤ 0.05 false matches. Rules fitted on even chunks, scored once on odd chunks.

**Result for v1, the rules the backtest scored (`evidence/golden/backtest.out.md`, ADR-003):** 5 of 8
thresholds pass — B-cubed P 0.937 / 0.902 (uncertain flipped), R 0.846 / 0.881, F1 0.889 vs warden
0.744 (+0.145, CI +0.098…+0.194), owner touch 0.62 % (warden 14.09 %), known-error false match
0.007. Fail: escalation recall and precision (one genuine decision in the held-out half — the test
is underpowered, and the keyword policy overfit the development half) and known-error match 0.479.
Design response in ADR-003: typed decision class, capability limits for three of four classes,
cross-source known errors. These numbers are v1's and are credited to nothing else: the revised
rules (v2 — windows by source kind, host fold on host evidence, close-by-member) have
development-half scores only, published in ADR-003 beside v1's, and are accepted by W3's gates — a
frozen-output regression, then a blind replay (`waves.md`). Escalation recall and known-error
matching are standing SLOs, first measured on the fresh pre-registered sample at W10's gate.
Hygiene: the spike listed the positive events' ids and notes in both halves before writing rules
(disclosed in the artefact); held-out packets were not read for design.

## 2. Gameday catalogue — failure modes from this estate's own history

Pass criteria for every row: the failure arrives through its primary source with source time,
becomes one incident, heals or is routed without an owner touch (except where the row says a
present human is physically required), and closes on an observation. The MTTR column is time to
service restored. A fix closes only after the post-deploy hold of its condition type (≥ 2 × the
fingerprint's median inter-occurrence gap, ≥ 24 h for crash, OOM and flap types), and for those
types a restart counts as resolution only if the condition stays resolved through that hold; a
recipe is promoted to automatic reuse only after its hold confirms it, and demoted when a
`regression_of` points at it (ADR-012).

| # | Failure mode (history) | Injection | Expected path | Pass | MTTR target |
|-|-|-|-|-|-|
| 1 | Crashed, stays-down container (glance baseline run) | `docker stop` a non-critical container | Docker `die` event and Kuma webhook → `health.down` → two observations by different mechanisms agree → known-error recipe *restart* → health green → condition resolved after its hold | 0 owner touches, 1 incident, 0 pages | ≤ 5 min |
| 2 | Clean VPS reboot (10-17: 7.9 min, 18 pages) | replay the recorded 10-17 event stream through the new intake in event order, each piece of host evidence entering when it became observable (first Down 20:52:02, boot record 20:56:42; ADR-003) | topology fold under host `vps` (children opened before the boot record fold in by a logged, reversible `merge`) → one candidate → recovered inside the window → dismissed or closed quiet | one incident after the `merge`, no recipe fired at the unreachable host, 0 pages | n/a (self-recovers) |
| 3 | Power event leaves a disk unmounted (homelab 10-21, e267: the drive was disconnected, the page legitimate) | in a scratch VM or on a spare mount: (a) unmount a non-critical volume; (b) detach its virtual disk | `infra.mount` condition, children held while it is open. (a) runbook (mount, verify, restart dependents); (b) the mount check fails and the host watchdog reports the drive disconnected → `needs_hands` on the heads-up tier, no further mount attempt (ADR-014) | (a) 0 owner touches; (b) exactly 1 heads-up, 0 restarts of dependents, 0 breaker trips | (a) ≤ 15 min; (b) heads-up ≤ 15 min |
| 4 | Disk floor during builds (mini, 365 GiB freed by hand) | `mkfile` a large file in scratch until the floor trips; delete after | `infra.disk` → disk-sweep runbook → floor restored | 0 owner touches | ≤ 30 min |
| 5 | Credential expiry (secrets cache, Claude auth, GitHub token) | point a non-critical consumer at an expired test credential | `auth.expired` condition 7 days ahead; the biometric renewal is one present-human ask per credential expiry, scheduled from the 7-day lead and coalesced across credentials | one ask per expiry, none otherwise; ≤ 2 present-human asks per month (§3), outside the decision SLO | lead time ≥ 7 d |
| 6 | OpenCode server restart kills episodes | restart agw's OpenCode server during a non-critical investigate | worker Agent stalled → Witness re-drives from the session/hook (lease epoch fenced, counted against the Task budget) | 0 owner touches, 0 duplicate PRs | ≤ 10 min |
| 7 | herdr crash | crash a dedicated `herdr --session gameday` with two test agents | panes restored, agents resumed by session id, shells re-driven | 0 owner nudges | ≤ 10 min |
| 8 | Quota exhaustion (7-day reading ≥ 90 % on 12 of 45 days, `kpi/quota`) | replay a recorded cycle that peaked at 98–100 % through the spawner's configured guard (ADR-008 is its only statement), with per-class burn | the guard's in-cycle projection of the owner's burn crosses 100 % → running non-urgent Max agents checkpoint and park in victim order (improve, then fleet; unattended owner waves continue on IU with a Claude-class model); owner-interactive spawns and attended waves are still admitted; after the reset the admission queue resumes parked work at the forecast token rate | 0 owner interactive sessions blocked; admission never above the forecast rate (no burst at the reset); every park and resume carries its reason | n/a — rate-bound, not time-bound |
| 9 | Agent parked by a transient API error (26 owner `continue`s; 41 of the 50 nudges came from the MacBook, `questions/`) | inject an API-error stop in a test pane on the mini and in a MacBook pane | `idle.parked{reason: api_error}` → Witness nudges once with a message id after backoff (a retry first probes the pane for that id), counted against the Task budget; on the MacBook the actuator applies it while the laptop is awake, otherwise the agent shows `host_asleep since hh:mm` and resumes on wake | 0 owner nudges, 1 nudge typed | ≤ 5 min |
| 10 | Failed deploy | merge a deliberately failing change to a canary project: (a) failing post-deploy verify; (b) passing it but failing its hold, with a second change deployed on top | (a) post-deploy verify red → rollback as a Deployment operation: redeploy the last `held` Deployment by image digest, compose revision or previous launchd bundle → green; (b) hold red → the same rollback, the failure attributed by redeploying digests in order (bisect); the known-bad marker lands only on the attributed change; the git revert follows as an ordinary Change | previous held version serving, 0 owner touches, the bad version not re-shipped, the innocent change not marked | ≤ 15 min |
| 11 | Broken dependency | Renovate-style bump to a known-bad version in a fork (Renovate opens the PR; automerge is off fleet-wide) | the train runs the dependency rung — CI, holdouts, known-bad check — red → never merged → Task filed | not merged, 0 owner touches | n/a |
| 12 | Flaky CI | a test failing 50 % of runs | one rerun on the same SHA; second red → revision | 0 owner touches | ≤ 1 rerun |
| 13 | Mini outage (dead-man) | stop the mini's heartbeat push for 20 min | VPS dead-man pushes to the phone; Argo shows "unreachable since" | push ≤ 15 min | n/a |
| 14 | Silent collector death (usage-tracker blind since 10-14) | point a collector at a moved store in scratch | staleness condition within one cadence | detected ≤ 1 cadence | n/a |
| 15 | Resolver blackhole on the factory host (the mini's recurring DNS/egress failure on ≥ 15 days, 05-06 to 08-29, `incidents/` e52) | point the mini's resolver at a non-answering address, and write one ERROR log record on the mini meanwhile | heartbeat's egress probe fails → VPS receiver reads "mini alive, egress dead" → `infra.egress` → network-independent runbook (flush the DNS cache, restart mDNSResponder, fail over to a secondary resolver); worker failures while the condition is open are classed infra; the log record reaches ClickStack from the shipper's local spool once egress returns | 0 owner touches unless the runbook fails (then heads-up); worker failures count against the lineage budget, not as Task failures — 0 Task breaker trips; the log record yields exactly one Condition | ≤ 10 min |
| 16 | Attack on a public host (in scope per the brief; none recorded in `incidents/`, so the injection is synthetic) | a CrowdSec-detectable scan against a test endpoint on a public host | CrowdSec decision → `security.anomaly` Condition → block in place → condition resolved on observation (no new hits through its hold) → incident closed | block in place, incident closed, 0 owner touches, 0 pages | set from the first measured run in W10 |
| 17 | A producer that never fails (an always-green probe; incidents #2–#4: the observer was wrong, not the service) | add a probe to a scratch project that stays green when the target is stopped | the verifier watches it in a scratch window, sees no failure, and the rung stays propose-only with the gap filed as a Task | rung propose-only, Task filed, 0 owner touches | n/a |
| 18 | A Change that weakens the factory's own verifier (synthetic) | submit a Change that makes the verifier pass everything | `factory-self` class → the N-1 CI job runs the previous release's verifier and holdout suite against it → rejected | rejected, 0 owner touches | n/a |
| 19 | A crash a restart clears every time (synthetic) | a container that OOMs every 20 h | each restart resolves the condition but earns no credit until its hold passes; ≥ 3 restarts in 7 days open `lineage.breaker` → routed to investigation on a stronger engine | breaker open within 7 days instead of closing clean each time, a code-fix or infra Task filed, 0 pages | within 7 days |

**Baseline run against today's system (row 1)** — `evidence/gameday/2026-10-22-glance.out.md`, fault
2026-10-22 09:13:44Z, `docker stop glance` on the homelab (warden W8's Phase 0 changes live):

| Step | Today | Under the design |
|-|-|-|
| detection | Kuma webhook event at **+6.8 min** (monitor interval and retries) | Docker `stop`/`die` event from the host recorder within seconds (W3); Kuma as the second source |
| item / incident | one item at **+10.5 min**; the Slack Down copy folded as a duplicate (Phase 0 fold works) | one incident |
| remediation | **none** — no dispatch, no operation; the item sat `new` | known-error recipe *restart*, rate-limited (ADR-012) |
| recovery | **not healed**; restored by the gameday script at +30 min | health green and the condition resolved on observation |
| closure | item closed `quiet` 10.5 min after the restore (poll cycle); Slack Up ignored | on the next reconcile once the condition has held for its type's hold (≥ 24 h for a crash type); service restored at health green |
| owner | 0 pages, 0 touches — but the service stayed down until a human-equivalent restored it | 0 pages, 0 touches |

MTTR today: unbounded without a human. Row 1's ≤ 5 min target holds only with the Docker event
recorder; the Kuma path alone spends ≈ 7 min on detection.

## 3. Factory KPIs and SLOs — read-only scripts, nothing in the loop can edit them

Scripts live in `evidence/kpi/` (and move to a `factory-kpi` repo the loop cannot write); each reads
the ledger or its snapshot read-only. Error budgets are per 28 days.

| SLI | Baseline (14 d unless noted) | Target | Error budget |
|-|-|-|-|
| Autonomy: items with no owner touch (item and touch counted per lineage root, `evidence/DEFINITIONS.md`) | 64.3 % | SLO ≥ 99 % (stretch 99.9 %) | 1 % of items |
| Genuine share of escalations | 3.8 % (4 of 105 escalated items in the golden set, `kpi/owner_pages`) | ≥ 90 % | — |
| Owner pages (all owner-facing notifications) per week | ≈ 62 (28 d: 140 decision entries + 71 posts + ≥ 38 reminders, `kpi/owner_pages`) | ≤ 2 | — |
| Time to resolve, median / p90 | 0.7 h / 14.9 h | ≤ 0.5 h / ≤ 4 h | p90 breach ≤ 2 per 28 d |
| Reopen rate | 10.4 % | ≤ 5 % | — |
| Regression rate (fix recurs ≤ 30 d) | 10.4 % (5 / 48) | ≤ 5 % | — |
| Change failure rate (attributed) | 2.0 % | ≤ 5 % | — |
| Rollback success when post-deploy verify or a hold fails (previous held Deployment serving) | 0 % (structural) | 100 % | 0 misses |
| Owner `continue` nudges | 50 in 45 d | 0 | — |
| Finished-but-open tabs > 24 h | 2 (+2 dead `--bg`) | 0 | — |
| Owner interactive sessions blocked by the Max quota per cycle | not recorded today — measured from W4 (quota guard log) | 0 | — |
| Max lapsed % per cycle (100 − the 7-day peak at the reset) | p50 4 %, p90 30.6 % (`kpi/forecast`); 3 of 7 complete cycles peaked at 55–79 % (`kpi/quota`) | tracked; the target is fixed by the guard replay, not asserted (ADR-008); the inverse rule spends it on non-urgent work late in light cycles, when the in-cycle projection of the owner's burn leaves room | — |
| Present-human asks per month (`present_human_ask`, `evidence/DEFINITIONS.md`: biometric renewals, one per credential expiry, coalesced) | not recorded today | ≤ 2, outside the decision SLO | — |
| Decisions defaulted on expiry, split into acked and never-acked cards (ADR-014) | not measurable today (no card, no ack) | never-acked 0 | — |
| Holdout churn per product per month and the fail→update rate (an edit after a failing story; ADR-012) | no holdouts today | churn tracked; an edit without a plan item 0 | — |
| Status questions asked outside Argo | ≈ 25 per week | ≤ 5 per week | — |
| Cost per resolved item, per action class × engine, attributed through Agent records | IU $0.12 per resolved item, Max $0 in the post-10-15 regime, all classes (W43, `kpi/cost`); per class × engine from W4 (`cost.py` re-cut from the post-10-15 regime); the 14 d mixed-regime $0.36 IU + $1.08 Max-eq is not a baseline | budgets count engine-tagged tokens per session — Max % and dollars are display only; interim ceiling 3 × baseline p90 per class, fed to the lineage budget; a class or engine with no baseline (Max after 10-15, mother wakes, herdr OpenCode tabs) starts from the measured p90 of W4's first week × 1.5; the 8-week revisit tightens both | — |

## 4. Holdout scenarios

Per fleet project (basalt-ui, argo, weatherorb, shutterflow, dotfiles, warden): end-to-end user
stories stored in a private `holdouts` repository that is never cloned into an agent-writable
checkout; the verifier runs them against the deployed app after every deploy and scores observed
behaviour (HTTP responses, rendered pages, CLI outputs). Workers see only pass/fail and the failing
story's title, never the scenario text. CI check: no worker transcript contains a holdout path.
Mothers draft each set (D4); a set binds 7 days after submission, and binding gates only that
project's switch from propose-only to auto-ship — W5's gate runs on drafted sets and records their
binding date.

- **Update path:** a holdout changes only through a Change to the holdouts repo, authored by a
  verifier-role agent that sees the approved plan Artifact, never the product diff; each
  Verification record stores the holdouts sha that gated its deploy.
- **Absent evidence fails closed:** `warden manifest check` computes effective autonomy per
  (project, action class); a rung whose evidence has no producer (no probe, no deployed app, no
  holdouts) drops to propose-only and files the gap as a factory Task; it flips back when the
  producer exists. A producer counts only after the verifier has watched it fail: a fault injected
  in a canary or scratch window turns it red, recorded as a Verification.
- **Substitute producers** where no deployed app can exist: a library — consumer-build holdouts
  (argo and weatherorb built and tested against the candidate basalt-ui); infra — a dry run plus a
  plan diff; tooling without a runtime (dotfiles) — the test suite plus a canary run; warden —
  `factory-self`. A propose-only PR whose gap stays open closes after 14 days with its Task kept;
  the owner never merges it.
- **`factory-self`:** changes to the ship path, verifier, holdout runner, breaker and rollback, and
  Changes that add, remove or weaken an evidence producer (probes, monitors, verify commands,
  rollback references), are verified by the previous release — N-1 is a CI job that runs the
  previous release's verifier and holdout suite against the Change, with no second installed
  release. A small independent watchdog rolls warden back to its last held release, because a bad
  warden deploy cannot be trusted to roll itself back.

## 5. Argo test

Every question of `design/argo.md` §2 — the 27 canonical questions, B1–B3 and P1 — answered from
Argo alone within its budget (≤ 10 s), on phone and desktop, scripted against fixtures and once live,
with one fixture per read model whose source is stale (the stale term must render, never the old
value). Three more fixtures:
- `intents_recent` with one intent ended `rejected` and one `expired`: P1 is answered from Home in
  ≤ 5 s.
- A property test over Home's situation function: every combination of decision open, production
  incident past or inside its budget, non-production incident, parked with a scheduled resume,
  resume failed or blocked, more than 5 working, paused project with an open Condition and a stale
  source gives one deterministic layout, and *quiet* holds when the only non-empty set is a
  scheduled resume.
- A steer to an agent that is mid-tool-call with expects-reply ends `replied`, through
  `warden agent reply`, or `expired` — never as a silent `delivered`.

"Left Argo to find out" is the weekly count of owner messages outside Argo in any of the 27 classes
(`evidence/questions/questions.py`, same numbering as `design/argo.md` §2).

## 6. CI structural checks

| Check | Fails when |
|-|-|
| One system of record per entity | a write to an entity table outside its owning module |
| Read-model lineage | a field of a read model in `design/argo.md` §2 resolves to no event kind with exactly one writer module (`agent.replied` → `warden agent reply`), and the model is not labelled a live probe |
| Generated docs have zero drift | a generated block (the per-repo AGENTS.md block, the global routing rules file, groups.json, project registry) differs from its re-render |
| Doc-contradiction lint | a banned claim or noun appears outside its home: "control plane" for anything but Argo, model ids in prose, lane lists outside the generated block, task state (a tick or status marker) in a tracked file, a `--flag` in a SKILL.md or AGENTS.md that the named CLI's schema snapshot lacks (ADR-004), a "never" line without a capability test or a `target` label |
| Concept budget | the glossary exceeds eleven nouns; a ledger table is neither a noun's own table, a noun-owned one (`task_deps` is Task's, `project_runtime` is Project's) nor named plumbing (events, operations, timers, leases, deliveries); or the generated inventory — processes per host, agent-facing CLIs, stores — exceeds its cap. An *agent-facing CLI* is a binary a manifest declares in `spec.provides.clis` with `contract: agent` (ADR-004); a *store* is a persistent location the factory reads or writes — a database, an event file, a repository, a vault. Caps are today's measured count minus the cuts the design claims, measured in W12 (`waves.md`); until then they are `target`. Target shape: one factory CLI (`warden manifest …`, `warden artifact …`), every loop a phase of one warden process |
| Autonomy only lowers | a Change raises a manifest's `autonomy`, rate limits or holdout locations, a Change adds, removes or weakens an evidence producer outside the `factory-self` class, or a `factory-self` Change is verified by anything but the previous release |
| Expand/contract only on the auto rung | an auto-rung migration's expand step fails the previous release's tests against the migrated schema |
| Holdout edits | a holdouts-repo Change is authored outside the verifier role or links no approved plan Artifact |
| Contract tests in the producer's CI | a cross-repo promise (verb set, verdict fields, Argo action verbs) breaks in the repo that produces it |
| Manifest drift | `warden manifest check` fails: an integration key does not resolve (the full list is in `design/model.md` §6) |
