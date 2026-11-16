# Host waste on the mini

Issue 1376. A read-only audit on 2026-11-15 found about 2 cores of `system` CPU over 24 h (37 to 40 % kernel time) outside the factory's leads. Each
consumer below was measured the same way (CPU seconds from `ps` over a window, process counts from `ps`), traced to a cause, and either fixed or
left with a reason. `make host-waste-check` (also a section of `make doctor`) shows four of them as yellow WARN lines; none can fail the doctor.

| Consumer | Before | After | Cause | Verdict |
|-|-|-|-|-|
| Orphaned `sleep` | 41 `sleep 180` and 20 `sleep 30` with parent 1 after one `make secrets-seed-test` | 0 after the same suite | `run_bounded`'s watchdog (`scripts/secrets-seed.sh`) killed its subshell, not the `sleep` inside it | fixed |
| `mediaanalysisd` | 52 CPU-min/h (85 % of a core), 331 CPU-min since boot | 0 for minutes after each kill, then back (it respawns on an XPC event); the disable applies at the next restart. Issue 1744: 0.61 core before, 0.00 with SIGSTOP held by `com.jkrumm.photos-analysis-stop` | Photos analysis of the 20,981-asset library, never throttled on a host that is never idle | disabled and stopped, ends at the next restart |
| `tailscaled` | 20 to 33 CPU-min/h (33 to 55 % of a core over 30 s), 224 CPU-min in 7.6 h | unchanged | WireGuard work for 5 to 16 MiB/s of bulk copies routed through the mini | stays, WARN line |
| `sshd-session [postauth]` | 7 processes, up to 6.6 h old | unchanged | seven live logins from the MacBook, each with an ESTABLISHED socket; not stale | stays, WARN line |
| CoreSimulator services | 6 processes, 76 MB, 0 CPU | unchanged | launchd starts them on demand for an `xcodebuild`; no simulator is booted | stays |
| `bun run start` in modelpick | 1 process, 0 CPU | unchanged | `com.jkrumm.modelpick-web`, a registered service | stays |
| XprotectService, syspolicyd, kernel_task | 5 and 2 CPU-min/h for the first two | unchanged | exec churn, see below | stays |

## Orphaned sleeps

`run_bounded` runs `op` under a deadline: `{ sleep "$secs"; kill -TERM …; } &`, then `kill "$wd_pid"` when `op` returns first. That kills the brace
group's shell and leaves its `sleep` running, reparented to launchd, for the full deadline. Every `op read` (30 s) and `op inject` (180 s) the seed
makes left one. One `make secrets-seed-test` makes 61 (41 `sleep 180` and 20 `sleep 30`), exactly the audit's 41: a lead's `make check` had just run it. The repro is a line: `{ sleep 181; } & kill $!`, then `ps -axo ppid=,args= | grep 'sleep 181'` shows parent 1.

The watchdog now starts the sleep as a child it waits on and traps TERM to kill it. The suite's last case (`99.`) runs every seed with deadlines
no real run uses (7311 and 7312 s) and fails on a surviving sleep with either; it fails on the old code (verified) and passes on the new.
`make host-waste-check` WARNs above 10 sleeps whose parent is launchd; a sleep in a loop under a shell is not counted.

## mediaanalysisd

Photos runs scene, face and text analysis over the library in the background and throttles it only while the Mac is busy. The mini never is idle in
that sense, and since iCloud Photos was set to Download Originals the analysis had 78 GiB to work through. Nothing on the host uses the result (no one
searches Photos on the mini); the nightly export reads `Photos Library.photoslibrary` through osxphotos and needs no analysis.

`launchctl disable gui/$(id -u)/com.apple.mediaanalysisd` is launchd's own switch for a user-domain agent. It needs no sudo, survives reboots and
updates of the plist, and `launchctl enable` undoes it. **It takes effect when the user session next loads, not at once**: the agent was loaded
before the disable, and launchd keeps answering its XPC event until then. System Integrity Protection refuses `bootout`, `remove` and `unload` of
an Apple agent (all `rc=150` or `Input/output error`, measured), so there is no way to unload it live without a restart. Until then the daemon is
killed by pid (SIGTERM is ignored): after the first kill on 2026-11-15 it came back about two minutes later (pid 67286, 0.4 core over the next
83 min), after the second it came back after about 12 minutes (pid 7308, 0.7 core). Killing it only trades a few minutes. The next planned restart (`make planned-restart`, `docs/recovery-drill.md` §4) ends it for good.

**Issue 1744: until that restart the daemon is stopped, not killed.** On 2026-11-16 it still ran (pid 24996, 3 h old, 0.61 core over a 10-minute window
at load 16; 46 to 79 % of a core in the owner's sample at load 35), because nobody had restarted the host since the disable. `SIGSTOP` cannot be ignored,
and a stopped process is still alive, so launchd has nothing to respawn and its XPC callers (`photoanalysisd`, Photos) just wait. The job
`com.jkrumm.photos-analysis-stop` (every 5 minutes, `host-waste-check.sh stop-mediaanalysisd`) stops any `mediaanalysisd` that is not already in state
`T`, so a respawn costs at most five minutes. `make photos-analysis-off` (run by `make setup` on the mini, idempotent) re-applies the disable and
installs the job; the doctor line reads a stopped daemon as `disabled and stopped` and WARNs when the agent is enabled again or a daemon runs
unstopped. Undo: `launchctl enable gui/$(id -u)/com.apple.mediaanalysisd`, remove the job's plist, `kill -CONT <pid>`. No night window: the analysis has no consumer, so bounding it would only spend the CPU later.

Not disabled: `photoanalysisd` (0 % CPU, the coordinator) and `photolibraryd` (the sync Download Originals needs).

## tailscaled

CPU follows throughput: 10 to 16 MiB/s through the mini's tailnet interface costs 0.3 to 0.5 core in userspace WireGuard, and tailscaled's lifetime
counters read 141 GB in and 160 GB out in 7.6 h (about 11 MiB/s on average). Two flows were running at the audit: a `ssh vps tar | ssh homelab tar`
corpus copy for weatherorb (the mini only relays it) and an `rclone check homelab:hdd/fuji … --download` of the EXT mirror. No setting makes this
cheaper: Funnel traffic is not it (`tailscale metrics`: 0.2 MB over DERP in total), direct paths are in use for every peer and the ACL drops are 28
packets. A copy between the VPS and the HomeLab belongs on one of those two hosts; filed for weatherorb as a signal.

The doctor line samples CPU and bytes over 10 s and WARNs above 40 % of one core, naming the MiB/s so the transfer is the first suspect.

## sshd sessions

The seven `[postauth]` processes are seven live logins (each a `[postauth]` and a session process), six from the MacBook's LAN address and one over
the tailnet, one of them the Herdr app's `herdr-core connect`; `netstat` shows an ESTABLISHED socket for every one, so none is stale. `sshd_config` leaves `ClientAliveInterval` unset, so a peer that vanishes (lid close, roam) keeps
its login until the TCP timeout; setting `ClientAliveInterval 60` and `ClientAliveCountMax 3` in `/etc/ssh/sshd_config.d/` would end those, but
needs the owner's sudo and no dead session exists to justify it. The doctor line WARNs above 20 `[postauth]` processes, which is where that
becomes a pile.

## Exec churn: XprotectService, syspolicyd, kernel_task

Process creations measured by the pid counter over 30 s: about 395 per second while other leads' `bun test` runs and the factory server were busy.
The spawners in a 20 s sample were `bun` (the factory server and a scenario test run), their `git` and `bash` children, and
the home repo's `tools/audio/speaker-watch.sh` at about 1.5 per second (it polls every 2 s), which is 0.4 % of that rate. XprotectService and
syspolicyd checked 7 CPU-min/h together over the same window; kernel_task's share follows the tailnet traffic and the forks. The lead's and the
factory's processes are out of scope, so this stays; a fork-rate probe would read the leads' load, not a fault, and gets no doctor line.

## Issue 1744: the CPU side, measured

The owner's sample (2026-11-16 21:34 UTC, load 31 to 39 on 12 cores): kernel_task 96 %, mediaanalysisd 46 to 79 %, corespotlightd 43 %, XprotectService
82 %, tailscaled 44 %, rclone 16 %, together three to four cores. `make host-cpu SECS=600` reproduces the table: CPU seconds per process name from
`ps` (kernel_task from `top`, which `ps` does not list) over a window, as cores. Two 600 s windows at 22:40 and 22:50 CET, the second after the change below:

| Process | Before (load 16.6) | After (load 14.5) | What was changed |
|-|-|-|-|
| mediaanalysisd | 0.61 | 0.00 | stopped with `SIGSTOP` by `com.jkrumm.photos-analysis-stop`; the `launchctl disable` of 2026-11-15 never took effect because the host was not restarted |
| kernel_task | 0.53 | 0.45 | nothing: it follows the network and fork rate of the rows below, not a setting |
| tailscaled | 0.40 | 0.50 | nothing: 5 MiB/s of the ext-mirror catch-up copy (`rclone sync`, started 20:13, not the 05:00 schedule); the copy is now capped by day, see rclone |
| XprotectService | 0.32 | 0.15 | nothing: build exec churn; fell with the load, not with a change |
| syspolicyd | 0.16 | 0.09 | nothing, same cause |
| rclone | 0.13 | 0.15 | `--bwlimit "07:00,4M 23:00,off"` for the next run (4 MiB/s is about 0.35 core of tailscaled at the measured 0.09 core per MiB/s); the running process keeps the limit it started with |
| fseventsd | 0.11 | 0.19 | nothing, `docs/spotlight.md` §fseventsd |
| mds, corespotlightd | 0.03, 0.03 | 0.03, 0.02 | nothing: indexing is off on every volume (`mdutil -a -s`: `/`, Data, Preboot, `/Volumes/EXT` disabled, both HomeLab SMB mounts "Indexing and searching disabled"); `docs/spotlight.md` |
| **Total** | **2.31** | **1.58** | |

Two windows at different loads are indicative, not a controlled test: the only change that can be told apart from load is mediaanalysisd (0.61 to 0), a
process the load does not drive. The 43 % `corespotlightd` of the owner's sample is the query storm `docs/spotlight.md` §`corespotlightd` records; it
did not recur at load 15 and cannot be fenced (`launchctl disable` does not hold, `bootout` is refused by SIP).

**Spotlight after a restart.** The disable is `mdutil`'s per-volume store, so it survives a restart: the host has been up since 2026-11-15 01:xx CET and
the volumes still read disabled; the heartbeat component `spotlight` (`scripts/spotlight-check.sh check`) fails if a volume turns on. Restarting `mds`
to prove it is a kill to prove a change, which the standing constraint forbids; the next `make planned-restart` is the proof, and `make spotlight-check`
afterwards is the read.

**XProtect and syspolicyd.** Their load is exec churn of fresh, ad-hoc-signed binaries (every Rust or Swift link produces a new cdhash that Gatekeeper
and XProtect assess once). What Apple supports is the **Developer Tools** exemption (`kTCCServiceDeveloperTool`, System Settings, Privacy & Security,
Developer Tools): a granted `.app` and its children are not scanned (the nextest and Next.js docs give the steps, `nexte.st/docs/installation/macos`).
Not found in any source: whether it covers a tree started under a launchd-born `.app` (here `Herdr Core.app`), and a way to grant it without a click,
so it is one Errand with the owner, and the measure after it decides: `make host-cpu` XprotectService + syspolicyd over a build hour. Gatekeeper
stays on, and `xattr`, `spctl --master-disable` and path hacks are not used. The pane already lists `com.apple.Terminal` (`TCC.db`, auth 0), so
`sudo spctl developer-mode enable-terminal` is likely not needed; the click adds `Herdr Core.app`. Binaries built before the grant keep their scan state
(`cargo clean` for a worktree's `target`).

**tailscaled.** The traffic is direct (`tailscale status`: homelab direct over IPv6; DERP carried 5 MB in and 31 MB out of 330 GB and 287 GB since
boot), so this is not relaying. The bytes are bulk copies the mini carries: the ext-mirror `rclone sync` (the `homelab:` remote is the HomeLab's
tailnet S3 endpoint, so every byte is WireGuard in userspace), and weatherorb's capture relay (`ops/v2/capture/relay.sh`, a deliberate transport
of Issue 1400 that runs VPS to mini to HomeLab). Neither the SMB mounts nor Funnel are the flow. There is no CPU knob on `tailscaled`; the lever is the
bytes, hence the rclone limit.

## Rule (moved from the root AGENTS.md)

**Host waste** — `make host-waste-check` (a `make doctor` section, WARN only): orphaned `sleep`s (a watchdog that kills its subshell, not its timer), `tailscaled` CPU (it follows bulk-copy throughput), `mediaanalysisd` (disabled and SIGSTOPped by `make photos-analysis-off`, which `make setup` re-applies and which installs the 5-minute stop job; `make host-cpu` reads the daemons' cores; `launchctl enable gui/$UID/com.apple.mediaanalysisd` undoes it), sshd sessions. Causes, numbers, what stays: `docs/host-waste.md`.
