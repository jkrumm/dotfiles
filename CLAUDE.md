# dotfiles — Claude Code Instructions

## What this repo is

VCS source of truth for Johannes's Claude Code setup and both Macs' bootstrap.
Everything is symlinked outward — edit at either end, git always sees the change
here. **After any edit: commit here.**

**MacBook (`iumac`) = thin client** (editing, `desk`, biometric 1Password, a few
Mac-only apps and repos). **Mac mini = always-on dev host** (agents, LaunchAgents,
Docker, dev servers), reached with `desk`/`rd`/`agent-dispatch`. homelab and VPS
are separate stacks with their own repos.

**`docs/architecture.md` is the map** — every machine, every repo on it, every
launchd job and its owner repo, every inbound door, the secrets flow, what
monitors what. Anything running on a machine appears there or gets deleted:
`scripts/architecture-check.sh` (via `make doctor`) exits 1 otherwise.

## Symlink map

| File here | Live path | Notes |
|-|-|-|
| `config/global.CLAUDE.md` | `~/.claude/CLAUDE.md` | Global Claude instructions (single source — no per-workspace layer) |
| `config/zshrc` | `~/.zshrc` | Thin loader — sources all modules in conf.d |
| `config/zsh/*.zsh` | `~/.zsh/conf.d/` (dir symlink) | aliases, brew, claude, claude-auth, codex, git, keybindings, path, prompt, remote-dev, secrets, secrets-cache, ssh-agent, tools |
| `config/gitconfig{,-personal,-work}` | `~/.gitconfig*` | `includeIf` per workspace; 1Password commit signing |
| `config/bunfig.toml` | `~/.bunfig.toml` | Supply-chain `minimumReleaseAge` cooldown (Bun is every SourceRoot repo's package manager) |
| `config/gitignore_global` | `~/.gitignore_global` | sc-note.md, CLAUDE.local.md |
| `config/starship.toml` | `~/.config/starship.toml` | Prompt. ANSI color names, never hex, so it follows the light/dark switch |
| `config/codex/astra.config.toml` | `~/.codex/astra.config.toml` | The `cxa` profile. `config/codex/config.toml.tpl` is **rendered**, not linked (below) |
| `config/codex/AGENTS.md` | `~/.codex/AGENTS.md` | Codex's global brief — environment facts only, deliberately **not** the Claude method |
| `config/herdr/config.toml` | `~/.config/herdr/config.toml` | The **file** only — the same dir holds herdr's sockets and logs |
| `config/ghostty/config` | `~/.config/ghostty/config` | The one terminal config. Themes under `config/ghostty/themes/` are **copied**, not symlinked (Ghostty theme names are exact filenames) |
| `config/Caddyfile` | `$(brew --prefix)/etc/Caddyfile` | Local HTTPS proxy + the single app registry — edit here, then `caddy reload` |
| `config/pr-required-repos.json` | `~/.claude/pr-required-repos.json` | Source of truth for PR-required repos — read by `protect-branches.ts` **and** `scripts/github-config.sh` |
| `rules/` | `~/.claude/rules/` (dir symlink) | All global rules. No `paths:` frontmatter → always on; with `paths:` → lazy. Roster in the global file's *Config hierarchy*. |
| `agents/` | `~/.claude/agents/` (dir symlink) | Global subagents — `implementer.md`. Frontmatter carries `model`/`effort`/`color`/`permissionMode`. |
| `config/output-styles/` | `~/.claude/output-styles/` (dir symlink) | `Direct.md`, activated by `outputStyle` in settings.json |
| `skills/{name}/` | `~/.claude/skills/{name}/` | **Global skills** — load in every session, symlinked individually |
| `hooks/{notify,protect-branches,docker-makefile,machine-role,model-discipline}.ts` | `~/.claude/hooks/` | Live symlinks — an edit applies on the next tool call |
| `config/settings.template.json` | merged into `~/.claude/settings.json` | Never edit the live file (below) |
| `scripts/statusline.sh` · `scripts/fetch_usage.py` | `~/.claude/` | Statusline · Claude.ai usage-% fetcher (uv script) — `docs/statusline.md` |
| `scripts/secrets-run` | `~/.local/bin/secrets-run` | Drop-in `op` shim (see Secrets) |
| `scripts/agent-dispatch.sh` | `~/.local/bin/agent-dispatch` | One bounded episode on whichever machine owns the repo |
| `scripts/astra.sh` | `~/.local/bin/astra` | One-shot Responses call at `reasoning.mode="pro"` — see *Codex* |
| `scripts/keyprobe.py` | `~/.local/bin/keyprobe` | Raw-byte key probe — the only unambiguous test that Caps-Lock-as-Hyper works. Run it in a **bare** terminal. |
| `skills/img/scripts/imgcli` | `~/.local/bin/imgcli` | `/img` CLI |
| `scripts/wakeup.sh` | `~/.wakeup` | sleepwatcher hook — `caddy reload` on wake |
| `raycast/` | `~/.raycast-scripts` (dir symlink) | Raycast Script Commands (battery limiter), MacBook-only via `make batt-setup` |

**Not symlinked:** `~/.codex/config.toml` (rendered by `_setup-codex` from
`config/codex/config.toml.tpl` — it needs the IU endpoint host, which never
enters git) · `~/.ssh/config` (copied from `config/ssh_config` — colima
appends its own `Include`; all four hosts are MagicDNS short names, so it installs
identically on a headless machine, no secret and no `op` call) ·
`config/karabiner/karabiner.json` (copied; Karabiner rewrites the live file on
every UI change and `_setup-karabiner` refuses to overwrite a diverged copy) ·
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
| Project/machine facts, routing, conventions | `CLAUDE.md` | Reference material to look things up in |

`keep-coding-instructions: true` is load-bearing (`false` drops the built-in
coding prompt). Read at session start (`/clear` to apply), never reaches
subagents (tone lives in `agents/*.md`), and carries the standing delegation
authorization.

Keep this file **under 40k chars** (`wc -c CLAUDE.md`; the agent context limit is
150k). When a section grows, move its narrative verbatim into the matching
`docs/*.md` and leave commands, tables and one-line gotchas with a pointer.

## Codex — the non-Anthropic lane

Claude Code stays the driver; this is the rare second opinion, and the whole
reason it is Codex and not a proxy is the **wire protocol**. OpenAI's reasoning
models only carry reasoning items across tool calls over the **Responses** API,
and Codex is the one harness whose `wire_api` is Responses-only. Chat-completions
drops them silently — the model re-derives its plan every tool round trip.
Routing Claude Code at an OpenAI model through a gateway is strictly worse
(double translation, thinking dropped, `reasoning_effort` ignored) and is not
worth building.

| Command | Model | Effort |
|-|-|-|
| `cx` | `gpt-5.6-sol` | `high` |
| `cxa` | `gpt-6-astra` — several times the price, opt-in on purpose | `xhigh` |
| `astra '<question>'` | `gpt-6-astra`, **no agent loop, no tools** | `xhigh` + `mode="pro"` |

- **`reasoning.mode = "pro"` is why `astra` exists.** The endpoint accepts it;
  codex has no config key for it (only `model_reasoning_effort`), so the
  strongest single shot the estate can fire is a bare Responses call. Take its
  plan, execute it in Claude Code.
- **`astra` has a ceiling, and it is the endpoint's front door, not `curl -m`.**
  `pro` + `xhigh` + a ~400-line `-f` attachment came back as an HTML `500 - The
  request timed out` after ~5 min; the same question at `-e high` returned a full
  answer in ~4 min. There is no knob for it — drop to `-e high`, drop `-m pro`, or
  send less. The script names this case explicitly now rather than printing markup.
- **Effort on this endpoint is `low|medium|high|xhigh|max`.** `none` and
  `minimal` are rejected for these models, and codex's own catalog lists
  `ultra`, which the endpoint rejects — don't set it.
- **`--profile NAME` loads `$CODEX_HOME/NAME.config.toml`**, not the legacy
  `[profiles.NAME]` table, which still parses and does nothing.
- **No prompts, no sandbox** — `approval_policy = "never"` +
  `sandbox_mode = "danger-full-access"`, parity with how `claude` runs here.
  `workspace-write` is not a middle ground: it keeps `.git` read-only and its
  network is off, so commits refuse and `bun outdated` dies on DNS. Per-run
  guardrails: `cx -s workspace-write -a on-request`.
- **The TUI probes the terminal background once, at startup**, and picks its
  colours from that (`terminal_bg` → a syntect theme, set through a `OnceLock`).
  It does not re-probe, and there is no documented `[tui]` theme key — so after
  `make theme` or an automatic light/dark flip, restart codex. herdr and Claude
  Code both switch live; this one doesn't.
- **`~/.codex/AGENTS.md` loads on every run** (verified: a marker planted in a
  scratch `CODEX_HOME` came back without any file read). It points codex at
  `CLAUDE.md` and `rules/` for environment facts and explicitly tells it *not*
  to read `skills/`, `agents/` or the output style — importing the framing is
  how a second opinion turns into an echo.
- **That combination is its own trust boundary**, not an inherited one: an
  unsandboxed agent with no human in the loop, holding a tool that fetches
  arbitrary web pages. Text in a fetched page is reachable input to a shell it
  can run unrestricted. The same shape as Claude Code + WebFetch here, but a
  second instance of it — treat an unfamiliar repo or a research-heavy run as
  the case for `cx -s workspace-write -a on-request`.
- **research-gateway is wired into codex too** (`[mcp_servers]`, bearer via
  `RESEARCH_GATEWAY_TOKEN`, `tool_timeout_sec = 7200` because one `job_wait`
  blocks for the whole job). `cx mcp list` reports it. **An empty
  `bearer_token_env_var` is fatal to codex's MCP startup** — it refuses to
  start the client rather than taking a 401 — so `cx` disables the server for
  that launch when the bearer won't resolve. In practice that means a shell
  that hasn't `sz`'d since this landed. The bearer is resolved
  once per launch into an env var, where Claude Code's headers helper re-reads
  it on every reconnect — so a mid-session rotation needs a codex restart.
- **`codex exec` blocks on stdin** when it isn't a TTY and no prompt is piped —
  redirect `</dev/null` in scripts or it hangs with no output at all.
- **`codex --strict-config` is the validator**: it names the exact unknown key
  and line. Run it after any edit to `config/codex/`.
- The key never enters the config file — `cx`/`cxa` resolve it per call
  (Keychain, then the mini's cache) into `IU_API_KEY` by prefix assignment, so
  it stays out of `ps auxww`.
- Casks are never auto-upgraded: `make brew-upgrade` reports codex, `/upgrade-deps`
  applies it.
- **Spend is tracked**: usage-tracker's `codex` collector reads
  `~/.codex/sessions/**/rollout-*.jsonl` and pushes to Argo like every other
  lane. Local only — codex runs on the MacBook are invisible until that
  collector gains an iumac mirror.

## Machines & remote dev

Agents run on the mini and outlive the MacBook. Stack: Tailscale (reachability) →
herdr on the mini (persistence + UI) → Caddy (service exposure). **No layer
substitutes for another.** `claude --bg` rides on top of all three.

| Want | Command |
|-|-|
| A terminal *on* the mini | `desk [session]` = `herdr --remote mini`. Client runs here (local keybindings, image paste); server and panes on the mini. TCP — a roam or lid-close ends the *connection*, re-run it. |
| Work *placed on* the mini, no terminal | `rd repos\|work\|bg\|agents\|read\|say` (`scripts/remote-dev.sh`; shorthands `work`/`agents`/`repos`) |
| One bounded episode, either machine | `agent-dispatch bg <repo> '<task>'` · `agent-dispatch work <repo>` |
| A long job as a self-continuing chain | `rd wave <repo> '<prompt>'` — a fresh solo pane per wave; `/wave` owns the contract and the green gate |
| Work that must not die | `claude --bg '<prompt>'` — reparents to PID 1, survives ssh, herdr and lid-close. Conflicts with `-p`. |
| What every agent is doing | `make agent-overview` — herdr workspace `overview` watching sideclaw `GET /api/overview.txt`; its JSON twin is the one producer for Hermes, brain and Argo. |

Commands take a repo **name, never a path** — resolution happens on the host.
`agent-dispatch` routes on the backend marker crossed with whether the repo exists
here: mini or mini-resident repo → `rd bg`/`rd work`; MacBook + MacBook-resident
repo → local `claude -p` on the IU Keychain creds (`claude-sonnet-5[1m]`).
`--dry-run` prints the route; `make agent-dispatch-smoke` runs a read-only task at
`dispatch-scratch`. It **refuses to nest inside an interactive Claude Code
session** (`CLAUDECODE` set → prints the brief, exit 1) — use a subagent instead.

Four facts to hold:

- **A herdr restart restores the layout and loses the processes in it** (new
  `terminal_id`) — but **not the Claude panes**: herdr's native agent session
  restore brings each one back with `claude --resume <id>`, which needs
  integration version 6+ (this machine reports 8) and
  `[session].resume_agents_on_restore`, true by default. Shells, dev servers and
  `bun` loops still die, and a resumed agent still lost whatever turn was in
  flight, so work that must not be *interrupted* still belongs in a `claude --bg`
  daemon rather than a pane.
- **`ssh iumac '<cmd>'` reaches the MacBook but carries no SSH identity by
  default** — `.zshrc` is not read by a remote command shell, so `SSH_AUTH_SOCK`
  is unset and every `git@github.com:` remote there fails `Permission denied
  (publickey)`. That reads like a broken tunnel and is not one. `ssh-agent.zsh`
  (loaded from `~/.zshenv`, gated on the `op` backend) fixes it; the gate is the
  backend and **not** the socket's existence, because the same socket path
  exists on the mini, where exporting it hangs.
- **Never `ssh mini 'claude …'`.** The Max credential lives in the login keychain,
  unreachable from an ssh session: the daemon comes up `Not logged in`, silently
  falls back to API billing, and still looks healthy in `claude agents`. `rd bg`
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

**Sidebar groups** — herdr has no folder and no separator primitive, so
`config/herdr/groups.json` declares the taxonomy and `make herdr-groups` makes
each header a **workspace** whose label is the rule (`── TOOLING ─────`),
ordered above its members via the socket API's `workspace.move_block`. A
metadata token in its own sidebar row was tried first and lost: herdr indents
rows 2+ of an entry, so any two-row entry pushes its own name out of line —
`scripts/herdr-groups.py` carries the full comparison. Nothing re-applies this
and nothing has to; both halves are workspace state, which `session.json`
persists. A separator costs an idle shell and a slot in the workspace picker,
and stays invisible to sideclaw's overview (agent-driven; `workspace list` is
only an id→label map there). `make herdr-groups-check` prints the plan,
`herdr-groups.py clear` is the undo. Adding a repo is one line in the JSON; an
unopened space is skipped, so listing one early costs nothing.

**human-queue** — ssh gives the mini reach, not a fingerprint. Work needing a
*present human* (biometric `op`, the ACL push, a person-only call) is enqueued on
the mini with `ask-human.sh ask "…" [--cmd …]`; `make
human-queue` **walks** each one (r/already-done/deny/skip; `-run`, `-resolve`,
`-deny ID=` one-shot; no TTY → a list). `resolve` closes one satisfied out of band. The mini only *proposes* a
string; `run` needs a typed `yes` on a real TTY, per request. No poller — that
means unattended Touch ID forever.

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

`make colima-{start,stop,restart,status}` — never bare `colima stop` (KeepAlive
undoes it) and **never `brew services restart colima`**: it regenerates the stock
plist and bootstraps *that*, so a repaired file never reaches launchd.
`colima-restart` applies `COLIMA_CPU`/`COLIMA_MEMORY` (mini **4/8/60**, MacBook
**2/4/30**; ceilings; disk grows only via recreate), converges the plist, then
bootout + bootstrap (the only reload that re-reads the file).

Gotchas (the inverted `KeepAlive` repair, brew silently regenerating the plist on
every `brew services start/restart`/`brew upgrade colima`, the `sh.brew.*` rename,
`kickstart -k` not re-reading the plist, `com.colima.docker-socket` for the
Raycast Docker extension): `docs/remote-dev.md` → *launchd on the dev host*.

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
plist and herdr's setsid wrapper each silently revert on an unrelated brew
upgrade, invisible until the failure mode it caused (cert renewal, a dirty
shutdown, the next `desk`). **`caddy` is the only pin, and a pin needs its
dependencies pinned too or it rots** (mosh is why that rule is written down —
deleted, not re-pinned). `colima` is deliberately unpinned (pinning the Docker
runtime means an unpatched hypervisor) and asserted + health-checked instead.
Casks and third-party taps are reported, never auto-upgraded — route them
through `/upgrade-deps`. Full invariants table and rationale: `docs/homebrew.md`.

## Heartbeat, drift, doctor (mini only)

| Command | Purpose |
|-|-|
| `make devhost-health-setup` / `-check` / `-teardown` | The 300 s composite heartbeat. `-check` runs it once, per-component. |
| `make drift-check-setup` / `-teardown` | The daily 09:40 upstream-drift agent (collie pin, caddy modules, brew-upgrade recency, pending macOS updates) |
| `make doctor` | The on-demand read-only view, including drift without pushing |

`scripts/devhost-health-check.sh` pushes **three** Uptime Kuma monitors.
`MacMini Dev Host - Push` is the composite over **16 components**: tailscale,
sshd, herdr, git push credential, dev vhosts, memory, launchd restarts, boot path,
services (9), claude auth, obsidian, disk, runaways, sideclaw jobs, overview
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
`cap`, `claude_iu` and `agent-dispatch`. `ANTHROPIC_API_KEY` is intentionally
**never exported**: Claude Code falls back to the Max subscription when the key is
absent, and exporting it bills API credits instead.

**MCP servers**, registered at user scope by `make setup`: `chrome-devtools`
(deferred; use only via `/browse`), `research-gateway` (remote HTTP; the bearer
is **not** in `~/.claude.json` — `headersHelper` runs
`scripts/mcp-research-headers.sh` per connect, Keychain first, `secrets-run`
second. Rotating `op://vps/research-gateway/API_SECRET` means
`security delete-generic-password -s research-gateway-token` then
`make setup`), and **`sideclaw` on the mini only** — its
MCP is stdio-only against `~/SourceRoot/sideclaw/server/mcp.ts`, a repo that lives
only there, so `/check`, `/review`, `/otel`, `/excalidraw-diagram` and
`dispatch` are mini-only skills. Don't clone sideclaw to the MacBook to "fix"
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
| `ca [model]` | IU unified endpoint, native Anthropic route | `claude-sonnet-5[1m]` default; any served id as the first arg |
| `cap` | picks a model from measured data (`modelpick`), then execs `ca` | `cap --list` prints the table; `cap -- <ca args>` passes through |
| `claude_iu` | IU endpoint, headless `claude -p` | for subprocess skills — no credential plumbing to copy |

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
  the gateway doesn't serve), and the window comes from `_CA_CTX` +
  `CLAUDE_CODE_MAX_CONTEXT_TOKENS`, never `[1m]` — a `claude-*` name would make
  usage-tracker misbill it as Max quota. `_CA_CTX` is deliberately conservative
  (200k unless measured): it is a *client-side budget*, so setting it above the
  real window trades a clean auto-compact for a hard mid-session rejection.

A `[claude-code:unrecognized_model]` line on stderr for gateway ids is expected
telemetry. `usage-tracker` bills all three lanes correctly because the SessionStart
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

## Tailnet ACL and serve — as code

Both are **declared state in `dotfiles-private`** (an ACL is a security boundary,
a serve file an exposure map) with the tooling here, and both apply **from the
MacBook**: the API key is `op://Private/Tailscale`, which the mini's cache refuses
by design.

| Command | Does |
|-|-|
| `make tailscale-acl-diff` | **Always first** — a push overwrites the whole tailnet ACL |
| `make tailscale-acl-pull` | Fetch live **into** the file, staged through a temp file |
| `make tailscale-acl-push` | Validate + apply (prompts; `ACL_PUSH_YES=1` bypasses) |
| `make tailscale-serve` / `-check` | Converge / report drift against `tailscale-serve.<machine>.conf` |

- **Every listening port needs a grant and the failure is silent** — no refusal,
  no log line on either end, just a timeout. The clean door rides `tcp:443`;
  `tcp:7700-7799` covers dev servers that bind `0.0.0.0`.
- **Applying serve does `tailscale serve reset` first** — a device rename leaves
  bindings under the old name that no per-port `off` can address. Row column 4 is
  an optional human label the applier normalises away, so it cannot cause drift.
- Rows: `:7730` (rb) and `:8788` (Collie), tailnet-only; **`:8443` — Funnel,
  public internet**, the IU dashboard, gated by `tag:iu-dashboard-funnel`, an
  *additive single-device* tag because Funnel is a whole-device capability and
  `tag:mac` would expose the work MacBook. **That one port is the machine's entire
  public surface** — don't "clean up" the tag.
- **Tagging a device is console-only** and independent of pushing a grant — both
  are silently inert without the other. Verify the live filter with no API key
  from the mini: `tailscale debug netmap`, parsing `PacketFilter`.
- **`--accept-routes` is off on the mini** — imperative daemon state with nothing
  declaring it; re-check after any Tailscale reinstall or re-auth.
- **The mini and homelab are on different networks** and meet only over Tailscale
  — homelab is *not* a LAN jump host for the mini.
- The mini runs the **open-source `tailscaled` from Homebrew** (root LaunchDaemon,
  starts before login), never the macsys app; consumers resolve the CLI through
  `scripts/lib/tailscale-cli.sh` — a leftover app-bundle CLI answers with a stopped
  tunnel and a stale IP, a wrong answer rather than an error.

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

**The look** — `make theme` applies all three layers and reloads herdr live; run
it on both machines, since applying one layer is how they drift.

| Layer | File | Setting |
|-|-|-|
| Terminal | `config/ghostty/config` | `theme = dark:one-zinc-dark,light:one-zinc-light` |
| herdr chrome | `config/herdr/config.toml` | `name = "one-dark"`, `auto_switch = true`, `light_name = "catppuccin-latte"` |
| Prompt | `config/starship.toml` | ANSI color *names* — resolve through whichever is active |

**Never black, never white** — middle-ground zinc (`#1f1f23` / `#f2f2f5`);
`#09090b` was tried and lasted one commit. `catppuccin-latte` for light is a taste
call **against** the measured contrast numbers; `nord`/`dracula`/`vesper` aren't
options (no light sibling for `auto_switch`). Font must be
**`JetBrainsMono Nerd Font Mono`** — the Mono variant forces single-width glyphs
so herdr's icons can't break sidebar alignment. `herdr config check` catches
unknown keys and theme names but **silently accepts a bad hex and exits 0 even on
`issues found`**, so `make theme` asserts the theme files instead. Measurements:
`docs/theme.md`.

**Obsidian must keep running on the mini** (`make obsidian-autostart` — `open -a
Obsidian`, deliberately no `KeepAlive`, or it respawns the instant a human quits
it). `obsidian` (`/opt/homebrew/bin/obsidian` → the app bundle) is a **client of
the running app** and exits 1 on every subcommand when it is down, so a closed
Obsidian is a closed agent door for `/brain` and Hermes. `docs/brain-access.md`.

**Debug logs** — structured JSONL at `~/.claude/logs/YYYY-MM-DD.jsonl` from
`hooks/notify.ts` and `scripts/fetch_usage.py`, 3-day auto-cleanup; filter with
`jq 'select(.event == "stop_decision")'` or `select(.src == "fetch_usage")`.
