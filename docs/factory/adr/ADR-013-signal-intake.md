# ADR-013 — Signals come from their primary sources; Slack intake retires

- Status: accepted · 2026-10-22
- Evidence: `evidence/signals/signals.md` and `topology.out.json`, `evidence/incidents/incidents.md` (10-17: a 7.9-min reboot → 18 pages, briefs anchored on poll time), `research/2026-10-22-small-host-healing.md` (Watchtower archived; Kuma webhook carries `heartbeat.status`)

## Context and problem statement

63.7 % of warden's signals (1,121 of 1,761) arrive as Slack relays. The relay keeps only text and
a poll time: no monitor identity or tags (89 of 128 slack_alert items had no repo), no recovery
pairing (an Up never closes its Down), a median 15.7-minute lag while 79.6 % of Kuma outages end
inside one poll, a 50-message cap per poll, and double intake (37 of 40 Kuma Down rows since 10-16
duplicate the live webhook). `slack_update` (713 RollHook/Watchtower notices) is never ingested,
and since 10-11 the notice stream has collapsed, so deploys are invisible.

## Decision outcome

One adapter per primary source, each emitting `signal.received` with a structured envelope:
`source`, `subject` (a topology id from the manifests), `kind` (firing | recovered | deployed |
failed | opened | closed | requested), `severity`, `fingerprint` (default + refinements, ADR-003),
`occurred_at` (source time, never poll time), `raw`.

| Primary source | Path |
|-|-|
| Uptime Kuma (homelab, 120 monitors) | webhook (live since 10-16); `heartbeat.status` pairs Up with Down |
| HyperDX / ClickStack alerts | webhook (live) |
| Application logs (152 `hermes_log` rows today, `evidence/signals/signals.md`) | a log adapter reading HyperDX/ClickStack alert rules on the structured severity field, never substring matches; fingerprint = logger + normalised message; output of the factory's own workers dropped at intake by provenance (ADR-006's resource attribute) |
| git / GitHub refs | a ref adapter per manifest repo emitting `change.merged` for every new default-branch sha, actor push \| renovate \| train; the ship loop owns only train state on those records |
| RollHook deploys | its job webhook, or the OTLP deploy markers already in ClickStack (1,453 ok / 5 failed in 30 d) |
| GitHub (Actions, issues, PRs) | `gh` poll on the mini (the ingest door is not reachable from GitHub); 553 failed Actions runs in 90 d are unread today |
| Beszel | Shoutrrr generic webhook |
| Docker events (homelab, vps) | a small recorder per host (the daemon keeps ~256 events) pushing to ingest |
| herdr | the Phase 0 event record; also agent heartbeat and last output |
| Quota and usage | `quota.sampled` (each quota reading); `usage.recorded` per session, carrying `factory.root` |
| Owner messages | `owner.message` from transcripts and Hermes, classified |
| Owner and Hermes requests | `warden run` / Hermes → Task (not a Signal) |
| Watchtower | archived upstream (last release 2023-11): replace with RollHook or WUD notifications |

Slack intake stops with the old warden at the start of the rewrite (no co-running, owner 2026-10-22);
each adapter proves itself before going live by replaying the recorded Slack history (every recorded
alert must reach the same Condition through its primary path). The Slack channel stays human-only
until Argo's notification stream replaces it.

The quota, usage, owner-message and agent-heartbeat adapters exist so invariant 8 holds: every read
model and control input — the spawner's quota guard included — replays from the event log, never
from usage.db, the herdr socket or transcripts directly. The ref adapter makes the Change set
complete: direct pushes, Renovate automerges and train merges all become `change.merged`, so
regression links, deployment suspects and change-failure rate see every merge.

### Consequences

- Good: recovery closes conditions (level-triggered), windows use real times, the 10-17 class of storm collapses to one incident; deploys become signals the correlator can blame.
- Bad: four new small signal adapters plus the log, ref, quota/usage and owner-message adapters; Docker recorders on two hosts.

### Confirmation

History replay per source (missed and duplicate events against the recorded Slack copies). W3's
gate replays the 152 `hermes_log` rows through the log adapter: the checkpoint-store race (#7) and
the egress outage (#1, `evidence/incidents/incidents.md`) must each produce a Condition, the factory's
own diagnostic output none. Then the gameday catalogue
(`design/proof.md`): every injected failure arrives through its primary source with `occurred_at`
within 60 s of the fault.
