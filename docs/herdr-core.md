# herdr-core + Herdr app — the design we run

herdr-core (`hc`) is a headless core that owns the PTYs; the Herdr desktop app is a native window on top of it.
Both machines run a core under launchd; the MacBook runs the app and links the mini's core as machine `mini`.
Classic herdr 0.9 still hosts the agents until the retirement plan (`docs/waves/PLAN.md`) removes it in Wave 7.
This page is the target design (§Port design), the facts it rests on (§Verified facts) and the upstream state.
Operational how-to: the `herdr-core` skill until Wave 6 replaces it with the new `herdr` skill.

## What the split buys

| Gain | Over herdr 0.9 |
|-|-|
| Core outlives every viewer; a core restart keeps the programs running (holders) | A herdr restart or upgrade kills every pane process |
| Agents run agents: `hc run` makes a child, `hc wait --children`, the parent gets notes, children end with the parent unless `--outlive-parent` | No parent/child model |
| One window over several machines (`hc machine add`) | `herdr --remote` attaches one client to one server |
| OpenRPC API (`hc schema`), `hc connect` over stdio/SSH, sequenced events with gap recovery | TUI JSON socket |
| UI as files: JSON layouts, JavaScript mods that hot-reload | Plugins only |
| Native window on libghostty's VT engine | TUI inside Ghostty |

## What it costs

- **No Claude conversation resume in core.** OSC 7501 carries no session reference, and Claude's record has none
  (fact 7). herdr-core #13 is closed as not planned until the protocol grows one; #15 proposes a `resume` key and
  has no maintainer answer. We record the session ourselves (§Port design, resume).
- **App auto-update has no off switch** (herdr-app #207, open). The updater checks hourly. It never updates a
  managed core (fact 4), which is what pins the part that matters.
- **TCC is keyed on the core binary.** Every program in a launchd core is attributed to `herdr-core` itself, which is
  ad-hoc signed, so a Full Disk Access grant does not survive a new binary (fact 5).
- **Beta cadence, checksum-only manifests.** Six core and seven app releases between 2026-10-23 and 2026-10-30.
  `releases.herdr.dev` serves `core|app/latest.json` and `<kind>/<version>/manifest.json`. The SHA-256 comes from
  the same service, there is no index page, and the manifests carry no date. Dates come from the HTTP
  `Last-Modified` of a manifest (core 0.1.15: `Fri, 30 Oct 2026 18:48:59 GMT`) or the GitHub tags.

## Port design

Decided 2026-10-31 (Wave 1). Every classic consumer has one fate. The wave that does it is in `docs/waves/PLAN.md`.

| Classic consumer | Fate | hc-world replacement |
|-|-|-|
| software-factory `HerdrRunner` + witness | port | `HcRunner` over `hc connect` (spawn contract below). Witness on `events.subscribe`: `status`, `turn`, `lost`, `restarted`, `finished`, `removed`, `labels`; `missed` = replace state from the snapshot. A **core** restart is the stream ending (EOF), then reconnect and compare `server.status` `pid`. `restarted` is per terminal: a kept program was lost and replaced by a shell |
| `rd work\|wave\|fan\|close\|read\|say\|agents` | port | factory first, hc direct as fallback. Until Wave 7 removes classic herdr, `read`/`say`/`close`/`agents` still reach a classic agent (the classic path stays as a fallback for a target hc doesn't know, and `agents` lists both rosters), and classic `herdr-reap` keeps running. Space = the `herdr-app` doc entry whose `folder` is the repo root, else a new `sp-<repo>-<hash>` id (hash of the full root, so `~/SourceRoot/x` and `~/IuRoot/x` never share one); tab = a chosen `herdr.tab` id. `read` → `hc read`, `say` → `hc send` (refuses on `blocked`), `close` → `hc kill` + `hc rm` |
| Waves: orchestrator tab, workers | port | orchestrator = labelled tab; workers = unlabelled children (`parent` = orchestrator): no pane, listed as the parent's `sub_agents`. Factory spawns keep `factory session wait --on workers`: a held (`queued:`) spawn has no hc terminal yet, so `hc wait --children` would return before it starts. `hc wait --children all\|any` and the notes hc types into the parent replace `herdr agent wait` on the hc-direct path |
| `resume_agents_on_restore` | replace | Claude SessionStart hook sets labels on its own terminal: `jk.claude.session=<id>` and `jk.claude.config=<CLAUDE_CONFIG_DIR>`, or `jk.claude.config=` for `iu` (`key=` removes the label, so a reused terminal never keeps the previous account). `hc-resume` (on a `restarted` event, on its own start, after every reconnect and on a `missed` snapshot, since a `restarted` event can fall into a gap) types `env CLAUDE_CONFIG_DIR=… claude --resume <id>` (`env -u CLAUDE_CONFIG_DIR …` when the label is absent, i.e. `iu`) into each kept shell that carries the labels: one attempt at a time per terminal, and only while its foreground is still a login shell. Labels survived a `kill -9` of a kept program and a core restart, and `terminal.list {labels}` filters on them. They live and die with the terminal, so nothing needs pruning (a core doc was the seeded design) |
| `herdr-reap.py` + `com.jkrumm.herdr-reap` | port | same rules over `terminal.list {all}` / `kill` / `rm` / `send` |
| `herdr-events.ts` + `com.jkrumm.herdr-events` | port | `events.subscribe` recorder, same JSONL dir; gap markers from `missed`, from stream EOF (core restart) and from an unparseable line |
| `herdr-groups.py`, `make herdr-groups*` | retire | `jk-spaces` folders; `config/herdr/groups.json` moves to `config/herdr-app/` |
| `make agent-overview` pane + heartbeat `overview pane` component | **retire** | the app's sidebar status dots and agents list. `agw agents` stays the JSON producer, ported to hc |
| collie + ACL/serve rows | **port** | upstream ColliePWA runs on herdr-core with `COLLIE_MUX=herdr-core` (experimental, core ≥ 0.1.14). Bump `COLLIE_REF`, run it standalone (not a herdr plugin), and keep the `:8787/:8788` rows. If its behavioural check fails on hc, collie retires and the rows go. Shepherdr (`eliasstravik/shepherdr`) is the alternative, not adopted |
| `desk` (`herdr --remote mini`) | replace | the app (MacBook); terminal-only fallback `ssh -t mini hc` |
| `claude-relogin.sh --machine mini` | port | `hc run --on mini` labelled into a `relogin` tab. The mini core is a launchd GUI-session child with the keychain |
| `claude-appearance.sh` / `appearance-sync.sh` | **port** | still needed (fact 6): an unattached terminal gets fixed dark answers, and a running program gets no push on a switch. The push moves from `herdr pane send-text` to raw input over `terminal.attach` (`hc send` always adds Enter). Drop it only when a core release does both: unattached terminals answer from the Mac's appearance, and running programs get `?997` on a switch |
| `brain-note.sh` (prefix+e popup) | port | a small mod: `keys.json` `"<key>": "jk-keys.brain-note"` reaches the mod's `nextCommand()`, which starts the script with `hc run --bg` and shows it with `terminal.peek` (fact 8) |
| `herdr-agent-state.sh` SessionStart hook | retire (Wave 7) | Claude reports to the core natively over OSC 7501 (fact 7); the classic agents still need it until they are gone |
| `herdr-server-start.py`, `_herdr-supervise`, `lib/herdr-ready.sh`, `herdr-upgrade.sh`, `herdr-wait-quiet.sh`, `herdr-skill-sync.sh`, `make herdr-{setup,upgrade,restart,status,launchd-status,server-start-test}` | retire | `com.jkrumm.herdr-core` + the Wave 8 upgrade target |
| heartbeat herdr component, `doctor.sh`, `brew-upgrade.sh`, `architecture-check` `herdr.*` regex, `log-rotate` collie log, `mini-macos-update` pane snapshot | port | core LaunchAgent running + `hc server status` + MacBook/mini version parity; the resume labels are the pre-reboot snapshot |
| `Brewfile` `herdr`, cask `penso/tap/herdr-gpui`, tinycast `so.pen.herdr-gpui` hotkey, `config/herdr/config.toml`, `config-gpui.local.toml` | retire | Herdr.app, bundle id `dev.herdr.app` (its `Info.plist`) |
| agent-workflows `agw agents` collectors (+ argo `herdrStatus`) | port | `terminal.list` over `hc connect` (full records: labels, parent, status), which already includes linked machines as `machine/tN`. `hc ls --json` is a compact view without labels or parent |
| iris herdr destination (raw `herdr.sock`) | port | `terminal.list` (labels) + `terminal.send` over `hc connect`; the destination value stays `"herdr"` |
| hermes-agent `skills/herdr`, SOUL/AGENTS/config refs | port | hc-world skill text |
| shutterflow `scripts/fleet/*` + PROTOCOL | port | `hc run`/`send`/`ls`/`kill` |
| sy-serendipity AGENTS.md dev-server pane | port | `hc run --bg --name dev …` + `hc wait --output` |
| brain wiki (`wiki/engineering/herdr.md` and live how-to pages) | port | rewrite live pages; dated pages, log and podcasts stay history |
| IuRoot/prometheus-epx eval adapter `SubprocessHerdr` | port, owner pushes | `EP-XX` branch committed locally; the MR to colleagues is the owner's step |
| jkrumm.com published guide, weatherorb/basalt-ui/prometheus-stack plans, archives | history | untouched, listed in the final report |
| comments: ghostty, starship, ssh_config, usage-tracker, modelpick, homelab monitors, linewatch, image-gateway | port | one-line fixes when the file is touched anyway, listed otherwise |

### Spawn contract (HcRunner, `rd`, waves)

- **Always pass `cwd`.** Through the API the default is the core's cwd (`/`).
- **Prompt as argv:** `["claude", …flags, "<prompt>"]`. Claude takes the first prompt as an argument (fact 7).
  `first_message` reports only template runs.
- **Account in `env`:** `CLAUDE_CONFIG_DIR` set, or absent for `iu`. Never an empty string, never inherited.
- **Parent:** a worker passes `parent` = the orchestrator's terminal and no labels. A tab (orchestrator, next wave,
  `rd work`) passes `no_parent: true`. The CLI defaults `parent` to the calling terminal, and a child ends with its
  parent's program, so a chain wave spawned without it would die with the wave that spawned it.
- **Placement without a window:** labels `herdr.space=<id>` + `herdr.tab=<chosen id>`, plus `keep: true`. The app
  adopts them the next time it sees the core (fact 1). The tab enters the `herdr-app` doc only then (the app also
  writes the terminal's `where` label), so name it after that: set its `name` with `doc.set` against the version
  just read, and retry on `conflict`. Wave 2 verifies whether writing the tab entry before adoption also works. Touch only tabs and spaces we created.
  The app guide says to change structure with commands, so this write is the fragile part. Without it the tab is
  numbered.

## Verified facts (2026-10-31, core 0.1.15, app 0.1.10)

Run on the mini in scratch cores (own `HC_SESSION`, scratch `XDG_*`), one of them under a scratch LaunchAgent, plus
a scratch Herdr.app instance (`HERDR_APP_HOME`, `HERDR_CORE_DIRS` at a managed-path copy, `HERDR_RELEASES_URL`
pointed at a dead port). The MacBook was offline, so the app ran on the mini's screen. Everything was torn down.

**1. Placement by label.** `space.new` made `sp259f…`. Then:

```text
hc run --bg --name named-agent --label herdr.space=sp259f… sleep 900   → new tab "3" (number, not the terminal name)
hc run --bg --label herdr.space=sp259f… sleep 901                      → new tab "2"
hc run --bg --name ghost --label herdr.space=sp-doesnotexist …         → new space with id sp-doesnotexist, named after the folder
hc run --bg --name w3 --label herdr.space=sp259f… --label herdr.tab=tbwave3 …  → new tab with id tbwave3
doc.set herdr-app (tab tbwave3 name "wave 3")                           → the open window renames it live
```

The app writes a `where` label (`proj / 3`) back, but no `herdr.tab`. With the app quit, a `doc.set` that added
space `spdocmade` and two `hc run`s (into `spdocmade`/`tblead`, and into the unknown `sp-windowless`) showed up on
the next start as `docmade › 1` and `proj2 › 1`. Labels alone create spaces and tabs, and no window is needed.

**2. env and hidden workers.** `terminal.run {line: "echo CCD=$CLAUDE_CONFIG_DIR FS=$FACTORY_SESSION", parent: "t1",
env: {CLAUDE_CONFIG_DIR: …/.claude-me, FACTORY_SESSION: w1}}` printed `CCD=<home>/.claude-me FS=w1`.
`terminal.wait {children: all, terminal: t1}` returned after the child's exit with `reason: children` and the child's
`exit_code: 0`. In the app, an unlabelled child of `t5` got no pane: `herdr-app ls` shows it only as
`sub_agents: ['t6']` on `t5`.

**3. Quitting the app keeps a launchd core.** The scratch core ran under a LaunchAgent, with the app → `herdr-core
connect` attached. `herdr-app do app.quit` (what Cmd-Q runs): the core pid stayed `43314`, the holder stayed and all
6 terminals stayed `live`. #219 is a core started by the app (no LaunchAgent), which both machines avoid.

**4. Managed installs.** The core decides from its own path: `/Cellar/` → `homebrew`, `/mise/installs/` → `mise`,
`/nix/store/` → `nix`, an unwritable folder → `system package manager`, else `null` (`~/.local/bin` today). Copies at
fake paths answered `installed_by: homebrew|mise|nix|null`. Then `hc update --from ~/.local/bin/herdr-core --force`
gave:

```text
Cellar copy: {"error":{"hint":"brew upgrade herdr-core","kind":"refused","message":"…/Cellar/herdr-core/0.1.15/bin/hc belongs to homebrew"}}
plain copy:  {"now":"hc 0.1.15","restarted":true,"was":"hc 0.1.15"}
```

The app reads `managed` from `server.status`, never offers that core an update, and its `app.update_core` shells out
to `hc update`, which refuses. Its guide: "The first start after an app update also updates herdr-core" applies to
unmanaged cores only. Until Wave 8, the MacBook's `~/.local/bin` core can be bumped by the app behind the mini's back.

**5. TCC freezes a launchd core's programs.** A scratch core under a LaunchAgent ran `hc run --timeout 20 "ls
~/Documents"` (also Desktop, Downloads): each one hung (`still running`, exit 124). tccd logged
`AUTHREQ_PROMPTING service=kTCCServiceSystemPolicyDesktopFolder … responsible_path=…/herdr-core,
identifier=herdr_core-f387ea2416bec939`, so a dialog nobody sees on the headless screen. The responsible process is
the core binary, and its identifier is the ad-hoc one, so the grant is keyed to that build. Full Disk Access for
`~/.local/bin/herdr-core` is queued (`ask-human` `20261031T135442-12744`). Every core upgrade needs the grant again
(Wave 8 automates the ask).

**6. Display queries.** A probe answered OSC 10/11, DECRQM 2031 and DSR 996:

| Where | OSC 11 | DSR 996 |
|-|-|-|
| bare core, no viewer, attached or `--bg` | `rgb:2828/2c2c/3434` (fixed) | `?997;1n` (dark) |
| app window, dark theme | `rgb:1717/1919/1d1d` | `?997;1n` |
| same running program after the app switched to light | unchanged, no `?997` push within 25 s (with `?2031h` on) | unchanged |
| new terminal opened after the switch | `rgb:ffff/ffff/ffff` | `?997;2n` |

The viewer's colours reach the core at attach (`terminal.attach` `display`). The core answers queries itself, so
mode 2031 reads `2` (reset), and no change is pushed. The mini's agents mostly run unattached, so they always see
dark.

**7. Events and status.** `hc events --json` lines are JSON-RPC notifications:
`{"method":"event","params":{"seq":N,"terminal":"t5","type":…,"data":…}}`, plus `{"method":"heartbeat","params":{"seq":N}}`
every 15 s. The first line is the snapshot `{"seq":5,"terminals":[…]}`. Shapes seen:

| type | data |
|-|-|
| `created`, `restarted` | the full terminal record |
| `status` | `{"records":{},"reported":true,"status":{"app":"claude-code","state":"working"}}` |
| `turn` | `{"state":"done","turn":1}` |
| `title` | `{"title":"✳ Claude Code"}` |
| `foreground` | `{"argv":[…],"cwd":…,"name":"zsh","pid":12654}` |
| `labels` | `{"labels":{…}}` (the full set) |
| `lost` | `{"exit_code":null,"finished_ms":null,"reason":"signaled","signal":9}` |
| `doc` | `{"name":"resume","version":1}` (no terminal) |

`kill -9` on a kept Claude gave `lost` then `restarted` (argv `/bin/zsh -l`, same address). `hc server restart` of the
scratch core ended the subscription stream and kept every terminal live under the same holder. A subscriber that
stopped reading while ~5000 4 KB label writes went in got 18 events, then
`{"method":"missed","params":{"seq":15191,"terminals":[…]}}` and the stream resumed after that seq. The writers never
blocked, and `hc ls` answered in 0.0 s. One earlier run handed the reader a truncated JSON line before recovery.
Claude 2.1.316's record is `{"app":"claude-code","state":"done"}`, with no session id. `doc.set` is
compare-and-set: a stale version returns `conflict` ("is at version 1, not 0").

**8. Keys.** A `keys.json` action is a command (`name` or `name:value`, value = first argument), `send:<text>`,
`<mod>.<command>` (to that mod's `nextCommand()`), or `terminal`. There is no shell action, and one bad action stops
the whole file from loading. `terminal.open {argv, folder, place: tab|right|down, name}` and `terminal.peek {terminal}`
exist. There is no float command.

**9. Spawn facts (Wave 2, scratch cores).** `outlive_parent: true` keeps a child running after its parent's program ends
(the parent killed, the child with the flag stayed live, the one without was killed). `claude --resume <id> "<prompt>"` is
valid, but `--resume` takes an optional value, so an id must always be passed or the prompt is read as the id. A
`doc.set` of a `herdr-app` space+tab entry before any terminal exists is accepted (version 0 → 1, stale version →
`conflict`); whether the app adopts a pre-written tab entry is **not** verified (no app on the mini), and the doc's shape
(`spaces[].{id,folder,tabs[].{id,name}}`) is a guess: software-factory reads it defensively and falls back to a stable
`sp-<dir>-<hash>` id. `hc connect` exits 2 when no core runs and does not start one (launchd owns the core). hc refuses
a terminal name that can read as an address (`t7`). Verify the doc shape against the app on the MacBook before
trusting tab names.

## Upstream state (2026-10-31)

agw research run `01a191f9-802c-75f1-ab6a-b3914a286ec5` (deep, 39/39 citations grounded, 78 pages). It covers
herdr-core #13/#15 (resume: closed / open, unanswered), herdr-app #207 (no auto-update switch, open), #219 (quit kills
an app-started core, open, no fix version), phone clients and the cadence. ColliePWA and Shepherdr name herdr-core
in their docs. Ovis, Nenu and several web UIs are classic-era. Earlier runs: `01a19101` (evaluation),
`01a19165` (ecosystem).

| herdr-core | Date | | herdr-app | Date |
|-|-|-|-|-|
| 0.1.15 | 2026-10-30 | | 0.1.10 (`core_min` 0.1.11) | 2026-10-30 |
| 0.1.14 | 2026-10-29 | | 0.1.9 | 2026-10-30 |
| 0.1.13 | 2026-10-29 | | 0.1.8 | 2026-10-30 |
| 0.1.12 | 2026-10-26 | | 0.1.7 | 2026-10-29 |
| 0.1.11 | 2026-10-26 | | 0.1.6 | 2026-10-29 |
| 0.1.10 | 2026-10-23 | | 0.1.5 | 2026-10-27 |

## Core as a LaunchAgent

`com.jkrumm.herdr-core` (`make herdr-core-setup`, **both machines**) runs `hc serve` as a KeepAlive LaunchAgent, **bootstrapped into `gui/<uid>`**. The MacBook links the mini's with `hc machine add mini --name mini` (once; ssh config host `mini`).

- **A core's environment is every terminal's environment.** `hc run` does not pass the caller's env on (verified 2026-10-31): terminals get the core's. A core started by hand from inside Claude passed `CLAUDECODE`/`CLAUDE_CODE_CHILD_SESSION` to every terminal, and every Claude in it ran as a non-persisting child session (no transcript, no `--resume`). launchd's clean env is the fix. Corollary: an account is chosen on the command (`env CLAUDE_CONFIG_DIR=… claude`), never inherited.

- **Always up, on purpose.** Any `hc` client call auto-starts a core when none runs, including the MacBook's link arriving over ssh. A core born in an ssh session spawns Claude without the login keychain (the `ssh mini 'claude …'` trap). Under launchd, a terminal in the core reaches the keychain (verified 2026-10-31).
- **Restart = `launchctl kickstart -k gui/$(id -u)/com.jkrumm.herdr-core`.** Terminals survive: a `sleep` kept its pid across the kickstart (verified). Don't use `hc server restart`, `hc update` or `hc machine update mini` on the mini. They restart the core outside launchd's view, and that combination is untested.
- **Upgrade:** `scp ~/.local/bin/herdr-core mini:.local/bin/`, then the kickstart. Keep MacBook and mini on the same `hc` version (`hc machine ls` shows it). Wave 8 replaces this with a pinned, managed install.
- State: `~/.local/state/herdr-core/` on the mini. Log: `~/Library/Logs/herdr-core.log`.

## Desktop layout (MacBook)

`make herdr-app-setup` converges the app onto `config/herdr-app/`. It's idempotent, and needs the window open to switch the layout and open spaces. It ends by switching layouts away and back, the only reload that picks up edits inside a symlinked mod folder.

| Piece | Source | Lands as |
|-|-|-|
| `jk` layout: the shipped `main` with `jk-spaces` instead of spaces + agents, `jk-status` as the bar, `jk-waves` as a right column (`waves`, 320 px, resizable, `cmd-shift-b` toggles it), theme `one-zinc-{light,dark}` following the system | `config/herdr-app/layouts/jk.json` | symlink |
| `jk-spaces`: Herdr's `spaces` mod (Apache-2.0) plus folders. Folders come from **`config/herdr/groups.json`**, the same taxonomy as classic herdr's sidebar. A space joins the group naming its repo (worktrees follow their repo), the rest go to the fallback (`OTHER`). Folders fold (state in the app), a folded folder shows ● when a space in it needs you. A row is a status dot plus the name: filled while an agent works, is blocked or just finished, a dim ring while its agents are all idle; hovering the dot names the state. Mini spaces take their agents from classic herdr (`agw agents` on the mini every 10 s, each project matched to the space whose folder is the longest prefix of its cwd), merged with core's status, most urgent wins: no letter avatar, no folder colors, no git tail, compact rows, this computer labelled `MacBook` | `config/herdr-app/mods/jk-spaces/` | symlink |
| `jk-status`: CPU % and memory used (active + wired + compressed; whole numbers in fixed-width cells) for this computer and every connected machine, every 5 s via `exec … { on }`. Claude usage per account (`5h/7d %`, uncolored by quota, then `∑<pool>%`: the statusline's plan-weighted 7-day use across accounts, also in the usage popup's header; dim when the sample is > 3 h old, `login` when auth failed), every 60 s from `claude-account usage --json`, which reads its local quota cache only (the MacBook's includes the mini's samples). Bottom right: Uptime Kuma `▲up ▼down` over every active monitor (down count red, the down names on hover), every 60 s, read-only from Kuma's SQLite on homelab over keyless Tailscale SSH, the same read as `make doctor` | `config/herdr-app/mods/jk-status/` | symlink |
| `jk-waves`: the right column, a read-only overview of wave work on the mini. Every 30 s, one `exec … { on: "mini" }` runs `factory --format json status` (sessions + spawn queue, via `secrets-run`) and reads every `docs/waves/PLAN.md`'s headings; the last good data stays and dims after 2 min. A repo shows while a live session runs in its cwd (worktrees fold into the repo) or a spawn is queued; an `active` plan with no session goes into a collapsed `PAUSED`, one with only pending waves into a collapsed `PLANNED`, finished plans are hidden. Repos sit under `groups.json`'s folders. A card: status dot (needs you: blocked or `wait=owner` > working > waiting, an amber ring > idle, a dim ring; every dot names its meaning on hover, and a legend at the column's foot lists all colors including the left sidebar's blue `done`), plan title, `Wave n/N` with a progress bar, the active wave; a click expands pending waves, sessions (role, id, state, account) and queued spawns with their hold. Header: running / live / queued / queue state, plus how many need you. `make herdr-app-setup` also binds `cmd-shift-b` → `layout.toggle:waves` in the app's `keys.json` (merged with jq, never overwriting a binding) | `config/herdr-app/mods/jk-waves/` | symlink |
| `jk-details`: the popup behind a click (it opens with its bottom edge 10 px above the clicked field, centered on it; the card measures itself, remembers its height per kind and re-places itself once when the guess was off, so a growing or shrinking content always sits right) on a machine (15-min CPU and memory history plus the top 10 processes on that machine, live) or on the usage (each account's plan as Anthropic now names it: Max 5x = Max, Max 20x = Ultra since 2026-10-30; 5-hour and 7-day % with reset countdown and clock time; a note only when the data is over 3 h old or the login expired). The process table has a fixed height, so the popup doesn't jump when it loads | `config/herdr-app/mods/jk-details/` | symlink |
| Claude problems: `jk-status` reads **`claude-account health --json`** every 5 min: login, quota and pending-ask health of both machines (the peer read through its core, ssh as fallback; an unreadable login is a warn), each problem with its fix command. It's the same source Tinycast reads; the app implements no quota or expiry logic of its own. Any row that isn't ok adds a `⚠ <id>·<machine>` chip (amber warn, red fail). The usage popup lists them under their account, with a **Re-login** button that runs the row's `fix` detached, only when it is exactly `claude-relogin <id> --machine macbook\|mini` (§Re-login in `docs/claude-accounts.md`) | `jk-status`, `jk-details` | — |
| Themes `one-zinc-*`: the terminal palette (`docs/theme.md`) plus a `colors` map for the chrome taken from basalt-ui's semantic tokens (background, card, sidebar, border, accent: the oklch values converted to hex), so sidebar, bars and popups read as basalt-ui rather than derived darker. `basalt-ui-*` is the Blueprint palette, converted from `config/ghostty/themes/` | `config/herdr-app/themes/` | symlink, pickable in Settings |
| Spaces shutterflow, ShutterflowOps, tinycast-extensions, finances, dotfiles | `SPACES` in `scripts/herdr-app-setup.sh` | `herdr-app do space.new`, skipped when one already works in that folder |
| Mini spaces: one per repo classic herdr has open on the mini (label resolved to `~/SourceRoot/<name>` or `~/IuRoot/<name>`), filed into the same folders | classic herdr's live workspace list | `space.new --machine mini`, skipped when already open. Spaces only, no agents |

A new repo gets its folder through one line in `groups.json`. Revert to stock with `herdr-app do layout.switch --name main`. The theme picker in Settings overrides the layout's theme.

## Ecosystem notes (2026-10-31)

A snapshot from agw research run `01a19165` (deep, partial: 22/34 citations grounded, so treat repo names and star counts as leads). The scene is days old: about 68 `herdr-mod` and 36 `herdr-layout` repos, mostly one to five commits.

| Pattern | Seen in | Status here |
|-|-|-|
| Folders over spaces | jankeesvw/herdr-space-folders (unlicensed), ejklock/herdr-workspaces | Done our way in `jk-spaces`, from `groups.json` |
| One status bar with machine load and plan usage | DanielFGray/herdr-config, berkeatac/herdr-usage-bar, kvkenyon/herdr-quota | Done in `jk-status`. Ours reads `claude-account`'s cache; theirs read the keychain and call the API |
| Click-through detail popup | DanielFGray (same mod, `props.panel`) | Done in `jk-details` (a separate mod). None of the public mods shows top processes |
| Orchestrator visible, workers hidden | Workers as unlabelled children (fact 2) | Built in, no mod needed: Waves 2–3; until then `jk-waves` shows leads, waves and workers from the factory's sessions |
| Light chrome as a design, not a palette | ritiksahni/herdr-linen | Basalt tokens in the theme `colors` |
| Import classic workspaces into the app | CiprianSpiridon/herdr-migration (claims conversation resume; **unverified**) | Not used: classic sessions are not carried over |
| Resume after a reboot | herdr-agent-resume stopgap in herdr-core #13 (SessionStart hook → labels, a key types `claude --resume`) | Same idea as ours, triggered by events instead of a key |
| Phone client on herdr-core | ColliePWA (`COLLIE_MUX=herdr-core`), Shepherdr | Collie ports (§Port design) |

The official `herdrdev/herdr-layout-examples` (board, call, chat, code, mission, pasture, threads, tmux-prefix) is the best API tour; several of its controls are decorative. App telemetry is on by default; `HERDR_TELEMETRY=0` or `DO_NOT_TRACK=1` turns it off (`~/.config/herdr-app/AGENTS.md`).
