---
name: herdr
allowed-tools: Bash(hc --help *)
description: "Run and steer terminals and agents through herdr-core (hc) and show them in the Herdr desktop app (`herdr-app`): hc run/read/send/wait/attach/kill, machines (mini), templates, labels, events, the OpenRPC API, and placing a terminal in a given space and tab. Use when the user names Herdr, hc, the app, a space or tab, or asks to run a program or agent in a persistent terminal, read or message another agent, or arrange what the window shows. Not for starting agent work in general: that is `@implementer` and the factory Issue (lane policy below)."
---

# Herdr — herdr-core (hc) + the Herdr app

Two binaries, one vendor. **hc** owns the terminals: persistent PTYs that outlive every viewer, parent/child agents,
labels, an event stream, other machines. **herdr-app** is the native window on top (spaces, tabs, panes, layouts, mods).

Verbs, live from the CLI (if you see the command and not its output, run it):

!`hc --help 2>&1 || echo "hc is not on this machine"`

Each binary ships a manual versioned with the release (several releases a week): `hc --skill` and `herdr-app --skill`
(MacBook only, the mini has no app). The flags of a verb come from its help, the API from `hc schema`; read them instead of
trusting memory or this file.

`$HC_TERMINAL_ID` is your address inside a core terminal (`t7`; on another machine `mini/t7`). `<t>` below is an id, a
name or `machine/tN`.

## Rules for this setup

- **One space per project.** Work happens in tabs inside it. A new space only for genuinely separate work (a
  long-lived worktree), named so `config/herdr-app/groups.json` files it into the right sidebar folder; a new repo
  gets one line there. The sidebar stays clean.
- **Agents visible, helpers hidden.** An agent is a labelled tab (visible). A helper is an unlabelled child (`--parent` =
  the spawner, `--outlive-parent` when it must survive it): no tab, and the jk layout replaces the agents mod, so it shows
  nowhere in the app. Find workers in `rd agents` (a `parent` field in the JSON listing; finished ones fold into
  `hidden_finished`). Don't add labels to a background worker.
- **Lane policy wins over the manual.** The manual says to delegate through `hc run … claude`. Here only `@implementer`
  and the factory Issue start agents (`docs/agent-platform.md`). Run a non-agent program (tests, a watcher, a dev server)
  in a terminal, an agent only when the user asks for one.
- **The account is chosen on the command, never inherited.** A core's env is every terminal's env, and run forwards
  nothing: write `env CLAUDE_CONFIG_DIR=<dir> claude …` (no variable = the `iu` account). Through the API,
  `terminal.run` takes `env`.
- **launchd owns the core**: the core is upstream's `Herdr Core.app` (Full Disk Access is granted to it once). On the mini
  the `com.jkrumm.herdr-core` starter detaches into upstream's launchd job; the MacBook's Herdr app starts its own. Never
  `hc server restart|stop`, `hc machine update` or start a core from ssh (a stray: no keychain, Claude runs logged
  out). Any hc call auto-starts a core when none runs, so scripts check `scripts/lib/core-up.sh` first. Updates are
  `make herdr-core-update` by hand in a quiet window (`docs/herdr-core.md` §How the core runs now).
- **Never stop or restart the owner's app or core**, and never experiment in them: use a scratch core (own
  `HC_SESSION`, scratch `XDG_*` and `HERDR_APP_HOME`), torn down afterwards.
- **Read, never attach** (attach is for a person; Ctrl+\ detaches). Read shows the screen; `--lines N` adds history above it. Never sleep or poll: `hc wait`.
- **Clean up what you started:** kill, then remove the terminal. Children end with their parent unless
  `--outlive-parent`; a top-level run from a shell keeps going.

## Conventions the listing does not say

- Running a program streams it and returns its exit code; at 180 s it returns 124 while the program keeps running.
- A `--bg` name is 1-32 of lowercase `a-z0-9-_`, not shaped like an address (`t7`); pass `--cwd`.
- `hc wait --output X` matches text printed *after* the wait starts. `--children all|any` waits on your helpers and
  returns early on a message or `timeout`: wait again.
- Send pastes and presses enter, and refuses a `blocked` terminal unless `--force`: never bypass a permission decision.
- A run `--on mini` returns `mini/t3`; exec gives exact output with no terminal.
- Templates live in `~/.config/herdr-core/templates/<name>.md` (none installed today).
- Labels of ours: `jk.claude.session`, `jk.claude.config` (resume, below), `herdr.space`, `herdr.tab` (placement). `k=` removes one.
- `--keep` replaces a lost program with a shell, never re-runs it. Claude conversations come back through `hc-resume`
  (labels), not the core.
- Events: on `missed` (a gap) rebuild from a snapshot; stream EOF means the core restarted. The API over stdin/stdout is
  also `ssh mini hc connect`; documents go through `doc.get`/`doc.set` (compare-and-set on a version).
- Status comes from the program's OSC 7501 reports (`idle|working|done|blocked|error`; plain programs report none), never from
  screen text. Claude Code reports natively; `null` on a Claude terminal means a trust dialog.

## Placing a terminal in a space and tab

Through the app (a window is open, the user wants to see it): `herdr-app ls` for ids, then
`herdr-app do space.new --name api --folder /path` · `tab.new --name "fix login" --argv '["claude"]'` ·
`pane.split --direction right --pane p12` · `agent.focus --terminal t7`; `--machine mini` for a space on the mini.
`herdr-app commands` lists every command and shape. Always an explicit name; ids from `ls`, never guessed.

Without a window (what rd and the factory do): `hc run` with labels `herdr.space=<space id>` (+ `herdr.tab=<chosen
id>`, else the app makes a tab) and `--keep`; the app adopts them the next time it sees the core. A label naming an
unknown space is not a new space. rd/HcRunner own the exact contract (cwd always, prompt in argv, `no_parent` for
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

Design, verified facts, how the core runs and updates: `docs/herdr-core.md`. Full Disk Access: `docs/tcc.md`.
