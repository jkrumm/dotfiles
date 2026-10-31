# Retire classic herdr: everything on herdr-core + the Herdr app

**Goal:** classic herdr is gone from both machines and from every live file an agent could follow. Each consumer
is ported to the herdr-core API (`hc schema`, `hc events`, core docs) or to `herdr-app do …`, replaced by a native
hc feature, or retired with the reason in its commit. One global `herdr` skill describes the hc world. Core and
app updates follow a cooldown and never need idle agents. The mini maintenance window has run.
**Gate (every wave):** `make check` green (the pre-existing reds are listed in the wave's Left behind, never new
ones); `/review` on every non-trivial diff, with findings fixed; one commit per concern; every other repo's own gate
and conventions apply (PR-required list: `config/pr-required-repos.json`; IuRoot: `EP-XX` branches, MR to `main`).
The plan is pushed before a wave spawns the next one.
Baseline 2026-10-31 (MacBook): `make -k check` is red only on `architecture-check` (`com.jkrumm.photoflow`, MacBook
only, fixed in Wave 9). It took 40 min of wall time at 5 % CPU, so a suite sleeps or waits on the network
(`fan-test` was running when a 10-min timeout hit). Run it in the background with a log; Wave 1 names the slow suite.

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

## Port map (seeded 2026-10-31, Wave 1 confirms or corrects every row)

| Classic consumer | Fate | hc-world replacement |
|-|-|-|
| software-factory `HerdrRunner` + witness (spawn, prompt, status, restart-resume) | port | `HcRunner` over the API (`hc connect`): `terminal.run` with `env`, `labels`, `parent`, `keep`; `terminal.send`/`wait`; witness on `events.subscribe` (snapshot + `missed` gap recovery) instead of a 60 s `agent list` poll; restart detected from `restarted`/`lost` events, not `ps` |
| `rd work|wave|fan|close|read|say|agents` | port | factory first, hc direct as fallback. Project space found by folder in the core doc `herdr-app` (the app's space tree, per machine); tab = label `herdr.space=<id>` (the app makes the tab), named; `--keep`. `read` → `hc read`, `say` → `hc send` (refuses on `blocked`), `close` → `hc kill` + `hc rm` |
| Waves: orchestrator tab, workers | port | orchestrator = visible tab; workers = unlabeled children (`parent` = orchestrator, hidden by the app), `hc wait --children all\|any` replaces `factory session wait --on workers` / `herdr agent wait` |
| `resume_agents_on_restore` | replace | a Claude SessionStart hook records `{terminal, session_id, CLAUDE_CONFIG_DIR, cwd, space, tab, name}` in a core doc per terminal (`doc.set`); `hc-resume` (on `restarted`/at login) types `env CLAUDE_CONFIG_DIR=… claude --resume <id>` into each kept shell; `claude-account latest <cwd>` as fallback |
| `herdr-reap.py` + `com.jkrumm.herdr-reap` | port | same rules over `hc ls --all` / `hc kill` / `hc rm` / `hc send` |
| `herdr-events.ts` + `com.jkrumm.herdr-events` | port | `hc events --json` recorder, same JSONL dir and gap markers (from hc's `missed`) |
| `herdr-groups.py`, `make herdr-groups*` | retire | `jk-spaces` folders from `config/herdr/groups.json` (keep the file, move it to `config/herdr-app/`) |
| `make agent-overview` watch pane + heartbeat component | decide (W1) | app sidebar status dots; `agw agents` stays the JSON producer (ported to hc) |
| collie (classic plugin, phone surface) + ACL/serve rows | decide (W1) | no hc equivalent known; candidate: `ssh mini -t hc attach` from a phone ssh client. Retiring collie removes `:8787/:8788` grants in dotfiles-private |
| `desk` (`herdr --remote mini`) | replace | the app (MacBook); terminal-only fallback `ssh -t mini hc` (picker) |
| `claude-relogin.sh --machine mini` (classic workspace = GUI-session child) | port | `hc run --on mini` with labels into a `relogin` tab: the mini core is a launchd GUI-session child with the keychain |
| `claude-appearance.sh` / `appearance-sync.sh` (OSC 10/11 + `?997` push into panes) | decide (W1) | probably retire: the app's libghostty engine may answer OSC 10/11 and DEC 2031 itself. Verify with and without an attached window |
| `brain-note.sh` (prefix+e popup) | port or retire | app key binding running a command, if `keys.json` supports one |
| `herdr-agent-state.sh` SessionStart hook (`herdr integration install`) | retire | Claude reports to core natively (OSC 7501) |
| `herdr-server-start.py`, `_herdr-supervise`, `lib/herdr-ready.sh`, `herdr-upgrade.sh`, `herdr-wait-quiet.sh`, `herdr-skill-sync.sh`, `make herdr-{setup,upgrade,restart,status,launchd-status,server-start-test}` | retire | `com.jkrumm.herdr-core` + the Wave 8 upgrade target |
| heartbeat herdr component, `doctor.sh`, `brew-upgrade.sh` herdr invariant, `architecture-check` `herdr.*` regex, `log-rotate` collie log, `mini-macos-update` pane snapshot | port | core LaunchAgent running + `hc server status` + MacBook/mini version parity; resume ledger as the pre-reboot snapshot |
| `Brewfile` `herdr`, cask `penso/tap/herdr-gpui`, tinycast `so.pen.herdr-gpui` hotkey, `config/herdr/config.toml`, `config-gpui.local.toml` | retire | Herdr.app (bundle id from its `Info.plist`) |
| agent-workflows `agw agents` collectors (+ argo `herdrStatus`) | port | `hc ls --json` per machine (`hc machine` links) merged with the Claude registry |
| iris herdr destination (raw `herdr.sock`) | port | `terminal.list` (labels) + `terminal.send` over `hc connect`; keep the `"herdr"` destination value, the product is still Herdr (no Swift change) |
| hermes-agent `skills/herdr`, SOUL/AGENTS/config refs | port | hc-world skill text |
| shutterflow `scripts/fleet/*` + PROTOCOL | port | `hc run`/`send`/`ls`/`kill` |
| sy-serendipity AGENTS.md dev-server pane | port | `hc run --bg --name dev …` + `hc wait --output` |
| brain wiki (`wiki/engineering/herdr.md` and live how-to pages) | port | rewrite live pages; dated pages, log and podcasts stay history |
| IuRoot/prometheus-epx eval adapter `SubprocessHerdr` | port, owner pushes | branch + commit locally (work repo, MR to colleagues = owner's step) |
| jkrumm.com published guide, weatherorb/basalt-ui/prometheus-stack plans, archives | history | untouched; listed in the final report |
| comments: ghostty, starship, ssh_config, usage-tracker, modelpick, homelab monitors, linewatch, image-gateway | port | one-line comment fixes when the file is touched anyway; listed otherwise |

## Wave 1 — Facts and port design            <!-- status: active -->
Role `lead`. Design and verification only: no consumer code. The MacBook is reachable from the mini as `ssh iumac`
(the app and its `herdr-app` socket live there).

- [ ] **Verify the open facts in a scratch core** (and a scratch `HERDR_APP_HOME` window on the MacBook where a
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
- [ ] **`/research` upstream state** (herdr-core and herdr-app repos, changelogs, issues, as of today): the
  OSC 7501 resume descriptor (#13/#15), the app auto-update off switch (#207), #219, a phone/web client or
  bridge that could replace collie, and the release cadence. Cite run ids in `docs/herdr-core.md`.
- [ ] **Decide every port-map row** above: confirm or correct the fate and the replacement, settle the three
  `decide (W1)` rows, and write the result as `docs/herdr-core.md` §Port design. Rewrite the page from
  "evaluation" to "the design we run" and keep the facts sections.
- [ ] **Reconcile the plan:** edit Waves 2–9 of this file to match the decisions (steps, owners, order). Record
  the classic agents still `working` on both machines (`herdr agent list`).

## Wave 2 — software-factory on hc            <!-- status: pending -->
Role `lead`. Repo `~/SourceRoot/software-factory`, in a worktree (its program lead commits on master): read its
`AGENTS.md`, `docs/design.md` and `docs/decisions.md` first. Its runner, witness and FL6 space rules are the
contract to keep.

- [ ] Write `HcRunner` behind the existing runner interface, over the API (`hc connect` JSON-RPC, not the CLI:
  the CLI has no `env`). Spawn = project space tab by label, `keep`, `env` (`FACTORY_SESSION`, `FACTORY_ROLE`,
  the account), `parent` = the spawning session's terminal when there is one (hidden worker). Prompt delivery
  uses `first_message` (`terminal.run` with a task) or `send --wait`, notes go through `terminal.send` and respect
  `blocked`.
- [ ] Witness on `events.subscribe`: status, turn, restarted, lost, gap recovery. Schema fields are
  renamed or aliased (`herdr_status` → a runner-neutral name) with a migration and contract bump. The hook's
  `HERDR_PANE_ID`/`HERDR_TAB_ID` become `HC_TERMINAL_ID` plus labels.
- [ ] A fake hc for the tests replaces `fake-herdr.ts`. Delete `HerdrRunner` once `HcRunner` is green: no
  dual-runner flag remains.
- [ ] Roll it out with software-factory's own release procedure (`~/.software-factory/releases/<sha>`, the
  LaunchAgent). Then prove it: one throwaway spawn lands as a named tab in the right space on the mini core and
  shows up in the app on the MacBook.

## Wave 3 — rd, waves and resume on hc            <!-- status: pending -->
Role `lead`. dotfiles.

- [ ] `scripts/remote-dev.sh`: every subcommand on hc (port map), the classic paths deleted, `factory`
  first and hc-direct as the fallback. `fan` workers are hidden children of the orchestrator. Update the
  `remote-dev-*.test.sh` stubs to a fake `hc`.
- [ ] Resume: a SessionStart hook writes the per-terminal resume doc, and `scripts/hc-resume` restores Claude
  sessions under the right account into kept shells (triggered at login and on a `restarted` event). Wire the
  hook in `config/settings.template.json`, write tests, and prove it with a scratch-core kill/restart.
- [ ] `skills/wave` (waiting = `hc wait --children`, the not-a-factory fallback), `skills/implement`,
  `docs/agent-platform.md`, `docs/remote-dev.md` §rd: hc semantics.
- [ ] Spawn Wave 4 through the new `rd wave`. That is the end-to-end proof that an orchestrator tab lands in the
  dotfiles space on the mini core.

## Wave 4 — the side consumers            <!-- status: pending -->
Role `wave`.

- [ ] dotfiles: reap and events recorder ported (plists renamed `com.jkrumm.hc-{reap,events}`), with tests.
  Settle `herdr-groups`, overview, collie, appearance and brain-note per §Port design. Port `claude-relogin`
  to `hc run --on mini`; `herdr-app-setup.sh` stops reading `herdr workspace list`.
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
  AGENTS.md; brain live wiki pages (`brain/voice.md` applies); dotfiles-private collie rows (if collie retires:
  ACL and serve rows, applied from the MacBook with `make tailscale-acl-diff` first).
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
- [ ] Repo: delete `herdr/`, the classic scripts, `config/herdr/config.toml`, the Makefile targets, the Brewfile
  lines and the settings-template hook. `make setup` + `make doctor` on both machines are green.
- [ ] `make check`, `/review`, and one commit per concern, each naming what was retired and why.

## Wave 8 — updates with a cooldown            <!-- status: pending -->
Role `wave`.

- [ ] Pin the core as a managed install, so the app's auto-update never replaces it: a formula in
  `jkrumm/tap` (hc + herdr-core from `releases.herdr.dev`, sha256 pinned, Brewfile entry) or the stable-path
  variant Wave 1 chose. The FDA path matters (fact 5). The LaunchAgent runs the pinned binary on both
  machines; `~/.local/bin/{hc,herdr-core}` go away.
- [ ] `make herdr-core-upgrade`: only a release ≥ 3 days old (from the release index date, the spirit of
  `config/bunfig.toml`'s `minimumReleaseAge`). It bumps the pin, upgrades both machines, kickstarts each core and
  asserts terminals survived and versions match. No idle-gating. `make herdr-core-upgrade-dry` previews.
- [ ] App auto-update: apply the owner's decision (default: accept, because the window only updates and the
  managed core stays pinned; else an app-side pin). The heartbeat flags a core version the pin doesn't own.
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
