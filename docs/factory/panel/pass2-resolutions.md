# Panel pass 2 — resolutions

Pass 2 (raw outputs in `panel/pass2/`) re-checked pass 1 — 21 resolved, 63 partially, 1 not — and
raised 76 new objections (12 blockers, 53 majors, 11 minors). Most *partially* verdicts are
carry-through gaps: an ADR changed, but `loops.md`, `model.md`, `waves.md` or the pictures did not.
Revision 2 fixes every carry-through gap the pass-1 statuses name, and applies the decisions below.
Rule adopted from sim-1: **each fact is stated once** (model or loops); ADRs and report sections link.

## Blockers

| Id | Resolution |
|-|-|
| cor-1 | **Changed.** W3 gate (a) becomes a fixture regression: live correlator output equals `backtest.py` v2's frozen output on all 959 events. ADR-003 publishes v2's development-only scores beside v1's held-out scores and stops attributing v1's numbers to the revised rules. |
| cor-6 | **Changed.** The fresh sample's unit is correlator-independent: stratified time windows per source × host, weights from that design. Cross-burst gold comes from a blind labeller searching ±7 d for the same subject, topology ancestor or fingerprint — never along warden entities. |
| cos-7, cos-9, cos-10 | **Changed.** The static reserve goes: the guard projects the owner's in-cycle burn (p90 rate × hours to reset), which shrinks toward the reset, so the inverse rule can fire late in light cycles. Victim order inside owner-started work: interactive > waves he is attending > unattended owner waves > fleet > improve; at a trip, unattended owner waves continue on IU with a Claude-class model instead of parking. The spillover is priced in D2. |
| dat-9 | **Changed, no new noun.** Intents are owner events with a lifecycle on their target entity (`intents_recent` derives from them); the breaker is a Condition `lineage.breaker` (subject = lineage) opened and closed on observation by a factory-self reconciler; budgets are counters derived from events per Task and lineage; a known-bad version is a `fail` Verification on (target, artifact digest) that the ship loop checks before deploying. |
| dur-1 | **Changed.** `rd` fails closed for every spawn carrying a `task_id` and for every spawn in adopt mode; the spool exists only for the owner's manual `rd wave` sessions without a task; each spool line carries a client uuid and replay records an observed Agent (adopt), never a spawn. W4's gate says so. |
| dur-2 | **Changed.** The same hook is granted to a successor only after the predecessor is confirmed dead (pane process tree killed, verified via herdr and `ps`); otherwise the successor gets a fresh worktree on a new branch cut from the ledger-recorded sha. A per-worktree pre-push hook calls `warden lease check --epoch`; commits carry `Factory-Agent` and `Factory-Epoch` trailers, and the train merges only heads pushed under the current epoch. |
| mig-1 | **Changed.** W3's grouping acceptance is a replay: a never-labelled window of recorded primary-source history (Kuma webhook rows since 10-16, HyperDX alerts, Docker events after `AS_OF`, the 10-17 burst), labelled blind; the comparator is old warden's recorded grouping of the same signals. Size and frame are fixed by a dated pre-registration amendment before any label exists (cor-7). |
| mig-2 | **Changed (premise corrected).** OpenCode on the mini already loads agent-gateway's MCP (`config/opencode/mini.json`), so lanes B and C stay on OpenCode/IU; W1's consumer inventory proves before day 1 that every lane engine runs `/check`, `/review` and the wave skill end to end; a lane that fails falls back to Claude Code on the IU endpoint (`ca`) — stated as a tradeoff, not a gate. |
| sre-1 | **Changed.** W3 ships the mini's logs (`~/Library/Logs`, Hermes, agent-gateway) to the VPS ClickStack through an OpenTelemetry collector's file receiver, so the log adapter has live input from day 5; log-sourced conditions resolve by quiet: no new occurrence for their type's hold. |
| ux-1 | **Changed.** A MacBook actuator, part of the MacBook herdr observer, pulls resume, steer and stop intents from the mini when online, applies them to the local herdr and acknowledges; while the laptop sleeps those intents stay queued (`host_asleep since hh:mm`) and expire on their budget. Shutterflow's fleet stays where its work is. |
| ver-1 | **Changed.** Deployment splits `verified` (post-deploy checks passed) from `held` (its hold confirmed it); the rollback target is the last `held` Deployment; a hold failure rolls back to it and attributes the failure by redeploying digests in order (bisect); the known-bad marker lands only on the attributed change. |
| ver-2 | **Changed.** An evidence producer counts only after the verifier has watched it fail (a fault in a canary or scratch window turns it red, recorded as a Verification); Changes that add, remove or weaken a producer (probes, monitors, verify commands, rollback refs) join `factory-self`. |

## Majors and minors

| Id | Resolution |
|-|-|
| cor-2 | **Changed.** The per-kind rule is written in the code's parameters: stateful = subject state with `w_open` / `w_reopen`, closed by recovery; stateless = `w_dedup`-bounded. |
| cor-3 | **Changed.** Stateless dedup is window-bounded even while an incident is open; later occurrences start a new candidate; the Condition key includes the fingerprint class, so two causes on one subject are two conditions. |
| cor-4 | **Changed.** Split rule: when every other member has resolved and one is still open after its type's hold, it splits into a new incident. Members without a condition type (chat, requests, issues, log lines) join only by an explicit, reversible edge. |
| cor-5 | **Changed.** A logged, reversible `merge` folds open child incidents under a host incident when host evidence arrives late. |
| cor-7 | **Changed.** A dated PREREGISTRATION amendment, written before any post-cutover label: frame and unit (cor-6), ≥ 400 elements, ≥ 30 decision candidates for escalation, blind packets, comparator (mig-1); thresholds unchanged. |
| cos-11 | **Changed.** ADR-008 is the only statement of the guard; loops §7 links to it; parameters live once in the spawner's config with a generated doc block; W4's gate tests that version. |
| cos-12 | **Changed.** The rewrite program is unattended owner work in the victim order: lane A takes Max while the forecast allows and continues on IU with a Claude-class model at a trip. |
| cos-13 | **Changed.** Two meters: D1 covers factory-originated IU only (base ≈ $28/week, agw OpenCode) and is stated in mother wakes per day; owner-started spillover to IU is priced in D2. |
| cos-14 | **Changed.** W4 sets the per-wake budget at the measured p90 × 1.5 after the first week; the wake rate becomes the planner's measured trigger rate. |
| cos-15 | **Changed.** Budgets count engine-tagged tokens per session; Max % and dollars are display only. |
| cos-16 | **Changed.** 204 % leaves the headline (it spans two resets) and appears only as "burn rate across two resets"; D2 becomes a priced choice — the next tier's price, which the owner reads from his account, against the measured IU spillover. |
| dat-10 | **Changed.** PLAN.md holds task ids only, written once through a normal Change; task state is never materialised in git — Argo and `warden task` render it. |
| dat-11 | **Changed.** *Item* is defined by lineage root; `emit()` enforces `correlation` = root id on every event; owner touch is counted per root. |
| dat-12 | **Changed.** Every loop decision is an event carrying its outcome and reason (`incident.member_added{rule, ancestor}`, …); read models replay decisions, never re-evaluate policy. |
| dat-13 | **Changed.** Adapters for `job.ran` (jobrun), `update.available` (a daily poll) and `config.observed` (versions, routing); any read model left without an event source is labelled a live probe, not a projection. |
| dat-14 | **Changed.** `runtime[].artifact {image, compose, launchd}`; Deployment records the immutable reference (digest, compose revision, bundle hash). |
| dur-3 | **Changed.** Deploys run detached under `jobrun` with a per-target lock and a start record; the probe reads lock held → wait, lock stale → deployed version. |
| dur-4 | **Changed.** Decision and heads-up pushes are at-least-once (pending → accepted, retried until the push service accepts), de-duplicated on the phone by event id. |
| dur-5 | **Changed.** Adoption covers agent-gateway jobs still in flight (results adopted by old item id), live herdr tabs and the Argo action queue. |
| dur-6 | **Changed.** Every key kind appends a per-entity attempt counter from `operations`, read in the same transaction. |
| dur-7 | **Changed.** Branches and PRs are keyed by Task (`factory/<task>`, `factory/<task>-<k>` after a forced fresh branch); agent and epoch travel as commit trailers. |
| dur-8, ux-5 | **Changed.** Messages go to the agent's hook inbox; Witness nudges once with a message id (`rd say` probe-before-retry on that id); the agent answers with `warden agent reply`, which produces `agent.replied`. |
| dx-1 | **Changed.** W8 and model.md carry the global routing file; W8's gate is spike 4's long-job probe passing without the policy sentence. |
| dx-2 | **Changed.** `config/factory/manifests.lock` (repo → default-branch blob sha) is committed with every render; renders read only those blobs. |
| dx-3 | **Changed.** `warden manifest draft` is a standing reconcile mode that observes compose labels (`factory.project`), launchd labels and Kuma monitors and proposes manifest Changes. |
| dx-4 | **Changed.** The settings template raises Claude Code's Bash timeouts (exact env names verified through `/research` at implementation) and the session hook sets the CLI wait budget just below them. |
| dx-5 | **Changed.** Contract item 9: every request carries the contract sha; a mismatch answers with the domain error `contract_mismatch`. |
| dx-6 | **Changed.** `product_surfaces` is derived per type (route trees, store-metadata directories, pricing files, public doors); the manifest field only adds or excludes. |
| dx-7 | **Changed.** Contract scope comes from manifests: `spec.provides.clis[{name, contract: agent | passthrough}]`; the suite fails on an undeclared `~/.local/bin` entry. |
| int-8 | **Changed.** "Traces to the owner" is a ledger fact: the lineage holds an event with actor `owner` (a submitted brief, or a comment or resolve on the plan Artifact). |
| int-9 | **Changed.** W10's gate ships one item per improve class end to end with its Verification records, plus gameday row 16: a CrowdSec-detectable scan against a test endpoint → `security.anomaly` → block → resolved. |
| int-10 | **Changed.** W9 is specified like W1–W3: ADR-006's steps, the mini's logs and host metrics in the VPS ClickStack, the settings fix; gate: one gameday item traced end to end. |
| int-11 | **Changed.** The cross-source known-error fix is a W3 bullet; known-error match ≥ 0.50 and escalation recall on the fresh sample join W10's gate as the standing SLO's first measurement. |
| int-12 | **Tradeoff.** Biometric renewals are physical presence, not decisions: one ask per credential expiry, scheduled from the 7-day lead and coalesced, counted as a separate KPI (present-human asks per month, ≤ 2), outside the decision SLO. |
| int-13 | **Changed.** D4's default starts at W5; §1b states that restarts and producer-backed config ship automatically from W5 (day 11) and fleet code fixes once their holdouts bind (≈ day 18). |
| int-14 | **Changed.** model §6.1: artifact versions committed by the submitting agent; threads live in the ledger; verdict lines aligned. |
| mig-3 | **Changed.** The quota rule is inverted: at a 7-day reading ≥ 80 % lane A continues on IU; lanes B and C never pause for Max; IU spend of the rewrite is logged against D2's spillover line. |
| mig-4 | **Changed.** W2 splits: W2a (schema, manifests with topology and `spec.commands` for repos with production runtime units, `warden manifest check`) on days 1–2; W2b (the remaining repos and the rendered registries) later in lane B. |
| mig-5 | **Changed.** Named horizons: the old `rd` and agent-gateway's MCP server stay on disk until W12 closes; rollbacks state their cross-lane effects. |
| mig-6 | **Changed.** W5's gate runs on drafted holdouts and records their binding date; binding gates only each project's switch from propose-only to auto-ship. |
| mig-7 | **Changed.** W1's inventory lists active owner waves and live herdr agents; a rewrite wave landing in a repo with an active owner wave works in a worktree with a declared merge order. |
| mig-8 | **Changed.** W1 splits into W1a (stop, archive, fresh ledger, import from the frozen snapshot plus a recorded delta, CLI read verbs) and W1b (effect registry, epochs, kill harness against real-shaped adapters); the calendar is re-planned from W1a's measured rate. |
| sim-1 | **Changed.** Each fact stated once; the diagrams are re-rendered from the revised text. |
| sim-2 | **Changed.** "Agent-facing CLI" and "store" are defined; caps = today's measured count minus the cuts the design claims, measured in W12. |
| sim-3 | **Changed.** A lead is a mother wake scoped to one plan — the same identity and hook mechanism — woken for re-sequencing or a conflict a worker returned; Tasks are claimed only through the ready queue and `rd`. |
| sim-4 | **Changed.** The quota guard, the per-mother and lineage budgets and the admission order fold into one admission module in the spawner; the breaker and per-action rate limits stay on the ship side. |
| sim-5 | **Tradeoff.** N-1 becomes a CI job running the previous release's verifier and holdout suite (no second installed release); the small independent watchdog that rolls warden back to its last held release stays — a bad warden deploy cannot be trusted to roll itself back. |
| sim-6 | **Changed.** Slack leaves the effector list; a briefing is the Home digest plus one push with an audio link. |
| sre-2 | **Changed.** The factory's own services (agent-gateway, Hermes, warden) get verified evidence producers first in W3, so their fixes do not sit propose-only. |
| sre-3 | **Changed.** Child recipes stay held while the host condition is open and until host reachability and mount checks pass; the host runbook runs first. |
| sre-4 | **Changed.** Kuma group monitors are topology parents (their state is derived from their children), never subjects of their own conditions; the drift check maps them. |
| sre-5 | **Changed.** The two observations must use different mechanisms: a Kuma docker monitor and the container's own healthcheck count as one; the second must be a functional probe or evidence of recent work. |
| sre-6 | **Changed.** W3 retires Watchtower for factory-managed containers (RollHook or WUD with recorded intent); a container replaced without intent is recorded as an unplanned Deployment from Docker events. |
| ux-2 | **Changed.** *Parked, resume scheduled* is an ambient count on line 1; *parked, resume failed or blocked* takes a slot; *quiet* means no open decision, no production incident past its budget and no failed resume. |
| ux-3 | **Changed.** W3 ships a minimal read slice — `warden status --json` and one Argo stub page (open incidents, decisions, freshness) — so days 5–16 are visible. |
| ux-4 | **Changed.** Pause stops actions only (observation and Conditions continue), takes an optional `until` shown on line 1 (without one, its age is shown); one definition in ADR-015, linked from the rest. |
| ux-6 | **Changed.** `intents_recent` read model; non-applied end states appear once in *Since you left*. |
| ver-3 | **Changed.** Substitute producers per runtime kind (library: consumer-build holdouts; infra: dry run plus plan diff; tooling without a runtime: test suite plus a canary run); a propose-only PR whose gap stays open closes after 14 days with its Task kept — never merged by the owner. |
| ver-4 | **Changed.** Renovate automerge is off fleet-wide; Renovate opens PRs and the train merges them through the dependency rung. |
| ver-5 | **Changed.** For crash, OOM and flap types a restart counts as resolution only if it holds for the type's hold (≥ 24 h); ≥ 3 restarts in a lineage within 7 days open its breaker and route it to investigation. |
| ver-6 | **Changed.** Budget and restart-lineage counters land in W3/W4 beside what they bound; effective autonomy, rollback references and `factory-self` land in W5, before any auto-ship. |
| ver-7 | **Changed.** The breaker closes only on a held fix or the lineage's conditions resolving — never on silence; egress-classed failures count against the lineage budget but not as task failures. |

## Tradeoffs from this pass

int-12 (biometric renewals outside the decision SLO), mig-2 (OpenCode lanes with a tested `ca`
fallback), sim-5 (keep the independent watchdog). No new open decision; D1 and D2 are restated.
