---
description: How a background-job failure travels from the job to a fix or a human, on both Macs. Covers today's real flow (with evidence), Uptime Kuma's proper role, the remediation tiers and their latency budgets, the source of truth per question, dead-man's-switch vs failure semantics, and the MacBook. Design v2, 2026-10-16; investigation only, nothing changed. The inventory and migration plan live in background-jobs.md.
---

# Ops signals — from a failing job to a fix

> **Verdict: there is no framework today. There are four half-frameworks running side by side, and
> warden is attached to them only through a lossy, 30-minute Kuma snapshot.** The target:
> - **warden is the self-healing loop.** Every alert source feeds it directly.
> - **Kuma is the calm outside-in backstop.**
> - **A human is reached only through warden's own `needs_decision`, and that should be rare.**
>
> Implementation runs as the wave chain in `docs/waves/PLAN.md`.

## Owner decisions (2026-10-16) — these override anything below

1. **warden is THE self-healing loop. Hermes is out of the path entirely:** no digest, no
   narration, no remediation of job signals. Human contact goes through warden's own
   `needs_decision` (Slack #agents), and it should be extremely rare. Human-queue is used only for
   physical, biometric or TCC work.
2. **There is no investigate-only ceiling.** warden implements fixes from day one in every owned
   SourceRoot repo, backups and secrets-adjacent repos included. Secret *values* are never touched:
   a missing grant or scope becomes a human-queue ask. Autonomy is kept safe by guardrails rather
   than a ceiling:
   - the canary job proves the full loop end to end before real jobs are wired in;
   - closure is verified: an item is `fixed` only when the job's next run succeeds;
   - dedup is per label;
   - chronic detection: a reopen within 7 days goes to `needs_decision`;
   - **a single kill-switch.**

   **IuRoot stays out of warden.**
3. **Every alert source feeds warden directly**, not via Slack or Kuma snapshots:
   - the `job` source (`jobs-grade`);
   - Uptime Kuma, as a webhook to warden-api, replacing the 30-minute poll snapshot;
   - HyperDX alerts, as a webhook to warden-api instead of #alerts → `slack_alert`.

   **Slack #alerts becomes a human-readable mirror**, plus the fallback for when warden itself is
   down. Kuma watches warden; nothing else watches Kuma.
4. **Kuma is the calm backstop** per §2: three duties, `maxretries ≥ 1`, never faster than warden
   could act.
5. **Self-improvement cycles are part of the system** (§9). They run during the chain, then as a
   recurring warden duty folded into warden's existing improve loop (`warden/docs/improve/LOOP.md`).
6. **`jobrun` and `jobs-grade` are written in bun/TS**, not bash-with-JSON. **The MacBook → mini
   state pull is deferred until something consumes it.**

Where the analysis below still mentions Hermes digests, investigate ceilings or #alerts paging,
the decisions above win. The sections have been edited to match.

Evidence comes from the code with file:line references, and from warden's ledger read with read-only
queries. External practice was checked through `/research`; the launchd semantics come from the
local `man launchd.plist`.

## 1. Today's actual flow

| Job class | Path from failure to human | Gap |
|-|-|-|
| launchd timer, log-only (`warden-backup`'s twins, `modelpick-refresh`, `weatherorb.{retention,verify}`, `log-rotate`, `research-gateway-deploy`, `brain-web-refresh`) | failure → `~/Library/Logs/*.err` → **nothing** | Invisible. The heartbeat checks only KeepAlive labels (`lib/launchd-restarts.sh`), not timer jobs |
| launchd timer with a Kuma push (`brain-sync`, `brain-backup`, `hermes-backup`, `warden-backup`, `drift-check`) | missed push → Kuma DOWN after one interval (`maxretries: 0` everywhere) → **Slack #alerts → human at once**. In parallel `warden-poll` (every 30 min, snapshot via Argo) → `uk` item → 30 min debounce → triage → investigate | A human is paged **before** any self-heal or remediation. A DOWN that recovers between two polls is invisible to warden. The push carries success only, so `hermes-backup`'s nightly rotation error stays green |
| KeepAlive service | crash/restart → `check_launchd_restarts` (edge-triggered) → composite DOWN at once → #alerts. Dead port → `services` component → 3 runs (~15 min) → DOWN | Composite → warden only via `uk`. **0 of 14 `uk` items in 30 days reached `fixed`** (8 quiet, 6 resolved) |
| In-process loop | warn log or `/health`. research-gateway, audio-gateway and weatherorb also export OTel → HyperDX alert → #alerts webhook → warden `slack_alert`. weatherorb's own alerts become a GitHub issue → `github_go` | Only 3 of about 25 owners export OTel. agent-gateway, warden, hermes, linewatch, usage-tracker and modelpick don't |
| Hermes cron | error → `jobs.json` `last_status` → warden `hermes_cron` **event**, read only by the morning briefing; never made an item (`loop/core.py:56`) | The drift audit's 10-10 model 404 was never triaged |
| warden itself | loop wedged → no `Warden Loop` push → Kuma DOWN (≈40 min). Poller dead → no `Hermes Watchdog` push (35 min) | `warden-sweep` dead → only `/health` staleness, which no monitor watches |
| MacBook | Tinycast background commands; only `opbackup` has a Kuma monitor | Not represented in warden (`WARDEN_MACHINE` defaults to `mini`) |

What warden *does* convert well:
- human/issue origins: 17 + 11 fixed in 30 days;
- `hermes_log`: 1 fixed and 30 resolved.

Signals arriving through Kuma are mostly transient: of 14 `uk` items, 8 went quiet and 6 resolved.
That is the evidence for the owner's intuition. Kuma pages a human for things that heal on their
own, while the real defects (hermes-backup rotation, warden-sweep 403, log-only jobs) never page at all.

## 2. Kuma's role (confirmed with one amendment)

External practice (`/research`; SRE Book ch. 6 and 11, SRE Workbook ch. 5 and 8):
- Page only on what is urgent, actionable, needs intelligence, and is novel. "If a page merely
  merits a robotic response, it shouldn't be a page."
- Alert on symptoms, not causes.
- Aim for a 1:1 ratio of alerts to incidents.
- Batch-job and backup failures are **tickets**, not pages.
- Cronitor's advice is to page on the **third consecutive miss**, not the first flake.

Kuma keeps exactly three duties. All three are things only an outside observer can see:

| Duty | Monitors (target) | Why outside-in |
|-|-|-|
| **The remediation chain is alive** | `MacMini Dev Host` (composite), `Warden Loop` (extended to require poll and sweep freshness), `Agent Gateway` | If warden, agent-gateway or the mini itself is dark, nothing local can report it. This is the watcher of the watcher |
| **A user-facing symptom** | `Hermes Agent`, `WeatherOrb Watchdog` (public app), `Home Line` | A person notices these. They are symptoms, not causes |
| **Data left the box** | `Brain Backup`, `Hermes Backup`, `Warden Backup`, `1Password Backup` (25 h / weekly) | Only the receiving side can confirm an off-site copy |

Everything else leaves Kuma or becomes a slow backstop: `Brain Sync` (600 s), `Hermes Watchdog`
(folds into `Warden Loop`), `Drift` (its findings become warden items), `Hermes Serve`,
`Collie`, `Secret Seed`. The backstop rule:
- interval at least 2× the job's own escalation budget;
- `maxretries` at least 1;
- never faster than warden could have acted.

**Amendment: the composite must not go DOWN for a job failure.** If the planned `check_jobs`
component (v1) failed the composite, Kuma would become the reporting bridge again, which is
exactly the pattern being removed. Job failures show up as **WARN** lines in the composite's
message: visible when a human looks, never paging. The composite pages only on machine and
platform symptoms.

## 3. Tiers and latency budgets

| Tier | Owner | Does | Budget |
|-|-|-|-|
| **T0 record** | `jobrun` (wrapper) | Writes the run's start, finish, rc, duration, tail and run id to the state dir | 0 s |
| **T1 self-heal** | the job itself, plus launchd | In-job retry with backoff and a deadline, escalating its own ladder (netgear-watchdog is the model). Next-tick retry comes free from launchd. KeepAlive restarts after the 10 s throttle | Interval jobs: 3 consecutive failures **or** `max(3×every, 30 min)` without success. Daily jobs: 1 missed run + 2 h. KeepAlive: 3 heartbeat runs (≈15 min, the existing `DEVHOST_TRANSIENT_FAILS`) |
| **T2 remediate** | warden | New `job` source reads the graded state → item → triage → investigate or implement in the owner repo → merge → deploy → **closure verified by the job's next `last_ok`** | Ingest ≤ 10 min (loop cadence, local file read, no Argo hop). Existing debounce 30 min. Verdict ≤ 2 h |
| **T3 human** | see below | Only what T2 can't do | as below |

T3 channels, one purpose each:

| Channel | When | Latency |
|-|-|-|
| Slack **#agents** (warden) | `needs_decision` only: chronic, or warden truly cannot decide. Should be rare | async |
| **human-queue** (`ask-human`, filed by warden) | Physical, biometric (`op`, ACL push, secret seed) or a TCC grant, and nothing else | when the MacBook answers |
| **Kuma → #alerts** | Only the three outside-in duties in §2, i.e. the chain itself is down. #alerts also mirrors what warden received, for reading, not acting | ≤ 20 min for chain-alive, 25 h for backups |
| **macOS notification** | MacBook only. Local consequences for a present human (van battery, router) | immediate |

There is no Hermes digest (decision 1). warden's ledger and Argo `/warden` are the record.

## 4. Source of truth (one per question)

| Question | Truth | Not this, because |
|-|-|-|
| **Is job X healthy right now?** | **The `jobrun` state dir** (`~/.local/state/jobs/<label>.json`) on the job's machine. One grading function, `scripts/lib/jobs-grade`, is shared by the heartbeat, warden and `make doctor` | **Kuma** only knows "a push arrived": it has no rc and no tail, and loses a flap between pushes. **OTel/HyperDX** *can* alert on absence (a `threshold_type: below` search alert, verified), but it would put the mini's local truth behind the VPS collector. A network blip would then make every job look dead at once; the `ENOTFOUND` on the collector host in `audio-gateway.err` shows this happens. Its alerts also land in Slack, adding a hop before warden |
| **Is something being done about it?** | **warden's ledger** (item per `job:<machine>:<label>`) | It does not duplicate run history. It stores the incident and points at the state file |
| **What happened over time?** | **OTel, as a mirror only**: `jobrun` emits one best-effort OTLP log per run (`service.name=jobrun`, attributes `job`, `rc`, `duration_ms`) for dashboards and trends. Never alerting. Optional, late in the migration | — |
| **Is the chain itself alive?** | **Kuma** (§2) | — |
| **How does an alert reach warden?** | **Directly.** `jobs-grade` is read locally. Kuma and HyperDX post webhooks to a new warden-api ingest route (bearer token via `secrets-run`, behind a Caddy door) | The Argo snapshot poll (30 min, loses flaps) and #alerts → `slack_alert` (a human sees it first, and parsing is lossy). Both retire once their webhook is proven |

**Catch for the webhooks:** the mini is push-only today, because the tailnet ACL grants nothing
inbound from the homelab or VPS tags to the mini (`architecture.md` §Monitoring). An ingest door
therefore needs a new, narrow ACL grant: those two tags → the devhost on `tcp:443` only. That grant
is declared in `dotfiles-private` and applied from the MacBook (biometric), so it goes through
human-queue. A portless :443 grant cannot be narrower than the port, so the containment is in the
Caddy door: `scripts/caddy-tailnet.sh` answers 403 to every homelab/VPS source for every host but
`warden-ingest.<dev-domain>`, and that host proxies `/ingest/*` of warden-api only (never its
GET routes).

## 5. Dead-man's switch vs failure

| Situation | Example | Who detects it | How |
|-|-|-|-|
| Ran, failed | rc≠0, deadline hit | `jobrun` (T0) → grade | `consecutive_fail`, `last_rc` |
| Ran, "succeeded" while a step failed | `hermes-backup` rotation | the job: each step must propagate rc | Wrapper-level detection is impossible. This is the owner repo's bug |
| Didn't run: plist unloaded, exit 78, binary gone, a launchd firing missed | — | **The grader, not the job.** A job can't report its own absence. `jobs-grade` flags `now − last_started > every + grace` and cross-checks `launchctl print gui/501/<label>` for loaded state | Run by the heartbeat (WARN) and by warden (item) |
| Machine dark, heartbeat dead, or warden dead | — | **Kuma** (outside-in) | The only layer that survives the mini being off |
| Hung, still running | a deadlocked run | `jobrun --timeout` (TERM, then KILL); KeepAlive services through `/health` | launchd skips `StartInterval` firings while the job runs (`man launchd.plist`), so a hang otherwise looks exactly like "didn't run" |
| Crash-looping service | KeepAlive restart storm | `check_launchd_restarts` (exists) | launchd has no `StartLimitBurst` equivalent: it retries forever at the 10 s throttle. That makes this check our start limiter |
| Flapping | ok/fail alternating, so the consecutive counter never trips | `jobs-grade`: ≥ 3 failures in 24 h counts as failing even if interleaved, until the latest 3 runs are all green (a recovered job is not flapping; Wave 8) | One item stays open, never reopen churn |

launchd facts this relies on (from `man launchd.plist` on the mini):
- `StartInterval` firings are **missed** while the machine is asleep **or the job is still
  running**. This is a built-in `concurrencyPolicy: Forbid`, so `jobrun` needs a lock only across
  labels.
- `StartCalendarInterval` jobs **run on wake** if a firing was missed during sleep.
- Spawns are throttled to once per 10 s by default (`ThrottleInterval`).

## 6. What warden can own

| Failure class | warden action | Why |
|-|-|-|
| Code or config bug in any owned SourceRoot repo, backups and secrets-adjacent included | **implement**, from day one | warden's normal lane. Closure is verified from the state file |
| External transient (GitHub/network outage, upstream 5xx) | none: T1 absorbs it | It would only flap. The grade threshold filters it out before warden sees it |
| Credential or token scope (`warden-sweep` 403) | implement what can be done in code; the grant itself goes to **human-queue** | Secret values are never touched. warden writes the exact ask |
| TCC grant, FDA after an upgrade, `/login`, physical | **human-queue** directly | Only a human can do these |
| Resource (disk, swap) | implement (e.g. retention or a cleanup target in the owner repo) | Deleting data the owner hasn't scoped is `needs_decision` |
| warden's own jobs, agent-gateway | **none: Kuma** | A remediator cannot remediate itself |
| IuRoot jobs | **out** | Owner decision 2 |

**Guardrails in place of a ceiling:**
- **Canary first:** `com.jkrumm.jobrun-canary` must go failing → item → implement → merge → deploy
  → next run ok → `fixed` live before any real job is wired in.
- **Verified closure:** `fixed` requires a `last_ok` after the deploy SHA.
- **Dedup per label.**
- **Chronic:** a reopen within 7 days goes to `needs_decision`.
- **One kill-switch** (`warden pause`, plus a flag file read every pass) that stops all `job`
  dispatches without stopping ingest.

**Remediation brief** for a `job` item: one new template next to `_build_cluster_brief()`, capped
at 8000 characters like the others. It contains:
- the label, machine, owner repo and plist path;
- cadence and grade (`failing`, `stale`, `flapping`);
- the last 5 runs (rc, duration, start time) and a 40-line stderr tail;
- `git log` of the owner repo since `last_ok`, plus brew changes since then (a silent-revert class:
  `docs/homebrew.md`);
- the allowed actions: read-only host inspection (`LIVE_STATE_INSTRUCTION`) and changes in the
  owner repo;
- the forbidden actions: `launchctl` bootout/kickstart (except policy verbs), editing live plists,
  touching secrets;
- the acceptance check: "the job's next scheduled run writes rc=0". warden marks the item `fixed`
  only when the state file shows `last_ok` after the deploy.

**Loop and flap protection.** Reuse warden's existing mechanisms:
- 6 h escalation cooldown per signature;
- strikes (10/30 min → `failed`);
- infra re-drive 60/180/480 min;
- 3 open investigations per pass;
- compare-and-set claims.

Add for jobs:
1. The dedup key is the job label, so one item per job, ever. A reopen within 7 days marks it
   chronic and escalates to `needs_decision` instead of re-dispatching.
2. Grading is level-based (failing/stale), not edge-based, so recovering and failing again inside
   the cooldown never creates a second item.
3. A job that warden "fixed" and that fails again within 24 h is a `work` strike, not a fresh item.

## 7. MacBook

**The MacBook stays self-contained for detection and escalation. The mini *pulls* its state for
history only.**

Why:
- **A sleeping, roaming MacBook makes absence normal.** A mini-side dead-man's switch would page
  every night.
- **Its jobs' consequences are local.** A van battery or a router the mini cannot reach only
  matter to a human who, by definition, is present whenever the MacBook is awake.
- **So its T3 is a native notification and T2 is the job's own ladder.** netgear-watchdog
  already does this well: confirm, reconnect, data toggle, reboot, with a cooldown and battery
  awareness.

How:
- The same `jobrun` and state dir.
- Grade **on wake**: `~/.wakeup` (sleepwatcher) runs `jobs-grade --notify`, with staleness
  measured against awake time. `StartInterval` ticks missed while asleep are not failures.
- **The mini → MacBook state pull is deferred** until something consumes it (decision 6). When it
  comes, it goes over the existing `ssh iumac` and serves history only, never escalation.
- **When netgear-watchdog moves to launchd, delete what the move makes obsolete:**
  - the view-driven ticker;
  - the cross-process action lock (launchd already prevents overlap);
  - the LocalStorage watchdog state. It moves to a state file the Tinycast view reads.
- `opbackup` keeps its weekly Kuma monitor, because its data leaves the box (§2).

**Catch: van-sampler and Bluetooth TCC.**
- `van-ble` works today because Tinycast Beta is the TCC-responsible process for Bluetooth.
- Under launchd the responsible process is the job's **program**. If that is `bun`, which then
  spawns `van-ble`, the grant would likely attach to bun, not the helper (unverified; spike first).
- So the launchd job's program must be the binary carrying the usage string. That means either a
  signed CLI with an embedded Info.plist (`-sectcreate __TEXT __info_plist`) declaring
  `NSBluetoothAlwaysUsageDescription`, or a minimal `.app` bundle.
- This is the one place the "Swift daemon" idea earns its keep: van-sampler becomes a small Swift
  executable, since it is Swift already in `van-ble`.
- netgear-watchdog (curl, `networksetup`) has no TCC surface and stays bun under launchd.

## 8. How mature setups map here

| Concept | Reference (verified via /research) | Here |
|-|-|-|
| Restart policy | systemd `Restart=on-failure`, `RestartSec` (fixed; exponential via `RestartSteps`/`RestartMaxDelaySec` since v254) | `KeepAlive` + `ThrottleInterval` (fixed 10 s, no backoff). Wrappers add bounded retry where it matters (colima) |
| Start limit | `StartLimitBurst`/`StartLimitIntervalSec` | None in launchd. `check_launchd_restarts` is the detector |
| On-failure hook | `OnFailure=` | The `jobs-grade` → warden `job` source |
| Deadline | k8s `activeDeadlineSeconds` | `jobrun --timeout` |
| Overlap | k8s `concurrencyPolicy: Forbid`, Nomad `prohibit_overlap` | launchd skips firings while running (built in) |
| Missed runs | k8s `startingDeadlineSeconds` | Calendar jobs catch up on wake. Interval firings are lost, which is fine because the next tick covers them |
| Retry budget | k8s `backoffLimit` 6, 10 s→10 min; Nomad `restart`/`reschedule` | T1 thresholds (§3) |
| Check-in | healthchecks.io start/success/fail + `rid` + exit status, period + grace; Cronitor run/complete/fail + `series` | The `jobrun` state file *is* a local check-in. `jobs-grade` is period + grace. No SaaS needed |
| Page vs ticket | SRE: page = urgent and novel; batch/backup failures = ticket; 1:1 alert:incident | Kuma = page (§2), #agents = ticket, briefing = P3 |
| Alert on symptoms | SRE ch. 6 | Kuma watches symptoms and the chain; causes go to warden |

## 9. Self-improvement cycle

The cycle runs as review waves during the chain (`docs/waves/PLAN.md`). After the chain it becomes
a recurring duty in warden's existing outcome-triggered improve loop
(`warden/docs/improve/LOOP.md`), not a second loop.

**Metrics** come from one read-only query, `docs/waves/jobs-metrics.sql`, run as
`sqlite3 -header -column "file:$HOME/.warden/warden.db?immutable=1" < docs/waves/jobs-metrics.sql`.
Per source over 14 days it reports:
- opened, fixed, needs_decision, failed, quiet, false positives (closed as ignored), duplicates;
- average and maximum hours to fix;
- redrives;
- signatures opened more than once (reopen and chronic candidates);
- raw events vs items (alert noise).

**Review checklist** (each finding becomes a tuned threshold, brief or grade rule, or nothing):

| # | Question | Healthy | Tune |
|-|-|-|-|
| 1 | Did every job failure reach warden as exactly one item? | events ≈ items for `job`; no dup | dedup key, flap rule |
| 2 | Fixed vs opened for `job`, `uk`, `hyperdx` | ≥ 70 % fixed; the rest quiet for a reason | brief content, routing rules |
| 3 | Time to fix | median ≤ 2 h, max ≤ 24 h | debounce, loop cadence, cooldowns |
| 4 | Reopened within 7 days | 0. Each one is a wrong fix or a wrong grade | brief acceptance check, grade thresholds |
| 5 | `needs_decision` count | ≤ 1 per week | Why could warden not decide? Move that class to implement or to human-queue |
| 6 | False positives (closed ignored) | trending to 0 | T1 thresholds (§3), `ignore` patterns |
| 7 | Kuma DOWNs that reached #alerts while warden was up | 0 (Kuma should only fire when the chain is down) | Kuma intervals and retries (§2) |
| 8 | Any job still at ladder level 0–1 | none in owned repos | adopt `jobrun` |
| 9 | Kill-switch used? Why? | — | whatever made it necessary |

The cycle records one journal line per cycle in `warden/docs/improve/JOURNAL.md`.
