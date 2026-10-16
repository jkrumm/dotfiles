---
description: Inventory of everything that repeats or watches on both Macs, each job's place on a five-level maturity ladder (today vs. target), the `jobrun` pattern, the defects found, and the migration order. v2, 2026-10-16; investigation only, nothing changed. Signal flow, Kuma's role and the remediation tiers are in ops-signals.md.
---

# Background jobs — inventory, maturity, migration (v2)

> **Verdict:**
> - **launchd stays the scheduler on both Macs.** Built-in no-overlap, catch-up on wake for
>   calendar jobs, KeepAlive restarts. A shared daemon would add a single point of failure and
>   fix nothing.
> - **What's missing is a run record and a route to a fix.** `jobrun` writes the record. warden
>   gets a `job` source and owns the fix, implementing from day one under guardrails. Kuma shrinks to an outside-in backstop
>   (`ops-signals.md` §2).
> - **One exception to "no daemon":** the MacBook's van-sampler needs a signed Swift executable as
>   its launchd program, for the Bluetooth TCC grant (`ops-signals.md` §7).

## Maturity ladder

| Level | Name | Means | Detector |
|-|-|-|-|
| **0** | unobserved | Runs; a failure exists only in a log nobody reads, or in `/tmp` | — |
| **1** | recorded | Each run leaves a structured record: `jobrun` state file, or the job's own state/`/health` | the job |
| **2** | dead-man covered | Something *independent* grades failure **and** absence with period + grace | `jobs-grade`, Kuma push, weatherorb watchdog `overdue_after`, warden heartbeat rows |
| **3** | self-healing | Retries with backoff and a deadline, a lock where needed, and escalates its own ladder before giving up | the job (netgear-watchdog, linewatch watchdog, research-gateway leases, DBOS, warden strikes) |
| **4** | remediated | A failure past T1 becomes a warden item in the owner repo, with a brief and verified closure | warden |

Levels are cumulative: a job at 3 must also be at 2. Self-healing that nobody can see failing is
still a 1. The target is the *right* level, not the highest. The detectors stop at 2 or 3 on
purpose: the heartbeat, Kuma pushers and warden itself must stay dumb, because a remediator cannot
remediate itself.

## Inventory with level today → target

Health notes are as of 2026-10-16 and come from logs only.

### Mini: dotfiles

| Job | Cadence | Today | Target | Note |
|-|-|-|-|-|
| `herdr`, `colima` (brew labels, wrappers) | KeepAlive | 3 | 3 | Restarts are human-timed (`make herdr-restart`); boot path asserted |
| `caddy`, `dnsmasq`, `tailscale`, `docker-socket` (root) | daemon | 2 | 2 | vendor |
| `postgresql@18`, `sleepwatcher`, `beszel-agent` | KeepAlive | 2 | 2 | `services` component |
| `~/.wakeup` | on wake | 0 | n/a on mini | Becomes the MacBook's on-wake grader (§MacBook) |
| `brain-sync` | 300s | 2 (on `jobrun`; graded) | 4 | Kuma 600 s → becomes a backstop; failures → warden |
| `brain-backup` | 03:30 | 2 (on `jobrun`; graded) | 4 | Keeps Kuma (data leaves the box) |
| `brain-web-refresh` | 300s | 2 (on `jobrun`; graded) | 4 | was log-only |
| `log-rotate` | 3600s | 2 (on `jobrun`; graded) | 2 | Its failures are cheap; list derived from plists (done) |
| `drift-check` | 09:40 | 2 (on `jobrun`; graded) | 2 | Exits 1 while a drift is open, so it grades `failing` until cleared. 2 drifts open. Findings become warden items (dotfiles owns the pins); Kuma `Drift` retires |
| `jobrun-canary` | 300s | 2 | 2 | The chain probe, see §Canary |
| `devhost-health` | 300s | 2 | 2 | A detector, so it stays dumb. 279/288 green over 24h |
| `lock-at-boot`, `obsidian-autostart` | RunAtLoad | 2 | 2 | — |
| `agent-gateway`, `-opencode` | KeepAlive | 3 | 3 | warden's own dependency, so Kuma is its backstop, not warden |
| `herdr.collie` | KeepAlive | 2 | 2 | Kuma `Collie` → backstop |
| herdr `overview` pane | `watch -n 30` | 2 | 2 | A UI, not a job |

### Mini: other SourceRoot repos

| Job | Owner | Cadence | Today | Target | Note |
|-|-|-|-|-|-|
| `ai.hermes.gateway` | hermes-agent | KeepAlive | 4 | 4 | `hermes_log` → triage; warden holds the restart verb. The one existing level-4 service |
| `hermes-liveness`, `-serve-liveness` | hermes-agent | 300s | 2 | 2 | Detectors |
| `hermes-serve` | hermes-agent | KeepAlive | 2 | 3 | — |
| `hermes-backup` | hermes-agent | 03:00 | **1** | 4 | Kuma green while the rotation fails every night: the push reports reaching the end, not step results |
| Hermes cron: briefing, report, narratives, drift audit | hermes-agent | daily/weekly | 1 | 4 | `last_status` → warden event, never an item. The 10-10 model 404 went untriaged |
| Hermes cron `91800bba0031` (human-queue retry) | hermes-agent | 15m | — | **delete** | Hard-coded to one request, resolved 10-01 |
| `warden-loop`, `-poll` | warden | 600/1800s | 3 | 3 | Kuma `Warden Loop` / `Hermes Watchdog` → fold into one |
| `warden-sweep` | warden | 300s | **1** | 3 | Only `/health` staleness, unmonitored. Recurring 403 on check-runs |
| `warden-api` | warden | KeepAlive | 2 | 2 | — |
| `warden-backup` | warden | 03:10 | 2 | 2 | Kuma `Warden Backup` (25 h) exists; v1 wrongly called it log-only. warden can't fix its own backup → Kuma |
| `modelpick-refresh` | modelpick | 06:00 | 0 | 4 | lmarena `coding` returns 0 rows: degraded but rc=0. Needs the step rc to propagate |
| `modelpick-web` | modelpick | KeepAlive | 1 | 2 | — |
| `weatherorb.*` services + DBOS workers | weatherorb | KeepAlive / DBOS cron | **4** | 4 | Reference citizen: DBOS (concurrency 1, stale cancel) + watchdog `overdue_after` + HyperDX → GitHub issue → warden |
| `weatherorb.{retention,verify}` | weatherorb | 04:30/05:45 | 0 | 4 | Or fold into DBOS schedules (owner's call) |
| `linewatch-*` | linewatch | KeepAlive/60s | 3 | 3 | ISP and router faults are human-only. Kuma `Home Line` stays (a symptom) |
| `usage-tracker` | usage-tracker | 900s | 2 | 4 | Heartbeat staleness today |
| `walkingpad` | walkingpad | KeepAlive | 1 | 2 | — |
| `audio-gateway` | audio-gateway | KeepAlive | 3 | 4 | OTel → HyperDX → #alerts → `slack_alert`. Last exit 127 inside `secrets-run`, unexplained |
| `research-gateway`, `-lightpanda` | research-gateway | KeepAlive | 4 | 4 | Leases + crash-loop guard + 10 HyperDX alerts |
| `research-gateway-deploy` | research-gateway | 120s | 1 | 4 | Own lock and deadline; failures are log lines only |

### Mini: IuRoot (`com.iu.prometheus-*`, prometheus-scripts)

| Job | Today | Target | Note |
|-|-|-|-|
| `epos-token`, `state-backup`, `conduktor-token` | 1 | 2 | `with-heartbeat.sh` ≈ `jobrun`; logs in `/tmp` |
| `artefact-daily`, `dashboard-autodeploy` | 0–1 | 2 | `/tmp` logs; autodeploy's WatchPaths self-triggers, held back only by a 60 s debounce |
| `vpn-watcher` | 1 | 3 | A real self-heal ladder, but its only alert is a desktop notification on a headless machine |
| `stack-dashboard` | 1 | 2 | — |

There are duplicate plists in `prometheus-stack/analysis/launchd/`.

### In-process loops

These stay in their processes and inherit their service's level. Visibility goes through `/health`
(the `services` probe) or OTel. Two gaps:
- the hermes overview/narrative pollers have no own deadline (they rely on the Hermes cron timeout);
- agent-gateway, warden, hermes and linewatch export no OTel.

### MacBook

| Job | Today | Target | Note |
|-|-|-|-|
| netgear-watchdog (Tinycast, 1m) | 1 | 3 | A best-in-class self-heal ladder that no detector watches. Tinycast kills, throttles and pauses it |
| van-sampler (Tinycast, 15m) | 1 | 3 | BLE TCC catch → Swift program |
| `opbackup` | 2 | 2 | Kuma weekly (data leaves the box) |
| `brain-sync`, `batt-reset`, `appearance-sync`, `db-tunnel`, `tailnet-sshd` | 0–1 | 2 | Graded on wake, local notification |
| `photoflow` | 0 | 2 | `/tmp` log |

Tally: about 50 jobs. **Level 4 today: 3** (hermes gateway, weatherorb, research-gateway).
**Level 0–1: about 30** — mostly timer jobs, IuRoot and the MacBook.

## Pattern

| Piece | Spec |
|-|-|
| `jobrun` (**built**, Wave 4) | `jobrun <label> --owner <repo> [--every <s>] [--timeout <s>] [--lock <name>] [--kuma <op-ref>] -- <cmd>`. Lives in dotfiles `scripts/jobrun.ts` (bun/TS, owner decision 6) → `~/.local/bin/jobrun`, tested with `bun test` in `make check`. It writes `~/.local/state/jobs/<label>.json` atomically: `run_id`, `started`, `finished`, `rc`, `duration_ms`, `every`, `owner`, `last_ok`, `consecutive_fail`, `fails_24h`, `tail` (40 lines), plus `owner_sha` (owner repo HEAD), `runs` (last 5) and `fail_times` (24 h, what `fails_24h` counts). A held `--lock` skips the run (rc 0, no state write, so absence grading catches a lock that never frees); a missed deadline is rc 124. Optionally it mirrors one OTLP log per run, best effort. `--kuma` only for the §2 backstop jobs |
| `jobs-grade` (**built**, expected set Wave 5: heartbeat `jobs` WARN component + `make doctor` table; warden and `~/.wakeup` consumers come later) | `scripts/lib/jobs-grade.ts` reads the state dir plus `launchctl print` and outputs `ok`, `failing`, `stale`, `flapping` or `unloaded` per job, as JSON. **The only grading logic.** The expected set is derived from the installed plists (`~/Library/LaunchAgents/*.plist`) whose ProgramArguments invoke `jobrun`: a declared label with no state file grades `unloaded` (not loaded) or `stale` (never recorded, once its first window since the plist mtime has passed), so a job that never ran is never invisible. Teardown targets `rm` the label's state file. It is called by the heartbeat (WARN lines), warden's `job` source (items), `make doctor` (table) and the MacBook's `~/.wakeup` (notify) |
| Labels and plists | `com.jkrumm.<repo>-<job>` for new jobs; no renames. The plist template lives in the owner repo, installed by its `make <x>-setup` |
| Logs | `~/Library/Logs/<label-suffix>.{log,err}`. `log-rotate.sh` derives its list from our plists' `Standard{Out,Error}Path`, so it is declared but never hand-kept |
| Map | `architecture-check.sh` also asserts map ⊆ live. Five stale weatherorb rows pass today |
| Step rc | A job with steps exits non-zero when any step fails. `jobrun` can't see inside a script that swallows errors; that bug belongs to the owner repo (hermes-backup, modelpick-refresh) |

## Canary

`com.jkrumm.jobrun-canary` (300 s, `make jobrun-canary-setup`, converged by `make setup` on the dev host) runs
`scripts/jobrun-canary.ts`, which exits 1 unless `config/jobrun-canary.json` has `"healthy": true`. The committed
value is always `true`. It is the end-to-end probe for Wave 7.

**Owner checkout decision (2026-10-16):** the canary's owner repo is `dotfiles`, because the file, the deploy
(`make deploy`) and the job all live here, and a canary in a repo nobody works in would not exercise the real
deploy. warden *parks* a merge into a checkout with a `working` herdr agent, so Wave 7 must run with the
dotfiles checkout idle: the orchestrator tab spawns it from another cwd and waits without working in
dotfiles, and no wave agent holds the checkout while the canary item is in flight.

## Defects found (fixes belong in the owner repos, not this plan)

| Defect | Owner |
|-|-|
| `hermes-backup` rotation has failed nightly since 09-21 while Kuma shows green | hermes-agent |
| Morning briefing reads the warden board on `:7734`, but warden moved to `:7735`. The 10-09 briefing showed "Board nicht erreichbar" | hermes-agent |
| `warden-sweep` gets 403 on check-runs (token scope) | warden + secrets (human) |
| `hermes_cron` failures are never triaged | warden |
| `audio-gateway` last exit 127 (`secrets-run: from_cache: command not found`) | dotfiles (`secrets-run`), unverified |
| `architecture.md` §Monitoring is missing `Agent Gateway`, `Warden Loop`, `Warden Backup`, `Hermes Serve`, `WeatherOrb Degraded`, `Home Line - Watchdog`, and lists five weatherorb timers that are now DBOS schedules | dotfiles |

## Migration order

This is the wave chain in **`docs/waves/PLAN.md`** (orchestrated, started 2026-10-16). The owner
decisions in `ops-signals.md` override the v2 analysis:
- warden is the only remediation loop, with no Hermes;
- implement from day one, with guardrails instead of a ceiling;
- direct webhooks into warden;
- IuRoot stays out of warden;
- bun/TS tooling;
- the MacBook pull is deferred.

IuRoot hygiene (`/tmp` logs, vpn-watcher alert surface, duplicate plists) is out of the chain, as
work-repo follow-ups.

## Open questions

None blocking. Resolved 2026-10-16:
- #alerts → a mirror plus the fallback;
- no ceiling;
- IuRoot out.

The van-sampler program shape (Swift executable vs `.app`) is settled by that wave's spike.
