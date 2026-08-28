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

`Brewfile` (repo root) is the single source of truth (taps + formulae + casks) —
its **git history is the supply-chain audit trail**. `make setup` installs it in
one `brew bundle install` (`_setup-packages`); npm-global/uv tools stay
Makefile-managed (need Node/uv on PATH, not ready that early in bootstrap).

- `make brew-check` — verify machine == Brewfile (read-only).
- `make brew-diff` — list installed-but-undeclared packages (dry-run).
- `make brew-dump` — regenerate from machine, then **review the git diff** before committing.

Adding a package: `brew install X` → `make brew-dump` → review diff → commit.

Hardening (`config/zsh/brew.zsh`): `HOMEBREW_REQUIRE_TAP_TRUST=1` (`_setup-packages`
auto-trusts exactly the Brewfile's declared taps before bundling — an
untrusted tap otherwise aborts the whole install), `HOMEBREW_NO_INSECURE_REDIRECT=1`,
`HOMEBREW_NO_ANALYTICS=1`. Auto-*update* (metadata refresh) stays on.

### Upgrading — `make brew-upgrade`

Auto-*upgrade* stays off — not for npm-style supply-chain reasons (homebrew/core
is a reviewed-PR bottle build, not a maintainer tarball), but because **three
packages silently revert local config on upgrade, with no error**:

| Package | What an upgrade breaks | Visible after |
|-|-|-|
| `caddy` | replaces the xcaddy-built binary; `dns.providers.cloudflare` vanishes | ~60 days, when the wildcard cert fails to *renew* |
| `mosh` | ALF stores mosh-server's *resolved* Cellar path, so the upgrade un-allows it | next inbound `dev` — ssh handshakes, then every datagram drops |
| `colima` | regenerates the plist, restoring the inverted `KeepAlive {SuccessfulExit=true}` | only after a *dirty* shutdown — the exact event this setup exists to survive |

`caddy`/`mosh` are **pinned** (`brew pin`, converged by `_setup-packages` on every
`make setup`); `colima` is deliberately left unpinned (it's the Docker runtime —
pinning means sitting on an unpatched hypervisor) and instead **asserted**
post-upgrade plus health-checked every 5 min.

| Command | Does |
|-|-|
| `make brew-upgrade` | Converge pins, upgrade outdated homebrew/core formulae, assert all three invariants |
| `make brew-upgrade-dry` | True no-op preview — touches nothing |

Casks/third-party-tap formulae are reported, never auto-upgraded (route through
`/upgrade-deps`) — a held package that's outdated prints its own
`brew unpin X && brew upgrade X && make <fixup> && brew pin X` follow-up.

Full rationale (why the npm framing was wrong, why colima stays unpinned, cask
trade-offs): `docs/homebrew.md`.

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

The mini is the dev host; the MacBook is a thin client. Full mental model,
war-stories and verification steps: **`docs/remote-dev.md`**. Four layers, none
substitutes for another — most design confusion comes from collapsing them:

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

**`make herdr-setup`** wires three things. `herdr integration install claude`
writes a SessionStart **hook** (`~/.claude/hooks/herdr-agent-state.sh`) — tells
*herdr* about the agent (real `agent_status`, not `unknown`; the reason to prefer
herdr over tmux). `scripts/herdr-skill-sync.sh` regenerates `skills/herdr/SKILL.md`
from `herdr --skill` — tells the *agent* about herdr. It then starts the
**server only on the dev host** (`cache` backend marker); a thin client gets the
hook + skill but no server.

**The skill is GENERATED from the binary, never hand-written** (`herdr --skill`)
— a hand-maintained copy goes stale silently on every `brew upgrade herdr`, and
stale CLI syntax is worse than none. Tracked in git anyway (not generated
straight into `~/.claude`) so an upgrade that changes agent instructions arrives
as a reviewable diff. The sync refuses to write a short/frontmatter-less file.

**`HERDR_ENV=1`** (+ `HERDR_PANE_ID`/`_TAB_ID`/`_WORKSPACE_ID`/`_SOCKET_PATH`/
`_BIN_PATH`) is how an agent knows it's inside herdr — the skill's first
instruction tests it and stops if unset, so the same skill is inert on the
MacBook and live on the mini with no branching. **Vars are inherited at spawn,
not tracked** — a `claude --bg` daemon that outlives its pane keeps a stale
`HERDR_PANE_ID`; resolve the live one with `herdr pane current --current`.

Three load-bearing constraints:

- **The server must start as a session leader** (`herdr/herdr-server-start.py`,
  pinned into the brew plist by `_herdr-supervise`) — a bare launchd job is not
  one (`getsid(0) != getpid()`), which used to make every `desk` launch ask to
  "restart the remote server" (always answer **N** — restarting outside brew
  services kills every pane). `brew upgrade herdr` / any `brew services
  start|restart` silently strips this wrapper (same trap as colima's plist);
  `brew-upgrade.sh` asserts it. Apply a fix to the *running* server with
  `make herdr-restart YES=1` (bootout+bootstrap — never `brew services restart`
  or `launchctl kickstart -k`) — it **kills every pane**, so it's human-timed,
  never part of `make setup`.
- The hook's settings entry lives in **`config/settings.template.json`**, not
  wherever herdr wrote it — `make setup`'s hooks-merge is what makes it survive
  a re-run.
- The tracked launch command is **guarded** (`test -f … && bash … || true`) —
  herdr's own unconditional version fails 127 where the integration was never
  installed.

### Notes — `prefix+e` opens the repo's page in the brain vault

**`prefix+e` opens `Projects/<repo>.md` from `~/SourceRoot/brain` in `$EDITOR`,
in a herdr popup.** `scripts/brain-note.sh` resolves the repo from
`HERDR_ACTIVE_PANE_CWD` and creates the page (house frontmatter, wikilinked from
`Projects/Projects.md`) if it doesn't exist. Replaced the `herdr-notes` plugin
on 2026-08-04 — that kept one untracked, unbackuped `<workspace-id>.json` per
workspace, a third place notes could live next to the vault and TickTick.
**Per repo, not per workspace**; new pages must stay wikilinked or `vault-lint`
warns. **The popup runs on the server** — via `desk` it edits the *mini's*
checkout; brain-sync (GitHub, every 5 min) reconciles both machines, and the
mini's lane pushes but never commits, so a note lands via the nightly
`brain-backup` sweep. Uses `popup` (session-modal, closes on exit) not a docked
pane — every failure path pauses on exit, or the error flashes unreadably.

`~/.zshenv` (`_setup-zshenv`, appends) is the only file a non-interactive
`ssh host -- cmd` sources — carries Homebrew **and** `~/.local/bin` (`claude`,
`secrets-run`, `imgcli`) onto that PATH, and is what lets `mosh-server` be found
when mosh launches over ssh before handing off to UDP.

**`claude --bg` reparents to PID 1** (`claude daemon run`) and survives
ssh/herdr/lid-close independently — use for anything that must not die. Bounds
herdr's crash risk: `kill -9` on the herdr server restores the workspace by name
but with a new `terminal_id`, so **a herdr crash restores the layout and loses
every process running in it**. `--bg` takes the positional prompt; conflicts
with `-p`.

**Surviving independently ≠ launching independently, and the gap is silent.**
Claude Code's Max credentials live in the **login keychain**, unreachable over
ssh — `ssh mini 'claude --bg …'` starts a daemon that silently falls back to API
billing while still showing healthy in `claude agents`. The herdr server is a
brew service under launchd *inside the GUI session*, so anything it spawns
(herdr panes, `rd bg`) inherits keychain access and works fine — the mini's
unattended auto-login (FileVault off, real password login, no human present)
brings the keychain up unlocked at boot, which is what makes this a non-problem
in practice. **Only a raw `ssh mini 'claude …'` fails**, and `rd bg` exists so
nothing needs that path.

**`config/zsh/claude-auth.zsh` is an ARMED fallback** (`claude()` zsh function
resolving `op://mini/claude/oauth-token` via `secrets-run` into
`CLAUDE_CODE_OAUTH_TOKEN` — never `ANTHROPIC_API_KEY`, which flips billing to
API credits). It probes the real keychain credential first (~245ms, uncached —
a cached verdict once produced a false-positive that suppressed the fallback for
an hour while `claude` ran with **no credential at all**, so there is no cache),
falling back to the token only on failure — which is also what keeps the
keychain's rolling refresh alive. It's a **function** (not a `~/.local/bin` shim
— that path gets rewritten by the updater), passes the token by **prefix
assignment** (not `env VAR=…`, which leaks into `ps auxww`), and **self-gates on
the `cache` backend marker** (on the MacBook this would prompt biometric `op` on
every launch). `check_claude_auth` (`scripts/devhost-health-check.sh`) grades
three states — keychain ok / keychain dead but token working / neither — and
only the last fails the heartbeat; the middle state passes (Max billing intact)
but is named in the msg. Restore the keychain credential with `/login` in a
**herdr pane on the mini** (GUI-session child) rather than re-minting — the
token is a one-year credential with no refresh and no reliable revocation, a
downgrade from the keychain's self-refreshing one. Full reasoning:
`docs/mini-headless-checklist.md` L3.3, `dotfiles-private/docs/security-review.md`.

### Unattended boot posture (mini only)

Three settings survive a power cut with no human: FileVault **off**, automatic
login **on**, `pmset -a autorestart 1` (its absence is silent — the machine just
never powers back on). `make lock-at-boot-setup` closes the resulting window:
**screen lock ≠ keychain lock**, so an unattended login otherwise leaves the
whole session reachable behind a password prompt. Two halves — GUI screen-lock
set to *Sofort* (`sysadminctl -screenLock immediate` has no interactive form,
needs `-password` inline) plus a `RunAtLoad` agent firing `pmset displaysleepnow`
— and the setup target refuses to install the second without the first already
applied. `make lock-at-boot-check` reports both plus live lock state. (`CGSession
-suspend` no longer exists on macOS 26; `osascript` ⌃⌘Q can't get TCC on a
headless box — full scope: `docs/remote-dev.md` → "What used to take this down".)

**`scripts/remote-dev.sh` (`rd`) puts work on the mini with no terminal needed**
— routes off the `~/.config/secrets/backend` marker (local exec on the mini, one
ssh hop from the MacBook):

| Command | Does |
|-|-|
| `repos [filter]` | repos on the host, branch + dirty count |
| `work <repo>` | herdr workspace + claude, **idempotent** (refocuses, never stacks) |
| `rd bg <repo> '<task>'` | durable daemon, spawned *through* a herdr pane (keychain reason above) |
| `agents` | both lanes, deduped on session id |
| `rd read <agent>` / `rd say <agent> '…'` | watch / steer without attaching |

Commands take a repo **name**, never a path — resolution happens on the host.
`config/ssh_config` gives `Host mini` real `ControlMaster` (one handshake, one
biometric approval for herdr/cmux's several connections) and
`SetEnv TERM=xterm-256color` (fixes cmux #2969 doubled-keystroke bug).

### Database access — MacBook → mini (`make db-tunnel-setup`)

The mini's dev databases bind `127.0.0.1`, so a GUI client on the MacBook needs a
forward: `com.jkrumm.db-tunnel` is a `KeepAlive` LaunchAgent holding one
long-lived `ssh -N` with every `-L` declared in `dbtunnel/tunnels.conf`
(`make db-tunnel-status` to probe). **Local ports are real port + 30000**
(33306, 36379) since this machine runs its own copy of the same stack. Not
`tailscale serve --tcp` (would publish a raw MySQL socket to every tagged
device) and not Caddy (no layer4 module, MySQL isn't HTTP).

Four launchd-specific traps, each cost a debugging cycle: launchd's inherited
`SSH_AUTH_SOCK` is Apple's own agent with **zero identities** (prefer
1Password's socket explicitly); `-o IdentityAgent=<path>` needs literal quotes
around 1Password's "Group Containers" path or ssh silently mis-parses the `-o`;
`ControlMaster=no`+`ControlPath=none` are mandatory (else the tunnel dies when
`ssh_config`'s shared `ControlMaster` session exits); ssh must run in the
**foreground** (`-f` looks like a clean exit to KeepAlive → respawn loop) —
reconnect instead via `ServerAliveInterval=15 × CountMax=3`.

### File shuttle — the mini's home mounted over SMB (`~/Shuttle`)

`smb://mini/jkrumm` mounted from the MacBook, `~/Shuttle` the agreed drop folder
— for ad-hoc **human** file movement only (not code/repos → `rd`/git; not vault
pages → brain-sync; not anything an agent reads → must live on the mini, the
mount is client-side and dies with the MacBook). `tcp:445` granted
`tag:mac → tag:mac`.

**The gotcha that costs an hour: a listening `:445` + running `smbd` ≠ a working
server.** macOS stores no NTLM (`SMB-NT`) hash for a local account by default,
so `smbd` refuses *every* principal identically — guest, password, Kerberos,
even on loopback — with an error (`Authentication error` / `STATUS_LOGON_FAILURE`)
that reads like a network fault. **Minting the hash is GUI-only, cannot be
scripted** (no `pwpolicy`/`dscl`/`sysadminctl` verb injects it) — System
Settings → Sharing → File Sharing ⓘ → Options → tick the user → type the
password; the prompt computing `MD4(utf-16le(password))` *is* the mechanism.
Verify with the data (`ShadowHashData` → `grep SMB-NT`), never the setting.
Kerberos is not an escape hatch (`kinit` against the LKDC fails headless, and no
port 88 grant exists anyway). Guest access is `sharing -g 000|001` (**three
digits**, `afp,ftp,smb` order — `-g 0` silently no-ops).

### Two dev-server doors: port-based (`.ts.net`) and clean (`.mini.jkrumm.com`)

**`config/Caddyfile` is the single app registry.** Every `<name>.test {
reverse_proxy localhost:PORT }` block automatically gets a clean door at
`https://<name>.$DEV_DOMAIN` — a new app needs zero work beyond the `.test`
block it already needs. Read via `caddy adapt` + walking the route JSON
(`scripts/lib/caddy-registry.py`), never regexed (defeated by the non-`.test`
`metabase.iu-aws.de` block, snippet imports, and `fpp.test`'s `header_up Host`
variant — that last one is carried over automatically). `~/.config/caddy-tailnet.ports`
is an **opt-out + flags** file (`exclude <name>`, `portdoor`, `host=rewrite`),
not a second app list — those two used to drift silently (17 apps vs 4). A
`.test` block the extractor can't reduce to one name+port (two `reverse_proxy`
handlers, multi-host match, non-loopback upstream) is **skipped**, never
guessed at — split it into one block per port instead. The extractor refuses to
emit an empty registry (a broken walker would otherwise tear down every door
silently) and every input/output path is overridable so it's testable against
scratch files without touching the real include.

`make caddy-tailnet` (`scripts/caddy-tailnet.sh`) generates **two additive**
doors onto the same dev servers:

1. **Port-based** `https://<mini-magicdns>:<port>` — cert straight from
   tailscaled, zero DNS/ACME dependency, the fallback that must survive door 2
   breaking. **Opt-in per app** (`portdoor`) — a port door binds the app's own
   port number on the tailnet interface, colliding with anything else holding
   that address (`tailscale serve`, any `0.0.0.0`-bound dev server), so
   auto-generating all of them would make Caddy squat ports Docker later fails
   to bind.
2. **Clean** `https://<app>.mini.jkrumm.com` — one wildcard site block on
   `:443`, `host` matchers → `localhost:<port>` each, single wildcard
   Let's Encrypt cert via Cloudflare DNS-01. **Default-on for every app**, opt-in
   per *machine* (needs `DEV_DOMAIN` + a chmod-600 Cloudflare token file — an
   unseeded machine silently gets door 1 only).

| Command | Purpose |
|-|-|
| `make caddy-tailnet` | Dev-host only: regenerate both doors, validate, reload. |
| `make caddy-dns-build` | Dev-host only, one-time / after any `brew upgrade caddy`: rebuild Caddy with the Cloudflare DNS module (stock Homebrew Caddy ships **none** — `caddy list-modules \| grep dns.providers` is empty). **Silently reverted by a bare `brew upgrade caddy`; nothing errors until the wildcard cert fails to renew ~60 days later** — `check_dev_vhosts` asserts the module + cert >21 days left + the `health.$DEV_DOMAIN` A record on every 5-min heartbeat run. |

Load-bearing gotchas:

- **Upstreams dial `localhost:<port>`, never `127.0.0.1:<port>`** — Vite falls
  back to binding `::1` alone when its port is held elsewhere on `0.0.0.0`, and
  a hardcoded `127.0.0.1` upstream then 502s against a plainly-running app.
- **One site block for every app, never one per app** (Caddy 2.10+ issues one
  wildcard cert per block; N blocks would race Let's Encrypt's ~50/week limit).
- **`bind 127.0.0.1` on every `.test` block** is what makes granting `:443`
  broadly on the tailnet interface safe — otherwise this Caddy would answer on
  the LAN too and collide with the wildcard block's own listener.
- **`servers { protocols h1 h2 }`** disables HTTP/3 globally — quic-go's
  1280-byte initial packet exceeds the tailnet MTU (caddyserver/caddy#7885),
  causing intermittent Chrome-only failures otherwise.
- **502 vs 403** — 502 means the dev server isn't running; 403 means it's
  running and rejecting the Host header (the common one) — fix by adding
  `.mini.jkrumm.com` to `server.allowedHosts` (Vite/Astro) or
  `*.mini.jkrumm.com` to `allowedDevOrigins` (Next — no leading-dot support).
- **DNS negative-caches at two layers you don't expect**: the LAN router (NODATA
  cached ~30min after adding a new A record) and macOS `mDNSResponder`
  (`dscacheutil -flushcache` does **not** clear it — only
  `sudo killall -HUP mDNSResponder`). `check_dev_vhosts` uses `dig` directly, so
  it can honestly report "in sync" while a browser still shows
  ERR_NAME_NOT_RESOLVED from its own cache.
- Status page (`https://mini.jkrumm.com`) probes are same-origin `handle
  /_up/<name>` routes nested inside the wildcard fallback (`rewrite * /` inside
  each, or a healthy app 404s on its own probe path). It also lists live
  `tailscale serve`/Funnel rows (second table, `public` marked) read straight
  from tailscaled, not the declared conf — a snapshot, not a drift check.

**Three apps carry `portdoor`** (argo 7715, modelpick 7727, jkrumm 7728) with
**`host=rewrite`** — enough to keep the fallback exercised, few enough to avoid
squatting ports; `basalt-playground` (7710) is deliberately excluded (the exact
port where a port door once broke Vite's fallback). The ACL grant is
`tag:devhost → tag:mac/tag:phone/tag:tablet` on `tcp:443` (additive `tag:devhost`,
not `tag:mac` — a bare `tag:mac` grant would leak dev servers to the work
MacBook). **Tagging a device is console-only** and independent of pushing the
grant — both are silently inert without the other. Verify the live filter with
no API key from the mini itself: `tailscale debug netmap` (parse `PacketFilter`
for a `(443, 443)` row) — the only path that works when `op://Private/*` is
refused by the cache.

Full walkthrough (apex-record handling, Kerberos/SMB asides, exact netmap
one-liner): `docs/remote-dev.md`.

## Collie — the phone control surface

[Collie](https://github.com/AltanS/collie) is a loopback-bound Bun bridge + PWA
that mirrors the herd on a phone: open a URL, see which agent is blocked, type
a reply. Third-party, **commit-pinned** (`COLLIE_REF`/`COLLIE_VERSION` in the
Makefile — a commit, not a tag, since `plugin install` re-clones every time) —
the only pinned plugin left since herdr-notes retired. Chosen over raw
ssh+mosh to the phone: no port-22 grant, no SSH key on a losable device.

**It is remote shell access by design, not "just a web UI"** — one bridge call
types arbitrary keystrokes into a live pane; treat the URL like a root login.
**The real gate is the ACL, not `COLLIE_TRUSTED_USER`** — every tailnet node is
tagged, not logged in, so the trusted-user check can't discriminate devices;
the grant is scoped to `tag:phone` specifically and **`tag:client` (TVs +
tablet) must never be granted**.

The hand-written `.env` (never templated) closes four gaps: `COLLIE_MULTI_SESSION=off`
(pins the bridge to one herdr session, not every named session); `COLLIE_PUBLIC_HOSTS`
listing **both** `host:8788` and bare `host` (defeats DNS rebinding —
`isHostAllowed` matches the full `Host` header by exact string); `COLLIE_SKIP_SERVE=1`
**mandatory** (serve is declared state here — `make tailscale-serve` resets and
would silently wipe collie's imperative `tailscale serve --bg` otherwise; the
real front door is the declared row on dedicated port **8788**, never funneled);
`COLLIE_HOST=127.0.0.1` (loopback only, serve terminates TLS and proxies in).

**Whatever starts the bridge must source the `.env`, or every hardening setting
above goes silently unset while the UI works perfectly** — the bridge reads
`process.env` only, never parses `.env` itself. This is why the health check is
**behavioural, not liveness**: a spoofed `Host` header must return 403 on
`/api/snapshot` specifically (the SPA shell at `/` answers 200 to any Host,
CSP-locked — a pathless probe reports the guard broken when it's fine).
Supervision is upstream's own LaunchAgent since collie 0.21.0 (`RunAtLoad` +
`KeepAlive`) — `make collie-setup` migrates off the old local plist and asserts
liveness + the rebind guard + real launchd supervision (a bare LaunchAgent only
starts at *login*, so a machine without auto-login degrades silently to an
unsupervised tier that dies on the next reboot).

| Command | Does |
|-|-|
| `make collie-setup` | Dev-host only: install/refresh the pinned plugin, `collie-ctl.sh start`, assert liveness + rebind guard + supervision |
| `make collie-upgrade` | Resolve newest tag, print changelog/diffstat/scope verdict, on `y` bump pin + reinstall + assert + commit (never `collie-ctl.sh update` — pulls branch head) |
| `make collie-status` | Read-only: LaunchAgent state, bridge health, rebind guard |
| `make collie-teardown` | Boot out both labels, uninstall the plugin (never `collie-ctl.sh uninstall` — it mutates declared `tailscale serve` state) |

The upgrade scope verdict is decision support, not a safety boundary — a
UI-only (`web/`) release is just as capable of malicious keystroke injection as
a bridge change, so it doesn't get treated as automatically safe; rollback on a
failed spoofed-Host assertion is what makes a bad release survivable. Refuses
to run unattended (no TTY, no `COLLIE_UPGRADE_YES=1`) or on a dirty `Makefile`.

**Monitoring is opt-in and separate from the devhost composite** (below) — a
machine without collie must not fail the heartbeat. Reports to its own Kuma
push monitor (`MacMini Collie - Push`), wired via `make uk-sync` (creates the
monitor) + a push-token file at `~/.config/uptime-kuma/collie-push-url`
(chmod 600); absent file = silently skipped.

Full rationale (the ACL-vs-trusted-user reasoning, the two upstream PATH/`.env`
fixes that made handover safe, the exact 403-vs-200 verification matrix):
`docs/collie.md`.

## Dev-host health heartbeat (mini only)

**Three** Uptime Kuma push monitors, one 5-min agent (`scripts/devhost-health-check.sh`
via `com.jkrumm.devhost-health`, opt-in per machine). `MacMini Dev Host - Push`
is the **composite**, covering thirteen components: tailscaled (state + node-key
expiry), sshd, herdr, mosh (binary + ALF allowlist), GitHub push credential,
clean dev-vhost door (`check_dev_vhosts` — Cloudflare DNS module, cert lifetime,
DNS A-record drift), memory/swap, launchd restart counts, six always-on services
(sideclaw, litellm, hermes gateway, colima, caddy, dnsmasq), `claude auth
status`, obsidian CLI, disk, and a report-only runaway reaper. `MacMini Collie -
Push` and `MacMini Secret Seed - Push` are **separate monitors** — the rule is
*absence, not independence*: a component that can be legitimately missing on a
good machine (collie not installed, cache not seeded) gets its own monitor, so
folding it in wouldn't page "dev host DOWN" for a feature this host lacks.
Everything merely independent (herdr fails with sshd/tailscaled when the mini
sleeps) stays one composite monitor — the failing component is just named in the
push `msg`, which is cheaper than N Kuma monitors saying the same thing at once.

| Command | Purpose |
|-|-|
| `make devhost-health-setup` | Install the agent. Refuses unless the push URL exists, prints the runbook to create it. |
| `make devhost-health-check` | Run once, print per-component status. |
| `make devhost-health-teardown` | Unload + remove. |

**Bash 3.2, and must stay one** — the plist sets no `PATH`, so `/usr/bin/env
bash` resolves to Apple's 3.2 (no `mapfile`, no `${var,,}`, no `"${arr[@]}"` on
a possibly-empty array under `set -u`) — checks accumulate into strings, never
arrays. **Push, not probe** — the ACL grants `tag:homelab → tag:vps` but not
`→ tag:mac`, so Kuma cannot reach the mini; opening an inbound grant purely for
monitoring would be new attack surface for something the mini can report on
itself.

**Transient tolerance** — a real power-cut test paged DOWN on pure boot noise
(two agents started 2m48s late during a deferred launchd bootstrap pass, not a
fault). Three env-overridable knobs absorb that: `DEVHOST_BOOT_GRACE_SECONDS`
(300 — every failing component reports `starting`, push stays UP),
`DEVHOST_TRANSIENT_FAILS` (3 — only FAILs on the third consecutive bad run),
`DEVHOST_REBOOT_NOTE_SECONDS` (600 — summary carries `host rebooted Ns ago`).
The boot grace covers **every** component, not just liveness ones (failures
cascade — `check_dev_vhosts` needs the tailnet IP, so it fails while tailscaled
is merely slow); the streak counter is **level-triggered only** —
`check_launchd_restarts` is a delta (true for one run per restart) and is the
sole component excluded from the streak, since silencing an edge event for 3
runs would just delay the page rather than absorb noise. None of this softens
"the machine is gone" — a dead host emits no push at all, which Kuma's own
missed-heartbeat (`maxretries 0`) still catches.

Two checks worth knowing the shape of: restart detection is a **delta** against
a state file, never a threshold on cumulative `runs` (else herdr's `Killed: 9`
from weeks ago pages forever); the runaway reaper gates on accumulated CPU time
**crossed with** lifetime average CPU (never instantaneous %CPU or accumulated
time alone — both false-page eventually) and only ever reports, never kills.
`claude --bg` daemons are excluded by name (PPID 1 + SourceRoot cwd, by design).

Collie's check is **behavioural, not liveness** — 200 on loopback **and** 403 on
a spoofed `Host` header, both against `/api/snapshot` specifically (`/` answers
200 to any Host — a pathless probe would report a healthy guard as broken).
Secrets-cache freshness moved here from a weekly agent (a Tuesday staleness was
invisible for six days) — pushes `MacMini Secret Seed - Push` on an 8-day mtime
threshold, never decrypts. `scripts/secrets-freshness-check.sh` is a **second,
still-live caller** — the MacBook's auto-reseed calls it over ssh as its last
step to refresh the heartbeat immediately rather than waiting out the 5-min
cycle; don't assume it's dead without `grep -rn secrets-freshness-check` first.

**Push monitors are fully declarative** — `make uk-sync` creates them and the
push token is fetchable in the same session via the `uptime-kuma-api` Python
client (`--username` defaults to `jkrumm`, not `admin`). The heartbeat asserts
credential **resolvability**, not push rights — no live GitHub call, since a
provider outage at `maxretries 0` would page as "dev host down"; the stronger
`git push --dry-run` claim lives in the on-demand `make remote-dev-doctor`.
Push token lives in a chmod-600 file, not 1Password (monitoring must survive a
stale secrets cache). `maxretries` must be **0** on every push monitor — the
default 3 turns a 10-minute time-to-DOWN into 40.

Full rationale (why each of the thirteen components was folded in vs given its
own monitor, the exact `uptime-kuma-api` scripting snippet, launchd/`op run`
traps hit while building this): `docs/devhost-health.md`.

## Upstream drift (mini only)

`make brew-upgrade` asserts its own invariants and the heartbeat above fails
loudly on a broken host, but neither ever says *a pin has drifted* — the collie
plugin once sat five releases behind (two security fixes) and was found by
accident. `make drift-check` closes that gap: watches the commit pin
(`COLLIE_REF`), caddy's compiled-in module versions, brew-upgrade recency, and
pending macOS updates — all read from the **Makefile**, never duplicated.

| Command | Does |
|-|-|
| `make drift-check` | Run once, print per-component drift. Read-only. |
| `make drift-check-setup` | Dev-host gated: install daily (09:40) drift-check agent |
| `make drift-check-teardown` | Unload + remove |

**It reports and never upgrades, deliberately** — the hazard here isn't a
compromised release, it's *silent config revert* (caddy's DNS module, colima's
plist), and an unattended upgrader on this host is a mechanism for introducing
that at 3am with nobody watching. `make collie-upgrade` is the paired
human-invoked applier (needs a TTY, refuses automation): **notice unattended,
apply attended.**

Four deliberate design choices: **its own scheduler** (every check is a network
call; the 300s heartbeat deliberately never touches GitHub, so drift needs a
separate daily cadence); **age grace, not bare "is it behind"** (`DRIFT_GRACE_DAYS`
14, keyed on the component so a fast-releasing upstream can't reset the clock to
zero forever — same anti-nag lesson as the 1Password backup monitor); **brew is
a recency stamp, not an outdated-package count** (homebrew/core moves daily, so
the alertable fact is "the guarded upgrader hasn't run", from
`~/.local/state/brew-upgrade/last-success`); **macOS updates read from Apple's
own cached scan**, never a live `softwareupdate -l`. A network failure degrades
to `skipped` in the msg, never DOWN — an unreachable GitHub and "five releases
behind" are opposite conclusions. Bash 3.2, same launchd PATH constraint as the
health-check script above.

Full rationale: `docs/devhost-health.md`.

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

### The auto-reseed's three traps (all hit on 2026-08-17)

The same hourly agent reseeds the mini's secrets cache
(`scripts/opbackup-seed-auto.sh`). It failed on every attempt for eleven days,
for three unrelated reasons stacked on top of each other — and each one presents
as a clean, deliberate-looking skip. **A skip line in `opbackup.log` is a claim,
not a diagnosis.**

- **`op whoami` is not an unlock probe, it is a permanent lock-out.** Under
  1Password's **desktop-app integration** — the only mode either Mac uses —
  there is no CLI session token, so `op whoami` returns rc=1 *"account is not
  signed in"* on a fully unlocked app, while `op read` in the same second
  resolves refs perfectly (measured, op 2.38.1). A whoami-gated guard therefore
  skips on every tick forever. The probe is **`scripts/lib/op-signed-in.sh
  <acct>`** (`op account get` under the hood): no secret, one call, instant when
  unlocked, exactly one dialog when locked. It runs for **both** accounts —
  `headless.iu.refs` is a careerpartner list, so a tkrumm-only check clears and
  then storms on the IU half.

  **It had spread to five call sites, and four of them were dead without anyone
  noticing**, because each failed with its own plausible refusal: the reseed
  skipped hourly for 11 days; `make tailscale-acl-diff` died telling you to run
  `op signin` — on the *only* machine that can push the tailnet ACL; `make
  secrets-rotate` refused and pointed you at the mini, the one host where
  rotation genuinely cannot run; and `make status` reported the session expired,
  permanently. The source was `rules/makefile-conventions.md`, which printed the
  whoami snippet as *the* pattern to copy. That rule now points at the shared
  probe instead — **fixing the call sites without fixing the rule would have
  regrown them.**

- **1Password authorizes per CALLING BINARY, and the first call from a new
  parent raises a one-time dialog.** After the fix, `bash lib/op-signed-in.sh
  tkrumm` passed standalone while `make status` still reported locked seconds
  later — not a bug, just `make` never having been approved before. Approve once
  and it sticks. This is also why a LaunchAgent's first `op` call behaves
  differently from your shell's, and why "it works when I run it by hand" proves
  less here than it looks like it does.
- **"mini unreachable" usually means "1Password is locked".** The 1Password SSH
  agent serves that `ssh mini` too, and a locked app fails it as `signing failed
  … communication with agent failed` → `Permission denied (publickey)`. Discard
  ssh's stderr and the two collapse into one wrong message that sends you to the
  tailnet, the sshd and the ACL for a problem that is a Touch ID away. The guard
  classifies the stderr instead.
- **One transient `op read` failure must not discard the whole run.** The seed is
  ~150 refs, one `op read` **process** each, and a few of those handshakes fail
  transiently (`response: promptError`) or hang on a dialog that never renders.
  Both refs that killed consecutive runs re-read fine by hand ~1s later, rc=0.
  Aborting on the first one spends the human's approval, resolves everything,
  throws it away and arms a 6h backoff. Reads are now `timeout -k`-bounded and
  retried 3× with backoff — but **only on transient errors**: a genuinely missing
  ref still fails on attempt 1, because retrying it just delays an error a human
  has to fix. Regression tests: `scripts/secrets-seed-retry.test.sh` (MacBook —
  `secrets-seed.test.sh` is mini-gated), which extracts the loop from the real
  script rather than copying it, and stubs `op` on **PATH** rather than as a
  shell function, since `timeout` execs past a function and hits the real binary.

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

**MCP-per-project policy** — keep project MCPs minimal. Global servers are `chrome-devtools` and `research-gateway` (the remote research MCP), both deferred (names only in context, schemas via ToolSearch), plus **`sideclaw` on the mini only**.

**`sideclaw` is not available on the MacBook, and its skills therefore are not either** — `/check`, `/review`, `/otel`, `/read-drawing`, `/excalidraw-diagram` and `dispatch` all route through it. Its MCP entry is `type: stdio` running `~/SourceRoot/sideclaw/server/mcp.ts`, and that repo lives only on the mini per the sanctioned-repo split — so the entry failed to spawn on every MacBook session until it was removed on 2026-08-18. There is nothing to point at remotely: sideclaw's MCP is `StdioServerTransport` only, and a real JSON-RPC POST to the mini's `:7705` returns `NOT_FOUND` (the 200 you get from a browser is the SPA catch-all — same trap as collie's `/` vs `/api/snapshot`). Reaching it from here would need a StreamableHTTP transport added in sideclaw, which is a design decision for that repo, not drift to tidy up. Until then: run those skills on the mini (`work <repo>`), don't clone sideclaw here. The **only** repo running real project-level MCPs is `prometheus-scripts/jupyter` (db/datadog/marimo, in a git-ignored `.mcp.json`). `epos_fe.spa-orchestrator`'s `.mcp.json` (nitrox + Figma Desktop) is declarative IDE config, not always-on. No other repo has or needs project MCPs — don't add one without a deliberate reason. (Note: jupyter's datadog block hardcodes keys in the git-ignored file; the sibling `db` server uses `op run` — migrate datadog to `op run` when convenient.)

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
| `ca [model]` | IU unified endpoint, native Anthropic route | `claude-sonnet-5[1m]` default; any served id as the first arg | Identical to `c` — same `~/.claude` config dir, only auth + model change |
| `oc` (`opencode`) | IU unified endpoint | whatever `opencode.json` configures | Separate harness — own plugin/hook/agent system, see below |

`ca` exists so the exact same Claude Code setup (skills, hooks, native subagents
like `@implementer`) runs off Max — at work, or to spare quota — billed as IU
tokens instead. **It does not go through the LiteLLM bridge**: it talks to the IU
unified endpoint's `/anthropic` route directly, so WebSearch/WebFetch and prompt
caching both work (the bridge serves neither).

An optional first argument picks the model, and the two tiers behave differently
on purpose:

- **`claude-*`** → `[1m]` is appended to the id and to every `ANTHROPIC_DEFAULT_*`
  tier. All Claude models on this route land on AWS Bedrock `eu-west-1`; the
  `-eu` aliases add nothing and break `count_tokens`, so don't use them.
- **anything else** (`DeepSeek-V4-Flash`, `glm-5.3-flash`, `kimi-k2.7-code`, …) →
  every `ANTHROPIC_DEFAULT_*` tier is pinned to that same id, and the window comes
  from `_CA_CTX` in `claude.zsh` rather than `[1m]`. Both details are load-bearing:
  leave one tier on a `claude-*` default and subagents 400 against a model the
  gateway doesn't serve, and `[1m]` on a gateway id would force a `claude-*` name
  that usage-tracker then misbills as Max quota.

`_CA_CTX` is a conservative table — 200k for anything whose real window hasn't
been measured, because the variable is a client-side budget: set it above the
true window and a clean auto-compact becomes a hard mid-session API rejection.
1M is **not** safe for every model (`kimi-k2.7-code` hard-caps at 262144).

A `[claude-code:unrecognized_model]` line on stderr for gateway ids is expected
telemetry, not an error. Rationale: `modelpick/docs/decisions/ca-launcher.md`.

An already-open shell keeps whatever `c`/`ca` definition it loaded at startup —
`source ~/.zshrc` (or open a new terminal) after editing `claude.zsh`.

`usage-tracker` (`~/SourceRoot/usage-tracker`) ingests all three automatically:
the `SessionStart` hook logs each session's `ANTHROPIC_BASE_URL`, which is what
`classifyBilling` keys on to bill `ca` as `iu` rather than sunk Max quota. Rates
for every gateway model are measured from the endpoint's own reported cost — see
`usage-tracker/src/pricing.ts`.

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
to *this* file: it is the largest in the tree and the agent context limit is
150k chars — check with `wc -c CLAUDE.md`. When trimming, move a section's
narrative rationale to a matching `docs/*.md` file (verbatim, so nothing is
lost) and condense what stays here to commands, tables, and one-line gotchas
with a `docs/X.md` pointer for the full story — that's what `remote-dev.md`,
`collie.md`, `devhost-health.md`, `homebrew.md`, and `theme.md` already are.
Reach for the same move on whatever section grows longest next.

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

## `make launchagents-check` — the MacBook has no heartbeat

The mini has `devhost-health-check.sh` every 300s. **This machine has nothing**,
and on 2026-08-18 that showed: `com.jkrumm.sideclaw` had **40,281** failed spawns
and `com.jkrumm.usage-tracker` **449**, both with a `WorkingDirectory` pointing at
a repo that lives only on the mini. launchd cannot chdir there, so every spawn
died `78 (EX_CONFIG)` — it never started, and KeepAlive retried forever. Nothing
reported it: both logged to `/tmp`, swept after 3 idle days, and the exit code
sits in a `launchctl list` column nobody reads. Both were leftovers from before
the MacBook/mini split and are now removed, along with the dead sideclaw MCP entry.

`scripts/launchagents-check.sh` (read-only, also folded into `make status` so it
is seen without knowing to run it) flags four things per `com.jkrumm.*` agent:
missing program or WorkingDirectory, a down KeepAlive job, logs under `/tmp`, and
plaintext credentials in `EnvironmentVariables` — `com.jkrumm.usage-tracker`
carried a bare `ARGO_TOKEN`, which `rules/security.md` forbids and nothing else
scans for.

**Exit codes are graded, and that is what makes it worth reading.** `78` always
fails, because the job can never start. Any *other* non-zero exit fails only if
the plist sets `KeepAlive` and the job is not currently running — `db-tunnel`
exits `255` every time the lid closes and has 103 such exits behind it while
being perfectly healthy, and flagging that on every run is precisely the noise
that trains you to skim past the one line that matters.

**Known outstanding:** `com.jkrumm.photoflow` still logs to `/tmp`. Deliberately
not fixed here — photo-flow is mid-flight on `feat/control-panel` with 122 dirty
files, and threading a plist change through that is how you lose someone's work.

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

## The look: One Zinc terminal, One Dark/Catppuccin Latte herdr chrome

Three programs paint one screen and none can see the other two: herdr paints its
**chrome** (sidebar/borders/tabs) from its own built-in theme, the terminal paints
**pane content** from its ANSI palette, starship paints the **prompt** inside
that. All three follow macOS appearance. **`make theme` applies all three and
reloads herdr live** — run on both machines; applying only one layer is how they
drift apart.

| Layer | File | Setting |
|-|-|-|
| Terminal | `config/ghostty/config.appsupport` (+ `config`) | `theme = dark:one-zinc-dark,light:one-zinc-light` |
| herdr | `config/herdr/config.toml` | `name = "one-dark"`, `auto_switch = true`, `light_name = "catppuccin-latte"` |
| Prompt | `config/starship.toml` | ANSI color *names* — resolve through whichever is active |

**Never black, never white** — backgrounds are middle-ground zinc (`#1f1f23`
dark, `#f2f2f5` light); pure `#09090b` was tried and lasted one commit (it broke
the sidebar's focused-row contrast, which needs the terminal bg as one of three
cues, not the only one). `catppuccin-latte` for light mode is a **taste call
against the measured numbers** (its focused row is only 1.09:1 contrast — no
light herdr theme clears 1.5 against this terminal bg) — don't read it as the
optimum. `nord`/`dracula`/`vesper` aren't options (no light sibling, so
`auto_switch` has nothing to pair with). `desk` follows the MacBook's live
appearance switch (DEC mode 2031 via cmux/libghostty); `dev` (mosh) cannot — it
swallows the escape, so `dev` always renders the static `name` fallback. Font
must be **`JetBrainsMono Nerd Font Mono`** specifically — the Mono variant forces
single-width glyphs so herdr's icons don't break sidebar column alignment.

Reload a live herdr config: `herdr server reload-config` (or `prefix+shift+R`).
`herdr config check` catches unknown keys/TOML errors and (since 0.8.2) unknown
built-in theme names, but **silently accepts a bad hex** in `[theme.custom]` and
**exits 0 even when it reports `issues found`** — `make theme` asserts the theme
files exist and are non-empty rather than trusting its exit code.

Full rationale + measured contrast tables for every herdr theme: `docs/theme.md`.

## Key Technical Facts

- Skills route via four modes: **inline** (no `model:` frontmatter — run on session model), **subprocess** (skill body shells `claude -p` with Keychain API key), **MCP/sideclaw** (registered tool with JSON schema + heartbeat + quota routing), **fork** (`context: fork` — wrap deferred MCP tools). See global CLAUDE.md `Token Efficiency` for the decision tree.
- `c()` in `config/zsh/claude.zsh`: writes Claude Code theme to `~/.claude.json`, then invokes `claude --dangerously-skip-permissions`. No `--plugin-dir` — global skills load from `~/.claude/skills/` automatically.
