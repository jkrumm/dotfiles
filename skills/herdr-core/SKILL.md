---
name: herdr-core
description: "Operate herdr-core (CLI `hc`) and the Herdr desktop app (`herdr-app`, the GPUI window on top of core) — persistent terminals, `hc run/read/send/wait/attach`, machines, templates, the OpenRPC API, app spaces/tabs/layouts/mods. Use only when the user names herdr-core, hc, the Herdr app/desktop app, Herdr layouts or mods, or the core migration. The classic `herdr` TUI (0.9.x, what the mini runs) is the `herdr` skill, not this one."
---

# herdr-core + Herdr app

Two products, one vendor, **no shared state**:

| | Command | Runs where (2026-10-31) |
|-|-|-|
| Classic TUI 0.9.x | `herdr` | the mini — every agent, `rd`, reap, events, overview, collie. Skill: `herdr` |
| herdr-core + app | `hc`, `herdr-app` | MacBook: app + core. Mini: core only. Both cores are the LaunchAgent `com.jkrumm.herdr-core` (clean env); the mini is machine `mini` |

They run in parallel and can't see each other's agents.

## First step, every time

The binaries ship their own manual, versioned with the release (core and app release several times a week). Read it rather than trusting memory or this file:

```bash
hc --skill          # core: run, read, send, wait, children, templates, machines
herdr-app --skill   # window: spaces, tabs, panes, layouts, mods, keys
hc <cmd> --help     # exact flags
hc schema           # OpenRPC + JSON Schema — the API for anything scripted
```

Inside a core terminal `$HC_TERMINAL_ID` is set. Inside a classic herdr pane `HERDR_ENV=1` is set. The env tells you which world you're in.

## Rules that override the upstream manual

- **Lane policy wins.** `hc --skill` says to delegate through `hc run … claude`. In this setup only `@implementer` and `rd wave` start agents (`docs/agent-platform.md`). Use `hc run` for a non-agent program (tests, a watcher), or for an agent only when the user asks for one in core.
- **The mini's core belongs to launchd.** Restart it only with `launchctl kickstart -k gui/$(id -u)/com.jkrumm.herdr-core`. Never use `hc server restart|stop`, `hc update` or `hc machine update mini` there, and never start a core from an ssh session (no keychain, so Claude runs logged out). Upgrades: `docs/herdr-core.md` §Core as a LaunchAgent. `hc run` passes no env: set the account on the command (`env CLAUDE_CONFIG_DIR=… claude`).
- **The look is tracked.** Layout, mods and themes live in `config/herdr-app/` and folders in `config/herdr-app/groups.json`. Edit there, then `make herdr-app-setup` (it reloads). Never edit the shipped mods in `~/.config/herdr-app/mods/`.
- Always `--bg` and `--name` for anything long. Read output with `hc read <t> --lines N`, never by attaching.
- `hc kill` whatever you started when you're done. Children end with their parent by default, but an `--outlive-parent` or a top-level `hc run` from a shell keeps going.

## Facts verified on this setup

- **Claude Code status works natively.** Claude 2.1.295+ speaks OSC 7501. Core answers the capability query and stores `{"app":"claude-code","state":"idle|working|blocked|done"}`. Check with `hc get <t> | jq .status`. `null` means a trust dialog or other pre-prompt screen, or (upstream #158) Claude's daemon owning the PTY. Workaround for the latter: `CLAUDE_CODE_DISABLE_AGENT_VIEW=1`.
- **No conversation resume.** After a core crash, reboot or `hc server stop`, kept terminals return as fresh shells in their folders. Run `claude --resume <id>` yourself, under the **same account's `CLAUDE_CONFIG_DIR`**, or it won't find the session. A planned `hc update` keeps programs running (holders own the PTYs).
- **Layouts are window chrome, not workspaces.** JSON `block/row/column/stack` trees that place existing tabs, panes and mods. They can't create spaces or tabs or run commands. Script structure imperatively: `herdr-app do space.new | tab.new | terminal.open --argv '[…]'`.
- Installed outside the Brewfile: `~/.local/bin/{hc,herdr-core,herdr-app}`, `~/Applications/Herdr.app` (notarized, Herdr, Inc.). State lives in `~/.local/state/herdr-core/`, config in `~/.config/herdr-{core,app}/`.

Evaluation, gaps, and the migration plan: `docs/herdr-core.md`.
