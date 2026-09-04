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
| `config/zsh/*.zsh` | `~/.zsh/conf.d/` (dir symlink) | ai, aliases, brew, claude, claude-auth, git, keybindings, path, prompt, remote-dev, secrets, secrets-cache, tools |
| `config/gitconfig{,-personal,-work}` | `~/.gitconfig*` | `includeIf` per workspace; 1Password commit signing |
| `config/bunfig.toml` | `~/.bunfig.toml` | Supply-chain `minimumReleaseAge` cooldown (Bun is every SourceRoot repo's package manager) |
| `config/gitignore_global` | `~/.gitignore_global` | sc-note.md, CLAUDE.local.md |
| `config/starship.toml` | `~/.config/starship.toml` | Prompt. ANSI color names, never hex, so it follows the light/dark switch |
| `config/herdr/config.toml` | `~/.config/herdr/config.toml` | The **file** only — the same dir holds herdr's sockets and logs |
| `config/ghostty/config` | `~/.config/ghostty/config` | The one terminal config. Themes under `config/ghostty/themes/` are **copied**, not symlinked (Ghostty theme names are exact filenames) |
| `config/Caddyfile` | `$(brew --prefix)/etc/Caddyfile` | Local HTTPS proxy + the single app registry — edit here, then `caddy reload` |
| `config/pr-required-repos.json` | `~/.claude/pr-required-repos.json` | Source of truth for PR-required repos — read by `protect-branches.ts` **and** `scripts/github-config.sh` |
| `rules/` | `~/.claude/rules/` (dir symlink) | All global rules. No `paths:` frontmatter → always on; with `paths:` → lazy. Roster in the global file's *Config hierarchy*. |
| `agents/` | `~/.claude/agents/` (dir symlink) | Global subagents — `implementer.md`. Frontmatter carries `model`/`effort`/`color`/`permissionMode`. |
| `config/output-styles/` | `~/.claude/output-styles/` (dir symlink) | `Direct.md`, activated by `outputStyle` in settings.json |
| `skills/{name}/` | `~/.claude/skills/{name}/` | **Global skills** — load in every session, symlinked individually |
| `hooks/{notify,protect-branches,docker-makefile,machine-role}.ts` | `~/.claude/hooks/` | Live symlinks — an edit applies on the next tool call |
| `config/settings.template.json` | merged into `~/.claude/settings.json` | Never edit the live file (below) |
| `scripts/statusline.sh` · `scripts/fetch_usage.py` | `~/.claude/` | Statusline · Claude.ai usage-% fetcher (uv script) — `docs/statusline.md` |
| `scripts/secrets-run` | `~/.local/bin/secrets-run` | Drop-in `op` shim (see Secrets) |
| `scripts/agent-dispatch.sh` | `~/.local/bin/agent-dispatch` | One bounded episode on whichever machine owns the repo |
| `scripts/keyprobe.py` | `~/.local/bin/keyprobe` | Raw-byte key probe — the only unambiguous test that Caps-Lock-as-Hyper works. Run it in a **bare** terminal. |
| `skills/img/scripts/imgcli` | `~/.local/bin/imgcli` | `/img` CLI |
| `scripts/wakeup.sh` | `~/.wakeup` | sleepwatcher hook — `caddy reload` on wake |
| `raycast/` | `~/.raycast-scripts` (dir symlink) | Raycast Script Commands (battery limiter), MacBook-only via `make batt-setup` |

**Not symlinked:** `~/.ssh/config` (copied from `config/ssh_config` — colima
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

`make doctor` on **both** machines: LaunchAgent grading, the architecture-map
assertion, the brew report. **Mini** adds drift (no push) and names the heartbeat
rather than running it (it always pushes). **MacBook** adds the remote path
(Tailscale, ssh, ControlMaster reuse, agent forwarding, herdr `--remote`, GitHub
credential + `git push --dry-run`), Kuma monitor states, then recurses into the
mini's doctor over ssh — `--local` skips that. Read-only by construction.

**Exit codes are graded, and that is what makes the LaunchAgent section worth
reading.** `78` (EX_CONFIG) always fails — the job can never start, so KeepAlive
retries forever with nothing reporting it. Any other non-zero exit fails only if
the plist sets `KeepAlive` **and** the job is not currently running: `db-tunnel`
exits `255` on every lid-close while perfectly healthy, and flagging that trains
you to skim past the line that matters. It also flags a missing
program/WorkingDirectory, `/tmp` logs, and plaintext credentials in
`EnvironmentVariables`.

**settings.json merge:** the template wins on structural keys (hooks, statusLine,
plugins, env) and on `permissions.deny`; `permissions.allow` and
`model`/`effortLevel`/`alwaysThinkingEnabled` are preserved from the live file.

**Hooks:** symlinked live, so a change applies on the *next tool call* — no
install step. Run **`make hooks-test`** (`bun test hooks/`) after any edit.
`docker-makefile.ts` tokenizes with quote/escape state and only inspects tokens in
**command position** — a *mention* is not an invocation, and a false block trains
you to distrust the hook. Host-level prune verbs (`docker
{builder,image,container} prune`) are allowlisted (no Makefile target covers the
daemon); `docker volume prune` stays blocked. Full map: `docs/hooks.md`.

**Adding a global skill:** `skills/{name}/SKILL.md` → `make setup`. **Per-repo
skill:** `.claude/skills/{name}/SKILL.md`, committed, no symlink. **Global rule:**
`rules/{name}.md` — the whole dir is symlinked; no `paths:` means always-on.

**Changing how Claude *talks* is `config/output-styles/Direct.md`, not this file:**

| Concern | Lives in | Why |
|-|-|-|
| Response shape, autonomy, question budget, delegation posture | `output-styles/Direct.md` | Appended at the *end* of the system prompt and survives `/clear` |
| Project/machine facts, routing, conventions | `CLAUDE.md` | Reference material to look things up in |

`keep-coding-instructions: true` is load-bearing — the default `false` drops
Claude Code's built-in software-engineering prompt and leaves a chatty generalist
holding a `Bash` tool. Read at session start only (`/clear` to apply an edit) and
does **not** reach subagents (their tone lives in `agents/*.md`). It also carries
the standing delegation authorization that counterweights Claude Code's stock "do
not call AgentTool unless the user requested it".

Keep this file **under 40k chars** (`wc -c CLAUDE.md`; the agent context limit is
150k). When a section grows, move its narrative verbatim into the matching
`docs/*.md` and leave commands, tables and one-line gotchas with a pointer.

## Machines & remote dev

Agents run on the mini and outlive the MacBook. Stack: Tailscale (reachability) →
herdr on the mini (persistence + UI) → Caddy (service exposure). **No layer
substitutes for another.** `claude --bg` rides on top of all three.

| Want | Command |
|-|-|
| A terminal *on* the mini | `desk [session]` = `herdr --remote mini`. Client runs here (local keybindings, image paste); server and panes on the mini. TCP — a roam or lid-close ends the *connection*, re-run it. |
| Work *placed on* the mini, no terminal | `rd repos\|work\|bg\|agents\|read\|say` (`scripts/remote-dev.sh`; shorthands `work`/`agents`/`repos`) |
| One bounded episode, either machine | `agent-dispatch bg <repo> '<task>'` · `agent-dispatch work <repo>` |
| Work that must not die | `claude --bg '<prompt>'` — reparents to PID 1, survives ssh, herdr and lid-close. Conflicts with `-p`. |

Commands take a repo **name, never a path** — resolution happens on the host.
`agent-dispatch` routes on the backend marker crossed with whether the repo exists
here: mini or mini-resident repo → `rd bg`/`rd work`; MacBook + MacBook-resident
repo → local `claude -p` on the IU Keychain creds (`claude-sonnet-5[1m]`).
`--dry-run` prints the route; `make agent-dispatch-smoke` runs a read-only task at
`dispatch-scratch`. It **refuses to nest inside an interactive Claude Code
session** (`CLAUDECODE` set → prints the brief, exit 1) — use a subagent instead.

Three facts worth holding without loading the skill:

- **A herdr crash restores the layout and loses every process in it** (new
  `terminal_id`) → durable work belongs in a `claude --bg` daemon, not a pane.
- **Never `ssh mini 'claude …'`.** The Max credential lives in the login keychain,
  unreachable from an ssh session: the daemon comes up `Not logged in`, silently
  falls back to API billing, and still looks healthy in `claude agents`. `rd bg`
  spawns *through* a herdr pane (a GUI-session child) precisely to avoid this.
- **`herdr attach` is not a command** — `herdr --session <name>`,
  `herdr session list|attach|stop`. Apply a fix to the live server with
  `make herdr-restart YES=1` (bootout + bootstrap; `kickstart -k` re-reads
  launchd's *cache*) — it kills every pane, so it is human-timed.

**human-queue** — ssh gives the mini reach, not a fingerprint. Work needing a
*present human* (biometric `op`, the ACL push, any person-only decision) is
enqueued on the mini with `ask-human.sh ask "…" [--cmd …] [--wait]` and drained on
the MacBook with `make human-queue` (`human-queue.sh show/run/deny <id>`). The
mini only ever *proposes* a command string; `run` needs a typed `yes` on a real
TTY. Nothing drains it automatically — a poller would mean an unattended Touch ID
prompt on a schedule forever.

Use **`/remote-dev`** for anything touching this stack. Full model:
`docs/remote-dev.md`.

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

- `~/.config/caddy-tailnet.ports` is **opt-out only** (`exclude <name>`), never a
  second app list — it used to be one and the two drifted silently (17 apps vs 4).
- The registry is read with `caddy adapt` + a route-JSON walk
  (`scripts/lib/caddy-registry.py`), **never regexed**; a block that can't reduce
  to one name+port is **skipped, never guessed at**, and an empty registry is
  refused.
- **Upstreams dial `localhost:PORT`, never `127.0.0.1:PORT`** — Vite binds `::1`
  alone when its port is held elsewhere and still prints `ready`.
- **One site block for every app, never one per app** (Caddy 2.10+ issues one
  wildcard cert per block; N blocks race Let's Encrypt's ~50/week).
- **502 vs 403**: 502 = dev server not running; 403 = running and rejecting the
  Host header → add `.mini.jkrumm.com` to `server.allowedHosts` (Vite/Astro) or
  `*.mini.jkrumm.com` to `allowedDevOrigins` (Next — no leading-dot support).
- **`servers { protocols h1 h2 }`** disables HTTP/3 globally — quic-go's
  1280-byte initial packet exceeds the tailnet MTU (caddyserver/caddy#7885).
- **DNS negative-caches at two layers**: the LAN router (~30 min) and macOS
  `mDNSResponder`, which `dscacheutil -flushcache` does **not** clear — only
  `sudo killall -HUP mDNSResponder`.
- **`https://apps.mini.jkrumm.com` lists every app** with port and live status,
  and answers at any *unmatched* `*.mini.jkrumm.com` name, so a typo shows what
  exists. The apex `https://mini.jkrumm.com` (own cert + A record) lands on the
  same page.

Full walkthrough: `docs/remote-dev.md` → *Dev-server doors*.

## Colima and the boot path

`make colima-{start,stop,restart,status}` wrap **`brew services`**, never bare
`colima stop` (KeepAlive undoes it). `colima-restart` also applies the current
`COLIMA_CPU`/`COLIMA_MEMORY` (defaults **2/4/60**, ceilings not reservations;
disk only grows via recreate).

- **The plist's `KeepAlive` is repaired and the repair is load-bearing.** Brew
  generates `{ SuccessfulExit => true }` (restart only on a *zero* exit) while
  `colima start -f` runs the VM in the foreground — inverted, so a dirty Lima
  image leaves Docker down until a human logs in. `{ Crashed => true }` is not the
  fix (that is death by *signal*). `_setup-colima` converges onto bare `KeepAlive
  => true` plus `colima/colima-start.sh`, a bounded-retry wrapper (5 attempts,
  then a 600 s cool-off, never latching off).
- **Brew regenerates that plist on every `brew services start/restart` and every
  `brew upgrade colima`, silently** — same trap as herdr's setsid wrapper and
  Caddy's DNS module. Every `colima-*` target re-converges; `colima-status` /
  `herdr-status` assert the boot path (plist on disk + `launchctl print` path
  match), and so does the heartbeat's `check_boot_path`.
- **Homebrew 6 renames the plist** to `sh.brew.<name>` on the next
  `brew services start|restart`. Never spell a label: **`scripts/lib/brew-service.sh`**
  resolves plist/label/target by service name (`make brew-service-test`); a
  hardcoded path once made converge exit 0 over the stock plist it repairs.
- **`launchctl kickstart -k` does not re-read the plist** — only `bootout` +
  `bootstrap` does. Expect `Bootstrap failed: 5` until the label disappears.
- **`brew services list` showing `caddy none` / `dnsmasq none` is a reporting
  artifact** — without sudo it enumerates only `gui/501` and both live in the
  `system` domain. Starting either with `brew services start` creates a duplicate
  user-domain job fighting the root one for `:443`.
- **`com.colima.docker-socket`** (root LaunchDaemon) maintains
  `/var/run/docker.sock` at boot — the only path the Raycast Docker extension can
  use, since it sanitizes `DOCKER_HOST`/context out of its env. Colima ships no
  GUI: that extension plus `lazydocker`. Drive containers via Makefile targets.

Full rationale: `docs/remote-dev.md` → *launchd on the dev host*.

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
`make brew-upgrade` asserts rather than assumes:

| Invariant | What an upgrade breaks | Visible after |
|-|-|-|
| caddy DNS module | replaces the xcaddy-built binary; `dns.providers.cloudflare` vanishes | ~60 days, when the wildcard cert fails to *renew* |
| colima plist | regenerates it, restoring the inverted `KeepAlive` | only after a *dirty* shutdown — the exact event this setup exists to survive |
| herdr setsid wrapper | strips `herdr-server-start.py` from the brew plist | next `desk`, which starts asking to restart the remote server |

**`caddy` is the only pin** (`brew pin` is the enforcement, not a hold list some
script knows about, so it holds for a bare command typed by hand). **A pin needs
its dependencies pinned too, or it rots** — a pinned binary still breaks when a
dylib it links is upgraded underneath it; mosh is why that rule is written down,
and why it was deleted rather than re-pinned. `colima` is deliberately unpinned
(pinning the Docker runtime means an unpatched hypervisor) and asserted +
health-checked instead. Casks and third-party taps are reported, never
auto-upgraded — route them through `/upgrade-deps`. `docs/homebrew.md`.

## Heartbeat, drift, doctor (mini only)

| Command | Purpose |
|-|-|
| `make devhost-health-setup` / `-check` / `-teardown` | The 300 s composite heartbeat. `-check` runs it once, per-component. |
| `make drift-check-setup` / `-teardown` | The daily 09:40 upstream-drift agent (collie pin, caddy modules, brew-upgrade recency, pending macOS updates) |
| `make doctor` | The on-demand read-only view, including drift without pushing |

`scripts/devhost-health-check.sh` pushes **three** Uptime Kuma monitors.
`MacMini Dev Host - Push` is the composite over **13 components**: tailscale,
sshd, herdr, git push credential, dev vhosts, memory, launchd restarts, boot path,
services, claude auth, obsidian, disk, runaways.

- **Push, not probe** — the ACL grants `tag:homelab → tag:vps` but not `→ tag:mac`,
  and an inbound grant purely for monitoring is new attack surface.
- **The line is absence, not independence** — a component that can legitimately be
  *missing* on a good machine gets its own monitor (collie, secrets freshness);
  merely independent ones stay composite, named in the push `msg`.
- **Bash 3.2, and must stay one** — launchd sets no PATH, so `/usr/bin/env bash`
  is Apple's 3.2 (no `mapfile`, no `${var,,}`, no `"${arr[@]}"` on a possibly-empty
  array under `set -u`). Same for `drift-check.sh` and `doctor.sh`.
- **Transient tolerance**: `DEVHOST_BOOT_GRACE_SECONDS` (300 — every failing
  component reports `starting`), `DEVHOST_TRANSIENT_FAILS` (3 — FAIL only on the
  third consecutive bad run; edge-triggered `check_launchd_restarts` is excluded),
  `DEVHOST_REBOOT_NOTE_SECONDS` (600). None of it softens "the machine is gone" —
  a dead host emits no push at all. `maxretries` must be **0** on every push
  monitor; the default 3 turns a 10-minute time-to-DOWN into 40.
- **Drift reports and never upgrades, deliberately** — the hazard is silent config
  revert, and an unattended upgrader at 3am is how you introduce it. `make
  collie-upgrade` and `make mini-macos-update` are the paired human-invoked
  appliers: **notice unattended, apply attended.** It uses age grace
  (`DRIFT_GRACE_DAYS` 14) rather than bare "is it behind", and degrades a network
  failure to `skipped`, never DOWN.
- **`make mini-macos-update`** (MacBook-only, TTY or `YES=1`) exists because the
  obvious spelling is wrong: `softwareupdate -i -a -R` returns in seconds printing
  `Restarting...` and does **not** restart — that is a *request* — and forcing
  `shutdown -r now` aborts the prepare and boots the old OS with everything still
  looking armed. `sw_vers -productVersion` is the only honest check.

Full rationale: `docs/devhost-health.md`.

## Collie — the phone control surface

| Command | Does |
|-|-|
| `make collie-setup` | Dev-host only: install/refresh the pinned plugin, start, assert liveness + rebind guard + real launchd supervision |
| `make collie-upgrade` | Resolve the newest tag, print changelog/diffstat/scope, on `y` bump the pin + reinstall + assert + commit |
| `make collie-status` | Read-only: LaunchAgent, bridge health, rebind guard, serve state |
| `make collie-teardown` | Boot out both labels, uninstall the plugin (never `collie-ctl.sh uninstall` — it mutates declared serve state) |

- **It is remote shell access by design, not "just a web UI"** — one bridge call
  types arbitrary keystrokes into a live pane; treat the URL like a root login.
- **The gate is the ACL, not `COLLIE_TRUSTED_USER`** — every tailnet node is
  tagged, not logged in, so the trusted-user check cannot discriminate devices.
  The grant is scoped to `tag:phone`; **`tag:client` (TVs + tablet) never**.
- **Whatever starts the bridge must source the hand-written `.env`, or every
  hardening setting goes silently unset while the UI works perfectly** — the
  bridge reads `process.env` only. Hence the health check is *behavioural*: a
  spoofed `Host` must 403 on `/api/snapshot` specifically (`/` answers 200 to any
  Host). Front door is the declared serve row on **:8788**, never funneled;
  `COLLIE_SKIP_SERVE=1` is mandatory or `make tailscale-serve` wipes it.
- Third-party and **commit-pinned** (`COLLIE_REF` in the Makefile — a commit, not
  a tag, since `plugin install` re-clones). Monitoring is opt-in on its own Kuma
  monitor: a machine without collie must not fail the heartbeat.

Full rationale: `docs/collie.md`.

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
(deferred; use only via `/browse`), `research-gateway` (remote HTTP, bearer
resolved from 1Password at provision time — re-run after rotating
`op://vps/research-gateway/API_SECRET`), and **`sideclaw` on the mini only** — its
MCP is stdio-only against `~/SourceRoot/sideclaw/server/mcp.ts`, a repo that lives
only there, so `/check`, `/review`, `/otel`, `/read-drawing`,
`/excalidraw-diagram` and `dispatch` are mini-only skills. Don't clone sideclaw to
the MacBook to "fix" that; reaching it remotely would need a StreamableHTTP
transport, which is sideclaw's design decision. HyperDX is deliberately *not*
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
never powers back on). Auto-login is also what makes Max auth work headlessly: a
real password login brings the keychain up unlocked.

`make lock-at-boot-setup` closes the resulting window — **screen lock ≠ keychain
lock**, so the session keeps running behind the password prompt, which is the
point. Two halves: `sysadminctl -screenLock immediate -password '<pw>'` (one-time,
by hand — prefer the GUI, it has no interactive form) plus a `RunAtLoad` agent
firing `pmset displaysleepnow` (`CGSession -suspend` is gone on macOS 26 and
`osascript` ⌃⌘Q needs TCC no launchd job can get). Setup **refuses to install the
second without the first**; `make lock-at-boot-check` reports both plus live state.

Physical possession still yields root (`/etc/kcpassword`, reversible XOR), reaching
every cached ref; Thunderbolt Sharing Mode is a FileVault question and stays open.
Full trade: `docs/remote-dev.md`.

## opbackup + secrets auto-reseed (MacBook only)

`opbackup` (`scripts/backup-1password.py`) exports every vault, age-encrypts it in
memory and rsyncs the ciphertext to homelab. The same hourly agent
(`com.jkrumm.opbackup`) also reseeds the mini's secrets cache.

| Command | Does |
|-|-|
| `make opbackup-setup` | Seed the stamp from the newest remote backup, install + load the agent |
| `make opbackup-check` | Run the guard once; prints which precondition stopped it. `FORCE=1` backs up now |
| `make opbackup-teardown` | Unload + remove (stamps kept) |

**It does not make the backup unattended and must never be made to** — the first
`op` call raises a biometric approval, and every way around that parks a
credential able to export every vault. The goal is a prompt at a sane moment.

- **Hourly via `StartCalendarInterval`**, never `RunAtLoad`/`StartInterval` — only
  calendar intervals coalesce a fire missed while asleep into one wake-up run.
- **Every decision lives in `scripts/opbackup-auto.sh`**, cheapest-first, each
  exiting **0** (a skip is the normal case). Two separate stamps (success >5d,
  attempt >6h), because declining an approval must not mean being asked again in
  60 minutes forever. Screen lock is `ioreg -n Root -d1 -k
  CGSSessionScreenIsLocked` — the key is **absent** while unlocked — read into a
  variable, never piped to `grep -q` (`pipefail` turns SIGPIPE into a false fail).
- **Retention:** `prune_remote()` keeps the newest 8 plus the newest per calendar
  month, deleting an explicit regex-validated filename list, never a remote glob —
  an old dump stays decryptable after the passwords in it are rotated.
- **A skip line in `~/Library/Logs/opbackup.log` is a claim, not a diagnosis** —
  three Secrets gotchas above (whoami, per-binary approval, a locked app reading as
  "mini unreachable") each present as a clean deliberate skip.
- **One transient `op read` failure must not discard a whole ~150-ref run** — reads
  are `timeout -k`-bounded and retried 3× **on transient errors only**; retrying a
  genuinely missing ref just delays an error a human has to fix.

## Battery charge limiter (MacBook only)

[`batt`](https://github.com/charlie0129/batt) holds the charge at a cap (default
**80%**) via a root LaunchDaemon. The binary ships in the Brewfile; the daemon and
cap are opt-in, and every target self-gates on an internal battery (no-op on the
mini).

| Command | Purpose |
|-|-|
| `make batt-setup` | One-time: daemon + cap + daily-reset agent + Raycast symlink (`LIMIT=N`) |
| `make batt-limit LIMIT=100` | Change the cap now |
| `make batt-limit LIMIT=100 DAYS=7` | Same, plus pause the daily 80% reset for 7 days |
| `make batt-status` | Charging state + limits, and the resume date if paused |

A 09:00 LaunchAgent resets the cap daily — that is what makes a 100% boost
*temporary*; `~/.config/batt/pause-until` (epoch stamp, from Raycast's "Pause days"
field or `DAYS=N`) suspends it for travel, and a cap set with no `DAYS` clears the
file, so that doubles as cancel. Changing the resting default means editing both
`battery/batt-reset.sh` and `LIMIT ?= 80`. Raycast control is self-authored Script
Commands in `raycast/` — point Raycast at `~/.raycast-scripts` once, under
**Settings → Script Commands** (a top-level tab, not under Extensions).

## Odds and ends

**Agent logs live in `~/Library/Logs/<name>.{log,err}`, never `/tmp`.** macOS
deletes `/tmp` files untouched for 3+ days and launchd opens its stdio **once, at
spawn** — after a sweep a `KeepAlive` agent writes into an unlinked inode and
nothing reports it. `make log-rotate-setup` bounds them: hourly, **copytruncate**
(a rename follows the inode, exactly like the sweep), 16 MB cap, one `.1`
generation, safe because launchd's fds are `O_APPEND`. The list in
`scripts/log-rotate.sh` is **declared, never globbed** (`~/Library/Logs` also
holds Apple and vendor logs). `com.jkrumm.photoflow` still logs to `/tmp` — known,
deliberately not fixed from here.

**Database access** (`make db-tunnel-setup`, MacBook): a `KeepAlive` agent holding
one `ssh -N` with every `-L` in `dbtunnel/tunnels.conf`; **local ports are the real
port + 30000** (33306, 36379). Four launchd traps, all in `docs/remote-dev.md`:
launchd's `SSH_AUTH_SOCK` has zero identities, `IdentityAgent` needs literal
quotes, `ControlMaster=no`+`ControlPath=none`, and ssh must stay in the foreground.

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

**Debug logs** — structured JSONL at `~/.claude/logs/YYYY-MM-DD.jsonl`, written by
`hooks/notify.ts` and `scripts/fetch_usage.py`, 3-day auto-cleanup on every
invocation. `jq 'select(.event == "stop_decision")'` for hook decisions;
`jq 'select(.src == "fetch_usage")'` for statusline errors (`type` names the
exception class).
