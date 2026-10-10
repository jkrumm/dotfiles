# dotfiles — Agent Instructions

## What this repo is

VCS source of truth for Johannes's Claude Code setup and both Macs' bootstrap.
Everything is symlinked outward — edit at either end, git always sees the change
here. **After any edit: commit here.**

**MacBook (`iumac`) = thin client** (editing, `desk`, biometric 1Password, a few
Mac-only apps and repos). **Mac mini = always-on dev host** (agents, LaunchAgents,
Docker, dev servers), reached with `desk`/`rd`.

**`docs/architecture.md` is the map** — every machine, every repo on it, every
launchd job and its owner repo, every inbound door, the secrets flow, what
monitors what. Anything running on a machine appears there or gets deleted:
`scripts/architecture-check.sh` (via `make doctor`) exits 1 otherwise.

## Symlink map

| File here | Live path | Notes |
|-|-|-|
| `config/global.CLAUDE.md` | `~/.claude/CLAUDE.md` | Global instructions (single source — no per-workspace layer). Claude Code and OpenCode both load it; per-repo files are `AGENTS.md` + a `CLAUDE.md` shim — `docs/agents-md.md` |
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
| `config/opencode/themes/` | `~/.config/opencode/themes/` (dir symlink) | `one-zinc.json` — the dark/light palette shared with Ghostty + herdr |
| `config/opencode/plugins/protect-branches.js` | `~/.config/opencode/plugins/` (the **file** — herdr owns a sibling) | Runs `hooks/protect-branches.ts` on every bash call: one branch-protection policy for both harnesses |
| `agents/*.md` | `~/.config/opencode/agent/*.md` — **rendered**, not linked | `scripts/opencode-agents.py` rewrites Claude's frontmatter (OpenCode rejects `tools: A, B` and `color: green`, and one bad file fails the whole config) |
| `config/herdr/config.toml` | `~/.config/herdr/config.toml` | The **file** only — the same dir holds herdr's sockets and logs |
| `config/ghostty/config` | `~/.config/ghostty/config` | The one terminal config. Themes under `config/ghostty/themes/` are **copied**, not symlinked (Ghostty theme names are exact filenames) |
| `config/Caddyfile` | `$(brew --prefix)/etc/Caddyfile` | Local HTTPS proxy + the single app registry — edit here, then `caddy reload` |
| `config/pr-required-repos.json` | `~/.claude/pr-required-repos.json` | Source of truth for PR-required repos — read by `protect-branches.ts` **and** `scripts/github-config.sh` |
| `rules/` | `~/.claude/rules/` (dir symlink) | All global rules. No `paths:` frontmatter → always on; with `paths:` → lazy. Roster in the global file's *Config hierarchy*. |
| `agents/` | `~/.claude/agents/` (dir symlink) | Global subagents — `implementer.md`, `verifier.md`. Frontmatter carries `model`/`effort`/`color`/`permissionMode`. |
| `config/output-styles/` | `~/.claude/output-styles/` (dir symlink) | `Direct.md`, activated by `outputStyle` in settings.json |
| `skills/{name}/` | `~/.claude/skills/{name}/` | **Global skills** — load in every session, symlinked individually |
| `hooks/{notify,protect-branches,docker-makefile,machine-role,model-discipline}.ts` | `~/.claude/hooks/` | Live symlinks — an edit applies on the next tool call |
| `config/settings.template.json` | merged into `~/.claude/settings.json` | Never edit the live file (below) |
| `scripts/statusline.sh` · `scripts/fetch_usage.py` | `~/.claude/` | Statusline · Claude.ai usage-% fetcher (uv script) — `docs/statusline.md` |
| `scripts/secrets-run` | `~/.local/bin/secrets-run` | Drop-in `op` shim (see Secrets) |
| `scripts/remote-dev.sh` | `~/.local/bin/rd` | Place work on the mini — `rd repos\|work\|wave\|fan\|merge\|close\|agents\|read\|say` (see Machines) |
| `scripts/ask-human.sh` | `~/.local/bin/ask-human` | Queue / push a request that needs a present human (see human-queue) |
| `~/SourceRoot/warden/scripts/warden` | `~/.local/bin/warden` | Linked from the warden repo, not from here — `warden run <repo> <<'BRIEF'` (brief on stdin) or `--brief-file <path>` |
| `scripts/astra.sh` | `~/.local/bin/astra` | One-shot Responses call at `reasoning.mode="pro"` — `docs/codex.md` |
| `scripts/keyprobe.py` | `~/.local/bin/keyprobe` | Raw-byte key probe — the only unambiguous test that Caps-Lock-as-Hyper works. Run it in a **bare** terminal. |
| `skills/img/scripts/imgcli` | `~/.local/bin/imgcli` | `/img` CLI |
| `scripts/wakeup.sh` | `~/.wakeup` | sleepwatcher hook — `caddy reload` on wake |

**Not symlinked:** `~/.codex/config.toml` (rendered by `_setup-codex` from
`config/codex/config.toml.tpl` — it needs the IU endpoint host, which never
enters git) · `~/.ssh/config` (copied from `config/ssh_config` — colima
appends its own `Include`; all four hosts are MagicDNS short names, so it installs
identically on a headless machine, no secret and no `op` call) ·
`config/karabiner/karabiner.json` (copied; Karabiner rewrites the live file on
every UI change and `_setup-karabiner` refuses to overwrite a diverged copy) ·
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
| `make check` | All local validation: architecture-check + secrets-lint + hooks-test + the hermetic suites (opbackup-seed, brew-service, launchd-restarts, human-queue). No side effects. |
| `make verify` | `make doctor`, under the repo-contract name. |
| `make logs` | Bounded tail of `~/Library/Logs/{devhost-health,…}.log`, then exits. |
| `make deploy` | `make setup` under the repo-contract name; prints what it does. |
| `make worktree-audit` / `worktree-prune` | List / reclaim clean, fully-merged git worktrees across `~/SourceRoot` + `~/IuRoot` — they pile up in four different parent dirs (repo-local, `.claude/worktrees/`, `~/IuRoot/worktrees/`, `~/IuRoot/.wt/`), so it asks git rather than assuming a location. |

`make doctor` on **both** machines: LaunchAgent grading, the architecture-map
assertion, the brew report, a worktree-audit nudge. **Mini** adds drift (no push)
and names the heartbeat rather than running it (it always pushes). **MacBook** adds the remote path
(Tailscale, ssh, ControlMaster reuse, agent forwarding, herdr `--remote`, GitHub
credential + `git push --dry-run`), Kuma monitor states, then recurses into the
mini's doctor over ssh — `--local` skips that. Read-only by construction.

**Exit codes are graded.** `78` (EX_CONFIG) always fails — the job can never
start, so KeepAlive retries forever with nothing reporting it. Any other non-zero
exit fails only if the plist sets `KeepAlive` **and** the job is not running
(`db-tunnel` exits `255` on every lid-close while healthy). Also flags `/tmp`
logs, missing programs and plaintext credentials.

**settings.json merge:** the template wins on structural keys (hooks, statusLine,
plugins, env) and on `permissions.deny`; `permissions.allow` and
`model`/`effortLevel`/`alwaysThinkingEnabled` are preserved from the live file.

**Hooks:** symlinked live, so a change applies on the *next tool call* — no
install step. Run **`make hooks-test`** (`bun test hooks/`) after any edit.
`docker-makefile.ts` tokenizes and inspects only **command position** — a mention
is not an invocation. `docker {builder,image,container} prune` is allowlisted
(daemon-level, no Makefile target); `docker volume prune` stays blocked. Map: `docs/hooks.md`.

**Adding a global skill:** `skills/{name}/SKILL.md` → `make setup`. **Per-repo
skill:** `.claude/skills/{name}/SKILL.md`, committed, no symlink. **Global rule:**
`rules/{name}.md` — the whole dir is symlinked; no `paths:` means always-on.

**Changing how Claude *talks* is `config/output-styles/Direct.md`, not this file:**

| Concern | Lives in | Why |
|-|-|-|
| Response shape, autonomy, question budget, delegation posture | `output-styles/Direct.md` | Appended at the *end* of the system prompt and survives `/clear` |
| Project/machine facts, routing, conventions | `AGENTS.md` (+ `CLAUDE.md` = `@AGENTS.md` shim) | Reference material to look things up in |

`keep-coding-instructions: true` is load-bearing (`false` drops the built-in
coding prompt). Read at session start (`/clear` to apply), never reaches
subagents (tone lives in `agents/*.md`), and carries the standing delegation
authorization.

Keep this file **under 40k chars** (`wc -c AGENTS.md`; the agent context limit is
150k). When a section grows, move its narrative verbatim into the matching
`docs/*.md` and leave commands, tables and one-line gotchas with a pointer.

## Validate

`make check` (architecture-check + secrets-lint + hooks-test + the four hermetic script suites). Any edit to
`hooks/` → `make hooks-test`; any edit to `scripts/secrets-run` → the full
guardrail under *Secrets*. Contract: `docs/agents-md.md`.

## Deploy

`make deploy` = `make setup` (idempotent; run on **both** machines). No CI, no
release: a merged commit is live once symlinked. Commit here after every edit.

## Verify & Monitor

`make verify` (= `make doctor`); `make logs` for the bounded log tail. No HTTP
health URL and no OTel `service.name` — this repo runs no service. Kuma:
`MacMini Dev Host - Push` (composite over the heartbeat components, mini only),
`MacMini Secret Seed - Push` (8-day mtime). Detail: `docs/devhost-health.md`.

## Gotchas

- Symlinks: edit at either end, but **never the live `~/.claude/settings.json`** (merged).
- Every always-on rule also needs adding to `config/opencode/opencode.json` `instructions`.
- herdr restart/upgrade, TCC grants, `ssh mini 'claude …'`, `ssh iumac` identity → *Machines & remote dev*.
- `op read`/`op run` on the mini hangs; use `secrets-run` → *Secrets*.
- Logs live in `~/Library/Logs`, never `/tmp` → *Odds and ends*.
- `docs/architecture.md` must list everything that runs, or `make doctor` exits 1.

## Machines & remote dev

Agents run on the mini and outlive the MacBook. Stack: Tailscale (reachability) →
herdr on the mini (persistence + UI) → Caddy (service exposure). **No layer
substitutes for another.**

**Four lanes start agent work** (spec: `docs/agent-platform.md` §Four lanes):

| Lane | Use for |
|-|-|
| `@implementer` | the edit must land in this session's live tree |
| `agw dispatch` | settled, bounded work → branch/PR or a verdict |
| `rd wave <repo> '<prompt>'` | long work the owner watches or steers; adds a `wave <n>` **tab** to the repo's existing herdr workspace (a workspace only if the repo has none), solo Claude (`--kind opencode` for OpenCode), bounded by `RD_WAVE_MAX`; `rd close <agent>` closes a finished wave tab (clean + pushed only); `/wave` owns the contract (chain or orchestrated) and the green gate |
| `warden run <repo> <<'BRIEF'` / `--brief-file <path>` | unattended, tracked to an outcome on warden's ledger |

| Want | Command |
|-|-|
| A terminal *on* the mini | `desk [session]` = `herdr --remote mini`. Client runs here (local keybindings, image paste); server and panes on the mini. TCP — a roam or lid-close ends the *connection*, re-run it. |
| Work *placed on* the mini, no terminal | `rd repos\|work\|wave\|fan\|merge\|close\|agents\|read\|say` (`scripts/remote-dev.sh`; shorthands `work`/`agents`/`repos`) |
| What every agent is doing | `make agent-overview` — herdr workspace `overview` watching agent-gateway `GET /api/overview.txt`; its JSON twin is the one producer for Hermes, brain and Argo. |

Commands take a repo **name, never a path** — resolution happens on the host.

Five facts to hold:

- **A herdr restart restores the layout and loses the processes in it** (new
  `terminal_id`) — but **not the Claude panes**: herdr's native agent session
  restore brings each one back with `claude --resume <id>`, which needs
  integration version 6+ (this machine reports 8) and
  `[session].resume_agents_on_restore`, true by default. Shells, dev servers and
  `bun` loops still die, and a resumed agent still lost whatever turn was in
  flight, so work that must not be *interrupted* belongs in `warden run`.
- **`ssh iumac '<cmd>'` reaches the MacBook but carries no SSH identity by
  default** — `.zshrc` is not read by a remote command shell, so `SSH_AUTH_SOCK`
  is unset and every `git@github.com:` remote there fails `Permission denied
  (publickey)`. That reads like a broken tunnel and is not one. `ssh-agent.zsh`
  (loaded from `~/.zshenv`, gated on the `op` backend) fixes it; the gate is the
  backend and **not** the socket's existence, because the same socket path
  exists on the mini, where exporting it hangs.
- **Never `ssh mini 'claude …'`.** The Max credential lives in the login keychain,
  unreachable from an ssh session: the daemon comes up `Not logged in`, silently
  falls back to API billing, and still looks healthy in `claude agents`. `rd wave`
  spawns *through* a herdr pane (a GUI-session child) precisely to avoid this.
- **`herdr attach` is not a command** — `herdr --session <name>`,
  `herdr session list|attach|stop`. Apply a fix to the live server with
  `make herdr-restart YES=1` (bootout + bootstrap; `kickstart -k` re-reads
  launchd's *cache*) — it kills every pane, so it is human-timed. A version
  bump is **`make herdr-upgrade`**, which owns the whole sequence: it refuses to
  run inside a herdr pane (the shell it would kill mid-sequence), writes a
  restore inventory with each agent's resume id, gates on working/blocked
  agents, converges the plist `brew upgrade herdr` silently reverts, then
  asserts the server, the config and the groups. **`bootout` does not stop the
  server** — since 0.9.0 it is a detached daemon holding the socket until it
  exits itself, so both targets wait on
  `scripts/lib/herdr-ready.sh` (running + protocol-compatible + expected
  version) rather than sleeping. A `sleep 2` there is what made the 0.8.2 →
  0.9.0 run talk to a protocol-20 server and fail a green upgrade.
- **herdr needs Full Disk Access, and loses it on every version bump.** A pane
  process's TCC requests are attributed to herdr, and the grant is keyed to the
  resolved `/opt/homebrew/Cellar/herdr/<version>/bin/herdr`. Ungranted, the first
  agent that opens `~/Documents`, `~/Desktop`, `~/Downloads` or iCloud Drive
  raises a consent dialog on the headless screen and the `openat()` blocks until
  someone clicks — the whole Claude process freezes, subagents included, at 0%
  CPU with no error. Diagnose with `sample <pid>` (main thread in `openat`) and
  `/usr/bin/log show --predicate 'process == "tccd"'`; answering the dialog over
  screen share unfreezes it in place. `make herdr-upgrade` prints the path to
  re-grant.

**Sidebar groups** — `config/herdr/groups.json` declares the taxonomy; `make
herdr-groups` applies it (headers are separator workspaces), `make
herdr-groups-check` prints the plan, `herdr-groups.py clear` is the undo. Adding
a repo is one line in the JSON. Rationale: `docs/remote-dev.md` §Sidebar groups.

**human-queue** — ssh gives the mini reach, not a fingerprint. Work needing a
*present human* (biometric `op`, the ACL push, a person-only call) is enqueued on
the mini with `ask-human ask "…" [--cmd …]`; `make
human-queue` **walks** each one (r/already-done/deny/skip; `-run`, `-resolve`,
`-deny ID=` one-shot; no TTY → a list). `resolve` closes one satisfied out of band. The mini only *proposes* a
string; `run` needs a typed `yes` on a real TTY, per request. No poller — that
means unattended Touch ID forever. **`ask-human ask …` pushes by default**
(`--no-push` or `HUMAN_QUEUE_PUSH=0` enqueues only; `push <id>` pushes an
existing request): it ssh's to `iumac` (the mini's own dedicated key — reach the
mini already has) and runs `human-queue.sh gui-run` there, which shows the exact
string in a native macOS dialog and only executes on a click. Only an
unreachable MacBook or an unanswered dialog leaves the request queued (and fires
the Slack notify). Still no path without a present human — the dialog is a second
gate next to the typed-yes TTY gate, not a bypass of it.

**`/remote-dev`** for anything touching this stack; model in `docs/remote-dev.md`.

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
`colima-restart` applies `COLIMA_CPU`/`COLIMA_MEMORY` (mini **4/12/60**, MacBook
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

**Auto-upgrade stays off because of silent config revert, not npm-style supply
chain** — a homebrew/core formula is a reviewed PR built by Homebrew's CI.
`make brew-upgrade` asserts rather than assumes: caddy's DNS module, colima's
plist, herdr's setsid wrapper and op's TCC grant each silently revert on an
unrelated brew upgrade, invisible until the failure mode it caused (cert
renewal, a dirty shutdown, the next `desk`, a macOS dialog mid-reseal).
**`caddy` is the only pin, and a pin needs its dependencies pinned too or it
rots** (mosh is why that rule is written down —
deleted, not re-pinned). `colima` is deliberately unpinned (pinning the Docker
runtime means an unpatched hypervisor) and asserted + health-checked instead.
Casks and third-party taps are reported, never auto-upgraded — route them
through `/upgrade-deps`. Full invariants table and rationale: `docs/homebrew.md`.

## Heartbeat, drift, doctor (mini only)

| Command | Purpose |
|-|-|
| `make devhost-health-setup` / `-check` / `-teardown` | The 300 s composite heartbeat. `-check` runs it once, per-component. |
| `make drift-check-setup` / `-teardown` | The daily 09:40 upstream-drift agent (collie pin, caddy modules, brew-upgrade recency, pending macOS updates) |
| `make beszel-agent-setup` / `-status` / `-teardown` | Push-mode system-metrics agent → the homelab Beszel hub, pinned-release install (not Homebrew) |
| `make doctor` | The on-demand read-only view, including drift without pushing |

`scripts/devhost-health-check.sh` pushes **three** Uptime Kuma monitors.
`MacMini Dev Host - Push` is the composite over **17 components**: tailscale,
sshd, herdr, git push credential, dev vhosts, memory, kernel panics (WARN), launchd restarts, boot path,
services (9), claude auth, obsidian, disk, runaways, agent-gateway jobs, overview
pane, quota (in every msg; WARN never pages). Push, not probe (no ACL grant runs
`tag:homelab → tag:mac`) — full rationale, transient-tolerance knobs, and the
paired `make mini-macos-update` applier: `docs/devhost-health.md`,
[[mac-host-monitoring]].

## Collie — the phone control surface

| Command | Does |
|-|-|
| `make collie-setup` | Dev-host only: install/refresh the pinned plugin, start, assert liveness + rebind guard + real launchd supervision |
| `make collie-upgrade` | Resolve the newest tag, print changelog/diffstat/scope, on `y` bump the pin + reinstall + assert + commit |
| `make collie-status` | Read-only: LaunchAgent, bridge health, rebind guard, serve state |
| `make collie-teardown` | Boot out both labels, uninstall the plugin (never `collie-ctl.sh uninstall` — it mutates declared serve state) |

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
- **The second dialog is macOS, not 1Password** — *"op möchte auf Daten aus
  anderen Apps zugreifen"* is TCC `SystemPolicyAppData`, raised because op reads
  the desktop app's group container to handshake. macOS keys that grant on the
  BINARY PATH, and the cask path carries the version
  (`…/Caskroom/1password-cli/<ver>/op`), so **every `brew upgrade
  1password-cli` drops it** and the dialog returns mid-reseal. Held by a Full
  Disk Access grant on that exact path (FDA supersedes the AppData check; clicking "Allow" on the dialog does **not** stick — it re-prompts per `op` process),
  asserted by `make brew-upgrade`. A grant earned through a Claude Code chain
  never sticks: claude's TCC client is `~/.local/share/claude/versions/<ver>`,
  a fresh client on every auto-update — run the seed from a plain terminal.
- **"mini unreachable" usually means "1Password is locked"** — the same agent
  serves `ssh mini`, and a locked app fails it as `Permission denied (publickey)`.
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
(from `op://common/anthropic/{API_KEY,BASE_URL}`) — the IU creds behind `ca`,
`cap` and `claude_iu`. `ANTHROPIC_API_KEY` is intentionally
**never exported**: Claude Code falls back to the Max subscription when the key is
absent, and exporting it bills API credits instead.

**MCP servers**, registered at user scope by `make setup`: `chrome-devtools`
(deferred; use only via `/browse`), `research-gateway` (remote HTTP; the bearer
is **not** in `~/.claude.json` — `headersHelper` runs
`scripts/mcp-research-headers.sh` per connect, Keychain first, `secrets-run`
second. Rotating `op://vps/research-gateway/API_SECRET` means
`security delete-generic-password -s research-gateway-token` then
`make setup`), and **`agent-gateway` on the mini only** — its
MCP is stdio-only against `~/SourceRoot/agent-gateway/server/mcp.ts`, a repo that lives
only there, so `/check`, `/review`, `/otel`, `/excalidraw-diagram` and
`dispatch` are mini-only skills. Don't clone agent-gateway to the MacBook to "fix"
(remote reach = a StreamableHTTP transport).
HyperDX is deliberately *not*
registered — `/otel` speaks its endpoint over HTTP rather than costing every
session ~60 deferred tool names. Keep project MCPs minimal. **CodeRabbit CLI**
needs a one-time `coderabbit auth login`.

## Claude Code launchers

`config/zsh/claude.zsh`. An already-open shell keeps whatever it loaded at
startup — `source ~/.zshrc` after editing.

| Command | Backend | Model |
|-|-|-|
| `c` | Max subscription | whatever `/model` last left it on |
| `cs` / `cf` | Max subscription | pinned to Sonnet / Fable for this session |
| `ca [model]` | IU unified endpoint, native Anthropic route | default set in `config/zsh/claude.zsh`; served ids per `agw routing`, any as the first arg |
| `cap` | picks a model from measured data (`modelpick`), then execs `ca` | `cap --list` prints the table; `cap -- <ca args>` passes through |
| `claude_iu` | IU endpoint, headless `claude -p` | for subprocess skills — no credential plumbing to copy |
| `oc` | OpenCode on the IU endpoint — OpenAI route (`iu/…`) + Anthropic route (`anthropic/…`) | default per `docs/opencode.md` (`--variant max` / `none`); `-m <provider/model>` (e.g. an `anthropic/…` id) |
| `cx` / `cxa` | Codex on the IU endpoint (Responses API) | models per `docs/codex.md`; `astra '<q>'` = one `pro`-mode call — `docs/codex.md` |
| `rd wave` | Max, via herdr keychain | `sonnet` default (`RD_WAVE_MODEL` overrides; a chain that needs Fable sets it per spawn) |

Model-choice rationale for every row: `brain/wiki/engineering/model-routing.md`.

All share `~/.claude`, so skills, hooks, subagents and CLAUDE.md are identical;
only auth and model change. `ca` talks to the endpoint's `/anthropic` route
directly, so WebSearch/WebFetch and prompt caching both work. Its two tiers behave
differently on purpose:

- **`claude-*`** → `[1m]` is appended to the id and to every `ANTHROPIC_DEFAULT_*`
  tier (not Haiku 4.5 — it really is a 200k model). All Claude models on this
  route land on Bedrock `eu-west-1`; the `-eu` aliases add nothing and break
  `count_tokens`.
- **anything else** (gateway ids) → every `ANTHROPIC_DEFAULT_*` tier is pinned to
  that same id (leave one on a `claude-*` default and subagents 400 against a model
  the gateway doesn't serve), and the window comes from `_ca_ctx` (shared table:
  `config/zsh/iu-models.sh`) + `CLAUDE_CODE_MAX_CONTEXT_TOKENS`, never `[1m]` — a
  `claude-*` name would make usage-tracker misbill it as Max quota. `_ca_ctx` is
  deliberately conservative (200k unless measured): it is a *client-side budget*,
  so setting it above the real window trades a clean auto-compact for a hard
  mid-session rejection. The same file's `_ca_thinking` sets `MAX_THINKING_TOKENS`
  for non-Claude gateway ids (DeepSeek, kimi, minimax) — the only reasoning-effort
  control that reaches the gateway's Anthropic leg.

A `[claude-code:unrecognized_model]` line on stderr for gateway ids is expected
telemetry. `usage-tracker` bills every launcher correctly because the SessionStart
hook logs `ANTHROPIC_BASE_URL`.

**`config/zsh/claude-auth.zsh` is an ARMED fallback** (mini only, self-gated on
the `cache` backend): a `claude()` function resolving `op://mini/claude/oauth-token`
into `CLAUDE_CODE_OAUTH_TOKEN` — **never `ANTHROPIC_API_KEY`**, which flips billing
to API credits. It probes the keychain credential first and **uncached** (a cached
verdict once suppressed the fallback for an hour while `claude` ran with no
credential at all), and passes the token by prefix assignment, not `env VAR=…`
(which leaks into `ps auxww`). Only keychain-dead *and* token-dead fails the
heartbeat. **Restore the keychain credential with `/login` in a herdr pane on the
mini** rather than minting a token — that token is a one-year credential with no
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
  `-acl-push` · `make tailscale-serve` / `-check`. Every listening port needs a
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
tunnel (`make db-tunnel-setup`) and the reverse `ssh iumac` reach on :2222 all
run only on the MacBook and cost every mini agent context for no benefit — full
command tables and gotchas: `docs/macbook.md`.

## Odds and ends

**Agent logs live in `~/Library/Logs/<name>.{log,err}`, never `/tmp`.** macOS
deletes `/tmp` files untouched for 3+ days and launchd opens its stdio **once, at
spawn** — after a sweep a `KeepAlive` agent writes into an unlinked inode and
nothing reports it. `make log-rotate-setup` bounds them: hourly, **copytruncate**
(a rename follows the inode, exactly like the sweep), 16 MB cap, one `.1`
generation, safe because launchd's fds are `O_APPEND`. The list in
`scripts/log-rotate.sh` is **declared, never globbed** (`~/Library/Logs` also
holds Apple and vendor logs). `com.jkrumm.photoflow` still logs to `/tmp` — known.

**File shuttle** — `smb://mini/jkrumm` on the MacBook, `~/Shuttle` the drop
folder, for ad-hoc **human** file movement only (code → `rd`/git; vault pages →
brain-sync; anything an agent reads must live on the mini). **A listening `:445`
plus a running `smbd` is not a working SMB server** — macOS stores no NTLM
(`SMB-NT`) hash by default and `smbd` then refuses every principal with what reads
like a network fault; minting it is GUI-only. `docs/remote-dev.md`.

**The look** — `make theme` applies the terminal + herdr layers (run it on both
machines); opencode is file-based (`config/opencode/themes/one-zinc.json`, `/theme`
on **Auto**). Layers and files: `docs/theme.md`. **Never black, never white** —
middle-ground zinc (`#1f1f23` / `#f2f2f5`); font is `JetBrainsMono Nerd Font Mono`;
`herdr config check` exits 0 even on `issues found`, so `make theme` asserts the
theme files instead.

**Obsidian must keep running on the mini** (`make obsidian-autostart` — `open -a
Obsidian`, deliberately no `KeepAlive`, or it respawns the instant a human quits
it). `obsidian` (`/opt/homebrew/bin/obsidian` → the app bundle) is a **client of
the running app** and exits 1 on every subcommand when it is down, so a closed
Obsidian is a closed agent door for `/brain` and Hermes. `docs/brain-access.md`.

**Debug logs** — structured JSONL at `~/.claude/logs/YYYY-MM-DD.jsonl` from
`hooks/notify.ts` and `scripts/fetch_usage.py`, 3-day auto-cleanup; filter with
`jq 'select(.event == "stop_decision")'` or `select(.src == "fetch_usage")`.
