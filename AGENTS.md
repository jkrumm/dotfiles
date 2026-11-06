# dotfiles — Agent Instructions

## What this repo is

VCS source of truth for Johannes's Claude Code setup and both Macs' bootstrap.
Everything is symlinked outward — edit at either end, git always sees the change
here. **After any edit: commit here.**

**MacBook (`iumac`) = thin client** (editing, the Herdr app, biometric 1Password, a few
Mac-only apps and repos). **Mac mini = always-on dev host** (agents, LaunchAgents,
Docker, dev servers), reached through the Herdr app and `rd`.

**`docs/architecture.md` is the map** — every machine, every repo on it, every
launchd job and its owner repo, every inbound door, the secrets flow, what
monitors what. Anything running on a machine appears there or gets deleted:
`scripts/architecture-check.sh` (via `make doctor`) exits 1 otherwise.

## Symlink map

| File here | Live path | Notes |
|-|-|-|
| `config/global.CLAUDE.md` | `~/.claude/CLAUDE.md` | Global instructions (single source — no per-workspace layer). Claude Code and OpenCode both load it; the per-repo file is `AGENTS.md` alone, no `CLAUDE.md` — `docs/agents-md.md` |
| `config/zshrc` | `~/.zshrc` | Thin loader — sources all modules in conf.d |
| `config/zsh/*.zsh` | `~/.zsh/conf.d/` (dir symlink) | aliases, brew, claude, claude-auth, codex, git, keybindings, path, prompt, remote-dev, secrets, secrets-cache, ssh-agent, tools |
| `config/gitconfig{,-personal,-work}` | `~/.gitconfig*` | `includeIf` per workspace; 1Password commit signing |
| `config/bunfig.toml` | `~/.bunfig.toml` | Supply-chain `minimumReleaseAge` cooldown (Bun is every SourceRoot repo's package manager) |
| `config/gitignore_global` | `~/.gitignore_global` | sc-note.md, CLAUDE.local.md |
| `config/starship.toml` | `~/.config/starship.toml` | Prompt. ANSI color names, never hex, so it follows the light/dark switch |
| `config/codex/astra.config.toml` | `~/.codex/astra.config.toml` | The `cxa` profile. `config/codex/config.toml.tpl` is **rendered**, not linked (below) |
| `config/codex/AGENTS.md` | `~/.codex/AGENTS.md` | Codex's global brief — environment facts only, deliberately **not** the Claude method |
| `config/opencode/opencode.json` | `~/.config/opencode/opencode.json` | The **file** only — the dir holds opencode's plugin `node_modules`. Rules via `instructions`, IU provider via `{env:IU_*}`, yolo via `permission` |
| `config/opencode/tui.json` | `~/.config/opencode/tui.json` | TUI-only keys. `theme` lives **here**, not in `opencode.json` |
| `config/opencode/themes/` | `~/.config/opencode/themes/` (dir symlink) | `one-zinc.json` — the dark/light palette shared with Ghostty + the Herdr app |
| `config/opencode/plugins/protect-branches.js` | `~/.config/opencode/plugins/` (the **file**) | Runs `hooks/protect-branches.ts` on every bash call: one branch-protection policy for both harnesses |
| `agents/*.md` | `~/.config/opencode/agent/*.md` — **rendered**, not linked | `scripts/opencode-agents.py` rewrites Claude's frontmatter (OpenCode rejects `tools: A, B` and `color: green`, and one bad file fails the whole config) |
| `config/herdr-app/groups.json` | `~/.config/factory/spaces.json` — **rendered** by `scripts/factory-spaces.py` (`make setup`) | software-factory's space list, same order; `~/SourceRoot` only, missing repos and `noFactorySpace` skipped |
| `config/herdr-app/` | `~/.config/herdr-app/` (per item, by `make herdr-app-setup`) | Layout `jk`, mods, themes `one-zinc-*`, `groups.json` (sidebar folders, one line per repo); link per item, never the dir (it holds the app's shipped mods) |
| `config/ghostty/config` | `~/.config/ghostty/config` | The one terminal config. Themes under `config/ghostty/themes/` are **copied**, not symlinked (Ghostty theme names are exact filenames) |
| `config/Caddyfile` | `$(brew --prefix)/etc/Caddyfile` | Local HTTPS proxy + the single app registry — edit here, then `caddy reload` |
| `config/pr-required-repos.json` | `~/.claude/pr-required-repos.json` | Source of truth for PR-required repos — read by `protect-branches.ts` **and** `scripts/github-config.sh` |
| `rules/` | `~/.claude/rules/` (dir symlink) | All global rules. No `paths:` frontmatter → always on; with `paths:` → lazy. Roster in the global file's *Config hierarchy*. |
| `agents/` | `~/.claude/agents/` (dir symlink) | Global subagents — `implementer.md`, `verifier.md` and `Explore.md` (replaces the built-in, which inherits the caller's model; Haiku high, as `verifier`), and the read-only `reviewer.md` + `review-verifier.md` that `/review` calls (`Agent(type)` restrictions are ignored in subagents, so "spawn only review-verifier" is prose). Frontmatter carries `model`/`effort`/`color`/`permissionMode`. |
| `config/output-styles/` | `~/.claude/output-styles/` (dir symlink) | `Direct.md`, activated by `outputStyle` in settings.json |
| `skills/{name}/` | `~/.claude/skills/{name}/` | **Global skills** — load in every session, symlinked individually |
| `hooks/{session-env,protect-branches,docker-makefile,broad-kill-guard,review-bypass-guard,test-slot,permission-allow,machine-role,model-discipline,iu-model-guard}.ts` | `~/.claude/hooks/` | Live symlinks — an edit applies on the next tool call |
| `config/settings.template.json` | merged into `~/.claude/settings.json` | Never edit the live file (below) |
| `scripts/statusline.sh` · `scripts/fetch_usage.py` | `~/.claude/` | Statusline · usage adapter over `claude-account` (uv script, no API calls) — `docs/statusline.md` |
| `scripts/secrets-run` | `~/.local/bin/secrets-run` | Drop-in `op` shim (see Secrets) |
| `scripts/remote-dev.sh` | `~/.local/bin/rd` | Place work on the mini — `rd work\|issue\|issues\|agents\|read\|say` (see Machines) |
| `scripts/ask-human.sh` | `~/.local/bin/ask-human` | Queue / push a request that needs a present human (see human-queue) |
| `scripts/astra.sh` | `~/.local/bin/astra` | One-shot Responses call at `reasoning.mode="pro"` — `docs/codex.md` |
| `scripts/keyprobe.py` | `~/.local/bin/keyprobe` | Raw-byte key probe — the only unambiguous test that Caps-Lock-as-Hyper works. Run it in a **bare** terminal. |
| `skills/img/scripts/imgcli` | `~/.local/bin/imgcli` | `/img` CLI |
| `scripts/hl` | `~/.local/bin/hl` | HomeLab files over S3 — rclone with an env-defined `homelab:` remote + `presign`/`mount`; key per machine (see *HomeLab files*) |
| `scripts/claude-account.ts` | `~/.local/bin/claude-account` | Account picker + quota cache over `config/claude-accounts.json`; `make claude-accounts-setup` builds `~/.claude-me`; `make claude-accounts-verify` (in `make doctor`) and `make claude-accounts-e2e` prove routing + attribution; the hourly keepalive agent keeps logins alive; `claude-account expiry` says when each login ends — `docs/claude-accounts.md` §Operate |
| `scripts/claude-relogin.sh` (+ `claude-login-browser.sh`) | `~/.local/bin/claude-relogin` | One-click re-login on the machine that owns the credential: `claude-relogin <id> [--machine mini\|macbook] [--ask] [--visible] [--dry-run]`; the owner only approves in the account's browser (never automated) — `docs/claude-accounts.md` §Re-login |
| `scripts/jobrun.ts` · `scripts/lib/jobs-grade.ts` | `~/.local/bin/jobrun` · `~/.local/bin/jobs-grade` | bun/TS job recorder and the only job-grading logic (`docs/background-jobs.md` §Pattern; alerts in `docs/ops-signals.md`); `make jobs-test`; the 300 s `com.jkrumm.jobrun-canary` is the chain probe; the dotfiles jobs run under `jobrun` in their plists |
| `scripts/wakeup.sh` | `~/.wakeup` | sleepwatcher hook — `caddy reload`, Colima socket heal, and (MacBook) `jobs-grade --notify` 2 min after wake, staleness judged against awake time |

**Not symlinked:** `~/.codex/config.toml` (rendered by `_setup-codex` from
`config/codex/config.toml.tpl` — it needs the IU endpoint host, which never
enters git) · `~/.ssh/config` (copied from `config/ssh_config` — colima
appends its own `Include`; all four hosts are MagicDNS short names, so it installs
identically on a headless machine, no secret and no `op` call) ·
`config/tinycast/defaults.json` (applied to Tinycast's defaults domain by
`scripts/tinycast-config.py`, never on the mini; live wins, `make tinycast-check`) ·
`~/.claude/settings.json` (merged, below) · `~/.gitconfig-headless` (written only
by `make git-headless` on the mini) · `scripts/doctor.sh` (invoked by `make
doctor`).

**Per-repo skills** are committed, not symlinked, and load only inside their repo.
This repo ships one: `.claude/skills/iu-endpoint/` — validates the IU unified
endpoint and diffs the live catalog against `models.txt`.

## Setup, status, doctor

| Command | Does |
|-|-|
| `make setup` | Converge this machine onto the tracked config. Idempotent, safe to re-run. |
| `make status` | Prerequisites + symlink health, then `doctor --local`. |
| `make doctor` | Read-only health. Self-routes on the backend marker (below). |
| `make help` | Every target, one line each. |
| `make check` | Every target in `check:` in the Makefile: hermetic suites only (secrets lint, hook tests, script and bun tests, the architecture-check generator test). No side effects, no live probes; the live architecture-map assertion runs in `make doctor` (= `make verify`). |
| `make verify` | `make doctor`, under the repo-contract name. |
| `make logs` | Bounded tail of `~/Library/Logs/{devhost-health,…}.log`, then exits. |
| `make deploy` | `make setup` under the repo-contract name; prints what it does. |
| `make worktree-audit` / `worktree-prune` | List / reclaim clean, fully-merged git worktrees across `~/SourceRoot` + `~/IuRoot` — they pile up in four different parent dirs (repo-local, `.claude/worktrees/`, `~/IuRoot/worktrees/`, `~/IuRoot/.wt/`), so it asks git rather than assuming a location. |

`make doctor` on **both** machines: LaunchAgent grading, the architecture-map
assertion, the brew report, a worktree-audit nudge. **Mini** adds drift (no push)
and names the heartbeat rather than running it (it always pushes). **MacBook** adds the remote path
(Tailscale, ssh, the core link `hc machine ls`, GitHub credential), Kuma monitor states, then recurses into the
mini's doctor over ssh — `--local` skips that. Read-only by construction.

**Exit codes are graded.** `78` (EX_CONFIG) always fails — the job can never
start, so KeepAlive retries forever with nothing reporting it. Any other non-zero
exit fails only if the plist sets `KeepAlive` **and** the job is not running
(`db-tunnel` exits `255` on every lid-close while healthy). Also flags `/tmp`
logs, missing programs and plaintext credentials.

**settings.json merge:** the template wins on structural keys (hooks, statusLine,
plugins, env) and on `permissions.deny` + `permissions.defaultMode`
(`bypassPermissions`, so resumed and `rd work` terminals come back
in bypass, not manual); `permissions.allow` and
`model`/`effortLevel`/`alwaysThinkingEnabled` are preserved from the live file.

**Hooks:** symlinked live, so a change applies on the *next tool call* — no
install step. Run **`make hooks-test`** (`bun test hooks/`) after any edit.
`broad-kill-guard.ts` denies pattern kills (`pkill -f`, `killall`, `kill` fed by `pgrep -f`) — they reach other agents' sessions. Map: `docs/hooks.md`.
`review-bypass-guard.ts` denies review bypasses (`gh pr merge --admin`, except on the owner's `ADMIN_MERGE_REPOS` when the command names the repo; `gh api` merge / ruleset / branch-protection writes) in factory sessions (`FACTORY_SESSION`) — the owner does those by hand.

**Adding a global skill:** `skills/{name}/SKILL.md` → `make setup`. **Per-repo
skill:** `.claude/skills/{name}/SKILL.md`, committed, no symlink. **Global rule:**
`rules/{name}.md` — the whole dir is symlinked; no `paths:` means always-on.

**Changing how Claude *talks* is `config/output-styles/Direct.md`, not this file:**

| Concern | Lives in | Why |
|-|-|-|
| Response shape, autonomy, question budget, delegation posture | `output-styles/Direct.md` | Appended at the *end* of the system prompt and survives `/clear` |
| Project/machine facts, routing, conventions | `AGENTS.md` (alone — a `CLAUDE.md` would suppress it) | Reference material to look things up in |

`keep-coding-instructions: true` is load-bearing (`false` drops the built-in
coding prompt). Read at session start (`/clear` to apply), never reaches
subagents (tone lives in `agents/*.md`), and carries the standing delegation
authorization.

Keep this file **under 40k chars** (`wc -c AGENTS.md`; the agent context limit is
150k). When a section grows, move its narrative verbatim into the matching
`docs/*.md` and leave commands, tables and one-line gotchas with a pointer.

## Validate

`make check` (every target in `check:`, all hermetic). Any edit to
`hooks/` → `make hooks-test`; any edit to `scripts/secrets-run` → the full
guardrail under *Secrets*. Contract: `docs/agents-md.md`.

## Deploy

`make deploy` = `make setup` (idempotent; run on **both** machines). No CI, no
release: a merged commit is live once symlinked. Commit here after every edit.
`make setup` also restarts a loaded `hc-events`/`hc-resume` whose script changed after the
process started (`scripts/agent-refresh.sh`, `kickstart -k` + deliberate-restart marker; never
the herdr-core agent). A new KeepAlive script agent calls it from its `*-setup`.

## Verify & Monitor

`make verify` (= `make doctor`); `make logs` for the bounded log tail. No HTTP
health URL and no OTel `service.name` — this repo runs no service. Kuma:
`MacMini Dev Host - Push` (composite over the heartbeat components, mini only),
`MacMini Secret Seed - Push` (8-day mtime). Detail: `docs/devhost-health.md`.

## Gotchas

- Symlinks: edit at either end, but **never the live `~/.claude/settings.json`** (merged).
- Every always-on rule also needs adding to `config/opencode/opencode.json` `instructions`.
- Core restart/update, TCC grants, `ssh mini 'claude …'`, `ssh iumac` identity → *Machines & remote dev*.
- `op read`/`op run` on the mini hangs; use `secrets-run` → *Secrets*.
- Logs live in `~/Library/Logs`, never `/tmp` → *Odds and ends*.
- `docs/architecture.md` must list everything that runs, or `make doctor` exits 1.

## Machines & remote dev

Agents run on the mini and outlive the MacBook. Stack: Tailscale (reachability) →
herdr-core on the mini (persistence; the Herdr app is the UI) → Caddy (service exposure). **No layer
substitutes for another.**

**Lanes start agent work** (spec: `docs/agent-platform.md` §The lanes):

| Lane | Use for |
|-|-|
| `@implementer` | the edit must land in this session's live tree |
| `rd issue <repo> <title>` | work for a repo that should ship on its own: a thin `factory issue new` (`--facts @file\|-`, `--after <id>`, `--key`); the factory's lead builds, reviews, deploys and verifies; no factory, no Issue (exit code passed through); `rd issues` lists. |

| Want | Command |
|-|-|
| A terminal *on* the mini | the Herdr app on the MacBook (the mini is machine `mini`, its terminals appear in the sidebar); terminal-only: `ssh -t mini hc` (core up only; else it starts one keychain-less) picks a terminal and attaches (Ctrl+\ detaches). A roam or lid-close ends only the view. |
| Work *placed on* the mini, no terminal | `rd work\|issue\|issues\|agents\|read\|say` (`scripts/remote-dev.sh`; shorthands `work`/`agents`) |
| Housekeeping | the janitor (`com.jkrumm.hc-reap`, every 30 min; `scripts/hc-reap.py`): closes finished factory-spawned agent terminals (idle past the age limit, clean and pushed tree), messages a dirty one instead, closes orphan shells, stops old background sessions; never a working agent. Rules in `docs/remote-dev.md` §Janitor rules. Log: `~/Library/Logs/hc-reap.log` |
| The raw record | `com.jkrumm.hc-events` appends every core event to `~/.local/share/herdr-events/YYYY-MM-DD.jsonl` (data, never rotated; `recorder.gap` marks holes). `make hc-events-status` |
| What every agent is doing | the app's sidebar; the factory (software-factory, `factory fleet`) is the one producer of agent state. `agw agents` is its client for Hermes, brain and Argo and adds only recommendations and the Max quota. |

Commands take a repo **name, never a path** — resolution happens on the host.

Facts to hold:

- **A core restart or update keeps every terminal; a reboot or `kill -9` does not.** Kept terminals (`keep`) come back as
  shells, and `com.jkrumm.hc-resume` (mini only) types `claude --resume <id>` under the right account from the
  `jk.claude.*` labels, only where the foreground is positively a login shell (model, effort and the turn in flight are
  lost). Core updates are `make herdr-core-update` (the official `hc update`, by hand in a quiet window; it can end programs
  inside terminals, upstream #133, and hc-resume repairs them). Never `hc server restart|stop` or `hc machine update` outside it.
- **"The core is up" has one definition**, `scripts/lib/core-up.sh`: the socket answers AND a launchd-born core exists
  (`herdr-core --hc-launchd`, parent pid 1). `rd`, `claude-relogin`, doctor and the heartbeat use it; a core that answers
  without being launchd-born is a stray (attributed to sshd, no keychain). The core is upstream's `Herdr Core.app`
  (`~/.local/share/herdr-core/active/`, official installer); on the mini `com.jkrumm.herdr-core` is only a one-shot
  starter, the MacBook's Herdr app starts its own. No wrapper at `~/.local/bin`, no Homebrew core: `docs/herdr-core.md`
  §How the core runs now.
- **`ssh iumac '<cmd>'` carries no SSH identity by default**: `git@github.com:` there fails `Permission denied (publickey)` and reads like a broken tunnel. `docs/remote-dev.md` §ssh iumac identity.
- **Never `ssh mini 'claude …'`**, and never start a core from ssh. The Max credential lives in the login
  keychain, unreachable from an ssh session: the daemon comes up `Not logged in`, silently falls back to API
  billing, and still looks healthy in `claude agents`. `rd work` spawns *through* the launchd core (a GUI-session
  child) precisely to avoid this.
- **A core's env is every terminal's env**, and `hc run` forwards nothing: choose the Claude account on the
  command (`CLAUDE_CONFIG_DIR`, unset = `iu`), never by inheritance.
- **Full Disk Access sits on `Herdr Core.app`** (one human grant per machine, survives updates; terminal programs take
  their holder's identity). A terminal whose holder predates the bundle keeps the old identity until it ends. A frozen
  agent at 0 % CPU = a missing grant or an AppData dialog (`docs/tcc.md`, `make tcc-probe`/`tcc-check`). The launcher
  `~/.local/libexec/herdr-core-launcher` is now only the umbrella for `op` in the opbackup LaunchAgent.

**human-queue** — ssh gives the mini reach, not a fingerprint. Work needing a *present human* (biometric `op`, the ACL
push, a person-only call) is enqueued on the mini with `ask-human ask "…" [--cmd …]` (pushes to the MacBook by default;
`--no-push` / `HUMAN_QUEUE_PUSH=0` enqueues only); `make human-queue` **walks** each one on the MacBook
(r/already-done/deny/skip; `-run`, `-resolve`, `-deny ID=` one-shot; no TTY → a list). The mini only *proposes* a string;
`run` needs a typed `yes` on a real TTY, and a push shows the exact string in a native dialog that executes only on a click.
No poller, no path without a present human. An unreachable MacBook or unanswered dialog leaves it queued (and fires the
ntfy notify). Detail: `docs/remote-dev.md`.

**`/remote-dev`** for anything touching this stack; model in `docs/remote-dev.md`.

**herdr-core (`hc`) + the Herdr app**, the terminal layer: `docs/herdr-core.md`; the global `herdr` skill drives them.

## Dev-server doors

**`config/Caddyfile` is the single app registry.** Every
`<name>.test { reverse_proxy localhost:PORT }` block automatically gets a clean
tailnet door — a new app needs nothing else.

| Door | URL | Scope |
|-|-|-|
| Local | `https://<name>.test` | this machine only (`bind 127.0.0.1`, dnsmasq wildcards `*.test`) |
| Clean | `https://<name>.mini.jkrumm.com` | tailnet — one wildcard site block, Cloudflare DNS-01 cert, ACL `tag:devhost → tag:mac/tag:phone/tag:tablet` on `tcp:443` |

`make caddy-tailnet` regenerates + validates + reloads (dev host only).
`make caddy-dns-build` rebuilds Caddy with the Cloudflare DNS module — one-time
and **after any `brew upgrade caddy`**, which silently reverts it.

Gotchas (opt-out ports file, `caddy adapt` registry reads, `localhost` vs
`127.0.0.1` upstreams, one site block per app, 502-vs-403, HTTP/3 off, DNS
negative-caching at two layers): `docs/remote-dev.md` §Dev-server doors.

## Colima and the boot path

`make colima-{start,stop,restart,status}` — never bare `colima stop` or `brew
services restart colima`, both fight the supervised boot path.
`colima-restart` applies `COLIMA_CPU`/`COLIMA_MEMORY` (mini **4/6/60**, MacBook
**2/4/30**; ceilings; disk grows only via recreate). Full model — the inverted
`KeepAlive` repair, brew silently regenerating the plist on every `brew
services start/restart`/`brew upgrade colima`, the `sh.brew.*` rename,
`kickstart -k` not re-reading the plist, `com.colima.docker-socket` for the
Raycast Docker extension: `docs/remote-dev.md` → *launchd on the dev host*.

## Homebrew

`Brewfile` (repo root) is the single source of truth — taps + formulae + casks —
and **its git history is the supply-chain audit trail**. `make setup` installs it
in one `brew bundle install`; npm-global and uv tools stay Makefile-managed.

| Command | Does |
|-|-|
| `make brew-check` | Verify machine == Brewfile (read-only) |
| `make brew-diff` | List installed-but-undeclared packages (dry-run) |
| `make brew-dump` | Regenerate from machine — then **review the git diff** |
| `make brew-upgrade` | Converge pins, upgrade outdated homebrew/core formulae, assert the invariants |
| `make brew-upgrade-dry` | True no-op preview — touches nothing, does not converge pins |

Adding a package: `brew install X` → `make brew-dump` → review diff → commit.
Hardening (`config/zsh/brew.zsh`): `HOMEBREW_REQUIRE_TAP_TRUST=1` (setup trusts
exactly the Brewfile's declared taps *before* bundling, or an untrusted tap aborts
the whole install), plus `NO_INSECURE_REDIRECT` / `NO_ANALYTICS`. Auto-*update*
(metadata) stays on.

**Auto-upgrade stays off because of silent config revert, not supply chain**: caddy's DNS module, colima's plist and
op's TCC grant each revert on an unrelated brew upgrade, invisible until the failure it caused; `make brew-upgrade`
asserts them. Pins: **`caddy`** (its dependencies too) and **`tailscale`** (`make tailscale-upgrade`, below); `colima` is unpinned on purpose. herdr-core is not a brew package. Casks and third-party taps are reported,
never auto-upgraded — route them through `/upgrade-deps`. Invariants: `docs/homebrew.md`.

## Heartbeat, drift, doctor (mini only)

| Command | Purpose |
|-|-|
| `make devhost-health-setup` / `-check` / `-teardown` | The 300 s composite heartbeat. `-check` runs it once, per-component. |
| `make kuma-door-setup` / `-restart` / `-teardown` / `-gen` / `-check` | The Kuma door (below): one tailnet port Kuma pulls service health through; `-gen` writes the monitors from the registry |
| `make drift-check-setup` / `-teardown` | Retires the old drift agent (run by `make setup`); drift is now a daily bounded side job of the heartbeat |
| `make beszel-agent-setup` / `-status` / `-teardown` | Push-mode system-metrics agent → the homelab Beszel hub, pinned-release install (not Homebrew) |
| `make doctor` | The on-demand read-only view, including drift without pushing |

`scripts/devhost-health-check.sh` (`jobrun --timeout 270`) pushes **three** Uptime Kuma monitors.
`MacMini Dev Host - Push` is the composite over **19 components**: tailscale,
sshd, core, git push credential, dev vhosts, memory, swapouts, kernel panics (WARN), launchd restarts, boot path,
services (6), claude auth, claude version, AGENTS.md flag, obsidian, disk, runaways,
jobs (WARN-only, `jobs-grade`), quota (in every msg; WARN never pages). The composite and
the jobs push (no ACL grant runs `tag:homelab → tag:mac`); service health is pulled
through the Kuma door (below). Every watcher in one table: `docs/architecture.md` §Watchers.
Rationale, knobs, applier: `docs/devhost-health.md`, [[mac-host-monitoring]].

**Kuma door** (`kuma-door/`, `com.jkrumm.kuma-door`, `127.0.0.1:8795`) — the one
tailnet port through which the homelab's Uptime Kuma pulls the mini's service
health. `GET /h/<name>` relays the loopback URL that `kuma-door/registry.json`
maps to `<name>` and returns the upstream status with a body capped at 4 KiB;
GET/HEAD only, nothing from the request reaches the upstream. Reachable by
`tag:homelab` only (ACL grant + `tailscale serve` row, both in dotfiles-private).
- **Add a service:** edit `registry.json` (`name`, loopback `url`, Kuma `title`),
  then `make kuma-door-restart kuma-door-gen`; commit the generated
  `homelab/uptime-kuma/monitors.mini-door.generated.yaml` and run homelab's
  `sync.py --extra-config`. Monitors are generated, never hand-edited.
- `make kuma-door-setup` / `-restart` / `-teardown` / `-gen` / `-check` / `-test`;
  `-check` proves the door, the serve row and that the generated file is current.
- Push stays for jobs and the composite; the door carries service health only. Its liveness is a heartbeat `services` component.

## Collie — the phone control surface

| Command | Does |
|-|-|
| `make collie-setup` | Dev-host only: install/refresh the pinned bridge (standalone `com.jkrumm.collie`, `COLLIE_MUX=herdr-core`), start, assert liveness + rebind guard + launchd supervision |
| `make collie-upgrade` | Resolve the newest tag, print changelog/diffstat/scope, on `y` bump the pin + reinstall + assert + commit |
| `make collie-status` | Read-only: LaunchAgent, bridge health, rebind guard, serve state |
| `make collie-teardown` | Boot out the agent, remove the bridge (never `collie-ctl.sh uninstall` — it mutates declared serve state); `make collie-pair` pairs a phone |

**It is remote shell access by design, not "just a web UI"** — one bridge call
types arbitrary keystrokes into a live pane; treat the URL like a root login.
The gate is the tailnet ACL (`tag:phone → tag:mac`), not `COLLIE_TRUSTED_USER`;
third-party and commit-pinned (`COLLIE_REF`). Full rationale (the behavioural
health check, `COLLIE_SKIP_SERVE=1`, monitoring opt-in): `docs/collie.md`.

## Secrets

Two 1Password accounts: **`tkrumm`** (personal, `~/SourceRoot/`) and
**`careerpartner`** (work, `~/IuRoot/`). Always pass `--account`;
`op_account_for_cwd` / `op_run` in `config/zsh/secrets.zsh` resolve it from cwd
(worktree-safe via `git rev-parse --git-common-dir`).

**`secrets-run` is a drop-in `op` shim.** Apps keep their own `.env.tpl` of
`op://` refs; only the backend differs per machine (`~/.config/secrets/backend`,
injected each session by `machine-role.ts` — trust it over guessing):

```bash
secrets-run read op://vault/item/field                  # ~ op read
secrets-run run [--env-file=<tpl>]... -- <cmd>          # ~ op run (repeats; last wins)
```

- **`op` (MacBook)** — passthrough to live `op`, biometric, native redaction.
- **`cache` (mini)** — resolves each ref from one SOPS+age cache decrypted in
  memory, injecting only the template's declared keys. No plaintext on disk, no
  network, fails closed on a missing ref. **A direct `op read` on the mini HANGS**
  on a biometric prompt no one can answer.

`make secrets-seed` reads `dotfiles-private/headless.refs` (+ `headless.iu.refs`),
resolves every ref through 1Password in one biometric pass, and reseals.
`secrets-run` warns after 14 days; the heartbeat pushes DOWN at 8.

- **Tiering guardrail:** only T0/T1 refs are cached — `op://Private/*` and T2/prod
  are refused by the seed (argo's `op://vps/argo/*` is an owner-classified
  exception). Work refs *are* cached: the gate is tkrumm's `Private` vault, not
  work-vs-personal.
- **A dead ref blocks EVERY reseal.** The seed fails closed, so one deleted
  upstream item means no cache update at all; the loop collects the complete list
  before aborting. Fixing it is a refs-file edit, never a `secrets-run` problem —
  and no monitor tells you which.
- **`op whoami` is not an unlock probe, it is a permanent lock-out** — under
  desktop-app integration there is no CLI session token, so it returns rc=1 on a
  fully unlocked app while `op read` works in the same second. Use
  `scripts/lib/op-signed-in.sh <acct>` for both accounts, never whoami.
- **1Password authorizes per calling binary** — the first `op` call from a new
  parent (`make`, a LaunchAgent) raises a one-time dialog, so "it works when I run
  it by hand" proves less than it looks like.
- **The second dialog is macOS, not 1Password** — *"op möchte auf Daten aus anderen Apps zugreifen"* is TCC
  `SystemPolicyAppData`: op reads the desktop app's group container. The grant is keyed on the BINARY PATH, which carries
  the version (`…/Caskroom/1password-cli/<ver>/op`), so **every `brew upgrade 1password-cli` drops it**. Held by Full Disk
  Access on that exact path (FDA supersedes AppData; "Allow" does **not** stick), asserted by `make brew-upgrade`. A grant
  earned through a Claude Code chain never sticks (its TCC client is a fresh `claude/versions/<ver>` per auto-update): run
  the seed from a plain terminal. MacBook: `op` under the `Herdr Core.app` FDA (Herdr terminals, `hc run` for
  `ask-human --cmd`) or the opbackup launcher; acceptance `make op-tcc-probe` (`docs/tcc.md` §1Password).
- **`secrets-seed` never fans out on an access failure.** A batch/read that dies on
  authorization, a timeout or the desktop-app handshake aborts the run at once (no
  per-ref fallback, no retry) and prints the resolved `op` path to add to Full Disk
  Access; only a genuine ref error (`isn't an item`…) falls back per-ref to name the
  dead ref. Seeing the TCC dialog = grant FDA on that exact path, then re-run.
- **"mini unreachable" no longer means "1Password is locked"** — `ssh mini` uses the
  dedicated `~/.ssh/id_ed25519_mini`; check Tailscale and that key's presence.
- **The login Keychain is not a headless credential store and it fails quietly** —
  `security find-generic-password` returns non-zero when the keychain is locked,
  which is what a launchd job gets with no GUI session. Callers fall back to
  `secrets-run read` on the same refs, and say so on stderr.
- `make secrets-rotate` **refuses on a detached mini rather than hanging** —
  rotation is biometric end to end and needs a human *at* the mini.
- **Any edit to `secrets-run`** takes the full guardrail: `make secrets-test` +
  `make secrets-lint` (shellcheck) + design.md/security-review.md in the same
  change + an adversarial `/review`. It is the sole secret path on the mini.

Data half (`headless.refs`, the encrypted cache, `.sops.yaml`, the ACL and serve
declarations) lives in `~/SourceRoot/dotfiles-private`; full model in its
`docs/{design,runbook,security-review}.md`. Ops via **`/secrets`**.

**Keychain-cached by `make setup`:** `CLAUDE_SDK_API_KEY` + `CLAUDE_SDK_BASE_URL`
(from `op://common/anthropic/{API_KEY,BASE_URL}`) — the IU creds behind `cx` and, on the MacBook, `oc` (the mini's `oc` uses the gateway door token instead). `ANTHROPIC_API_KEY` is intentionally
**never exported**: Claude Code falls back to the Max subscription when the key is
absent, and exporting it bills API credits instead.

**MCP servers**, registered at user scope by `make setup`: `chrome-devtools`
(deferred; use only via `/browse`). Claude Code
reaches the platform through `agw` (`/check`, `/review`, `/prose`,
`/excalidraw-diagram`, `/brain` lookups, `/otel` — mini-only). HyperDX is deliberately *not* registered — `/otel`
speaks its endpoint through `agw hdx`. Keep project MCPs minimal.

## Claude Code launchers

`config/zsh/claude.zsh`. An already-open shell keeps whatever it loaded at
startup — `source ~/.zshrc` after editing.

| Command | Backend | Model |
|-|-|-|
| `claude` (bare, interactive zsh) | Max subscription, account from `claude-account pick --lane ${USAGE_LANE:-interactive}` unless `CLAUDE_ACCOUNT_PICKED` is set | what the resume hook types into a terminal; `-p`, subcommands and non-interactive shells never pick |
| `c` / `ch` | Max subscription | Opus, effort medium / high |
| `cs` / `cf` | Max subscription | Sonnet high / Fable medium; the four fill the app's + menu |
| `oc` | OpenCode — the local inference gateway on the mini (door token of caller `oc`), IU direct on the MacBook; OpenAI route (`iu/…`, `iu-responses/…`) + Anthropic route (`iu-anthropic/…`) | default per `docs/opencode.md` (`--variant max` / `none`); `-m <provider/model>` (e.g. an `iu-anthropic/…` id) |
| `cx` / `cxa` | Codex on the IU endpoint (Responses API) | models per `docs/codex.md`; `astra '<q>'` = one `pro`-mode call — `docs/codex.md` |

Model-choice rationale for every row: `brain/wiki/engineering/model-routing.md`.

`CLAUDE_ACCOUNT_PICKED=<id>` marks "account already chosen" (set by `c`/`ch`/`cs`/`cf` and `rd`, inherited by children;
iu is `unset CLAUDE_CONFIG_DIR`, so the marker says it was decided; it only counts while it agrees with `CLAUDE_CONFIG_DIR`): one pick-log line per spawn. `CLAUDE_ACCOUNT_REASON` (the picker's reason, display-only) travels with it for the statusline.
`make claude-accounts-setup` pre-trusts `$HOME` in every account's `.claude.json` (`scripts/claude-pretrust.sh`) and copies the default account's trusted folders into the extra ones (`scripts/claude-trust-sync.sh`, never loosens).
Contract and tests: `docs/claude-accounts.md` §Spawn integration, `make claude-launcher-test`.

A `[claude-code:unrecognized_model]` line on stderr for gateway ids is expected
telemetry. `usage-tracker` bills every launcher correctly because the SessionStart
hook logs `ANTHROPIC_BASE_URL`.

**`config/zsh/claude-auth.zsh` holds the one `claude()` function** (account pick on every machine, see above) **and
an ARMED token fallback** (`_claude_auth_run`, mini only, self-gated on the `cache` backend) resolving `op://mini/claude/oauth-token`
into `CLAUDE_CODE_OAUTH_TOKEN` — **never `ANTHROPIC_API_KEY`**, which flips billing
to API credits. It probes the keychain credential first and **uncached** (a cached
verdict once suppressed the fallback for an hour while `claude` ran with no
credential at all), and passes the token by prefix assignment, not `env VAR=…`
(which leaks into `ps auxww`). Only keychain-dead *and* token-dead fails the
heartbeat. **Restore the keychain credential with `/login` in a core terminal on the
mini** (`ssh -t mini hc run claude`) rather than minting a token — that token is a one-year credential with no
refresh and no reliable revocation.

## Codex, OpenCode, tailnet

- **Codex** (`cx`/`cxa`/`astra`) is the rare second opinion; Responses-only wire
  protocol is why it is Codex and not a proxy. `codex --strict-config` validates
  any edit to `config/codex/`; `codex exec` needs `</dev/null` in scripts.
  Everything else: `docs/codex.md`.
- **OpenCode** (`oc`) reads this file, `~/.claude/CLAUDE.md` and every skill
  natively; always-on global rules come from `instructions` in
  `config/opencode/opencode.json` (a new always-on rule must be added there too).
  Headless `run` ends on any `ask` permission; `theme` lives in `tui.json`; a
  missing `opencode.json` is a silent failure — `make status` lists the links.
  Everything else: `docs/opencode.md`.
- **Tailnet ACL and serve** are declared in `dotfiles-private` and apply **from
  the MacBook**: `make tailscale-acl-diff` (always first) · `-acl-pull` ·
  `-acl-push` · `make tailscale-serve` / `-check`. **Updates, every machine:** `make tailscale-status` / `make tailscale-upgrade [HOST=]`. Every listening port needs a
  grant and the failure is silent; `:8443` is the machine's entire public surface
  (Funnel). Everything else: `docs/tailnet.md`.

## Unattended boot posture (mini only)

Three settings survive a power cut with no human: FileVault **off**, automatic
login **on**, `pmset -a autorestart 1` (**its absence is silent** — the machine
never powers back on). Auto-login is also what makes Max auth work headlessly.
`make lock-at-boot-setup` closes the resulting screen-lock-≠-keychain-lock
window (`make lock-at-boot-check` reports both plus live state). Full posture,
the physical-possession trade and `docs/remote-dev.md` own the rationale.

## MacBook-only subsystems

opbackup + secrets auto-reseed (hourly guard, `make opbackup-{setup,check,teardown}`),
the battery charge limiter (`make batt-{setup,limit,status}`), the database
tunnel (`make db-tunnel-setup`), the HomeLab SMB keepalive (`make
smb-keepalive-setup`) and the reverse `ssh iumac` reach on :2222 all
run only on the MacBook and cost every mini agent context for no benefit — full
command tables and gotchas: `docs/macbook.md`.

## Odds and ends

**Agent logs live in `~/Library/Logs/<name>.{log,err}`, never `/tmp`.** macOS
deletes `/tmp` files untouched for 3+ days and launchd opens its stdio **once, at
spawn** — after a sweep a `KeepAlive` agent writes into an unlinked inode and
nothing reports it. `make log-rotate-setup` bounds them: hourly, **copytruncate**
(a rename follows the inode, exactly like the sweep), 16 MB cap, one `.1`
generation, safe because launchd's fds are `O_APPEND`. The list in
`scripts/log-rotate.sh` derives its list from the `com.jkrumm.*`/`com.iu.*` plists' log paths plus
a short declared `EXTRA` list; it never globs `~/Library/Logs` (which also holds Apple and vendor logs).

**File shuttle** — `smb://mini/jkrumm` on the MacBook, `~/Shuttle` the drop
folder, for ad-hoc **human** file movement only (code → `rd`/git; vault pages →
brain-sync; anything an agent reads must live on the mini). **A running `smbd` is not a working SMB server** (no NTLM hash, GUI-only fix). `docs/remote-dev.md`.

**Disk** — the mini's budget per owner, the daily `com.jkrumm.disk-sweep` (`make
disk-sweep-run` runs it once), what moved to the HomeLab and how to
restore it: `docs/disk.md`. **Agents cannot see `~/.Trash`** (no Full Disk Access; it held
246 GiB unnoticed) — measure it through `ask-human` over `ssh mini`.

**HomeLab files** — agents on the mini use **`hl`** (S3 against the HomeLab
VersityGW, buckets `ssd` and `hdd` = the same roots as SMB: `hl lsd homelab:hdd/fuji`,
`hl copy ./x homelab:hdd/inbox/…`, `hl presign <bucket>/<key> [ttl]`), **never an SMB
mount**. The mini's key (`s3-agent`, in the headless cache) reads and writes both, no delete; the
MacBook's `hl` resolves `s3-admin` (full access) through live `op`. Humans use
Finder SMB, kept alive by `com.jkrumm.smb-keepalive` (`docs/macbook.md`; `SSD` automounts), or
Cyberduck (manual install — not in the Brewfile); `hl mount <bucket>` (MacBook) is the S3 Finder mount via `rclone
nfsmount`, verified 2026-10-20 — the first run from a Terminal needs macOS's
**Network Volumes** grant; a headless run (ssh, ask-human) fails with "Operation not
permitted". Buckets, keys and policies: `~/SourceRoot/homelab/docs/s3.md`.

**The look** — `make theme` applies the terminal layer, `make herdr-app-setup` the Herdr app's (run both on each
machine); opencode is file-based (`config/opencode/themes/one-zinc.json`, `/theme`
on **Auto**). Layers and files: `docs/theme.md`. **Never black, never white** —
middle-ground zinc (`#1f1f23` / `#f2f2f5`); font is `JetBrainsMono Nerd Font Mono`;
`make theme` asserts the theme files rather than trusting a config check's exit code.

**Obsidian must keep running on the mini** (`make obsidian-autostart` — `open -a
Obsidian`, deliberately no `KeepAlive`, or it respawns the instant a human quits
it). `obsidian` (`/opt/homebrew/bin/obsidian` → the app bundle) is a **client of
the running app** and exits 1 on every subcommand when it is down, so a closed
Obsidian is a closed agent door for `/brain` and Hermes. `docs/brain-access.md`.

**Debug logs** — structured JSONL at `~/.claude/logs/YYYY-MM-DD.jsonl` from
`hooks/session-env.ts` and `scripts/fetch_usage.py`, 3-day auto-cleanup; filter with
`jq 'select(.event == "session_env")'` or `select(.src == "fetch_usage")`.
