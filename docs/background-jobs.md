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

Levels are as of 2026-10-17 (Wave 17). A `jobrun`-wrapped job is level 4 by construction: `jobs-grade` feeds warden's `job` source, which briefs the owner repo and closes only on a verified next run. That path is proven live on two items (the canary, Wave 7; the drift-audit cron, Wave 11).

### Mini: dotfiles

| Job | Cadence | Today | Target | Note |
|-|-|-|-|-|
| `herdr`, `colima` (brew labels, wrappers) | KeepAlive | 3 | 3 | Restarts are human-timed (`make herdr-restart`); boot path asserted |
| `caddy`, `dnsmasq`, `tailscale`, `docker-socket` (root) | daemon | 2 | 2 | vendor |
| `postgresql@18`, `sleepwatcher`, `beszel-agent` | KeepAlive | 2 | 2 | `services` component |
| `~/.wakeup` | on wake | 0 | n/a on mini | Becomes the MacBook's on-wake grader (§MacBook) |
| `brain-sync` | 300s | 4 (`jobrun` + `job` item) | 4 | Kuma 600 s → becomes a backstop; failures → warden |
| `brain-backup` | 03:30 | 4 (`jobrun` + `job` item) | 4 | Keeps Kuma (data leaves the box) |
| `brain-web-refresh` | 300s | 4 (`jobrun` + `job` item) | 4 | was log-only |
| `log-rotate` | 3600s | 2 (on `jobrun`; graded) | 2 | Its failures are cheap; list derived from plists (done) |
| `drift-check` | 09:40 | 2 (on `jobrun`; graded) | 2 | Exits 1 while a drift is open, so it grades `failing` until cleared. 2 drifts open. Findings become warden items (dotfiles owns the pins); Kuma `Drift` retires |
| `jobrun-canary` | 300s | 4 | 4 | The chain probe, see §Canary. **Proven live 2026-10-16:** committed `healthy:false` → warden fixed, merged, deployed and closed it with no page |
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
| `hermes-backup` | hermes-agent | 03:00 | 4 (`jobrun` + `job` item) | 4 | Wave 11: `jobrun --every 86400 --kuma op://hermes/uptime-kuma/backup-push-url`; the script no longer pushes (Wave 1 made its rc honest, `jobrun --kuma` pushes only on rc 0) |
| Hermes cron: briefing, report, narratives, drift audit | hermes-agent | daily/weekly | 4 (`jobs-grade` cron adapter + `job` item) | 4 | Wave 11: `jobs.json` `last_status` → `hermes-cron.<slug>` run record → `job` item for hermes-agent; the `hermes_cron` event source is retired. Only the last outcome is known, so a failed daily/weekly job grades `failing` at once. The 10-10 drift-audit model 404 is the first live item |
| `warden-loop`, `-poll` | warden | 600/1800s | 3 | 3 | Kuma `Warden Loop` / `Hermes Watchdog` → fold into one |
| `warden-sweep` | warden | 300s | 2 (Wave 16: its `/health` heartbeat gates the `Warden Loop` push, so a dead sweep pages through Kuma) | 3 | Only `/health` staleness, unmonitored. Check-runs 403 is by design (fine-grained PATs have no Checks permission; warden uses the Actions-runs fallback) — no fault |
| `warden-api` | warden | KeepAlive | 2 | 2 | — |
| `warden-backup` | warden | 03:10 | 2 (on `jobrun`; graded) | 2 | Wave 11: no `--kuma`, the script pushes `Warden Backup` (25 h) itself from a mode-600 file (its op:// ref cannot be seeded from the mini). warden can't fix its own backup → Kuma stays the backstop |
| `modelpick-refresh` | modelpick | 06:00 | 4 (`jobrun` + `job` item) | 4 | Wave 10: a failed collector or one returning 0 rows now exits 1 (`RefreshResult.degraded`), so a half-empty refresh grades `failing` and becomes a `job` item for modelpick. Per-category emptiness inside one source (lmarena `coding`) is still not caught |
| `modelpick-web` | modelpick | KeepAlive | 1 | 1 | **Accepted straggler (Wave 17):** a read-only dashboard on :7727, no job and no consumer that pages on it. A probe would cost a services row for a UI nobody depends on |
| `weatherorb.*` services + DBOS workers | weatherorb | KeepAlive / DBOS cron | **4** | 4 | Reference citizen: DBOS (concurrency 1, stale cancel) + watchdog `overdue_after` + HyperDX → GitHub issue → warden |
| `weatherorb.{retention,verify}` | weatherorb | 04:30/05:45 | 4 (`jobrun` + `job` item) | 4 | Wave 11: `jobrun --every 86400`; a failure opens a `job` item routed to weatherorb. Folding into DBOS schedules stays the owner's call |
| `linewatch-*` | linewatch | KeepAlive/60s | 3 | 3 | ISP and router faults are human-only. Kuma `Home Line` stays (a symptom) |
| `usage-tracker` | usage-tracker | 900s | 4 (`jobrun` + `job` item) | 4 | Wave 10: `--timeout 600`; the heartbeat's log-mtime probe is gone (the `jobs` component is WARN-only, so staleness no longer FAILs the composite) |
| `walkingpad` | walkingpad | KeepAlive | 2 | 2 | The heartbeat `services` component probes its HTTP port (`probe_walkingpad`) |
| `audio-gateway` | audio-gateway | KeepAlive | 4 | 4 | OTel → HyperDX → `Warden ingest` webhook → `hyperdx` item. `LastExitStatus` 127 is the 10-14 in-place `secrets-run` rewrite (Wave 2, fixed); the process is running and the value clears at its next restart, nothing kickstarted |
| `research-gateway`, `-lightpanda` | research-gateway | KeepAlive | 4 | 4 | Leases + crash-loop guard + 10 HyperDX alerts |
| `research-gateway-deploy` | research-gateway | 120s | 4 (`jobrun` + `job` item) | 4 | Wave 10: `jobrun --lock research-gateway-deploy --timeout 7200` replaced the mkdir lock and stale-lock reclaim (also behind `make deploy`). A red CI or a deferred (busy) tick is rc 0 by design; only fetch/install/unhealthy-restart fail |

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
| netgear-watchdog (`com.jkrumm.netgear-watchdog`, launchd 60 s, `jobrun`) | **DOWN on the MacBook, level 0** (Tinycast no longer hosts it and the launchd install is still pending: ask `20261016T190047-10176`, the `macbook-installs` herdr agent; the level-2 version is written and pushed on `wave/netgear-launchd`) | 3 | The self-heal ladder is unchanged and now runs outside Tinycast (no kill, no pause, ticks with a view open). The view reads `~/.local/state/netgear-watchdog/state.json`. Live proof pending the MacBook install |
| van-sampler (`com.jkrumm.van-sampler`, launchd 15 min, `jobrun`, signed `van-ble --supervise`) | **not live** (still the Tinycast command, level 1; the level-2 version is on `wave/van-sampler`, gated on the Bluetooth TCC spike, a pending owner ask on the MacBook) | 3 | Leaves Tinycast (which ran it only with no view open). The Tinycast `van-sampler` command and its LocalStorage state are deleted on the branch; state is files in `~/.local/state/van-sampler/` that the Van Power view shares. Spike, evidence and the `.app` fallback: `tinycast-extensions/docs/van-sampler-tcc.md`. Becomes level 2 only when the spike passes and the install is verified |
| `opbackup` | 2 | 2 | Kuma weekly (data leaves the box) |
| smb-keepalive (`com.jkrumm.smb-keepalive`, launchd 60 s + network change, `jobrun`) | 2 | 2 | Born on `jobrun` (2026-10-19): remounts a stale HomeLab Samba share; exits non-zero only on a failed (re)mount, unreachable is normal. Graded on wake |
| `brain-sync`, `batt-reset`, `appearance-sync`, `db-tunnel`, `tailnet-sshd` | 0–1 | 2 | Graded on wake, local notification |
| `photoflow` | 0 | 2 | `/tmp` log |

Tally (2026-10-17): about 50 jobs. **Level 4: 3 services** (hermes gateway, weatherorb, research-gateway) **plus 17 graded `jobrun`/cron-adapter jobs** on the mini (13 launchd, 4 Hermes cron) — every owned mini job is at ≥ 2; the one level-1 straggler is `modelpick-web` (accepted above). The MacBook's two level-2 rows are written and **not live**; netgear-watchdog is **down** until its install (above).
**Level 0–1: IuRoot's `com.iu.*` jobs (out of the chain), the MacBook's unmigrated jobs and `modelpick-web`.**

**Open owner actions (MacBook installs, not closed by any wave):**
- netgear-watchdog launchd install: ask `20261016T190047-10176` (the `macbook-installs` herdr agent). Until it lands the watchdog does not run.
- van-sampler install, gated on the Bluetooth TCC spike (`make van-sampler-spike`): ask `20261016T193742-5588`.

## Pattern

| Piece | Spec |
|-|-|
| `jobrun` (**built**, Wave 4) | `jobrun <label> --owner <repo> [--every <s>] [--timeout <s>] [--lock <name>] [--kuma <op-ref>] -- <cmd>`. Lives in dotfiles `scripts/jobrun.ts` (bun/TS, owner decision 6) → `~/.local/bin/jobrun`, tested with `bun test` in `make check`. It writes `~/.local/state/jobs/<label>.json` atomically: `run_id`, `started`, `finished`, `rc`, `duration_ms`, `every`, `owner`, `last_ok`, `consecutive_fail`, `fails_24h`, `tail` (40 lines), plus `owner_sha` (owner repo HEAD), `runs` (last 5) and `fail_times` (24 h, what `fails_24h` counts). A held `--lock` skips the run (rc 0, no state write, so absence grading catches a lock that never frees); a missed deadline is rc 124. Optionally it mirrors one OTLP log per run, best effort. `--kuma` only for the §2 backstop jobs |
| `jobs-grade` (**built**, expected set Wave 5: heartbeat `jobs` WARN component + `make doctor` table; warden consumes it; `~/.wakeup` runs `--notify` on the MacBook) | `scripts/lib/jobs-grade.ts` reads the state dir plus `launchctl print` and outputs `ok`, `failing`, `stale`, `flapping` or `unloaded` per job, as JSON. **The only grading logic.** The expected set is derived from the installed plists (`~/Library/LaunchAgents/*.plist`) whose ProgramArguments invoke `jobrun`: a declared label with no state file grades `unloaded` (not loaded) or `stale` (never recorded, once its first window since the plist mtime has passed), so a job that never ran is never invisible. Hermes cron jobs (`~/.hermes/cron/jobs.json`, env `JOBRUN_HERMES_CRON`) are translated into the same records by an adapter (`hermes-cron.<slug>`, owner `hermes-agent`, loaded = `ai.hermes.gateway` loaded; cadence from the cron expression, failure always graded; an unreadable registry or entry is a `failing` row). Teardown targets `rm` the label's state file. It is called by the heartbeat (WARN lines), warden's `job` source (items), `make doctor` (table) and the MacBook's `~/.wakeup` (notify) |
| Labels and plists | `com.jkrumm.<repo>-<job>` for new jobs; no renames. The plist template lives in the owner repo, installed by its `make <x>-setup` |
| Logs | `~/Library/Logs/<label-suffix>.{log,err}`. `log-rotate.sh` derives its list from our plists' `Standard{Out,Error}Path`, so it is declared but never hand-kept |
| Map | `architecture-check.sh` also asserts map ⊆ live. Five stale weatherorb rows pass today |
| Step rc | A job with steps exits non-zero when any step fails. `jobrun` can't see inside a script that swallows errors; that bug belongs to the owner repo (hermes-backup, modelpick-refresh) |

## Canary

`com.jkrumm.jobrun-canary` (300 s, `make jobrun-canary-setup`, converged by `make setup` on the dev host) runs
`scripts/jobrun-canary.ts`, which exits 1 unless `config/jobrun-canary.json` has `"healthy": true`. The committed
value is always `true`. It is the end-to-end probe for Wave 7.

On failure it prints `canary unhealthy: config/jobrun-canary.json has healthy:false; the fix is to set healthy:true and
commit`, which lands in the run record's tail and so in warden's job brief: a tail that names its own fix is a normal
implement, not a question for the owner (the brief says so). To exercise the chain again, commit `"healthy": false` to
master (the commit is the owner's, the fix is warden's), and expect: `failing` after 3 runs, an item within one loop
pass, a PR within ~10 min, merge + deploy, `fixed` once a run after the deploy succeeds. Measured 2026-10-16 (re-drive
to `fixed`): investigation 6.6 min after the dispatch pass, PR +8 min, merged +5 min, deployed +7 min, `fixed` +11 min.

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
| `warden-sweep` 403 on check-runs: not a defect — Checks is GitHub-App-only for fine-grained tokens, the Actions-runs fallback handles it (never ask for a grant) | none |
| `hermes_cron` failures are never triaged (fixed in Wave 11: graded by the `jobs-grade` cron adapter, `job` items) | warden |
| `audio-gateway` last exit 127 (`secrets-run: from_cache: command not found`) | dotfiles (`secrets-run`), unverified |
| `architecture.md` §Monitoring is missing `Agent Gateway`, `Warden Loop`, `Warden Backup`, `Hermes Serve`, `WeatherOrb Degraded`, `Home Line - Watchdog`, and lists five weatherorb timers that are now DBOS schedules | dotfiles |

## Migration order

This was the wave chain in **`docs/waves/archive/2026-10-background-jobs-PLAN.md`** (orchestrated, 2026-10-16 to 2026-10-17; closed). The owner
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
