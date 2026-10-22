# The ten costliest incidents, raw signal to closure

Source: `costliest.py` → `costliest.out.json` (every number below; `detail` holds the node
lists and milestone timelines) and `costliest.out.md` (ranking tables). AS_OF
`2026-10-22T08:00:00Z`, frozen warden/usage snapshots; git, OpenCode stores and host boot
records read-only. All times UTC. Ids: `e123` warden event, `e1173.1` its second lifecycle, `d1161`
dispatch, 8-hex job ids, 7–10 hex commit shas.

## How to read this

- **Incident** = the baseline grouping in the script docstring (co-firing within 32 min,
  same repo/class, duplicates, same root-cause text, same fix commit; an event row is reused
  per recurrence, so a *lifecycle* of an item is the unit). A baseline, not the design.
- **Pages** = `needs_decision` entries + `notified_at` + `reminder_count`. Distinct Slack
  posts are fewer (10 for the 18 pages of 2026-10-17). Rank = pages, then duration, then cost.
- **Era**: four of the ten (#1, #2, #3, #5) predate warden's triage items (first item
  2026-09-08): 0 items, 0 jobs, no triage — the ledger only holds `first_seen`, `notified_at`,
  reminders, `resolved_at`; #4 is notifier-driven too (3 notifications + 16 reminders, no
  decision entry). They are ranked on the stated rule anyway; the loop-era top ten is in
  `costliest.out.md`.
- **Ideal path** elements: **R** level-triggered reconcile (state, not edges; auto-close on
  recovery), **C** correlate (fingerprint + topology + time window, change events included),
  **K** known-error store (a past diagnosis or fix keyed by fingerprint), **V** verification
  ladder that authorises auto-ship, **D** durable execution (episodes resume, nothing re-runs
  blind), **N** none — a genuine owner decision (product direction, spend, irreversible loss,
  other people). Expected pages and MTTR are my estimates from the ledger's own timings, with
  the assumption stated per incident. MTTR = first signal → ledger closure; a service cannot
  recover faster than the service.

| # | id | what | pages | duration | jobs / $ | ideal |
|-|-|-|-|-|-|-|
| 1 | `inc-20260508T0000-e52` | the mini's recurring DNS/outbound failures (the 7-hour night of 05-08: 23 alerts, then 8 re-notifications) | 31 | 7 h night, 1,284 h tail | 0 | K R C |
| 2 | `inc-20260430T0733-e3` | container healthcheck false positive, 19 reminders | 20 | 124 h | 0 | R V (K) |
| 3 | `inc-20260801T1906-e599` | monitor-config sync with unresolved variables (ten monitors) | 20 | 11.4 h | 0 | C V R |
| 4 | `inc-20260908T0659-e944` | deploy churn → keyword monitor + derived group monitors | 19 | 78.5 h (59 h parents) | 1 | C R |
| 5 | `inc-20260704T1830-e268` | laptop job heartbeat missing, 17 reminders | 18 | 108 h | 0 | R C |
| 6 | `inc-20261017T2052-e77` | clean VPS kernel-update reboot became 18 pages | 18 | 7.9 min service, 107 h open | 12 / $0.08 | C R K |
| 7 | `inc-20260915T1045-e1060` | log-poller false positives + checkpoint-store race | 16 | 4.7 h | 3 | C V (K) |
| 8 | `inc-20261004T1540-e1114` | checkpoint log noise: park, 23 re-runs, 9 cards | 15 | 140 h | 32 / $2.30 | K C V D |
| 9 | `inc-20261021T1556-e267` | homelab hard reset, storage not remounted | 12 | 16.1 h (15.4 h service) | 11 / $0.07 | C N R |
| 10 | `inc-20261001T0731-e1368` | gateway crash + the loop paging on its own grep | 11 | 3.1 h | 5 / $0.15 | K C R |

Pages in the ten: 180 (at the upper bounds below: 8). Pages in the whole ranked pool: 446; the ledger holds 577
owner-facing notifications in all — 140 decision entries, 281 legacy notifications, 156
reminders — so 76 % of what reached the owner never went through `needs_decision`.

## 1. `inc-20260508T0000-e52` — a 7-hour outbound outage, then the same signature re-notified until 06-30

31 pages = 23 `notified_at` + 8 reminders; 23 `hermes_log` events (e52–e75, no e68), no item, no job.
- 05-08 00:00:19 first poller batch: "Cannot connect to host slack.com … [nodename nor servname
  provided]" (name resolution failing), cron delivery error, "Job Watchdog failed: Connection
  error", "API call failed after 3 retries" (e52–e55); each notified on sight (+0 min).
- 00:30 → 07:00:21 one half-hourly cron job failing the same way (e56–e75), a notification
  each. The night is ≈ 7 h; Slack, the delivery channel, was itself down.
- The rows are reused per recurrence: e53/e55 re-notified 05-12 11:30:39 (latest occurrence
  05-12 11:01Z), e54 six times up to 06-30 12:30:55 (latest occurrence 06-30 12:02Z). The
  connect-failure signature recurs on at least 15 distinct days between 05-06 and 08-29 (13
  from first_seen dates, plus the 05-12 and 06-30 recurrences of reused rows): a chronic
  resolver/connectivity problem on the mini, not one outage. `resolved_at` here is a
  retention sweep (06-08/06-15), not a recovery.
- No fix commit (dotfiles and hermes-agent are silent that night); the cause is not recorded.
- Owner touches: none recorded.

Ideal: **K + R + C**. The 23 lines are one fingerprint class on one host → one incident closed
on the first successful Slack/API call; the Nth recurrence of a fingerprint opens (or reopens)
one tracked known-error item instead of re-notifying; the notice is sent once, after recovery
(the channel was dead during it). Pages 31 → ≤ 1; MTTR (night) ≈ 7 h = the outage itself, the
1,284 h tail disappears. Fixing the resolver is a V step once someone finds the cause.
The baseline split this night into five incidents until the poll-jitter allowance; see limits.

## 2. `inc-20260430T0733-e3` — `garmin-sync` "unhealthy" for 124 h: the healthcheck was wrong

20 pages = 1 notification + 19 reminders (every ≈ 6 h); docker poll event e3, no item.
- 04-30 07:33:41 first_seen; 08:30:12 notified (+57 min); reminders until 05-05 10:30:15.
- 05-05 11:49:13 homelab `9ef11bf` "fix(garmin-sync): healthcheck considers WAL/SHM mtimes";
  12:00:09 `resolved_at`, 11 min later. The container had been syncing; SQLite in WAL mode
  writes `-wal/-shm`, the check only read the database file's mtime.
- Owner touches: none in the ledger; the fix was a manual commit on day 5.

Ideal: **R + V** (K for the next false-positive of this kind). Unhealthy-with-successful-syncs
is a diagnosable state: investigate with host reads (container logs show syncs, the check
reads one file), a one-line fix, ladder (healthcheck test + container turns healthy) →
auto-ship. Pages 20 → 0–1 (one if the cause cannot be named within 6 h); MTTR 124 h → ≈ 3 h.
Assumption: the investigation finds the defect from the check definition and logs.

## 3. `inc-20260801T1906-e599` — a monitor-config sync with unresolved variables

20 pages = 10 notified + 10 reminders; 20 events (10 Slack Down messages, 10 Kuma events),
no item. Service window 11.4 h.
- 19:02:14 homelab `45d7d45` (monitors.yaml: a new push monitor); 19:06:29–19:12 ten Down
  messages: HTTP probes "connect ECONNREFUSED" on loopback ports, three "Uptime" monitors
  "status code 401", four group monitors "Child monitors down".
- 19:30:51 warden first_seen (18–24 min after the raw messages); 20:00:55 notified (+54 min
  from first signal); 08-02 06:30:21 all ten monitors recover in the same second and get one
  reminder each; 08:35:49 `96da215` "refuse to sync when a ${VAR} is unresolved", test `6a75d02`.
- Cause (inference, strong): loopback ECONNREFUSED and empty-credential 401s are what unresolved
  `${VAR}` placeholders produce; the monitors.yaml commit is four minutes before the first
  failure (a sync would follow) and the fix the next morning is exactly that guard. The sync run
  itself is not in the ledger. A
  weaker candidate: the mini could not resolve names at 19:09 either (Hermes log, e586/e589).
- Owner touches: none recorded; the 06:30 re-sync was manual.

Ideal: **C + V + R**. Ten monitors changing state inside six minutes of a config deploy is a
change-correlated incident; the sync's own verification (probe what it just wrote, refuse an
unresolved variable) or an auto-rollback closes it. Pages 20 → 0–1; MTTR 11.4 h → ≤ 1 h.
Prevention beats healing here: the guard is the V step at the change itself.

## 4. `inc-20260908T0659-e944` — five deploys in 75 minutes, then derived monitors paging for 59 h

19 pages = 3 notified + 16 reminders; 5 nodes (the keyword monitor twice — Slack and Kuma —,
two parent group monitors, an unrelated push monitor), 1 investigate job (d22). Duration 78.5 h to the
child item's closure; the parents were red 59.2 h.
- 09-08 06:59:55 "Research Gateway - HTTP Down: 200 OK, but keyword is not in …"; 07:30:26
  warden sees the parent monitors `VPS` (e285) and `Services` (e710); 08:00:31 notified
  (+30 min after warden first saw them); 8 reminders each, last 09-10 17:14:00.
- 07:17–08:31 five code-changing commits to drain/shutdown/memory-pressure logic in
  research-gateway, each deployed (investigate d22, 18:02:47–18:10:08: "self-admitted
  bugs … overlapping old replicas"); `nextAction=human`.
- 09-10 18:02:40 warden `968f4ac` "the reminder path reads the ledger, and group monitors
  stop at the poller"; 18:14:11 parents `resolved_at` (11 min later); child e943 closed
  09-11 13:32:06 ("monitor recovered 09-11 09:16Z; no OOM kill in 4 days").
- A third parent (`Local`, e269) is its own incident here: 8 pages, 53.9 h.
- Owner touches: none; closed by the warden fix.

Ideal: **C + R**. A group monitor is derived state: never a page, only the child (topology:
parent → child); the deploy burst is a change window that holds the child's flaps. Pages 19
→ 1 (the child, until the keyword mismatch is fixed); MTTR bounded by the child's real fix
(hours to a day), not 59 h of reminders. Assumption: the investigation, with host reads,
sees a healthy container and a keyword mismatch.

## 5. `inc-20260704T1830-e268` — a laptop job's heartbeat missing for 4.5 days

18 pages = 1 notification + 17 reminders (≈ every 6 h); Kuma push event e268, no item.
- 07-04 18:30:52 push missed; 19:00:59 notified (+30 min); reminders to 07-09 05:30:59;
  06:30:10 `resolved_at`. No fix commit in dotfiles that week.
- Cause is not recorded. The monitor is the vault-backup job of the MacBook (a MacBook-only
  subsystem needing the desktop app); consistent with the job not running or the app locked
  until the next use (inference).
- Owner touches: none.

Ideal: **R + C**. Source host (a laptop) in the monitor's topology → class "expected-unavailable":
no reminders, one digest line after 24 h, close on the next heartbeat. Pages 18 → 0; MTTR
unchanged (108 h, bound to the owner's laptop) — this is the one case where the system should
*not* ask, and not an owner decision either (N does not apply).

## 6. `inc-20261017T2052-e77` — the 2026-10-17 outage: a clean VPS kernel-update reboot became 18 pages

Reconstructed in full (the PLAN's "21:22 became 16 pages"). 18 pages = 18 decision entries
(16 Kuma/Slack + 2 GitHub alert issues), 10 distinct Slack posts, 59 nodes, 50 items, 12
investigate jobs (1.95 M tokens, $0.08), service window 7.9 min, 18 items still
`needs_decision` at AS_OF (107 h later).

**Cause.** 20:49:07 clean shutdown, 20:56:42 boot of the VPS, kernel 6.8.0-138 → 6.8.0-147
(7.6 min; wtmp). The host has no unattended-upgrades log and the shutdown is clean with a
kernel bump: it reads as a deliberate reboot, not a fault (initiator not proven). Nine boot
records since March 7 (kernel bumps); ledger footprint of those with alerts: 06-05 (26 min down, 37 alert nodes, 0 pages), 07-07 (3
nodes), 08-09 (6 min, 12 nodes, 2 pages), 10-17 (60 nodes, 18 pages). 10-17 is the first
reboot since the triage loop could escalate.

**Timeline.**
- 20:52:02 first push miss; 20:52:27–20:56:37 eighteen monitors Down (RollHook-ready 530 first,
  Traefik last; 530s via the tunnel, 90 s timeouts on the tailnet path, push misses).
- 20:57:29 → 20:59:54 every monitor Up. Outage 7.9 min.
- Path A, Kuma webhook (`uk`): items created 20:54:14, nine auto-`quiet` at 21:04:42 —
  the recovered path resolved itself.
- Path B, GitHub alert issues (weatherorb #159/#160, door/egress): first_seen 21:04:42,
  triage 21:04:42, investigate 21:04:50 (20 s), pages 21:06:07 (+14 min) and 21:16:10; an
  old FPP-DB item reopens at 21:24:57, page 21:26:11.
- Path C, the same Kuma alerts via the Slack relay: first_seen **21:22:25** (22–30 min after
  the raw messages, Up and Down together), items 21:24:57, triage 21:55:11 (+30 min queue),
  nine investigations ≈ 20 s each (12 jobs in all with the GitHub path and the FPP-DB item),
  pages 21:56:12–13 (7 items, 3 cards), 22:06:16 (3, one card), 22:16:16–17 (5, three cards).
  Last page +84 min after the first signal.
- Every episode ended `verdict_only`, "unverified: shell denied" (the agw-readonly
  contradiction). **9 of 9 Slack-path briefs say "since 2026-10-17 21:22 UTC"** — warden's poll
  time — and the recommendations ask for logs at 21:15–21:30, after the outage had ended. A
  host read of the boot time would still have shown 20:56, so shell alone might have sufficed;
  the wrong clock would have cost a second round.
- After 22:16:17 nothing: 18 cards unanswered, 0 closed by hand, 0 re-investigations.
  The vps repo was committed to at 21:30:20 the same evening (shutterflow imgproxy), so someone
  was working there; none of the cards was answered.

Owner touches: 18 escalations, 0 actions.

Ideal: **C + R + K**. Topology (all 18 monitors sit behind one host's ingress) plus a 4.6-minute window is a host
event; a boot-time change on that host and the recovery of every monitor closes it at the
first tick after 20:59:54. K holds the class "VPS reboot: ≤ 10 min of flaps, self-recovers",
and a declared reboot (the actor records intent, as `operations` already does for deploys) makes
it expected. Pages 18 → 0 (one digest line: "VPS rebooted 20:49–20:56, kernel -147, green
since 20:59:54"); MTTR (ledger) 107 h → ≤ 5 min after recovery; jobs 12 → 0. N: none.

## 7. `inc-20260915T1045-e1060` — sixteen notifications in two hours, eight of them the loop's own diagnostics

16 pages, all legacy notifications (11 in one second at 12:45:54); 16 `hermes_log` items, 3
jobs, 15 closed by hand.
- 10:45:23 → 12:15 three "tools.checkpoint_manager: Git command failed: git add -A (rc=128)"
  (e1060, e1061, e1071); 11:45 two `WARNING … Tool terminal returned error` lines (e1063/e1064).
- 12:17:46 / 12:23:06 / 12:28:49 hermes-agent `37c887a`, `620683d`, `ead94fa` (lock the
  shared checkpoint store, apply the exclude file, retry a transient add; cross-process lock).
- 12:45:54 batch of 11: three more `git add` failures (e1074, e1078, e1079) + eight WARNING lines (e1075–e1077, e1080–e1084) whose
  JSON output contains the word "ERROR" — **poller false positives** from the agent's own
  tool calls. 12:53–12:58 eight closed by hand ("same poller false positive, duplicate of
  e1075"); 14:06:43 the gateway restarts with the lock fix; 15:29:05 last item closed ("zero
  index.lock failures since process start").
- Cause: a real race in the checkpoint store (two processes, `git add -A`, index lock; a nested
  repo as scratch) plus a classifier that matches "ERROR" as a substring of WARNING lines.
- Owner touches: 15 closed by hand (typed outside the loop, counted by definition).

Ideal: **C + V** (K from here on). Eight lines are one physical line seen twice or a WARNING
mistaken for an ERROR: a poller rule (level field, dedupe by physical line) collapses them;
the `git add` shape has a fix commit within 1.5 h; ladder: unit test for the lock, restart,
zero lock errors for an hour → auto-ship. The class was only written down on 10-01 (a skill
doc), so K helps the next round (#10), not this one. Pages 16 → 1; MTTR 4.7 h → ≈ 2 h
(restart-bound).

## 8. `inc-20261004T1540-e1114` — an expected skip logged at ERROR: parked 30 h, re-run 23 times, 9 cards

15 pages = 6 notifications + 9 decision entries (8 Slack posts); 8 items (6 `hermes_log`, 2
filed), 32 jobs (23 implement, 9 investigate; 2.1 h of agent wall time; 45.9 M tokens, $2.30);
140 h.
- 10-04 15:36–15:39 gateway restart ("Another gateway instance is already running", 15:39:36) →
  "Git command skipped … working directory not found" at ERROR, five signatures; 15:40:16 all
  six notified; items 15:50:21; investigate job fb932b1f.
- 15:56:14 and 16:16:14 every implement refused: "tier 'implement' exceeds the ceiling
  'investigate' for repo 'hermes-agent'" → `failed`. Parked until 10-05 21:58:18 ("re-drive
  after the dispatch policy changed": **30 h**).
- 10-05 21:58 → 10-07 01:54 23 implement episodes (an `implement` op every 10–15 min per item)
  ending in nine cards 10-05 22:48:28 … 10-07 01:59:20: "re-apply the patch to the live checkout
  and restart the gateway, or …" — the fix needs the pinned upstream checkout and a restart.
- 10-06 16:52:22 hermes-agent `0934dff` "log the expected missing-workdir checkpoint skip at INFO";
  16:52:40 six items closed by hand ("patch-check 15/15, deployed with gateway restart" — the
  improve loop). 1424 re-investigated by CLI 10-06 19:04:36, two `no_changes` re-drives, closed
  by hand 10-10 11:44:14 ("no local patch; deploy now waits out the drain, `6de9a88`").
- **Recurrence**: the same fingerprint family (`tools.checkpoint_manager`) ran 09-15 → 10-06:
  25 events, 25 pages, 30 dispatches. On 09-18 an item was closed "duplicate … nothing to
  repair", on 09-22 "expected skip, not a store defect" — the cause was named and the log
  level left at ERROR.
- Owner touches: 8 items closed by hand, 1 re-investigation request, 9 escalations.

Ideal: **K + C + V + D**. 09-22's diagnosis is the known-error entry ("expected skip: lower to
INFO"); the fingerprint (command and path normalised) makes 10-04's five signatures one item;
D removes the 30 h park and the 23 blind re-runs; ladder (patch-check, restart, zero ERROR
lines of the class for an hour) ships it. Pages 15 → 0–1 (family 25 → ≤ 2); MTTR 140 h → ≈ 3–6 h
from 10-04; jobs 32 → ≤ 6.

## 9. `inc-20261021T1556-e267` — a hard reset left the storage unmounted; eleven near-identical cards

12 pages = 11 decision entries (3 Slack posts) + 1 notification; 41 nodes, 22 items, 11
jobs (5 implement, 6 investigate; $0.07). Service window 15.4 h.
- 15:56:40 first status-page chatter; 16:04:50 homelab host boots with **no shutdown record**
  (a hang or power loss); 16:10:59 → 16:35 container and HTTP monitors Down (20+ on the Kuma
  path); the watchdog reports the external drive as disconnected at 16:20.
- Warden sees them 6–29 min late (16:11:39, 16:41:47); items 16:15–16:45; triage 16:45:29;
  notification 17:11:53 (+75 min); first investigate 17:16:16.
- 17:17:37 (5), 17:27:38 (5), 17:57:40 (1) cards: "[blocker] re-triage with host log access, or
  close as a benign one-off?" — shell denied again. Five implement episodes 17:57–18:26.
- 16:10:39 homelab `388817d` "re-check the HDD mount before declaring 'resolved itself'".
- 10-22 07:18–07:20 monitors recover after a manual intervention (Slack 07:40: "healthy after
  manual intervention period"); 07:22:58 the existing `uk` recovered-auto-close moves ten items
  to `quiet` ("event recovered on its own") — 3 minutes after recovery, 14 h after the cards.
- Owner touches: 11 escalations, 0 actions in the ledger (the fix was physical).

Ideal: **C + N + R** (V for the watchdog change). One host, one boot record, one drive missing →
one incident. This is the legitimate page: someone must act on site (other people). Pages 12 →
1; first page +75 min → ≈ +10 min; MTTR stays ≈ 15 h (physical), ledger closure ≤ 2 min after
recovery. Assumption: the reconciler can read the host's boot and mount state.

## 10. `inc-20261001T0731-e1368` — a Hermes crash, and the loop paging on its own grep (3 rounds)

11 pages, all legacy notifications; 13 nodes, 5 jobs ($0.15), 6 closed by hand; 3.1 h
(service window 1.04 h).
- 07:31:52 poller: two `WARNING … Tool terminal returned error` (e1368/e1369): an agent's own
  grep for "503" exiting non-zero. 07:57:22 Hermes HTTP Down; 08:04:02 push monitors
  (Hermes, Collie, Brain sync) down; the gateway process died uncleanly 08:04 and restarted 08:05.
- 08:04:03 investigate (job d5b1dc1d) → "self-inflicted diagnostic WARNING, not a fault"; 08:09:33
  closed by hand. 08:34:10 three more notifications (the Hermes push monitor again, and e1372/e1373:
  **the same noise**, from the next diagnostic); 08:50:26 closed by hand. 10:04:30 two more (e1380/e1381), 10:37:33 closed.
- 09:34 e1377 "streaming failed" = an upstream router blip (502), closed 09:36:33;
  09:37:04 closed by hand: "all three signatures are one Hermes process outage"; 09:45:30
  push monitor recovers.
- 6 of 11 pages were the loop re-ingesting its own diagnostics, three rounds in 2.5 h. The
  double-card WARNING family was documented in the hermes-agent skills at 08:10 and 10:37
  (`3de2bf4`, `c50cb4e`): a known-error store written by hand, not read by the poller.
- Owner touches: 6 closed by hand (agent sessions), 0 escalations.

Ideal: **K + C + R**. The class is known; the diagnostic-output filter is a poller rule; the
crash is one correlated incident closed at 09:45. Pages 11 → ≤ 1 (informational); MTTR 3.1 h →
≈ 1 h (service window).

## Where the agent money went (cost, not pages)

Whole ranked pool: 1,274 jobs, 1.55 B tokens, $73.9. Costliest single incident $5.49; all five
costliest are filed work, not alerts: weatherorb security/deps PRs (`e1608`, 32 jobs, 16 implement
+ 12 review, $5.49, revision ceiling 5, 3 open), weatherorb blend fixes (`e1558`, 30 jobs, $4.18),
the opencode-2.x harness (`e1511`, 14 jobs, 95 M tokens, $3.46, 0 pages), a warden spec
(`e1570`, 22 jobs, $2.81). Pattern: ≈ 8 implement + ≈ 8 review per item; review is half the
jobs. The ten above carry $2.6 of agent spend (51 M tokens) in total: the cost of incidents is owner attention.
Chronic items (not one incident under the baseline): `Agent Gateway - Push` 26 lifecycles (4
jobs), VPS edge p95 alert 25 lifecycles, `MacMini Dev Host - Push` 11 lifecycles, 25 jobs, $1.63.

## Closing table — would the design have healed these untouched?

● prevents or removes the cost named; (●) partly; N = a page remains by rule.

| incident | R reconcile | C correlate | K known-error | V verify ladder | D durable | N | pages | MTTR |
|-|-|-|-|-|-|-|-|-|
| 1 e52 outbound outage | ● 8 reminders, 53-day tail | ● 23 alerts → 1 | ● Nth recurrence, one item | | | | 31 → ≤ 1 | 1,284 h → 7 h |
| 2 e3 healthcheck | ● 19 reminders | | (●) next time | ● one-line fix ships | | | 20 → ≤ 1 | 124 h → ≈ 3 h |
| 3 e599 config sync | ● 10 reminders | ● change-window link | | ● verify/rollback the sync | | | 20 → ≤ 1 | 11.4 h → ≤ 1 h |
| 4 e944 group monitors | ● 16 reminders | ● parent ← child | (●) deploy churn | | | | 19 → 1 | 78 h → hours |
| 5 e268 laptop heartbeat | ● 17 reminders | ● source host | | | | | 18 → 0 | 108 h → same |
| 6 e77 VPS reboot | ● closes at 20:59:54 | ● 18 monitors, one host | ● reboot class | | (●) right time window | | 18 → 0 | 107 h → ≤ 5 min |
| 7 e1060 poller + race | | ● duplicates, 3 shapes | (●) next time | ● lock fix ships | | | 16 → ≤ 1 | 4.7 h → ≈ 2 h |
| 8 e1114 checkpoint noise | | ● 5 signatures → 1 | ● 09-22 diagnosis | ● log-level ships | ● 30 h park, 23 re-runs | | 15 → ≤ 1 | 140 h → ≈ 3–6 h |
| 9 e267 hard reset | ● closes at recovery | ● 20+ monitors, one host | | (●) watchdog fix | | N 1 page | 12 → 1 | 15 h → same |
| 10 e1368 crash + self-noise | ● closes 09:45 | ● one outage | ● own-grep class | | | | 11 → ≤ 1 | 3.1 h → ≈ 1 h |

Reading: R appears in 8 of the 10, C in 9, K in 4 (+3 partial), V in 4 (+1), D in 1 (+1); N is
genuinely needed once (#9), and for #5 the right answer is not to ask. The loop's pages here come
from edge-triggered notifiers (reminders: 156 in the ledger), from absent correlation (same
host, same minute: #6, #9), and from a loop that cannot tell its own output from a signal (#7,
#10) — not from decisions only the owner can make. At the upper bounds in the table the ten
incidents page 8 times instead of 180.

## What this changes or contradicts

- **PLAN "Established facts"**: "one outage on 10-17 21:22 became 16 pages" — 21:22:25 is
  warden's poll time; the outage was 20:52–20:59 (7.9 min), a clean VPS kernel-update reboot;
  pages = 18 (16 Kuma/Slack + 2 GitHub alert issues), 10 Slack posts. The "~30 of 74 pages
  are the agw-readonly contradiction" holds (#6 + #9 carry 26 of them: 16 + 10) but is not the whole
  story: 9 of 9 Slack-path briefs also quoted the wrong time.
- **Findings**: "OpenCode `~/.local/share/opencode/opencode.db` records every agw episode" is
  stale (last session 2026-10-15). agw's own store (`~/.local/share/agent-gateway/opencode/`,
  5,606 sessions since 10-14) is not read by usage-tracker, whose `opencode` cursor stops at
  2026-10-13 12:34; tokens for agw episodes after that are only in agw's store. usage-tracker's
  cost is 1× (Anthropic), 2× (deepseek-flash) and ≈ 2.9× (Pro) the cost OpenCode reports for the
  same tokens (`meta.cost_calibration`).
- **Findings** "63 % of signals via Slack relays" is right and understated: the relay lags a
  median 16 min (p90 28, max 72; n = 1,042) and the same Kuma alert arrives twice in both big cascades
  (#6, #9: `uk` webhook and Slack relay), only one copy auto-resolving (#6: 9 `uk` items quiet
  at 21:04:42, 16 pages from the Slack path).
- **Round 5 KPIs** count items that reached `needs_decision` (114 / 597, reproduced). The
  ledger also holds 281 legacy notifications and 156 reminders that never touch that state;
  the reminder path still fires (a "Deployed …" notice was reminded 5× between 10-13 and 10-21).
- `closed by hand` is on 203 of 597 items; most are typed by agent sessions (improve loop),
  so `owner_touch` measures "outside the loop", not owner effort.

## Limits

- Event rows are reused per recurrence (first_seen reset), so legacy incidents show only the
  latest occurrence; lifecycles are reconstructed from transitions where items exist.
- Baseline weaknesses: a busy repo fuses same-day filings (`inc-20261015T0124-e1540`, 29 nodes,
  66 jobs); a 5-hourly flapper is 26 micro-incidents (see `meta.chronic_items`); a bare 30 min
  cut the 05-08 night in five. Time-proximity rules cap at 8 h, skip chronic items, and run before
  the identity rules.
- Tokens exist from 2026-09-22; 317 of 1,308 dispatches have none (older, in-place or
  worktree-less). Not attributed: owner Claude Code sessions, Hermes loops, agw triage/decide calls.
- Boot records come from the hosts' wtmp over a read-only ssh command; if ssh is unavailable the
  script records `status: unavailable` and omits `host_reboot` tags.
- Causes marked "inference" rest on timing and error strings, not on a recorded action.
