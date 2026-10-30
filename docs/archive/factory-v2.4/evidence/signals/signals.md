# Signals - what sits behind warden's Slack relays

AS_OF 2026-10-22T08:00:00Z. Frozen `warden.db` plus read-only probes (ssh homelab/vps, gh); `signals.py` writes `signals.out.json` and `topology.out.json`. A row is a warden `events` row (one per text fingerprint), not a Slack message.

**Headline.** 1,121 of 1,761 events (63.7 %) came through Slack: slack_alert 408, slack_update 713 (the brief's 1,112 of 1,752 predates nine rows).
- **Nothing consumes slack_update:** 713 rows = 669 RollHook deploy notices, 3 Watchtower, 41 chat; `INGEST_SOURCES` excludes it, 0 became items.
- **slack_alert is mostly Kuma** (286 of 408; chat 57, Better Stack 16, homelab-private 16, HyperDX 13, Beszel 11, WatchDog 5). 128 rows became items, 23 of those reached the owner, none reached `fixed` (35 went quiet).
- **Kuma and HyperDX already push to warden (webhooks live since 2026-10-16), but Kuma's Slack copy is still ingested:** 37 of 40 Kuma Down rows since then duplicate a `uk` event; escalations in that era: 19 via Slack, 14 via the webhook.

## Source map

| primary (host) | relay -> warden source | rows | lost in the relay | direct path | recommended intake |
|-|-|-|-|-|-|
| Uptime Kuma (homelab) | Slack webhook -> slack_alert | 286 | id, type, tags, url, times; groups echo children; Down/Up split | y, live: webhook -> /ingest/kuma (uk) | webhook wakes a state reconcile; drop Kuma lines from Slack intake |
| Better Stack (SaaS) | Slack integration -> slack_alert | 16 | incident id, cause, times; prose filter closes them | pull: API (SaaS cannot reach the door) | drop; Kuma probes all 5 subjects |
| Beszel hub (homelab) | Shoutrrr Slack -> slack_alert | 11 | value, times; recurrences collapse | y, config: generic webhook or alerts_history | reconcile alerts_history |
| HomeLab WatchDog (homelab) | Slack Block Kit -> slack_alert | 5 | blocks flattened, cut at 240 | n: notify() could POST to the door | structured POST; low volume |
| HyperDX alerts (vps) | Slack webhook -> slack_alert (before 2026-10-17) | 13 | value, range, url, service | y, live: webhook -> /ingest/hyperdx | keep; reconcile alert state |
| homelab-private stack (homelab) | Slack webhook -> slack_alert | 16 | structure, severity, origin | n: POST to the door or push monitor | structured POST; low volume |
| RollHook (vps) | Slack webhook -> slack_update (never ingested) | 669 | job id, duration, error; deploys folded per app | y, config: job webhook; OTLP markers live | webhook -> deploy event (DORA) |
| Watchtower (homelab and vps) | Shoutrrr Slack -> slack_update (never ingested) | 3 | image and container | y, other: Docker events and digests | ignore; use Docker state |
| Hermes gateway chat (mini) | Slack messages -> slack_alert, slack_update | 98 | not a signal | n/a | stop reading prose |
| Docker daemon (homelab, vps) | Argo summary poll -> docker_homelab, docker_vps | 7 | history; 30-min summary | y: events stream (nothing records it) | stream consumer + recorder |
| GitHub (SaaS) | gh poll -> github_go, github_pr, github_issue | 178 | Actions are no source | pull: gh api | poll runs (ETag) or runner step |

Rule for every row: the push is a wake-up, the level (current state per entity) is read from the source.

## What happened to the rows (columns 3-7: events since the first loop item, 2026-09-08)

| class | rows | loop-era rows | item | attached | ignored | no item | escalated (all time) | recoveries (of fault+recovery) |
|-|-|-|-|-|-|-|-|-|
| Uptime Kuma | 286 | 95 | 67 | 15 | 38 | 13 | 19 | 115 (40.2 %) |
| Better Stack | 16 | 10 | 10 | 0 | 10 | 0 | 0 | 5 (31.2 %) |
| homelab-private apps and scripts | 16 | 8 | 7 | 1 | 4 | 0 | 1 | 1 (6.2 %) |
| HyperDX alerts | 13 | 12 | 12 | 0 | 0 | 0 | 1 | 4 (30.8 %) |
| Beszel hub | 11 | 10 | 9 | 1 | 6 | 0 | 2 | 6 (54.5 %) |
| HomeLab WatchDog | 5 | 3 | 2 | 0 | 2 | 1 | 0 | 2 (40.0 %) |
| RollHook | 669 | 250 | 0 | 0 | 0 | 250 | 0 | n/a (update notices) |
| uk (direct) | 96 | 69 | 53 | 7 | 2 | 9 | 17 | 94.8 % resolved |
| hyperdx (direct) | 4 | 4 | 3 | 0 | 0 | 1 | 1 | 100.0 % resolved |

`item` = non-duplicate item rows (ignored included); `attached` = duplicate_of set. slack_alert ignores: policy list 28, prose filter 8, hand or model 27. All 98 chat rows predate the loop; 4 of 5 Better Stack incident rows died in the prose filter (no bracket, no glyph).

## What the relay loses (measured)

- **Structure.** Argo's mapper keeps ts, user-or-bot id, text, thread, reactions, files but drops username, app id, attachments and blocks (`argo/apps/api/src/clients/slack.ts:191`); warden keeps only `text` and `ts` (`watchdog-poll.py:369-392`), discarding even the bot id, so the poster is a guess from text shape and 33 rows are cut at 240 characters. Routing suffers: items without a repo are 89 of 128 for slack_alert and 21 of 56 for `uk` (Kuma holds 0 tags, so the repo label that `route_by_label` reads does not exist; github_go, human, job: 0).
- **Fingerprints.** Identity is the text minus numbers and ids (`watchdog-poll.py:795`). Recurrence collapses: Beszel 137 episodes since May -> 11 rows; Kuma 2,251 transitions -> 286 rows (82 group echoes). Changing error text splits one outage (32 of 89 Kuma names have 2+ Down fingerprints); a rename orphans rows (35 name monitors that no longer exist). RollHook since 2026-10-04: 22 per-app rows for 1,267 deploys (before: 174 rows for 186).
- **Recovery events.** 133 of 1,121 rows (11.9 %) are recoveries, 662 (59.1 %) update notices, 102 (9.1 %) chat or tests; of fault plus recovery rows 37.3 % are recoveries (Kuma 40.2 %). A recovery is its own row keyed by its own text, so a Kuma Up never closes its Down; only a glyph flip normalises to one key, and inside one batch it leaves no trace (`intake.py:735`). The policy ignores Kuma Up lines (yes) and Better Stack resolved lines (yes).
- **Timing.** Only the Slack ts survives: poll lag median 15.7 min, p90 28.2 (single-message rows), the loop adds median 2.5 min; a webhook (`uk`) row becomes an item after median 4.2 min (n 34). 43.1 % of Kuma outages end within 5 minutes and 79.6 % within 30, shorter than one poll, so a relay sees Down and Up in one batch or misses the Down. `first_seen` is the last re-arm (67 rows lag over 6 h).
- **Volume cap.** The poll takes the newest 50 messages and passes no `oldest` or cursor although Argo offers both plus `has_more` (`watchdog-poll.py:363`). Kuma's busiest half hour (2026-07-28 02:00 UTC, the homelab reboot) held 98 heartbeats (84 leaf): the only window over 50 of 645. 210 of 791 leaf DOWNs sit in 34 five-minute buckets where 3+ monitors failed together: the correlation target.
- **Double intake.** The skip rule matches `[... Push]` names only (`watchdog-poll.py:384`), so Docker and HTTP monitor lines still open `slack_alert` items beside the webhook's `uk` events. One leaf has no webhook, FPP - DB - MySQL (sync.py skips existing DB monitors): for it Slack is the only path.

## Monthly volumes (ledger first_seen month; recurring rows re-arm, so older months undercount; ts-based months are in the JSON)

| class | 04 | 05 | 06 | 07 | 08 | 09 | 10 | total |
|-|-|-|-|-|-|-|-|-|
| Uptime Kuma | 0 | 43 | 39 | 46 | 50 | 24 | 84 | 286 |
| Hermes gateway chat | 0 | 0 | 0 | 97 | 0 | 1 | 0 | 98 |
| Better Stack | 0 | 2 | 3 | 0 | 1 | 0 | 10 | 16 |
| homelab-private apps and scripts | 0 | 0 | 3 | 0 | 3 | 4 | 6 | 16 |
| HyperDX alerts | 0 | 0 | 0 | 0 | 0 | 5 | 8 | 13 |
| Beszel hub | 0 | 1 | 0 | 0 | 0 | 4 | 6 | 11 |
| HomeLab WatchDog | 0 | 0 | 0 | 0 | 2 | 0 | 3 | 5 |
| RollHook | 0 | 59 | 30 | 93 | 156 | 262 | 69 | 669 |
| uk (direct) | 0 | 1 | 1 | 1 | 18 | 16 | 59 | 96 |
| hyperdx (direct) | 0 | 0 | 0 | 0 | 0 | 0 | 4 | 4 |
| other direct sources | 7 | 57 | 5 | 12 | 33 | 197 | 229 | 540 |

Not in the table: Watchtower 3, tests 4. Other direct sources: human 162, hermes_log 152, github_go 136, github_pr 30, stray_skill 16, github_issue 12, job 7, warden_self 7, docker_homelab 5, hermes_cron 4, warden_canary 4, op_refs_homelab 3, docker_vps 2.

## Direct paths, probed read-only

- **Kuma:** one instance, on the homelab (the vps runs none): 120 monitors (docker 30, group 22, http 22, keyword 8, mysql 1, push 37), Slack on 98 leaves, `Warden - Ingest` on 97, groups notify nobody; the door answers the homelab and vps tags only. `/metrics` answers 401 without a key and 2 API keys exist (`monitor_status` per monitor), so a level read is possible.
- **Deploys, metrics, events:** RollHook left 1,453 OTLP deploy markers ok and 5 failed in ClickStack since 2026-09-23 (30-day TTL) against 196 and 5 Slack rows; its job webhook is one env var away. Beszel `alerts_history`: 237 rows, 100.0 % resolved, value kept. Docker's event ring (~256 events) is under 1 min of healthcheck noise on the vps and 1 to 3 min on the homelab, so history needs a live consumer. Watchtower: HTTP API is trigger-only, `/v1/metrics` needs API mode and a token, level `warn`.
- **GitHub:** `gh api` works non-interactively; 553 failed Actions runs in 90 days over 18 repos (228 on a default-branch push); no warden source reads Actions. **Not probed:** Better Stack API, HyperDX alert history, RollHook `/jobs`, Slack itself.

## Topology (draft; `topology.out.json` holds every unit, monitor, alert, edge and project roll-up)

| host | units (host -> container or job -> service -> project) | Kuma leaf monitors aimed at it | updates | alerts |
|-|-|-|-|-|
| homelab | 25 containers + 11 homelab-private (counted) | 34 | Watchtower 04:00 | Beszel hub |
| vps | 36 containers | 25 | RollHook for apps, Watchtower 04:00 for the rest | 21 HyperDX alerts (also for the mini's research-gateway) |
| mini | 54 launchd jobs + 7 IuRoot (counted) | 16 | own deploy paths | push monitors only |
| macbook, external | 1 push; SaaS: Better Stack, Vercel, GitHub | 1, 1 | - | - |

- Mapped to host, service and project: 77 of 77 public Kuma leaf monitors, 21 of 21 alerts, all 36 vps and 25 homelab containers; 11 cross-host edges are listed. Blind spots: homelab containers without a Docker monitor (docker-socket-proxy-claude, garmin-collector, homelab-watchdog-logs, proton-bridge); 19 of 36 vps services have no Kuma monitor or push.
- Routing today: 74 policy rules; 117 of 556 items carry no repo; repo names not in SourceRoot: ntfy-mac, sideclaw. Topology alone attributes 215 of 347 slack_alert signal rows to a project and 81 to a host (Kuma groups, Beszel, WatchDog); the rest name stale monitors or Better Stack subjects.

## Limits

Rows are fingerprints, not messages: the Slack API was not called and the ledger cannot give true message counts. The system per row is inferred from text shape; chat is the residual class. Container lists are live at probe time; Kuma, Beszel and ClickStack aggregates are append-only reads below AS_OF. homelab-private and IuRoot items are counted, never named.
