# herdr-core + Herdr app — evaluation

The classic `herdr` TUI 0.9.x runs the mini. herdr-core (`hc`) and the Herdr desktop app are its vendor's new split: a headless core that owns the PTYs, and a native GPUI window on top of it. This page records what that split buys, what it costs, and the migration plan. Operational how-to: the `herdr-core` skill.

Status 2026-10-31: **running in parallel** (core 0.1.15, app 0.1.10). The MacBook runs the app; the mini runs a core beside classic herdr, and every agent workflow (`rd`, waves, reap, overview) stays on classic herdr until the gaps below close. Classic herdr is phased out one consumer at a time.

## What the split buys

| Gain | Over herdr 0.9 |
|-|-|
| Core outlives every viewer, and `hc update` restarts core while holders keep the programs running | A herdr server restart or upgrade kills every pane process. `--handoff` is best effort |
| Agents run agents: `hc run` inside a terminal makes a child, `hc wait --children`, parents get notes, children die with the parent unless `--outlive-parent` | No parent/child model |
| One window over several machines: `hc machine add` merges remote cores over SSH | `herdr --remote` attaches one client to one server |
| OpenRPC API (`hc schema`), `hc connect` over stdio/SSH, sequenced events with gap recovery | TUI JSON socket |
| UI as files: JSON layouts, JavaScript mods that hot-reload, agent-editable | Plugins only |
| Native window on libghostty's VT engine: images, HiDPI, mouse, clipboard, IME | TUI inside Ghostty |
| Templates (`~/.config/herdr-core/templates/*.md`): named agent roles with command and instructions | none |

## What it costs

- **No Claude conversation resume.** After a crash, reboot or `server stop`, kept terminals come back as fresh shells. The maintainer closed the request as not planned until OSC 7501 grows a resume descriptor (herdr-core #13, proposal #15 open). herdr 0.9's `resume_agents_on_restore` runs `claude --resume <id>` automatically. For an always-on host of 15–20 agents, this is the decisive gap.
- **Nothing migrates.** The app's welcome: "Your herdr workspaces stay where they are; nothing moves over." Only keybinds and settings carry over (via an agent reading `~/.config/herdr/config.toml`). The two can't share agents.
- **Every herdr-0.9 consumer needs a rewrite against the `hc` API:** `rd`, `herdr-reap.py`, `herdr-events.ts`, agent-overview, `herdr-groups.py`, collie, `make herdr-upgrade/-restart`, the heartbeat's herdr component.
- **Layouts don't declare workspaces.** They arrange the window around existing tabs, panes and mods. Rebuilding a session is imperative (`herdr-app do space.new/tab.new/terminal.open`). `pane.split` takes no folder, and there's no resize command.
- **macOS lifecycle and TCC are unsettled.** herdr-app #219: quitting the app on macOS killed core and its holder, losing a Claude session. Core is a bare ad-hoc-signed Mach-O, so TCC can't prompt for it: Accessibility, screen capture, mic and camera fail (#135, #90). Whether launchd or the app parents core varies by version. A durable headless core would need its own LaunchAgent, verified.
- **Beta cadence, outside the supply chain.** Six core and seven app releases in eight days. Distribution is `releases.herdr.dev` with a SHA-256 from the same index (no signed manifest), plus background auto-update with no off switch (#207). Not in the Brewfile.

## Verified here

- **Claude Code status works.** Claude 2.1.314, spawned by `hc run --bg claude` on the MacBook, reports `{"app":"claude-code","state":"idle"}` → `done` after a prompt. That held both with and without `CLAUDE_CODE_CHILD_SESSION`. The daemon-PTY failure in herdr-app #158 didn't reproduce. A `null` status at start was the folder-trust dialog.
- App notarized (`Developer ID Application: Herdr, Inc. (2W9652Q7QR)`). The installers write only `~/.local/bin` and `~/Applications` and register no launchd jobs.

## Decision

1. **Now:** both in parallel. Local work runs in the app on the MacBook, and the mini's core is reachable as machine `mini`. Learn the window, the mods and the `hc` model there.
2. **Mini maintenance window** (herdr 0.9.5, brew, macOS 26.x, Colima): runs as planned, on classic herdr.
3. **Move the mini to core only when** (a) core resumes Claude sessions, or we accept a scripted `claude --resume` rebuild per account; (b) quitting the app provably leaves core running; (c) core runs under a LaunchAgent on the mini and survives a reboot. Then port the consumers listed above as a `/wave`.

Sources: the herdr-core and herdr-app READMEs, CHANGELOGs and issues cited above; agw research run `01a19101-d7ba-7122-98db-6230df648a9f` (deep, 41/42 citations grounded).

## Mini core

`com.jkrumm.herdr-core` (`make herdr-core-setup`, dev host only) runs `hc serve` as a KeepAlive LaunchAgent, **bootstrapped into `gui/<uid>`**. The MacBook links it with `hc machine add mini --name mini` (once; ssh config host `mini`).

- **Always up, on purpose.** Any `hc` client call auto-starts a core when none runs, including the MacBook's link arriving over ssh. A core born in an ssh session spawns Claude without the login keychain (the `ssh mini 'claude …'` trap). Under launchd, a terminal in the core reaches the keychain (verified 2026-10-31).
- **Restart = `launchctl kickstart -k gui/$(id -u)/com.jkrumm.herdr-core`.** Terminals survive: a `sleep` kept its pid across the kickstart (verified). Don't use `hc server restart`, `hc update` or `hc machine update mini` on the mini. They restart the core outside launchd's view, and that combination is untested.
- **Upgrade:** `scp ~/.local/bin/herdr-core mini:.local/bin/`, then the kickstart. Keep MacBook and mini on the same `hc` version (`hc machine ls` shows it).
- State: `~/.local/state/herdr-core/` on the mini. Log: `~/Library/Logs/herdr-core.log`.

## Desktop layout (MacBook)

`make herdr-app-setup` converges the app onto `config/herdr-app/`. It's idempotent, and needs the window open to switch the layout and open spaces. It ends by switching layouts away and back, the only reload that picks up edits inside a symlinked mod folder.

| Piece | Source | Lands as |
|-|-|-|
| `jk` layout: the shipped `main` with `jk-spaces` instead of spaces + agents, `jk-status` as the bar, theme `one-zinc-{light,dark}` following the system | `config/herdr-app/layouts/jk.json` | symlink |
| `jk-spaces`: Herdr's `spaces` mod (Apache-2.0) plus folders. Folders come from **`config/herdr/groups.json`**, the same taxonomy as classic herdr's sidebar. A space joins the group naming its repo (worktrees follow their repo), the rest go to the fallback (`OTHER`). Folders fold (state in the app), a folded folder shows ● when a space in it needs you, avatars take the folder's color, and rows carry the agent-status dot | `config/herdr-app/mods/jk-spaces/` | symlink |
| `jk-status`: CPU % and memory used (active + wired + compressed) for this computer and every connected machine, every 5 s via `exec … { on }`. Claude Max usage per account (`5h/7d %`, red ≥ 90, dim when the sample is > 3 h old, `login` when auth failed), every 60 s from `claude-account usage --json`, which reads its local quota cache only (the MacBook's includes the mini's samples) | `config/herdr-app/mods/jk-status/` | symlink |
| Themes `one-zinc-*` (the terminal look, `docs/theme.md`) and `basalt-ui-*` (Blueprint palette), converted from `config/ghostty/themes/` | `config/herdr-app/themes/` | symlink, pickable in Settings |
| Spaces shutterflow, ShutterflowOps, tinycast-extensions, finances, dotfiles | `SPACES` in `scripts/herdr-app-setup.sh` | `herdr-app do space.new`, skipped when one already works in that folder |

A new repo gets its folder through one line in `groups.json`. Revert to stock with `herdr-app do layout.switch --name main`. The theme picker in Settings overrides the layout's theme.
