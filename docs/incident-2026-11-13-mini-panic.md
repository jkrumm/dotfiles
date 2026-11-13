# Incident 2026-11-13: the mini kernel-panicked

Single record for the Issues and plans that follow from it. Times are CET unless marked Z (UTC). Kuma stores UTC.

## What happened

- **Last healthy push 18:56 (17:56:28Z):** tailnet, sshd, core all fine; swap 10.8 GB of 32 GB, `swapouts ok (0M/300s)`, Data volume 94% used.
- **Earlier precursor 18:22 (17:22:51Z):** `tailscale status` and the core liveness check both timed out at 5 s ("slow, not proven dead"), then recovered.
- **Last hc-events record 18:58 (17:58Z).** No event storm before it.
- **Panic about 19:00:** `watchdog timeout: no checkins from watchdogd in 94 seconds (104645 total checkins)`. Panicked task `gtimeout` pid 80039 is only the thread that tripped the watchdog. Compressor 18% of limit (OK), 12 swapfiles. Boot faults `wdog,reset_in1`, boot failure count 0. The report names no culprit.
- **Reboot 19:01:33** (auto-restart worked). The core was launchd-born again by 19:09, reachable over ssh 19:09:22. Between boot and 19:09 the wired link showed 0 Mbit at the router and the load average was 175, then 404: about 25 `claude` processes, Colima and further Virtualization.framework VMs, corespotlightd, mobileassetd. `hc-resume` issued 25 `claude --resume` within 9 ms (log 18:09:30Z).
- **No alert fired:** the Dev Host monitor (interval 600 s, maxretries 1, ntfy on DOWN) went PENDING at 18:06:30Z and recovered before DOWN. The panic shows only as a WARN inside a healthy heartbeat.
- The core had also restarted at 07:07Z the same day (hc-resume log: "stream ended", then "no launchd-born core" for about a minute, 18 resumes at 07:02Z); cause not established.

## Cause

Unproven. Userspace was starved long enough that `watchdogd` missed 94 s. Candidates, none shown: memory or IO starvation (swap 9-14 GB, 12 swapfiles, Data volume at 94%), a runaway process. Nothing recorded what ran, so this cannot be settled after the fact; that is Issue 1034's job.

## Standing constraint: HerdrCore must stay recoverable and unbroken

The owner has been burned by changes around the core and its auto-update. Every change near it, in any Issue or plan, keeps these:

1. **Recovery target:** after a panic or reboot the core is launchd-born (`scripts/lib/core-up.sh`), every kept terminal comes back as a shell, and `hc-resume` brings each Claude session back under the right account. "Recovered" is measured: terminals with a resumable session versus terminals running `claude` again.
2. **One update path:** `make herdr-core-update`, by hand, in a quiet window. Never `hc server restart|stop`, `hc update` or `hc machine update` outside it; never a wrapper at `~/.local/bin/{hc,herdr-core}`; never a core started from ssh or an agent. The app's auto-update has no off switch (herdr-app #207): recovery must survive an app-triggered core update.
3. **No live proof by breaking it:** no reboot, kill, panic or core restart to verify a change. Proof is a test plus reading the code path; a live check happens only in an owner-chosen quiet window.
4. **Scope:** `hc-resume` changes alter pacing and order only, never which terminals are resumed or which account is chosen. Anything touching the core's plist, launcher or `make herdr-core-*` gets `/review` and a one-line rollback in its Issue.

Detail of how the core runs: `docs/herdr-core.md` §How the core runs now.

## Open work (factory, repo dotfiles)

| Issue | What |
|-|-|
| 1033 | Cap `hc-resume` concurrency so sshd and tailscale answer within about 2 minutes of boot |
| 1034 | Rolling pre-hang snapshot log, panic headline in the heartbeat, one ntfy push on reboot or panic |
| 1035 | Memory budget: explain 10-14 GB swap on 32 GB, set per-class limits as config |
| 1026 | Disk above 90% (swapfile headroom is part of the panic picture) |

## Planned: external SSD on the mini

The owner is attaching a 1 TB external SSD to the mini for bulk data, first candidate the weather data (weatherorb). Not attached yet; do not assume a mount path. Design points for whoever plans it:

- The volume can be absent at boot or after a USB hiccup: jobs that write there must tolerate absence and never recreate the path on the internal disk.
- Mount order: dependents start after the volume is there.
- TCC and Full Disk Access for the programs that read and write it (`docs/tcc.md`).
- Keep off it: swap, the Colima/Docker VM disk, herdr-core state, anything the boot path needs.
- Spotlight and backup status; where it sits in the per-owner disk budget (`docs/disk.md`).
