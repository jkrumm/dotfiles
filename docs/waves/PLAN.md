# Retire classic herdr: everything on herdr-core + the Herdr app

**Goal:** classic herdr is gone from both machines and from every live file an agent could follow. Each consumer
is ported to the herdr-core API (`hc schema`, `hc events`, core docs) or to `herdr-app do …`, replaced by a native
hc feature, or retired with the reason in its commit. One global `herdr` skill describes the hc world. Core
updates follow a cooldown and never need idle agents; the app auto-updates (no off switch, herdr-app #207) and
never touches the pinned core. The mini maintenance window has run.
**Gate (every wave):** `make check` green (the pre-existing reds are listed in the wave's Left behind, never new
ones); `/review` on every non-trivial diff, with findings fixed; one commit per concern; every other repo's own gate
and conventions apply (PR-required list: `config/pr-required-repos.json`; IuRoot: `EP-XX` branches, MR to `main`).
The plan is pushed before a wave spawns the next one.
Baseline 2026-10-31 (MacBook): `make -k check` is red only on `architecture-check` (`com.jkrumm.photoflow`, MacBook
only, fixed in Wave 9). It took 40 min of wall time at 5 % CPU, so a suite sleeps or waits on the network
(`fan-test` was running when a 10-min timeout hit). Run it in the background with a log.
Mini 2026-10-31 (Wave 1, each suite timed alone): all 17 green in ~6.5 min; the slow ones are `fan-test` (156 s) and
`claude-launcher-test` (121 s), then `herdr-reap-test` (55 s). The MacBook's 40 min was not reproduced (it was offline).

Handover and context: `docs/herdr-core.md`, `hc --skill`, `herdr-app --skill`, `~/.config/herdr-app/AGENTS.md` +
its `.d.ts` files, `hc schema`. The binaries' own manuals are version-current; trust them over memory and over
this file. Chain mode. A wave that cannot finish writes `stopped: <reason>` into its Left behind and stops.

## Ground rules for every wave

- **Never start a core except through launchd. Never stop or restart the owner's app.** The only core restart is
  `launchctl kickstart -k gui/$(id -u)/com.jkrumm.herdr-core`. Never use `hc update`, `hc server restart|stop` or
  `hc machine update`. Any `hc` call auto-starts a core when none runs, so check `launchctl print` first.
- **A core's env is every terminal's env.** `hc run` (the CLI) forwards nothing. `terminal.run` in the API takes
  `env`. Choose the account on the command or in `env` (`CLAUDE_CONFIG_DIR`; unset means `iu`), never by
  inheritance.
- **Experiments run in a scratch core:** their own `HC_SESSION`, scratch `XDG_*` paths and a scratch
  `HERDR_APP_HOME`, torn down afterwards. Never experiment in the owner's core or window.
- **Lane policy holds** (`docs/agent-platform.md`): only `@implementer` and `rd wave` start agents.
- **Other repos:** work in a worktree from fetched origin, never in a checkout another agent or the owner is
  committing in. Check `rd agents` or `hc ls` for a working agent in that repo first.
- **`AGENTS.md` must end under 40k chars.** It is 42.1k on 2026-10-31. Every wave that touches it leaves it no
  larger, and Wave 6 brings it under the limit.

## Port map

Decided in Wave 1: `docs/herdr-core.md` §Port design (every consumer's fate and replacement, and the spawn contract),
resting on §Verified facts. That page is the contract for Waves 2–9. The seeded table that was here is in git history
(`b387732`).

## Wave 1 — Facts and port design            <!-- status: done -->
Role `lead`. Design and verification only: no consumer code. The MacBook is reachable from the mini as `ssh iumac`
(the app and its `herdr-app` socket live there).

- [x] **Verify the open facts in a scratch core** (and a scratch `HERDR_APP_HOME` window on the MacBook where a
  window is needed), each with the command and output recorded in `docs/herdr-core.md`:
  (1) a terminal labelled `herdr.space=<existing id>` without `herdr.tab` gets a new tab, and what names it; a
  label with an unknown space id: ignored, adopted or a new space? How to create a space with no window open
  (is writing the `herdr-app` core doc supported, or only `herdr-app do space.new`?);
  (2) `terminal.run` `env` reaches the program (`CLAUDE_CONFIG_DIR`), and `parent` + no labels keeps a worker
  hidden while `hc wait --children` sees it;
  (3) quitting a second app instance leaves the launchd core and its terminals running (herdr-app #219);
  (4) how the app decides `core.managed` / `installed_by` (exe path under `/Cellar/`, `/mise/installs/`,
  `/nix/store/`?), and that `hc update` and `app.update_core` then refuse;
  (5) on the mini, does an agent in a core terminal that opens `~/Documents` freeze on a TCC prompt? If so,
  which path needs Full Disk Access (queue the grant with `ask-human`);
  (6) does the app (and a bare core with no window) answer OSC 10/11 and DEC 2031 for a terminal, so the
  appearance push can retire;
  (7) `hc events` field shapes for status/turn/restarted/lost/doc, and the `missed` gap recovery;
  (8) can `keys.json` bind a key to a command (brain-note popup).
- [x] **`/research` upstream state** (herdr-core and herdr-app repos, changelogs, issues, as of today): the
  OSC 7501 resume descriptor (#13/#15), the app auto-update off switch (#207), #219, a phone/web client or
  bridge that could replace collie, and the release cadence. Cite run ids in `docs/herdr-core.md`.
- [x] **Decide every port-map row** above: confirm or correct the fate and the replacement, settle the three
  `decide (W1)` rows, and write the result as `docs/herdr-core.md` §Port design. Rewrite the page from
  "evaluation" to "the design we run" and keep the facts sections.
- [x] **Reconcile the plan:** edit Waves 2–9 of this file to match the decisions (steps, owners, order). Record
  the classic agents still `working` on both machines (`herdr agent list`).
**Left behind:**
- Facts 1–8 verified and written up in `docs/herdr-core.md` §Verified facts; §Port design settles every row
  (overview **retire**, collie **port** to `COLLIE_MUX=herdr-core`, appearance **port**: the core answers fixed dark
  when no viewer is attached and never pushes `?997`). Research run `01a191f9-802c-75f1-ab6a-b3914a286ec5`.
- Design changes against the seeded map: resume uses **labels** on the terminal (`jk.claude.session`,
  `jk.claude.config`), not a core doc; a core restart is the event stream's EOF (`restarted` is per terminal);
  tabs and next waves need `no_parent` (the CLI defaults `parent` to the caller and children die with it); prompts go
  in argv (`first_message` is template-only); every API spawn passes `cwd` (default `/`).
- The MacBook was offline the whole wave (Tailscale "last seen", ssh :2222 timed out). App facts ran in a scratch
  Herdr.app on the mini's screen instead. Not done there: its classic `herdr agent list` (Wave 7's gate covers it).
  Mini: 22 classic agents, 1 `working` (this wave, `dotfiles-w1`), 12 idle, 9 done.
- FDA for `~/.local/bin/herdr-core` on the mini is queued (`ask-human` `20261031T135442-12744`, MacBook unreachable,
  so it waits in the queue). The TCC probe may have left consent dialogs for a deleted `/private/tmp/hcw1/…/herdr-core`
  on the mini's screen; the ask says to dismiss them.
- The MacBook core sits at `~/.local/bin` (unmanaged), so the app's auto-update can bump it ahead of the mini's
  until Wave 8.
- Gate: `make check` green on the mini (timings above); AGENTS.md untouched (42.1k).

## Wave 2 — software-factory on hc            <!-- status: active -->
Role `lead`. Repo `~/SourceRoot/software-factory`, in a worktree (its program lead commits on master): read its
`AGENTS.md`, `docs/design.md` and `docs/decisions.md` first. Its runner, witness and FL6 space rules are the
contract to keep.

- [ ] Write `HcRunner` behind the existing runner interface, over the API (`hc connect` JSON-RPC, not the CLI:
  the CLI has no `env`), following `docs/herdr-core.md` §Spawn contract: `cwd` always, the prompt in argv,
  `env` (`FACTORY_SESSION`, `FACTORY_ROLE`, `CLAUDE_CONFIG_DIR` or absent for `iu`), `keep`. A tab gets labels
  `herdr.space` (the `herdr-app` doc entry by folder, else `sp-<repo>-<hash of the full root>`) + a chosen `herdr.tab` id and
  `no_parent`, and is named through a compare-and-set `doc.set`. A worker gets `parent` = the spawning terminal
  and no labels. Notes go through `terminal.send` and respect `blocked`.
- [ ] Witness on `events.subscribe` (shapes: §Verified facts 7): status, turn, lost/restarted per terminal,
  `missed` → rebuild from its snapshot, stream EOF → core restart (reconnect, compare `server.status` pid). Schema fields are
  renamed or aliased (`herdr_status` → a runner-neutral name) with a migration and contract bump. The hook's
  `HERDR_PANE_ID`/`HERDR_TAB_ID` become `HC_TERMINAL_ID` plus labels.
- [ ] A fake hc for the tests replaces `fake-herdr.ts`. Delete `HerdrRunner` once `HcRunner` is green: no
  dual-runner flag remains. Roll out only when `factory status` shows no live session on the classic runner
  (they lose their witness otherwise); else write `stopped: <sessions>` and stop.
- [ ] Roll it out with software-factory's own release procedure (`~/.software-factory/releases/<sha>`, the
  LaunchAgent). Then prove it: one throwaway spawn lands as a named tab in the right space on the mini core and
  shows up in the app on the MacBook.

## Wave 3 — rd, waves and resume on hc            <!-- status: pending -->
Role `lead`. dotfiles.

- [ ] `scripts/remote-dev.sh`: every subcommand on hc (§Port design), the classic paths deleted, `factory`
  first and hc-direct as the fallback, same spawn contract as `HcRunner`. `read`/`say`/`close` keep a
  classic fallback for targets hc doesn't know, and `agents` lists both rosters, until Wave 7. `fan` workers are hidden children of
  the orchestrator; `wave` tabs (the chain's next wave included) are `no_parent`. Update the
  `remote-dev-*.test.sh` stubs to a fake `hc`.
- [ ] Resume: a SessionStart hook labels its own terminal (`hc label "$HC_TERMINAL_ID" jk.claude.session=<id>
  jk.claude.config=<dir>`, `jk.claude.config=` for `iu`), and `scripts/hc-resume` restores Claude sessions under
  the right account into kept shells (at login, on a `restarted` event, after a reconnect or `missed` snapshot;
  one attempt per terminal, only into a login shell). Tests cover an account change on a reused terminal and
  overlapping triggers. Wire the hook in
  `config/settings.template.json`, write tests, and prove it with a scratch-core kill/restart.
- [ ] `skills/wave` (factory spawns keep `factory session wait --on workers`, since a held spawn has no hc
  terminal yet; hc-direct waits on the notes hc types into the parent plus `hc wait --children`), `skills/implement`,
  `docs/agent-platform.md`, `docs/remote-dev.md` §rd: hc semantics.
- [ ] Spawn Wave 4 through the new `rd wave`. That is the end-to-end proof that an orchestrator tab lands in the
  dotfiles space on the mini core.

## Wave 4 — the side consumers            <!-- status: pending -->
Role `wave`.

- [ ] dotfiles: reap and events recorder ported (new plists `com.jkrumm.hc-{reap,events}`; the classic
  `herdr-reap` keeps running beside them until Wave 7), with tests.
  `herdr-groups` retires (`groups.json` → `config/herdr-app/`); `make agent-overview` and the heartbeat's
  overview component retire. Port `claude-relogin` to `hc run --on mini`; `herdr-app-setup.sh` stops reading
  `herdr workspace list`. The `herdr-agent-state.sh` hook stays until Wave 7 (classic agents need it).
- [ ] Collie: `make collie-upgrade` to a ref with `COLLIE_MUX=herdr-core`, run standalone under its own
  LaunchAgent (no herdr plugin), keep the ACL/serve rows. If its behavioural check fails on hc, retire it and
  hand the row removal to Wave 5.
- [ ] Appearance: the push retires only if the current core does both (unattached terminals answer from the
  Mac's appearance, running programs get `?997` on a switch); else move it to raw input over
  `terminal.attach` (`hc send` adds Enter). Brain-note: a `jk-keys` mod whose command
  runs the script with `hc run --bg` and shows it with `terminal.peek`, bound in `keys.json` (MacBook).
- [ ] dotfiles health: heartbeat herdr component → core component (+ version parity),
  `doctor.sh`, `brew-upgrade.sh`, `architecture-check.sh`, `log-rotate.sh`, `mini-macos-update.sh`, and the
  `docs/architecture.md` rows.
- [ ] agent-workflows `agw agents` collectors on hc (+ fixtures, README), and argo's `herdrStatus` follows.
- [ ] Each repo: its gate, `/review`, commit, push.

## Wave 5 — the other repos            <!-- status: pending -->
Role `wave`. One worktree per repo; `rd fan` where the repos are independent.

- [ ] iris: the `herdr` destination adapter on hc (raw socket → `hc connect`); `/herd` lists labelled
  terminals; the e2e passes.
- [ ] hermes-agent skill + SOUL/AGENTS/config; shutterflow `scripts/fleet` + PROTOCOL; sy-serendipity
  AGENTS.md; brain live wiki pages (`brain/voice.md` applies); dotfiles-private collie rows only if Wave 4
  retired collie (ACL and serve rows, applied from the MacBook with `make tailscale-acl-diff` first).
- [ ] IuRoot/prometheus-epx: the port on an `EP-XX` branch, committed locally, not pushed. Name the branch and
  the open MR step in Left behind for the owner.
- [ ] The one-line comment fixes from the port map. List every remaining hit as history.

## Wave 6 — the `herdr` skill and the docs            <!-- status: pending -->
Role `wave`.

- [ ] Write the new global `skills/herdr/SKILL.md` (replaces the classic `herdr` skill and `herdr-core`;
  delete `skills/herdr-core`, `make setup` re-links). Its rules:
  - **One space per project.** Work happens in tabs inside it. A new space only for genuinely separate work,
    such as a long-lived worktree, named so `groups.json` files it. The sidebar stays clean.
  - **Orchestrator visible, workers hidden.**
  - **Lane policy.**
  - **Account on the command.**
  - **launchd owns the core.**
  - **Full API coverage**, each verified against the binaries: run/read/send/wait/attach/kill, machines,
    templates, labels, events, docs, and placing a terminal in a given space and tab.

  Point to `hc --skill` and `herdr-app --skill` for the version-current detail rather than copying it.
- [ ] `AGENTS.md` (every classic section rewritten, **under 40k**), `config/global.CLAUDE.md`,
  `docs/{remote-dev,architecture,agent-platform,collie,global-reference,claude-accounts,hooks,homebrew,devhost-health,theme,macbook,opencode}.md`,
  `skills/{remote-dev,upgrade-deps}`. Retired features get one line with the reason, never a dangling
  reference.
- [ ] `git grep -n -i 'herdr ' -- ':!docs/archive' ':!docs/waves/archive'` hits only hc-world text, the Herdr
  product name or the history list.

## Wave 7 — remove classic herdr            <!-- status: pending -->
Role `wave`. Gate first: `herdr agent list` on both machines shows nothing `working`. Otherwise write
`stopped: <who is working>` and stop. Never stop someone's work.

- [ ] Inventory both machines' classic state (agents, workspaces, plists, `~/.config/herdr`, the brew service)
  into Left behind. The classic Claude sessions are not carried over (owner, 2026-10-31): no migration and no
  `--resume` into hc. Then: `brew services stop herdr`, `brew uninstall herdr`, `brew uninstall --cask
  herdr-gpui`, `brew untap penso/tap` (if nothing else needs it); boot out and delete the `herdr-reap`,
  `herdr-events` and `herdr.collie` plists; archive `~/.config/herdr` to `~/.local/share/herdr-classic-archive/`.
  Both machines.
- [ ] Repo: delete `herdr/`, the classic scripts (and `rd`'s classic fallbacks), `config/herdr/config.toml`, the
  Makefile targets, the Brewfile lines and the settings-template hook (`herdr-agent-state.sh`). `make setup` + `make doctor` on both machines are green.
- [ ] `make check`, `/review`, and one commit per concern, each naming what was retired and why.

## Wave 8 — updates with a cooldown            <!-- status: pending -->
Role `wave`.

- [ ] Pin the core as a managed install, so the app's auto-update never replaces it: a formula in
  `jkrumm/tap` (hc + herdr-core from `releases.herdr.dev`, sha256 pinned, Brewfile entry). A `/Cellar/` path
  makes the core report `installed_by: homebrew`, the app stop offering updates and `hc update` refuse (fact 4).
  The LaunchAgent runs the pinned binary (the stable `opt` link, resolved under `/Cellar/`) on both machines;
  `~/.local/bin/{hc,herdr-core}` go away.
- [ ] FDA (fact 5): the grant is keyed to the ad-hoc build, so every core upgrade loses it on the mini. The
  upgrade target queues the re-grant with `ask-human` (the new resolved path) and reports the mini upgrade as
  incomplete until the grant is confirmed; it never probes a protected folder from the core (the probe itself
  raises a dialog nobody sees).
- [ ] `make herdr-core-upgrade`: only a release ≥ 3 days old. The manifests carry no date: take the HTTP
  `Last-Modified` of `core/<v>/manifest.json` (or the GitHub tag date), in the spirit of `config/bunfig.toml`'s
  `minimumReleaseAge`. It bumps the pin, upgrades both machines, kickstarts each core and asserts terminals
  survived and versions match. No idle-gating. `make herdr-core-upgrade-dry` previews.
- [ ] App auto-update: no off switch exists (herdr-app #207, open), so accept it (the window only updates, and
  the managed core stays pinned). The heartbeat flags a core version the pin doesn't own and an app whose
  `core_min` (`app/latest.json`) is above the pin.
- [ ] Fold it into `skills/upgrade-deps` machine mode and `docs/homebrew.md`.

## Wave 9 — the mini maintenance window            <!-- status: pending -->
Role `wave`. Memory note `mini-maintenance-window.md`; the classic herdr upgrade step is moot (delete it from the
note).

- [ ] `make brew-upgrade` (mini, then MacBook); Colima 12 → 6 GiB (Makefile default + AGENTS.md line,
  `make colima-restart`); teamchat 6 → 3 GiB in IuRoot `chat` (work repo: a branch, the owner opens the MR).
- [ ] The heartbeat WARNs: read the logs and fix the cause of `disk-sweep`, `drift-check` and `vps-pg-backup`;
  `make claude-accounts-verify`; me2's stale quota sample. Fix photoflow's architecture-map entry.
- [ ] `make mini-macos-update` on 26.x (**never 27**), last, after the close-out commit, from the MacBook
  (`ask-human` push, it reboots the mini). After the reboot: cores up, `hc-resume` restored the sessions,
  `make doctor` green on both machines.
- [ ] Final report into Left behind: everything ported, retired or deferred (one line each), anything still
  classic, and the verified state of both machines. Update the memory note.
