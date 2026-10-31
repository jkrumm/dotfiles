---
description: How background jobs on both Macs are recorded and graded - the four-level maturity ladder, the `jobrun` run record and `jobs-grade` pattern, the canary, and the MacBook jobs. Signal flow and alert paths are in ops-signals.md. The per-job inventory, defects and migration order of the retired remediation loop are archived in docs/archive/background-jobs-2026-10-warden-era.md.
---

# Background jobs — maturity ladder, `jobrun`, grading

> - **launchd stays the scheduler on both Macs.** Built-in no-overlap, catch-up on wake for calendar
>   jobs, KeepAlive restarts. A shared daemon would add a single point of failure and fix nothing.
> - **`jobrun` writes the run record; `jobs-grade` grades it.** A failure past the job's own
>   self-heal reaches a human as a Slack message (`ops-signals.md`). Nothing auto-heals: the
>   autonomous remediation loop was switched off 2026-10-27.
> - **One exception to "no daemon":** the MacBook's van-sampler needs a signed Swift executable as
>   its launchd program, for the Bluetooth TCC grant (the archived ops-signals design §7).

The per-job inventory for the mini (dotfiles and other SourceRoot repos), the IuRoot jobs, the defects
list and the migration order were written against the retired remediation loop (switched off
2026-10-27) and are archived in `docs/archive/background-jobs-2026-10-warden-era.md` (snapshot of
2026-10-17; levels there assume a remediator).

## Maturity ladder

| Level | Name | Means | Detector |
|-|-|-|-|
| **0** | unobserved | Runs; a failure exists only in a log nobody reads, or in `/tmp` | — |
| **1** | recorded | Each run leaves a structured record: `jobrun` state file, or the job's own state/`/health` | the job |
| **2** | dead-man covered | Something *independent* grades failure **and** absence with period + grace | `jobs-grade`, Kuma push, weatherorb watchdog `overdue_after` |
| **3** | self-healing | Retries with backoff and a deadline, a lock where needed, and escalates its own ladder before giving up | the job (netgear-watchdog, linewatch watchdog, agw runs resumed from the journal, DBOS) |

Levels are cumulative: a job at 3 must also be at 2. Self-healing that nobody can see failing is
still a 1. The target is the *right* level, not the highest. The detectors stop at 2 or 3 on
purpose: the heartbeat and Kuma pushers must stay dumb. (The archived inventory also uses a level 4,
"remediated", which existed only under the retired loop.)

### MacBook

| Job | Today | Target | Note |
|-|-|-|-|
| netgear-watchdog (`com.jkrumm.netgear-watchdog`, launchd 60 s, `jobrun`) | **DOWN on the MacBook, level 0** (Tinycast no longer hosts it and the launchd install is still pending: ask `20261016T190047-10176`, the `macbook-installs` herdr agent; the level-2 version is written and pushed on `wave/netgear-launchd`) | 3 | The self-heal ladder is unchanged and now runs outside Tinycast (no kill, no pause, ticks with a view open). The view reads `~/.local/state/netgear-watchdog/state.json`. Live proof pending the MacBook install |
| van-sampler (`com.jkrumm.van-sampler`, launchd 15 min, `jobrun`, signed `van-ble --supervise`) | **not live** (still the Tinycast command, level 1; the level-2 version is on `wave/van-sampler`, gated on the Bluetooth TCC spike, a pending owner ask on the MacBook) | 3 | Leaves Tinycast (which ran it only with no view open). The Tinycast `van-sampler` command and its LocalStorage state are deleted on the branch; state is files in `~/.local/state/van-sampler/` that the Van Power view shares. Spike, evidence and the `.app` fallback: `tinycast-extensions/docs/van-sampler-tcc.md`. Becomes level 2 only when the spike passes and the install is verified |
| herdr-core-update (`com.jkrumm.herdr-core-update`, calendar 04:15, `jobrun`, **both machines**) | 2 | 2 | Daily core update through the `jkrumm/tap` formula (newest release ≥ 24 h old). A failed step leaves the old core running and grades the job red; its tail names the step. Runs on the mini too, so it is graded there as well; the MacBook's run starts the mini's job when the versions differ. `docs/herdr-core.md` §Updates |
| `opbackup` | 2 | 2 | Kuma weekly (data leaves the box) |
| smb-keepalive (`com.jkrumm.smb-keepalive`, launchd 60 s + network change, `jobrun`) | 2 | 2 | Born on `jobrun` (2026-10-19): remounts a stale HomeLab Samba share; exits non-zero only on a failed (re)mount, unreachable is normal. Graded on wake |
| `brain-sync`, `batt-reset`, `appearance-sync`, `db-tunnel`, `tailnet-sshd` | 0–1 | 2 | Graded on wake, local notification |

Job state dir, grading and the heartbeat `jobs` component: see Pattern below.

**Open owner actions (MacBook installs, not closed by any wave):**
- netgear-watchdog launchd install: ask `20261016T190047-10176` (the `macbook-installs` herdr agent). Until it lands the watchdog does not run.
- van-sampler install, gated on the Bluetooth TCC spike (`make van-sampler-spike`): ask `20261016T193742-5588`.

## Pattern

| Piece | Spec |
|-|-|
| `jobrun` (**built**, Wave 4) | `jobrun <label> --owner <repo> [--every <s>] [--timeout <s>] [--lock <name>] [--kuma <op-ref>] -- <cmd>`. Lives in dotfiles `scripts/jobrun.ts` (bun/TS, owner decision 6) → `~/.local/bin/jobrun`, tested with `bun test` in `make check`. It writes `~/.local/state/jobs/<label>.json` atomically: `run_id`, `started`, `finished`, `rc`, `duration_ms`, `every`, `owner`, `last_ok`, `consecutive_fail`, `fails_24h`, `tail` (40 lines), plus `owner_sha` (owner repo HEAD), `runs` (last 5) and `fail_times` (24 h, what `fails_24h` counts). A held `--lock` skips the run (rc 0, no state write, so absence grading catches a lock that never frees); a missed deadline is rc 124. Optionally it mirrors one OTLP log per run, best effort. `--kuma` only for the `ops-signals.md` §2 backstop jobs |
| `jobs-grade` (**built**: heartbeat `jobs` WARN component + `make doctor` table; `~/.wakeup` runs `--notify` on the MacBook) | `scripts/lib/jobs-grade.ts` reads the state dir plus `launchctl print` and outputs `ok`, `failing`, `stale`, `flapping` or `unloaded` per job, as JSON. **The only grading logic.** The expected set is derived from the installed plists (`~/Library/LaunchAgents/*.plist`) whose ProgramArguments invoke `jobrun`: a declared label with no state file grades `unloaded` (not loaded) or `stale` (never recorded, once its first window since the plist mtime has passed), so a job that never ran is never invisible. Hermes cron jobs (`~/.hermes/cron/jobs.json`, env `JOBRUN_HERMES_CRON`) are translated into the same records by an adapter (`hermes-cron.<slug>`, owner `hermes-agent`, loaded = `ai.hermes.gateway` loaded; cadence from the cron expression, failure always graded; an unreadable registry or entry is a `failing` row). Teardown targets `rm` the label's state file. It is called by the heartbeat (WARN lines; `--slack` posts to Slack #alerts when the set of not-ok jobs changes), `make doctor` (table) and the MacBook's `~/.wakeup` (notify) |
| Labels and plists | `com.jkrumm.<repo>-<job>` for new jobs; no renames. The plist template lives in the owner repo, installed by its `make <x>-setup` |
| Logs | `~/Library/Logs/<label-suffix>.{log,err}`. `log-rotate.sh` derives its list from our plists' `Standard{Out,Error}Path`, so it is declared but never hand-kept |
| Map | `architecture-check.sh` also asserts map ⊆ live. Five stale weatherorb rows pass today |
| Step rc | A job with steps exits non-zero when any step fails. `jobrun` can't see inside a script that swallows errors; that bug belongs to the owner repo (hermes-backup, modelpick-refresh) |

## Canary

`com.jkrumm.jobrun-canary` (300 s, `make jobrun-canary-setup`, converged by `make setup` on the dev host) runs
`scripts/jobrun-canary.ts`, which exits 1 unless `config/jobrun-canary.json` has `"healthy": true`. The committed
value is always `true`. It is the end-to-end probe for the job failure chain.

On failure it prints `canary unhealthy: config/jobrun-canary.json has healthy:false; the fix is to set healthy:true and
commit`, which lands in the run record's tail. To exercise the chain, set `"healthy": false` (locally uncommitted is
enough): the job grades `failing` after 3 runs, and the next heartbeat tick posts the change to Slack #alerts. Set it
back to `true` and the next green run produces the recovery message. Never leave it committed `false`.
