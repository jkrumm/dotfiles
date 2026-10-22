# Factory rewrite — waves

The rewrite-and-cutover plan for the factory design (`report.html`, ADRs in `adr/`). It
replaces Round 5 (`docs/waves/PLAN.md` of 2026-10-21, dispositioned below). The runnable copy is
`docs/waves/PLAN.md` once Round 5 is archived; this file is the design record. Revised after panel
pass 2 (`panel/pass2-resolutions.md`): W1 and W2 are split into W1a/W1b and W2a/W2b, gates rest on a
fixture and a replay, every rollback has a named horizon. Revised again after the cross-lab review
(`panel/review-resolutions.md`): W3 and W4 are split into W3a/W3b and W4a/W4b, the legacy rollback
ends at the new ledger's first external effect, holdouts bind on measurement, and no gate is a
waiting period. `scripts/wave-gate.py` matches `Wave <number> —` headings, so the runnable copy
numbers the split waves consecutively or the parser gains the letter suffix.

**Rewrite, not co-run** (owner, 2026-10-22). The old factory layer — warden's loop, agent-gateway's
dispatch role, Argo's factory pages and snapshot pushes, Hermes' factory crons, Slack intake — stops
when its rewrite starts. Nothing runs beside the old path. A rewrite goes live when it passes its
own proof gate (fixture regression and replay, gamedays, holdouts, conformance suite, timed Argo
test). Shadow survives only as a proof method: replaying recorded history. Every wave names a
**Rollback** with a named horizon — a way back, not co-running.

**What stays up the whole time** — the construction crane, not legacy:
- **The build lane:** herdr, Claude Code, `rd`, `/check`, `/review`, git, the CI runners, `make deploy`, and agw `dispatch` until W4a's worker profiles pass (it stops at the W4a cutover). Each piece is replaced in one cutover that leaves it working: the new binary or skill installs beside the old one and switches by one symlink flip after its gate, at a lane barrier (below), the old one kept as the Rollback (`rd` in W4a, `/check` and `/review` in W8; horizon in *Rules*); a wave that touches one proves it still works before close-out.
- **The owner's apps and their data:** weatherorb, shutterflow, free-planning-poker, rollhook, jkrumm.com, Argo's life pages and their Postgres, the homelab and vps services.
- **Every historical store, archived read-only:** `warden.db`, agw's job store, both OpenCode stores, Hermes' `state.db`, usage.db, the human-queue, transcripts. They seed the new ledger (one-time import), the known-error store and the golden set.

**Mode:** orchestrated from an orchestrator tab in the `dotfiles` herdr workspace; each wave is an
`RD_ORCHESTRATED=1 rd wave <repo>` tab in the repo it changes most, committing to each repo it
touches separately. One active wave per repo; three lanes.
- **warden is the serial spine** (lane A): one warden wave at a time. Parallel warden work (W1b, W2a's `warden manifest` module, W2b's `warden project new`, W9, W13) runs only in a separate worktree with a declared merge order, stated in its wave and in the Calendar.
- **Active owner waves:** W1a's inventory lists them. A rewrite wave that lands in a repo with one (*Active waves* in `evidence/projects/classify.out.md`: basalt-ui, weatherorb, agent-gateway, dotfiles and warden at `AS_OF`, 2026-10-22T08:00:00Z per `evidence/README.md`) works in a worktree with a declared merge order — the rule warden already follows.
- **Every spawn names an engine `rd wave` can start.** `rd` knows two kinds, `claude` and `opencode`; it has no `ca` kind.
  - Lane A: Claude Code on Max (the default kind, `RD_WAVE_MODEL` default).
  - Lanes B and C: OpenCode on IU (`rd wave --kind opencode`).
  - W1b, and any lane that needs a Claude-class model on IU: `--kind opencode` with `RD_WAVE_MODEL` set to a Claude-class id from `agw routing`.

  A wave that needs a stronger model says why in the spawn. OpenCode on the mini already loads agent-gateway's MCP (`config/opencode/mini.json`), so `/check`, `/review` and the wave skill are reachable from every lane; W1a proves it end to end before day 1, and a lane whose engine fails is re-spawned on the other kind — a tradeoff in cost, not a gate.
- **Quota:** the rewrite is unattended owner work in ADR-008's victim order. Lane A takes Max while the forecast allows and continues on IU with a Claude-class model at a trip instead of parking; lanes B and C run on IU and never pause for Max. Until W4b ships the guard, the orchestrator tab stands in for it: at a 7-day Max reading ≥ 80 % the next lane-A spawn runs on IU (`--kind opencode`, a Claude-class `RD_WAVE_MODEL`), and a lane-A wave stalled at 100 % is re-spawned the same way (the reading sat at ≥ 82 % a quarter of the time over 43.6 days, p75, `evidence/kpi/quota.out.md`). No lane waits for Max, so the Calendar counts working days; the rewrite's IU spend is logged against D2's spillover line (report §10).

**Rules for every wave**
- Gate: `make check`, `/review` on every non-trivial diff, `make deploy`, `make verify`, and the wave's **proof gate** — a measured exit, never a waiting period.
- **Rollback:** every wave states one below its gate — the mechanism, its **horizon** and what must be rolled back first. Horizons are named, never "one wave": the legacy warden (tag, plists, archive), the old `rd`, the superseded skills, agent-gateway's MCP server and the code of the tools W8 unregisters all stay on disk until **W12 closes**, and W12's close-out deletes them. Past a horizon a rollback is a forward fix; the legacy warden's horizon is shorter than its stay on disk: it can resume only until the new ledger performs its first external effect (W1a). A wave nothing builds on is marked **Leaf**.
- **Lane barrier:** a build-lane flip (W4a's `rd`, W8's skills) happens when no wave in a rewrite lane is mid-gate, and is announced with `rd say` on the tab of every active owner wave.
- **Left behind is computed:** every open item becomes a Task with an owner (W1a's `warden task add` from day one), never a bare line. An item with no named owner defaults to the project's mother (fleet class) or the planner queue (session class).
- **homelab-private stays self-contained:** its manifest and topology live inside homelab-private; every generated output (groups, usage map, AGENTS.md blocks, rendered registries, Argo) excludes it.
- **PR-required repos go by PR** (`config/pr-required-repos.json`: basalt-ui, free-planning-poker, rollhook, rollhook-action); every other SourceRoot repo direct to its default branch.
- New CLIs and services follow the agent-CLI contract (ADR-004) from their first commit.
- Every invariant a wave adds is enforced (test, CI check, generated file) or labelled `target` (postmortem rule).

## How to start

The first three waves are runnable now; their plans are copies of the sections below (this file wins on any difference):

| Wave | Plan | Launch from the orchestrator tab |
|-|-|-|
| W1a | `warden/docs/waves/PLAN.md`, Wave 9 (active) | `RD_ORCHESTRATED=1 rd wave warden 'Read docs/waves/PLAN.md. Execute the active wave (Wave 9). Follow the /wave skill, but do NOT spawn the next wave.'` |
| W2a | `dotfiles/docs/waves/PLAN.md`, Wave 1 (active) — Round 5 archived to `docs/waves/archive/2026-10-round-5-PLAN.md` | `RD_ORCHESTRATED=1 rd wave --kind opencode dotfiles 'Read docs/waves/PLAN.md. Execute the active wave (Wave 1). Follow the /wave skill, but do NOT spawn the next wave.'` |
| W1b | the `w1b` worktree's copy of `warden/docs/waves/PLAN.md`, Wave 10, from W1a's close-out | `RD_ORCHESTRATED=1 RD_WAVE_MODEL=<Claude-class id from agw routing> rd wave --kind opencode warden 'Read ~/SourceRoot/warden-w1b/docs/waves/PLAN.md. Execute the active wave (Wave 10) in that worktree. Follow the /wave skill, but do NOT spawn the next wave.'` |

W1a and W2a run in parallel (disjoint files).

**W1b beside W3a, two warden waves at once.** `wave-gate.py` accepts one active wave per plan, and it requires the section just above it to be done. So each of the two waves runs from its own copy of the plan:
1. In master's plan, W3a's section (Wave 11) sits above W1b's (Wave 10). W3a's predecessor is then Wave 9.
2. At W1a's close-out the orchestrator runs `git -C ~/SourceRoot/warden worktree add ../warden-w1b -b w1b`. Its first commit on `w1b` moves W1b's section back above W3a's and marks it active.
3. W1b launches with the worktree's plan path. `rd` takes the first `…docs/waves/PLAN.md` path in the prompt as the gate's plan.
4. On day 5, before W3b opens, the branch merges. Master keeps its section order, and W1b's section takes the branch's checkboxes and Left behind.
 W3a (warden Wave 11) and W2b (dotfiles Wave 2) are
already copied behind them, pending; each later wave — W3b, W4a, W4b onward — is copied into its
repo's plan the same way when its predecessor closes.

## What stops when

| Old component | Stops | Replaced by |
|-|-|-|
| warden loop (intake, triage, the `decision_shadow` decide lane, merge train, notify, reminders), its push monitors and the jobrun canary's warden leg | W1a start: LaunchAgents unloaded (plists kept on disk), tag `warden-legacy`, `warden.db` archived read-only; the push monitors and the canary leg are removed | W1a ledger and the dev-host heartbeat's new-warden component, W3a intake, W3b incidents, W4a tasks, W4b agents, W5 ship |
| jobrun / `jobs-grade` `job` source into warden | W1a: findings stay WARN lines in the dev-host composite (`docs/ops-signals.md` §2) | W3a's `job.ran` adapter |
| `warden run` lane (global CLAUDE.md lane table, `rd` help, the wave skill) | W1a, one commit | `warden task add` |
| agent-gateway `dispatch` (implement, investigate) | W4a cutover — it counts as build lane until W4a's worker profiles pass | herdr workers through `rd` (W4a); investigate as a read-only worker profile on OpenCode/IU |
| agw `decide`, `triage`, `narrative`, `investigate` tools | before W8 (W8's first bullet): unregistered | correlator (W3b), investigate worker (W4a), W13's changelog rendering |
| Slack intake (warden's poller) | W1a start, with warden | primary-source adapters (W3a); raw Kuma alerts, and HyperDX re-pointed at the Slack webhook, reach the owner's Slack channel on days 1–8, until W3b opens Conditions |
| Argo `/agents`, `/warden`, overview and snapshot pushes, warden action queue | W1a: frozen (stale, no writes); W6 start: deleted | W3a's read slice (`warden status --json`, one Argo stub page) until the factory read API and write verbs (W6) |
| agent-overview pane (`make agent-overview`) | W6 | Argo's Fleet view |
| Hermes factory crons (narratives, briefing reads of `warden.db`, watchdog summary) | W1a for the `warden.db` reads (stale data); W11 for the rest | renderings of the one digest projection (W11, W13) |
| Watchtower on factory-managed containers | W3a | RollHook or WUD with recorded intent; a replacement without intent is an unplanned Deployment from Docker events |
| agent-gateway's MCP server and deferred-tool path | W8 cutover: skills stop calling it and the registration goes | CLIs + skills (W8) |
| plannotator interim backend | W7 cutover (removed at W7's gate) | `warden artifact` (the factory CLI and API) and Argo's Artifacts view (W7) |

## Calendar

{{asset:rewrite-plan}}


```
day  1   2   3   4   5   6   7   8   9   10  11  12  13  14  15  16  17  18  19  20  21  22  23  24  25  26
A    W1a W1a W3a W3a W3a W3b W3b W3b W4a W4b W4b W5  W5  W5  W6  W6  W6  W6  W6  W7  W7  W7  W10 W10 W10 W10  warden spine (Max; IU at a trip)
B    W2a W2a W2b W2b W2b ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   ·   W11 W11 W11 W13 W13 ·   ·    manifests, Hermes, brain (IU)
C    ·   ·   W1b W1b W1b ·   ·   ·   ·   ·   ·   W8  W8  W8  W8  W8  W12 W12 W12 W9  W9  ·   ·   ·   W14 W14  W1b worktree, tooling, dotfiles, telemetry, docs (IU)
```

≈ 26 working days on the warden spine (W1a 2 + W3a 3 + W3b 3 + W4a 1 + W4b 2 + W5 3 + W6 5 + W7 3 +
W10 4). Splitting W3 grows the spine by three days: the cross-lab review found one wave of 13
bullets in three days implausible (`panel/review-resolutions.md`), so intake and conditions take
three each. Splitting W4 adds none — its three days are shared by the halves in proportion to their
bullets, and the split buys each half its own rollback. The earlier splits add none either: W1b
leaves the spine and runs beside W3a in lane C as a warden worktree, and W2b takes lane B on days
3–5, while dotfiles is free until W4a holds it (day 9). **The day counts are estimates, and W1a's
close-out re-plans them.** No evidence file measures a wave of this size —
`evidence/postmortem/waves.out.json` holds 303 done waves with a cycle time, at a median of 2.4 h
from first plan commit to the commit that marks them done and 4 steps, against 4–10 bullets in each
of W1a, W3a, W3b, W4a, W4b, W5 and W8 (the W3 and W4 halves 4–8) — so W1a records its wall-clock and
bullet count (git, the herdr event record) and the orchestrator re-sizes W3a onward at that rate
before W3a opens, rewriting this block. No lane waits for Max (*Mode*), so the days are working
days of wave time, not owner time; a gate that fails extends its wave, never skips it.

Lanes B and C idle where every free wave would touch dotfiles while W4a and W4b hold it (days 9–11)
or needs a spine wave first: W8 needs W4a's cutover (agw's four tools leave its surface before it),
W11 needs W6's read API. Warden worktrees merge in this order: W2a's `warden manifest` after W1a's
close-out (day 2); W1b's on day 5, before W3b opens (day 6; its restart recipe needs the registry)
and before W4a opens (day 9); W2b's `warden project new` after W1b's (day 5); W9's after W7's
(day 22); W13's after W10's (day 26). What returns to the owner on which day: report §1b, *During
the rewrite*.

---

## Wave 1a — Stop the old loop, a fresh ledger, history imported            <!-- status: pending -->
Repo: warden (new code tree; the old loop is stopped first) and dotfiles (the lane retirement, the heartbeat component and the conformance suite's core — files W2a does not touch). ADR-011, ADR-002, ADR-004. Days 1–2, lane A. W1b branches from its close-out; W2a's `warden manifest` module merges after it.

- [ ] **Consumer inventory and lane proof first:** a generated list of every consumer of the old warden (grep of all SourceRoot repos and `docs/architecture.md` for warden, its API port and its ingest paths), each with a disposition — the known ones are the rows of *What stops when* — committed before anything stops. A consumer the list misses is a gate failure, not a Left-behind line. The inventory also lists the **active owner waves** and **live herdr agents** per repo (each repo's PLAN.md, `rd agents`), the input to the worktree rule in *Mode*, and **proves each lane engine** before day 1: a throwaway change taken end to end through `/check`, `/review` and the wave skill on OpenCode/IU and on Claude Code.
- [ ] **Stop the old loop:** tag the warden repo `warden-legacy`; unload warden's LaunchAgents and keep the plists on disk; archive `~/.warden/warden.db` read-only — `sqlite3 .backup` after the unload, an `lsof` check that nothing holds it open for writing, a recorded checksum, `chmod 444`, plus a copy in the homelab bucket via `hl`. Record what changed since the frozen evidence snapshot (`~/.local/share/factory/snapshots/2026-10-22/warden.db`, taken 07:51:56Z, `evidence/kpi/baseline.out.md`; Phase 0's drain among it) as a **delta** file beside the archive, and the live state at the stop (open items, queue, open PRs, in-flight deploys and agw jobs, operations with no outcome) as an import input. The manual build lane is untouched.
- [ ] **Monitoring never goes dark:** the dev-host heartbeat (`MacMini Dev Host - Push`, `scripts/devhost-health-check.sh`, `docs/devhost-health.md`) is kept through the stop and gains a new-warden liveness component from day 1 — the one warden process answering and `make verify`'s `integrity_check` passing — so the removed push monitors leave no unwatched stretch before W6's dead-man switch.
- [ ] **Retire the `warden run` lane** in one commit: the global CLAUDE.md lane table, `rd` help and the wave skill point at `warden task add` instead. agw `dispatch` stays in the lane table until W4a.
- [ ] **Enact W1a's rows of *What stops when*** in the stop window, each left in its new state:
  - HyperDX alerts re-pointed at the Slack webhook;
  - warden's push monitors and the jobrun canary's warden leg removed;
  - Argo's `/agents` and `/warden` pages, the overview and snapshot pushes and the action queue frozen (stale, no writes);
  - Hermes' `warden.db` reads cut;
  - the Slack poller stopped with warden.
- [ ] **Fresh ledger** `~/.warden/ledger.db` with `synchronous=FULL` (ADR-011): one table per noun and the named plumbing of `docs/factory/design/model.md` (§1, eleven nouns), the `events` log (§4), decisions with absolute deadlines. One write module per noun; `emit()` inside every state-changing transaction.
- [ ] **One-time import** (`warden import` from the frozen snapshot plus the delta — ADR-011's pure function with deterministic ids, `inc_` + hash of the old id, likewise per noun): events → Signals (source time where the payload has it, fingerprints recomputed); items → closed Incidents with root cause, fix commits and verification evidence where present (the known-error seed); transitions and notifications → historical events with actor `import`, which effectors skip from their go-live cursor, so the 577 owner-facing notifications (`evidence/incidents/incidents.md`) are never re-sent; the open `needs_decision` items (2 after Phase 0's drain) → Decisions with defaults (ADR-014), each deadline counted from go-live plus its class expiry; open work items, the four features closed as "a feature, not a fix" (1708, 1709, 1711, 1712 — Phase 0 did not re-open them) and the open Left-behind lines of every plan → Tasks with an owner (default per *Rules for every wave*) — a plan line has no old id, so its Task id hashes (repo, plan path, normalised line) and W4a's projection of the same line yields the same Task. The golden-set labels (`docs/factory/evidence/golden/labels/`) attach to the imported incidents. **The order is fixed:** stop the old loop → import into a new file → swap it in by rename → only then does the new ledger go live; no row exists in it before the swap.
- [ ] **Adoption pass** (ADR-011): probes the external state of every non-terminal old item — open PRs, in-flight deploys, in-doubt operations, **agw jobs still in flight** (each result adopted when it lands, keyed by the old item id, so the imported Task gets no second worker), **live herdr tabs** (each becomes an observed Agent) and **the frozen Argo action queue** (each pending owner action is an imported intent that ends `applied`, `rejected` or `expired(stale)`, with an event: it applies only if its target's observed state still matches the state when it was issued, and one that expired as stale shows once in *Since you left*) — and sets the new entity from what it finds (an open PR becomes a Change, a NULL-outcome operation is resolved by its probe), so the first tick spawns nothing for work already in flight.
- [ ] **`warden` CLI — the one factory CLI** — on the agent-CLI contract (ADR-004). W1a builds the Python contract library (cyclopts + pydantic) and the conformance suite's core, with warden as their first consumer; W8 adds the TS/Bun runner and widens the suite to every binary in scope. Read verbs `warden signal|condition|incident|task|decision|event list/show`, `warden task add` (bd's verbs and JSON names, ADR-001), `warden schema [cmd]`; generated `REFERENCE.md`. The lease verbs (`warden task claim|heartbeat|done`, `warden lease check`) arrive with epochs in W1b; `warden manifest …` (W2a) and `warden artifact …` (W7) join as modules; every loop runs as a phase of the one warden process.
- [ ] **Checks in `make check`:** one-writer (entity writes only from their module), projection rebuild (drop a read model, rebuild from `events`, compare), `PRAGMA integrity_check` in `make verify`. The effect-registry bypass check, the kill harness, the ledger's off-box replication and restore-as-adopt-mode are W1b's.
- [ ] **Proof gate:** every W1a row of *What stops when* is verified in its new state:
  - a test alert from HyperDX reaches Slack;
  - the removed monitors are gone from Kuma;
  - Argo serves its frozen pages;
  - a Hermes briefing runs without reading `warden.db`.

  Import reconciliation: every archived event, item and transition accounted for (script, 100 %) and the delta reconciled row by row; the import run twice from one snapshot and delta yields identical ids and row counts; the KPI scripts in `docs/factory/evidence/kpi/` re-pointed at `ledger.db` reproduce `baseline.out.json` exactly from an import of the frozen snapshot alone (the archive was taken after Phase 0's drain, so the baseline is not asked of it); the swap order held — the new file holds the import's rows and nothing else when it is swapped in; adoption on a seeded snapshot — a live agw implement job, two Argo queue entries (one whose target still matches the state it was issued against, one whose target has moved), an open `needs_decision` three days old, a plan with Left-behind lines — yields 0 extra workers, the first entry applied or rejected and the second `expired(stale)`, each with an event, the decision's deadline at go-live plus its class expiry, and identical Task counts on a second run; stopping the new warden turns the heartbeat's new-warden component red and starting it turns it green; the dormant legacy restore (below) run once and timed, before the swap, while the legacy can still resume.
- **Rollback:** check out `warden-legacy`, copy the archive back writable, re-load the kept plists; the old `warden run` lines return with a revert of the lane commit. Tested once in the gate, then the legacy stays dormant — a way back, not co-running. **Horizon:** the new ledger's first external effect, recorded when it happens (ADR-011); the dormant legacy stays on disk until W12's close. Past that moment the legacy loop would re-execute effects the new ledger already took, so a rollback is a roll-forward — a fix in the new ledger, re-entering its adopt mode — never the legacy loop. **First:** W1b and W3a, if live — W3a's rollback restores the Slack-only alert path this one assumes; a later wave's first effect closes the horizon. **Cross-lane:** rows the new ledger wrote since its go-live stay in `ledger.db`, unread by the legacy; W2a's and W2b's manifests do not depend on the loop and stay.
**Left behind:**

## Wave 1b — Effects are registered, leases are fenced            <!-- status: pending -->
Repo: warden (a worktree beside W3a, merged before W3b opens — its restart recipe needs the registry — and so before W4a opens). ADR-002, ADR-007, ADR-011. Needs W1a. Days 3–5, lane C — OpenCode on IU with a Claude-class model (`--kind opencode`, `RD_WAVE_MODEL` from `agw routing`) rather than the lane's default model: the registry, the fencing and the kill harness are the logic every later wave stands on. Gates W3b's restart recipe, W4a, W4b and W5.

- [ ] **Effect registry** (ADR-002): every external side effect goes through one module that writes an `operations` row before the call and declares one strategy, its generation key read from ledger state in the same transaction. The registry covers every effect kind the factory emits, the agent-plane ones included (spawn, `rd say` steers, Witness resume and continue, `rd close`, the integrations reconciler's creates, `hl` copies), each with a strategy in ADR-002's table. A CI check rejects external calls that bypass it.
- [ ] **Epochs** (ADR-002, ADR-007): every lease grant (task claim, agent, merge slot) issues a monotonic epoch, written into the hook; every mutating call carries it and a stale epoch is rejected. `warden lease check --epoch` is the call W4b's per-worktree pre-push hook makes; `warden task claim|heartbeat|done` (bd's verbs, ADR-001) arrive here. Git effects are fenced by `push --force-with-lease=<ledger sha>` and merge `sha=`.
- [ ] **Kill harness in `make check`:** spike 2's tests a–f and h against the primitives plus a stale-epoch call, one case per registry entry; a new flow type ships only when it passes.
- [ ] **Ledger replication:** the WAL of `ledger.db` is replicated continuously to the homelab bucket by a Litestream-class replicator, a LaunchAgent declared in warden's manifest (`research/2026-10-22-durable-await-sqlite.md` §1.8; the tool and its version are pinned after `/research` at implementation, ADR-011) — a recovery point in seconds, where a nightly copy loses up to a day of operations and owner intents. The heartbeat's new-warden component (W1a) reads the replica's freshness.
- [ ] **Replica retention:** the mini's bucket key cannot delete, so pruning of the replicated WAL runs from a key or a bucket rule that can. The rule is settled here (ADR-011).
- [ ] **Restore is an adopt mode:** after restoring the replicated copy or failing an integrity check, effects are refused until the adoption pass has probed every in-doubt operation.
- [ ] **Proof gate:** kill tests b, b_deploy and h re-run against real-shaped adapters (a scratch GitHub repo returning real 422s, counting fakes for deploy and restart) — every target counts exactly one effect; the restore drill (gameday row 20, `design/proof.md` §2) — a day of operations run against the same adapters, then `ledger.db` restored from a copy a day old, in adopt mode: 0 re-executed effects, every target still one effect, and the replica's recovery point (its lag at a kill) recorded; a stale epoch is rejected on every epoch-carrying verb; a seeded registry bypass fails `make check`.
- **Rollback:** revert the W1b merge — the registry, epochs and the kill harness leave `make check`, the replicator unloads (its replica stays in the bucket), and W3b's restart recipe is switched off with them (it has no registry). **Horizon:** day 8, before W4a opens. **First:** W5, W4b and W4a (claims, Witness actions and the train run on epochs and the registry).
**Left behind:**

## Wave 2a — Projects that run something describe themselves            <!-- status: pending -->
Repo: dotfiles (the schema), one `docs:` commit per repo (PR-required repos by PR; homelab-private's manifest inside homelab-private) and a warden worktree for the `warden manifest` module, merged after W1a's close-out. ADR-010. Days 1–2, parallel with W1a, lane B. The only prerequisite W3a and W3b take from this lane.

- [ ] `config/factory/project.schema.json` — the `factory/v1` schema of `design/model.md` §6 — and the `warden manifest draft|check|gen` module on the agent-CLI contract. `draft` is a standing reconcile mode that proposes manifest Changes from what it observes (compose labels, launchd labels, Kuma monitors), not a one-off; `product_surfaces[]` is derived per type (route trees, store-metadata directories, pricing files, public `doors[]`) and the manifest field only adds or excludes (ADR-010).
- [ ] **Manifests for the 22 SourceRoot repos that own a container, a launchd job or a Kuma monitor** (`docs/factory/evidence/signals/topology.out.json`, `projects`), each with topology and `spec.commands`: drafts from what exists (AGENTS.md *Verify & Monitor*, Makefile, `config/herdr/groups.json`, `topology.out.json`, OTel service names; class from `docs/factory/evidence/projects/classify.out.json`), reviewed and committed per repo. homelab-private's manifest and topology are committed inside homelab-private and excluded from every generated output.
- [ ] **`spec.commands{check, verify, deploy, restart, logs}`** per project, validated by the drift check (`make -n` parses, params declared) and rendered into the per-repo block. Every production runtime declares `restart`: the check lists the ones that do not and files each with `warden task add`, and a runtime without it gets no restart recipe.
- [ ] **Proof gate:** `warden manifest check` green on the 22 repos (ADR-010's W2a confirmation) — schema, every integration key resolves, every declared command parses, an availability SLO or an explicit `slo: none` on every production runtime, topology covers every running container, launchd job and Kuma monitor of those repos (each blind spot filed with `warden task add`, e.g. 19 of 36 vps services unmonitored, `docs/factory/evidence/signals/signals.md`); agent-gateway, hermes-agent and warden are among the 22 and declare `restart`; no generated output names a homelab-private entity.
- **Rollback:** revert the schema and manifest commits per repo (PR-required repos by revert PR); the warden worktree is not merged, or its module commit is reverted. **Horizon:** day 2, before W3a reads the manifests. **First:** W3b and W3a (their adapters and reconcilers resolve subjects through the topology).
**Left behind:**

## Wave 2b — The remaining repos, one-command onboarding, rendered registries            <!-- status: pending -->
Repo: dotfiles (generated outputs, registries), the other 11 SourceRoot repos, the IuRoot sources in dotfiles-private (PR-required repos by PR) and a warden worktree for `warden project new` and the integrations reconciler, merged after W1b's (its creates go through the effect registry). ADR-010. Needs W2a. Days 3–5, lane B — dotfiles is free until W4a holds it (day 9); an overrun continues in a dotfiles worktree that merges after W4b.

- [ ] **`warden project new <name> --type …`** writes `project.yaml` and the type's Makefile from a per-type template (a Makefile that holds targets is not an empty placeholder, and its `commands` parse), renders every generated file and writes the CI workflow. `integrations` are desired state: the integrations reconciler creates what it can — the GitHub repo and its protection tier (`scripts/github-config.sh`), herdr workspace, brain note stub, Kuma monitor via its API, TickTick list, runner sync, PR-required entry — and verifies what it can only observe (an OTel service seen: a Condition while the project is `experimental`, a check failure from `production`, ADR-010). A new repo is green on `warden manifest check` from that one command plus name and type.
- [ ] **Directory contract** (`design/model.md` §6.1) for every repo: `project.yaml`, `docs/waves/`, `docs/adr/`, `docs/artifacts/`, `docs/notes/`, `.factory/` ignored; holdouts never in the repo. The contract fixes locations and creates nothing empty; `manifest draft` moves nothing that tools depend on without updating them.
- [ ] Manifests for the other 11 SourceRoot repos and the 20 IuRoot repos (names only here): IuRoot drafts in `dotfiles-private/projects/<repo>/`, linked per file into each work repo and listed in its `.git/info/exclude`; one loading test fixes the IuRoot block's file name (ADR-010). Reviewed and committed per repo.
- [ ] Generated outputs v1, rendered only from the default-branch blobs pinned in `config/factory/manifests.lock` (repo → blob sha, committed with every render, advanced by the integrations reconciler): herdr `groups.json`; the AGENTS.md block between `<!-- factory:begin -->` / `<!-- factory:end -->` (manifest facts only: role, class, runtime, health, monitors, commands, directory map); usage-tracker's project map; and the registries that today live outside the manifest — `config/pr-required-repos.json`, `docs/architecture.md`'s repo and LaunchAgent tables, the `config/Caddyfile` app blocks, the runner list behind `make gh-runner-sync`. `scripts/architecture-check.sh` folds into `warden manifest check` as its machine-local leg, so one checker owns topology and `make doctor` calls it.
- [ ] **Proof gate:** ADR-010's W2b confirmation — `warden manifest check` green on every repo; generated blocks and rendered registries byte-equal to a re-render from `manifests.lock`; the directory contract holds; `warden project new` on a scratch repo (deleted afterwards) reaches green and appears in herdr groups and usage-tracker with zero hand-typed facts beyond name and type (Argo's project list is W6's); the IuRoot loading test passes for all three cases with `git status` clean; no generated output names a homelab-private entity.
- **Rollback:** revert the manifest, generated-block and registry commits per repo (PR-required repos by revert PR); the rendered registries fall back to their last hand-edited versions in git, and the warden module commit is reverted. **Horizon:** day 17, before W12 asserts byte-equality against them. **First:** W12, and W6's project registry (Argo's registry is rendered from the manifests).
**Left behind:**

## Wave 3a — Intake: Signals from every primary source, the mini's logs, a read slice            <!-- status: pending -->
Repo: warden (+ homelab, vps for the Docker event recorders and Watchtower; argo for the stub page). ADR-013. Needs W1a and W2a. Days 3–5, lane A; W3b follows on the spine, W1b runs beside it in lane C.

- [ ] Signal envelope per ADR-013; `subject` resolved through the manifests' topology; `occurred_at` is source time, never poll time.
- [ ] **Adapters**, one per primary source — every row of ADR-013's table: Kuma webhook (pairs Up with Down by monitor id), HyperDX webhook (HyperDX moves off the Slack webhook onto it when W3b opens Conditions), RollHook deploys, GitHub Actions failures and issues (`gh` poll), Beszel, HomeLab WatchDog (the observer for "device absent"), a Docker events recorder per host (homelab, vps), jobrun's `job.ran` (it takes over the old `job` source; `jobs-grade` stays the only grader), a daily `update.available` poll, `config.observed` (versions, routing), and the inputs of W4b's guard and Witness — the herdr event record (agent heartbeat, last output), `quota.sampled`, `usage.recorded`, classified `owner.message`. A read model left without an event source is labelled a live probe, not a projection. Each adapter proves itself by replaying the recorded history before it goes live.
- [ ] **Watchtower retires for factory-managed containers** (archived upstream): RollHook or WUD with recorded intent update them, and a container replaced without intent is recorded as an unplanned Deployment from Docker events, not restarted.
- [ ] **Mini logs in the VPS ClickStack:** an OpenTelemetry collector on the mini ships `~/Library/Logs`, Hermes' and agent-gateway's logs through its file receiver, so the log adapter has live input from day 5 — Hermes logs reach warden today only through the file poller that W1a stops (`hermes_log`, `evidence/signals/signals.md`). The collector is a LaunchAgent declared in warden's manifest, so the architecture tables list it; W9 adds host metrics and traces to it.
- [ ] **Log adapter** (ADR-013): alert rules on the structured severity field, never substring matches; fingerprint = logger + normalised message; the factory's own workers dropped by provenance (ADR-006's resource attribute).
- [ ] **Git/GitHub ref adapter:** emits `change.merged` for every new default-branch sha, whatever the actor; the ship loop (W5) owns only train state.
- [ ] **Read slice:** `warden status --json` and one Argo stub page with `incidents_open`, `decisions_open` and `freshness` (`design/argo.md` §3, *Before Home exists*), so days 5–19 are visible; W6 replaces both.
- [ ] **Proof gate:**
  - (a) history replay per source (ADR-013's confirmation): each adapter's replay of its recorded history, run per source against the recorded Slack copies, with missed and duplicate events counted;
  - (b) the log path to the ledger, live: one ERROR record written on the mini reaches the VPS ClickStack through the collector and enters the ledger as exactly one log Signal, and one WARNING record whose JSON body contains "ERROR" yields none (ADR-013's live test, at the Signal level);
  - (c) the stub page shows an injected incident, an open decision and a stale source as a stale term, never as its old value.
- **Rollback:** stop the new intake, the collector and the stub page; Kuma and HyperDX still post their raw alerts to Slack, so nothing else moves, and the ledger keeps the Signals already recorded. **Horizon:** W12's close — Kuma and HyperDX keep their Slack channel configuration until then. **First:** W5, W4b, W4a and W3b (they read these Signals or act on the incidents built from them).
**Left behind:**

## Wave 3b — Conditions, correlation, known errors, the restart recipe            <!-- status: pending -->
Repo: warden. ADR-003, ADR-012, loops §1–2. Needs W3a; the restart recipe also needs W1b. Days 6–8, lane A.

- [ ] Health reconciler per project (loops §1): opens and closes Conditions from the manifest's desired state and the observed state — signals, a direct probe and container-level state (`docker ps` on resync, so a lost recorder edge is still caught); resync timer plus signal-scheduled runs. **Level-triggered:** a webhook only schedules a reconcile, and every resync reads monitor state from the source — Kuma's `monitor_status` on `/metrics` or its status API, HyperDX's alert state (its read path is unprobed, so W3b probes it first, ADR-013) — so a missed webhook delays detection by at most one resync interval and never loses the condition. A log-sourced Condition resolves by quiet: no new occurrence for its type's hold.
- [ ] **Evidence producers for the factory's own services first:** agent-gateway, hermes-agent and warden each get a deploy record, a Deployment-level probe and a `restart` command, verified as ADR-012 requires of any producer, so their fixes (#7's lock, #8's log level, `evidence/incidents/incidents.md`) never sit propose-only.
- [ ] Correlator per ADR-003 with the parameters frozen by `backtest.py` v2 on the development half; known-error match against imported and new closed incidents; regression link. No single-shot decision model anywhere in the loop: judgment calls (recipe choice, `decision_class`) belong to the investigate worker on OpenCode/IU (W4a), backed by `decision_shadow` — 92.4 % agreement with LLM triage, 60.1 % with the gold (`evidence/kpi/decision_shadow.out.md`).
- [ ] **Cross-source known-error fix** (ADR-003): fingerprints are normalised through the topology subject, so a Kuma monitor, its Slack relay and a HyperDX alert share priors — the held-out misses were cross-source (`evidence/golden/backtest.out.md`). It was designed from those misses, so it is scored as a new rule on the fresh sample, not on the spent held-out.
- [ ] Restart recipe (known error *container down, manual stop or crash*), landing after W1b's merge: `spec.commands.restart` from the project's manifest (W2a), acting only when two observations by different mechanisms agree (a Kuma docker monitor and the container's own healthcheck count as one; the second is a functional probe or evidence of recent work); held while a topology ancestor has an open host condition, until host reachability and mount checks pass; never fired on a target with an in-flight Deployment or declared maintenance; rate-limited per ADR-012. For crash, OOM and flap types a restart counts as resolution only if it holds for the type's hold (≥ 24 h). The **restart-lineage counter** lands here, beside the recipe: ≥ 3 restarts in a lineage within 7 days stop the recipe and route the lineage to investigation, until W5's `lineage.breaker` Condition takes over the opening.
- [ ] **Proof gate:**
  - (a) fixture regression: the live correlator's output equals `backtest.py` v2's frozen output on all 959 events (`evidence/golden/backtest.out.md`), no thresholds. v1's held-out numbers describe v1 and the held-out is spent; v2's development-only scores are published beside them (ADR-003);
  - (b) grouping by replay: a never-labelled window of recorded primary-source history — Kuma webhook rows since 10-16, HyperDX alerts, Docker events after `AS_OF`, the 2026-10-17 burst — replayed through the new adapters and correlator and labelled blind (packets carry raw signal text, source time and topology only; cross-burst gold comes from a blind labeller searching ±7 d for the same subject, topology ancestor or fingerprint, never along warden entities). The three grouping thresholds of `docs/factory/evidence/golden/PREREGISTRATION.md`, unchanged (B-cubed precision ≥ 0.90, recall ≥ 0.80, F1 strictly above the comparator — old warden's recorded grouping of the same signals, read from the archive) pass under the labelled, detach and join readings; hinted packets are a second, reported reading. The dated amendment to that file, committed before any label exists, fixes frame, unit, size, packets, comparator and decision-candidate count;
  - (c) gameday rows 1–2 (`design/proof.md` §2) pass: glance stopped live — one incident, the restart recipe executed, health green and the Condition resolved on observation within MTTR ≤ 5 min, 0 owner touches (the incident's own closure waits for its type's hold, ≥ 24 h for a crash type, and is not part of the gate); the 2026-10-17 VPS reboot replayed in event order with its host evidence arriving late — one incident after the `merge`, no recipe fired at the unreachable host, 0 pages (ADR-003);
  - (d) ≥ 10 injected Down/Up pairs on a test Kuma monitor each yield exactly one Condition open and close; with warden stopped, a test monitor goes Down and its webhook is lost — on restart the Condition opens within one resync interval and closes when the monitor recovers (ADR-013's level-recovery test);
  - (e) the log path per ADR-013's confirmation: the 152 recorded `hermes_log` rows replayed through the adapters (the checkpoint-store race and the egress outage each produce a Condition, the factory's own diagnostic lines none), then run live on the mini, the resolver blackhole included;
  - (f) a canary container replaced without recorded intent yields one unplanned Deployment, 0 restarts and 0 Conditions.
  - Grouping on the live post-cutover sample, escalation recall and known-error matching are not W3b gates, nor any wave's: they are standing SLOs on the pre-registered fresh sample (stratified time windows per source × host, same amendment), read when the sample reaches the size that amendment fixes, blind and hinted readings both reported (ADR-003).
- **Rollback:** stop the reconcilers, the correlator and the restart recipe, and point Kuma and HyperDX back at the Slack webhook (the days-1–8 state); the ledger keeps the Signals, Conditions and Incidents already recorded. **Horizon:** W12's close — Kuma and HyperDX keep their Slack channel configuration until then. **First:** W5, W4b and W4a (they act on the incidents this wave opens).
**Left behind:**

---

## Wave 4a — Tasks and one spawner: ready queue, claims, the `rd` cutover            <!-- status: pending -->
Repos: warden, dotfiles (`rd` — one cutover). ADR-001, ADR-007. Needs W1b and W3b. Day 9, lane A; W4b follows. Spawns are guarded by the orchestrator's stand-in until W4b ships the admission module (*Mode*).
- [ ] Ready queue, claim leases with epochs, plan projector. After its one-time projection the ledger is the only home of task state: PLAN.md keeps task ids only, written once through a normal Change, and Argo and `warden task list --plan <path>` render the state, which is never written to git. A plan line's Task id hashes (repo, plan path, normalised line), so W1a's import and this projection yield the same Task. `/wave` and `scripts/wave-gate.py` read and close tasks through `warden task`.
- [ ] `rd` writes Agent records through warden's verbs (optional `task_id`, its hook under `.factory/` per `design/model.md` §6.1 — a Task's attempts are its worker Agents), sets tab metadata; Hermes' herdr skill calls `rd`. `rd` joins the agent-CLI contract and stays a thin spawner: it never opens `ledger.db`. **It fails closed** (ADR-007): a spawn carrying a `task_id` is refused while warden cannot answer (down, or its ledger unreadable), and every spawn is refused in adopt mode; the JSONL spool exists only for the owner's manual `rd wave` sessions without a task, each line carries a client uuid, and replay records an observed Agent (adopt), never a spawn. The new `rd` installs beside the old one and switches by one symlink flip after the gate, at a lane barrier.
- [ ] **Worker profiles** (implement, investigate) on OpenCode/IU; the investigate worker makes the judgment calls (root cause, recipe choice, `decision_class`). agw `dispatch` stops at this cutover and leaves the global CLAUDE.md lane table.
- [ ] **Proof gate:**
  - spike 1's oracle against the ready queue and the claim leases;
  - `rd wave` and `rd agents` proven; with warden or its ledger unavailable a spawn carrying a `task_id` is refused while an owner's manual `rd wave` session (no task) starts and spools; a replay killed halfway, twice, adds 0 duplicate Agents and records them as observed, and a second replay adds 0 rows; in adopt mode 0 spawns; a CI check fails if `rd` opens `ledger.db` (ADR-007);
  - the worker profiles: an implement worker and an investigate worker each take a scratch Task through the ready queue and `rd` to a Change or a verdict — only then does agw `dispatch` leave the lane table; 0 spawns outside `rd`.
- **Rollback:** flip the `rd` symlink back to the kept old binary: the old `rd` ignores ledger Tasks, and PLAN.md holds task ids only, so no plan file changes; re-add agw `dispatch` to the lane table (its code stays); spooled JSONL replays once the ledger is back. **Horizon:** W12's close. **First:** W4b, W5 and W6 (they stand on the ready queue and `rd`'s Agent records). **Cross-lane:** the flip back is itself a build-lane flip, taken at a lane barrier; agents the new `rd` started keep running as herdr tabs, and their Agent records stay in the ledger.

## Wave 4b — Agents that never wait for the owner: Witness, mothers, admission, the MacBook actuator            <!-- status: pending -->
Repos: warden, dotfiles (the MacBook herdr observer's actuator; `rd`'s call into admission). ADR-007, ADR-008. Needs W4a; it reads W3a's herdr, quota and usage adapters and acts on W3b's Conditions. Days 10–11, lane A.
- [ ] **Mothers and lead wakes** (ADR-007): one mother identity per fleet project — persistent identity and continuity in its hook, run as on-demand sessions: the planner wakes it when a Condition has no recipe, a submitted brief needs breaking into tasks, or a plan needs re-sequencing; between wakes no context is resident. A lead is a mother wake scoped to one plan — the same identity and hook mechanism — woken to re-sequence its plan or resolve a conflict a worker returned; it claims no Task and spawns no worker, because Tasks are claimed only through the ready queue and `rd`. Handover and rotation go through the hook.
- [ ] **Today's mothers and leads cut over.** Each live mother or lead tab that W1a's adoption recorded is rotated once into its new identity:
  - its handover is written into the hook;
  - the successor is spawned through `rd`;
  - the old tab is reaped.

  After W4b, no agent tab exists outside the spawner's records.
- [ ] **Admission module** (ADR-007, ADR-008): one module, in warden — `warden admit`, a verb of the factory API — decides every spawn and every resume; `rd` calls it before it creates anything and fails closed, and nothing outside warden reads the ledger for policy. It holds the quota guard (a projection over every Max consumer, with ADR-008's victim and resume orders), the admission order, and the per-wake, per-Task and per-lineage budgets, which count engine-tagged tokens per session (Max % and dollars are display only). The guard's parameters live once in warden's admission config and a generated block renders them into ADR-008; `forecast.py` replays the 7 complete cycles through the guard before it ships. The breaker and the per-action rate limits stay on the ship side (W5). The module replaces the orchestrator's 80 % stand-in (*Mode*). The first per-wake budget is the forecast's assumption (0.25 × the median wave session ≈ 4.8M tokens, `evidence/kpi/forecast.out.md` — an assumption, not a measurement); after the first week of wakes it becomes the measured p90 × 1.5 and the wake rate becomes the planner's measured trigger rate, and D1 is re-issued from both — W4b's close-out files that as a Task.
- [ ] **Witness** (ADR-007): resume goes through the admission module, never a timer at the quota reset; auto-continue after transient API errors; re-drive stuck or dead agents from the hook; reap finished tabs (absorbs Phase 0's janitor); writes `idle.parked{reason, resume_at}`. Messages and steers go through the hook inbox, nudged once with a message id; `warden agent reply` is the one writer of `agent.replied`. **Re-drive is fenced in the checkout:** the successor takes the same hook only after the predecessor is confirmed dead (pane process tree killed, verified through herdr and `ps`), otherwise a fresh worktree on a new branch cut from the ledger-recorded sha; a per-worktree pre-push hook calls `warden lease check --epoch`; commits carry `Factory-Agent` and `Factory-Epoch` trailers. Auto-continues and re-drives are charged to the Task and lineage budget with backoff — the **budget counter** lands here, beside what it bounds, derived from events.
- [ ] **MacBook agents** (ADR-007): the Phase 0 herdr event recorder also runs on the MacBook and pushes to the mini's ingest when online; an actuator in the same MacBook observer pulls resume, steer and stop intents from the mini, applies them to the local herdr and acknowledges. While the laptop is closed its agents carry `host_asleep since hh:mm` and their intents stay queued until they expire on their budget. shutterflow's fleet stays on the MacBook (Mac-only work), observed and actuated there, not moved.
- [ ] **Proof gate:**
  - gameday rows 6–9, row 8 against the admission module's guard (`warden admit`); the budget check fires from live usage within one tool turn of the cap on a gameday Task (ADR-008);
  - ADR-007's W4b gamedays: a mother killed and rotated mid-plan — 0 lost or duplicated tasks, 0 owner nudges; kill between `rd say` and the timer-clear commit, 20 times — each message once in the pane transcript;
  - the zombie test: SIGSTOP a worker past its TTL, re-drive, SIGCONT, and have the zombie run raw `git commit -am x && git push && gh pr create` from its pane — the successor's tree never contains its edits, the push is rejected, no PR from it survives, 0 of its commits land;
  - with `warden admit` unreachable, `rd` refuses every spawn that carries a `task_id` (fails closed);
  - MacBook agents visible in the ledger; a resume, a steer and a stop applied to one through the actuator, and queued as `host_asleep` with the lid closed;
  - the guard's parameters in warden's admission config equal the generated block (one statement of the guard).
- **Rollback:** set Witness to observe-only with one config flag: it keeps writing `idle.parked` and reading the herdr event record but takes no action — no resume, continue, re-drive, reap or steer — while mothers, the admission module and the MacBook actuator, which gate or carry rather than drive, keep running. **Horizon:** none — a flag, no kept artefact. **First:** nothing; W5 and W6 stand on the budget counters, the admission module and the actuator, which the flag leaves in place.

## Wave 5 — Ship: verification replaces approval            <!-- status: pending -->
Repos: warden, holdouts (new, private), each fleet repo. ADR-012. Needs W1b, W4a and W4b. Days 12–14, lane A. The first three bullets land before the train's first auto-ship.
- [ ] **Effective autonomy** per (project, action class), computed by `warden manifest check` from which evidence producers exist (ADR-012): a rung with no producer is **propose-only** and files its gap as a Task. Built here: the substitute producers per runtime kind, the 14-day close of a propose-only PR whose gap stays open (Task kept, never merged by the owner), and the rule that a producer counts only after the verifier has watched it fail in a canary or scratch window.
- [ ] **Rollback as a Deployment operation** (ADR-012, `design/loops.md` §3): every Deployment records its `runtime[].artifact` reference (image digest, compose revision or launchd bundle hash); `verified` (checks passed) and `held` (hold confirmed) are separate states and the target is the last `held` Deployment; a hold failure is bisected by redeploying digests in order; the known-bad marker — a `fail` Verification on (target, artifact digest) checked before every deploy — lands only on the attributed change.
- [ ] **`factory-self`** (ADR-012): the class for the ship path, verifier, holdout runner, breaker, rollback and any Change that adds, removes or weakens a producer. N-1 verification is a CI job on the previous tagged release's verifier and holdout suite (W4b's tag for W5's own change). `factory-self` releases migrate the ledger by expand/contract steps only and the ledger carries a schema stamp (ADR-011): a small independent watchdog restores warden's last `held` release only if that release supports the current stamp, otherwise it stops automation and sends a heads-up.
- [ ] **Merge train** with squash merges: one train entry per agent-originated push, merged only if its head was pushed under the current epoch; deploy and post-deploy verify; ladder per action class from the manifests; the runaway breaker as the Condition `lineage.breaker`; rate limits.
- [ ] **Renovate automerge off fleet-wide:** in every repo's Renovate config and the manifest default (one commit per repo, PR-required repos by PR). Renovate only opens PRs, and the train merges them through the dependency rung.
- [ ] **Holdouts:** ≥ 5 scenarios per fleet project in the private holdouts repo, drafted by the project's mother from W5's first day (D4's default starts here). A set **binds on measurement, not on a clock**: it passes against the project's current production release, and each scenario has been watched failing against a seeded fault in a canary or scratch window (the verified-producer rule, recorded as Verifications); the owner may edit a set at any time and no timer runs on it. The update path is ADR-012's, and each Verification that gates a deploy records the holdouts sha it ran against.
- [ ] **A canary or scratch window per fleet project** (ADR-012 rules 2 and 7; manifest `runtime[].canary`):
  - what it is: a preview deploy, a scratch copy of the service and its data, or a time-boxed window on the live target;
  - why it exists: it is where seeded faults run, so evidence producers and holdout sets can be watched failing and bind;
  - without one, the project stays propose-only for code fixes, and `warden manifest check` files the gap as a Task.
- [ ] **Proof gate:**
  - gameday rows 1, 10–12 and 17–19 (`design/proof.md` §2): a rollback to the last `held` Deployment, a hold failure attributed by bisect (row 10); a known-bad dependency bump never merged (row 11); the always-green probe leaves its rung propose-only with the gap filed as a Task (row 17); the weakened verifier rejected by the N-1 CI job (row 18); the crash a restart clears every time opens `lineage.breaker` (row 19); rollback success 100 % on injected failures;
  - gameday row 21 (`design/proof.md` §2), the migrating bad release: a deliberately failing `factory-self` release that migrates the ledger is met by the watchdog's rollback when the last `held` release supports the new schema stamp, and by its safe stop — automation stopped, one heads-up — when it does not, never by a restore onto a ledger the older release cannot read;
  - the train rejects a head not pushed under the current epoch (W4b's zombie PR);
  - replay of #8 (`evidence/incidents/incidents.md`) with the ship loop in dry run: the log-level Change reaches a recorded Deployment and its hold, with 0 propose-only Changes open for agent-gateway, hermes-agent and warden;
  - every project's effective autonomy printed per action class with its holdouts' binding state — bound on measurement, or which measurement is missing — the gate runs on drafted holdouts, and binding gates only a project's switch from propose-only to auto-ship, never an owner approval.
- **What ships at the close:** restarts and producer-backed config automatically; fleet code fixes per project once its holdouts have bound on measurement; escalation and known-error matching start as standing SLOs; improve and heal wait for W10.
- **Rollback:** switch the train off — every Change is opened and verified but not merged, and merges through the build lane; the last `held` Deployment stays live. **Horizon:** none — a switch, no kept artefact. **First:** W10 (its jobs ship through the train): pause them.

## Wave 6 — Decisions and Argo as the control plane            <!-- status: pending -->
Repos: warden, argo, basalt-ui (PR), vps. ADR-009, ADR-014, ADR-015, `design/argo.md`. Needs W4a and W4b (steer and stop execute through `rd`'s Agent records, the MacBook actuator included). Days 15–19, lane A.
- [ ] Decision entity with options, reversible default, expiry; push tiers, decision and heads-up pushes at-least-once and de-duplicated on the phone by event id (ADR-009, ADR-014); the imported decisions drained under ADR-014.
- [ ] Factory read API on the mini (read models of `design/argo.md` §2, replacing W3a's read slice) and the write verbs of ADR-015, each writing an owner intent event with a lifecycle on its target entity, executed by a reconciler or `rd`; delete the frozen snapshot pushes and the action queue; VPS dead-man's switch, its heartbeat payload carrying an egress probe so the VPS tells "mini dead" from "mini alive, egress dead".
- [ ] Views: situation-adaptive Home, capability-composed Project pages, Needs you, Incidents, Fleet, Artifacts (read side), Health, Usage, Traffic; basalt-ui lands the event list, upstreams status chip, decision card and entity card, builds the lifecycle strip.
- [ ] Gate: the timed Argo test on phone and desktop; every write verb except `comment` (W7 builds `warden artifact`) exercised end to end with its audit event, both non-applied end states and the MacBook actuator included (ADR-015's confirmation); the verb-set and read-model lineage checks (`design/proof.md` §6) green; gameday row 13.
- **Rollback:** redeploy Argo's pre-W6 `held` Deployment (the frozen pages with W3a's stub page); the read API and verbs stop with it; basalt-ui changes revert by PR. **Horizon:** W12's close — the pre-W6 Argo digest stays pinned until then. **First:** W7 and W11 (they read the API; W7's view deploys on Argo).

## Wave 7 — Artifacts are ours            <!-- status: pending -->
Repos: warden (`warden artifact`, a module of the factory CLI and API), argo, basalt-ui (PR: comment-thread export). ADR-005. Needs W6. Days 20–22, lane A.
- [ ] `warden artifact submit|wait|status|comment` — ADR-005's contract, spike 5's `rv` verbs — on the agent-CLI contract. Threads live only in the ledger: Artifact entities plus comment events carrying the anchor triple (quote + prefix + suffix); a comment or resolve with actor `owner` on a plan Artifact is the ledger fact the ladder reads as "traces to the owner". Versions stay in git as `path@sha` under `docs/artifacts/<slug>/`, committed by the submitting agent through the normal Change path; the artifact module never commits. plannotator's semantics kept (supersedes, wait-for-reply, global sequence).
- [ ] Argo Artifacts view with anchored threads, project-grouped inbox, phone layout; basalt-ui gains the comment thread as a package export in its own PR.
- [ ] Gate: ADR-015's `comment` verb exercised end to end from Argo, with its audit event; the spike-5 `rv` contract suite against `warden artifact`; a review round trip from phone and desktop, the phone comment landing as an event with actor `owner`; a thread rebuilt from events alone; a phone comment on an artifact in a PR-required repo and in an IuRoot repo leaving `git status` clean in both; plannotator removed.
- **Rollback:** plannotator's Inbox stays installed until the gate passes; flipping back re-points the contract at it, and threads recorded meanwhile stay in the ledger. **Horizon:** W7's gate, where plannotator is removed. **Leaf.**

## Wave 8 — CLI-first tooling (the former W11)            <!-- status: pending -->
Repos: agent-gateway, email-, audio-, image-gateway, dotfiles (skills). ADR-004. Needs W4a's cutover. Days 12–16, lane C.
- [ ] **First:** agw's `decide`, `triage`, `narrative` and `investigate` tools stop being registered. agw's role, one line: a bounded tool server, no loop.
- [ ] **Entry gate:** every exposed route of each gateway has input and output schemas (Elysia route schemas — Zod or TypeBox — exported to JSON Schema); a gateway that fails it gets the schemas first.
- [ ] Contract libraries: W1a's Python library and conformance suite are the base; W8 adds the TS/Bun runner (command tables generated from the HTTP contract, ADR-004) and widens the suite to the set the manifests declare (`spec.provides.clis`, ADR-010) — it fails on an undeclared `~/.local/bin` entry and tests the contract-sha handshake. `hl`, `secrets-run`, `ask-human`, `jobrun`, `imgcli` and the research CLI join here (`rd` joined in W4a); drop-in shims are tested for compatibility with the tool they shadow.
- [ ] CLIs for agw (review, check, prose, read_image, read_drawing), email, audio and image gateways; generated help, `REFERENCE.md` and each skill's `references/cli.md`. **Tool routing renders once into the global generated rules file** (a Claude Code rule and the same file in OpenCode's `instructions`); the per-repo AGENTS.md block (W2b) holds manifest facts only; CI drift check.
- [ ] **Long-job budget** (ADR-004): the settings template raises Claude Code's Bash default and maximum timeouts (exact env names verified through `/research` at implementation) and the session hook sets the CLI wait budget just below the raised default, so a default `--wait` returns `pending` with its resume command before the harness cuts the call. The budget bounds a tool call, never the job.
- [ ] Skills move onto the CLIs in one cutover each, shipped under new names and switched by one symlink flip after the gate, at a lane barrier: `/check`, `/review`, `/otel`, `/prose`, `/excalidraw-diagram`; dispatch-era skills retired; MCP registration shrinks to research-gateway (plus chrome-devtools until a browser CLI replaces it) — agw's MCP server leaves the registration and the deferred-tool path here.
- [ ] Gate: conformance suite green on every declared binary and red on an undeclared `~/.local/bin` entry; `/check` and `/review` proven on two repos after the cutover; spike 4's long-job probe passes without the policy sentence, at the measured p50 and p90 durations, in headless Claude Code with the raised timeouts, OpenCode and cron (ADR-004's confirmation); MCP registration audited to research-gateway and chrome-devtools only.
- **Rollback:** flip the skill symlinks back to the old names and re-register agw's MCP server. **Horizon:** W12's close — the old skills and the server stay on disk until then. **First:** W12 (it generates routing from these CLIs). **Cross-lane:** the flip back is a build-lane flip, taken at a lane barrier.

## Wave 9 — One trace per item            <!-- status: pending -->
Repos: warden (worktree, merged after W7's close-out), agent-gateway, research-, email-, audio-gateway, dotfiles. ADR-006. Needs W3a's collector. Days 20–21, lane C.
- [ ] **ADR-006's rollout, in its order:** trace id derived from the root entity, `traceparent` wherever it works, `warden.item.id` then `factory.root` as the resource attribute on everything that cannot carry a context; agw's Claude env block and warden's header → research-gateway's 30-line `traceparent` patch, then email and audio → OpenCode env and header → `rd`'s pane env (attribute only) → the Hermes plugin.
- [ ] **The mini in the VPS ClickStack:** W3a's collector already ships the logs; W9 adds host metrics, so a LaunchAgent log line and a host metric for one window sit in the same store.
- [ ] **Settings fix:** `CLAUDE_CODE_ENABLE_TELEMETRY=0` leaves `config/settings.template.json` (or is overridden per spawn) — today it silently disables all Claude Code telemetry. The `/otel` preset fixes noted in the spike (status-code and column names) land here too.
- [ ] **Proof gate:** ADR-006's confirmation — one gameday item traced from signal to gateway call in a single VPS ClickHouse query; a mini LaunchAgent log line and a host metric for the same window both found in that store; a CI check that every spawn path sets the resource attribute.
- **Rollback:** revert the telemetry commits per repo; traces already exported stay in ClickHouse. **Horizon:** none — additive. **First:** W10's `perf.regression` job reads this data; pause it.

## Wave 10 — Improve and heal on the same path            <!-- status: pending -->
Repos: warden (+ Renovate release-age and grouping config per repo, landed on days 23–24 before W14 opens dotfiles; CrowdSec on homelab, vps). Loops §6, proof §2. Needs W5 and W9. Days 23–26, lane A.
- [ ] One recurring job per loops §6 row, each a reconciler on a schedule whose Conditions flow through correlate → plan → spawn → verify:
  - dependencies — Renovate opens the PRs (14 d age; automerge off since W5) and the train merges them through the dependency rung; the reconciler watches Renovate's failures and majors → `deps.*`;
  - docs drift — generated blocks, doc-contradiction lint, age → `docs.*`;
  - code health — `/analyze` weekly over thresholds → `code.health` (batched);
  - Claude Code setup — CLAUDE.md/AGENTS.md size, skill count, resident tool-definition tokens → `setup.bloat`;
  - basalt-ui dogfooding — components duplicated in consumers → `ui.upstream`;
  - performance, OTel — p95/error-rate regressions per service vs baseline (W9's data) → `perf.regression`;
  - bugs — a weekly correctness sweep: `/code-review` over each repo's merged diffs since the last sweep, plus new OTel error clusters per service (W9's data) → `code.bug`;
  - GitHub issues on owned repos → Signals → Tasks;
  - infra — the runbooks below → `infra.*`;
  - attacks, anomalies — CrowdSec on the public hosts, auth/log anomalies → `security.anomaly`.
- [ ] **Credential expiry** (gameday row 5): an `auth.expired` Condition is raised 7 days ahead for the secrets cache, Claude auth and the GitHub token. Each expiry becomes one present-human ask through `ask-human`, coalesced across credentials.
- [ ] **ADR-016 first: attack and anomaly detection per host.** It decides:
  - which detector runs where: CrowdSec on the public hosts, plus what covers the mini and the homelab;
  - each bouncer's failure mode: the Traefik plugin fails closed by default (`research/2026-10-22-small-host-healing.md` §9), which reads as an outage;
  - what a `security.anomaly` Condition may do without the owner.

  It is written from that research before any CrowdSec config lands.
- [ ] **Infra runbooks per host** (mini, homelab, vps), code-only where the cause is known: disk (disk-sweep), mount (mount, verify, restart dependents), certs, backups, restart loops, DB/ClickHouse health, and `infra.egress` for the factory host — network-independent (flush the DNS cache, restart mDNSResponder, fail over to a secondary resolver); attempt failures during an open egress condition are classed infra. A runbook that fails on a physical cause (device absent, power, no shutdown record) ends in `needs_hands` on the heads-up tier.
- [ ] **Proof gate:**
  - gameday rows 3, 4, 5, 14 and 15 pass at their proof §2 targets, 0 owner touches;
  - gameday row 16: a CrowdSec-detectable scan against a test endpoint → `security.anomaly` → block → resolved, 0 owner touches;
  - one code fix per fleet project auto-shipped end to end through a bound holdout set; a project without one is reported as not yet autonomous for code, never counted as passing;
  - one item per improve class (the first eight jobs above) shipped end to end through the ladder — Condition → Task → merged, verified Change — with its Verification records and 0 owner touches.
  Grouping, known-error matching and escalation recall are standing SLOs on the pre-registered fresh sample (`docs/factory/evidence/golden/PREREGISTRATION.md`), not a gate here (W3b). Passing it is full autonomous operation.
- **Rollback:** pause a job through its project runtime record (ADR-015's pause); Renovate and CrowdSec configs revert per repo. **Horizon:** none. **Leaf.**

## Wave 11 — Hermes becomes the door            <!-- status: pending -->
Repo: hermes-agent. Needs W6's read API. Days 20–22, lane B.
- [ ] **Inventory and ADR-017 first:**
  - every Hermes plugin, cron, skill and tool, with its consumer and its disposition: a door feature, a factory job, or deleted;
  - what Hermes owns.

  Both are committed before the capability cut.
- [ ] Capability limit with a test: no file, code-execution or code-writing terminal tools; a terminal allowlist of factory CLIs.
- [ ] Reads only the factory read API and CLIs; files Tasks and asks `rd` for sessions; briefings (morning, evening) are a rendering of the one digest projection — Home and the per-project changelogs (W13) are its other two, no second pipeline: a briefing is the Home digest plus one push with an audio link; the "Project narratives" cron retires (its job moves to W13's changelog rendering); Slack posting exits.
- [ ] Gate: a replay of the last 30 days of owner requests to Hermes (its `state.db`, archived read-only) through the new Hermes — zero file, code or commit tool calls — and the capability test above (a code-tool call is refused); briefings reproduce from events.
- **Rollback:** redeploy Hermes' previous release; the capability limit stays. **Horizon:** none. **Leaf.**

## Wave 12 — dotfiles rewired            <!-- status: pending -->
Repo: dotfiles. Needs W2b and W8. Days 17–19, lane C.
- [ ] Generated routing everywhere (manifests + CLI contract); skills diet (each skill = when to use + judgment, flags generated); launchers consolidated; global CLAUDE.md and AGENTS.md generated blocks; the security-policy line aligned with ADR-014.
- [ ] **Doc-contradiction lint** (`design/proof.md` §6): bans hand-ticked task checklists (PLAN.md keeps task ids only, W4a) and fails any `--flag` in a SKILL.md or AGENTS.md that the referenced CLI's schema snapshot lacks (ADR-004). **Concept-budget check** over a generated inventory: its caps (processes per host, agent-facing CLIs, stores, as `design/proof.md` §6 defines them) are today's measured count minus the cuts the design claims, measured in this wave.
- [ ] **The macOS-vs-GNU failure class** (`fail:bsd-vs-gnu-and-glob`: 530 failing calls in 360 sessions, `evidence/toil/toil.md` C18) gets the fix that evidence names, a PreToolUse rewrite — not GNU tools first on PATH (ADR-004). The gate re-runs `evidence/toil/toil.py` and reports the count; the panel's bar, under 50 per 30 days (`panel/pass1/dx.json` dx-8), is a standing KPI read after 30 days of sessions, not a W12 waiting period.
- [ ] **CodeRabbit removed** from `skills/{commit,git-cleanup,pr,ship}`, Round 5 W1's chore that its disposition kept.
- [ ] **Close the rollback horizons** after the gate: delete what the Rollback lines kept — the legacy plists, the old `rd` binary, the superseded skills, agent-gateway's MCP server code and the code of the tools W8 unregistered. The `warden-legacy` tag stays in git.
- [ ] Gate: doc-contradiction lint (flag lint included) and drift checks green across all repos; the concept-budget caps hold; no hand-maintained project registry left (`config/pr-required-repos.json`, `docs/architecture.md`'s repo and LaunchAgent tables, the Caddyfile app blocks, the runner list all byte-equal to a re-render from the manifests); `make check` green on both machines.
- **Rollback:** revert the generated-block and routing commits; the renderers stay, their outputs return to the W2b state. **Horizon:** the horizon-closing bullet runs last, after the gate; from then on W1a, W4a and W8 roll forward only. **Leaf.**

## Wave 13 — Brain projections and per-project changelogs            <!-- status: pending -->
Repos: brain, warden (projector, worktree merged after W10's close-out). Needs W11. Days 23–24, lane B.
- [ ] Each project's brain note gains generated sections (status, links, changelog) from the manifest and the event log; the changelog is a rendering of the one digest projection (W11); `changelog.target` honoured (brain by default, repo for libraries with release notes); one writer for the vault.
- [ ] Gate: every project note re-renders from events; no Slack changelog left.
- **Rollback:** revert the vault commits of the generated sections; hand-written note content outside them is never touched. **Horizon:** none. **Leaf.**

## Wave 14 — Archive, retention, docs, website            <!-- status: pending -->
Repos: dotfiles, brain, jkrumm.com. Days 25–26, lane C. Last.
- [ ] Historical stores archived under open decision D5's default — the reversible half only: archive to the homelab bucket, keep every local copy; local deletion is never defaulted, so retention jobs delete nothing local until D5 is answered; generated docs replace hand-written restatements; jkrumm.com's guide rewritten from the new model.
- **Rollback:** archives are copies — restore a store from its archive; retention jobs unload; doc and site changes revert by commit. **Horizon:** none. **Leaf.**

---

## Round 5 disposition

| Round 5 wave | Disposition | Where |
|-|-|-|
| W1 Constitution | **merge** — the model is generated from manifests and ADRs; CodeRabbit removal kept as a chore | W2a, W2b, W12 |
| W2 Escalation cut | **done in part** (Phase 0: agw W12; warden W8 closed early — the rewrite stops the old loop); timeout default → W6; improve loop → W10; shadow promotion → **drop** (no single-shot decision model in the loop; judgment in the investigate worker on OpenCode/IU, ADR-003); rebase-merge revert → W5; Argo `adopt` verb → **drop** (write verbs, ADR-015) | Phase 0, W3b, W4a, W5, W6, W10 |
| W3 Execution layer | **done in part** (Phase 0: recorder, janitor); recorder on the MacBook → W4b; tab metadata and one launcher → W4a; overview truth → W6; Obsidian 1706 → imported as a Decision with a default | Phase 0, W1a, W4a, W4b, W6 |
| W4 Implementation into herdr | **keep**, unblocked by ADR-008; widened: worker profiles replace agw `dispatch` (W4a), on-demand mothers and leads for fleet projects (W4b) | W4a, W4b |
| W5 Thin Hermes | **keep**, widened: Hermes becomes the door | W11 |
| W6 Argo control plane | **keep**, redesigned from the owner's questions plus write verbs | W6, W7 |
| W7 Slack retirement | **merge** — intake stops with warden (W1a); human posting exits in W6, W11, W13 | W1a, W6, W11, W13 |
| W8 Brain door | **merge** | W13 |
| W9 Observability | **keep** | W9 |
| W10 Docs and website | **keep**, last | W14 |
