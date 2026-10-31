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
Baseline 2026-10-31 (MacBook): `make -k check` was red only on `architecture-check` (`com.jkrumm.photoflow`, MacBook
only; retired in `1190896`, so the baseline is green). It took 40 min of wall time at 5 % CPU, so a suite sleeps or waits on the network
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

## Parallel track (started 2026-10-31 by the owner's session, beside the chain)

Independent of Waves 2–3 (it needs neither the factory nor `rd` on hc), so it runs now, one agent per item, each
in its own checkout. **Rules for a P agent:** read this plan and `docs/herdr-core.md` from
`git -C ~/SourceRoot/dotfiles show origin/master:<path>` (never edit dotfiles' `PLAN.md`: the chain owns it);
spawn no waves and no other agents beyond `@implementer`; the repo's own gate, `/review`, one commit per concern,
push to the repo's default branch (dotfiles: rebase the fan branch onto `origin/master` and push to master).
Classic herdr is still live until Wave 7: a consumer that has both worlds keeps the classic path working beside
the hc one, and leaves a one-line `TODO(Wave 7): drop classic` where the classic path goes. End with a short
report (done / deferred, one line each). The chain's Waves 4, 5 and 8 verify these and only do what is missing.

- **P1 — dotfiles, `rd fan` worktree, role `lead`: automatic core updates and durable Full Disk Access.**
  - **TCC model** (research run above): an FDA row for a CLI is keyed by its **resolved path** plus a designated
    requirement. An ad-hoc signature's requirement is its cdhash, so every new build fails it silently. TCC judges
    the **responsible process**: for a LaunchAgent, the job's own program, inherited by every descendant unless a
    child disclaims. No user-installed PPPC profile on an unmanaged Mac; no scripted FDA grant.
  - **Design to verify first, in a scratch core:** a tiny native Mach-O supervisor (Swift or C, built once,
    in the repo, at a stable path such as `~/.local/libexec/herdr-core-launcher`) becomes the LaunchAgent's
    `Program`. It `posix_spawn`s the core **as a child (never `exec`)** without disclaiming, forwards signals
    and exits with it. FDA is granted once to the launcher. Prove that `ls ~/Documents` from a terminal of a
    launcher-parented scratch core neither prompts nor freezes **after swapping the core binary for another
    build**. If the core's holders disclaim responsibility (the grant then fails to cover them), fall back to
    re-signing each core build with one stable self-signed code-signing identity and an explicit
    `--identifier` at a stable path (then `bootout` + `bootstrap`, because launchd pins the code identity at
    bootstrap). Record which design held, with the evidence, in `docs/herdr-core.md`.
  - **Managed core:** the app must never replace the core. The core reports `installed_by` from its own path
    (fact 4). Pick a layout that reports non-null and keeps the launcher path stable: a `jkrumm/tap`
    formula (versioned `/Cellar/` path, fine once the grant lives on the launcher) is the default. The
    heartbeat fails on `installed_by: null` or a core version the job didn't install.
  - **The job:** `com.jkrumm.herdr-core-update` under `jobrun` (`docs/background-jobs.md` §Pattern), daily,
    both machines. Steps:
    1. Take the newest release whose publish time (HTTP `Last-Modified` of `core/<v>/manifest.json`, or the
       GitHub tag date) is ≥ 24 h old. Verify its sha256 against the index.
    2. Bump and install it (formula bump commit in `jkrumm/tap`, or the chosen layout).
    3. `launchctl kickstart -k` the core.
    4. Assert that terminals survived (pids before = after) and that `hc machine ls` versions match on both
       machines.

    The MacBook runs first, the mini follows on its next run (or in the same run over `hc exec --on mini`).
    No idle-gating. A failed step leaves the old core running and grades the job red. `make
    herdr-core-update-check` previews (dry), `make herdr-core-update` runs it now.
  - Docs in the same commits: `docs/herdr-core.md` §Updates, `docs/architecture.md` rows (launcher, job),
    `AGENTS.md` one line (no growth), `docs/background-jobs.md`.
  - **1Password (`op`, owner pain, same mechanism):** the AppData prompt comes back after every `brew upgrade`
    because the cask path is versioned. Recipes, cheapest first:
    1. `OP_LOAD_DESKTOP_APP_SETTINGS=false` + `OP_CACHE=false` in headless contexts (undocumented, so verify
       it).
    2. Run `make secrets-seed` from a core terminal once the launcher holds FDA (op inherits it).
    3. A stable-path copy of `op` with its own FDA grant, refreshed after each upgrade.

    Verify which works without breaking biometric `op` on the MacBook. Wire the winner into
    `secrets-seed`/`brew-upgrade.sh` and drop the FDA-on-Caskroom-path assertion. Never touch `secrets-run`
    without its full guardrail (`AGENTS.md` §Secrets); if the fix needs it, stop and report instead.
  - **Holistic, not per tool (owner, 2026-10-31):** the same TCC failure bites more than core and `op`.
    Start from an inventory on both machines: every FDA / Files-and-Folders / AppData grant (System Settings
    lists; `tccutil` cannot list on 26, so read what the panel shows or what `sqlite3` on the user DB allows
    without SIP changes), every LaunchAgent `Program`, every binary under a versioned path (Caskroom, Cellar,
    `~/.local/share/claude/versions/<v>`) or ad-hoc signed (`codesign -d -r-`), and every TCC dialog in the
    unified log (`log show --predicate 'process == "tccd"' --last 7d`). Classify each one: covered by the
    launcher's grant (runs in a core terminal), needs the stable-path or stable-signature pattern, or needs no
    grant at all (`op`'s env switch, moving data out of protected folders). Write it up as `docs/tcc.md`:
    the model, the three patterns, the per-binary table, and the one-time grant list for each machine. Add a
    `make tcc-check` (read-only, in `make doctor`) that flags a LaunchAgent whose program is ad-hoc signed or
    versioned-path and not covered. Queue every one-time grant with `ask-human` in one batch per machine.
- **P2 — agent-workflows (+ argo), role `wave`:** `agw agents` collects from hc (`hc ls --json` on each
  machine through the MacBook's `hc machine` links or per-host collection; fields per `docs/herdr-core.md`
  §Verified facts) **beside** classic `herdr agent list` until Wave 7. Status, session id (from the resume
  labels), project (space name from the `herdr-app` doc), `source: hc`. argo's agents API and dashboard accept
  the new source; keep `herdrStatus` as a runner-neutral status field or rename it in both repos in one pass.
- **P3 — iris, role `wave`:** an hc destination adapter (`hc connect`: `terminal.list` by labels,
  `terminal.send`) beside the classic socket adapter, preferred when a matching hc terminal exists; `/herd` lists
  both worlds; the destination value stays `"herdr"` (no Swift change); unit tests plus the e2e.
- **P4 — shutterflow + sy-serendipity, role `wave`:** shutterflow `scripts/fleet/{spawn,retire}.sh`,
  `watch.py` and `fleet/PROTOCOL.md`/roles on hc (labels into the shutterflow space, `hc send`, `hc ls`,
  `hc kill`); sy-serendipity `AGENTS.md` dev-server instructions on `hc run --bg --name dev` + `hc wait --output`.

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

## Wave 2 — software-factory on hc            <!-- status: done -->
Role `lead`. Repo `~/SourceRoot/software-factory`, in a worktree (its program lead commits on master): read its
`AGENTS.md`, `docs/design.md` and `docs/decisions.md` first. Its runner, witness and FL6 space rules are the
contract to keep.

- [x] Write `HcRunner` behind the existing runner interface, over the API (`hc connect` JSON-RPC, not the CLI:
  the CLI has no `env`), following `docs/herdr-core.md` §Spawn contract: `cwd` always, the prompt in argv,
  `env` (`FACTORY_SESSION`, `FACTORY_ROLE`, `CLAUDE_CONFIG_DIR` or absent for `iu`), `keep`. A tab gets labels
  `herdr.space` (the `herdr-app` doc entry by folder, else `sp-<repo>-<hash of the full root>`) + a chosen `herdr.tab` id and
  `no_parent`, and is named through a compare-and-set `doc.set`. A worker gets `parent` = the spawning terminal
  and no labels. Notes go through `terminal.send` and respect `blocked`.
- [x] Witness on `events.subscribe` (shapes: §Verified facts 7): status, turn, lost/restarted per terminal,
  `missed` → rebuild from its snapshot, stream EOF → core restart (reconnect, compare `server.status` pid). Schema fields are
  renamed or aliased (`herdr_status` → a runner-neutral name) with a migration and contract bump. The hook's
  `HERDR_PANE_ID`/`HERDR_TAB_ID` become `HC_TERMINAL_ID` plus labels.
- [x] A fake hc for the tests replaces `fake-herdr.ts`. Delete `HerdrRunner` once `HcRunner` is green: no
  dual-runner flag remains. Roll out only when `factory status` shows no live session on the classic runner
  (they lose their witness otherwise); else write `stopped: <sessions>` and stop.
- [x] Roll it out with software-factory's own release procedure (`~/.software-factory/releases/<sha>`, the
  LaunchAgent). Then prove it: one throwaway spawn lands as a named tab in the right space on the mini core and
  shows up in the app on the MacBook.
**Left behind:**
- stopped: rollout and proof not done. The code is on software-factory `master` (`437a4ea`, `make check` green 693/0 three
  times, `HC_E2E=1` e2e green against a scratch core, two `agw review` rounds triaged), **not deployed**. `factory status`
  at close-out still shows live sessions on classic panes (`dotfiles-p1-hc-updates-fda` working; `dotfiles-w1`,
  `shutterflow-w1`, `agent-workflows-w1`, `iris-w1`, `iris-w19-i3-telemetry-ui-` idle), and a deploy would drop their witness
  and their notes. Next: when none is live, `make deploy` in software-factory (its release procedure), then the throwaway
  spawn proof (named tab in the dotfiles space on the mini core, visible in the app on the MacBook), then flip Wave 2 `done`
  and Wave 3 `active`. Wave 3 needs the factory on hc, so it waits for this.
- Facts the wave added (`docs/herdr-core.md` fact 9): `outlive_parent`, `claude --resume <id> "<prompt>"`, pre-adoption `doc.set`
  accepted. **Unverified:** the `herdr-app` doc shape (guessed `spaces[].{id,folder,tabs[]}`, read defensively) and whether
  the app adopts a pre-written tab entry; no app on the mini, the MacBook was not used. Tab naming is best effort
  (`factory.tab_name` label + a retry in the witness) until the proof shows the real shape.
- Contract: sessions emit `agentStatus`/`agentSeenAt` and the deprecated `herdrStatus`/`herdrSeenAt` for one release (argo/agw
  follow in Wave 4, then the aliases go). Event kind `herdr_restarted` → `runner_restarted` (migration 010, both columns
  written for one release). Hook reports `HC_TERMINAL_ID`, with `HERDR_PANE_ID`/`HERDR_TAB_ID` fallback until Wave 7.
  `HC_BIN` replaces `HERDR_BIN` (the plist template sets it; an old installed plist is regenerated by `make deploy`).
- Review findings dismissed on purpose: prompt in argv (design contract, single-user host); no classic-pane routing
  (the rollout gate is the drain); a retry on another account keeps a live terminal's account; no send guard for `done`.
  Known gap: a hidden worker is a child of its parent's *terminal*; with the parent gone it falls back to a tab.
- One commit for both halves (runner and witness share `main.ts`, the fake and `AGENTS.md`). Worktree
  `~/SourceRoot/software-factory-w2` (branch `dotfiles-w2-hc`) is merged; remove it with `git worktree remove` after the rollout.
- dotfiles gate: docs only (`docs/herdr-core.md`, this file); AGENTS.md untouched (42.1k).
- **Rollout done by the owner's session (2026-10-31 16:25):** the classic factory sessions were closed first (P1-P4,
  Wave 1/2, iris w19, software-factory W4/F1, argo-w7), then `make deploy` in software-factory: `437a4ea` healthy, rollback
  release `dd9b001`. Proof: `factory spawn create hc-proof-1` (role mechanical) landed as `mini/t1m` with labels
  `herdr.space=sp1a1c873f…` (the dotfiles space) + `herdr.tab=tb-7ebc48849fd7`; `herdr-app ls` on the MacBook shows the tab
  **named `hc-proof-1`** in that space (adoption and naming work, the guessed doc shape holds); Claude ran on Max `iu`,
  status `done`, and its transcript persisted (a normal session, `--resume`-able). Proof terminal killed and removed.
- Same session: the mini core now runs from the P1 launcher (`make herdr-core-setup YES=1`, managed core 0.1.15,
  `installed_by: homebrew`); **all 22 mini terminals survived the bootout**. The MacBook link went `needs_login` (the
  1Password agent refuses a background requester) and was re-logged by the owner; a dedicated link key follows.

## Wave 3 — rd, waves and resume on hc            <!-- status: active -->
Role `lead`. dotfiles.

- [ ] `scripts/remote-dev.sh`: every subcommand on hc (§Port design), the classic paths deleted, `factory`
  first and hc-direct as the fallback, same spawn contract as `HcRunner`. `read`/`say`/`close` keep a
  classic fallback for targets hc doesn't know, and `agents` lists both rosters, until Wave 7. `fan` workers are hidden children of
  the orchestrator; `wave` tabs (the chain's next wave included) are `no_parent`. Update the
  `remote-dev-*.test.sh` stubs to a fake `hc`.
  **CLI compatibility (owner's iris fleet depends on it):** iris `docs/waves/handoff/mother-watch.sh` greps the text
  of `rd agents` for agent names (`iris-w<n>`) and the word `blocked`; its `mother.md` spawns leads with
  `RD_ORCHESTRATED=1 rd wave iris '…'` and workers with `rd fan` (and the train that lands them), `rd read`, `rd say`. Keep those
  verbs, flags and the `rd agents` text shape (name + status word per line) working, or update iris's scripts in
  the same wave.
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
- [ ] `claude-account health` reads the peer's logins through its core (`hc exec --on mini`), not ssh: over
  ssh the mini's keychain is invisible, so the app's ⚠ chip said ok while `me`/`me2` were logged out on the mini
  (2026-10-31). Re-poll ~60 s after a Re-login starts.
- [ ] dotfiles health: heartbeat herdr component → core component (+ version parity),
  `doctor.sh`, `brew-upgrade.sh`, `architecture-check.sh`, `log-rotate.sh`, `mini-macos-update.sh`, and the
  `docs/architecture.md` rows.
- [ ] agent-workflows `agw agents` collectors on hc (+ fixtures, README), and argo's `herdrStatus` follows:
  built by parallel track P2, verify it landed and fill gaps.
- [ ] Each repo: its gate, `/review`, commit, push.

## Wave 5 — the other repos            <!-- status: pending -->
Role `wave`. One worktree per repo; `rd fan` where the repos are independent.

- [ ] iris: the `herdr` destination adapter on hc (raw socket → `hc connect`); `/herd` lists labelled
  terminals; the e2e passes. Built by parallel track P3: verify and fill gaps.
- [ ] hermes-agent skill + SOUL/AGENTS/config; shutterflow `scripts/fleet` + PROTOCOL; sy-serendipity
  AGENTS.md (both built by parallel track P4: verify); brain live wiki pages (`brain/voice.md` applies); dotfiles-private collie rows only if Wave 4
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

## Wave 8 — automatic core updates, durable Full Disk Access            <!-- status: pending -->
Role `wave`. Built by parallel track **P1** (below); this wave only verifies that P1 landed on master and fixes
what is missing. Owner decisions 2026-10-31: the core updates **automatically, daily, with a 1-day cooldown**,
through our own launchd job (never the app's updater, never `hc update`); the app's window auto-update stays
(option a); Full Disk Access must survive updates. Research run `01a1923f-c23e-7789-a684-4d96b8f41f42` (deep,
29/29 citations grounded) is the basis for the TCC design.

- [ ] P1 is merged: every item of §Parallel track P1 is true on both machines; `make herdr-core-update-check`
  and `make doctor` are green; one real automatic update has run (or a forced dry run with a fake newer release).
- [ ] `skills/upgrade-deps` machine mode and `docs/homebrew.md` describe the job; no other path updates the core.
- [ ] **MacBook cutover done by the owner's session (2026-10-31 16:5x):** launcher + managed 0.1.15 + update job on the
  MacBook, all 6 terminals survived; FDA granted, `make tcc-probe` ✓; `op read` (desktop-app integration on) in a
  fresh core terminal: OP_OK and **0 AppData prompts** in the unified log. Fix what that run exposed:
  (1) **terminals born before a cutover keep the old core's TCC identity** (they hang off the pre-cutover holder,
  `~/.local/bin/herdr-core hold` from before the cutover) and get no grant until they end; only terminals created
  after it inherit the launcher. Document it in `docs/tcc.md`, and have `op-tcc-probe` and `tcc-probe` always run
  in a fresh terminal. The "cannot read the unified log … no Full Disk Access" verdict was this, not a missing grant.
  (2) `op-tcc-probe` must pick the account: `op://hermes/…` failed against the default account
  (`--account tkrumm.1password.com` works); resolve it like `op_account_for_cwd`.
  (3) `make herdr-core-setup` failed with `No available formula … jkrumm/tap/herdr-core` because
  `HOMEBREW_NO_AUTO_UPDATE=1` kept a stale local tap: refresh `jkrumm/tap` first (`git -C "$(brew --repo
  jkrumm/tap)" pull --ff-only`), and the update job does the same.
- [ ] **The launcher's grant survives a rebuild too.** 2026-10-31: P1 rebuilt the ad-hoc launcher at 15:40, the owner's
  earlier FDA entry kept the old cdhash, and tccd logged `Failed to match existing code requirement` and prompted per
  folder until the entry was removed and re-added. Sign the launcher with one stable self-signed code-signing identity
  and an explicit `--identifier` (research run `01a1923f`, §1), so its designated requirement survives a rebuild.
  `make herdr-core-setup` refuses to swap in a rebuilt launcher without queueing the re-grant (`ask-human`), and
  `make tcc-probe` runs after every launcher change. The mini grant was verified at 16:32 (`tcc-probe` ✓).

## Wave 9 — the mini maintenance window            <!-- status: pending -->
Role `wave`. Memory note `mini-maintenance-window.md`; the classic herdr upgrade step is moot (delete it from the
note).

- [ ] `make brew-upgrade` on both machines (mini, then MacBook; owner-confirmed 2026-10-31); Colima 12 → 6 GiB (Makefile default + AGENTS.md line,
  `make colima-restart`); teamchat 6 → 3 GiB in IuRoot `chat` (work repo: a branch, the owner opens the MR).
- [ ] The heartbeat WARNs: read the logs and fix the cause of `disk-sweep`, `drift-check` and `vps-pg-backup`;
  `make claude-accounts-verify`; me2's stale quota sample. (photoflow's architecture-map entry: already retired
  in `1190896`.)
- [ ] The macOS update moved to Wave 10 (it reboots the mini, and with it this wave's own terminal).
- [ ] Final report into Left behind: everything ported, retired or deferred (one line each), anything still
  classic, and the verified state of both machines. Update the memory note.

## Wave 10 — reboot proof and the owner's next work            <!-- status: pending -->
Role `wave`. The last wave: it spawns no further wave.

- [ ] Write this wave's Left behind first (what follows, and that a reboot is next), commit, push. Then queue the macOS
  update: `ask-human ask "Mini: make mini-macos-update, staying on 26.x (never 27)" --cmd "make -C ~/SourceRoot/dotfiles
  mini-macos-update"`. It pushes a dialog to the MacBook, and the owner clicks Run. The mini reboots and this terminal ends.
- [ ] After the reboot, `hc-resume` (Wave 3) should bring this session back under its account. If it does, continue
  here: the resume itself is the proof. If it doesn't, the next owner session reads this Left behind and continues.
  Verify both cores are up (launcher, managed version, versions match), the factory is healthy, `make doctor` is green
  on both machines, and `make tcc-probe` passes on the mini.
- [ ] Start the owner's prompts from `docs/waves/handoff/post-migration/` (README: how), verbatim. If `rd wave`'s
  gate refuses a repo's plan state, start the agent with `rd work <repo>` and deliver the prompt as its first message
  instead. Never edit the prompts.
- [ ] Final report into Left behind (the Wave 9 report plus the reboot result and the two spawned agents), and update
  the memory note `mini-maintenance-window.md` to "done" (or delete it).

