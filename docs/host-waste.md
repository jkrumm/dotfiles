# Host waste on the mini

Issue 1376. A read-only audit on 2026-11-15 found about 2 cores of `system` CPU over 24 h (37 to 40 % kernel time) outside the factory's leads. Each
consumer below was measured the same way (CPU seconds from `ps` over a window, process counts from `ps`), traced to a cause, and either fixed or
left with a reason. `make host-waste-check` (also a section of `make doctor`) shows four of them as yellow WARN lines; none can fail the doctor.

| Consumer | Before | After | Cause | Verdict |
|-|-|-|-|-|
| Orphaned `sleep` | 41 `sleep 180` and 20 `sleep 30` with parent 1 after one `make secrets-seed-test` | 0 after the same suite | `run_bounded`'s watchdog (`scripts/secrets-seed.sh`) killed its subshell, not the `sleep` inside it | fixed |
| `mediaanalysisd` | 52 CPU-min/h (85 % of a core), 331 CPU-min since boot | 0 for minutes after each kill, then back (it respawns on an XPC event); the disable applies at the next restart | Photos analysis of the 20,981-asset library, never throttled on a host that is never idle | disabled, ends at the next restart |
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
83 min), after the second it came back after about 12 minutes (pid 7308, 0.7 core). Killing it only trades a few minutes. The next planned restart (`make planned-restart`, `docs/recovery-drill.md` §4) ends it for good; the doctor
line WARNs on `disabled but still running` until then.
`make photos-analysis-off` (run by `make setup` on the mini, idempotent) re-applies the disable, and the doctor line also WARNs when the agent is
enabled again. No night window: the analysis has no consumer, so bounding it would only spend the CPU later.

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
