# herdr-core + Herdr app — evaluation

The classic `herdr` TUI 0.9.x runs the mini. herdr-core (`hc`) and the Herdr desktop app are its vendor's new split: a headless core that owns the PTYs, and a native GPUI window on top of it. This page records what that split buys, what it costs, and the migration plan. Operational how-to: the `herdr-core` skill.

Status 2026-10-31: **evaluation on the MacBook only** (core 0.1.15, app 0.1.10). The mini stays on classic herdr.

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

1. **Now:** evaluate on the MacBook for local work. Learn the window, layouts and mods, and the `hc` model.
2. **Mini maintenance window** (herdr 0.9.5, brew, macOS 26.x, Colima): runs as planned, on classic herdr.
3. **Move the mini to core only when** (a) core resumes Claude sessions, or we accept a scripted `claude --resume` rebuild per account; (b) quitting the app provably leaves core running; (c) core runs under a LaunchAgent on the mini and survives a reboot. Then port the consumers listed above as a `/wave`.

Sources: the herdr-core and herdr-app READMEs, CHANGELOGs and issues cited above; agw research run `01a19101-d7ba-7122-98db-6230df648a9f` (deep, 41/42 citations grounded).
