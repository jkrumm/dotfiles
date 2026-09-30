---
type: Runbook
title: MacBook-only subsystems
tags:
  - engineering
  - macbook
timestamp: 2026-09-07
description: The four subsystems that exist only on the MacBook — opbackup + secrets auto-reseed, the battery charge limiter, the database tunnel, and the tailnet-facing sshd on :2222 — moved out of CLAUDE.md because they cost every mini agent context for no benefit (agents load CLAUDE.md on the mini, where none of this runs).
---

# MacBook-only subsystems

These four run only on the MacBook (`iumac`), never on the mini — `make
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

## Herdr GPUI light/dark — `com.jkrumm.appearance-sync`

Herdr GPUI (the herdr desktop client, attached to the mini through the saved
`herdr machine` profile) takes one `theme` name and has no system-appearance
support. `scripts/appearance-sync.sh` rewrites the `theme` line of
`~/.config/herdr/config-gpui.local.toml` to `basalt-ui-light`/`-dark`; the app
reloads it on save. The agent `WatchPaths` the global preferences plist, so it
also fires on unrelated preference writes (no-ops) and lags a flip by ~7–10 s
(cfprefsd flush + launchd throttle). Installed by `make setup`, skipped on the
mini.

**Claude and OpenCode panes on the mini follow too.** Claude Code on `theme:
auto` flips on a DEC 2031 report plus the OSC 11 background answer it re-queries
— which only a Ghostty (`desk`) client supplies; Herdr GPUI never sends either.
OpenCode's opentui renderer reads the same 2031 report. So on a change the agent
also runs `ssh mini scripts/claude-appearance.sh light|dark` (BatchMode, riding
the ControlMaster a connected GUI keeps open; a failed push retries on the next
preferences write), which sends both halves to every `claude` and `opencode`
pane and records the mode in `~/.local/state/claude-appearance`. A SessionStart
hook replays that mode into each new Claude session ~3 s after start; the `oc`
wrapper does the same for a new OpenCode pane. Measured: live flip, no redraw,
nothing typed into the prompt. Either half alone, or editing `~/.claude.json`,
does nothing to a running session.

## Database access — `make db-tunnel-setup`

A `KeepAlive` LaunchAgent holding one `ssh -N` with every `-L` in
`dbtunnel/tunnels.conf`; **local ports are the real port + 30000** (33306,
36379). Four launchd traps to hold onto, all detailed in `docs/remote-dev.md`
§Database access: launchd's `SSH_AUTH_SOCK` has zero identities, `IdentityAgent`
needs literal quotes, `ControlMaster=no`+`ControlPath=none`, and ssh must stay in
the foreground.

## The reverse reach — mini → iumac on :2222

`ssh iumac` from the mini lands on a userland sshd on the MacBook's `:2222`
(MDM owns the system `:22`), restricted to `restrict,pty`, no agent forwarding.
Full setup, the SSH-identity trap (`ssh iumac '<cmd>'` carries none by default,
since `.zshrc` is not read by a remote command shell) and the ACL grant: `docs/remote-dev.md` §mini → iumac.

---

Owning doc for the rest of the remote-dev model: `docs/remote-dev.md`. Map:
`docs/architecture.md`.
