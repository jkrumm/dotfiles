# Reaching the brain from something that isn't the mini

Written 2026-07-31, replacing LiveSync. Companion to the `brain` row in
`config/global.CLAUDE.md` and to the vault's own `AGENTS.md`.

## The model, in one line

**The mini is the single writer. Git is the only durability. Everything else
reads.**

Writes arrive three ways, all of them on the mini: agentically through Claude
Code's `/brain`, agentically through Hermes, or from a human sitting at the
machine. A nightly LaunchAgent (`com.jkrumm.brain-backup`, 03:30) commits and
pushes whatever Obsidian touched directly, so nothing depends on remembering.

That is a deliberate narrowing, not a limitation to route around. Multi-writer
sync is what LiveSync was, and it failed silently for ten days without anyone
noticing — the vault gained 13 commits while CouchDB sat untouched.

## Why not the obvious alternatives

**Syncthing + Möbius** was the closest match to what LiveSync promised, and was
rejected on three counts: it puts a full copy of a private vault on a phone that
can be lost; its conflict artefacts (`.sync-conflict-*.md`) were gitignored here,
making them invisible to both git *and* the nightly backup; and the only thing it
buys over a read door is phone *writing*, which now goes through Hermes instead.
It remains additive — nothing in this design forecloses adding it later.

**Git clones everywhere** (Working Copy on iOS driving Obsidian mobile) was
rejected for the phone only. On the MacBook it is exactly the right answer.

## What each device gets

| Device | Access | Can write? |
|-|-|-|
| Mac mini | the vault itself | yes — sole writer |
| MacBook | `git clone` at `~/SourceRoot/brain` | yes, by pulling first |
| iPhone | Hermes/Slack for capture; read-only web door (planned) | capture only |

### MacBook

A full clone, which means real Obsidian: Dataview, Excalidraw, folder notes,
canvas, offline. It is also the vault's only second copy of any kind.

Two things about it are easy to get wrong:

- **It is a documented exception to "this MacBook holds no project repos".**
  That rule exists because the two trees diverged once already. Brain is
  exempted on purpose; `config/global.CLAUDE.md` says so, so a future session
  doesn't read it as drift and delete it.
- **`.obsidian/plugins/` is untracked**, so a fresh clone has the plugin
  *declaration* but not the binaries. Install the three from the community
  store on first open: `dataview`, `folder-notes`, `obsidian-excalidraw-plugin`.
  `.obsidian/community-plugins.json` is the tracked list.

Discipline: `git pull` before writing, push after. Skip it and you rebase
against the mini's 03:30 auto-commit — recoverable, just annoying.

### iPhone

Capture goes to Hermes over Slack, which writes into `00_Inbox/` on the source
of truth. No vault data lives on the phone at all.

Reading is the planned web door below.

## Obsidian must keep running on the mini

`obsidian-cli` is a **client of the running app**, not a standalone tool — it
speaks to `~/.obsidian-cli.sock` and exits 1 with "please make sure Obsidian is
running" for every subcommand, `version` included. `/brain` and Hermes's
obsidian skill both go through it, so a closed Obsidian is a closed agent door.
`make obsidian-autostart` installs the LaunchAgent (`open -a Obsidian`,
deliberately **no** `KeepAlive` — an agent exec'ing the binary directly bypasses
LaunchServices and would respawn the app the instant a human quits it).

**The web door could eventually retire this**, which is the one good argument
for building it beyond aesthetics: a static build serves read, full-text search
and backlinks without an Electron process. What would still be missing is
`obsidian orphans` / `obsidian deadends` — graph queries the filesystem fallback
can't cheaply replace. Revisit after the door exists, not before.

## Outstanding work

### Tear down the homelab CouchDB

Untouched since 2026-07-21 and strictly superseded by git HEAD. **This is now a
destroy, not a migrate:** `_device-settings` held the end-to-end passphrase in
plaintext and was deleted on 2026-07-31 rather than carried onto a machine about
to have FileVault disabled. The replica can no longer be decrypted, which is
fine — every note in it is in git history — but it does mean there is no reason
to keep the container. The HTTP credential survives in `op://homelab/couchdb`.

### The read-only web door

Target: `brain.mini.jkrumm.com`, one more `host` matcher in the existing
`*.mini.jkrumm.com` wildcard block, reachable from the phone and the MacBook
over the tailnet with no app and no copy. The ACL grant already exists
(`tag:devhost` ← `tag:mac`/`tag:phone`/`tag:tablet` on `tcp:443`), so this needs
no new exposure.

Three things to decide when building it:

- **Dataview does not render in a static build**, and 7 notes use it — including
  `03_Projects/03_Projects.md` and the Areas index pages, i.e. the pages you
  land on first. They would appear as code blocks. The fix is generating those
  index lists at build time instead of querying them, which has the side benefit
  of making them legible in a plain `git diff`.
- **Rebuild trigger.** Cheapest is a post-commit hook plus the nightly backup
  run; a file watcher is the alternative.
- **Engine.** Quartz is the default choice — it *is* the backlinks/graph/FTS
  layer, and rebuilding that inside Argo or a custom basalt-ui app to gain a
  theme trades weeks for aesthetics. Quartz is themeable, so the zinc tokens and
  the One Zinc palette can go on top without touching the engine. A custom app
  is the honest Stage 3 option if the read surface ever needs to do something
  Quartz structurally can't.

**The door goes dark whenever the mini is off**, including the move. That is
what the MacBook clone covers.
