---
name: herdr
description: "Run and steer terminals and agents through herdr-core (`hc`) and show them in the Herdr desktop app (`herdr-app`): hc run/read/send/wait/attach/kill, machines (mini), templates, labels, events, the OpenRPC API, and placing a terminal in a given space and tab. Use when the user names Herdr, hc, the app, a space or tab, or asks to run a program or agent in a persistent terminal, read or message another agent, or arrange what the window shows. Not for starting agent work in general: that is `@implementer` and `rd wave` (lane policy below)."
---

# Herdr — herdr-core (`hc`) + the Herdr app

Two binaries, one vendor. **`hc`** owns the terminals: persistent PTYs that outlive every viewer, parent/child agents,
labels, an event stream, other machines. **`herdr-app`** is the native window on top (spaces, tabs, panes, layouts,
mods).

## First step, every time

The binaries ship a manual versioned with the release (several releases a week). Read it instead of trusting memory or
this file for flags:

```bash
hc --skill            # run, read, send, wait, children, templates, machines
herdr-app --skill     # spaces, tabs, panes, layouts, mods, keys (MacBook only; the mini has no app)
hc <cmd> --help       # exact flags
hc schema             # OpenRPC + JSON Schema: the API for anything scripted
```

`$HC_TERMINAL_ID` is your address inside a core terminal (`t7`; on another machine `mini/t7`). `<t>` below is an id, a
name or `machine/tN`.

## Rules for this setup

- **One space per project.** Work happens in tabs inside it. A new space only for genuinely separate work (a
  long-lived worktree), named so `config/herdr-app/groups.json` files it into the right sidebar folder; a new repo
  gets one line there. The sidebar stays clean.
- **Orchestrator visible, workers hidden.** An orchestrator or a wave is a labelled tab (visible). A worker is an
  unlabelled child (`--parent` = the orchestrator, `--outlive-parent` when it must survive it): no tab, listed under
  its parent in the app. Don't add labels to a background worker.
- **Lane policy wins over `hc --skill`.** The manual says to delegate through `hc run … claude`. Here only
  `@implementer` and `rd wave` (incl. `rd fan`) start agents (`docs/agent-platform.md`). Use `hc run` for a
  non-agent program (tests, a watcher, a dev server), or for an agent only when the user asks for one.
- **The account is chosen on the command, never inherited.** A core's env is every terminal's env, and `hc run`
  forwards nothing: write `env CLAUDE_CONFIG_DIR=<dir> claude …` (no variable = the `iu` account). Through the API,
  `terminal.run` takes `env`.
- **launchd owns the core** (`com.jkrumm.herdr-core`, both machines, through the launcher that holds Full Disk
  Access). The only restart is `launchctl kickstart -k gui/$(id -u)/com.jkrumm.herdr-core`. Never `hc update`,
  `hc server restart|stop` or `hc machine update`; never start a core from ssh (no keychain, Claude runs logged
  out). Any `hc` call auto-starts a core when none runs, so scripts check `launchctl print` first. Updates are the
  daily `com.jkrumm.herdr-core-update` job (`docs/herdr-core.md` §Updates).
- **Never stop or restart the owner's app or core**, and never experiment in them: use a scratch core (own
  `HC_SESSION`, scratch `XDG_*` and `HERDR_APP_HOME`), torn down afterwards.
- **Read, never attach.** `hc read <t> --lines N`; `hc attach` is for a person (Ctrl+\ detaches). Never sleep or
  poll: `hc wait`.
- **Clean up what you started:** `hc kill <t>`, then `hc rm <t>`. Children end with their parent unless
  `--outlive-parent`; a top-level `hc run` from a shell keeps going.

## The API surface, verified against `hc` 0.1.15 / app 0.1.10

| Need | Command |
|-|-|
| Run to completion | `hc run cargo test` (streams, returns the exit code, times out at 180 s with exit 124 while the program keeps running) |
| Background | `hc run --bg --name web --cwd <dir> bun dev`; names are 1-32 of `a-z0-9-_` |
| Wait without polling | `hc wait <t>`; `--output X` (text printed *after* the wait starts); `--children all\|any` (your helpers; returns early on a message or `timeout`, then wait again) |
| Read | `hc read <t> --lines N`; `hc get <t>` (state + status); `hc ls [--all]` |
| Talk | `hc send <t> "text"` (pastes, presses enter, refuses on `blocked` unless `--force`: don't bypass a permission decision); `hc keys <t> down enter`; `hc interrupt <t>`; `hc put <t> <file>` |
| Other machines | `hc machine ls`; `hc run --on mini …` returns `mini/t3`; `hc exec --on mini <cmd>` (exact output, no terminal); `hc file read\|write\|edit --on mini <path>` |
| Templates | `hc templates`; `hc run reviewer "task"` (`~/.config/herdr-core/templates/<name>.md`; none installed today) |
| Labels | `hc run --label k=v`, `hc label <t> k=v` (`k=` removes); `terminal.list` filters on them. Ours: `jk.claude.session`, `jk.claude.config` (resume, below), `herdr.space`, `herdr.tab` (placement) |
| Survive a lost program | `hc keep <t>` / `hc run --keep` replaces a lost program with a shell, never re-runs it. Claude conversations come back through `hc-resume` (labels), not core |
| Events | `hc events [--terminal t] [--children-of t] [--label k=v]`: JSON lines; `events.subscribe` over the API with `missed` (gap: rebuild from a snapshot) and stream EOF (the core restarted) |
| API | `hc connect` (JSON-RPC over stdin/stdout, also `ssh mini hc connect`); methods: `hc schema \| jq -r '.methods[].name'`; docs via `doc.get`/`doc.set` (compare-and-set on a version) |

Status comes from the program's OSC 7501 reports (`idle|working|done|blocked|error`; plain programs report none),
never from screen text. Claude Code reports natively; `null` on a Claude terminal means a trust dialog.

## Placing a terminal in a space and tab

Through the app (a window is open, the user wants to see it): `herdr-app ls` for ids, then
`herdr-app do space.new --name api --folder /path` · `tab.new --name "fix login" --argv '["claude"]'` ·
`pane.split --direction right --pane p12` · `agent.focus --terminal t7`; `--machine mini` for a space on the mini.
`herdr-app commands` lists every command and shape. Always an explicit name; ids from `ls`, never guessed.

Without a window (what `rd` and the factory do): `hc run` with labels `herdr.space=<space id>` (+ `herdr.tab=<chosen
id>`, else the app makes a tab) and `--keep`; the app adopts them the next time it sees the core. A label naming an
unknown space is not a new space. `rd`/HcRunner own the exact contract (cwd always, prompt in argv, `no_parent` for
tabs): `docs/herdr-core.md` §Spawn contract.

## Resume after a restart

Core cannot resume a Claude conversation. A SessionStart hook labels its own terminal (`jk.claude.session`,
`jk.claude.config`; empty config = `iu`), and `com.jkrumm.hc-resume` (mini) types `claude --resume <id>` under the
right account into the kept shell after a restart. Model and effort are not restored. Terminals born before a core
cutover keep the old core's TCC identity until they end (`docs/tcc.md`).

## The look

Layout, mods, themes and folders are tracked in `config/herdr-app/`; edit there, then `make herdr-app-setup`. Never edit
the shipped mods under `~/.config/herdr-app/mods/` (clone them). After a mod change: `herdr-app check <mod dir>`,
`herdr-app status`, `herdr-app shot` and look at the picture.

Design, verified facts, launcher and updates: `docs/herdr-core.md`. Full Disk Access: `docs/tcc.md`.
