# ADR-013 — Signals come from their primary sources; Slack intake retires

> **v2 status (2026-10-24):** revised — polling + a Slack adapter, no public endpoint (TDD v2 §10). The text below is v1 history.

- Status: accepted · 2026-10-22 · revised after panel pass 1 and pass 2 (dat-3, dat-4, dat-5, dat-12, dat-13, sre-1, sre-2, sre-4, sre-6) and the cross-lab review (`panel/review-resolutions.md`: R12)
- Evidence: `evidence/signals/signals.md` and `topology.out.json`, `evidence/incidents/incidents.md` (10-17: a 7.9-min reboot → 18 pages, briefs anchored on poll time), `research/2026-10-22-small-host-healing.md` (Watchtower archived; Kuma webhook carries `heartbeat.status`)

## Context and problem statement

63.7 % of warden's signals (1,121 of 1,761) arrive as Slack relays. The relay keeps only text and
a poll time: no monitor identity or tags (89 of 128 slack_alert items had no repo), no recovery
pairing (an Up never closes its Down), a median 15.7-minute lag while 79.6 % of Kuma outages end
inside one poll, a 50-message cap per poll, and double intake (37 of 40 Kuma Down rows since 10-16
duplicate the live webhook). `slack_update` (713 rows: 669 RollHook deploy notices, 3 Watchtower,
41 chat) is never ingested, and since 10-11 the notice stream has collapsed, so deploys are invisible.

## Decision outcome

One adapter per primary source, each emitting `signal.received` with a structured envelope:
`source`, `subject` (a topology id from the manifests, resolved once at intake and stored on the
Signal — a rebuild reads it and never re-resolves it), `kind` (firing | recovered | started |
deployed | failed | merged | opened | closed | requested), `severity`, `fingerprint` (default +
refinements, ADR-003), `occurred_at` (source time, never poll time), `raw`. `started` is a deploy
beginning, so deploy intent is a Signal and the deploy reconciler stays the only Deployment writer;
`merged` is a new default-branch sha.

| Primary source | Path |
|-|-|
| Uptime Kuma (homelab, 120 monitors) | webhook (live since 10-16); `heartbeat.status` pairs Up with Down; group monitors are topology parents, never subjects of their own Conditions (`design/loops.md` §1); state read at every resync (below) |
| HyperDX / ClickStack alerts | webhook (live); alert state read at every resync (below) |
| Application logs (152 `hermes_log` rows today, `evidence/signals/signals.md`) | the mini's logs (`~/Library/Logs`, Hermes, agent-gateway) ship to the VPS ClickStack through an OpenTelemetry collector's file receiver, so the adapter has live input from W3a (the file poller that fed warden stops with it at W1); the log adapter reads ClickStack alert rules on the structured severity field, never substring matches; fingerprint = logger + normalised message; output of the factory's own workers dropped at intake by provenance (ADR-006's resource attribute); a log-sourced Condition resolves by quiet, with no Up to wait for (`design/loops.md` §1) |
| git / GitHub refs | a ref adapter per manifest repo emits `merged` for every new default-branch sha, actor push \| renovate \| train; the Change module records `change.merged` from it (`design/model.md` §1), and the ship loop owns only train state |
| Deploys: RollHook, WUD, the `make deploy` wrapper, CI | each emits only `started`, `deployed` and `failed` (RollHook: its job webhook, or the OTLP deploy markers already in ClickStack, 1,453 ok / 5 failed in 30 d); the deploy reconciler alone turns them into Deployment transitions |
| GitHub (Actions, issues, PRs) | `gh` poll on the mini (the ingest door is not reachable from GitHub); 553 failed Actions runs in 90 d are unread today |
| Beszel | Shoutrrr generic webhook |
| HomeLab WatchDog | structured POST to ingest, low volume (`evidence/signals/signals.md`); the observer for "device absent" — an external drive reported disconnected, `evidence/incidents/incidents.md` #9 — feeding `infra.mount` |
| Docker events (homelab, vps) | a small recorder per host (the daemon keeps ~256 events) pushing to ingest; also the source of unplanned Deployments: a container replaced with no `started` Signal |
| herdr | the Phase 0 event record; also agent heartbeat and last output |
| Quota and usage | `quota.sampled` (each quota reading); `usage.recorded` per session, carrying `factory.root` |
| Owner messages | `owner.message` from transcripts and Hermes, classified; joined to its root through the receiving Agent's `correlation` |
| jobrun / `jobs-grade` | `job.ran` per scheduled run with its grade; launchd failures reach the health reconciler through it from W3a |
| Updates poll (daily: brew, OS and image updates, restart-needed flags) | `update.available` |
| agent-gateway routing, CLI and gateway versions | `config.observed`, on change |
| Owner and Hermes requests | `warden task add` / Hermes → Task (not a Signal) |
| Watchtower | archived upstream (last release 2023-11): retired for factory-managed containers in W3a — RollHook or WUD with recorded intent (`started`) replace it; any other replacement is an unplanned Deployment |

**Webhooks only schedule reconciles.** The Kuma and HyperDX webhooks carry the transition and its
source time and wake the project's reconciler, but a webhook is never the only record of a
monitor's state: every resync reads that state from the source — Kuma's `monitor_status` per
monitor on `/metrics` or its status API, and HyperDX's alert state — so a
webhook missed across a warden restart delays detection by at most one resync interval and never
loses the condition (level-triggered, `design/loops.md` §1). Kuma's level read is possible
(`/metrics` answers 401 without a key and API keys exist); HyperDX's alert-state read path is not
probed yet — only its alert history is on the not-probed list (`evidence/signals/signals.md`
§Direct paths).

Slack intake stops with the old warden at the start of the rewrite (no co-running, owner 2026-10-22);
each adapter proves itself before going live by replaying the recorded Slack history (every recorded
alert must reach the same Condition through its primary path). The Slack channel stays human-only
until Argo's notification stream replaces it.

The quota, usage, owner-message and agent-heartbeat adapters exist so invariant 8 holds: every read
model and control input — the spawner's quota guard included — replays from the event log, never
from usage.db, the herdr socket or transcripts directly. The ref adapter makes the Change set
complete: direct pushes, any Renovate merge (its automerge is off fleet-wide, so none is expected)
and train merges all become `change.merged`, so regression links, deployment suspects and
change-failure rate see every merge. The job, update and config adapters give Argo's job-run,
pending-update and routing views an event source; a read model that still has no adapter is labelled
a live probe in `design/argo.md` — it renders with `as_of` and is neither a projection nor a control
input.

### Consequences

- Good: recovery closes conditions (level-triggered), windows use real times, the 10-17 class of storm collapses to one incident; deploys become signals the correlator can blame; every Argo read model is either a projection or an openly labelled live probe.
- Bad: many small adapters to build and keep honest (the table above), Docker recorders on two hosts and a log shipper on the mini; a Condition opened from a log has no Up, so its quiet period is the only way it closes.

### Confirmation

History replay per source (missed and duplicate events against the recorded Slack copies). Level
recovery (R12): with warden stopped, a test Kuma monitor goes Down and its webhook is lost; on
restart the Condition opens within one resync interval, and closes when the monitor recovers. W3's
gate replays the 152 `hermes_log` rows through the log adapter: the checkpoint-store race (#7) and
the egress outage (#1, `evidence/incidents/incidents.md`) must each produce a Condition, the factory's
own diagnostic output none. A replay has no live source behind it, so W3 also runs the log path live
(sre-1): one ERROR record from the `tools.checkpoint_manager` logger written on the mini yields exactly
one Condition within 5 min, one WARNING record whose JSON body contains "ERROR" yields none, and the
Condition resolves by quiet after its type's hold with no further occurrence; with the mini's resolver
blackholed (gameday row 15) a record written meanwhile reaches ClickStack from the shipper's local
spool once egress returns and still yields exactly one Condition. The pass criteria are the panel's
(`panel/pass2/sre.json`, sre-1). Then the gameday catalogue (`design/proof.md`): every injected
failure arrives through its primary source with `occurred_at` within 60 s of the fault.
