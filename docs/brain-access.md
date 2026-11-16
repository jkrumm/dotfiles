# Reaching the brain from something that isn't the mini

The vault lives at `~/SourceRoot/brain`. **The sync contract is owned by that
repo** — `brain/docs/brain-access.md` is the authority for roles, the
`brain-sync.sh` script and conflict handling. This page covers only the
dotfiles-side machinery around it.

## The model, in one line

**Git through GitHub is the only replication.** `com.jkrumm.brain-sync` runs on
both machines every 300 s (`git pull --rebase --autostash`, then push); the
MacBook commits when the tree is dirty, the mini never does outside the nightly
`com.jkrumm.brain-backup` (03:30) sweep. No CouchDB, no Syncthing, no plugin
committing on its own timer. Multi-writer sync was tried (LiveSync) and failed
silently for ten days — the vault gained 13 commits while CouchDB sat untouched.

**Offline is not a job fault.** A pull or push that fails on the network (github.com
unresolvable, a timeout, no route) counts toward the Kuma DOWN streak (3 ticks) but
the tick exits 0, so `jobs-grade` does not file a "job needs a fix" Issue for a home-line
outage. A conflict, an auth failure or a rejected push still exits 1.

| Device | Access | Can write? |
|-|-|-|
| Mac mini | the vault itself; Claude Code `/brain`, Hermes, Obsidian | yes |
| MacBook | full `git clone` at `~/SourceRoot/brain` | yes — pull first |
| iPhone | Hermes/Slack for capture; the read-only web door for reading | capture only |

### MacBook

A full clone, so real Obsidian: Dataview, Excalidraw, folder notes, canvas,
offline. It is also the vault's only second copy of any kind.

- **It is a documented exception to "this MacBook holds no project repos"** —
  `config/global.CLAUDE.md` says so, so a future session does not read it as
  drift and delete it.
- **`.obsidian/plugins/` is untracked**, so a fresh clone has the plugin
  *declaration* but not the binaries. Install `dataview`, `folder-notes` and
  `obsidian-excalidraw-plugin` from the community store on first open;
  `.obsidian/community-plugins.json` is the tracked list.

- **Sync auth uses a deploy key, not 1Password.** `~/.ssh/id_ed25519_brain_sync`
  (a write deploy key on `jkrumm/brain` only, titled `brain-sync-macbook`)
  replaced the 1Password agent for `brain-sync.sh` on 2026-11-07. The agent
  refuses while 1Password is locked, so about one tick in ten failed and the
  vault lagged. Revoke: delete the key file and the deploy key on GitHub.

Discipline: pull before writing. Skip it and you rebase against the mini's 03:30
auto-commit — recoverable, just annoying.

**Syncthing + Möbius** was rejected for the phone: a full copy of a private vault
on a losable device, conflict artefacts (`.sync-conflict-*.md`) gitignored here
and therefore invisible to both git and the nightly backup, and the only thing it
buys over a read door is phone *writing*, which goes through Hermes instead.

## Obsidian must keep running on the mini

`obsidian-cli` is a **client of the running app**, not a standalone tool — it
speaks to `~/.obsidian-cli.sock` and exits 1 with "please make sure Obsidian is
running" for every subcommand, `version` included. `/brain` and Hermes's obsidian
skill both go through it, so a closed Obsidian is a closed agent door.
`make obsidian-autostart` installs the LaunchAgent (`open -a Obsidian`,
deliberately **no** `KeepAlive` — an agent exec'ing the binary bypasses
LaunchServices and would respawn the app the instant a human quits it). The
heartbeat's obsidian component asserts the CLI answers.

## The read-only web door

`~/SourceRoot/basalt-ui-obsidian` builds the vault into an offline-first static
reader, served on the mini as `brain-web` by Caddy's `file_server` (loopback
`:7733`, no container, no VM) behind `brain.test` locally and
`brain.mini.jkrumm.com` on the tailnet — how the iPhone reads the vault, with
no app and no copy. The ACL grant is the existing `tag:devhost` one on `tcp:443`,
so it needs no new exposure.

`com.jkrumm.brain-web-refresh` (300 s) keeps it current and is **downstream of
brain-sync, not a replacement**: it polls the vault's git HEAD and runs
`make refresh` only when it moved. A no-op tick is one `git rev-parse` and no log
line. It rebuilds `dist/` in place and Caddy reads it fresh per request, so a
rebuild is live on the next request with nothing to restart. The cache policy
(no-cache for `/`, `/index.html`, `/vault.json`, `/search-index.json` and
`/sw.js`; immutable `/assets/*`; SPA fallback to `/index.html`) lives in the
`:7733` block of `config/Caddyfile`. This was an nginx container in the Colima
VM until 2026-11-14, and a VM restart took the door down.

Two constraints from that agent, both already paid for elsewhere:
`ProgramArguments` points at the shell script and **never at a Homebrew binary**
(Background Task Management denies a raw Homebrew entry point and silently
downgrades the agent to `[enabled, disallowed]`, skipping `RunAtLoad`), and
launchd's minimal PATH is fixed up inside the script.

**The door goes dark whenever the mini is off.** That is what the MacBook clone
covers.

## Obsidian on the mini (moved from the root AGENTS.md)

**Obsidian must keep running on the mini** (`make obsidian-autostart` — `open -a
Obsidian`, deliberately no `KeepAlive`, or it respawns the instant a human quits
it). `obsidian` (`/opt/homebrew/bin/obsidian` → the app bundle) is a **client of
the running app** and exits 1 on every subcommand when it is down, so a closed
Obsidian is a closed agent door for `/brain` and Hermes. `docs/brain-access.md`.
