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
mounts), pins the `colima` docker context, registers the **brew service** so it's
always-on and auto-starts at login, and installs the `com.colima.docker-socket`
LaunchDaemon (see **Docker socket** below).

**That brew service is `RunAtLoad` + a REPAIRED `KeepAlive`, and the repair is
load-bearing.** Homebrew generates the plist with `KeepAlive { SuccessfulExit => true }`
— restart only on a **zero** exit. `colima start -f` runs the VM in the foreground, so
exit 0 means "shut down cleanly" and non-zero means "failed to start": the condition is
inverted against what you want. A dirty Lima image after an unclean shutdown therefore
leaves Docker down until a human logs in, with nothing checking `docker info` and
nothing paging. `{ Crashed => true }` is **not** the fix — launchd's `Crashed` means
death by *signal*, not a non-zero exit.

`_setup-colima` converges the plist onto bare `KeepAlive => true` plus
`colima/colima-start.sh`, a bounded-retry wrapper (5 fast attempts, then a 600 s
cool-off, never latching off permanently — on a headless host the cause is often
transient and self-clearing). Bare `KeepAlive` without the wrapper turns a persistently
broken image into a full Lima VM boot attempt every 10 s forever. **Brew REGENERATES
this plist on every `brew services start/restart` and every `brew upgrade colima`, and
the revert is silent** — same trap as the Caddy DNS module. Every `colima-*` target
re-converges afterwards, and `make colima-status` asserts the boot path rather than
just the running VM.

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

**Do NOT "fix" `brew services list` showing `caddy none` and `dnsmasq none`.** It is a
**reporting artifact**, not a stopped service: `brew services` invoked without sudo can
only enumerate `gui/501`, and both of those live in the `system` domain. Its own output
gives the tell — the `User` column says `root` while `File` is blank.
`launchctl print system/homebrew.mxcl.{caddy,dnsmasq}` shows both `state = running`
(verified 2026-07-31: PIDs 91368 and 549). Starting either with `brew services start`
creates a **duplicate user-domain job fighting the root one for :443**. `batt none` is
also correct — the mini has no battery.

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

## Boot-path plists: two ways an edit silently reverts

Both were hit on 2026-07-31 and neither errors.

- **`launchctl kickstart -k gui/501/<label>` does NOT re-read the plist.** It restarts
  the process from launchd's *cached* job definition. The hermes gateway came back
  healthy on the **old** PATH and `launchctl print` reported it running — the fix
  looked applied and was not. Only `bootout` + `bootstrap` reloads the file. Proven
  with a throwaway agent: edit the plist, `kickstart -k`, and the job re-runs the old
  argument string; `bootout` + `bootstrap` runs the new one. Expect
  `Bootstrap failed: 5: Input/output error` while the old job is still in
  `state = SIGTERMed` — wait for the label to disappear from the domain
  (`launchctl print` → `Could not find service`), then bootstrap.
- **`ai.hermes.gateway.plist` is generated by Hermes itself**
  (`hermes_cli/gateway.py:generate_launchd_plist`), from the **invoking shell's**
  `os.environ["PATH"]` — which is how a dead `fnm_multishells/<pid>` dir and two
  `$TMPDIR/cmux-cli-shims/…` paths ended up baked into a boot-time service.
  `launchd_plist_is_current()` **masks the PATH string** (`__HERMES_PATH__`) but
  compares every other line verbatim, so a hand-fixed PATH survives — while adding an
  XML comment of your own marks the file stale and makes the next gateway restart
  rewrite the whole thing from a shell env. The corrected plist therefore carries only
  the generator's own comment. Verify after any edit: `launchd_plist_is_current()` must
  return `True` (it does, checked 2026-07-31).

**Obsidian starts at login via `make obsidian-autostart`** (dev-host gated on the
`cache` backend marker). It is a hard agent dependency, not an app preference: `/brain`
and Hermes's obsidian skill both go through `obsidian-cli` (`/usr/local/bin/obsidian` →
the app bundle), and `obsidian-cli` is a **client of the running app**, not a standalone
tool — it talks to a socket at `~/.obsidian-cli.sock` and exits 1 with "please make sure
Obsidian is running" when the app is down. A closed Obsidian is a closed agent door. Yet
it was not a login item at all, and the running instance had been started by hand 2.5
days after the previous boot. `ProgramArguments` is `open -a Obsidian` and there is **deliberately no
`KeepAlive`**: an agent exec'ing the binary bypasses LaunchServices, and with
`KeepAlive` it respawns the app the instant a human quits it.

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
off`). Auto-*update* (metadata refresh) stays on.

### Upgrading — `make brew-upgrade`

Auto-*upgrade* (unattended `brew upgrade`) stays off, but **not for the reason
this file claimed for months**. It said "auto-upgrade is the npm-style risk",
which is a dependency-hygiene rule applied to the wrong ecosystem: a
homebrew/core formula is a reviewed PR built into a bottle by Homebrew's own
CI, not a maintainer publishing a tarball straight to a registry with a
`postinstall` hook. Nothing on either machine has ever come from outside
homebrew/core, homebrew/cask, or the four vetted taps. So the cooldown
argument, which is the whole defence in npm, buys almost nothing here — while
sitting on unpatched `libssh2`/`libarchive`/`sqlite` point releases costs
something real.

**The actual hazard is silent config revert, and it is three packages.**
Each has local machinery bolted on top that an upgrade destroys with no error:

| Package | What an upgrade breaks | Visible after |
|-|-|-|
| `caddy` | replaces the xcaddy-built binary; `dns.providers.cloudflare` vanishes | ~60 days, when the wildcard cert fails to *renew* |
| `mosh` | ALF stores mosh-server's *resolved* Cellar path, so the upgrade un-allows it | next inbound `dev` — ssh handshakes, then every datagram drops |
| `colima` | regenerates the plist, restoring the inverted `KeepAlive {SuccessfulExit=true}` and the direct `colima start -f` | only after a *dirty* shutdown, when the failed start is never retried — i.e. the power cut this whole setup exists to survive |

**`colima` is asserted but deliberately not pinned**, unlike the other two. Pinning
caddy and mosh costs nothing — they are stable and their local machinery is
rebuilt by a named target. colima is the Docker runtime and holds the VM; pinning
it means sitting on an unpatched hypervisor to protect a two-key plist that
`make colima-restart` re-converges anyway. So it gets the post-upgrade assertion
and a 5-minute health check instead, which is the same trade with the failure
made loud rather than prevented.

**`brew pin` is the enforcement, not a hold list some script knows about.**
`brew upgrade` skips pinned formulae and refuses a named `brew upgrade caddy`
outright, so the guard holds for a bare command typed by hand six months from
now. `_setup-packages` converges the pins on every `make setup`, so a fresh
machine is protected before `caddy-dns-build` has run even once.

| Command | Does |
|-|-|
| `make brew-upgrade` | Converge pins, upgrade outdated **homebrew/core formulae**, then assert all three invariants |
| `make brew-upgrade-dry` | True no-op preview — reports what *would* be pinned/upgraded and touches nothing |

Casks and third-party-tap formulae are **reported, never auto-upgraded** —
casks are vendor binaries (Homebrew ships the metadata, the bits come from the
vendor), which is where the release-age cooldown genuinely applies. Those go
through `/upgrade-deps`. A held package that is outdated prints its own
deliberate four-step follow-up (`brew unpin X && brew upgrade X && make <fixup>
&& brew pin X`) rather than being silently dropped.

**That cask exclusion is a preference, not a guarantee — unlike the caddy/mosh
pins.** A bare `brew upgrade` upgrades casks too (it says so: *"Homebrew will
now attempt to upgrade casks with `auto_updates true`"*), and casks are
deliberately left unpinned. Pinning them all would mean hand-maintaining a list
that silently stops receiving security updates — a worse trade than a soft
preference honoured by the command you normally reach for. The two formulae are
pinned because *their* failure mode is silent config revert, which no amount of
care at the keyboard catches after the fact.

**It asserts rather than assumes the pins protected anything** — a dependency
upgrade can relink a dependent, so after upgrading it re-checks the caddy module
and the ALF allowlist directly (dev-host-gated on the `cache` backend marker,
same gate `caddy-dns-build` uses) and re-checks that every held package is still
pinned. `--dry-run` deliberately does *not* converge pins: a `-dry` target that
mutates machine state is the surprise `makefile-conventions.md` exists to
prevent, and it is the command you reach for precisely because you are not ready
to touch anything.

## Symlink Map

| File here | Live path | Notes |
|-|-|-|
| `config/global.CLAUDE.md` | `~/.claude/CLAUDE.md` | Global Claude instructions (single source — no per-workspace layer) |
| `config/zshrc` | `~/.zshrc` | Thin loader — sources all modules in conf.d |
| `config/zsh/*.zsh` | `~/.zsh/conf.d/` (dir symlink) | ai, aliases, brew, claude, claude-auth, git, keybindings, opencode, path, prompt, remote-dev, secrets, secrets-cache, tools |
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
| `config/herdr/config.toml` | `~/.config/herdr/config.toml` | herdr theme (near-stock: 1 colour override) + the `prefix+e` project-note binding. The **file** only — the same dir holds herdr's sockets and logs |
| `config/karabiner/karabiner.json` | `~/.config/karabiner/karabiner.json` | Caps Lock → ctrl+alt+shift, plus the global `Hyper+letter` app launchers. **Copied, never symlinked** — Karabiner rewrites this file on every UI change, and `_setup-karabiner` refuses to overwrite a diverged live copy |
| `config/starship.toml` | `~/.config/starship.toml` | Prompt. ANSI color names, never hex, so it follows the light/dark switch |
| `config/Caddyfile` | `$(brew --prefix)/etc/Caddyfile` | Local HTTPS reverse proxy — edit here, then `caddy reload` |
| `scripts/wakeup.sh` | `~/.wakeup` | sleepwatcher hook — runs `caddy reload` on wake |
| `scripts/secrets-run` | `~/.local/bin/secrets-run` | Drop-in `op` shim — `op` (MacBook) or `cache` (mini) backend, see Headless secrets below |
| `hooks/notify.ts` | `~/.claude/hooks/notify.ts` | All 4 hook events |
| `hooks/protect-branches.ts` | `~/.claude/hooks/protect-branches.ts` | PreToolUse — blocks push to protected branches |
| `hooks/docker-makefile.ts` | `~/.claude/hooks/docker-makefile.ts` | PreToolUse — blocks raw docker commands when Makefile exists |
| `hooks/machine-role.ts` | `~/.claude/hooks/machine-role.ts` | SessionStart — injects this machine's secrets backend + outbound-access routing (cache/mini vs op/MacBook) |
| `config/pr-required-repos.json` | `~/.claude/pr-required-repos.json` | Single source of truth for PR-required repos — read by `protect-branches.ts` (hook) and `scripts/github-config.sh` (full vs lite ruleset tier). |
| `scripts/keyprobe.py` | `~/.local/bin/keyprobe` | Raw-byte terminal key probe — the only unambiguous test that Caps-Lock-as-Hyper works. Run in a **bare** terminal, never inside herdr |
| `scripts/statusline.sh` | `~/.claude/statusline.sh` | 3-line statusline |
| `scripts/fetch_usage.py` | `~/.claude/fetch_usage.py` | Claude.ai usage % fetcher (uv script) |
| `rules/` | `~/.claude/rules/` (dir symlink) | All 17 global rules. Always-on: attribution, commit-conventions, dependency-hygiene, formatting, research-first, security, typescript, code-style, docker-makefile. Lazy (`paths:`): dockerfile, makefile-conventions, visx-charts, elysia, react-best-practices, tanstack-query, tanstack-router, tanstack-start. |
| `agents/` | `~/.claude/agents/` (dir symlink) | Global subagents — `implementer.md`. Frontmatter carries `model`/`effort`/`color`/`permissionMode`. |
| `config/output-styles/` | `~/.claude/output-styles/` (dir symlink) | `Direct.md` — the response-shape + autonomy contract. Activated by `outputStyle` in settings.json. |
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

**The mini cannot verify its own inbound SSH.** It has no key **for itself** — the one
private key it now holds, `~/.ssh/id_ed25519_iumac`, is an outbound credential for reaching
iumac and is not in the mini's own `authorized_keys` — and the 1Password agent can't sign
headlessly, so `ssh localhost` fails by design — inbound auth is always the *connecting*
machine's key. Verify this path
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
the biometric prompt — so the mini routes around it instead: keylessly (Tailscale
SSH), through a dedicated non-1P key (iumac), or via a cache-resolved credential
(GitHub):

- **homelab + VPS → Tailscale SSH.** tailscaled on the servers authenticates the
  tailnet identity (`tag:mac` ACL); OpenSSH-level auth is `none`. `ssh homelab` /
  `ssh vps` work headless with zero keys, zero agents, zero prompts. No dedicated
  key exists for this path — a stolen mini holds no server credential; revocation
  is removing the device in the Tailscale admin.
- **mini → iumac (the MacBook) → a dedicated non-1P key, to a userland sshd on
  :2222.** `ssh iumac` / `rsync … iumac:…` reach the MacBook non-interactively over
  `~/.ssh/id_ed25519_iumac` (`restrict,pty`, no agent forwarding, never enters
  1Password or the secrets cache) — for `usage-tracker`/`brain`/file pulls. **The
  system sshd on :22 is dead to us**: iumac's MDM pins the Remote Login SACL
  (`com.apple.access_ssh`) to `IT-Admin` and re-drops `johannes.krumm` on every
  check-in, so :22 accepts the key then closes the session with no log line. The
  door is our **own** sshd on **:2222** (`dotfiles/tailnet-sshd/`, `make
  tailnet-sshd-setup`): Apple's `/usr/sbin/sshd` with `UsePAM no` (the SACL is a
  PAM module, `pam_sacl.so` — skipping PAM skips the group check), pubkey-only,
  bound to loopback behind a `tailscale serve --tcp 2222` forwarder (Collie's
  pattern — self-heals across tailscaled restart + IP change, invisible to the
  corp LAN). ACL: `tcp:2222` on `tag:mac → tag:mac`. `Host iumac` pins `Port 2222`
  + `IdentityAgent none` so this leg never touches the 1Password agent and cannot
  hang on it. `op` still can't resolve `op://Private/*` there — over `ssh iumac`
  it fails FAST ("account is not signed in", exit 1) rather than hanging, so the
  biometric gate holds with no hang hazard. Full model:
  `dotfiles-private/docs/access-model.md` (2026-08-07 addendum), `docs/remote-dev.md` §10.
- **GitHub → HTTPS + a secrets-cache-backed credential helper.** GitHub is off the
  tailnet, so this is another outbound path that needs a headless credential:
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

There are now keys in **both** directions, each its own credential: **inbound** is
the MacBook reaching the mini over plain OpenSSH (`make remote-access` above),
needed for remote dev's agent/port forwarding and full-speed transfers that
Tailscale SSH doesn't provide; **outbound reverse** is the `iumac` bullet above —
the mini reaching back to the MacBook, restricted and with no agent forwarding. The
full per-path access model + break-glass runbook lives in
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

**`--accept-routes` is off on the mini** (set 2026-07-31; `tailscale debug prefs`
→ `RouteAll: false`). No peer advertises a subnet route today, so this changes
nothing observable — it removes a latent trap: any peer advertising a subnet that
overlaps the mini's own would silently pull local traffic out through the tailnet,
a routing fault that presents as a DNS or Docker one. This is imperative daemon
state with no declared-state file behind it — the Tailscale menu bar can flip it
back and nothing asserts otherwise, so re-check it after any Tailscale reinstall
or re-auth.

**The mini and homelab are on different networks** — measured 2026-07-31: mini
`192.168.1.100` behind gateway `192.168.1.1`, homelab `192.168.178.129`, mutually
unreachable by LAN address. They meet only over Tailscale (direct IPv6, 7 ms).
Earlier notes here and in `docs/mini-headless.md` claimed they shared a LAN "one
L2 hop away"; that was wrong. It matters beyond pedantry: macOS 26's pre-boot SSH
FileVault unlock is reachable **only over the LAN** (Tailscale does not exist
before the Data volume mounts), so homelab is *not* a jump host for break-glass
recovery of the mini as currently wired.

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
MacBook too. Don't "clean up" that row — the tag exists to make it safe. **That
one port is the machine's entire public surface** — every dev door and both
other serve rows are tailnet-bound.

Rows take an **optional 4th column, a human label** (`8443 http://localhost:5173
yes  IU dashboard`). `tailscale-serve.sh` normalises with `$1|$2|$3`, so the
applier cannot see it and it can never cause drift; it exists so the dev-apps
landing page can name a binding instead of printing a bare loopback port next to
the word "public". An unlabelled row degrades to showing its target — never to a
guessed name, which on an exposure map is the one failure that matters.

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
structurally cannot see inbound auth or the mosh UDP path, since the mini has no
key for itself and cannot ssh to itself.

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

### Notes — `prefix+e` opens the repo's page in the brain vault

**`prefix+e` opens `Projects/<repo>.md` from `~/SourceRoot/brain` in `$EDITOR`,
in a herdr popup.** `scripts/brain-note.sh` resolves the repo with
`git rev-parse --show-toplevel` against `HERDR_ACTIVE_PANE_CWD` and creates the
page (house frontmatter, linked from the Projects folder note) if it does not
exist yet. No plugin, no pin, nothing to install.

**This replaced the `herdr-notes` plugin on 2026-08-04, and the reason was the
store, not the UX.** That plugin kept one `<workspace-id>.json` in herdr's
plugin state dir: untracked, unsynced, unbackuped, keyed to a workspace id that
a closed workspace orphans — a *third* place notes could live, next to a
git-backed Obsidian vault on the same disk and TickTick for tasks. This file
already said as much ("scratch space, not the brain: anything worth keeping goes
to `/brain`"), which is an argument for not having it. `make herdr-setup` carries
a one-shot, self-deleting uninstall; the old notes are **not migrated** and the
state dir is left on disk rather than deleted.

Four things worth knowing:

- **Per repo, not per workspace.** Two workspaces on one checkout were two
  files under the plugin and are one page now — and a page a human can find
  without knowing herdr exists.
- **`Projects/` is deliberate.** PARA `Projects` is the vault's curated human
  surface (light lint: wikilinks must resolve, no forced schema), and an active
  repo is an active project. Scratch that turns out to matter gets tidied in
  place instead of migrated.
- **New pages must be wikilinked from `Projects/Projects.md`.** `vault-lint`
  warns `not wikilinked from its folder note` otherwise, and the dashboard's
  dataview does **not** satisfy it — that query is rendered by Obsidian while the
  linter reads the file. The script appends the bullet itself; a page that makes
  the vault warn on creation is how a linter stops being believed.
- **The popup runs on the server**, so via `desk` (client on the MacBook, server
  on the mini) it edits the *mini's* checkout. Both machines hold one and
  brain-sync reconciles through GitHub every 5 minutes, so either is the right
  file. The mini's lane pulls and pushes but never **commits**, so a note written
  there lands via the nightly `brain-backup` sweep. The script deliberately does
  no `git pull` of its own: that is brain-sync's job, and a keystroke should not
  wait on the network.

`popup` rather than a docked pane is measured, not assumed — herdr's
`CommandKeybindType` is exactly `{shell, pane, popup, plugin_action}` (read out
of the binary). A popup is session-modal and closes when the command exits, so
the note stops eating pane width permanently. Custom commands get
`HERDR_ACTIVE_PANE_CWD`, `HERDR_ACTIVE_WORKSPACE_ID`, `HERDR_ACTIVE_TAB_ID`,
`HERDR_ACTIVE_PANE_ID` and `HERDR_BIN_PATH` in the environment.

**Every failure path pauses on the way out.** A popup closes the instant its
command exits, so an unpaused error message is a flash of text nobody can read —
which makes a broken script indistinguishable from a dead keybinding.

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

**That constraint binds `ssh mini 'claude …'` only — and the auto-login change
made it a non-problem in practice.** Since 2026-08-01 the mini boots unattended
with FileVault off and automatic login on, which performs a *real* password login
and therefore brings the login keychain up **unlocked** with no human present.
Measured on a genuine unattended boot: `security show-keychain-info` → `no-timeout`,
`claude auth status` → `loggedIn: true, max`. Every practical path onto this
machine — herdr panes, `rd bg`, LaunchAgents — is a GUI-session child and simply
works. The claim that auto-login would leave the keychain locked, which drove the
push toward `setup-token`, was **wrong**; it is disproven rather than merely
doubted. Only a raw `ssh mini 'claude …'` still fails, and `rd bg` exists
precisely so nothing needs that.

**`config/zsh/claude-auth.zsh` is therefore a dormant fallback, not the fix.**
Leave it wired and unminted: it costs nothing dormant, and a `setup-token`
credential is a **one-year token with no refresh and no reliable server-side
revocation** — a downgrade from a keychain credential that refreshes itself
(access ~8h, refresh rolling). Mint one only if the keychain path actually breaks.
It
defines a `claude()` zsh function that resolves `op://mini/claude/oauth-token`
through `secrets-run` and passes it as `CLAUDE_CODE_OAUTH_TOKEN` — the one
mechanism that needs no keychain. It must be that variable and **never
`ANTHROPIC_API_KEY`**, which flips billing to API credits, i.e. causes the exact
failure it is meant to prevent. `_setup-zshenv` sources it from `~/.zshenv` as
well as conf.d, because `ssh mini 'claude …'` reads only `.zshenv`. Three
constraints, each the reason for a design choice: it is a **function**, not a
shim in `~/.local/bin`, because that path is a symlink the Claude Code updater
rewrites on every version bump; it passes the token by **prefix assignment**, not
`env VAR=… claude`, because `env` puts the value in argv where `ps auxww` shows
it; and it **self-gates on the `cache` backend marker**, because on the MacBook
`secrets-run` passes through to biometric `op` and would prompt on every launch.
`ca` / `claude_iu` / `claude_bridge` launch through `env`, which resolves the
binary from PATH and bypasses shell functions — so their off-Max
`ANTHROPIC_AUTH_TOKEN` flow is unaffected by construction, not by a guard that
could rot. Until the human mints the token (`claude setup-token`) and the cache
is reseeded, the read fails and the wrapper falls through to the existing
keychain login **silently** — it must not break a working machine to announce a
future step. The reporter for the failure case is `check_claude_auth` in
`scripts/devhost-health-check.sh`, which fails the 5-minute heartbeat on anything
that is not a logged-in Max session. Note the token is a **one-year** credential
with no refresh and no reliable server-side revocation; that heartbeat is the
only thing that makes the expiry loud. Full reasoning:
`docs/mini-headless-checklist.md` L3.3 and `dotfiles-private/docs/security-review.md`.

### Unattended boot posture (mini only)

Three settings make the mini survive a power cut with no human: FileVault **off**,
automatic login **on**, `pmset -a autorestart 1`. The third is the one whose
absence is silent — without it the machine does not power on at all, and nothing
reports that until the exact event the arrangement exists to survive.

`make lock-at-boot-setup` (dev-host gated) then closes the window that opens:
`com.jkrumm.lock-at-boot` is a `RunAtLoad` agent that locks the screen right after
the unattended login. **Screen lock does not lock the keychain** — that re-locks
only on the "Lock when sleeping" setting, the inactivity timer, or logout — so the
whole session keeps running behind a password prompt.

Two halves, and the agent alone is inert: `sysadminctl -screenLock immediate`
removes the grace period, the agent fires `pmset displaysleepnow`. **The setup
target refuses to install** unless the first half is already applied, because a
plist that sleeps the display and leaves the machine unlocked reads as done while
doing nothing. `make lock-at-boot-check` reports all of it plus live lock state.

**`sysadminctl -screenLock` does not prompt** — unlike `-autologin` it has no
interactive form, and exits `Password is required!` unless the password is inline
(`-password '<pw>'`). Prefer the GUI (Systemeinstellungen → Sperrbildschirm →
*Sofort*), which puts it on no command line. If using the CLI, `histignorespace`
is **off** here so a leading space does not hide it from `~/.zsh_history` — run
`setopt histignorespace` first. The argv exposure is moot (that password is
already in `/etc/kcpassword`); the persisted history line is not.

Two things that contradict most write-ups: **`CGSession -suspend` does not exist**
on macOS 26 (the `User.menu` bundle is gone — checked on disk, not inferred), and
`osascript` ⌃⌘Q is the wrong tool because Accessibility/TCC cannot be granted to a
launchd job on a headless machine. Scope, threat model and sources:
`docs/remote-dev.md` → "What used to take this down".

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

### Two dev-server doors: port-based (`.ts.net`) and clean (`.mini.jkrumm.com`)

**`config/Caddyfile` is the single app registry.** Every `<name>.test {
reverse_proxy localhost:PORT }` block in the tracked Caddyfile automatically
gets a clean door at `https://<name>.$DEV_DOMAIN` — a new app needs **zero**
work beyond the `.test` block it already needs. `~/.config/caddy-tailnet.ports`
survives as an **opt-out + flags** file (`exclude <name>`, and the `portdoor` /
`host=rewrite` flags), not a second list. Before this it *was* a second list,
and the two drifted silently: 17 apps in one, 4 in the other, and an app
reached the tailnet only if you remembered to edit both.

The Caddyfile is read by handing it to **`caddy adapt` and walking the route
JSON** (`scripts/lib/caddy-registry.py`) — never by regexing it, which the live
file defeats three separate ways: the non-`.test` `metabase.iu-aws.de` block,
snippet imports, and `fpp.test`'s `header_up Host` variant. That last one is
carried over automatically, so an app whose `.test` block rewrites Host gets the
same treatment on the tailnet door without a flag. Two guards run before the
parse and both are fatal: the machine-local include is stripped (it holds the
Cloudflare token and must never enter the parse path), and any *other* file
import aborts — adapting happens from stdin, so a surviving relative import
would resolve against the wrong directory and silently return a short app list
rather than an error. The extractor also refuses to emit an empty registry,
because a future Caddyfile restructure that broke the walker would otherwise
tear down every dev door quietly instead of failing.

**An app that exists in the registry but not on this machine gets `exclude
<name>` in the machine-local ports file, not a deletion from the tracked
Caddyfile.** `photoflow` (7717) is the case: photo-flow and its LaunchAgent live
on the MacBook, which shares this Caddyfile and genuinely needs
`photoflow.test`, while nothing on the mini has ever bound 7717. Left in, its
probe reports red forever for something that is not broken — which is how you
train yourself to ignore the status column. Excluded, it gets no probe route at
all and the landing page omits it.

**A `.test` block the extractor can't reduce to one name and one port is
SKIPPED, and the summary says so.** A block with two `reverse_proxy` handlers
(the retired `whisper.test` split `/v1/audio/transcriptions*` from `/v1/*` — so
this is a real pattern, not a hypothetical), a multi-host match, or a
non-loopback upstream cannot be routed by name, so it gets no tailnet door. It
is never guessed at; a wrong upstream in a generated proxy is worse than a
missing door. Split such an app into one block per port to give it doors.

The generator's every input *and* output is overridable
(`CADDY_TAILNET_{CADDYFILE,PORTS,CONF,OUT,PAGE_DIR,NO_RELOAD}`) so it can be
exercised against scratch files. That is a safety property, not a convenience:
when only the inputs were overridable, the obvious way to test a change —
scratch PORTS/CONF — still rewrote the **real** include and reloaded Caddy from
it, which with an empty scratch `DEV_DOMAIN` deletes the clean door for every
app at once. An `OUT` outside `Caddyfile.d` now implies `NO_RELOAD`.

`make caddy-tailnet` (`scripts/caddy-tailnet.sh`) generates **two** doors onto
the same dev servers, not one, and the second is additive — the first stays,
permanently, as the zero-dependency fallback:

1. **Port-based**: `https://<mini-magicdns>:<port>` — the original mechanism.
   Cert comes straight from tailscaled (`tls { get_certificate tailscale }`),
   so it has no DNS provider, no Cloudflare, and no ACME in its path. This is
   the fallback that must survive door 2 breaking, but it is **opt-in per app**
   (`portdoor`), and that asymmetry is deliberate — see below.
2. **Clean**: `https://<app>.mini.jkrumm.com` — one wildcard Caddy site block
   (`*.mini.jkrumm.com { … }`) on `:443` of the tailnet IP, `host` matchers
   fanning out to `localhost:<port>` per app, secured by a single wildcard
   Let's Encrypt cert via Cloudflare DNS-01. **Default-on for every app.**
   Opt-in per *machine*: only generated once `~/.config/caddy-tailnet.conf`
   sets `DEV_DOMAIN` and a chmod-600 Cloudflare token file exists — an
   un-seeded machine silently gets door 1 only, which is a valid state, not
   an error.

| Command | Purpose |
|-|-|
| `make caddy-tailnet` | Dev-host only: regenerate both doors from `config/Caddyfile` + `~/.config/caddy-tailnet.{ports,conf}`, validate, reload. |
| `make caddy-dns-build` | Dev-host only, one-time (or after any `brew upgrade caddy`): build + install Caddy with the Cloudflare DNS module — prerequisite for door 2. |

**Only the clean door defaults on, and the reason is port squatting.** A port
door makes Caddy bind the app's *own port number* on the tailnet interface, so
it collides with anything else holding that address: `tailscale serve` (rb's
`:7730` row) and any dev server that binds `0.0.0.0` rather than loopback
(sideclaw does; Docker published ports do by default). Auto-generating 17 of
them would have Caddy squat ports that `docker compose` then fails to bind
days later, with a confusing error — so the port door stays a per-app opt-in.
The clean door has no such failure mode: every app shares one `:443` listener,
which is exactly why it is the one that scales to "every app, no work".

**Upstreams dial `localhost:<port>`, never `127.0.0.1:<port>`.** A dev server
does not reliably bind the IPv4 loopback. Vite, finding its port already held
on some other address, silently falls back to binding **`::1` alone** and still
prints a cheerful `ready` line — after which a hardcoded `127.0.0.1` upstream
502s against an app that is plainly running. Observed with basalt-playground on
7710 while a port door held the tailnet IP. `localhost` resolves to both
families and Go's dialer tries each, so it covers the app whichever way it
binds; it is also what the tracked `.test` blocks already use.

**One site block for every app, never one per app.** Caddy 2.10+ issues a
single wildcard cert that covers every `host {}` matcher inside one site
block; N site blocks would each provision their own cert and race Let's
Encrypt's ~50-certs-per-registered-domain-per-week limit for zero benefit.
The `host=rewrite` flag is the escape hatch for a dev server that validates
the `Host` header on dev-only endpoints and can't be allowlisted — same shape
as the `fpp.test` block in `config/Caddyfile`, and **carried over from that
block automatically**, so it needs setting by hand only to force it on for an
app whose `.test` block doesn't already do it.

**The landing page at `https://mini.jkrumm.com`** (also `apps.mini.jkrumm.com`)
lists every app with its port, both doors, and live status — and is served from
the wildcard block's bare `handle {}` fallback too, so a *typo'd* name shows you
what exists instead of a bare 404. **The whole row is the link**; the anchors in
the doors cell survive only so a URL stays visible, copyable and
middle-clickable, and a row click that landed on one is deliberately left alone
(otherwise a secondary door link would navigate to the primary one).

**It also lists the `tailscale serve` rows, in a second table, with Funnel
marked `public`.** Those are a different mechanism with a different blast
radius — but a page that lists 18 tailnet-only doors and stays silent about the
funneled port reads as a complete exposure map while omitting the only row where
"who can reach this" has a different answer. Read **live from tailscaled** at
generation time, not from the declared conf, because the question is what is
published right now; drift against the declared state stays
`make tailscale-serve-check`'s job and the page says so rather than implying it
re-checked. It is a snapshot — changing serve state wants a `make caddy-tailnet`
after `make tailscale-serve`. Serve rows are never probed: there is no
same-origin `/_up` route for them, and a cross-origin `fetch` would report every
one as failed regardless of health.

**Three apps carry `portdoor` on the mini** (2026-07-31): argo 7715, modelpick
7727, jkrumm 7728. For a while none did, and that was the wrong end state — a
fallback documented as permanent but deployed for zero apps means every door on
the machine hangs off one Cloudflare token, one DNS module and one wildcard cert
with nothing behind it. Three is the compromise: enough that the fallback is
exercised and known-good, few enough that Caddy squats almost no ports.

The port must be free on the tailnet interface **and** inside the ACL's
`tcp:7700-7799` grant, or the door times out with nothing in any log. All three
run loopback-only dev servers. **basalt-playground (7710) is deliberately
excluded** despite being on the pre-registry list: 7710 is the exact port where a
port door once pushed Vite into its `::1`-only fallback, the incident
`caddy-tailnet.sh` cites in its own upstream comment.

**They carry `host=rewrite`, and that is what makes the fallback real.** A port
door's Host is the MagicDNS name — the *machine*, not the app — and no app
allowlists it (all three list `.mini.jkrumm.com`, which does not cover
`*.ts.net`), so a bare `portdoor` answers 403 on the day door 2 fails.
Allowlisting a machine name in three app repos would also re-break on the next
device rename. Rewriting to `localhost:PORT` needs nothing from the app and is
accepted unconditionally by Vite and Astro. It applies to the clean door too —
harmless, since `localhost` is allowlisted there as well.

**The apex is a second subject on the same site block, not a third door** —
`*.mini.jkrumm.com, mini.jkrumm.com { … }`. A wildcard answers for exactly one
label below the name, in DNS *and* in the cert, so the apex needs its own A
record (`mini.jkrumm.com → <tailnet-ip>`, grey-cloud) and Caddy provisions a
separate `CN=mini.jkrumm.com` cert for it. Sharing the block is what makes it
free otherwise: the apex matches no `host` matcher, falls through to the
landing-page fallback, and inherits the `/_up/*` probes. `check_dev_vhosts`
asserts **both** A records against the live tailnet IP, because they drift
independently — and apex drift is the quiet one, where every app door keeps
working and only the front page dies.

**Adding the apex record is not the same as being able to resolve it.** Any
lookup made *before* the record existed is negatively cached, at two independent
layers, and neither expires when you expect:

- **The LAN router.** MagicDNS declares no resolvers of its own here, so it
  forwards to the system default — the Fritz!Box — which served NODATA with a
  flat 1800s SOA for `mini.jkrumm.com` while answering fine for every sibling
  (`argo.jkrumm.com`, `apps.mini.jkrumm.com`). This is *not* DNS rebind
  protection: verified by `dig @192.168.1.1 localtest.me` → `127.0.0.1` and
  `<mini-tailnet-ip-dashed>.nip.io` → `<mini-tailnet-ip>`, both unfiltered. It cleared on its own
  in ~4 minutes; a mixed-case query (`MiNi.JkRumm.com`) also forces a miss,
  because its cache keys are case-sensitive.
- **macOS `mDNSResponder`, which is the one that actually bites.** `dig` talks
  to `100.100.100.100` directly and reported the record as soon as the router
  did — while `curl` and every browser on the same machine still failed with
  "could not resolve host" for far longer. **`dscacheutil -flushcache` does not
  clear it**; only `sudo killall -HUP mDNSResponder` does, which on the mini
  means the MacBook-only root password (see Secrets). Chrome caches on top of
  that again — `chrome://net-internals/#dns`.

So `check_dev_vhosts` can honestly report `DNS in sync` while the browser in
front of you still says ERR_NAME_NOT_RESOLVED: it uses `dig`, deliberately, to
assert what is *published* rather than what one client has cached. Verify the
door itself out-of-band and it separates cleanly —
`curl --resolve mini.jkrumm.com:443:<tailnet-ip> https://mini.jkrumm.com/`
returned 200 with `CN=mini.jkrumm.com` before any cache had caught up.

Status is same-origin by construction — no daemon, no CORS. The generator emits
a `handle /_up/<name>` probe route per app in the *same* site block, so the
page just fetches `/_up/<name>` and reads the code. Three details are
load-bearing:

- **`rewrite * /` inside each probe.** Without it the upstream receives
  `/_up/<name>` and a perfectly healthy dev server answers 404 — indistinguishable
  from a real failure. With it, a live app returns its real status.
- **The probes nest inside the fallback `handle {}`**, not at the top of the
  block. At the top they would shadow `/_up/*` on every real app's own
  subdomain. Relatedly, the bare `handle {}` must be written **last**: handles
  in one group are mutually exclusive and first-match, so a bare one written
  earlier swallows every named host above it.
- **502 vs 403 is the whole point.** `502` means Caddy could not dial the port
  (dev server not running); `403` means it is running and rejecting the door's
  Host header. That second state is the most common failure here and it looks
  exactly like a proxy fault, so the page names the fix outright: add
  `.mini.jkrumm.com` to Vite/Astro `server.allowedHosts`, or `*.mini.jkrumm.com`
  to Next's `allowedDevOrigins` — **Next does not understand a leading dot**, it
  globs whole segments.

**`servers { protocols h1 h2 }` in the global options block is load-bearing,
not incidental.** HTTP/3 is unusable over Tailscale: quic-go's 1280-byte
initial packet exceeds the tailnet MTU once headers are added
(caddyserver/caddy#7885), so h3 connections fail — Chrome-only, intermittent,
exactly the kind of bug you don't want to rediscover by accident. Disabled
explicitly for every site block Caddy serves, not just the tailnet ones.

**`bind 127.0.0.1` on every `.test` block is what makes the clean door safe to
grant broadly on `:443`.** Before this change, the local dev proxy's `(local)`
snippet (and the `http://*.test` redirect, and `metabase.iu-aws.de`) took the
default `0.0.0.0`, which made this Caddy reachable over the LAN *and* the
tailnet — and on the mini it collided with the tailnet wildcard block's own
`:443` listener. After the change, nothing but the deliberate tailnet-bound
site blocks listens on the tailnet interface's `:443` at all, which is the
premise the ACL grant below relies on.

**`make caddy-dns-build` is the prerequisite, and it has a sharp trap.** Stock
Homebrew Caddy ships zero DNS provider modules
(`caddy list-modules | grep dns.providers` is empty), so DNS-01 is impossible
until Caddy is rebuilt with `github.com/caddy-dns/cloudflare` via `xcaddy`
(installed via `go install`, not Homebrew — pinned in the Makefile like
`COLLIE_REF`) and installed over
`$(brew --prefix)/opt/caddy/bin/caddy`, the exact path the brew LaunchDaemon
plist execs. Dev-host only, same gate `collie-setup` uses. **A later
`brew upgrade caddy` silently reverts this binary and the module vanishes —
nothing errors until the wildcard cert fails to renew ~60 days later.** That
is why `devhost-health-check.sh`'s `check_dev_vhosts` asserts the module is
present on every 5-minute run (folded into the composite push monitor, not a
new one — same `check_git_push` exception: it doesn't fail *with*
herdr/sshd/tailscaled/mosh, but didn't warrant a monitor of its own), and why
re-running `caddy-dns-build` is the fix after any caddy upgrade. It also
checks the wildcard cert has >21 days left (probed locally via `openssl
s_client` against the tailnet IP — never an outbound call to Cloudflare or
Let's Encrypt, same restraint as `check_git_push`'s comment) and that the
published `health.$DEV_DOMAIN` A record still matches the live tailnet IP,
catching the silent-drift failure mode where a device rename or re-key leaves
every clean URL dead with nothing in any log.

**The ACL grant needs an additive tag, same pattern as Funnel and Collie.**
`tag:devhost → tag:mac/tag:phone/tag:tablet` on `tcp:443` in
`dotfiles-private/tailscale-acl.jsonc` — `dst` is the additive `tag:devhost`,
not `tag:mac`, because both Macs run this same Caddy config and a
`tag:mac → tag:mac` grant on 443 would hand the work MacBook the personal
Caddy too (which also fronts `metabase.iu-aws.de`). `tag:tablet` is new for
the same reason as the Collie grant's `tag:phone` scoping: `tag:client`
buckets the two TVs *and* the tablet as one group, and only the tablet should
reach dev servers — additive on the tablet alone so it keeps its existing
`tag:client` grants, and the TVs must never gain this. Port 443 rather than a
dedicated port (Collie's `tcp:8788` pattern) because the entire point of this
door is a portless URL — the dedicated-port trick that scopes every other
grant here is simply unavailable. **Both re-taggings (mini `+tag:devhost`,
tablet `+tag:tablet`) are console-only actions** — `make tailscale-acl-push`
can declare the grant, but cannot tag a physical device, so the grant is
inert until both are applied by hand in the admin console.

**Two halves, and each is silently useless without the other**: the tag is
applied in the console, the grant is applied by `make tailscale-acl-push` from
the MacBook. Tagging the mini while the grant sits unpushed in
`dotfiles-private` looks exactly like tagging having no effect — the tag is
right there in the machine list, and every device still times out.

**Verify the live filter from the mini itself, with no API key.**
`tailscale debug netmap` carries this node's effective *inbound* rules, so it
settles "is the grant actually pushed?" on the machine that cannot run
`tailscale-acl-diff` (`op://Private/*`, refused by the cache — the target now
says so instead of suggesting `op signin`, which would hang there):

```bash
/Applications/Tailscale.app/Contents/MacOS/Tailscale debug netmap \
  | python3 -c 'import json,sys
for i,r in enumerate(json.load(sys.stdin)["PacketFilter"]):
    print(i, r.get("Srcs"), sorted({(d["Ports"]["First"],d["Ports"]["Last"]) for d in r.get("Dsts") or []}))'
```

No `(443, 443)` row means no grant, whatever the console shows. Expect the
existing rows to be 22/5900/7700-7799 (Macs), 60000-61000 (mosh), 7730 (rb),
8788 (collie, phone only).

## Collie — the phone control surface

[Collie](https://github.com/AltanS/collie) is a loopback-bound Bun bridge + PWA
that mirrors the herd on a phone: open a URL, see which agent is blocked, type
a reply. Third-party, installed and **commit-pinned** by `make collie-setup` —
`COLLIE_REF`/`COLLIE_VERSION` in the Makefile — a commit, not a tag, because
tags move and `plugin install` re-clones and rebuilds the repo every time.
Since herdr-notes was retired it is the **only** pinned plugin left. Upgrading
is a reviewed diff of that pin, driven by `make collie-upgrade`; there is no
`plugin update`. Collie was chosen over granting the phone raw ssh+mosh: no
port-22 grant, no SSH key on a device that can be lost or stolen.

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

**Supervision is upstream's as of collie 0.21.0 — this repo used to own it.**
`collie-ctl.sh start` now writes `~/Library/LaunchAgents/herdr.collie.plist`
itself (`RunAtLoad` + `KeepAlive {SuccessfulExit: false}` + `ThrottleInterval 5`),
closing the gap that `collie/com.jkrumm.collie.plist.template` existed to close:
before it, macOS got a bare `nohup` that did not survive a reboot. Our template
is **deleted**, not disabled — two `RunAtLoad` + `KeepAlive` agents on port 8787
is a fight neither wins cleanly, and upstream's `start` clears only its own
pidfile tier, so it cannot free the port from a label it has never heard of.
`make collie-setup` boots the legacy label out and removes the file before
calling `start`; that migration is idempotent and self-deleting.

It is a **LaunchAgent, so it starts at login, not at boot** — and a Mac
administered purely over SSH has no `gui/<uid>` to bootstrap into, so upstream
degrades to the unsupervised tier with a warning instead of failing. That tier
passes every liveness probe and dies on the next reboot, which is precisely the
gap this whole section exists to close, so `collie-setup` asserts the plist
exists *and* the label is loaded, and fails otherwise. The mini clears this only
because it auto-logs-in (see *Unattended boot posture*) — that is what makes
"at login" equivalent to "at boot" here, and it is not true of a Mac without it.

Two upstream fixes made this safe to hand over, and both were the reason the
local plist existed. PATH: `herdr plugin action invoke start` used to die with
`error: bun not found` (a herdr-server-spawned command does not inherit
Homebrew's PATH — same class as the mosh-server/`~/.zshenv` gap above), so our
plist pinned `PATH`; 0.20.2 made collie-ctl resolve Bun from its install
locations, not just `PATH`. And the `.env`: upstream's plist execs
`collie-ctl.sh _exec-bridge` rather than `bun`, and the script sources the
`.env` at top level (`set -a; . "$CONFIG_DIR/.env"; set +a`, `collie-ctl.sh:42`).

**Whatever starts it must source the `.env`.** This is the invariant, and it
outlives whoever owns the plist. The bridge reads `process.env` only
(`bridge/config.ts`) and never parses `.env` itself — on Linux systemd feeds it
in with `EnvironmentFile=-`, and launchd has no equivalent. Any start path that
reaches `bun` without sourcing it first brings the bridge up with
`COLLIE_PUBLIC_HOSTS`, `COLLIE_MULTI_SESSION` and `COLLIE_SKIP_SERVE` **all
unset** — every hardening setting above quietly off, DNS-rebinding guard
included — while `launchctl list` shows status 0 and the UI works perfectly.
Upstream holds that invariant today; it is one refactor away from silently
inverting, which is why the check below is behavioural and stayed behavioural
through the handover. The original break was caught only
because that check is behavioural: a spoofed `Host` header must still
return 403 **on `/api/snapshot`** after any change to how the bridge is started.
It had gone back to 200. The path is load-bearing — the guard fires on API routes
only, and the SPA shell at `/` answers 200 to any Host (it is CSP-locked,
`default-src 'self'`), so a pathless probe reports the guard broken when it is
fine. Verified 2026-07-31: `/api/snapshot` loopback 200 / spoofed 403; `/`
loopback 200 / spoofed 200. `make collie-setup` now **fails** on anything but
403, so the handover could not have silently regressed it — re-run that
assertion, not just `launchctl list`, whenever the start path or the `.env`
moves.

| Command | Does |
|-|-|
| `make collie-setup` | Dev-host only (gated on the `cache` backend marker): install/refresh the pinned plugin, migrate off the legacy agent, `collie-ctl.sh start`, then assert liveness + the rebind guard + that launchd actually supervises it |
| `make collie-upgrade` | Dev-host only: resolve the newest release tag, print its changelog + diffstat + a scope verdict, and on `y` bump the pin, reinstall, assert, commit |
| `make collie-status` | Read-only: LaunchAgent state, bridge health, rebind guard, `tailscale serve status` |
| `make collie-teardown` | Boot out both labels (current + legacy), uninstall the plugin — deliberately **not** `collie-ctl.sh uninstall`, which attempts a `tailscale serve` teardown even under `COLLIE_SKIP_SERVE=1`; serve is declared state and no upstream script gets to mutate it |

**Upgrading is still a reviewed diff — `make collie-upgrade` just removes the
eleven mechanical steps around it.** There is no `plugin update` (herdr's docs:
"reinstall from GitHub to refresh"), and upstream's own `collie-ctl.sh update`
is deliberately unused here: it pulls **branch head**, which discards the pin and
can land pre-release commits.

**The scope verdict it prints is decision support, not a safety boundary — do
not let it grow into an auto-applier.** It answers "did anything outside `web/`
move?", which catches a *bridge or hardening* change worth reading closely. It
does not make a UI-only release safe: the PWA **is** the control surface, so
malicious `web/` code reads the snapshot and sends keys exactly as well as
malicious `bridge/` code would. `bun.lock` is excluded from the safe set for the
same reason — a changed lockfile is a changed dependency. What makes a bad
release survivable is the rollback: `collie-setup`'s spoofed-Host assertion runs
after the install, and a failure restores the previous pin and reinstalls it.

It refuses to run unattended (no TTY and no `COLLIE_UPGRADE_YES=1` → exit 1) and
refuses on a dirty `Makefile`, since it commits that file. It commits locally and
never pushes.

**Monitoring is opt-in, and wiring it is scripted end to end.** Collie reports
to its own Kuma monitor, `MacMini Collie - Push` (id=205, declared in
`homelab/uptime-kuma/monitors.yaml`), pushed by the existing
`com.jkrumm.devhost-health` LaunchAgent — see the heartbeat section below for
why it is a separate monitor rather than a sixth component. On a fresh machine:

1. `make uk-sync` from `homelab` — creates the monitor if absent, no browser.
2. Fetch its `pushToken` and write `https://uptime.jkrumm.com/api/push/<token>`
   into `~/.config/uptime-kuma/collie-push-url`, `chmod 600` (snippet below).

Until step 2 the collie push is skipped silently, which is deliberate: a machine
that never ran `collie-setup` has no collie and must not fail the heartbeat.

## Dev-host health heartbeat (mini only)

**Three** Uptime Kuma push monitors, one agent. `MacMini Dev Host - Push` (group
`Local`) is the composite and covers **thirteen** components: tailscaled (state
*and* node-key expiry days), sshd, herdr, mosh (both the binary and its
Application Firewall allowlist membership), the GitHub push credential, the clean
dev-vhost door (`check_dev_vhosts` — the Cloudflare DNS module, wildcard cert
lifetime, DNS A-record drift, and token/include file permissions; see *Two
dev-server doors* above), memory pressure + swap, launchd restart counts, six
always-on services (sideclaw, litellm, hermes gateway, colima, caddy, dnsmasq),
`claude auth status`, the obsidian CLI, disk, and a report-only runaway reaper.
`MacMini Collie - Push` and `MacMini Secret Seed - Push` are separate — see **One
scheduler, three monitors** below for why. All three are driven by
`scripts/devhost-health-check.sh` via the `com.jkrumm.devhost-health` LaunchAgent
every 5 minutes. Opt-in per machine like `remote-access`:

| Command | Purpose |
|-|-|
| `make devhost-health-setup` | Install the agent. Refuses unless the push URL exists, and prints the ordered runbook to create it. |
| `make devhost-health-check` | Run once, print per-component status. |
| `make devhost-health-teardown` | Unload + remove. |

**It is a bash 3.2 script and must stay one.** The plist sets no `PATH`, so
launchd hands it `/usr/bin:/bin:/usr/sbin:/sbin` and `/usr/bin/env bash` resolves
to Apple's 3.2. No `mapfile`, no `${var,,}`, and no `"${arr[@]}"` on a
possibly-empty array (3.2 calls that an unbound variable under `set -u`), which
is why the newer checks accumulate into strings rather than arrays. The mini has
no Homebrew bash today, so an interactive `make devhost-health-check` also runs
3.2 — but that is machine state, not a guarantee: `brew install bash` and the
interactive run silently starts accepting constructs launchd will fail on.

**Push, not probe** — the ACL grants `tag:homelab → tag:vps` but *not*
`tag:homelab → tag:mac`, so Uptime Kuma physically cannot reach the mini.
Opening an inbound grant purely for monitoring would be new attack surface for a
check the mini can report on itself over the already-granted outbound path. Same
pattern as `MacMini Secret Seed - Push` and the Hermes monitors.

**One monitor, not thirteen.** herdr/sshd/tailscaled/mosh all fail together when
the mini sleeps or drops off the tailnet; separate monitors would be simultaneous
pages saying one thing. The failing component is named in the push `msg`, which
is where the diagnosis belongs. The other nine are all deliberate exceptions to
that rule — a token expires, `brew upgrade caddy` reverts a DNS module, a cert
nears expiry, an A record drifts, a service crash-loops, an OAuth token lapses, a
disk fills — each while the rest of the host is perfectly healthy. Every one was
folded in anyway, because a dedicated Kuma monitor is worth less than one more
named component in the `msg`.

**The line that does hold is absence, not independence.** A component that can be
legitimately *missing* on a good machine gets its own monitor, because folding it
in would page "dev host DOWN" for a feature this host does not have — that is
collie and secrets freshness. A component that is merely *independent* stays in
the composite and SKIPs when unconfigured: `check_dev_vhosts` without
`DEV_DOMAIN`, the six service probes without their plists, `claude auth` and the
obsidian CLI without their binaries, and the Tailscale key-expiry sub-check once
WP1 disables expiry entirely (an empty `KeyExpiry` is the correct steady state,
so it skips silently and permanently rather than nagging).

**Transient tolerance (2026-08-01).** The first real power-cut test produced a
DOWN page that was pure noise: the host booted 08:53:20, the agent ran 08:54:24,
and sideclaw + linewatch-collector did not start until 08:56:08 — **+2m48s, both
at the same second**, a deferred launchd bootstrap pass rather than a fault. With
`maxretries 0` that is a full DOWN alert on *every* reboot, and a monitor that
cries wolf after every power blip trains you to ignore it. (An earlier diagnosis
said those two agents "never load" and blamed Background Task Management — wrong;
they were only late. Don't re-engineer two working plists.) Three knobs, all
env-overridable: `DEVHOST_BOOT_GRACE_SECONDS` (300 — every failing component
reports `starting`, push stays UP), `DEVHOST_TRANSIENT_FAILS` (3 — outside the
grace a check reports `degraded n/3` and only FAILs on the third consecutive
run), `DEVHOST_REBOOT_NOTE_SECONDS` (600 — the summary carries `host rebooted Ns
ago`, closing the gap where a 3am power cut that recovered perfectly left no
trace anywhere).

Two things that were got wrong first: **the boot grace covers every component,
not just liveness ones** — failures cascade at boot (`check_dev_vhosts` needs the
tailnet IP, so it fails while tailscaled is merely slow), so a liveness-only
grace still paged on every reboot. And **the axis is level- vs edge-triggered,
not liveness vs state** — a streak counter silences an edge-triggered check
*permanently* rather than delaying it, which is why `check_launchd_restarts` (a
delta, true for one run per restart) is the sole `IMMEDIATE_COMPONENTS` member.
**None of this relaxes "the machine died"** — if the host is gone no push lands
and Kuma's own missed-heartbeat is untouched, which is the property `maxretries
0` exists to protect.

**Two of the new checks are worth knowing the shape of, because the obvious
implementation of each is wrong.** Restart detection is a **delta** against a
state file (`~/.local/state/devhost-health/launchd-runs`), not a threshold on
`runs` — `runs` is cumulative since load, so failing on `runs > 1` would page
forever over herdr's `Killed: 9` from weeks ago; the alertable fact is "restarted
since the last 5-minute check", which for herdr means every pane's processes are
gone right now. And the runaway reaper gates on **accumulated CPU time crossed
with lifetime average CPU**, never instantaneous `%CPU` (a compile pegs a core)
and never accumulated time alone (a healthy sideclaw crosses any fixed
CPU-minute line given enough uptime, then pages forever). `claude --bg` daemons
are excluded by name: they are PPID 1 with a SourceRoot cwd by design. It reports
and never kills.

**One scheduler, three monitors.** Collie is deliberately *not* a composite
component, and the reason is the rule above pointed the other way: it is opt-in
per machine and can be absent, down or mis-hardened while herdr/sshd/tailscaled/
mosh are all fine — so folding it in would mark the dev host DOWN and implicate
healthy components. It gets `MacMini Collie - Push` instead. What it does *not*
get is its own agent: the existing LaunchAgent already runs every 300s, so a
second one would be pure duplication. Only the push target differs, and the URL
file's absence is silent by design so a machine without collie never fails the
script.

Collie's check asserts **behaviour, not liveness** — the bridge answers 200 on
loopback *and* a spoofed `Host` header must return 403, both on
**`/api/snapshot`**. Naming the path is not pedantry: `/` serves the SPA shell to
any Host and always answers 200, so the same probe run against `/` reports a
perfectly healthy guard as broken. That second assertion is the whole point:
collie's hardening lives in a `.env` that launchd does not load on its own, so a
mis-started bridge passes every liveness probe with its DNS-rebinding guard
silently gone. `launchctl list` says status 0 and the UI works. Only the
behavioural check sees it.

**Secrets-cache freshness is the second case, and it moved here from a weekly
agent.** `com.jkrumm.secrets-freshness` fired once a week (Mon 09:15), so a cache
going stale on a Tuesday was invisible for six days — six days of services
potentially coming up credential-less with nothing reporting it. The check now
runs in the 300s script and pushes `MacMini Secret Seed - Push` (8-day threshold,
mtime only, never decrypts), on exactly collie's terms: its own monitor because a
stale cache does not fail with tailscaled/sshd/herdr, and a silent skip when
`~/.config/secrets/freshness-push-url` is absent. Two follow-ups: the weekly
LaunchAgent and `scripts/secrets-freshness-check.sh` are now redundant and should
be removed, and that monitor's `interval: 691200` in
`homelab/uptime-kuma/monitors.yaml` was sized for a weekly pusher — its
missed-heartbeat arm is now 8 days too lax.

**Push monitors are fully declarative — no browser step.** `make uk-sync`
creates them, proven on 2026-07-28 when it created `MacMini Collie - Push`
(id=205) against `uptime-kuma:2` with `uptime-kuma-api` 1.2.1. The push token is
retrievable in the same session, so create-and-wire is one scripted pass:

```bash
# on homelab, monitor id from the uk-sync output
op run --env-file=.env.tpl -- uptime-kuma/.venv/bin/python -c \
  'import os; from uptime_kuma_api import UptimeKumaApi
   api=UptimeKumaApi("http://localhost:3010")
   api.login("jkrumm", os.environ["UPTIME_KUMA_PASSWORD"])
   print(api.get_monitor(<id>)["pushToken"])'
# → https://uptime.jkrumm.com/api/push/<token> into a chmod-600 file
```

Note `--username` defaults to `jkrumm` in sync.py, not `admin` — an ad-hoc
script that assumes otherwise fails the login and returns an empty token rather
than an error. Only `active` is genuinely unsupported for push monitors.

Seven comments in `homelab/uptime-kuma/monitors.yaml` and one in `sync.py`
asserted the opposite for months. They were stale, believed, and reasoned
from — all now corrected. Treat a "this isn't supported" comment as a claim to
re-test, not a constraint, especially where the call site says otherwise.

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

## Upstream drift (mini only)

**Two halves of the update story were built and the middle was missing.**
`make brew-upgrade` is a guarded upgrader that asserts its own invariants;
the heartbeat above fails loudly on a broken host. Neither ever says *a pin
has drifted* — so the collie plugin sat **five releases behind** (0.17.0 →
0.22.0, two of them security fixes on a shell-equivalent surface) and was
found by hand, months later, by accident. `make drift-check` closes that.

| Command | Does |
|-|-|
| `make drift-check` | Run once, print per-component drift. Read-only. |
| `make drift-check-setup` | Dev-host gated: install `com.jkrumm.drift-check` (daily 09:40) |
| `make drift-check-teardown` | Unload + remove |

It watches what nothing else does: the commit pin (`COLLIE_REF`), the version pins compiled into caddy (`XCADDY_VERSION`,
`CADDY_DNS_MODULE_VERSION`), brew-upgrade recency, and pending macOS updates.
Pins are read out of the **Makefile**, never duplicated.

Tag resolution is shared with `make collie-upgrade` via
`scripts/lib/github-tags.sh` rather than copied. The subtle half is
`tag_commit`'s annotated-tag peel: `herdr plugin install --ref` pins the
*dereferenced* commit, so reading the tag object's own sha instead reports drift
that no upgrade can ever clear — and a second copy of that logic is a second
chance to get it backwards, in the one place where wrong looks exactly like
right.

**It reports and never upgrades, deliberately.** The hazard on this machine is
not a compromised release — `brew-upgrade.sh`'s header settles that — it is
*silent config revert*: caddy loses its DNS module and nothing fails for ~60
days; colima's plist reverts and nothing fails until the next power cut. An
unattended upgrader on the host that runs herdr, colima, sideclaw, Hermes and
every dev door is a mechanism for introducing exactly that at 3am with nobody
watching. Same trade as the caddy/mosh pins, and as the runaway reaper's refusal
to kill.

That stays true with `make collie-upgrade` in the tree, and the pair is the whole
point: **notice unattended, apply attended.** The applier is human-invoked, needs
a TTY, and refuses to run from automation — it removes the tedium of upgrading,
never the decision.

Four decisions that are not arbitrary:

- **Its own scheduler**, breaking the "one scheduler, N monitors" rule collie
  and secrets-freshness follow. Every check here is a **network call**, and the
  300s agent runs `maxretries 0` and deliberately refuses to touch GitHub for
  exactly that reason — a provider outage would page as "dev host down". Drift
  moves in days; daily is the right cadence and it needs its own agent to have
  one.
- **Age grace, not bare "is it behind".** A drifted pin is named in the msg
  immediately but only FAILS after `DRIFT_GRACE_DAYS` (14). The 1Password backup
  monitor already taught this: it "had spent large stretches red as a nag, which
  is how you train yourself to ignore it". The clock is keyed on the
  **component, never the version** — keying on the version lets a fast-releasing
  upstream reset it to zero forever.
- **brew is a recency stamp, not an outdated count.** homebrew/core moves daily,
  so "something is outdated" is true almost always and would sit red
  permanently. The alertable fact is that the *guarded upgrader has not run* —
  `brew-upgrade.sh` writes `~/.local/state/brew-upgrade/last-success`, and
  `drift-check-setup` seeds it to *now* rather than leaving it absent, because a
  monitor whose first act is to report a fault it invented is one you learn to
  disbelieve.
- **macOS is read from Apple's own cached scan** (`defaults read
  /Library/Preferences/com.apple.SoftwareUpdate RecommendedUpdates`), not
  `softwareupdate -l` — the background scan already ran, so the answer is in a
  plist and costs nothing instead of tens of seconds and a network round trip.

A network failure degrades to **`skipped`** in the msg and never to DOWN;
"GitHub was unreachable" and "you are five releases behind" are opposite
conclusions and only one of them is your problem. Both paths are tested rather
than asserted — backdate a `first-seen` entry and it goes stale and exits 1;
point `GIT_BIN` at `/usr/bin/false` and all four pin checks report `skipped`
with exit 0. The push URL file is optional and its absence silent, same contract
as the collie and secrets monitors, so the agent is useful on a machine with no
Kuma wiring at all.

**Bash 3.2**, same constraint and same reason as `devhost-health-check.sh`: the
plist sets no PATH, launchd hands over `/usr/bin:/bin:/usr/sbin:/sbin`, and
`/usr/bin/env bash` there is Apple's 3.2. Newline-delimited strings, never
arrays.

## 1Password vault backup — auto-trigger (MacBook only)

`opbackup` (`scripts/backup-1password.py`) exports every vault, age-encrypts it
in memory and rsyncs the ciphertext to homelab. It was documented as weekly and
was not: 12 runs between 2026-04-02 and 2026-08-01, gaps of **6–22 days**, median
~10. The 8-day Uptime Kuma monitor had therefore spent large stretches red as a
*nag*, which is how you train yourself to ignore it.

`com.jkrumm.opbackup` (`make opbackup-setup`, opt-in per machine) fixes the
remembering. It does **not** make the backup unattended, and must never be made
to: the first `op` call raises a biometric approval, and the only ways around
that are an `op` service-account token or a long-lived `OP_SESSION_*` — i.e.
parking a credential that can export every vault you own on a laptop's disk.
The design goal is a prompt that arrives at a sane moment, not no prompt.

| Command | Does |
|-|-|
| `make opbackup-setup` | Seed the stamp from the newest remote backup, install + load the agent |
| `make opbackup-check` | Run the guard once; prints which precondition stopped it. `FORCE=1` to back up now |
| `make opbackup-teardown` | Unload + remove the plist (stamps kept) |

**Hourly, not daily, and `RunAtLoad` is the wrong key entirely.** `RunAtLoad`
fires when the agent is *loaded* — login or reboot — never on wake, and
launchd.plist(5) says outright to avoid it. The catch-up wanted here is
`StartCalendarInterval`'s: *"Unlike cron which skips job invocations when the
computer is asleep, launchd will start the job the next time the computer wakes
up... coalesced into one event."* `StartInterval` explicitly does **not** do this
(a fire missed while asleep is lost). A bare `Minute` wildcards every other
field, so `{Minute: 17}` is every hour — which matters because a single daily
fire that lands at a locked screen is skipped with the next chance 24h out, so a
laptop shut at 10:00 drifts red while sitting open all afternoon.

**Every real decision lives in `scripts/opbackup-auto.sh`**, ordered
cheapest-first, and each one exits **0** — a skipped run is the normal case, not
a failure launchd should see: backend is `op` (never the mini) → success stamp
>5d → no attempt within 6h → screen unlocked → 1Password desktop running →
homelab reachable. 23 of 24 fires cost one `stat`.

**The attempt stamp is the part that makes it liveable.** A real attempt costs a
Touch ID approval, so declining one must not mean being asked again in 60
minutes forever — that is precisely the habit (dismissing 1Password dialogs
reflexively) that would make automating this a net security *loss*. Freshness and
re-prompting are therefore two separate stamps in
`~/.local/state/opbackup/`, and `opbackup-setup` backdates the success one to the
newest backup already on homelab so installing never fires a surprise prompt.

Two probes are worth knowing because the obvious spelling of each is wrong.
Screen lock is `ioreg -n Root -d1 -k CGSSessionScreenIsLocked` — the key is
**absent entirely** while unlocked, not `No` — and it is read into a variable
rather than piped to `grep -q`, because `set -o pipefail` turns that early exit's
SIGPIPE into a false failure (a trap this repo has already paid for once).
Reachability is checked **before** the prompt: failing at the rsync leg would
mean having spent an approval and ~90s of `op` calls for nothing.

**Automation adds no standing access** — no token, no key, no service account;
the age recipient is a public key and its private half stays in 1Password plus
paper. What it did add was closed in the same change: output now lands in a log
file rather than a terminal, so `backup-1password.py` prints one-line errors
instead of tracebacks (`~/Library/Logs/opbackup.log`, declared in
`scripts/log-rotate.sh`, never `/tmp`); and the remote had accumulated 12
never-pruned dumps, each a complete copy of every credential owned and each still
decryptable with the age key **after** the passwords inside it have been
rotated — so a April dump exposes the password changed in May. `prune_remote()`
keeps the newest 8 plus the newest of each calendar month, deleting an
**explicit** regex-validated filename list, never a remote glob.

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
  LaunchAgent that runs `battery/batt-reset.sh` at **09:00** daily (`RunAtLoad`
  false, so installing it never clobbers a live boost). This is what makes a
  100% boost *temporary* — it expires the next morning. Changing the resting
  default means editing both the script's hardcoded `80` and the Makefile
  `LIMIT ?= 80`.
- **Multi-day pause.** For a boost that should survive more than one morning
  (e.g. traveling for a week), `batt-reset.sh` checks
  `~/.config/batt/pause-until` (an epoch timestamp) before resetting — if still
  in the future it skips the reset and leaves the cap alone; once past, it
  deletes the file and resumes normal daily resets. Written by either
  interface: Raycast's "Pause days" field, or `make batt-limit LIMIT=100
  DAYS=7`. Setting a cap with no pause days always clears the file, so it also
  doubles as the cancel/resume-early path.
- **Raycast control.** Self-authored **Script Commands** (no extension/build, no
  deps — `raycast/battery-{limit,status}.sh`) symlinked as `~/.raycast-scripts`.
  "Battery Limit" offers an 80/90/100 dropdown plus an optional "Pause days"
  text field; "Battery Status" shows state and, if paused, the resume date.
  One-time: point Raycast at the dir — **Settings (⌘,) → Script Commands**, a
  top-level tab, not nested under Extensions (moved there at some point;
  `com.raycast.macos.plist` even carries a stale
  `fallbackSearches_didMigrateScriptCommands` key from the move) → **Add Script
  Directory** → `~/.raycast-scripts`.

| Command | Purpose |
|-|-|
| `make batt-setup` | One-time per MacBook: daemon + 80% cap + daily-reset agent + Raycast symlink. `LIMIT=N` to set a different initial cap. |
| `make batt-limit LIMIT=100` | Change the cap now (or just flip it in Raycast). Default `LIMIT=80`. |
| `make batt-limit LIMIT=100 DAYS=7` | Same, plus pause the daily 80% reset for 7 days. Omit `DAYS` to clear an existing pause. |
| `make batt-status` | Show charging state + current limits, and the pause resume date if paused. |

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

**The login Keychain is not a headless credential store, and it fails quietly.**
`security find-generic-password` returns non-zero when the login keychain is
locked — what a launchd job gets the moment the GUI session is gone. Both callers
swallowed that into an empty string (`|| echo ""`, `|| true`):
`brain/brain-backup.sh` has therefore committed the literal fallback message
`chore(brain): nightly vault sync` on both commits it has ever made, and
`litellm/bin/start-litellm.sh` would have come up credential-less. Both now fall
back to `secrets-run read` on the same `op://common/anthropic/{API_KEY,BASE_URL}`
refs `make setup` cached those Keychain entries from, and both say so on stderr.
litellm exits 1 when neither source resolves; brain-backup degrades to the
fallback message loudly, on purpose — a generated commit message is not worth
skipping the backup over. `brain-backup.sh` also needed `$HOME/.local/bin` on its
PATH: that is where `claude` lives (it is not Homebrew-managed), and its absence
is why the generated-message path had never once run.

**`make secrets-rotate` refuses on a detached mini rather than hanging.** Rotation
is biometric end to end — the 1Password key backup, then every `op read` inside
`secrets-seed.sh` — so it needs a human *at the mini* (Screen Sharing or an
attached keyboard), and `op signin` is not the fix there, it is the hang. The
preflight probes `op whoami` with stdin closed and a 15 s bound, then dies naming
the machine. There is no MacBook-only rotation path today: the age key and the
cache both live on the mini, and only the seed half can be driven remotely.

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

**Changing how Claude *talks*:** that is `config/output-styles/Direct.md`, not
CLAUDE.md. The split is deliberate and the two are not interchangeable:

| Concern | Lives in | Why |
|-|-|-|
| Response shape, autonomy, question budget, delegation posture | `output-styles/Direct.md` | Appended to the end of the system prompt — the last thing read, and it survives a `/clear`. Instructions this behavioural sit poorly among 200 lines of repo facts. |
| Project/machine facts, routing, conventions | `CLAUDE.md` | Reference material the model looks things up in. |

`keep-coding-instructions: true` is load-bearing — the frontmatter default is
**false**, which *drops* Claude Code's built-in software-engineering system prompt
and leaves a chatty generalist holding a `Bash` tool. The style is read at session
start only; `/clear` or a new session to apply an edit. It does **not** reach
subagents — a subagent's tone belongs in its own `agents/*.md`.

Claude Code 2.1.x ships a stock directive — *"Do not call the AgentTool unless the
user requested it"* — which is why an Opus orchestrator grinds through multi-file
edits inline instead of delegating. The style's standing authorization is the
counterweight, and it has to be *standing*: re-authorizing per session is exactly
the tax it exists to remove.

The density rule and the global/per-project/rules/output-style layering are stated
once, in the global file's "Config hierarchy" — not restated here. What is specific
to *this* file: at 1800+ lines it is the largest in the tree, and the narrative
sections (remote-dev, collie, devhost-health, homebrew, theme) are the ones to move
to `docs/` when trimming. The tables and gotchas stay.

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

The same lesson recurred on 2026-07-31 in a different shape: the tokenization is
right, but the *verb scope* is too wide. `docker builder prune`, `docker image
prune` and `docker container prune` address the daemon, not a project — there is
no secret to inject, no compose file, no deployment order, and no `make` target
that covers them. The hook blocked all three during a planned disk reclaim,
leaving 86 GB of reclaimable layers and build cache in place (`docker system df`:
48.6 GB images + 37.8 GB build cache). `docker system df` is already allowed as
read-only, so the machine can be *measured* but not *cleaned*. Carve the
host-level prune verbs into the allowlist — and keep `docker volume prune`
blocked: 12 of this machine's 23 volumes are dangling right now, including
`modelpick_postgres_data`, `student-enrolment_redpanda-data` and
`prometheus-feuer-agent_feuer_state`, which back real stacks that merely happen
to be stopped.

**settings.json changes:** update `config/settings.template.json`, then `make setup`
to merge into the live file. Never edit the live settings.json for persistent changes.

## Agent logs: `~/Library/Logs`, never `/tmp`

**A LaunchAgent that logs to `/tmp` eventually writes into an unlinked inode, and
nothing anywhere reports it.** macOS's periodic cleanup *deletes* files in `/tmp`
untouched for 3+ days; launchd opens `StandardOutPath`/`StandardErrorPath`
**once, at spawn**, and there is no way to make it reopen. So after a sweep a
long-running `KeepAlive` agent keeps writing to a file that no longer has a name.
Measured on the mini 2026-07-31: `lsof -p 895` held `/private/tmp/sideclaw.log`,
`.err` and `.db` open while `ls` found none of them. sideclaw and litellm had no
post-mortem at all, and sideclaw's ephemeral SQLite file existed only inside the
process.

Every agent this repo installs now uses `~/Library/Logs/<name>.{log,err}` — which
also closes a `/tmp` symlink-clobber class for free, since `/tmp` is
world-writable. Interval- and calendar-driven agents re-create their file each
spawn so they never hit the unlinked case, but their *history* is deleted just
the same, which for an audit log (`brain-backup`) is the same loss.

Moving off `/tmp` removes the only thing that had ever bounded these files, so
**`make log-rotate-setup`** replaces it: hourly, **copytruncate** (`cp` then
`: > file`), 16 MB cap, one `.1` generation. Copytruncate rather than rename
because a rename does exactly what the sweep did — the fd follows the inode.
Truncation is safe because launchd's stdio fds are `O_APPEND`, probed directly
with a throwaway agent rather than assumed. `newsyslog.d` is not an option: it
needs root, and this machine's root password is deliberately MacBook-only. The
file list in `scripts/log-rotate.sh` is **declared, never globbed** —
`~/Library/Logs` also holds Apple and vendor logs.

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
