# dotfiles — Claude Code Instructions

## What This Repo Is

VCS source of truth for Johannes's Claude Code setup. Everything is symlinked
outward — edit at either end, git always sees the change here.

TTS/STT runs via the **audio-gateway** service (`~/SourceRoot/audio-gateway`,
OpenAI-compatible VPS container at `audio-gateway.jkrumm.com`, reached over the tailnet).
It fronts the IU unified audio endpoint (STT + expressive Gemini TTS). Hermes and Argo
point at it. LLM is also cloud — Hermes uses Sonnet 4.6 via the IU unified endpoint.

The `localai/` directory (per-machine `mlx-audio` STT + Fish S2 Pro TTS, :8000/:8001/:8002)
is **RETIRED** (2026-05-25): no longer in the `make setup` chain and not running. Files are
kept, not deleted, for an easy re-add. Tear down a live install with `make localai-teardown`.
See `localai/README.md` and the `/localai` skill (both marked retired).

**Companion repo: `~/SourceRoot/hermes-agent`** — Hermes Agent setup (Mac Mini-only).
Historically pulled the `localai-helper` plist template from
`localai/com.localai.helper.plist.template` here; now that Hermes consumes the VPS
audio-gateway, that helper is retired too — clean it up in hermes-agent's own setup. See
`hermes-agent/CLAUDE.md`.

**After any edit: commit here.**

## Docker runtime: Colima

The Docker runtime on every Mac is **Colima** (Lima + Apple Virtualization.Framework),
installed by `make setup` (`_setup-colima`) — it replaced OrbStack (commercial license
enforced via phone-home) and Docker Desktop (heavy). `make setup` brews
`colima docker docker-compose docker-credential-helper lazydocker` (the credential
helper supplies `docker-credential-osxkeychain`, which OrbStack used to provide and the
CLI needs for `"credsStore": "osxkeychain"`), wires the Compose plugin path into
`~/.docker/config.json`, creates the VM (`vz` + Rosetta amd64 emulation + virtiofs
mounts), pins the `colima` docker context, registers the **brew service**
(`RunAtLoad` + `KeepAlive`) so it's always-on and auto-starts at login, and installs the
`com.colima.docker-socket` LaunchDaemon (see **Docker socket** below).

Resources are set by `COLIMA_CPU` / `COLIMA_MEMORY` / `COLIMA_DISK` (defaults
**2 / 4 / 60**). These are **ceilings, not reservations**: idle VM holds ~1.3GB on the
host regardless of the cap, and CPU is time-shared (free when idle). Bump for heavy
stacks (e.g. ClickHouse + Redpanda): `COLIMA_MEMORY=10 make colima-restart`.

Manage with `make colima-{start,stop,restart,status}` — these wrap **`brew services`**,
not bare `colima stop` (KeepAlive would relaunch it). `colima-restart` also applies the
current `COLIMA_CPU/MEMORY` to the persisted config (disk only grows via recreate).

No GUI ships with Colima by design — use the **Raycast "Manage Docker" extension**
(start/stop/restart containers) and **`lazydocker`** (TUI: logs/stats/exec). The
`docker-makefile` rule still applies — drive containers via repo Makefile targets,
not raw `docker`/`compose`. Colima provides no auto-domains; local HTTPS routing is
handled by the existing Caddy + dnsmasq `*.test` setup.

**Docker socket:** Colima's engine socket is `~/.colima/default/docker.sock`. A root
**LaunchDaemon** (`com.colima.docker-socket`, template in `colima/`, installed to
`/Library/LaunchDaemons` by `_setup-colima`) maintains `/var/run/docker.sock` → that
socket at every boot — exactly what OrbStack's privileged helper did. This single
mechanism makes the standard default socket work for **everything**: the docker CLI, the
Raycast Docker extension (which sanitizes extension env vars, so `DOCKER_HOST`/context
*cannot* reach it — the `/var/run` socket is the only thing that does), IDEs,
Testcontainers, and scripts. The CLI additionally has the `colima` context pinned.
Reboot-, brew-upgrade-, and colima-restart-safe (the symlink target path is stable).
Installing the daemon needs sudo (like the Caddy step). A GUI app that was already running
during first install must be quit + relaunched once to retry the socket.

## Homebrew (Brewfile + supply-chain hardening)

All brew-managed packages are declared in **`Brewfile`** (repo root) — the single
source of truth (full machine manifest: taps + formulae + casks). `make setup`
installs from it in one `brew bundle install` step (`_setup-packages`), so the
per-tool `brew install` lines are gone from the Makefile; each `_setup-*` step now
only *configures* (links config, runs services, wires the VM). **npm-global and uv
tools stay Makefile-managed** (fallow, litellm, etc.) — they need Node/uv on PATH,
not ready that early in bootstrap — so the Brewfile is deliberately brew-native only.

Keep it honest (the Brewfile's **git history is the supply-chain audit trail** —
nothing joins the manifest without a reviewed diff):

- `make brew-check` — verify machine == Brewfile (read-only).
- `make brew-diff` — list installed-but-undeclared packages (dry-run).
- `make brew-dump` — regenerate from machine (brew-native only; preserves the header), then **review the git diff** before committing.

Adding a brew package: `brew install X` → `make brew-dump` → review diff → commit
(or edit `Brewfile` → `brew bundle install`). Source of truth is the **file**, not
the machine.

**Hardening** lives in `config/zsh/brew.zsh`: `HOMEBREW_REQUIRE_TAP_TRUST=1`
(refuse untrusted third-party taps). `_setup-packages` auto-runs `brew trust` on exactly
the taps the Brewfile declares **before** `brew bundle` — otherwise a declared-but-untrusted
tap makes bundle refuse and abort the whole manifest on a fresh machine (this once silently
skipped colima/docker). Self-maintaining: trust follows the vetted manifest, no hardcoded list.
Other hardening: `HOMEBREW_NO_INSECURE_REDIRECT=1`, `HOMEBREW_NO_ANALYTICS=1` (also `brew analytics
off`). Auto-*update* (metadata refresh) stays on; auto-*upgrade* is the npm-style
risk and is **never** enabled — upgrade one package at a time (`/upgrade-deps`).

## Symlink Map

| File here | Live path | Notes |
|-|-|-|
| `config/global.CLAUDE.md` | `~/.claude/CLAUDE.md` | Global Claude instructions (single source — no per-workspace layer) |
| `config/zshrc` | `~/.zshrc` | Thin loader — sources all modules in conf.d |
| `config/zsh/*.zsh` | `~/.zsh/conf.d/` (dir symlink) | ai, aliases, brew, claude, git, keybindings, opencode, path, remote-dev, secrets, secrets-cache, tools |
| `config/opencode/opencode.json` | `~/.config/opencode/opencode.json` | OpenCode CLI config — IU unified-endpoint providers (no secrets/hostnames; `{env:IU_*}` placeholders) |
| `config/opencode/AGENTS.md` | `~/.config/opencode/AGENTS.md` | OpenCode global preamble — defers to `~/.claude` config via `instructions` |
| `config/gitconfig` | `~/.gitconfig` | includeIf per workspace |
| `config/gitconfig-personal` | `~/.gitconfig-personal` | jkrumm@pm.me + 1Password signing |
| `config/gitconfig-work` | `~/.gitconfig-work` | johannes.krumm@iu.org + 1Password signing |
| `config/bunfig.toml` | `~/.bunfig.toml` | Global Bun config — supply-chain `minimumReleaseAge` cooldown (Bun is every SourceRoot repo's package manager) |
| `config/gitignore_global` | `~/.gitignore_global` | sc-note.md, CLAUDE.local.md |
| `config/ghostty/config` | `~/.config/ghostty/config` | Shell integration + option key settings. Loaded FIRST, so `config.appsupport` overrides it |
| `config/ghostty/config.appsupport` | `~/Library/Application Support/com.mitchellh.ghostty/config` | Font, theme, cursor, padding. Ghostty's own macOS config path — read by **both** cmux and bare Ghostty, and it WINS over the file above |
| `config/ghostty/themes/*` | `~/.config/ghostty/themes/` | `one-zinc-{dark,light}` (active) + `basalt-ui-{dark,light}` (tracked alternative). Copied, not symlinked — cmux symlink bug |
| `config/herdr/config.toml` | `~/.config/herdr/config.toml` | herdr theme (near-stock: 1 colour override) + the `prefix+e` notes binding. The **file** only — the same dir holds herdr's sockets and logs |
| `config/starship.toml` | `~/.config/starship.toml` | Prompt. ANSI color names, never hex, so it follows the light/dark switch |
| `config/Caddyfile` | `$(brew --prefix)/etc/Caddyfile` | Local HTTPS reverse proxy — edit here, then `caddy reload` |
| `scripts/wakeup.sh` | `~/.wakeup` | sleepwatcher hook — runs `caddy reload` on wake |
| `scripts/secrets-run` | `~/.local/bin/secrets-run` | Drop-in `op` shim — `op` (MacBook) or `cache` (mini) backend, see Headless secrets below |
| `hooks/notify.ts` | `~/.claude/hooks/notify.ts` | All 4 hook events |
| `hooks/protect-branches.ts` | `~/.claude/hooks/protect-branches.ts` | PreToolUse — blocks push to protected branches |
| `hooks/docker-makefile.ts` | `~/.claude/hooks/docker-makefile.ts` | PreToolUse — blocks raw docker commands when Makefile exists |
| `hooks/machine-role.ts` | `~/.claude/hooks/machine-role.ts` | SessionStart — injects this machine's secrets backend + outbound-access routing (cache/mini vs op/MacBook) |
| `config/pr-required-repos.json` | `~/.claude/pr-required-repos.json` | Single source of truth for PR-required repos — read by `protect-branches.ts` (hook) and `scripts/github-config.sh` (full vs lite ruleset tier). |
| `scripts/statusline.sh` | `~/.claude/statusline.sh` | 3-line statusline |
| `scripts/fetch_usage.py` | `~/.claude/fetch_usage.py` | Claude.ai usage % fetcher (uv script) |
| `rules/` | `~/.claude/rules/` (dir symlink) | Global rules (attribution, commit conventions, dependency hygiene, formatting, research-first, security, TypeScript, code style, docker-makefile, makefile-conventions, visx-charts) |
| `skills/{name}/` | `~/.claude/skills/{name}/` | **Global skills** — load in every Claude Code session. Each skill is symlinked individually. |
| `raycast/` | `~/.raycast-scripts` (dir symlink) | Raycast Script Commands (battery limiter). MacBook-only via `make batt-setup`; point Raycast at the dir once. |

**Per-repo skills** (not symlinked — committed to the repo, load only when Claude is started inside that repo):
- `.claude/skills/localai/` — **RETIRED** (local mlx-audio / Fish S2 Pro stack, replaced by the VPS audio-gateway). Kept for an easy re-add.
- `.claude/skills/iu-endpoint/` — validate the IU unified endpoint + discover newer/better models for OpenCode and Hermes (`validate.sh` probes transports, health-checks configured models with backend-redundancy, diffs the live catalog).
- `.claude/skills/sync/` — bidirectionally sync all git repos between this MacBook (orchestrator) and the always-on Mac mini over SSH, using the git remote as transport. `scripts/recon.sh` scans both machines' git state ($HOME-relative, so it works despite differing usernames); a per-repo reconcile plan is confirmed once, then subagents commit wip work, push, rebase, and resolve conflicts. Skips the stale local-branch graveyard (`local_only` count, never mass-pushed), preserves diverged branches, handles PR-required-master. Run from a dotfiles session (`/sync`); MacBook-only.

**Generated (not symlinked):** `~/.ssh/config` — installed by `_setup-ssh` from `config/ssh_config`. All four hosts (`mini`, `iumac`, `homelab`, `vps`) are **MagicDNS short names**, so there is no rendering, no secret, and no `op` call: the file installs identically on a headless machine. That is the payoff of giving every machine one canonical short name — the old version injected the two Mac hostnames from `op://Private/*-server/hostname`, which hung `make setup` on the mini (no biometric prompt to answer). Copied rather than symlinked because colima appends its own `Include` to this file, which the target re-appends after each install. `mini` sets `ForwardAgent yes` so the always-on Mac mini can do git/ssh ops with approval popping on the connecting machine's 1Password. Also generated: `~/.gitconfig-headless` — written only by `make git-headless` on the mini (machine-local, never symlinked), see Headless outbound access below.

**Not symlinked:** `~/.claude/settings.json` — machine-specific permissions.
`make setup` creates from template if missing, otherwise jq-merges:
template wins on structural keys (hooks, statusLine, plugins, env); permissions + model/effortLevel/alwaysThinkingEnabled preserved from live file.

## Remote access (Mac mini, over Tailscale)

The Mac mini is the always-on home base (Hermes + Feuer run here), reached from the
MacBook over Tailscale — never the public internet. `make remote-access` (opt-in per
machine, **not** in the default `setup` chain — enabling an SSH server is a deliberate
per-host call) makes a Mac remotely controllable:

- Installs trusted public keys from `config/ssh/authorized_keys` into `~/.ssh/authorized_keys`
  (append-if-missing; public keys, safe to commit — served by the 1Password SSH agent).
- Installs the key-only sshd hardening drop-in (`config/sshd/200-hardening.conf.template`
  → `/etc/ssh/sshd_config.d/200-hardening.conf`, `__SSH_USER__` injected): no root, no
  passwords (both `PasswordAuthentication` and `KbdInteractiveAuthentication` off —
  required under macOS `UsePAM yes`), `AllowUsers <you>`, agent forwarding on. Guarded on
  `authorized_keys` being non-empty so it can't lock out SSH.
- Remote Login + Screen Sharing toggles are best-effort (TCC/SIP usually need System
  Settings → General → Sharing); set "Allow access for" to your user only, VNC password off.

Two boundaries gate access: the Tailscale ACL (`tag:mac → tag:mac` on 22/5900 — plus
UDP 60000-61000 for mosh, see Remote dev below — in `homelab-private`) restricts the
source to your own Macs, and sshd is key-only. Keep the router free of any WAN
port-forward for 22/5900 — that would bypass both.

**The mini cannot verify its own inbound SSH.** It holds no private key material at all
(`~/.ssh/*.pub` is empty) and the 1Password agent can't sign headlessly, so `ssh localhost`
fails by design — inbound auth is always the *connecting* machine's key. Verify this path
from the MacBook, never from the mini. Relatedly: `launchctl print system/com.openssh.sshd`
reporting `state = not running` is socket-activation idle, not a fault — check
`netstat -an | grep '\.22 .*LISTEN'` instead.

**Both work and personal secrets resolve headlessly on the mini** — the gate is
*tkrumm's* `Private` vault, not work-vs-personal. Personal: Hermes is cache-only since
2026-07-16. Work: `headless.iu.refs` deliberately allows careerpartner's `op://Private/*`
(Feuer's service identity, Artifactory, Jira, dashboard tokens) plus read-only
`se-prod`/`care-prod` DB passwords, each an owner-classified T2 exception justified at the
ref, and each with a named always-on consumer on the mini. So an agent there reaches work
credentials with no human present — a standing accepted exposure, enumerated in
`dotfiles-private/docs/security-review.md`. What stays human-only is tkrumm's `Private`
(Tailscale API key, the mini's own root password), refused by the seed unconditionally.
The cache is encrypted at rest and decrypted in memory, so "no plaintext secret on the
mini" still holds — that is a different claim from "biometric-gated". See Headless
secrets below.

## Headless outbound access (Mac mini only)

With no human present, anything authenticated by the 1Password SSH agent hangs on
the biometric prompt — so the mini never uses key auth outbound:

- **homelab + VPS → Tailscale SSH.** tailscaled on the servers authenticates the
  tailnet identity (`tag:mac` ACL); OpenSSH-level auth is `none`. `ssh homelab` /
  `ssh vps` work headless with zero keys, zero agents, zero prompts. No dedicated
  key exists for this path — a stolen mini holds no server credential; revocation
  is removing the device in the Tailscale admin.
- **GitHub → HTTPS + a secrets-cache-backed credential helper.** GitHub is off the
  tailnet, so this is the one outbound path that needs a headless credential:
  `make git-headless` (opt-in, cache-backend-gated) writes `~/.gitconfig-headless`,
  rewriting `git@github.com:` remotes to HTTPS and pointing the credential helper at
  `scripts/git-credential-secrets-cache`, which resolves `op://mini/github/token`
  from the secrets cache. This replaced the `gh` keyring token: that token expired,
  and `gh auth git-credential get` exits **0 with an empty body** on expiry, so git
  fell through to prompting and reported
  `could not read Username for 'https://github.com'` — which reads as a transport
  fault and sent the diagnosis chasing SSH agent forwarding instead. The cache-backed
  helper has no session dependency (no login keychain, no GUI session, no forwarded
  agent), so it resolves identically from a LaunchAgent, a `claude --bg` daemon that
  outlived its ssh connection, a herdr pane, and an interactive shell.
  The push credential is **`op://mini/github/token`, deliberately not Hermes's
  `op://hermes/github/token`** — the latter is read-only and returned 403
  `Permission to jkrumm/dotfiles.git denied`, which is what sent this whole path
  looking like a transport bug. Be honest about what the split buys: it does *not*
  contain a compromised agent, since anything on the mini with `secrets-run` reads
  every cached ref. It contains accident — Hermes's `.env.tpl` still points at the
  read-only token, so Hermes cannot push through its configured credential — and it
  lets the two rotate independently. Headless push verified end to end on
  2026-07-26 with a real `git push --dry-run` from the mini; resolvability is not
  the same claim (see the health-check note below).

Inbound is the reverse direction and a different key entirely: the MacBook reaches
the mini over plain OpenSSH (`make remote-access` above) because remote dev needs
agent/port forwarding and full-speed transfers that Tailscale SSH doesn't provide.
The full per-path access model + break-glass runbook lives in
`dotfiles-private/docs/access-model.md`.

## Tailnet ACL — as code

Moved out of `homelab-private` on 2026-07-27. The ACL is **tailnet-wide, not
homelab's**: it governs Mac↔Mac ssh/screen-sharing, mosh, the dev-port block,
rb, the phone and the e-reader. Living in homelab-private also put it on the one
machine that *cannot* apply it — the API key is `op://Private/Tailscale`, which
the mini's cache refuses unconditionally by design, so a change needed the repo
(mini) and the biometric human (MacBook) at the same time. `dotfiles-private` is
on the MacBook, which collapses that back to one machine.

Same split as serve: tooling here, declared state private.

```bash
make tailscale-acl-diff    # ALWAYS first — push overwrites the whole tailnet ACL
make tailscale-acl-pull    # fetch live INTO dotfiles-private/tailscale-acl.jsonc
make tailscale-acl-push    # validate + apply (prompts; ACL_PUSH_YES=1 to bypass)
```

`pull` **writes the file** — it previously only printed to stdout despite the
name, so "normalise the formatting with pull" silently did nothing and the local
file kept drifting in whitespace from the live ACL (every diff then rendered the
whole file, hiding real changes). It stages through a temp file, so a failed
fetch cannot truncate the source of truth.

**Every listening port needs a grant, and the failure is silent.** A port with
no grant does not refuse — it times out, with nothing in any log on either end.
That is how the dev-port work went missing for a full debugging cycle; rb's
dedicated `tcp:7730` grant encodes the same lesson.

## Inbound exposure — `tailscale serve` / Funnel

Serve bindings are imperative daemon state **keyed on the machine's MagicDNS
name**, so renaming a device orphans every binding at once and nothing in git
says what was supposed to be exposed. They are declared instead, per machine, in
`dotfiles-private/tailscale-serve.<machine>.conf` (private repo — it is an
exposure map, and `funnel yes` means the public internet):

```
make tailscale-serve         # converge live state onto the declared state
make tailscale-serve-check   # report drift, change nothing, exit 1 if any
```

Applying does `tailscale serve reset` first — a rename leaves bindings under the
old name that no per-port `off` can address — then re-adds every declared row.

Both current rows are deliberate: `:7730` (rb, tailnet-only) and `:8443`
(**Funnel — public internet**, the IU dashboard). The Funnel is gated by
`tag:iu-dashboard-funnel`, an *additive* single-device tag: Funnel is a
whole-device capability, so granting it to `tag:mac` would expose the work
MacBook too. Don't "clean up" that row — the tag exists to make it safe.

## Remote dev — MacBook → mini

The mini is the dev host; the MacBook is a thin client. Full plan and the
end-to-end mental model: **`docs/remote-dev.md`**. Four layers, none of which
substitutes for another — most design confusion here comes from collapsing them:

| Layer | Tool | Solves |
|-|-|-|
| Reachability | Tailscale | stable address, NAT traversal |
| Transport | **mosh** | keystrokes survive lid-close + roaming |
| Persistence + UI | **herdr** (on the mini) | panes stay alive, per-pane agent state |
| Service exposure | Caddy | dev servers over the tailnet with working WebSockets |

`herdr` owns the workspace model because it runs on the *mini* and survives
lid-close; **cmux is demoted to the window herdr renders in**, and tmux is the
fallback if herdr (pre-1.0) breaks. On the mini it runs as a **brew service**
(`RunAtLoad` + `KeepAlive`, same mechanism as colima) — manage it with
`brew services`, not `herdr server stop`, which KeepAlive would just undo.

There are **two mutually exclusive ways in**, and they trade different things —
persistence is not one of them, since the server and its panes live on the mini
either way. `config/zsh/remote-dev.zsh` gives each a one-command entry point:

- `dev [session]` → `mosh mini`, then `herdr` there — UDP, roams, survives
  lid-close *without reattaching*. mosh cannot multiplex, so it is always *one*
  connection into herdr, never N. Needs the ACL's `udp:60000-61000` grant or it
  hangs after a successful ssh handshake. Pins
  `--experimental-remote-ip=remote` so mosh reuses `ssh_config`'s
  `ControlMaster` instead of popping its own 1Password approval per launch
  (mosh's default proxy mode passes `-S none`, disabling multiplexing).
- `desk [session]` → `herdr --remote mini` — herdr's native attach over
  **ssh**, client-side on the MacBook (local keybindings, local image paste).
  TCP, so a roam or lid-close ends the connection and you re-run it.

`herdr attach` is not a command; sessions are `herdr --session <name>` /
`herdr session list|attach|stop`.

**`make remote-dev-doctor`** (`scripts/remote-dev-doctor.sh`) verifies this whole
path from the MacBook — reachability, ssh, ControlMaster reuse, agent
forwarding, mosh, and herdr — read-only, currently 10/10. It complements rather
than duplicates the mini-side heartbeat below: that one runs *on* the mini and
structurally cannot see inbound auth or the mosh UDP path, since the mini holds
no key material and cannot ssh to itself.

**`make herdr-setup`** wires the two halves. It installs herdr's first-party
Claude Code integration (`herdr integration install claude` → a SessionStart
hook at `~/.claude/hooks/herdr-agent-state.sh`), which is what makes a pane
report real agent status instead of `agent_status: "unknown"` — the entire
reason to prefer herdr over tmux. It then starts the **server only on the dev
host**, detected by the `cache` backend marker, the same signal `git-headless`
uses; a thin client gets the hook and no server.

Two non-obvious constraints, both load-bearing:

- The hook's settings entry lives in **`config/settings.template.json`**, not
  just wherever herdr wrote it. `make setup` merges settings.json with the
  template winning on `hooks`, so an entry added only by `herdr integration
  install` is deleted on the next `make setup`. The target re-runs the merge
  afterwards so the template's version is the one that survives.
- The tracked command is **guarded** (`test -f … && bash … || true`). herdr's
  own version calls the script unconditionally, which fails 127 on every
  session start on a machine where the integration was never installed. The
  script is `managed by herdr` and overwritten on reinstall, so it is
  deliberately not tracked in this repo — only the guarded call to it is.

### Notes — the `herdr-notes` plugin

A persistent markdown note **per workspace**, docked on the right edge, toggled
with **`prefix+e`**. Third-party (`alexarthurs/herdr-notes`, MIT), installed and
**commit-pinned** by `make herdr-setup` — `HERDR_NOTES_REF` in the Makefile, not
a tag, because tags move and `herdr plugin install` runs the repo's own
`cargo build --release`. Upgrading is a reviewed diff of that pin; there is no
`plugin update`, only reinstall. The step is guarded on `resolved_commit`, so
re-running `herdr-setup` doesn't put a Rust build in the path every time.

Installed vs *open* are separate, and this is the part that surprises:

- **Installed + enabled is permanent** — herdr registers plugins per user,
  globally, surviving server restarts and reboots. Nothing to re-run.
- **The pane is not.** The plugin ships actions, not keys; without the
  `[[keys.command]]` block in `config/herdr/config.toml` the only way in is
  `herdr plugin action invoke herdr-notes.open-notes`. The binding is the whole
  point of tracking it here.

Three facts about where it lives, all verified rather than assumed:

- **Plugin commands are spawned by the server**, so the pane and its note are
  always on the **mini** — the same note whether you came in via `dev` (mosh) or
  `desk` (client on the MacBook). Keys are handled client-side on the `desk`
  path, but the action is dispatched over the socket.
- **The shared config.toml is safe on a machine without the plugin.** herdr's
  keybind parser does not resolve plugin ids at load — `herdr config check`
  returns `ok` for an action id that does not exist (probed directly), so the
  key is inert rather than an error. The install is still unconditional in
  `herdr-setup`: it's inert until pressed, and gating it on the dev-host marker
  would leave the binding dead on a machine running herdr locally.
- **Notes are untracked, unsynced, unbackuped.** One `<workspace-id>.json` per
  workspace in herdr's `HERDR_PLUGIN_STATE_DIR` (created on first write, so it
  does not exist until you type something; `herdr plugin config-dir herdr-notes`
  prints only the config sibling). Keyed to the *stable* workspace id — renames
  keep the note, closing a workspace orphans the file. Scratch space, not the
  brain: anything worth keeping goes to `/brain`.

`~/.zshenv` is now managed too (`_setup-zshenv`, idempotent, appends rather than
symlinks — the vite-plus and cargo installers also append to that file). It is the
only file a non-interactive `ssh host -- cmd` sources (zsh's non-interactive
non-login path skips `/etc/zprofile`'s `path_helper`), and mosh depends on it to find
`mosh-server` when it launches over ssh before handing off to UDP.

`_setup-zshenv` now puts **`~/.local/bin`** on that non-interactive PATH too,
not just Homebrew — `claude`, `secrets-run`, and `imgcli` all live there and
none of them are Homebrew-managed, so remote automation no longer needs to
hand-prefix PATH to reach them. The target also strips the superseded
Homebrew-only block from machines that ran the earlier version, so re-running
`make setup` converges rather than duplicating.

Independent of all four layers: **`claude --bg` reparents to PID 1** as
`claude daemon run` and survives ssh/herdr/lid-close on its own (`claude agents`,
`claude attach|logs|stop <id>`). Use it for anything that must not die — it is
what bounds the risk of herdr being new. That risk is measured, not assumed:
`kill -9` on the herdr server brings the workspace back by name but with a new
`terminal_id`, so **a herdr crash restores the layout and loses every process
running in it**. Note `--bg` takes the positional prompt;
it conflicts with `-p`. Phone access is Claude Remote Control (official, no relay).

**Surviving independently is not the same as launching independently, and the
difference is silent.** Claude Code's Max credentials live in the **login
keychain**, which an ssh session cannot reach — so `ssh mini 'claude --bg …'`
starts a daemon that prints `Not logged in · Please run /login`, falls back to
*API Usage Billing*, and still lists healthy in `claude agents`. The herdr server
is a brew service under launchd inside the user's GUI session, so what it spawns
inherits keychain access. Verified both directions 2026-07-27. Anything on the
mini needing the login keychain (LaunchAgent, cron, script-spawned daemon) has
the same constraint: on the tailnet ≠ in the GUI session.

**`scripts/remote-dev.sh` (`rd`) is the layer above the four.** The transport
layers answer "how do I get a terminal"; `rd` answers "how do I put work on the
mini and check on it", which needs no terminal. It routes off the
`~/.config/secrets/backend` marker — local exec on the mini, one ssh hop from the
MacBook — so one command surface serves both machines:

| Command | Does |
|-|-|
| `repos [filter]` | repos on the host, branch + dirty count |
| `work <repo>` | herdr workspace + claude, **idempotent** (refocuses rather than stacking two agents on one checkout) |
| `rd bg <repo> '<task>'` | durable daemon, spawned *through* a herdr pane for the keychain reason above |
| `agents` | both lanes, deduped on session id |
| `rd read <agent>` / `rd say <agent> '…'` | watch / steer without attaching |

`work`, `agents` and `repos` get bare shorthands; `bg`, `read` and `say` stay
behind `rd` because those names are a zsh builtin, a zsh builtin and
`/usr/bin/say`. Commands take a repo **name**, never a path — the MacBook has no
project repos to point at, and `$HOME` differs between the machines, so
resolution happens on the host.

`config/ssh_config` carries the desk path: a `Host *` keepalive block, real
`ControlMaster` on `Host mini` (multiplexes herdr/cmux's several connections into
one handshake and one biometric approval), and `SetEnv TERM=xterm-256color` —
which fixes cmux #2969, doubled keystrokes when `TERM=xterm-ghostty` reaches a
host with no such terminfo. `_setup-ssh` creates `~/.ssh/cm`; ssh won't.

herdr layers its own ssh hardening on top for `--remote` only
(`[remote] manage_ssh_config = true`): a generated config that **includes
`~/.ssh/config` first** — so the values above still win — plus its own
per-attach control socket. The repo's `ControlMaster` still earns its place;
it covers plain `ssh`, `scp` and git-over-ssh, which herdr never touches.

## Collie — the phone control surface

[Collie](https://github.com/AltanS/collie) is a loopback-bound Bun bridge + PWA
that mirrors the herd on a phone: open a URL, see which agent is blocked, type
a reply. Third-party, installed and **commit-pinned** by `make collie-setup` —
`COLLIE_REF`/`COLLIE_VERSION` in the Makefile, same discipline as
`HERDR_NOTES_REF` and for the same reason (`plugin install` re-clones + builds
every time; upgrading is a reviewed diff of the pin, not `plugin update`,
which doesn't exist). Chosen over granting the phone raw ssh+mosh: no port-22
grant, no SSH key on a device that can be lost or stolen.

**It is remote shell access by design, not "just a web UI".** One bridge call
types arbitrary keystrokes into a live pane — Collie's own README says to
treat the URL like a root login, and that framing should not get softened by
how it looks (a phone-friendly PWA). Granting it is granting a shell.

**The real gate is the ACL, not `COLLIE_TRUSTED_USER`.** Every node on this
tailnet is tagged (`tag:mac`, `tag:phone`, `tag:client`, …), so `tailscale
serve` has no human login to inject into `Tailscale-User-Login` — the
trusted-user check cannot tell our own devices apart from each other. That is
why the `.env` leaves `COLLIE_TRUSTED_USER` unset and the grant is scoped to
`tag:phone` specifically. **`tag:client` (the two TVs and the tablet) must
never be granted** — a television driving coding agents is not a theoretical
failure mode once the check itself can't discriminate.

The `.env` (written once by hand, not templated — `make collie-setup` never
touches it) carries four settings, each closing a specific gap:
- `COLLIE_MULTI_SESSION=off` — the default `on` fronts **every** named herdr
  session through one URL; this pins the bridge to the primary session only.
- `COLLIE_PUBLIC_HOSTS=mini.<tailnet>.ts.net:8788,mini.<tailnet>.ts.net` — defeats
  DNS rebinding, and **both entries are required**. `isHostAllowed`
  (`bridge/server.ts`) matches the full `Host` header by exact string, and the
  browser sends the ported host once the tailnet front door isn't on 443 — so
  the bare name alone 403s every phone request while every loopback check still
  passes clean. Verified matrix: `<name>:8788` → 200, bare `<name>` → 200,
  `evil.example.com` → 403, `<name>:9999` → 403.
- `COLLIE_SKIP_SERVE=1` — **mandatory**, not a preference. `collie-ctl.sh`
  publishes itself imperatively (`tailscale serve --bg 8787`), but this repo
  owns serve as *declared* state (`## Inbound exposure` above) and
  `make tailscale-serve` runs `tailscale serve reset` first — an imperative
  binding is silently wiped on the next convergence. Collie stays
  loopback-only; the front door is the row in
  `dotfiles-private/tailscale-serve.mini.conf`
  (`8788  http://127.0.0.1:8787  no`). **Never funnel it.**
  The tailnet port is **8788, not tailscale serve's default 443**: on 443 the
  ACL grant would have to name the default port every future serve row lands on
  unless it says otherwise, silently sharing one grant with whatever gets
  published next — a dedicated port keeps the grant meaning exactly one
  service, permanently (same lesson as rb's dedicated `tcp:7730` grant). It
  also sits outside `7700-7799`, already granted `tag:mac → tag:mac` for dev
  servers, so reusing that range would hand collie to the work MacBook through
  an unrelated rule. An additive single-device tag (the `tag:iu-dashboard-funnel`
  pattern) was considered to narrow the grant's `dst` from `tag:mac` to the mini
  alone, and rejected: it requires re-tagging the device, and with a
  collie-only port nothing listens on 8788 on the work MacBook anyway. The
  bridge itself is still bound to loopback `127.0.0.1:8787` — only the
  `tailscale serve` front door moved.
- `COLLIE_HOST=127.0.0.1` — no interface binding beyond loopback; `serve`
  terminates TLS on the tailnet and proxies in.

**The LaunchAgent exists because macOS has no systemd.** `collie-ctl.sh`
writes a systemd unit on Linux and falls back to a bare `nohup` on macOS,
which does not survive a reboot — `collie/com.jkrumm.collie.plist.template`
(rendered by `make collie-setup`, `RunAtLoad` + `KeepAlive`, same always-on
shape as the herdr brew service) closes that gap. One trap already cost a
debugging cycle here: invoking the plugin action through herdr
(`herdr plugin action invoke start --plugin herdr.collie`) fails with
`error: bun not found`, because a herdr-server-spawned command does not
inherit Homebrew's PATH — the same class of failure as the
mosh-server/`~/.zshenv` gap already documented above. The plist pins `PATH`
explicitly for exactly that reason.

**The plist sources the `.env`, and must.** The worse trap sits next to the PATH
one and is silent where PATH is loud. The bridge reads `process.env` only
(`bridge/config.ts`) and never parses `.env` itself — on Linux systemd feeds it
in with `EnvironmentFile=-`, and launchd has no equivalent. A plist that execs
`bun` directly therefore starts a bridge with `COLLIE_PUBLIC_HOSTS`,
`COLLIE_MULTI_SESSION` and `COLLIE_SKIP_SERVE` **all unset** — every hardening
setting above quietly off, DNS-rebinding guard included — while `launchctl list`
shows status 0 and the UI works perfectly. So `ProgramArguments` runs
`bash -c 'set -a; . .env; set +a; exec bun …'` instead. It was caught only
because the acceptance check is behavioural: a spoofed `Host` header must still
return 403 after any change to how the bridge is started. It had gone back to
200. Re-run that assertion, not just `launchctl list`, whenever this plist or
the `.env` moves.

| Command | Does |
|-|-|
| `make collie-setup` | Dev-host only (gated on the `cache` backend marker): install/refresh the pinned plugin, render + load the LaunchAgent |
| `make collie-status` | Read-only: LaunchAgent state, bridge health, `tailscale serve status` |
| `make collie-teardown` | Unload the LaunchAgent, uninstall the plugin — leaves `tailscale-serve.mini.conf` untouched (declared state, not this target's to change) |

Upgrading is moving `COLLIE_REF` in a reviewed diff — there is no
`plugin update`.

**Monitoring is opt-in and needs one browser step.** Collie reports to its own
Kuma monitor, `MacMini Collie - Push` (declared in
`homelab/uptime-kuma/monitors.yaml`), pushed by the existing
`com.jkrumm.devhost-health` LaunchAgent — see the heartbeat section below for
why it is a separate monitor rather than a sixth component. To wire it:

1. Create a **Push** monitor named `MacMini Collie - Push` in the Uptime Kuma
   UI, group `Local` (push monitors cannot be created by `uk-sync` — see below).
2. Copy its push URL into `~/.config/uptime-kuma/collie-push-url`, `chmod 600`.
3. `make uk-sync` from `homelab` to apply the declared interval/retries.

Until step 2 the collie push is skipped silently, which is deliberate: a machine
that never ran `collie-setup` has no collie and must not fail the heartbeat.

## Dev-host health heartbeat (mini only)

**Two** Uptime Kuma push monitors, one agent. `MacMini Dev Host - Push` (group
`Local`) is the composite and covers **five** components: tailscaled, sshd,
herdr, mosh (both the binary and its Application Firewall allowlist membership)
and the GitHub push credential. `MacMini Collie - Push` is separate — see
**One scheduler, two monitors** below for why. Both are driven by
`scripts/devhost-health-check.sh` via the `com.jkrumm.devhost-health`
LaunchAgent every 5 minutes. Opt-in per machine like `remote-access`:

| Command | Purpose |
|-|-|
| `make devhost-health-setup` | Install the agent. Refuses unless the push URL exists, and prints the ordered runbook to create it. |
| `make devhost-health-check` | Run once, print per-component status. |
| `make devhost-health-teardown` | Unload + remove. |

**Push, not probe** — the ACL grants `tag:homelab → tag:vps` but *not*
`tag:homelab → tag:mac`, so Uptime Kuma physically cannot reach the mini.
Opening an inbound grant purely for monitoring would be new attack surface for a
check the mini can report on itself over the already-granted outbound path. Same
pattern as `MacMini Secret Seed - Push` and the Hermes monitors.

**One monitor, not five.** herdr/sshd/tailscaled/mosh all fail together when the
mini sleeps or drops off the tailnet; five monitors would be five simultaneous
pages saying one thing. The failing component is named in the push `msg`, which
is where the diagnosis belongs. `check_git_push` is the one deliberate exception
— a token expires while the host is perfectly healthy — folded in anyway because
a second monitor wasn't worth it for one component.

**One scheduler, two monitors.** Collie is deliberately *not* a sixth component,
and the reason is the same rule pointed the other way: it genuinely does **not**
fail with the other five. It's opt-in per machine and can be absent, down or
mis-hardened while herdr/sshd/tailscaled/mosh are all fine — so folding it in
would mark the dev host DOWN and implicate four healthy components. It gets
`MacMini Collie - Push` instead. What it does *not* get is its own agent: the
existing LaunchAgent already runs every 300s, so a second one would be pure
duplication. Only the push target differs, and the URL file's absence is silent
by design so a machine without collie never fails the script.

Its check asserts **behaviour, not liveness** — the bridge answers 200 on
loopback *and* a spoofed `Host` header must return 403. That second assertion is
the whole point: collie's hardening lives in a `.env` that launchd does not load
on its own, so a mis-started bridge passes every liveness probe with its
DNS-rebinding guard silently gone. `launchctl list` says status 0 and the UI
works. Only the behavioural check sees it.

**Creating a push monitor is still a manual browser step**, and an earlier
version of this file claimed otherwise. `uptime-kuma-api` 1.2.1 cannot create
push monitors against UK 2.x (`homelab/uptime-kuma/sync.py` says so at the call
site), and could not obtain the push token regardless — Kuma generates that
server-side. `make uk-sync` manages an *existing* push monitor's
interval/timeout/retries. So: create it in the UI, copy the push URL into a
chmod-600 file, then let uk-sync own its settings. Budget one browser visit per
new monitor rather than assuming it's declarative.

**The heartbeat asserts resolvability, not push rights** — and says "credential
ready", not "push ready", on purpose. It makes no network call to GitHub, because
at a 300s cadence with `maxretries 0` a GitHub outage or a flaky link would page
as "dev host down". The stronger claim costs a real `git push --dry-run`, so it
lives in the on-demand `make remote-dev-doctor` instead. That split has already
earned itself: on 2026-07-26 the credential resolved fine on the mini while the
deployed helper still pointed at Hermes's read-only token, and only the doctor's
dry-run saw it.

The push token lives in a chmod-600 `~/.config/uptime-kuma/devhost-push-url`,
not 1Password, so monitoring never depends on the secrets cache being seeded — a
stale cache would otherwise take the monitor down with it. Kuma's monitor
interval (600s) must stay longer than the agent's cadence (300s) so one skipped
run doesn't page. **`maxretries` must be 0**: time-to-DOWN is
`interval + maxretries × retry_interval`, so inheriting the default 3 would page
at 40 minutes, not 10 — the other push monitors in `monitors.yaml` still do.
Three traps worth remembering, all hit while building this:
`set -o pipefail` + `grep -q` turns a SIGPIPE into a false failure; `op run`
masks injected secret values in its *own* stdout, so a remote script that prints
a full push URL returns the domain as `<concealed by 1Password>` (print the token
alone and assemble the URL locally); and a
LaunchAgent has no shell aliases — `tailscale` is an alias to the app bundle and
must be called by absolute path.

## Battery charge limiter (MacBook only)

The MacBook holds its charge at a cap (default **80%**) to slow Li-ion wear, via
[`batt`](https://github.com/charlie0129/batt) (charlie0129) — a root LaunchDaemon
(`/Library/LaunchDaemons/cc.chlc.batt.plist`, started by `brew services`) that
controls the SMC and reads its cap from `$(brew --prefix)/opt/batt/bin/batt`'s
config (`{brew}/etc/batt.json`). The daemon runs with `--always-allow-non-root-access`,
so `batt limit` needs no sudo after setup.

The **binary** ships via the Brewfile (declared/audited like everything else; it's
keg-only, hence called by its `opt/batt/bin` path), but it's harmless on a
battery-less Mac. The **daemon + cap are opt-in per machine** — like `remote-access`,
not in the default `setup` chain — and every target self-gates on the machine having
an internal battery (`pmset -g batt | grep InternalBattery`), so they no-op on the
Mac mini.

`make batt-setup` wires three things on a MacBook (idempotent): the daemon + cap, a
daily-reset LaunchAgent, and Raycast control.

- **Daily auto-reset.** `battery/com.jkrumm.batt-reset.plist.template` → a user
  LaunchAgent that runs `batt limit 80` at **09:00** daily (`RunAtLoad` false, so
  installing it never clobbers a live boost). This is what makes a 100% boost
  *temporary* — it expires the next morning. Changing the resting default means
  editing both this plist's hardcoded `80` and the Makefile `LIMIT ?= 80`.
- **Raycast control.** Self-authored **Script Commands** (no extension/build, no
  deps — `raycast/battery-{limit,status}.sh`) symlinked as `~/.raycast-scripts`.
  "Battery Limit" offers an 80/90/100 dropdown; "Battery Status" shows state.
  One-time: point Raycast at the dir (Settings → Extensions → Script Commands → Add
  Directories → `~/.raycast-scripts`).

| Command | Purpose |
|-|-|
| `make batt-setup` | One-time per MacBook: daemon + 80% cap + daily-reset agent + Raycast symlink. `LIMIT=N` to set a different initial cap. |
| `make batt-limit LIMIT=100` | Change the cap now (or just flip it in Raycast). Default `LIMIT=80`. |
| `make batt-status` | Show charging state + current limits. |

To remove entirely: `sudo brew services stop batt`,
`launchctl unload ~/Library/LaunchAgents/com.jkrumm.batt-reset.plist`,
`rm ~/.raycast-scripts`, then drop `brew "batt"` from the Brewfile (`brew uninstall batt`).

## Secrets Strategy

Two 1Password accounts are configured:
- **`tkrumm`** — personal account, used in `~/SourceRoot/`. Always pass `--account tkrumm` to `op` CLI.
- **`careerpartner`** — work account, used in `~/IuRoot/`. Always pass `--account careerpartner` to `op` CLI.

`make setup` uses `--account tkrumm` (biometric/session token via Touch ID).

`ANTHROPIC_API_KEY` is intentionally **not exported** — Claude Code falls back to the subscription when the key is absent. Exporting it would cause Claude Code to bill API credits instead.

**API keys** cached in macOS Keychain by `make setup`:
- `CLAUDE_SDK_API_KEY` + `CLAUDE_SDK_BASE_URL` — from `op://common/anthropic/API_KEY` and `BASE_URL`. Used for API offloading via `claude -p`.

**Chrome DevTools MCP** — registered globally with deferred tool loading (~400 tokens overhead). Used exclusively via `/browse` skill (haiku fork) to isolate expensive MCP responses from main context.

**MCP-per-project policy** — keep project MCPs minimal. Global servers are only `sideclaw`, `chrome-devtools`, and `research-gateway` (the remote research MCP), all deferred (names only in context, schemas via ToolSearch). The **only** repo running real project-level MCPs is `prometheus-scripts/jupyter` (db/datadog/marimo, in a git-ignored `.mcp.json`). `epos_fe.spa-orchestrator`'s `.mcp.json` (nitrox + Figma Desktop) is declarative IDE config, not always-on. No other repo has or needs project MCPs — don't add one without a deliberate reason. (Note: jupyter's datadog block hardcodes keys in the git-ignored file; the sibling `db` server uses `op run` — migrate datadog to `op run` when convenient.)

**CodeRabbit CLI** — requires one-time auth: `coderabbit auth login` (GitHub OAuth). Free tier: 3 reviews/hour. Used by `/review` and `/ship` skills.

**New machine setup:**
1. Install 1Password + enable CLI integration (Settings → Developer → Enable CLI)
2. `make setup` — will fail fast with instructions if 1Password isn't ready

**Headless secrets (agent host, no human at the keyboard).** `secrets-run` is a
drop-in `op` shim: apps keep their own `.env.tpl` of `op://` references and run
via `secrets-run run --env-file=<tpl> -- <cmd>` (mirrors `op run`); only the
backend differs per machine (`~/.config/secrets/backend`). Tooling
(`scripts/secrets-run`, `scripts/secrets-seed.sh`, this repo's Makefile targets)
lives here; the data half — `headless.refs` (the explicit list of refs the mini
may cache), the encrypted cache, `.sops.yaml` — lives in the private
`~/SourceRoot/dotfiles-private` repo (see its `docs/design.md` for the full model
and runbook). Two backends:
- **`op`** (MacBook) — `secrets-run` passes through to live `op` (biometric); native output redaction.
- **`cache`** (mini) — `secrets-run` resolves each `op://` ref from a single SOPS+age cache (`op://ref → value`, decrypted in memory), injecting only the template's declared keys and masking resolved values from piped output. No plaintext on disk, no 1Password/network call, fails closed on any missing ref.

Ritual: `make secrets-seed` reads `dotfiles-private/headless.refs`, resolves every
ref through 1Password (biometric, one pass), and reseals the cache — run from the
mini (present-human) or the MacBook whenever secrets rotate or the cache goes
stale (`secrets-run` warns after 14 days). varlock is retained only as the
`dotfiles-private` pre-commit leak scanner, not in the seed/runtime path.

## Claude Code Launchers

Three ways to start an agentic coding session — `c`/`ca` defined in
`config/zsh/claude.zsh`, `oc` in `config/zsh/opencode.zsh`:

| Command | Backend | Model | Setup |
|-|-|-|-|
| `c` | Claude Max subscription | Opus/Sonnet/Haiku via `/model` | Native — full skills/hooks/subagents/CLAUDE.md |
| `ca` | Local LiteLLM bridge (`:4000`) | DeepSeek-V4-Pro (hardcoded default) | Identical to `c` — same `~/.claude` config dir, only auth + model change |
| `oc` (`opencode`) | IU unified endpoint | whatever `opencode.json` configures | Separate harness — own plugin/hook/agent system, see below |

`ca` exists so the exact same Claude Code setup (skills, hooks, native subagents
like `@implementer`) runs off Max — at work, or to spare quota — billed as cheap
IU/DeepSeek tokens instead. It's deliberately inflexible: no WebSearch/WebFetch
(the bridge can't serve those Anthropic-only tool calls), and no built-in model
switching — change the `--model DeepSeek-V4-Pro` default in the file by hand if
needed. Rationale: `modelpick/docs/decisions/ca-launcher.md`.

An already-open shell keeps whatever `c`/`ca` definition it loaded at startup —
`source ~/.zshrc` (or open a new terminal) after editing `claude.zsh`.

`usage-tracker` (`~/SourceRoot/usage-tracker`) ingests all three automatically —
`ca`'s billing classification, pricing, and dedup against the bridge's own
request log all fall out of its existing `claude-code`/`litellm` collector
split, no extra wiring needed.

## OpenCode (Claude Code fallback)

OpenCode CLI is wired as a fallback for when the Claude Code Max subscription is
exhausted. It runs against the **IU unified endpoint** using the same credential
as the Agent SDK (`op://common/anthropic`).

- **Two providers** in `config/opencode/opencode.json` (both keyed off one IU credential):
  - `iu` — OpenAI-compatible gateway (`…/openai/v1`). Holds the **default `iu/DeepSeek-V4-Pro`** (coding/smart, EU — Azure Spain) and **small `iu/DeepSeek-V4-Flash`** (fast/cheap, EU — Azure Spain), plus the zoo: Kimi-K2.6 / K2.5 / k2.7-code, GPT-5.5, Gemini 3.1 Pro / 3.5 Flash / 2.5 Pro, GLM-5.2, MiniMax-M3, Qwen3-Coder-480B, Qwen3.7-Max, MiMo-V2.5-Pro, Nemotron-3-Ultra, Mistral-Medium-3 (the last four single-backend).
  - `iu-anthropic` — native Anthropic API (`…/anthropic/v1`), best Claude fidelity (prompt caching): `claude-opus-4-8`, `claude-opus-4-6`, `claude-sonnet-4-6`, `claude-haiku-4-5`.
- **Reliability — the model alias is the host selector.** Each id maps to one or more backend "sinks" (`owned_by`); more = more redundant. `claude-opus-4-8` / `claude-opus-4-6` (3 backends each, current top tier); `Kimi-K2.5` (2 backends) steadier than `Kimi-K2.6` (1 backend, Sweden Central, throttle-prone); `glm-5.2` / `minimax-m3` (2 backends) replaced the 1-backend `GLM-5` / `MiniMax-M2.5`. The current defaults `DeepSeek-V4-Pro`/`DeepSeek-V4-Flash` serve from Azure Spain (EU) — run `/iu-endpoint` for their live backend counts. The AI SDK auto-retries 429s. Run `/iu-endpoint` for live health + backend counts. There is **no** `/bedrock` passthrough (404) — Bedrock is only an internal backing; `/azure`, `/gemini`, `/replicate` transports exist but `/openai/v1` already fronts the richest catalog. `*-codex` models return empty over chat-completions (responses API only) — don't configure them.
- **EU data residency / GDPR.** Serving region is exposed in response headers (`x-ms-region`, `x-middleware-forwarded-server`); `/iu-endpoint` shows it as an EU/US column. Verified **EU**: `DeepSeek-V4-Pro` / `DeepSeek-V4-Flash` (Azure Spain Central), `Kimi-K2.6` (Azure Sweden Central), the `*-eu` Claude aliases **over the openai-compat transport** (route to the "GDPR ONLY" gateway), `gpt-5.5` (Sweden). **NOT EU-safe**: `Kimi-K2.5` (Nebius + Azure US-East-2), native `iu-anthropic` Claude (can route US), Nebius-served models (`GLM-5`, `DeepSeek-V3.2` — region not exposed, shown `?`). Default is `iu/DeepSeek-V4-Pro` so the fallback is EU by default. Hermes Kimi switch: `.claude/skills/iu-endpoint/hermes-kimi-handover.md` (K2.6 primary + `claude-sonnet-4-6-eu` fallback).
- **Secrets:** `opencode.json` contains no key and no hostname — only `{env:IU_*}` placeholders. The `opencode()` wrapper in `config/zsh/opencode.zsh` injects `IU_API_KEY` + both base URLs into the OpenCode process **only** (not the interactive shell), read just-in-time from the existing `claude-sdk-*` Keychain entries. Both base URLs are derived from `claude-sdk-base-url` (`…/anthropic` → `…/anthropic/v1` and `…/openai/v1`), so no new Keychain entry or 1Password field is needed.
- **Why `IU_*` and not `ANTHROPIC_*`:** exporting `ANTHROPIC_*` would push Claude Code itself onto IU API billing instead of the Max subscription. Distinct names keep Claude Code on the subscription; OpenCode is the deliberate fallback.
- **CLAUDE.md compatibility:** `instructions` loads `~/.claude/CLAUDE.md`, the always-on global rules listed individually, and per-project `.claude/rules/*.md`; per-project `CLAUDE.md` auto-loads via OpenCode's native fallback. A minimal global `AGENTS.md` takes control of the global slot (and disables the duplicate `~/.claude/CLAUDE.md` auto-fallback). OpenCode ignores `paths:` frontmatter, so the path-scoped framework rules (`react-best-practices`, `tanstack-*`, `elysia`) are deliberately excluded from the global list; put them in a project's `CLAUDE.md`/`.claude/rules/` when needed.
- **Usage:** `oc` (TUI) · `ocr "<prompt>"` (one-shot) · `opencode -m iu/DeepSeek-V4-Pro …` (pick model). Adding a model = edit `opencode.json`, no `make setup` needed (symlinked).

## Editing Rules

**Adding a global skill:** create `skills/{name}/SKILL.md` here, then `make setup` — it gets symlinked into `~/.claude/skills/{name}/` and loads in every session.

**Adding a per-repo (dotfiles-only) skill:** create `.claude/skills/{name}/SKILL.md` here directly (committed, no symlink). Loads only when Claude starts inside this repo. Used for skills that manage this repo's infrastructure (e.g. `iu-endpoint`).

**Adding a global rule:** create `rules/{name}.md` here. The entire `rules/` dir is symlinked to `~/.claude/rules/`. Rules without `paths:` frontmatter load every session. Rules with `paths:` load lazily.

**Skills scope:** global skills load everywhere (SourceRoot, IuRoot, anywhere) via `~/.claude/skills/`. Workspace-specific behavior (e.g. SourceRoot vs IuRoot 1Password account) is handled inside the skill via the `op_account_for_cwd` helper or explicit `$PWD` guards.

**Editing a hook:** hooks are symlinked live into `~/.claude/hooks/`, so a change
takes effect on the *next tool call* — there is no install step and no staging. Run
**`make hooks-test`** (`bun test hooks/`) after any edit. `docker-makefile.ts` is
covered because it once blocked `grep -n 'foo\|docker-socket' Makefile`: it regexed
the raw command string, so the `|` inside the quoted grep pattern read as a pipe and
`docker-socket` read as the binary. It now tokenizes with quote/escape state and only
inspects tokens in command position. When adding a hook that gates commands, prefer
the same shape — a mention is not an invocation, and a false block trains you to
distrust the hook.

**settings.json changes:** update `config/settings.template.json`, then `make setup`
to merge into the live file. Never edit the live settings.json for persistent changes.

## Debug Logs

Structured JSONL logs at `~/.claude/logs/YYYY-MM-DD.jsonl`. Written by `hooks/notify.ts` and `scripts/fetch_usage.py`. 3-day auto-cleanup on every invocation.

**Query examples:**
```bash
# All events today
cat ~/.claude/logs/$(date +%Y-%m-%d).jsonl | jq .

# Hook stop decisions only
cat ~/.claude/logs/$(date +%Y-%m-%d).jsonl | jq 'select(.event == "stop_decision")'

# fetch_usage errors
cat ~/.claude/logs/$(date +%Y-%m-%d).jsonl | jq 'select(.src == "fetch_usage")'
```

**Key events to check when debugging:**
- fetch_usage broken → `fetch_error` with `type` field shows which exception class failed
- Notification routing → `received` shows which event fired with cwd/session context

## Terminal Setup

**cmux** (`/Applications/cmux.app`) is the primary terminal — a macOS-native multiplexer built on top of Ghostty. It is **not tmux**. cmux reads `~/.config/ghostty/config` for terminal rendering (same syntax as Ghostty) and stores its own app preferences (appearance mode, sidebar, etc.) in macOS defaults under `com.cmuxterm.app`.

**Scope note (2026-07-26):** cmux is a *client-side* app — it runs on whichever Mac you're
sitting at and dies with it. For remote dev on the mini it is deliberately **not** the
workspace owner; herdr is, because herdr runs on the mini and survives lid-close (see
*Remote dev* above). Locally cmux is still the full multiplexer. One cross-cutting gotcha:
cmux exports `TERM=xterm-ghostty`, which produces doubled keystrokes on any SSH target
lacking that terminfo (cmux #2969) — `config/ssh_config` pins `SetEnv TERM=xterm-256color`
to neutralise it.

**Config files (two separate files, both managed in dotfiles):**
- `~/Library/Application Support/com.mitchellh.ghostty/config` — **primary cmux config** (font, theme, cursor, padding). This is what cmux actually reads.
- `~/.config/ghostty/config` — shell integration + option key settings only; lower priority

**Theme auto-switching:**
- cmux app chrome: `appearanceMode = system` (stored in plist — follows macOS appearance)
- Terminal colors: `theme = dark:one-dark,light:one-light` in the cmux config above
- Theme files: copied (not symlinked) to `~/.config/ghostty/themes/` — cmux has a bug where it skips symlinked theme files
- Claude Code: `c()` in `claude.zsh` writes `theme` key to `~/.claude.json` via `jq` on each launch

## The look: One Zinc terminal, One Dark/One Light herdr chrome

Three programs paint one screen and none of them can see the other two. herdr
paints its **chrome** (sidebar, borders, tab row) from its own built-in theme;
the outer terminal paints **pane content** from its ANSI palette; starship
paints the **prompt** inside that. All three follow macOS appearance.

**`make theme` applies all three and reloads herdr live.** Run it on both
machines — it is a subset of `make setup`, idempotent, and safe to repeat.
Applying only one layer is how they drift apart.

| Layer | File | Setting |
|-|-|-|
| Terminal | `config/ghostty/config.appsupport` (+ `config`) | `theme = dark:one-zinc-dark,light:one-zinc-light` |
| herdr | `config/herdr/config.toml` | `name = "one-dark"`, `auto_switch = true`, `light_name = "one-light"` |
| Prompt | `config/starship.toml` | ANSI color *names* — resolve through whichever is active |

**One Zinc = Atom One's hues, muted to ~72% saturation, on basalt-ui's zinc
surfaces.** Two design systems used for what each is good at: basalt-ui's zinc
ramp is a true neutral (no blue cast like One Dark's `#282c34`, no plum like
Catppuccin's `#1e1e2e`), while Atom One's hues are what herdr's chrome already
renders. Backgrounds are middle-ground on purpose — `#1f1f23` dark (between
basalt's zinc-900 `#18181b` and zinc-800 `#27272a`), `#f2f2f5` light (basalt's
own `--vx-surface-bg`). **Never black, never white**; `#09090b` was tried and
lasted one commit.

How the sidebar actually renders — measured in a pty capture with three
workspaces, one focused, per theme, not assumed:

| Theme | Focused row | Unfocused rows |
|-|-|-|
| `one-dark` | bg `#282C34`, fg `#ABB2BF`, **bold** | no bg, fg `#969CA8`, regular |
| `one-light` | bg `#F5F5F6`, fg `#383A42`, **bold** | no bg, fg `#686B77`, regular |

Five decisions that are not taste:

- **The focused row has three cues, not one** — background, brighter foreground,
  and bold. The sidebar is never painted in either theme, so that background
  lands on the *terminal's* background, but because it is one cue of three it is
  allowed to be subtle: currently 1.17 dark, 1.03 light. **An earlier revision
  believed the background was the only cue and drove the terminal to `#09090b` to
  maximise that one ratio.** That is where the black-black terminal came from.
  Verify with a pty capture before trading anything else away for it.
- **`[theme.custom]` cannot fix this per-mode.** herdr does expose the sidebar
  colours (`panel_bg`, `surface0/1`, `surface_dim`, `overlay0/1`, `accent`,
  `text`, `subtext0`, `mauve`, `green`, `yellow`, `red`, `blue`, `teal`, `peach`)
  — the focused row is `surface_dim` — but it is a **single global block applied
  to whichever theme is active**, so it cannot hold one value for light and
  another for dark. No single colour is a highlight on both a dark and a light
  canvas. That is why the *terminal* background, which ghostty does switch per
  mode, stays the differentiator.
- **`nord`, `dracula` and `vesper` are not options** — herdr ships no light
  sibling for any of them, so `auto_switch` has nothing to switch to.
- **herdr does not use its `terminal` theme** (inherit the host ANSI palette),
  which is the obvious-looking choice. It emits only basic ANSI codes there, so
  palette 8 would have to serve as both the row highlight and the comment gray;
  and on the `dev` path herdr renders *on the mini* and would have to negotiate
  the palette through mosh's UDP proxy. A named theme needs no negotiation and
  looks identical over both transports.
- **starship uses ANSI names, herdr's one override uses hex — asymmetric on
  purpose.** starship's names resolve through the active palette, so they follow
  the switch for free. herdr's inline sidebar token styles accept strict hex
  only, so the single `branch` override (`#358a5c`) has to clear both surfaces it
  can land on — the sidebar is transparent in both themes, so those are the
  terminal's two backgrounds: 3.86 on `#1f1f23`, 3.80 on `#f2f2f5`, the best
  worst-case of the greens tried. It is styled at all because herdr renders
  `branch` in the theme's mauve slot, and that is universal — `#C678DD` one-dark,
  `#CBA6F7` catppuccin, `#BB9AF7` tokyo-night, `#B48EAD` nord. **No theme choice
  avoids the purple; only an explicit style does.** `mauve` itself is left
  unoverridden — this is the only place it showed up, and a targeted override
  beats a global one whose other uses are unknown.

Ghostty theme names are **exact filenames**. `one-zinc-dark` resolves because the
file is named that; bundled themes with spaces and capitals must be written in
full (`Catppuccin Mocha`, never `catppuccin-mocha`, which errors and falls back
to no theme at all). Verify with `ghostty +validate-config --config-file=…` —
but note it validates *syntax*, not theme **values**: a bad hex falls back to
defaults silently, which is why `make theme` also asserts the theme files exist
and are non-empty.
- **Font is `JetBrainsMono Nerd Font Mono`, the "Mono" family specifically.**
  herdr's state icons and starship's glyphs are Nerd Font codepoints (tofu
  without it), and the Mono variant forces single-width glyphs so an icon can't
  push herdr's column-aligned sidebar rows out of alignment. The plain
  `font-jetbrains-mono` cask stays declared because the Nerd Font one does *not*
  register a family named "JetBrains Mono" — dropping it would silently break
  any editor still configured with that name.

Applying a herdr config change to a live server without dropping panes:
`herdr server reload-config` (or `prefix+shift+R` inside herdr). `make
herdr-setup` does it for you. Validate first with `herdr config check` — it
catches unknown keys and TOML errors, but **not** bad theme *values*, which
fall back to defaults silently.

## Key Technical Facts

- Skills route via four modes: **inline** (no `model:` frontmatter — run on session model), **subprocess** (skill body shells `claude -p` with Keychain API key), **MCP/sideclaw** (registered tool with JSON schema + heartbeat + quota routing), **fork** (`context: fork` — wrap deferred MCP tools). See global CLAUDE.md `Token Efficiency` for the decision tree.
- `c()` in `config/zsh/claude.zsh`: writes Claude Code theme to `~/.claude.json`, then invokes `claude --dangerously-skip-permissions`. No `--plugin-dir` — global skills load from `~/.claude/skills/` automatically.
