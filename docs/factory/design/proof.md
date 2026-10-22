# Proof — draft 1 (Phase 6)

Evidence that is neither the owner's opinion nor the designer's. Report section 7 is built from
this file. Numbers marked ⟨…⟩ fill from the backtest and the gameday run.

## 1. Backtest on the golden set

Pre-registered before any label existed (`evidence/golden/PREREGISTRATION.md`, committed first):
grouping B-cubed P ≥ 0.90 and R ≥ 0.80 and F1 above today's warden; escalation recall 1.00 on
genuine owner decisions, precision ≥ 0.80; owner-touch share ≤ 1 %; known-error match ≥ 0.50 with
≤ 0.05 false matches. Rules fitted on even chunks, scored once on odd chunks. Result: ⟨spike 3⟩.

## 2. Gameday catalogue — failure modes from this estate's own history

Pass criteria for every row: the failure arrives through its primary source with source time,
becomes one incident, heals or is routed without an owner touch (except where the row says a
present human is physically required), and closes on an observation.

| # | Failure mode (history) | Injection | Expected path | Pass | MTTR target |
|-|-|-|-|-|-|
| 1 | Crashed, stays-down container (glance baseline run) | `docker stop` a non-critical container | Kuma webhook → `health.down` → known-error recipe *restart* → health green → condition resolved | 0 owner touches, 1 incident, 0 pages | ≤ 5 min |
| 2 | Clean VPS reboot (10-17: 7.9 min, 18 pages) | replay the 10-17 event stream into the new intake in shadow | topology fold under host `vps` → one candidate → recovered inside the window → dismissed or closed quiet | 0 pages | n/a (self-recovers) |
| 3 | Power event leaves a disk unmounted (homelab 10-21, e267) | in a scratch VM or on a spare mount: unmount a non-critical volume | `infra.mount` condition → runbook (mount, verify, restart dependents) | 0 owner touches | ≤ 15 min |
| 4 | Disk floor during builds (mini, 365 GiB freed by hand) | `mkfile` a large file in scratch until the floor trips; delete after | `infra.disk` → disk-sweep runbook → floor restored | 0 owner touches | ≤ 30 min |
| 5 | Credential expiry (secrets cache, Claude auth, GitHub token) | point a non-critical consumer at an expired test credential | `auth.expired` condition 7 days ahead; biometric renewal batched into one weekly ask | ≤ 1 batched owner action per week | lead time ≥ 7 d |
| 6 | OpenCode server restart kills episodes | restart agw's OpenCode server during a non-critical investigate | attempt stalled → Witness re-drives from the session/hook | 0 owner touches, 0 duplicate PRs | ≤ 10 min |
| 7 | herdr crash | crash a dedicated `herdr --session gameday` with two test agents | panes restored, agents resumed by session id, shells re-driven | 0 owner nudges | ≤ 10 min |
| 8 | Quota exhaustion | feed the quota guard 95 % in shadow | non-urgent spawns flip to IU; parked agents get a resume timer at the reset | 0 owner nudges | resume ≤ 5 min after reset |
| 9 | Agent parked by a transient API error (26 owner `continue`s) | inject an API-error stop in a test pane | Witness auto-continues after backoff | 0 owner nudges | ≤ 5 min |
| 10 | Failed deploy | merge a deliberately failing change to a canary project | post-deploy verify red → automatic revert (squash) → redeploy → green | 0 owner touches | ≤ 15 min |
| 11 | Broken dependency | Renovate-style bump to a known-bad version in a fork | CI or holdouts red → never merged → Task filed | not merged, 0 owner touches | n/a |
| 12 | Flaky CI | a test failing 50 % of runs | one rerun on the same SHA; second red → revision | 0 owner touches | ≤ 1 rerun |
| 13 | Mini outage (dead-man) | stop the mini's heartbeat push for 20 min | VPS dead-man pushes to the phone; Argo shows "unreachable since" | push ≤ 15 min | n/a |
| 14 | Silent collector death (usage-tracker blind since 10-14) | point a collector at a moved store in scratch | staleness condition within one cadence | detected ≤ 1 cadence | n/a |

**Baseline run against today's system (row 1)** — `evidence/gameday/2026-10-22-glance.out.md`, fault
2026-10-22 09:13:44Z, `docker stop glance` on the homelab (warden W8's Phase 0 changes live):

| Step | Today | Under the design |
|-|-|-|
| detection | Kuma webhook event at **+6.8 min** (monitor interval and retries) | Docker `stop`/`die` event from the host recorder within seconds (W3); Kuma as the second source |
| item / incident | one item at **+10.5 min**; the Slack Down copy folded as a duplicate (Phase 0 fold works) | one incident |
| remediation | **none** — no dispatch, no operation; the item sat `new` | known-error recipe *restart*, rate-limited (ADR-012) |
| recovery | **not healed**; restored by the gameday script at +30 min | health green and the condition resolved on observation |
| closure | item closed `quiet` 10.5 min after the restore (poll cycle); Slack Up ignored | on the next reconcile after health is green |
| owner | 0 pages, 0 touches — but the service stayed down until a human-equivalent restored it | 0 pages, 0 touches |

MTTR today: unbounded without a human. Row 1's ≤ 5 min target holds only with the Docker event
recorder; the Kuma path alone spends ≈ 7 min on detection.

## 3. Factory KPIs and SLOs — read-only scripts, nothing in the loop can edit them

Scripts live in `evidence/kpi/` (and move to a `factory-kpi` repo the loop cannot write); each reads
the ledger or its snapshot read-only. Error budgets are per 28 days.

| SLI | Baseline (14 d unless noted) | Target | Error budget |
|-|-|-|-|
| Autonomy: items with no owner touch | 64.3 % | SLO ≥ 99 % (stretch 99.9 %) | 1 % of items |
| Genuine share of escalations | ⟨golden set⟩ | ≥ 90 % | — |
| Owner pages (all owner-facing notifications) per week | ⟨from `owner_pages`⟩ | ≤ 2 | — |
| Time to resolve, median / p90 | 0.7 h / 14.9 h | ≤ 0.5 h / ≤ 4 h | p90 breach ≤ 2 per 28 d |
| Reopen rate | 10.4 % | ≤ 5 % | — |
| Regression rate (fix recurs ≤ 30 d) | 10.4 % (5 / 48) | ≤ 5 % | — |
| Change failure rate (attributed) | 2.0 % | ≤ 5 % | — |
| Revert success when post-deploy verify fails | 0 % (structural) | 100 % | 0 misses |
| Owner `continue` nudges | 50 in 45 d | 0 | — |
| Finished-but-open tabs > 24 h | 2 (+2 dead `--bg`) | 0 | — |
| Max 7-day window ≥ 90 % | 12 of 45 days | ≤ 2 days per month | — |
| Status questions asked outside Argo | ≈ 25 per week | ≤ 5 per week | — |
| Cost per resolved item | IU $0.36 + Max-equivalent $1.08 | tracked, no target until 8 weeks of data | — |

## 4. Holdout scenarios

Per fleet project (basalt-ui, argo, weatherorb, shutterflow, dotfiles, warden): end-to-end user
stories stored in a private `holdouts` repository that is never cloned into an agent-writable
checkout; the verifier runs them against the deployed app after every deploy and scores observed
behaviour (HTTP responses, rendered pages, CLI outputs). Workers see only pass/fail and the failing
story's title, never the scenario text. CI check: no worker transcript contains a holdout path.

## 5. Argo test

Every question of `design/argo.md` §2 answered from Argo alone within its budget (≤ 10 s), on
phone and desktop, scripted against fixtures and once live. "Left Argo to find out" is the weekly
count of status-class owner messages outside Argo (`evidence/questions/questions.py`).

## 6. CI structural checks

| Check | Fails when |
|-|-|
| One system of record per entity | a write to an entity table outside its owning module |
| Generated docs have zero drift | a generated block (AGENTS.md routing, groups.json, project registry) differs from its re-render |
| Doc-contradiction lint | a banned claim or noun appears outside its home: "control plane" for anything but Argo, model ids in prose, lane lists outside the generated block, a "never" line without a capability test or a `target` label |
| Concept budget | the glossary exceeds twelve nouns, or a ledger table maps to no noun |
| Contract tests in the producer's CI | a cross-repo promise (verb set, verdict fields, Argo action verbs) breaks in the repo that produces it |
| Manifest drift | an integration key does not resolve |
