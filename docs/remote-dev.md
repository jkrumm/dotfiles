# Remote dev — MacBook → Mac mini

The Mac mini is the always-on dev host: agents, LaunchAgents, Docker, dev
servers. The IU MacBook (`iumac`) is the thin client — editing, `desk`, biometric
1Password. Agents run on the mini and outlive the MacBook.

Inventory of machines, repos, agents and doors: `docs/architecture.md`.
Day-to-day commands: the `/remote-dev` skill.

## The mental model

Three layers, each solving exactly one problem. **No layer substitutes for
another.**

| Layer | Tool | Solves | Cannot solve |
|-|-|-|-|
| Reachability | **Tailscale** | Stable address + NAT traversal | Nothing above it |
| Persistence + UI | **herdr** (on the mini) | Panes stay alive; per-pane agent state | Anything about the network |
| Service exposure | **Caddy** | Dev servers over the tailnet, real HTTPS, working WebSockets | Anything about terminals |

Riding on top, independent of all three: **`claude --bg`** (reparents to PID 1 as
`claude daemon run`; survives ssh death, herdr death and lid-close — the safety
net that bounds herdr being pre-1.0) and **Claude Remote Control** (first-party,
one session at a time; the whole-herd view is Collie).

**`mini` resolves two ways and the resolver picks silently.** The bare name is
LAN-first and `ssh_config` pins neither, so at home the tailnet is not in the
path and the ACL is inert — key-only sshd is the sole boundary there. The
consequence: **an ACL change cannot be verified from the couch.** Test ACL edits
off-network, or against the MagicDNS FQDN explicitly.

## Connecting — `desk`

```bash
desk [session]      # = herdr --remote mini
```

The herdr **client** runs on the MacBook (local keybindings, image paste,
appearance switch); the **server and every pane** run on the mini. ssh/TCP, so a
roam or lid-close ends the *connection* — re-run `desk`. Nothing in a pane dies
with it.

- **ControlMaster is why one `desk` costs one biometric approval.** `Host mini`
  sets `ControlMaster auto` / `ControlPath ~/.ssh/cm/%r@%h:%p` /
  `ControlPersist 10m`; herdr opens several connections. `_setup-ssh` creates
  `~/.ssh/cm` — ssh will not, and connections fail without it.
- **`~/.zshenv` is the only file a non-interactive `ssh mini -- cmd` sources**
  (macOS runs `path_helper` from the *login* file `/etc/zprofile`). Without the
  guarded block `_setup-zshenv` appends, remote commands land with no Homebrew on
  PATH. It carries Homebrew and `~/.local/bin` (`claude`, `secrets-run`,
  `imgcli`), and is appended, not symlinked — other installers write to it too.
- `SetEnv TERM=xterm-256color` on `Host *` pins a universally-present terminfo;
  TERM is the one variable `SetEnv` passes without server-side `AcceptEnv`.
- Sessions: `herdr --session <name>`, `herdr session list|attach|stop`.
  `herdr attach` is not a command. tmux stays installed as the fallback only.

## herdr on the mini

A **brew service** (`RunAtLoad` + `KeepAlive`, same mechanism as colima). Manage
it with `brew services`, never `herdr server stop` — KeepAlive relaunches it.
`LimitLoadToSessionType` covers `Background`/`System`, so it holds state with no
client attached (`herdr workspace create …` succeeds with zero clients).

- **The server must start as a session leader.** herdr derives
  `detached_server_daemon` from `getsid(0) == getpid()`, and a bare launchd job
  is not one — which made every `desk` launch ask *"restart the remote server?
  [y/N]"*. Always answer **N**: y restarts it outside brew services and kills
  every process in every pane. `herdr/herdr-server-start.py` forks and `setsid()`s
  before exec, `_herdr-supervise` pins it into the brew plist, and
  `brew-upgrade.sh` asserts it — **`brew upgrade herdr` and any `brew services
  start|restart` regenerate that plist and strip the wrapper, silently.**
- **Apply a fix to the running server with `make herdr-restart YES=1`** (bootout
  + bootstrap; never `brew services restart`, never `launchctl kickstart -k`). It
  **kills every pane**, so it is human-timed and not in `make setup`.
- **`make herdr-setup` wires both integrations**: `herdr integration install
  claude` writes `~/.claude/hooks/herdr-agent-state.sh` (tells *herdr* about the
  agent), and `scripts/herdr-skill-sync.sh` regenerates `skills/herdr/SKILL.md`
  from `herdr --skill` (tells the *agent* about herdr) — **generated from the
  binary, never hand-written**, but tracked so an upgrade is a reviewable diff.
  The hook's settings entry lives in `config/settings.template.json` (that is
  what survives `make setup`) and its command is guarded.

**A herdr crash restores the layout and loses every process in it** — the
workspace comes back by name with a new `terminal_id`. That is the concrete
reason `claude --bg` is not optional for work that matters.

**Config is tracked**: `config/herdr/config.toml` → `~/.config/herdr/config.toml`
on both machines, linking the **file** and never the directory (the same dir
holds the sockets and rotating logs). On `desk` the MacBook's copy renders. Apply
a change without dropping panes with `herdr server reload-config` (or
`prefix+shift+R`); `herdr config check` first, but see `docs/theme.md` for what
it silently misses.

**`HERDR_ENV=1` is how an agent knows it is inside herdr** (plus `HERDR_PANE_ID`
/ `_TAB_ID` / `_WORKSPACE_ID` / `_SOCKET_PATH` / `_BIN_PATH`), which makes the
skill inert on the MacBook with no branching. **Vars are inherited at spawn, not
tracked** — a `claude --bg` daemon that outlives its pane keeps a stale
`HERDR_PANE_ID`; resolve the live one with `herdr pane current --current`.

**`prefix+e` opens `Projects/<repo>.md`** from `~/SourceRoot/brain` in `$EDITOR`,
in a herdr **popup** (session-modal; a docked pane would flash the error
unreadably). `scripts/brain-note.sh` resolves the repo from
`HERDR_ACTIVE_PANE_CWD` and creates the page if absent (house frontmatter,
wikilinked from `Projects/Projects.md` — new pages must stay wikilinked or
`vault-lint` warns). **Per repo, not per workspace.** The popup runs on the
server, so over `desk` it edits the mini's checkout, where the brain-sync lane
never commits — the note lands via the nightly `brain-backup` sweep.

## Putting work on the mini

`desk` answers "how do I go look at the mini". The commoner question is "how do I
put work there and check on it", which needs no terminal.

`scripts/remote-dev.sh` (`rd`) routes off the `~/.config/secrets/backend` marker
— local on the mini, one ssh hop from the MacBook. Commands take a repo **name,
never a path**; resolution happens on the far side across `~/SourceRoot` and
`~/IuRoot`.

| Command | Does |
|-|-|
| `repos [filter]` | repos on the host, branch + dirty count |
| `work <repo>` | herdr workspace + claude, **idempotent** (refocuses, never stacks) |
| `rd bg <repo> '<task>'` | durable `claude --bg` daemon, spawned *through* a herdr pane |
| `agents` | both lanes, deduped on Claude session id |
| `rd read <agent>` / `rd say <agent> '…'` | watch / steer without attaching |

`work` is idempotent because two agents in one checkout is the file-ownership
hazard, except across panes where you cannot see it happen. `agents` dedupes on
the Claude session id (herdr exposes `agent_session.value`, the daemon
`sessionId`) — otherwise one Claude in a pane reads as two agents racing a tree.

`agent-dispatch` is the machine-agnostic layer above `rd`: one bounded episode,
placed on whichever machine owns the repo.

| Command | mini / mini-resident repo | MacBook + MacBook-resident repo |
|-|-|-|
| `agent-dispatch bg <repo> '<task>'` | `rd bg` — herdr-pane spawn, keychain-safe Max auth | local `claude -p` on the IU Keychain creds, `claude-sonnet-5[1m]` |
| `agent-dispatch work <repo>` | `rd work` | local session |

MacBook-resident repos are the sanctioned set: `dotfiles`, `dotfiles-private`,
`brain`, `photo-flow`, `shutterflow`. It **refuses to nest inside an interactive
Claude Code session** (`CLAUDECODE` set → prints the brief, exit 1).
`make agent-dispatch-smoke` runs a read-only task at `dispatch-scratch`.

**Never `ssh mini 'claude …'`.** Claude Code's Max credential lives in the
**login keychain**, unreachable from an ssh session, so that spelling comes up
`Not logged in`, silently falls back to API billing, and still looks healthy in
`claude agents`. The herdr server is a brew service inside the GUI session, so
anything it spawns (panes, `rd bg`) inherits keychain access, and the mini's
auto-login brings the keychain up unlocked at boot. `claude --bg` takes the
positional prompt and conflicts with `-p`.

**`config/zsh/claude-auth.zsh` is an armed fallback**: a `claude()` zsh function
resolving `op://mini/claude/oauth-token` via `secrets-run` into
`CLAUDE_CODE_OAUTH_TOKEN` — **never `ANTHROPIC_API_KEY`**, which flips billing to
API credits. It probes the keychain credential first and **uncached** (a cached
verdict once suppressed the fallback for an hour while `claude` ran with no
credential at all). It is a **function**, not a `~/.local/bin` shim (the updater
rewrites that path), passes the token by **prefix assignment** (not `env VAR=…`,
which leaks into `ps auxww`), and self-gates on the `cache` backend marker. Only
the keychain-dead-*and*-token-dead state fails the heartbeat. **Restore the
keychain credential with `/login` in a herdr pane on the mini** rather than
minting a token: it is a one-year credential with no refresh and no reliable
revocation.

## Dev-server doors

**`config/Caddyfile` is the single app registry.** Every
`<name>.test { reverse_proxy localhost:PORT }` block automatically gets a clean
tailnet door — a new app needs nothing else. `~/.config/caddy-tailnet.ports` is
**opt-out only** (`exclude <name>`), not a second list; it used to be one and the
two drifted silently (17 apps vs 4). `~/.config/caddy-tailnet.conf` carries
`DEV_DOMAIN` and the Cloudflare token path.

| Door | URL | Scope |
|-|-|-|
| Local | `https://<name>.test` | this machine only (`bind 127.0.0.1`; dnsmasq wildcards `*.test` → 127.0.0.1) |
| Clean | `https://<name>.mini.jkrumm.com` | tailnet — one wildcard site block, Cloudflare DNS-01 cert, ACL `tag:devhost → tag:mac/tag:phone/tag:tablet` on `tcp:443` |

| Command | Purpose |
|-|-|
| `make caddy-tailnet` | Dev host only: regenerate the tailnet door, validate, reload |
| `make caddy-dns-build` | Dev host only, one-time and after any `brew upgrade caddy`: rebuild Caddy with the Cloudflare DNS module |

The registry is read with `caddy adapt` + a walk of the route JSON
(`scripts/lib/caddy-registry.py`), **never regexed** — snippet imports and
`fpp.test`'s `header_up Host` variant defeat regex. A block that cannot be
reduced to one name+port is **skipped, never guessed at**; an empty registry is
refused. The generated include is untracked: it holds the tailnet IP and the
Cloudflare token (chmod 600).

- **Upstreams dial `localhost:PORT`, never `127.0.0.1:PORT`** — Vite, finding its
  port held on another address, binds **`::1` alone** and still prints `ready`;
  an IPv4-pinned upstream then 502s against a running app.
- **One site block for every app, never one per app** — Caddy 2.10+ issues one
  wildcard cert per block and N blocks would race Let's Encrypt's ~50/week.
- **`bind <tailnet-ip>` on the wildcard block, `bind 127.0.0.1` on every `.test`
  block** — otherwise Caddy takes `0.0.0.0:443`, answers on the LAN, and the two
  listeners collide.
- **`servers { protocols h1 h2 }` disables HTTP/3 globally** — quic-go's
  1280-byte initial packet exceeds the tailnet MTU (caddyserver/caddy#7885),
  giving intermittent Chrome-only failures.
- **502 vs 403**: 502 = dev server not running; 403 = running and rejecting the
  Host header — add `.mini.jkrumm.com` to `server.allowedHosts` (Vite/Astro) or
  `*.mini.jkrumm.com` to `allowedDevOrigins` (Next — **no leading-dot support**).
- **Every listening port needs an ACL grant and the failure is silent** (no
  refusal, no log line, just a timeout). Dev servers sit in `tcp:7700-7799`.
- **DNS negative-caches at two layers**: the LAN router (~30 min after a new A
  record) and macOS `mDNSResponder`, which `dscacheutil -flushcache` does **not**
  clear — only `sudo killall -HUP mDNSResponder`. `check_dev_vhosts` uses `dig`,
  so it can report "in sync" while a browser still shows ERR_NAME_NOT_RESOLVED.
- **`brew upgrade caddy` silently reverts the DNS module** and nothing fails
  until the wildcard cert misses a renewal ~60 days later — hence the pin, and
  hence `check_dev_vhosts` asserting module, cert days-left, A-record drift and
  file permissions every 5 minutes.
- **Caddy reads tailscaled's cert material because it runs as root**; a non-root
  Caddy silently cannot. Caddy rather than more `tailscale serve` rows because
  Tailscale #18827 drops WebSockets through serve/funnel every 10–40 s.

**`https://apps.mini.jkrumm.com` lists every app** with port and live status,
answering at any *unmatched* name too, so a typo shows what exists. Status comes
from generated `handle /_up/<name>` routes nested inside the wildcard fallback
(each with `rewrite * /`, or a healthy app 404s on its own probe path) —
same-origin, no daemon, no CORS. It also lists live `tailscale serve`/Funnel rows
from tailscaled: a snapshot, not a drift check. The apex `https://mini.jkrumm.com`
is a second subject on the same site block — a wildcard cert covers one label only,
so the apex gets its own cert and needs its own A record — and falls through the
host matchers to the same landing page.

## Phone

Three tiers: notification hooks (outbound push when an agent needs input), Claude
Remote Control (first-party, one session), and **Collie** — a herdr plugin +
loopback bridge serving a PWA on `:8788`, the only one that sees the whole herd.
Collie is remote shell access by design; the gate is the ACL (`tag:phone` only —
`tag:client`, the TVs and tablet, never), not `COLLIE_TRUSTED_USER`, which cannot
discriminate tagged devices. Chosen over raw ssh to the phone: no port-22 grant,
no SSH key on a losable device. Full model: `docs/collie.md`.

## Inbound and outbound access

### Inbound: MacBook → mini (OpenSSH)

`make remote-access` (opt-in per machine, not in the default `setup` chain)
installs the public keys from `config/ssh/authorized_keys` plus the sshd
hardening drop-in (`config/sshd/200-hardening.conf.template`): no root, no
passwords (both `PasswordAuthentication` **and** `KbdInteractiveAuthentication`
off — required under macOS `UsePAM yes`), `AllowUsers <you>`, agent forwarding
on. Guarded on `authorized_keys` being non-empty so it cannot lock out SSH.
Remote Login / Screen Sharing toggles are best-effort (TCC/SIP usually need
System Settings → General → Sharing).

Two boundaries gate this: the ACL (`tag:mac → tag:mac` on 22/5900) and key-only
sshd. Keep the router free of any WAN forward for 22/5900 — that bypasses both.

- **The mini cannot verify its own inbound SSH** (no key for itself, and the
  1Password agent cannot sign headlessly) — verify from the MacBook.
- `launchctl print system/com.openssh.sshd` → `state = not running` is
  socket-activation idle, not a fault. Check `netstat -an | grep '\.22 .*LISTEN'`.

### Outbound: no human, so each path routes around biometrics

- **homelab + VPS → Tailscale SSH.** tailscaled authenticates the tailnet
  identity (`tag:mac` ACL); OpenSSH auth is `none`. Zero keys, zero prompts — a
  stolen mini holds no server credential, and revocation is removing the device.
- **GitHub → HTTPS + a secrets-cache credential helper.** `make git-headless`
  (opt-in, cache-gated) writes `~/.gitconfig-headless`, rewrites remotes to HTTPS
  and points the helper at `scripts/git-credential-secrets-cache` →
  `op://mini/github/token`. It replaced a `gh` keyring token that **exits 0 with
  an empty body on expiry**, so git fell through to prompting and reported
  `could not read Username` — a transport error for a credential problem. The
  cache helper has no session dependency (no login keychain, no GUI session, no
  forwarded agent), so it resolves identically from a LaunchAgent, a `--bg`
  daemon, a herdr pane and a shell. It is deliberately **not** Hermes's read-only
  token (403 on push); the split allows independent rotation and contains
  accident, not a compromised agent — anything with `secrets-run` reads every
  cached ref.

### mini → iumac — the reverse reach, on :2222

For pulling `usage-tracker` stats, `brain` and files off the MacBook. The ACL
already grants `tag:mac → tag:mac` on `tcp:22`; what was missing is auth, since
macOS ships no Tailscale SSH server.

- **The key** is `~/.ssh/id_ed25519_iumac` on the mini (mode 600, no passphrase,
  never enters 1Password or the cache), installed from
  `config/ssh/authorized_keys.iumac` by `make authorized-keys` as `restrict,pty`.
  **No agent forwarding** is the load-bearing restriction — without it the mini
  could borrow the human's 1Password GitHub/signing key on every connection. The
  target skips the mini itself: both halves there turn an outbound-only
  credential into an inbound one. Verify positively — `ssh -A iumac` leaves
  `SSH_AUTH_SOCK` unset remotely and `-R` is refused (`-L` is **not** a valid
  test; a local forward needs no server-side setup).
- **The door is our own userland sshd on :2222.** iumac's MDM pins the Remote
  Login SACL (`com.apple.access_ssh`) to `IT-Admin` and re-drops the account
  every check-in, so **:22 accepts the key then closes the session with no sshd
  log line**. The SACL is a PAM check (`pam_sacl.so` in `/etc/pam.d/sshd`) and
  PAM runs only under `UsePAM yes`, so `dotfiles/tailnet-sshd/`
  (`make tailnet-sshd-setup`, MacBook-only) runs Apple's `/usr/sbin/sshd` with
  `UsePAM no`, pubkey-only, on the same `authorized_keys`, bound to
  `127.0.0.1:2222` behind a `tailscale serve --tcp 2222` forwarder (self-healing
  across tailscaled restarts and IP changes) under `com.jkrumm.tailnet-sshd` (a
  GUI-session Agent, not a root daemon). Only tailscaled listens externally, so a
  corp LAN portscan finds nothing on 2222. ACL `tcp:2222` on `tag:mac → tag:mac`;
  `make tailnet-sshd-status` asserts both halves.

- `Host iumac` pins `Port 2222`, `IdentitiesOnly yes`, **`IdentityAgent none`** —
  not optional on the mini, where `SSH_AUTH_SOCK` points at the 1Password agent
  and any target consulting it *hangs* rather than fails. `op` on the far side
  then fails fast (exit 1), so the biometric gate holds with no hang hazard.
- **TCC: stage files out, do not grant Full Disk Access.** The door reads home
  root, `~/SourceRoot`, `~/.claude`, `/tmp` and is blocked from `~/Downloads`,
  `~/Desktop`, `~/Documents` and cloud folders — `cp ~/Downloads/x ~/xfer/`, then
  pull `iumac:xfer/x`. FDA on `/usr/sbin/sshd` is the most EDR-flagged TCC grant
  there is, cannot be scoped to this door (same binary as the system sshd), and
  undoes the low profile it exists for.
- **Renaming a device: verify `DNSName`, not `HostName`** —
  `tailscale set --hostname` does not move MagicDNS on a registered device (only
  the admin console does), and the mismatch fails at name resolution while
  looking like a broken key.
- **Honest cost:** a mini compromise now reaches the MacBook's files and user
  session, but not `op://Private/*`, which needs a biometric prompt a stolen key
  cannot answer. Full model: `dotfiles-private/docs/access-model.md`.

### File shuttle — `~/Shuttle` over SMB

`smb://mini/jkrumm` mounted from the MacBook, `~/Shuttle` the drop folder, for
ad-hoc **human** file movement only — not code (→ `rd`/git), not vault pages (→
brain-sync), not anything an agent reads (client-side mount; mini down and Finder
hangs). `tcp:445` on `tag:mac → tag:mac`.

**A listening `:445` plus a running `smbd` is not a working SMB server.** macOS
stores no NTLM (`SMB-NT`) hash for a local account by default, so `smbd` refuses
*every* principal identically — guest, password, Kerberos, even on loopback —
with an error that reads like a network fault. Minting it is **GUI-only** (System
Settings → Sharing → File Sharing ⓘ → Options → tick the user → type the
password; no `pwpolicy`/`dscl`/`sysadminctl` verb injects it). Verify with the
data (`ShadowHashData` → `grep SMB-NT`), never the setting. Guest access is
`sharing -g 000|001`, **three digits**. Diagnose against loopback first.

### Database access — `make db-tunnel-setup`

The mini's dev databases bind `127.0.0.1`, so a GUI client on the MacBook needs
`com.jkrumm.db-tunnel`: a `KeepAlive` LaunchAgent holding one long-lived
`ssh -N` with every `-L` from `dbtunnel/tunnels.conf` (`make db-tunnel-status`
probes it). **Local ports are the real port + 30000** (33306, 36379) — the
MacBook runs its own copy of the same stack. Not `tailscale serve --tcp` (a raw
MySQL socket for every tagged device), not Caddy (no layer4 module). Four launchd
traps: the inherited `SSH_AUTH_SOCK` is Apple's agent with **zero identities**
(point at 1Password's socket); `-o IdentityAgent=<path>` needs literal quotes
around the "Group Containers" path; `ControlMaster=no` + `ControlPath=none` are
mandatory or the tunnel dies with the shared master session; ssh must run in the
**foreground** (`-f` reads as a clean exit → respawn loop), reconnecting via
`ServerAliveInterval=15 × CountMax=3`. It exits `255` on every lid-close while
healthy — which is why `make doctor` grades exit codes.

## Unattended boot posture (mini only)

Everything here is user-scoped and starts at login. Three settings make a power
cut survivable with no human:

```
fdesetup status   → FileVault is Off
autoLoginUser     → jkrumm          (/etc/kcpassword, written by System Settings)
pmset -g custom   → autorestart 1
```

**`autorestart 1` is not optional and its absence is silent** — without it the
machine does not power on at all after a cut. **Auto-login is also what makes Max
auth work headlessly**: a real password login, so the keychain comes up unlocked
(`claude auth status` → `loggedIn: true, max`). `claude setup-token` is therefore
not required.

| Path | With FileVault off |
|-|-|
| Boot the desktop and use it | closed by `lock-at-boot` |
| Pull the SSD, read it elsewhere | protected — volume key fused to the Secure Enclave |
| Boot from external media | protected — needs a LocalPolicy on the internal SSD |
| recoveryOS Terminal | admin-password gate |
| **Mac Sharing Mode (Share Disk, Thunderbolt)** | **open — the real hole** |

`/etc/kcpassword` holds the login password under a reversible XOR, so physical
possession yields root and every ref in `headless.refs` / `headless.iu.refs`.
"Encrypted at rest" still holds for the secrets cache but is weaker than it reads
— the age key is on the same disk. Activation Lock and Find My cover only the
opportunistic case (unsellable, remotely erasable).

### `lock-at-boot`

**Screen lock ≠ keychain lock.** The keychain re-locks on exactly three events
("lock when sleeping", the inactivity timer, logout), so the session keeps
running in full behind the password prompt — herdr, every agent, SSH, Tailscale.
That is the point, not a flaw.

| Half | Command | Why |
|-|-|-|
| Remove the grace period | `sysadminctl -screenLock immediate -password '<pw>'` | one-time, by hand |
| Fire screen-off at login | `com.jkrumm.lock-at-boot` → `pmset displaysleepnow` | needs no TCC |

`make lock-at-boot-setup` **refuses to install** unless the first half is already
applied — a plist that sleeps the display on an unlocked machine reads as done
and is worse than none. `make lock-at-boot-check` reports FileVault, autologin,
autorestart, screenLock, agent presence, live lock and keychain state.

- `sysadminctl -screenLock` **does not prompt** — the password must be inline.
  Prefer the GUI (Lock Screen → require password → *Sofort*); `histignorespace`
  is off here, so a CLI invocation lands in `~/.zsh_history`.
- **`CGSession -suspend` no longer exists** on macOS 26, and **`osascript` ⌃⌘Q
  needs Accessibility (TCC)**, ungrantable to a launchd job on a headless
  machine. `pmset displaysleepnow` is the one that works.
- Resuming over Screen Sharing does not start a new session, so unlocking from
  the MacBook does not re-fire the agent.

It does nothing about Mac Sharing Mode (a FileVault question), and must not stand
in for the two things that shrink the blast radius: re-deriving what
`headless.iu.refs` really needs to hold, and a written theft runbook (Tailscale
device removal, `op://mini/github/token` revoke, Claude session revoke, IU
credential rotation, Find My → Erase Mac).

## human-queue — the present-human channel

SSH gives the mini reach, not a fingerprint. For work needing a *present human* —
biometric `op` (`make secrets-seed`), the Tailscale ACL push, any person-only
decision — an agent on the mini enqueues instead of writing prose nobody reads.

| Side | Command | Runs on |
|-|-|-|
| Enqueue | `ask-human.sh ask "<text>" [--cmd <command>] [--wait [seconds]]` | mini |
| Inspect own request | `ask-human.sh list` / `status <id>` | mini |
| Drain | `make human-queue-count` · `make human-queue` · `human-queue.sh show/run/deny <id>` | MacBook |

State is `<id>.req` + `<id>.res` under
`${XDG_STATE_HOME:-$HOME/.local/state}/human-queue/` on the mini (dir 700, files
600); pending = no `.res`. `--wait` polls every 5 s, exiting 0/1/2/3 for
done/denied/failed/timeout.

- **The transport is the existing MacBook→mini ssh hop**, not a new credential —
  no inbound door opens on the MacBook. It refuses to run on the `cache` backend.
- **The mini only ever *proposes* a command string.** `run <id>` prints it
  verbatim, names its origin, and requires a typed `yes` on a real TTY — no TTY,
  no path to `run`. A misbehaving mini can put a string in front of a human,
  never open a shell.
- **No LaunchAgent drains it, deliberately** — the hop sits behind the per-use
  biometric 1Password agent, so a poller means an unattended Touch ID prompt on a
  schedule forever. `hooks/machine-role.ts` folds a count into SessionStart on
  the `op` backend only, with a 2500 ms timeout collapsing to silence.

## launchd on the dev host

Everything long-running on the mini is a launchd job, and every trap below fails
by looking fine.

- **`launchctl kickstart -k gui/501/<label>` does NOT re-read the plist** — it
  restarts from launchd's *cached* definition, so an edited plist looks applied
  and is not. Only `bootout` + `bootstrap` reloads the file; expect
  `Bootstrap failed: 5: Input/output error` until `launchctl print` says
  `Could not find service`.
- **`ai.hermes.gateway.plist` is generated by Hermes** from the invoking shell's
  `os.environ["PATH"]` — which is how dead `fnm_multishells/<pid>` dirs get baked
  into a boot service. `launchd_plist_is_current()` masks the PATH string and
  compares every other line verbatim, so a hand-fixed PATH survives while an XML
  comment of your own marks the file stale and makes the next restart rewrite it
  from a shell env. After any edit it must return `True`.
- **`check_boot_path` asserts, for every KeepAlive job, that the plist exists on
  disk and `launchctl print`'s path matches** — the gap where a job runs only
  from launchd's cache and the next power cut takes it down silently.
  `make colima-status` / `make herdr-status` assert the same on demand.
- **Logs go to `~/Library/Logs/<name>.{log,err}`, never `/tmp`.** macOS deletes
  `/tmp` files untouched for 3+ days and launchd opens its stdio **once, at
  spawn**, so after a sweep a `KeepAlive` agent writes into an unlinked inode and
  nothing reports it. `make log-rotate-setup` bounds them: hourly,
  **copytruncate** (a rename would follow the inode, exactly like the sweep),
  16 MB cap, one `.1` generation, safe because launchd's fds are `O_APPEND`. The
  list in `scripts/log-rotate.sh` is declared, never globbed.

### Colima — the Docker runtime

`_setup-colima` brews the docker toolchain, creates the VM (`vz` + Rosetta amd64
+ virtiofs), pins the `colima` docker context, registers the brew service and
installs the `com.colima.docker-socket` LaunchDaemon. Manage with
`make colima-{start,stop,restart,status}` — they wrap **`brew services`**, never
bare `colima stop` (KeepAlive undoes it).

- **The plist's `KeepAlive` is repaired, and the repair is load-bearing.**
  Homebrew generates `KeepAlive { SuccessfulExit => true }` (restart only on a
  *zero* exit) while `colima start -f` runs the VM in the foreground — inverted,
  so a dirty Lima image leaves Docker down until a human logs in.
  `{ Crashed => true }` is not the fix (that is death by *signal*).
  `_setup-colima` converges onto bare `KeepAlive => true` plus
  `colima/colima-start.sh`, a bounded-retry wrapper (5 fast attempts, then a
  600 s cool-off, never latching off). **Brew regenerates the plist on every
  `brew services start/restart` and every `brew upgrade colima`, silently** — so
  every `colima-*` target re-converges and `colima-status` asserts the boot path.
- **And since Homebrew 6, it regenerates it under a different NAME** —
  `homebrew.mxcl.<name>` → `sh.brew.<name>`, written on the next `brew services
  start|restart` (the old file is deleted then, not at upgrade time), so both
  names are live across these two machines. `scripts/lib/brew-service.sh` is the
  single resolver every caller goes through; nothing hardcodes a label. The old
  hardcoded path turned the converge step into `plist absent — nothing to
  supervise`, exit 0, over the stock plist it exists to repair.
- `COLIMA_CPU` / `COLIMA_MEMORY` / `COLIMA_DISK` default to **2 / 4 / 60** and are
  **ceilings, not reservations**; disk only grows via recreate.
- `com.colima.docker-socket` maintains `/var/run/docker.sock` at boot — the only
  path the Raycast Docker extension can use, since it sanitizes
  `DOCKER_HOST`/context out of its env.
- **`brew services list` showing `caddy none` / `dnsmasq none` is a reporting
  artifact**: without sudo it enumerates only `gui/501` and both live in the
  `system` domain. Starting either with `brew services start` creates a duplicate
  user-domain job fighting the root one for `:443`.

### The Application Firewall lies about which failure it is

**ALF keys on the resolved binary path**, so replacing a binary silently
un-allows it — and a blocked inbound connection is **not refused**: the kernel
completes the handshake and never hands the socket to the app, so the client
times out on every path while the app's log says it is listening. The running
process keeps its grant, so the fuse is the next restart. **After replacing any
binary that accepts inbound connections, re-check the ALF list** — a venv rebuild
is the usual trigger, and the heartbeat appends this hint to the Hermes failure.

```bash
FW=/usr/libexec/ApplicationFirewall/socketfilterfw
sudo "$FW" --add "$BIN" && sudo "$FW" --unblockapp "$BIN"
"$FW" --listapps | grep -F "$BIN"      # reading needs no sudo
```

## Tailnet ACL and serve — as code

Both live as **declared state** in `dotfiles-private` (an ACL is a security
boundary, a serve file an exposure map) with the tooling here. Both apply **from
the MacBook**: the API key is `op://Private/Tailscale`, which the mini's cache
refuses unconditionally by design — the edit happens where the repo is, the push
where the human is.

| Command | Does |
|-|-|
| `make tailscale-acl-diff` | **Always first** — a push overwrites the whole tailnet ACL |
| `make tailscale-acl-pull` | Fetch live **into** `tailscale-acl.jsonc`, staged through a temp file so a failed fetch cannot truncate it |
| `make tailscale-acl-push` | Validate + apply (prompts; `ACL_PUSH_YES=1` bypasses) |
| `make tailscale-serve` | Converge live serve state onto `tailscale-serve.<machine>.conf` |
| `make tailscale-serve-check` | Report drift, change nothing, exit 1 if any |

- **Every listening port needs a grant, and the failure is silent** — no
  refusal, no log line on either end, just a timeout.
- **Applying serve does `tailscale serve reset` first** — a device rename leaves
  bindings under the old name that no per-port `off` can address. Rows take an
  optional 4th column, a human label; the applier normalises on `$1|$2|$3`, so a
  label can never cause drift.
- **Current rows**: `:7730` (rb, tailnet-only), `:8788` (Collie, tailnet-only,
  never funneled), `:8443` — **Funnel, public internet**, the IU dashboard, gated
  by `tag:iu-dashboard-funnel`, an *additive single-device* tag because Funnel is
  a whole-device capability and `tag:mac` would expose the work MacBook. That one
  port is the machine's entire public surface.
- **Tagging a device is console-only** and independent of pushing a grant — both
  are silently inert without the other (`tag:devhost`, `tag:tablet` likewise).
- **Verify the live filter with no API key**, from the mini itself:
  `tailscale debug netmap`, parsing `PacketFilter` for the port.
- **`--accept-routes` is off on the mini** — it removes the trap where a peer's
  overlapping subnet route silently pulls local traffic through the tailnet and
  presents as a DNS or Docker fault. Imperative daemon state with nothing
  declaring it: re-check after any Tailscale reinstall or re-auth.
- **The mini and homelab are on different networks** and meet only over
  Tailscale — homelab is **not** a LAN jump host for the mini.

**The mini runs the open-source `tailscaled` from Homebrew**, not the Standalone
(macsys) app: a root LaunchDaemon with `keep_alive: always` that starts **before
login** and cannot be quit out of existence. `sudo brew services start` is
required (as the user it installs a LaunchAgent, which cannot run a root
service), and every consumer resolves the CLI through
`scripts/lib/tailscale-cli.sh` — a leftover app-bundle CLI answers with a
*stopped* tunnel and a stale IP, a wrong answer rather than an error. **Reboot is
a required acceptance test**: two Tailscale stacks contesting the tunnel leave a
node that looks healthy everywhere (`Running`, right IP, tags, peers, `ping`
answering) with `serve` ports still serving — they terminate *inside* tailscaled
— while sshd, Caddy and ICMP are silently dropped.

## Applying a macOS update to the mini

`make mini-macos-update` (MacBook-only, TTY or `YES=1`). What it does, for when
it has to be done by hand:

```bash
PW=$(op read "op://Private/mac-mini-server/password" --account tkrumm)
printf '%s\n' "$PW" | ssh mini 'read -r pw
  { printf "%s\n" "$pw"; printf "%s\n" "$pw"; } |
    nohup sudo -S softwareupdate -i -a -R --user jkrumm --stdinpass \
      > ~/Library/Logs/macos-update.log 2>&1 &'
```

- **Apple Silicon needs volume-owner auth**, hence `--user … --stdinpass`.
  `sudo -S` reads one line and `--stdinpass` the next, so the password twice on
  stdin satisfies both and keeps it out of `ps auxww`. Detached, because a
  `tailscale` upgrade in the same window restarts the transport this session
  rides.
- **The CLI returns in seconds printing `Restarting...` and does not restart** —
  that line is a *request*; `UpdateBrainService` and `SoftwareUpdateLauncher`
  then prepare for minutes and restart the machine themselves.
- **Do not `shutdown -r now` to hurry it**: a forced reboot aborts the prepare
  and boots the **old** version while `Update.plist`, `nvram` and
  `RecommendedUpdates` all still look armed. `sw_vers -productVersion` is the
  only honest check.
- **If the request was swallowed**, neither process is there a minute later — a
  stale GUI session (a modal vetoes the restart) is the usual cause. Plain reboot
  first, then the installer, then leave it alone.

## Verification

| Command | Covers |
|-|-|
| `make doctor` | Read-only, self-routing. Both machines: LaunchAgent grading, architecture-map check, brew pins/outdated. Mini: the drift report without pushing. MacBook: the remote path (Tailscale, ssh, ControlMaster reuse, agent forwarding, herdr `--remote`, git push dry-run), Kuma monitor states, then the mini's doctor over ssh |
| `make status` | Prerequisites + symlink health, then `doctor --local` |
| `make devhost-health-check` | One heartbeat run, per-component (`docs/devhost-health.md`) |
| `make colima-status` / `make herdr-status` | Boot path asserted, not just "the process is up" |
| `make tailscale-serve-check` | Serve drift against the declared file |
| `bash scripts/architecture-check.sh` | Every loaded/on-disk launchd label appears in `docs/architecture.md` |

By hand after a change to this stack: start agents in herdr, close the lid,
re-run `desk` — all still there; `claude --bg` a long task, stop herdr entirely,
confirm the daemon still runs.

**The heartbeat asserts the GitHub credential resolves, not that a push
succeeds** — the real `git push --dry-run` lives in `make doctor`, because at a
300 s cadence a provider outage would page as "dev host down". That split earned
itself once already: the credential resolved fine while the deployed helper still
pointed at a read-only token, and only the dry-run saw it.
