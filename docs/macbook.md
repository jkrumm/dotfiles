---
type: Runbook
title: MacBook-only subsystems
tags:
  - engineering
  - macbook
timestamp: 2026-09-07
description: The subsystems that exist only on the MacBook — opbackup + secrets auto-reseed, the battery charge limiter, the database tunnel, the HomeLab SMB keepalive, and the tailnet-facing sshd on :2222 — moved out of CLAUDE.md because they cost every mini agent context for no benefit (agents load CLAUDE.md on the mini, where none of this runs).
---

# MacBook-only subsystems

These run only on the MacBook (`iumac`), never on the mini — `make
setup`'s per-target guards no-op on the wrong machine. They matter little to an
agent working on the mini, which is why they live here rather than in
`AGENTS.md`.

## opbackup + secrets auto-reseed

`opbackup` (`scripts/backup-1password.py`) exports every vault, age-encrypts it in
memory, rsyncs the ciphertext to homelab. The same hourly agent also reseeds the
mini's secrets cache.

| Command | Does |
|-|-|
| `make opbackup-setup` | Stamp from the newest remote backup, install + load the agent |
| `make opbackup-check` | Run the guard once; prints what stopped it. `FORCE=1` backs up now |
| `make opbackup-seed-test` | Hermetic reseed-guard regression suite |
| `make opbackup-teardown` | Unload + remove (stamps kept) |

**Never unattended, and must never be made to** — the first `op` call raises a
biometric approval, and every way around that parks a credential able to export
every vault. The goal is a prompt at a sane moment.

- **A new ref is a stale cache even at a fresh mtime.** The guard fetches
  dotfiles-private and reseeds when the `headless*.refs` **blob hashes** differ
  from the last seal — the mini pushes a ref, it is live within the hour, no
  `ask-human`. Age alone meant a 5-day wait, and sealing an unpulled checkout
  delivered a cache missing the ref that triggered it. A checkout that
  can't fast-forward **refuses to seal**: sealing resets the mtime and buys one
  warning, then silence.
- **Hourly via `StartCalendarInterval`**, never `RunAtLoad`/`StartInterval` — only
  those coalesce a sleep-missed fire into one wake-up run.
- **A skip line in `~/Library/Logs/opbackup.log` is a claim, not a diagnosis** —
  every guard exits **0**; three Secrets gotchas (see `dotfiles/AGENTS.md`
  §Secrets) each present as one.

Full rationale: `docs/opbackup.md`.

## Battery charge limiter

[`batt`](https://github.com/charlie0129/batt) holds the charge at a cap (default
**80%**) via a root LaunchDaemon. The binary ships in the Brewfile; the daemon and
cap are opt-in, and every target self-gates on an internal battery (no-op on the
mini).

| Command | Purpose |
|-|-|
| `make batt-setup` | One-time: daemon + cap + daily-reset agent (`LIMIT=N`) |
| `make batt-limit LIMIT=100` | Change the cap now |
| `make batt-limit LIMIT=100 DAYS=7` | Same, plus pause the daily 80% reset for 7 days |
| `make batt-status` | Charging state + limits, and the resume date if paused |

A 09:00 LaunchAgent resets the cap daily — that is what makes a 100% boost
*temporary*; `~/.config/batt/pause-until` (epoch stamp, from Tinycast's "Pause days"
field or `DAYS=N`) suspends it for travel, and a cap set with no `DAYS` clears the
file, so that doubles as cancel. Changing the resting default means editing both
`battery/batt-reset.sh` and `LIMIT ?= 80`. Launcher control is the **Battery**
command of the `tinycast-extensions` repo (status via `batt status --json`, limit
changes via `launcher/battery-limit.sh`, so the pause logic lives in one place).

## Light/dark — `com.jkrumm.appearance-sync`

The Herdr app follows the system appearance itself (theme `one-zinc-{light,dark}`, `docs/theme.md`). What it
does not do is tell the programs inside its terminals: an unattached core terminal answers OSC 10/11 with fixed dark
colours and a running program gets no `?997` push on a switch (`docs/herdr-core.md` fact 6). The agent `WatchPaths` the
global preferences plist, so it also fires on unrelated preference writes (no-ops) and lags a flip by ~7-10 s
(cfprefsd flush + launchd throttle). Installed by `make setup`, skipped on the mini.

**Claude and OpenCode terminals follow too, here and on the mini.** Claude Code on `theme: auto` flips on a DEC 2031
report plus the OSC 11 answer it re-queries; OpenCode's opentui renderer needs the report **and both** OSC 11
(background) and OSC 10 (foreground): the report alone only makes it re-query, and a missing colour leaves it dark. So
on a change the agent runs `scripts/claude-appearance.sh light|dark` for this machine, then on the mini over
`ssh mini … claude-appearance.sh light|dark` (BatchMode; a failed push retries on the next preferences write). The script
sends the bytes as raw input over `terminal.attach` (`scripts/hc-raw-input.ts`, because `hc send` always adds Enter) to
every live terminal running `claude` or `opencode`, and records the mode in `~/.local/state/claude-appearance`. The `oc`
wrapper replays it into a new OpenCode terminal at 0.4 s (early enough to beat opencode's first paint) and Claude's
SessionStart hook ~3 s after start. Live flip, no redraw, nothing typed into the prompt; editing `~/.claude.json` does
nothing to a running session.

## Database access — `make db-tunnel-setup`

A `KeepAlive` LaunchAgent holding one `ssh -N` with every `-L` in
`dbtunnel/tunnels.conf`; **local ports are the real port + 30000** (33306,
36379). Four launchd traps to hold onto, all detailed in `docs/remote-dev.md`
§Database access: launchd's `SSH_AUTH_SOCK` has zero identities, `IdentityAgent`
needs literal quotes, `ControlMaster=no`+`ControlPath=none`, and ssh must stay in
the foreground.

## HomeLab Samba — `make smb-keepalive-setup` (both Macs)

macOS never reconnects an SMB mount after sleep or a network change; the stale
mount then blocks the first Finder/`stat` that touches it.
`com.jkrumm.smb-keepalive` runs `smb/smb-keepalive.sh` under `jobrun` (graded by
`jobs-grade`) every 60 s and on every
network change (`WatchPaths` on `/Library/Preferences/SystemConfiguration`): per
share in `dotfiles-private/smb-shares.conf` (it names the server, so not here),
`:445` unreachable → log "skipped", exit 0; mounted and the bounded probe
hangs or fails (twice, for a fast failure) → `diskutil unmount force` + remount; absent and `automount yes` →
mount. Every call is bounded and a hung one is abandoned, never waited on. A row's
optional fifth field (`macbook`|`mini`) scopes it to one host. `make smb-keepalive-setup`
also links `smb/nsmb.conf` → `~/Library/Preferences/nsmb.conf` (`soft=yes`, SMB3-only,
no NetBIOS, no multichannel — each key checked against nsmb.conf(5)); `make setup`
runs it on both Macs. `make smb-keepalive-status` shows the launchd state and the log tail,
`make smb-keepalive-test` the hermetic suite (fake mount table; hanging-`stat`, silent-server, dropped-session and EPERM fixtures).

**The probe differs per host, because macOS lets a launchd job only stat an SMB mount.** Reading one
(`ls`, `cat`) needs the Network Volumes grant (`kTCCServiceSystemPolicyNetworkVolumes`) for the job's
program, which under `jobrun` is `bun` at a versioned Cellar path: the grant drops with every bun
upgrade, and without it the read answers `Operation not permitted` or hangs on a prompt nobody sees
(the first mini deploy force-unmounted a healthy share every minute that way, 2026-11-14). So:

| Host | Probe | Why |
|-|-|-|
| mini | `stat <mount>` + `stat <mount>/<a name that cannot exist>`, no read | the lookup has to reach the server and needs no grant: a healthy share answers `No such file or directory`. Measured through a local forwarder in front of the share: a **silent** server (packets dropped) hangs the lookup; a **dropped session** (connection reset) answers `Operation timed out`. `stat` of the root alone is answered from cache; `df` is too, and `smbutil statshares` hangs under `jobrun` (it works from a plain `/bin/sh` launchd job, which is how the first fix attempt missed it) |
| MacBook | `stat` + `ls -a` | runs in the GUI session, where the read works |

An `Operation not permitted` from any probe is "cannot probe" (logged, mount left alone), never "stale".

**Volatile rows.** A row's sixth field, `volatile` (after an explicit scope: `… yes macbook volatile`), marks a share whose
volume can be absent on the server, like the mini's external SSD (`docs/external-ssd.md` §Share). A mount that fails there logs
`<share>: unavailable (volatile share, …)` and does not count toward the job's exit code, so an unplugged or locked drive does not
turn the job red every minute and file a background-job Issue; the next run mounts it when the volume is back. A stale mount of
such a share is still force-unmounted first. A row's user `-` leaves the user out of the mount URL: the mini's
shares are mounted by Finder as the Apple ID's Kerberos identity (the mount table shows a `com.apple.idms…` user), so a URL naming
the mini user matches no credential and `osascript mount volume` waits on a login prompt until the 45 s bound (measured
2026-11-15: a force-unmounted EXT never came back). Mini-served shares (`EXT`, the home folder) are scoped `macbook`: the mini reads its
own disk.

| Host | Mount | Password | Mount point |
|-|-|-|-|
| MacBook | `osascript mount volume` | HomeLab shares: the login Keychain entry Finder saved (mount each once in Finder with *Remember* first). The mini's shares: none, a row user of `-` signs in with the Apple ID's Kerberos ticket | `/Volumes/<share>` |
| mini (cache backend) | `mount_smbfs` through `expect`, in a transient launchd job (`smb/smb-mount.sh`) | `op://homelab/samba/PASSWORD` from the secrets cache (`secrets-run read`, never `op`); a missing ref → `make secrets-reseal-request` | `~/HomeLab/<share>`, created for the attempt and removed again when the mount fails |

The mini's password never enters the keepalive process: `smb/smb-mount.sh` runs as a transient `launchctl submit`
job of its own, reads the ref from the secrets cache and hands it to `mount_smbfs` through a pty (`smb/smb-mount.exp`:
`mount_smbfs` asks on its terminal, `expect` answers from a pipe). So it is in no argv (`ps`/`pgrep -fl` show only the
user, server, share and mount point), no file, not the plist, the log or the environment. **The separate job is the
fix for a hang, not a style choice:** under `jobrun` the responsible process is bun, and `mount_smbfs` from there hangs
before it asks for anything (an argv mount hung > 20 s under `jobrun`, 1 s from a submitted job and from a terminal;
the first mini deploy saw the same as a 45 s mount timeout), most likely the same Network Volumes cause as the probe above (not proven: the prompt itself is not observable headless).
The keepalive waits for the job's status file, bounded, and removes the job (`submit` jobs restart after they exit).
(Keychain was the other candidate for keeping the password out of argv: `security add-internet-password -w` takes the
secret in argv or on a pty prompt itself, and a login-keychain item would sit at rest, which the age-encrypted cache
avoids.) The mount point is removed again
whenever the share is not mounted (an empty directory would swallow a copy while the
HomeLab is down). That account can
delete on the HomeLab shares, unlike the `hl` S3 key — the ref's comment in
`headless.refs` carries the blast radius. A HomeLab that is down at boot delays and fails
nothing: the run logs "skipped" and exits 0. Teardown (the rollback): `make
smb-keepalive-teardown` unloads the agent, removes the plist, the jobrun state and the
`nsmb.conf` link; mounts stay until unmounted (`diskutil unmount force ~/HomeLab/<share>`).

## The reverse reach — mini → iumac on :2222

`ssh iumac` from the mini lands on a userland sshd on the MacBook's `:2222`
(MDM owns the system `:22`), a forced-command key that runs fixed verbs only, no agent forwarding.
Full setup, the verb list, the identity model (`ssh iumac` carries none; a dotfiles pull is the fixed verb `dotfiles-sync`; every other git pull goes through `ask-human --cmd`) and the ACL grant: `docs/remote-dev.md` §mini → iumac.

---

Owning doc for the rest of the remote-dev model: `docs/remote-dev.md`. Map:
`docs/architecture.md`.
