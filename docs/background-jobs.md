---
description: Inventory of everything that repeats or watches on the mini (launchd, in-process loops, Hermes cron, warden), a target home per job, the one pattern both Macs share, and the migration order. Investigation 2026-10-16; read-only, nothing was changed.
---

# Background jobs — inventory and target pattern

> **Verdict: launchd is already fine on the mini. Don't build a shared daemon here.**
> launchd already handles scheduling, boot start, restart, and per-label
> no-overlap: it never starts a second instance of a label that is still running.
> The workloads that need durable state already have a home:
> - weatherorb uses DBOS queues
> - warden uses its ledger plus heartbeat rows
> - research-gateway uses DB leases
>
> A shared daemon would put one process in front of a dozen unrelated repos. That is the
> failure warden was pulled out of Hermes to avoid (`architecture.md` §warden).
> **The gap is visibility, not execution.** About a dozen jobs report failure only as a log
> line, and nothing checks whether a timer job actually ran. The fix:
> - a standard wrapper (`jobrun`) that writes one state file per run
> - one heartbeat component that grades all those state files
>
> The MacBook's reason for a daemon is Tinycast's runtime, not launchd. The same answer
> applies there: launchd plists plus `jobrun`, with Tinycast reading the state files.

Snapshot taken 2026-10-16 from `~/Library/LaunchAgents`, the owned `/Library` daemons, the
crontab (empty), `~/.wakeup`, herdr pane processes, the Hermes cron store, and every log under
`~/Library/Logs`. No job was run.

## Inventory and classification

Targets:
- **L** — plain launchd job (keep)
- **L+** — launchd job, adopt `jobrun` (see Pattern)
- **D** — shared per-machine daemon
- **H** — Hermes cron
- **W** — warden
- **S** — herdr Claude session
- **X** — delete

None of the jobs below landed on D.

### launchd — dotfiles

| Job | Cadence | Failure surface | Health 2026-10-16 | Target — reason |
|-|-|-|-|-|
| `herdr`, `colima` (brew labels, wrappers) | KeepAlive | heartbeat `boot path` | up | L — supervised boot path, already asserted |
| `caddy`, `dnsmasq`, `tailscale`, `docker-socket` (root) | daemon | heartbeat `dev vhosts`, `tailnet` | up | L — vendor daemons |
| `postgresql@18`, `sleepwatcher` | KeepAlive | `services` component | up | L |
| `~/.wakeup` (sleepwatcher hook) | on wake | none | n/a | L — event hook; the mini never sleeps, so it is effectively MacBook-only |
| `brain-sync` | 300s | Kuma `Brain Sync - Push` | ok | L+ — already pushes Kuma; gets the state file for free |
| `brain-backup` | 03:30 | Kuma `Brain Backup - Push` | ok | L+ |
| `brain-web-refresh` | 300s | log only | ok | L+ — log-only today |
| `devhost-health` | 300s | Kuma composite (18 components) | 279/288 green over 24h; reds were disk and swap; occasional push rc=28/56 | L — this *is* the health surface. Never wrap it in anything it monitors |
| `drift-check` | 09:40 | Kuma `Drift` | ok, 2 drifts open (collie, tailscale) | L+ |
| `log-rotate` | 3600s | log only | ok (70 files) | L+ — also: derive its list from plists, see Pattern |
| `beszel-agent` | KeepAlive | the hub notices | reconnects, ok | L |
| `lock-at-boot`, `obsidian-autostart` | RunAtLoad | heartbeat `obsidian` | ok | L |
| `agent-gateway`, `agent-gateway-opencode` | KeepAlive | in-process Kuma push every 60s, plus heartbeat `agent-gateway jobs` | up | L — the Kuma push is not in `architecture.md` §Monitoring |
| `herdr.collie` | KeepAlive | Kuma `Collie` | up | L |
| herdr `overview` pane (`watch -n 30`) | 30s | heartbeat `overview pane` | alive | L — the only loop running in a herdr tab; a human looks at it, it is not a job |

### launchd — other SourceRoot repos

| Job | Owner | Cadence | Failure surface | Health | Target — reason |
|-|-|-|-|-|-|
| `ai.hermes.gateway` | hermes-agent | KeepAlive | `hermes-liveness` → Kuma | up | L |
| `hermes-liveness`, `hermes-serve-liveness` | hermes-agent | 300s | Kuma | one miss 10-15, no error since | L — success is silent by design |
| `hermes-serve` | hermes-agent | KeepAlive | its own liveness job | up (last exit 143 = SIGTERM) | L |
| `hermes-backup` | hermes-agent | 03:00 | Kuma `Hermes Backup` | **rotation fails nightly** (`cannot delete non-empty directory sidecars-excluded-20260921`) | L+ — Kuma is green while the rotation is broken; a state file with the step rc would show it |
| `warden-api` | warden | KeepAlive | `/health` | up | L |
| `warden-loop` / `-sweep` / `-poll` | warden | 600 / 300 / 1800s | ledger heartbeat rows (flagged after 3× interval), Kuma `Warden Loop`, Kuma `Watchdog` | loop ok; **sweep: recurring 403 reading check-runs** on a weatherorb SHA; poll: schema-mismatch crash 10-14, quiet since | W — already the owner; has its own lock (compare-and-set), backoff (`core.strike`) and heartbeat. Don't wrap |
| `warden-backup` | warden | 03:10 | log only | ok | L+ |
| `modelpick-refresh` | modelpick | 06:00 | log only | 3/3 steps ok; lmarena `coding` returned no rows | L+ |
| `modelpick-web` | modelpick | KeepAlive | none | up | L |
| `weatherorb.{serve,tileserver,public,sync}` | weatherorb | KeepAlive | `weatherorb.watchdog` | up | L — `sync` is the vendor's own 15-min repeat loop and can only fail by exiting |
| `weatherorb.worker-{ingest,round}` | weatherorb | KeepAlive (DBOS) | watchdog `overdue_after` → Kuma | up | L — DBOS is weatherorb's scheduler: obs */20, fcstlog */15, archive :40, backfill 07:15, round 3h. Concurrency 1 per queue, stale-run cancel |
| `weatherorb.{retention,verify}` | weatherorb | 04:30 / 05:45 | log only | ok | L+ |
| `weatherorb.watchdog` | weatherorb | 900s | Kuma | ok | L |
| `linewatch-{collector-agent,watchdog}` | linewatch | KeepAlive | Kuma `Home Line` (via heartbeat) | ok | L — the watchdog keeps its own ledger and disarm files; it is already its own daemon |
| `linewatch-heartbeat` | linewatch | 60s | Kuma | ok | L |
| `usage-tracker` | usage-tracker | 900s | heartbeat (staleness) | ok | L+ |
| `walkingpad` | walkingpad | KeepAlive | log only | ok | L |
| `audio-gateway` | audio-gateway | KeepAlive | `services` component | up; **last exit 127** (`secrets-run: from_cache: command not found`, 10-15). Cause not verified | L |
| `research-gateway{,-lightpanda}` | research-gateway | KeepAlive | `services` | up | L |
| `research-gateway-deploy` | research-gateway | 120s | log only | last tick: `git fetch` failed (network), retries | L+ — hand-rolled mkdir lock (stale after 2h) plus deadline; `jobrun --lock` replaces the lock |

### launchd — IuRoot (`com.iu.prometheus-*`, owned by prometheus-scripts)

| Job | Cadence | Failure surface | Health | Target — reason |
|-|-|-|-|-|
| `epos-token`, `state-backup`, `conduktor-token` | 300 / 3600 / 21600s | own `with-heartbeat.sh`; logs in `/tmp` | running | L+ — `with-heartbeat.sh` already does what `jobrun` would. Fix the `/tmp` logs |
| `artefact-daily` | 07:30 | `/tmp` log only | ran | L+ |
| `dashboard-autodeploy` | 600s + WatchPaths | `status.json` + `/tmp` log | ok | L+ — WatchPaths watches the dir it writes `status.json` into; only a 60s debounce prevents a self-trigger loop |
| `stack-dashboard` | KeepAlive | none | up | L |
| `vpn-watcher` | KeepAlive (asyncio supervisor) | **macOS desktop notification only** | up | L — a headless mini shows nobody that notification, so its alerts go nowhere. Needs a push surface |

Also: `prometheus-stack/analysis/launchd/` duplicates four of these labels. The installed plists
point at prometheus-scripts.

### Inside processes (not launchd)

| Loop | Cadence | Failure surface | Target — reason |
|-|-|-|-|
| research-gateway: lease adoption, TTL sweep, memory/loop-lag watch | 5–60s | logs + `/health` | L (stays in-process) — owned state; `/health` is its surface |
| agent-gateway: Argo overview push, per-job idle watchdogs | 10 min / per job | warn log | L (in-process) |
| audio-gateway: stale podcast sweep | 60s | warn log | L (in-process) |
| walkingpad: BLE reconnect, Argo sync | 1–60s | logs | L (in-process) |
| linewatch server (container): speedtest, router poll | hourly / 10 min | console | L (in-process) |
| prometheus dashboard (container): snapshot, sampler, repair worker (polls about 1s even when idle) | 1s–30 min | `logger.exception` | L (in-process) — the owner repo's call |
| hermes `agents-overview.py`, `project-narratives.py` job polls | 10–20s, **no deadline** | none (rely on Hermes cron timeout) | H — bounded by the cron timeout, acceptable |

In-process loops stay where they are. Their state is the process's state, and moving them would
only add IPC. Their visibility is each service's `/health`, which the `services` component
already probes.

### Hermes cron (in the gateway process, invisible to launchd)

| Job | Schedule | Health | Target — reason |
|-|-|-|-|
| Morning briefing / Evening report | weekdays 07:00 / Mon–Thu 22:00 | ok | H — LLM synthesis delivered to Slack |
| Project narratives | 06:30 daily | ok | H |
| Brain drift audit | Sat 09:00 | **last run errored** (model 404); re-pinned, first proof 10-17 | H — needs judgment |
| Human-queue push retry `91800bba0031` | every 15m | runs fine, does nothing | **X** — hard-coded to one request (`…-23770`), resolved and reported 10-01; 1800+ idle runs since |

## Pattern (both Macs)

The schedule stays in launchd and the reporting moves into one wrapper.

| Concern | Rule |
|-|-|
| Label | `com.jkrumm.<repo>-<job>`. Existing labels keep their names: a rename is churn across Kuma, `architecture.md` and the plist templates for no gain |
| Plist source | The **owner repo**, as `*.plist.template`, installed by that repo's `make <x>-setup`/`-teardown`. Dotfiles holds only dotfiles-owned jobs, next to their script (today's layout, e.g. `brain/`, `drift/`). No central plist dir: ownership follows the code |
| Program | `jobrun <name> [--every <s>] [--timeout <s>] [--lock <name>] [--kuma <op-ref>] -- <cmd>` — dotfiles `scripts/jobrun`, linked into `~/.local/bin` |
| What `jobrun` does | Prefixes every output line with a timestamp. Applies a wall-clock deadline (TERM, then KILL). `--lock` is only for exclusion *across* labels; launchd already stops a label overlapping itself. Atomically writes `~/.local/state/jobs/<name>.json` (`started`, `finished`, `rc`, `duration`, `every`, `last_ok`, `consecutive_fail`). Pushes Kuma only when `--kuma` is set and rc=0. About 80 lines of bash, no dependencies |
| Logs | `~/Library/Logs/<label-suffix>.{log,err}`, never `/tmp`. `log-rotate.sh` takes its list from our own plists' `StandardOutPath`/`StandardErrorPath` (`com.jkrumm.*` and `com.iu.*`). That keeps "declared, never globbed" without a hand-kept list that drifts |
| Health | One new heartbeat component, `check_jobs`. It reads the state dir and FAILs a job when `last_ok` is older than 3×`every` or `consecutive_fail ≥ 3`. It reports WARN-only for jobs not marked critical. That brings every log-only job above onto the existing composite Kuma monitor with no new monitor per job |
| Escalation | Kuma → Slack stays the only paging path. A dedicated Kuma monitor only where something outside the machine depends on the job (backups, brain sync). human-queue is for actions that need a present human, never for alerting. Desktop notifications only on the MacBook, never as the sole surface on the mini |
| `make doctor` | Prints the state-dir table (job, last ok, rc, streak). Read-only |
| Map | `architecture-check.sh` also asserts **map ⊆ live** on the machine that owns the row. Today it checks only live ⊆ map, so five stale weatherorb rows (`obs`, `fcstlog`, `archive`, `backfill`, `round`, now DBOS schedules) pass unnoticed |

**MacBook / tinycast-extensions:**
- netgear-watchdog becomes a 60s plist and van-sampler a 900s plist, each running
  `jobrun … -- bun run <engine>.ts` with the existing TS logic.
- Each engine keeps its own state file next to `jobrun`'s; Tinycast only reads them.
- Notifications use `osascript`, or ntfy, which already runs there.
- A Swift daemon pays off only if one engine needs sub-minute cadence or a long-lived
  connection. Nothing in the brief does.

## Migration order

Each step stands alone, starting with the least risky.

1. **Map hygiene.** Drop the five stale weatherorb rows; add the map ⊆ live assertion. Verify: `make doctor` passes, and fails with a fake stale row added.
2. **Delete Hermes cron `91800bba0031`** (via `hermes cron`) and its row in `hermes-agent/docs/scheduled-jobs.md`. Verify: `hermes cron list`.
3. **Ship `jobrun` plus `check_jobs`, with `check_jobs` reporting WARN-only at first.** Adopt it on dotfiles' own timer jobs: `brain-web-refresh`, `log-rotate`, `drift-check`, then `brain-sync` and `brain-backup` (their Kuma push moves into `--kuma`). Verify: state files appear and `make devhost-health-check` shows `jobs ok (n)`.
4. **Derive the log-rotate list from plists.** Verify: the `log-rotate` log count matches or exceeds today's 70, and nothing outside our labels is touched.
5. **Adopt `jobrun` in the other repos' log-only jobs**, one repo per commit: `hermes-backup`, `warden-backup`, `modelpick-refresh`, `weatherorb.{retention,verify}`, `usage-tracker`, `research-gateway-deploy`. Verify: each shows in `check_jobs`. Then switch the component to FAIL for jobs marked critical (the backups and the deploy).
6. **MacBook: move the tinycast-extensions engines to launchd plus `jobrun`**; Tinycast reads the state. Verify: an engine keeps running with a Tinycast view open, and `make doctor --local` on the MacBook lists it.
7. **IuRoot (`prometheus-scripts`).** Move its `/tmp` logs to `~/Library/Logs`, give vpn-watcher a push surface, and drop the duplicate plists in `prometheus-stack`. Work repo, own PR.

Found during the inventory and outside this pattern, so they need fixes in their owner repos:
- `hermes-backup` rotation
- `warden-sweep` 403 on check-runs (token scope)
- `audio-gateway`'s exit 127 inside `secrets-run`
- `architecture.md` §Monitoring is missing the agent-gateway and `Warden Loop` Kuma monitors

## Open questions

1. Should `check_jobs` FAIL the composite for every job, or only for jobs marked critical? My
   tendency is critical-only. Otherwise one flaky refresh job keeps the composite red, and the
   history above shows how long a red composite gets ignored.
2. Does the IuRoot side adopt `jobrun`, or keep `with-heartbeat.sh` and only fix its log paths?
   They do the same job, and it is a work repo.
3. MacBook: is launchd plus `bun` the end state (my recommendation), or is a Swift daemon still
   wanted for native notification actions? Those buttons would justify one.
