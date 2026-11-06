# herdr-core + Herdr app — the design we run

herdr-core (`hc`) is a headless core that owns the PTYs; the Herdr desktop app is a native window on top of it.
Both machines run a launchd-born core (§How the core runs now); the MacBook runs the app and links the mini's core as machine `mini`.
Classic herdr 0.9 was removed in Wave 7 (2026-10-31); §Removal lists what it had and what replaced each part.
This page is the design (§Port design, written when the port was decided), the facts it rests on (§Verified facts)
and the upstream state. Operational how-to: the `herdr` skill.

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
- **TCC is keyed on the responsible process.** Since 0.1.17 that is the holder or core itself, and since 0.1.18 the
  signed `Herdr Core.app`, which holds the Full Disk Access grant once (§How the core runs now, `docs/tcc.md`).
- **Beta cadence, checksum-only manifests.** Six core and seven app releases between 2026-10-23 and 2026-10-30.
  `releases.herdr.dev` serves `core|app/latest.json` and `<kind>/<version>/manifest.json`. The SHA-256 comes from
  the same service, there is no index page, and the manifests carry no date. Dates come from the HTTP
  `Last-Modified` of a manifest (core 0.1.15: `Fri, 30 Oct 2026 18:48:59 GMT`) or the GitHub tags.

## Port design

Decided 2026-10-31 (Wave 1); all of it is done and classic herdr is gone (§Removal). Every classic consumer had one fate.

| Classic consumer | Fate | hc-world replacement |
|-|-|-|
| software-factory `HerdrRunner` + witness | port | `HcRunner` over `hc connect` (spawn contract below). Witness on `events.subscribe`: `status`, `turn`, `lost`, `restarted`, `finished`, `removed`, `labels`; `missed` = replace state from the snapshot. A **core** restart is the stream ending (EOF), then reconnect and compare `server.status` `pid`. `restarted` is per terminal: a kept program was lost and replaced by a shell |
| `rd work\|read\|say\|agents` | port | hc direct (`say`: factory first). Space = the `herdr-app` doc entry whose `folder` is the repo root, else a new `sp-<repo>-<hash>` id (hash of the full root, so `~/SourceRoot/x` and `~/IuRoot/x` never share one); tab = a chosen `herdr.tab` id. `read` → `hc read`, `say` → `hc send` (refuses on `blocked`) |
| Factory spawns and hc-direct helper children | port | a factory spawn = labelled tab; a helper child = unlabelled child (`parent` = the spawning terminal): no pane, listed as the parent's `sub_agents`. Factory spawns keep `factory session wait --on workers`: a held (`queued:`) spawn has no hc terminal yet, so `hc wait --children` would return before it starts. `hc wait --children all\|any` and the notes hc types into the parent replace `herdr agent wait` on the hc-direct path |
| `resume_agents_on_restore` | replace | Claude SessionStart hook sets labels on its own terminal: `jk.claude.session=<id>` and `jk.claude.config=<CLAUDE_CONFIG_DIR>`, or `jk.claude.config=` for `iu` (`key=` removes the label, so a reused terminal never keeps the previous account). `hc-resume` (on a `restarted` event, on its own start, after every reconnect and on a `missed` snapshot, since a `restarted` event can fall into a gap) types `env CLAUDE_CONFIG_DIR=… claude --resume <id>` (`env -u CLAUDE_CONFIG_DIR …` when the label is absent, i.e. `iu`) into each kept shell that carries the labels: one attempt at a time per terminal, and only while its foreground is still a login shell. Labels survived a `kill -9` of a kept program and a core restart, and `terminal.list {labels}` filters on them. They live and die with the terminal, so nothing needs pruning (a core doc was the seeded design) |
| `herdr-reap.py` + `com.jkrumm.herdr-reap` | port | same rules over `terminal.list {all}` / `kill` / `rm` / `send` |
| `herdr-events.ts` + `com.jkrumm.herdr-events` | port | `events.subscribe` recorder, same JSONL dir; gap markers from `missed`, from stream EOF (core restart) and from an unparseable line |
| `herdr-groups.py`, `make herdr-groups*` | retire | `jk-spaces` folders; `groups.json` moved to `config/herdr-app/` (Wave 4) |
| `make agent-overview` pane + heartbeat `overview pane` component | **retire** | the app's sidebar status dots and agents list. Agent state comes from the factory's fleet view (software-factory, `factory fleet`), the one producer; `agw agents` is its client (agent-workflows Wave 8) |
| collie + ACL/serve rows | **port** | upstream ColliePWA runs on herdr-core with `COLLIE_MUX=herdr-core` (experimental, core ≥ 0.1.14). Bump `COLLIE_REF`, run it standalone (not a herdr plugin), and keep the `:8787/:8788` rows. If its behavioural check fails on hc, collie retires and the rows go. Shepherdr (`eliasstravik/shepherdr`) is the alternative, not adopted |
| `desk` (`herdr --remote mini`) | replace | the app (MacBook); terminal-only fallback `ssh -t mini hc` |
| `claude-relogin.sh --machine mini` | port | `hc run --on mini` labelled into a `relogin` tab. The mini core is a launchd GUI-session child with the keychain |
| `claude-appearance.sh` / `appearance-sync.sh` | **port** (Wave 4, `scripts/hc-raw-input.ts`) | still needed (fact 6): an unattached terminal gets fixed dark answers, and a running program gets no push on a switch. The push moves from `herdr pane send-text` to raw input over `terminal.attach` (`hc send` always adds Enter). Drop it only when a core release does both: unattached terminals answer from the Mac's appearance, and running programs get `?997` on a switch |
| `brain-note.sh` (prefix+e popup) | port (Wave 4, `jk-keys`, cmd-e) | a small mod: `keys.json` `"<key>": "jk-keys.brain-note"` reaches the mod's `nextCommand()`, which starts the script with `hc run --bg` and shows it with `terminal.peek` (fact 8) |
| `herdr-agent-state.sh` SessionStart hook | retire | Claude reports to the core natively over OSC 7501 (fact 7) |
| `herdr-server-start.py`, `_herdr-supervise`, `lib/herdr-ready.sh`, `herdr-upgrade.sh`, `herdr-wait-quiet.sh`, `herdr-skill-sync.sh`, `make herdr-{setup,upgrade,restart,status,launchd-status,server-start-test}` | retire | `com.jkrumm.herdr-core` + the Wave 8 upgrade target |
| heartbeat herdr component, `doctor.sh`, `brew-upgrade.sh`, `architecture-check` `herdr.*` regex, `log-rotate` collie log, `mini-macos-update` pane snapshot | port | core up (`lib/core-up.sh`) + `hc server status` + responsibility + MacBook/mini version parity; the resume labels are the pre-reboot snapshot |
| `Brewfile` `herdr`, cask `penso/tap/herdr-gpui`, tinycast `so.pen.herdr-gpui` hotkey, `config/herdr/config.toml`, `config-gpui.local.toml` | retire | Herdr.app, bundle id `dev.herdr.app` (its `Info.plist`) |
| agent-workflows `agw agents` collectors (+ argo `herdrStatus`) | **retired** | the factory reads hc and is the one producer of agent state; `agw agents` reads `factory fleet --format json` and adds only recommendations and the Max quota (agent-workflows Wave 8). argo's `herdrStatus` carries hc's word through the factory |
| iris herdr destination (raw `herdr.sock`) | port | `terminal.list` (labels) + `terminal.send` over `hc connect`; the destination value stays `"herdr"` |
| hermes-agent `skills/herdr`, SOUL/AGENTS/config refs | port | hc-world skill text |
| shutterflow `scripts/fleet/*` + PROTOCOL | port | `hc run`/`send`/`ls`/`kill` |
| sy-serendipity AGENTS.md dev-server pane | port | `hc run --bg --name dev …` + `hc wait --output` |
| brain wiki (`wiki/engineering/herdr.md` and live how-to pages) | port | rewrite live pages; dated pages, log and podcasts stay history |
| IuRoot/prometheus-epx eval adapter `SubprocessHerdr` | port, owner pushes | `EP-XX` branch committed locally; the MR to colleagues is the owner's step |
| jkrumm.com published guide, weatherorb/basalt-ui/prometheus-stack plans, archives | history | untouched, listed in the final report |
| comments: ghostty, starship, ssh_config, usage-tracker, modelpick, homelab monitors, linewatch, image-gateway | port | one-line fixes when the file is touched anyway, listed otherwise |

### Spawn contract (HcRunner, `rd`)

- **Always pass `cwd`.** Through the API the default is the core's cwd (`/`).
- **Prompt as argv:** `["claude", …flags, "<prompt>"]`. Claude takes the first prompt as an argument (fact 7).
  `first_message` reports only template runs.
- **Account in `env`:** `CLAUDE_CONFIG_DIR` set, or absent for `iu`. Never an empty string, never inherited.
- **Parent:** a hidden child passes `parent` = the spawner's terminal and no labels. A tab (`rd work`) passes
  `no_parent: true`. The CLI defaults `parent` to the calling terminal, and a child ends with its
  parent's program, so a tab spawned without it would die with the terminal that spawned it.
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

Re-checked in Wave 4 on core 0.1.15 (scratch core): a probe in an unattached `hc run --bg` terminal read
`OSC11 rgb:2828/2c2c/3434`, `OSC10 rgb:ffff/ffff/ffff`, `DSR996 ?997;1n`, so the first half of the retirement test
still fails and the push stays. It now goes in as raw input: `scripts/hc-raw-input.ts` opens `hc connect`, sends `hello
{framed: true}`, attaches with the terminal's own size (no resize, no `display`) and writes the bytes as a type-0 frame
on the attach channel. Frames (read off `hc attach` through a socket proxy; the schema names them without a layout):
`u32le channel | u8 type | u32le length | payload`, channel 0 = JSON-RPC (type 0), types 0 data / 1 credit / 2 close.
No credit frame is needed for input to land. `claude-appearance.sh dark|light|session` uses it for terminals whose status
app or foreground program is claude/opencode.

**7. Events and status.** `hc events --json` lines are JSON-RPC notifications:
`{"method":"event","params":{"seq":N,"terminal":"t5","type":…,"data":…}}`, plus `{"method":"heartbeat","params":{"seq":N}}`
every 15 s. The first line is the snapshot `{"seq":5,"terminals":[…]}`. Shapes seen:

| type | data |
|-|-|
| `created`, `restarted` | the full terminal record |
| `status` | `{"records":{},"reported":true,"status":{"app":"claude-code","state":"working"}}` |
| `turn` | `{"state":"done","turn":1}` (a plain login shell has a `turn` too, and it rises as commands run: on the live core on 2026-11-05 `hc ls` showed unnamed zsh terminals at turn 8 (hermes-agent), 14 (home) and 15 (an IuRoot shell) while fresh ones were at 0; hc-reap's orphaned-shell rule reads it as the activity signal) |
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

Wave 4 proved the mod route in a scratch app (0.1.10, scratch core, app home and `HERDR_APP_HOME`): `herdr-app do jk-keys.brain-note`
(what a `keys.json` `"<key>": "jk-keys.brain-note"` runs) reached the mod's `nextCommand()` as `brain-note`. A `<mod>.<command>`
reaches **shown** copies only, so `jk-keys` sits in `jk.json` as a zero-width block. The mod ran `hc run --bg --json --rm --cwd
<focused terminal cwd> -- bash -c 'exec bash "$HOME/…/brain-note.sh"'` and the peek showed the script. A `terminal.peek` issued
right after `hc run` failed with `no running terminal "t12"` (the window learns of a terminal through the core's events), so the
mod waits until `terminals()` lists the address first. With `--rm`, the terminal and the peek vanish when the script exits.

**9. Spawn facts (Wave 2, scratch cores).** `outlive_parent: true` keeps a child running after its parent's program ends
(the parent killed, the child with the flag stayed live, the one without was killed). `claude --resume <id> "<prompt>"` is
valid, but `--resume` takes an optional value, so an id must always be passed or the prompt is read as the id. A
`doc.set` of a `herdr-app` space+tab entry before any terminal exists is accepted (version 0 → 1, stale version →
`conflict`); whether the app adopts a pre-written tab entry is **not** verified (no app on the mini). The doc's shape is
verified against the live doc (2026-11-01, version 86, read with `doc.get {name: "herdr-app"}` over `hc connect`): the
value is `{spaces: [{id, name, folder, tabs: [{id, name, root}]}]}`. software-factory still reads it defensively and
falls back to a stable `sp-<dir>-<hash>` id. `hc connect` STARTS a core when none runs (a `hello` on a fresh `HC_SESSION` did), so a subscriber must check that launchd's `com.jkrumm.herdr-core` is running before it connects (corrected 2026-10-31; an earlier note said it exits 2). hc refuses
a terminal name that can read as an address (`t7`).

**10. Resume (Wave 3).** `hooks/hc-session-label.ts` labels its own terminal on SessionStart
(`jk.claude.session=<id>`, `jk.claude.config=<CLAUDE_CONFIG_DIR>`, empty for `iu`) and clears the session label on
SessionEnd; it only runs `hc` when `HC_TERMINAL_ID` is set. `scripts/hc-resume.ts` (LaunchAgent `com.jkrumm.hc-resume`,
`make hc-resume-setup`) subscribes over `hc connect` and types `env CLAUDE_CONFIG_DIR='<dir>' claude
--dangerously-skip-permissions --resume <id>` (`env -u CLAUDE_CONFIG_DIR …` without the label) into a terminal whose
foreground is positively a login shell (a `restarted` event, whose record has no foreground fact yet, may use the terminal's own program instead). A subscribed `hc connect` connection answers no requests, so each send is
a `terminal.send` on its own short-lived `hc connect`. Proof in a scratch core (own `HC_SESSION`, scratch `XDG_*`, torn down):

```text
hc run --bg --keep --name standin sh -c '<SessionStart JSON> | CLAUDE_CONFIG_DIR=/tmp/hcs/cfgdir bun hooks/hc-session-label.ts; exec sleep 600'
  → labels {jk.claude.config: /tmp/hcs/cfgdir, jk.claude.session: 0d6f3a52-…}
bun scripts/hc-resume.ts &            → started; snapshot: nothing sent (foreground is sleep)
kill -9 <sleep>                       → lost, restarted (argv /bin/zsh -l)
  hc-resume.log: resume t2 0d6f3a52-… (/tmp/hcs/cfgdir)
  hc read: ❯ env CLAUDE_CONFIG_DIR='/tmp/hcs/cfgdir' claude --dangerously-skip-permissions --resume 0d6f3a52-…
  hc get: foreground argv [claude, --dangerously-skip-permissions, --resume, 0d6f3a52-…]
kill -9 that claude                   → restarted again, no second send (one attempt per terminal + session id)
hc server stop; hc server start       → "stream ended, reconnecting"; the parked second terminal (kept, labelled) had a
                                         shell again: resume t3 1e7a4b63-… typed on the reconnect snapshot
```

SessionEnd clears the label only for `reason` `prompt_input_exit` or `logout` (SIGTERM fires `other`, which must stay
resumable). A `restarted` event resets the per-terminal attempt (a new loss resumes again); snapshots need the foreground
fact; each send re-reads the terminal (`terminal.get`) and skips unless its foreground is still a login shell with the same
session label (an unknown foreground, `null` or absent, is retried by the next snapshot and never typed into; only a
`restarted`-triggered send lets the terminal's own program stand in for an absent key), under a 15 s deadline. `hc connect` would start a core, so hc-resume runs `scripts/lib/core-up.sh` (the socket answers AND a launchd-born core exists) before every connect (skipped when `HC_SESSION` is set): no such core means backoff retries, never an auto-start. Not mirrored on resume:
model/effort flags and the `c` launcher's env (`ENABLE_TOOL_SEARCH`, lane vars). A terminal sitting at a shell prompt
that carries a session label (the claude exited without SessionEnd, e.g. the shell was reused) is resumed too, once.

## Removal

Classic herdr (the `herdr` 0.9 CLI/server, formula `herdr`, cask `penso/tap/herdr-gpui`) was removed in Wave 7 on
2026-10-31, on both machines. Classic Claude sessions were not carried over (no `--resume` into hc). What it had and
what replaced each part, from §Port design:

| Classic had | Replaced by |
|-|-|
| Agents: the server hosting every pane, the `herdr-agent-state.sh` hook, `herdr agent list/wait`, `desk` (`herdr --remote mini`), `resume_agents_on_restore` | `hc` terminals under `com.jkrumm.herdr-core`, Claude's native OSC 7501 reports, `hc wait --children`, the Herdr app on the MacBook (`ssh -t mini hc` without it), `hc-resume` over the `jk.claude.*` labels |
| Jobs: `herdr-reap`, `herdr-events`, the supervised `sh.brew.herdr` boot path (`herdr-server-start.py`), `herdr.collie` | `hc-reap`, `hc-events`, `com.jkrumm.herdr-core` (starter) and `make herdr-core-update`, `com.jkrumm.collie` on herdr-core |
| Files: `~/.config/herdr`, `herdr/`, `config/herdr/config.toml`, the `herdr-*` scripts and `make herdr-*` targets, the heartbeat `herdr` component and its two `doctor.sh` checks, the overview pane, `make herdr-groups` | `config/herdr-app/` (layout, mods, themes, `groups.json`), `make herdr-core-setup` / `herdr-app-setup`, the `core` heartbeat component and `section_core`, the app's sidebar dots and agents list, `jk-spaces` folders |

`~/.config/herdr` was archived to `~/.local/share/herdr-classic-archive/` rather than deleted.

## Upstream state (2026-10-31)

agw research run `01a191f9-802c-75f1-ab6a-b3914a286ec5` (deep, 39/39 citations grounded, 78 pages). It covers
herdr-core #13/#15 (resume: closed / open, unanswered), herdr-app #207 (no auto-update switch, open), #219 (quit kills
an app-started core, open, no fix version), phone clients and the cadence. ColliePWA and Shepherdr name herdr-core
in their docs. Ovis, Nenu and several web UIs are classic-era. Earlier runs: `01a19101` (evaluation),
`01a19165` (ecosystem).

| herdr-core | Date | | herdr-app | Date |
|-|-|-|-|-|
| 0.1.18 (running) | 2026-11-04 | | | |
| 0.1.17 | 2026-11-02 | | | |
| 0.1.16 | 2026-10-31 | | | |
| 0.1.15 | 2026-10-30 | | 0.1.10 (`core_min` 0.1.11) | 2026-10-30 |
| 0.1.14 | 2026-10-29 | | 0.1.9 | 2026-10-30 |
| 0.1.13 | 2026-10-29 | | 0.1.8 | 2026-10-30 |
| 0.1.12 | 2026-10-26 | | 0.1.7 | 2026-10-29 |
| 0.1.11 | 2026-10-26 | | 0.1.6 | 2026-10-29 |
| 0.1.10 | 2026-10-23 | | 0.1.5 | 2026-10-27 |

## How the core runs now

Core 0.1.18 and later is upstream's own app. Everything below follows from that one fact; there is no wrapper, launcher,
pin or nightly updater of ours around it any more (history at the end of this section).

**Install.** The official installer (`curl -fsSL https://releases.herdr.dev/core/install.sh | sh`, `HC_INSTALL_DIR` unset)
puts `Herdr Core.app` (Developer ID team `2W9652Q7QR`, identifier `dev.herdr.core`, notarized and stapled) at the fixed
path `~/.local/share/herdr-core/active/Herdr Core.app` (`~/.local/share/herdr-core/current` is a link to it) and the entry
points `~/.local/bin/herdr-core` and `~/.local/bin/hc` (a link to `herdr-core`) pointing into the bundle. A fresh install
starts no core. `make herdr-core-setup` (both machines, idempotent, safe with agents live) runs the installer only when the
bundle is missing, after removing an entry link that points into this repo or into Homebrew so the installer cannot write
through it. A Homebrew-installed core is "package-managed": `hc update` refuses it and it has no bundle identity. Upstream
has no formula (herdr-core #109).

**Identity.** The core, each holder (`herdr-core hold`) and the programs in terminals are attributed to the holder or the
core itself (every holder re-execs with a responsibility disclaimer since 0.1.17), so macOS judges file access on the
`Herdr Core.app` bundle. The owner grants Full Disk Access once per machine to that path (System Settings, a human step,
`docs/tcc.md` §One-time grants); the grant is keyed on the signing identity and survives updates. Local Network and
microphone prompts appear once on the machine's screen. Upstream still says session-scoped AppData consent on macOS 26 may
prompt anyway, so nothing here promises "never again".

**Starter (mini only).** `com.jkrumm.herdr-core` (`scripts/com.jkrumm.herdr-core.plist.template`) is a starter, not the
core: `RunAtLoad`, never `KeepAlive`, program `Herdr Core.app/Contents/MacOS/herdr-core serve`, `ProcessType Interactive`,
log `~/Library/Logs/herdr-core.log`. `serve` outside ssh detaches into upstream's own one-shot launchd job (the process
shows as `herdr-core --hc-launchd /tmp/hc-launchd-…`, parent pid 1, in the GUI session, so the Claude Max keychain
login is reachable) and the starter exits 0; the detached process is the core. Re-running the starter while a core runs is
harmless (`serve` finds the lock and exits), booting it out does not stop the core, and `make herdr-core-setup`
bootstraps it only when it is not loaded. The environment of the core is the environment of every terminal (`hc run`
forwards nothing): a clean launchd env is why no Claude runs as a non-persisting child session; choose the Claude account
on the command line, never by inheritance. A changed starter applies at the next login.

**MacBook.** No job of ours. The Herdr app starts the core through the same launchd path and links the mini with
`hc machine add mini --name mini` (once; ssh config host `mini`). `herdr-core-setup` there only ensures the bundle and
removes a stale `com.jkrumm.herdr-core` / `-update` LaunchAgent.

**Core up** is defined once, in `scripts/lib/core-up.sh`: the default socket answers (bare `nc -U`, never an `hc` call)
**and** a launchd-born core exists (`ps`: `herdr-core --hc-launchd`, parent pid 1). Used by `lib/core-health.sh`
(heartbeat component `core`, `doctor.sh`), `rd`'s `require_core`, `claude-relogin`, `hc-events`, `hc-resume`, `hc-reap`
and `collie-setup`. Any `hc` call auto-starts a core when none answers, which is why every consumer asks `core_up` first.

**Strays.** A core started by a client (`herdr-core connect` over ssh, upstream herdr-core #12; a `hc` call while no core
runs) answers on the same socket but is attributed to sshd and has no keychain: Claude silently falls back to API
billing. It fails `core_up`'s second clause, so heartbeat and doctor FAIL with the fix (stop it, `hc server stop` keeps
every terminal, then `launchctl kickstart gui/<uid>/com.jkrumm.herdr-core`). Protection is structural: the mini's core is
always started by launchd, the MacBook never starts it, and nothing wraps `~/.local/bin/hc` (the installer and `hc update`
rewrite those links).

**Probes.**
- `make tcc-probe`: a fresh `hc run` terminal lists `~/Documents ~/Desktop ~/Downloads` (MacBook: also the 1Password group
  container), then `scripts/hc-responsible.py` asks `responsibility_get_pid_responsible_for_pid` for the core and every
  holder and exits 1 listing any whose responsible process is not inside `Herdr Core.app` (a Homebrew Cellar herdr-core,
  sshd, a launcher). Terminals born before the cutover keep their old holder until they end, so offenders shrink over time;
  the heartbeat shows them as a WARN.
- `make herdr-core-status`: version, `core_up`, responsibility.
- `make op-tcc-probe` (MacBook): `op` in a Herdr terminal raises no AppData dialog; re-run after every core update.

**Updates.** `make herdr-core-update` runs the official `hc update` (it may ask to be run a second time; the target runs
it again), then verifies `hc --version`, `core_up`, that the terminal count did not change and the responsibility check.
Run it by hand in a quiet window (`hc ls` shows what is live), on each machine. Running terminals keep running, but an
update can end the programs inside them (upstream herdr-core #133): `hc-resume` types `claude --resume <id>` into the
login shells that remain, only where the foreground is positively a login shell. There is no unattended update job: the
Herdr app also updates linked machines' cores, and a second updater would race it. Read the release notes first
(`/upgrade-deps`, Machine mode: herdr-core).

**What breaks it.**
- A wrapper at `~/.local/bin/{hc,herdr-core}` (the installer and `hc update` rewrite those links).
- A Homebrew core (no bundle identity, `hc update` refuses it).
- A core started over ssh or by the MacBook (stray, see above).
- Clicking "Allow" on an AppData dialog as the fix: that consent is session-scoped on macOS 26 and returns.
- A changed signing identifier or team on a future release: re-grant Full Disk Access then, and only then.

**Do not.** Start a core or open the Herdr app from an agent: a core's environment becomes every terminal's and `open` passes the caller's, so one `open -a Herdr` from Claude put `CLAUDE_CODE_CHILD_SESSION` in every terminal ("Transcript saving is off"; `hc-responsible.py` flags it, `make herdr-core-clean-restart` cures it). Put a wrapper script at `~/.local/bin`. Install the core through Homebrew. Start the mini's core over ssh
or from the MacBook (`hc` there when the core is down). Click Allow as a fix. Re-grant unless the signing identity
changes. Run `hc server restart|stop` or `hc update` outside `make herdr-core-update`'s conditions (quiet window,
verification).

State: `~/.local/state/herdr-core/`. Log: `~/Library/Logs/herdr-core.log`.

**Launcher (opbackup only).** `~/.local/libexec/herdr-core-launcher` (`scripts/herdr-core-launcher.c`, built by `make
herdr-core-launcher`, a prerequisite of `opbackup-setup` only) is the Full Disk Access umbrella for LaunchAgent programs
that call `op` (`docs/tcc.md` pattern "Launcher"). It was the core's program until 0.1.17 and still carries that name and
path because the grant is keyed on them; its source still has the old comments, because editing the file changes the hash
the build marker keys on and would trigger a rebuild that loses the grant.

**History.** 0.1.15 (2026-10-31): the design held. A launcher as the job's program, the Homebrew formula's core as its
child, terminals attributed to the launcher (scratch-core evidence: `responsible_path` was the launcher), one Full Disk
Access grant that survived core swaps. 0.1.17 (2026-11-02): every holder re-execs with a responsibility disclaimer, so
terminal programs take their holder's identity and the launcher's grant never covered them (the cause of the endless
"herdr-core möchte auf Daten aus anderen Apps zugreifen" dialogs), and a macOS `serve` detaches into its own one-shot
launchd job (incident 2026-11-04: the KeepAlive job looped `spawn scheduled`, `runs` in the thousands, while an orphan core
answered; worked around with a launcher env variable, a lock-reclaiming launcher, a client guard and a version-pinned
nightly updater). 0.1.18 (2026-11-04): the core ships its own identity, `Herdr Core.app`, the official installer and
`hc update`; the workaround stack was deleted.

## Desktop layout (MacBook)

`make herdr-app-setup` converges the app onto `config/herdr-app/`. It's idempotent, and needs the window open to switch the layout and open spaces. It ends by switching layouts away and back, the only reload that picks up edits inside a symlinked mod folder.

| Piece | Source | Lands as |
|-|-|-|
| `jk` layout: the shipped `main` with `jk-spaces` instead of spaces + agents, `jk-tabs` as the tab bar, `jk-pane` as the pane header, `jk-status` as the bar, `jk-board` as a right column (`board`, 320 px, resizable, `cmd-shift-b` toggles it), theme `one-zinc-{light,dark}` following the system | `config/herdr-app/layouts/jk.json` | symlink |
| `jk-spaces`: Herdr's `spaces` mod (Apache-2.0) plus folders. Folders come from **`config/herdr-app/groups.json`**, the taxonomy classic herdr's sidebar used. A space joins the group naming its repo (worktrees follow their repo), the rest go to the fallback (`OTHER`). Folders fold (state in the app), a folded folder shows ● when a space in it needs you. A row is a status dot plus the name: filled while an agent works, is blocked or just finished, a dim ring while its agents are all idle; hovering the dot names the state. Mini spaces take their status from the mini core's terminals, most urgent wins: no letter avatar, no folder colors, no git tail, compact rows, this computer labelled `MacBook` | `config/herdr-app/mods/jk-spaces/` | symlink |
| `jk-status`: CPU % and memory used (active + wired + compressed; whole numbers in fixed-width cells) for this computer and every connected machine, every 5 s via `exec … { on }`. Claude usage per account (`5h/7d %`, uncolored by quota, then `∑<pool>%`: the statusline's plan-weighted 7-day use across accounts, also in the usage popup's header; dim when the sample is > 3 h old, `login` when auth failed), every 60 s from `claude-account usage --json`, which reads its local quota cache only (the MacBook's includes the mini's samples). Bottom right: Uptime Kuma `▲up ▼down` over every active monitor (down count red, the down names on hover), every 60 s from Argo's `/uptime-kuma/monitors` (read on the mini with `secrets-run`, groups and paused monitors excluded), a click switches the board to its Uptime tab | `config/herdr-app/mods/jk-status/` | symlink |
| `jk-board`: the right column, two tabs (a segmented row on top, the choice persists; the Uptime tab shows a red down count; a stored or shared `waves` reads as `issues`). **Issues** (default), a read-only view of software-factory's read API (`docs/design.md` §"The read API"). Every 15 s, one `exec … { on: "mini" }` runs `factory --format json read overview`, `read issues --state all --limit 40` and `read sessions --live` in one `secrets-run` with the factory's `.env.tpl` (the token never reaches argv), plus `hc ls --json` for the child tree. Each part parses on its own and keeps its last good answer; the view dims after 2 min without a good poll (or when `builtAt` is that old). Unknown enum values read as `other`, all text is data. Top to bottom: a summary line (`3 working · 1 waiting · 6 queued · queue: run`); **ASKS** (the owner's first, then by time; the `short`, repo else source, age; hover has the summary, text and suggestion; a click jumps to the ask's session, or for a `decision:<issue>:…` ask to that Issue's lead); **HUMAN QUEUE** (the open items, stale ones dim behind a folded `older (n)` row, no jump, hidden when empty); **HEALTH** (the `short`, repo else kind, age; a click jumps via `session`, else the `issue`'s lead); **RUNNING** (open Issues with a live lead or an active state: needs you, then working, waiting, idle, then recent activity); **QUEUED** and **RECENT** (the last 8 closed), both folded by default; **SESSIONS** (live sessions that belong to no Issue). The tab badge is the asks plus the open human queue (blocked tone when one ask is the owner's); health never counts. An Issue card: status dot (needs you when the owner is waited on, or the reason is decision, blocked or wall, or the lead is blocked, stuck or `wait=owner`; else the lead's state; queued and closed are a dim ring), the human title, the working time; `repo · phase · account`; the summary on one line. The Issue that owns the focused terminal has the selected background. A click expands it (remembered): the filed title, the full summary, a facts line (`feature · l · sonnet · 20 turns · 112 tools · 10 subagents · 61k out`), the account's quota, its sessions with the hidden children under the lead's terminal as a tree (hc's `parent`; click a child for its last lines, `hc read` on demand), the last 5 timeline lines (`read issue <id>`, only while open) and a `Jump to agent` row. A queued card is title and repo plus the queue's hold reason. After each good sessions answer the board publishes `shared("jk.factory.terminals")` (app terminal address `mini/<id>` to issue, title, short, summary, phase, role, state, repo; only when it changed) for `jk-pane`. Colour: `theme()` tokens only, `working` and `blocked` the only hues. No actions. **Uptime**, an Uptime Kuma overview from Argo's `/uptime-kuma/monitors` (one `exec … { on: "mini" }`, token read by `secrets-run` and piped to curl, never in argv): summary line, an always-open `DOWN` section (down and pending, with the latest message), then collapsible groups by `parent` (nested ones as `Parent / Child`; folded unless something is down, remembered; flat list when Argo sends no `parent`) with ping and 24 h uptime per row. Every 30 s while the tab shows, 60 s otherwise (for the badge); last good data stays and dims after 2 min or when Argo isn't `ready`. `make herdr-app-setup` also binds `cmd-shift-b` → `layout.toggle:board` in the app's `keys.json` (merged with jq, replacing only the old `layout.toggle:waves`, never another binding) and drops the stale `jk-waves` link | `config/herdr-app/mods/jk-board/` | symlink |
| `jk-details`: the popup behind a click (it opens with its bottom edge 10 px above the clicked field, centered on it; the card measures itself, remembers its height per kind and re-places itself once when the guess was off, so a growing or shrinking content always sits right) on a machine (15-min CPU and memory history plus the top 10 processes on that machine, live) or on the usage (each account's plan as Anthropic now names it: Max 5x = Max, Max 20x = Ultra since 2026-10-30; 5-hour and 7-day % with reset countdown and clock time; a note only when the data is over 3 h old or the login expired). The process table has a fixed height, so the popup doesn't jump when it loads | `config/herdr-app/mods/jk-details/` | symlink |
| Claude problems: `jk-status` reads **`claude-account health --json`** every 5 min: login, quota and pending-ask health of both machines (the peer read through its core, ssh as fallback; an unreadable login is a warn), each problem with its fix command. It's the same source Tinycast reads; the app implements no quota or expiry logic of its own. Any row that isn't ok adds a `⚠ <id>·<machine>` chip (amber warn, red fail). The usage popup lists them under their account, with a **Re-login** button that runs the row's `fix` detached, only when it is exactly `claude-relogin <id> --machine macbook\|mini` (§Re-login in `docs/claude-accounts.md`) | `jk-status`, `jk-details` | — |
| `jk-tabs` + `jk-new`: clones of the shipped `tabs` and `new-menu` (0.1.11; `mod.clone`). The only change in `jk-tabs` is that + opens `jk-new`; `jk-new` lists only the four Claude launchers from `config/herdr-app/programs.json` (`c` Opus medium, `ch` Opus high, `cs` Sonnet high, `cf` Fable medium), in that order. Each entry runs `zsh -ic <launcher>`, so the installed check also passes on the mini, where remote checks find executables only and not shell functions. `programs.json` can add entries but cannot hide the built-in agents (a `null` run is rejected, an empty one is ignored), hence the clone. Re-clone after an app release changes either shipped mod | `config/herdr-app/mods/jk-{tabs,new}/`, `config/herdr-app/programs.json` | symlink |
| `jk-pane`: a clone of the shipped `pane` header (0.1.11), set in `layouts/jk.json` (`pane.header.content.mod`). In a terminal that `jk-board` published under `shared("jk.factory.terminals")` (key `mini/<terminal id>`, what a mini terminal's `PaneInfo.terminal` reads at runtime) the header says what that agent is about: icon, `#<issue>` (a non-lead adds its role, a session without an Issue shows only the role), the Issue's title, its phase, its summary; program name and folder are hidden. The tooltip has title, summary, repo, role and folder. Without an entry it is the shipped header, one line at 30 px | `config/herdr-app/mods/jk-pane/` | symlink |
| `jk-keys`: headless key commands, no UI. `jk-keys.brain-note` (bound to `cmd-e`) runs `scripts/brain-note.sh` for the focused terminal's repo as a peek over the tab (`hc run --bg --rm`, then `terminal.peek`; a terminal on another machine starts it there). It sits in `jk.json` as a zero-width block because `<mod>.<command>` reaches shown copies only. `scripts/herdr-app-keys.sh` binds the key in `keys.json` (jq merge: only our binding, an owner's binding on the same key wins) | `config/herdr-app/mods/jk-keys/` | symlink |
| Themes `one-zinc-*`: the terminal palette (`docs/theme.md`) plus a `colors` map for the chrome taken from basalt-ui's semantic tokens (background, card, sidebar, border, accent: the oklch values converted to hex), so sidebar, bars and popups read as basalt-ui rather than derived darker. `basalt-ui-*` is the Blueprint palette, converted from `config/ghostty/themes/` | `config/herdr-app/themes/` | symlink, pickable in Settings |
| Spaces shutterflow, ShutterflowOps, tinycast-extensions, finances, dotfiles | `SPACES` in `scripts/herdr-app-setup.sh` | `herdr-app do space.new`, skipped when one already works in that folder |
| Mini spaces: one per repo the mini core's terminals sit in (label resolved to `~/SourceRoot/<name>` or `~/IuRoot/<name>`), filed into the same folders | the mini core's terminal cwds | `space.new --machine mini`, skipped when already open. Spaces only, no agents |

A new repo gets its folder through one line in `groups.json`. Revert to stock with `herdr-app do layout.switch --name main`. The theme picker in Settings overrides the layout's theme.

## Ecosystem notes (2026-10-31)

A snapshot from agw research run `01a19165` (deep, partial: 22/34 citations grounded, so treat repo names and star counts as leads). The scene is days old: about 68 `herdr-mod` and 36 `herdr-layout` repos, mostly one to five commits.

| Pattern | Seen in | Status here |
|-|-|-|
| Folders over spaces | jankeesvw/herdr-space-folders (unlicensed), ejklock/herdr-workspaces | Done our way in `jk-spaces`, from `groups.json` |
| One status bar with machine load and plan usage | DanielFGray/herdr-config, berkeatac/herdr-usage-bar, kvkenyon/herdr-quota | Done in `jk-status`. Ours reads `claude-account`'s cache; theirs read the keychain and call the API |
| Click-through detail popup | DanielFGray (same mod, `props.panel`) | Done in `jk-details` (a separate mod). None of the public mods shows top processes |
| Agents visible, helpers hidden | Workers as unlabelled children (fact 2) | A visible agent is a tab; a hidden child has none and shows nowhere in the app (the jk layout replaces the agents mod). Children are visible through `rd agents` / `hc ls --json` (`parent`, `hidden_finished`), and `jk-board` shows each Issue's sessions from the factory's read API, lists children as a tree under their parent's row (hc's `parent`; name, state, and the turn from one `hc ls --json` per poll) and reads a child's last lines on click (`hc read` on the mini; the app's own `terminal.peek` is an overlay that returns no text and needs the app's address for a mini terminal, unverified) |
| Light chrome as a design, not a palette | ritiksahni/herdr-linen | Basalt tokens in the theme `colors` |
| Import classic workspaces into the app | CiprianSpiridon/herdr-migration (claims conversation resume; **unverified**) | Not used: classic sessions are not carried over |
| Resume after a reboot | herdr-agent-resume stopgap in herdr-core #13 (SessionStart hook → labels, a key types `claude --resume`) | Same idea as ours, triggered by events instead of a key |
| Phone client on herdr-core | ColliePWA (`COLLIE_MUX=herdr-core`), Shepherdr | Collie ports (§Port design) |

The official `herdrdev/herdr-layout-examples` (board, call, chat, code, mission, pasture, threads, tmux-prefix) is the best API tour; several of its controls are decorative. App telemetry is on by default; `HERDR_TELEMETRY=0` or `DO_NOT_TRACK=1` turns it off (`~/.config/herdr-app/AGENTS.md`).
