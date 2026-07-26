# Remote dev — MacBook → Mac mini

Implementation plan. The mini is the always-on dev host; the IU MacBook is a
thin client. Agents run on the mini and outlive the MacBook.

## The mental model

Four layers. Each solves exactly one problem, and **no layer can substitute for
another** — most of the confusion in designing this came from collapsing them.

| Layer | Tool | Solves | Cannot solve |
|-|-|-|-|
| Reachability | **Tailscale** | Stable address + NAT traversal, mini reachable from anywhere | Nothing above it |
| Transport | **mosh** | Your keystrokes survive lid-close, roaming, bad wifi | Multiplexing, port-forwarding, persistence |
| Persistence + UI | **herdr** | Panes stay alive on the mini; per-pane agent state | Anything about the network |
| Service exposure | **Caddy** | Dev servers reachable over the tailnet with real HTTPS + working WebSockets | Anything about terminals |

Two independent extras that ride on top:

- **`claude --bg`** — verified to reparent to PID 1 as `claude daemon run`. Survives
  SSH death, herdr death, and lid-close *independently of every layer above*. This is
  the safety net: use it for anything that must not die. It bounds the blast radius of
  herdr being pre-1.0.
- **Claude Remote Control** — phone/browser window onto a session running on the mini.
  Official, no relay to run.

```
                  MacBook                         mini
                  ───────                         ────
  terminal ──mosh(UDP, roams)──────────────►  herdr server
                                                ├─ pane: agent 1  [blocked]
                                                ├─ pane: agent 2  [working]
                                                ├─ pane: dev server
                                                └─ pane: logs
                                              claude --bg daemons  (PID 1, independent)
  browser  ──https──────────────────────────►  Caddy → localhost:PORT
  phone    ──Claude Remote Control──────────►  session on the mini
```

### `mini` is two routes, and the resolver picks silently

Accepted, not fixed — but know it is happening. The bare name `mini` resolves
**LAN-first**: the router's `mini.<lan-domain>` (IPv6) answers before the
MagicDNS `mini.<tailnet>.ts.net`. `ssh_config` sets `HostName mini`, so it never
pins either one.

The consequence is that the *same command* takes two different paths depending
on where you are sitting:

| Where | Path | Gated by the Tailscale ACL? |
|-|-|-|
| At home | LAN, direct to the router's address | **No** — the tailnet is not in the path at all |
| Travelling | Tailnet, via MagicDNS | Yes |

So the `tag:mac → tag:mac` ACL is real protection on the road and simply inert
at home, and the switch between them is invisible — no error, no log line, just a
different route. Two practical follow-ons: at home you are relying on sshd's
key-only config as the *sole* boundary (it is a good one, which is why this is
acceptable), and any ACL change you make cannot be verified from the couch,
because at home you are not exercising the ACL. Test ACL edits from off-network,
or against the MagicDNS FQDN explicitly.

Pinning `HostName` to the MagicDNS FQDN would collapse this to one always-gated
route, at the cost of pushing LAN-speed transfers through WireGuard. That trade
was considered and declined — the speed is worth more than uniformity for a host
that is ten feet away.

## Why not the alternatives

- **herdr over tmux** — tmux persists terminals; herdr persists *agent workspaces* and
  reports blocked/working/done/idle per pane. At 5-8 concurrent agents that state view is
  the whole point. tmux stays installed as the fallback, not the daily driver.
- **herdr over cmux** — they overlap. Both want to own the workspace model, and only one
  can. herdr wins because it runs *on the mini* (survives lid-close); cmux is a MacBook
  GUI and dies with the MacBook. cmux stays as the terminal window herdr is displayed in.
- **mosh over plain ssh** — ssh is TCP; a lid-close kills it. Mosh roams over UDP. It
  cannot multiplex, so the shape is always *one* mosh connection into herdr, never N
  parallel connections.
- **Caddy over `tailscale serve`** — Tailscale issue #18827 (open): WebSockets through
  `serve`/`funnel` drop every 10-40s with close code 1001. That is Vite HMR breaking on a
  timer. Caddy proxies WebSocket upgrades transparently.

## Already done (do not redo)

Committed in this repo — verified with `ssh -G`, not just written:

- `config/ssh_config` — `Host *` block: `ServerAliveInterval 15`, `ServerAliveCountMax 3`,
  `TCPKeepAlive yes`, `SetEnv TERM=xterm-256color`.
- `config/ssh_config` — `Host mini`: `ControlMaster auto`, `ControlPath ~/.ssh/cm/%r@%h:%p`,
  `ControlPersist 10m`. The file had *claimed* ControlMaster in a comment for months
  without it being set.
- `Makefile` `_setup-ssh` — creates `~/.ssh/cm` (ssh will not create it; connections fail
  without it).
- `Brewfile` — added `herdr` (homebrew-core, v0.7.5), `mosh`, `tmux`.

`SetEnv TERM` fixes cmux bug #2969 (doubled keystrokes when `TERM=xterm-ghostty` reaches a
host with no such terminfo). TERM is the one variable `SetEnv` passes without server-side
`AcceptEnv`.

## Steps

### 0. Tailscale ACL — DONE

The `udp:60000-61000` grant sits on the Mac↔Mac rule
(`homelab-private/config/tailscale-acl.jsonc:60`) and **is applied** — the mini's live
packet filter carries an IPProto 17 rule for ports 60000-61000 with both Macs as sources,
confirmed via `tailscale debug netmap`. mosh authenticates over ssh and then moves the
session to UDP 60000-61000, so a missing grant would read as a broken mosh rather than a
blocked port — worth knowing even now that it's applied, since the symptom is identical
if the grant ever regresses.

Nothing else in this plan depends on it — steps 1-3 work over plain ssh; only mosh needs
this.

### 1. Install — DONE on both

`make setup` on the MacBook (`brew bundle` picks up the three new formulae). mosh needs
`mosh-server` present on the mini and `mosh` on the MacBook; both come from the same
Brewfile entry. herdr must be installed on **both** ends for `herdr --remote`.

On the mini (2026-07-26): herdr 0.7.5, mosh 1.4.0 and tmux 3.7b are installed, and
`make _setup-ssh` has been run — `~/.ssh/cm` exists and `ssh -G mini` confirms
`controlmaster auto` / `controlpersist 600` / `serveraliveinterval 15` /
`setenv TERM=xterm-256color`, with colima's `Include` preserved. The sudo-gated steps
(caddy, dnsmasq, the `com.colima.docker-socket` LaunchDaemon) were already in place on
the mini from an earlier run; what still needs a present human there is the biometric
half (`make secrets-seed`), not this plan.

On the MacBook (2026-07-26): herdr 0.7.5, mosh 1.4.0_40, tmux 3.7b are installed from the
Brewfile; `~/.ssh/config` was regenerated with `Host mini` (the stale `mac-mini` host is
gone, colima's `Include` preserved) and `~/.ssh/cm` created — `ssh -G mini` confirms
`controlmaster auto` / `controlpersist 600` / `serveraliveinterval 15` /
`setenv TERM=xterm-256color` / `forwardagent yes`.

**Two newly-fixed, load-bearing gotchas — both were real outages of the mosh path
today:**

- **Non-interactive PATH.** zsh reads *only* `~/.zshenv` for a non-interactive
  non-login shell, which is what `ssh host -- cmd` gets and what mosh uses to launch
  `mosh-server`. macOS runs `path_helper` from `/etc/zprofile`, a login file, so
  `ssh mini 'herdr status'` landed with `PATH=/usr/bin:/bin:/usr/sbin:/sbin` and no
  Homebrew — mosh reported "Did not find mosh server startup message. (Have you
  installed mosh on your server?)" while `/opt/homebrew/bin/mosh-server` was installed
  and healthy. `make setup` now appends an idempotent guarded PATH block to
  `~/.zshenv` (`_setup-zshenv`). Not symlinked: the vite-plus and cargo installers
  append to that file and would clobber a symlink.
- **Application Firewall.** The macOS ALF is per-process and does **not** auto-allow
  Homebrew binaries (no Developer ID signature), despite "Automatically allow
  downloaded signed software" being enabled. With `mosh-server` absent from the
  allowlist the ssh handshake succeeds, mosh-server starts, binds its UDP port and
  prints `MOSH CONNECT` — and then every datagram is dropped, with the client blaming
  a firewalled UDP port. That reads exactly like a missing ACL grant and misdirected
  the diagnosis. Isolated by sending UDP from the MacBook to `/usr/bin/nc`
  (Apple-signed) on the mini: it arrives over *both* the LAN and the tailnet, while
  mosh-server gets nothing. Fix is `make mosh-firewall` (sudo, mini-only).
  `socketfilterfw` stores the resolved path, and the brew symlink points into a
  version-stamped Cellar dir, so `brew upgrade mosh` silently un-allows it — which is
  why `devhost-health-check.sh` now asserts allowlist membership on every run.

### 2. herdr on the mini — DONE

No custom LaunchAgent: herdr ships a brew service with `RunAtLoad` + `KeepAlive`, which is
the same mechanism colima already uses here, so `brew services start herdr` is both the
house pattern and the always-on answer. Its `LimitLoadToSessionType` includes `Background`
and `System`, so it does not need a GUI session.

```
brew services start herdr     # done on the mini 2026-07-26
herdr status                  # server: running
```

Manage it via `brew services`, never `herdr server stop` alone — `KeepAlive` would just
relaunch it, exactly as with colima.

**Tested crash semantics (mini, 2026-07-26).** The server was `kill -9`'d with a workspace
open. `KeepAlive` relaunched it and the workspace came back by name — but the pane's
`terminal_id` changed, so **the layout is restored and the running processes are not**.
That is the sharp edge of a pre-1.0 multiplexer: a herdr crash costs you every agent
running inside it, even though the workspace reappears looking intact. It is the concrete
reason the `claude --bg` safety net below is not optional for work that matters.

A related check that needs no client at all: `herdr workspace create …` succeeds with zero
clients attached, which is the actual proof that the server is headless and holds state on
its own. Everything past that (detach, roam, reattach) is inherently MacBook-side.

### 3. Connect from the MacBook — a real fork, decide by testing

`herdr attach` is **not a command** (an earlier draft of this plan invented it). The real
options are two mutually exclusive shapes, and the four-layer model above quietly assumed
the first:

```
mosh mini                     # then run `herdr` on the mini. Client runs THERE.
herdr --remote mini           # herdr's native remote attach. Client runs HERE, over ssh.
```

| | transport | client runs on | roaming |
|-|-|-|-|
| `mosh mini` → `herdr` | mosh (UDP) | the mini | survives lid-close *without reconnecting* |
| `herdr --remote mini` | ssh (TCP) | the MacBook | connection dies; re-run to reattach |

Either way the herdr **server** and its panes survive on the mini — this is a question of
client experience, not persistence. `--remote` gives local keybindings
(`--remote-keybindings`), local image paste, and a local-feeling UI; mosh gives a session
that never needs reattaching on a bad link. Test both on the MacBook and keep one.

Two things bias this toward `--remote` at the desk, and they are worth knowing before
picking:

- **mosh does not forward the SSH agent** (upstream refuses it), and does not carry port
  forwarding, OSC 52 clipboard, or sixel/kitty graphics. `ssh_config` sets
  `ForwardAgent yes` on `mini` on purpose — though the practical bite is small here,
  because the mini reaches GitHub over HTTPS + the `gh` token, not over a forwarded key.
- **mosh's predictive echo only engages on a laggy link.** On a LAN-latency tailnet hop it
  is doing nothing ssh wasn't, so at the desk it costs the features above and buys
  nothing. Its value is real but specific: a genuinely bad link, and a session that
  survives roaming without reattaching.

Read that as: `--remote` at the desk, mosh on the road — not a single winner.

Note `herdr` does its own ssh hardening for `--remote`: `[remote] manage_ssh_config = true`
(default) generates a config that **includes `~/.ssh/config` first** — so the values in
step "Already done" still win — then adds `ServerAlive*` as fallbacks and a private
per-attach control socket. That does not make the repo's `ControlMaster` redundant: it
covers plain `ssh`, `scp` and git-over-ssh, which herdr never touches.

Session naming, if you want more than the default: `herdr --session <name>`,
`herdr session list|attach|stop`.

### 4. Caddy — for *new* dev servers only

**Leave the two existing bindings alone.** Both are deliberate and working:

```
7730    http://127.0.0.1:4050   no     # rb — tailnet only
8443    http://localhost:5173   yes    # IU dashboard — public by design
```

The 8443 Funnel is not an accident. It is gated by `tag:iu-dashboard-funnel`, an additive
single-device tag that exists precisely so Funnel capability lands on the mini and never
on the work MacBook (Funnel is a whole-device capability, not port-scoped). An earlier
draft of this plan recommended dropping it — that was wrong.

Caddy's job here is the *new* need: reaching an arbitrary dev server on the mini from the
MacBook, with working HMR, without minting a new `tailscale serve` binding per port. Only
build this when you actually have that need — it is not a prerequisite for steps 1-3.

When you do, resolve first:
- **Port 443 conflict** — `tailscale serve` holds 443 on the tailnet IP; Caddy cannot also
  bind it. Give Caddy a distinct port rather than migrating the working bindings.
- **Certificates** — Caddy ≥2.5 pulls `*.ts.net` certs from the local tailscaled. Verify
  against the *macOS* Tailscale app, which may not expose the socket the way the Linux
  daemon does. Fallback: `tls internal` plus trusting the mini's local CA on the MacBook.
- **Vite** — `server.allowedHosts` must include the hostname or Vite 5.4.12+ returns 403
  (DNS-rebinding guard); also `server.cors`. rb already solved this with a `.ts.net`
  suffix match — copy that shape.

Why Caddy rather than more `tailscale serve` rows: issue #18827 (open) drops WebSockets
through serve/funnel every 10-40s, which is HMR breaking on a timer. Caddy proxies
upgrades transparently. If an existing binding ever shows that symptom, this is the fix.

### 5. Phone

Enable Claude Remote Control against a session on the mini. Optionally add cmux Remote
(needs the `cmux-relay` helper on the mini, connects over the existing tailnet) if you
want a shell rather than just the agent.

### 6. Monitoring — DONE

One composite push monitor, `MacMini Dev Host - Push` (group `Local`), covering herdr +
sshd + tailscaled + mosh (binary and Application Firewall allowlist membership) + the
GitHub push credential — five components. `scripts/devhost-health-check.sh` via the
`com.jkrumm.devhost-health` LaunchAgent, every 5 minutes; `make devhost-health-setup`
installs it and refuses until the push URL exists.

**Push, not probe** — the ACL grants `tag:homelab → tag:vps` but not
`tag:homelab → tag:mac`, so Uptime Kuma cannot reach the mini. The alternative was an
inbound grant: new attack surface for a check the mini can just do itself.
**One monitor, not five** — herdr/sshd/tailscaled/mosh fail together whenever the mini
sleeps or leaves the tailnet, so splitting them buys simultaneous pages and no extra
information. The GitHub push credential is the deliberate exception — it does not fail
with the rest (a token can expire on a perfectly healthy host) — folded in anyway because
a second Kuma push monitor wasn't worth it for one component. The failing component is
named in the push `msg`.

The monitor is live — `MacMini Dev Host - Push` (id 204, group `Local`, interval 600,
maxretries 0), created declaratively by `make uk-sync` from
`homelab/uptime-kuma/monitors.yaml`. `uptime-kuma-api` creates push monitors fine on
UK 2.x, so there was never a UI-only step. The LaunchAgent's last run exited 0.

### 7. The operating contract lives in a skill

`/remote-dev` (global, `dotfiles/skills/remote-dev/`) is the day-to-day surface: the two
connection forms, herdr's socket API, `claude --bg`, the health check, and a failure-mode
table. This document is the *design*; the skill is the *usage*. Keep it that way — when
something here turns into a routine command, it belongs in the skill.

## What actually takes this down

The four layers all assume the mini is *booted into a user session*. Everything
in this design — herdr, Colima, Caddy, every LaunchAgent, every `claude --bg`
daemon — is user-scoped and starts at login. Verified on the mini 2026-07-26:

```
fdesetup status   → FileVault is On
pmset -g          → autorestart 0
autoLoginUser     → unset
```

So a reboot or a power blip leaves the mini sitting at the **pre-boot FileVault
unlock screen**: no user session, therefore no agents, no herdr, no Tailscale
login-item, and nothing in this plan can reach it. The most likely outage on the
box is the one that is *not* remotely recoverable. That is the real ceiling on
"always-on", and it is worth knowing before trusting the host with long work.

Options, none free:

- **Planned reboots**: `sudo fdesetup authrestart` unlocks the next boot in
  advance, so updates and deliberate restarts stay remote. This is the one that
  costs nothing — use it instead of `sudo reboot`.
- **Power loss**: `sudo pmset -a autorestart 1` makes the Mac power back on, but
  it still stops at FileVault. It shortens the outage only if someone unlocks.
- **Turning FileVault off** would make the host fully remote-recoverable at the
  cost of at-rest encryption on a machine holding the secrets cache. Not
  recommended; noted so the trade is explicit rather than accidental.

Accepting the constraint is defensible — the mini is at home and the fix is
walking to it. Pretending it does not exist is not.

## Blocking constraint

**The inbound path is not testable from the mini.** The mini holds *no SSH private key
material at all* — `~/.ssh/*.pub` is empty and the 1Password agent cannot sign headlessly,
so the mini cannot even SSH to itself. Inbound auth depends entirely on the MacBook's
1Password agent.

Everything that does *not* depend on inbound ssh has now been verified locally: the
installs, the ssh config, the herdr server and its crash semantics, the ACL grant landing
in the live packet filter, and every component of the health check. What is left is
exactly three interactive tests — `mosh mini`, `herdr --remote mini`, and the lid-close
reattach. A non-interactive probe cannot stand in for the first: `mosh mini -- true`
fails at `sign_and_send_pubkey … agent refused operation` because the 1Password agent
will not sign without a human, long before mosh is even reached.

Note the device is still named `iu-mac-book` on the tailnet while `ssh_config` says
`Host iumac` — the rename is open work (see the MacBook handover doc). `ssh iumac` will
not resolve until `tailscale set --hostname=iumac` runs on that machine. This does not
affect MacBook → mini, which is the direction this plan needs.

## Verify at the end

- Start 3 agents in herdr on the mini, close the MacBook lid, reopen, reattach — all three
  still there with correct state.
- Kill the mosh connection mid-task; reconnect; work continued.
- `claude --bg` a long task, stop herdr entirely, confirm the daemon is still running.
- `mosh mini` connects at all — if it hangs after the ssh handshake, step 0 was not applied.
  (Step 0 *is* applied as of 2026-07-26: `udp:60000-61000` confirmed present in the mini's
  live packet filter via `tailscale debug netmap`, IPProto 17.) Both `make mosh-firewall`
  and the `_setup-zshenv` PATH block are prerequisites — either missing reproduces the
  same "hangs after handshake" symptom for a different reason.
- `make devhost-health-check` on the mini prints **five** green components (herdr, sshd,
  tailscaled, mosh, GitHub push credential — not four), and the Kuma monitor goes green
  within one interval.
- `tailscale serve status` still shows both existing rows (`:7730` tailnet, `:8443` Funnel).
  This plan must not change them.
- Only if you built step 4: a dev server over Caddy keeps HMR alive past 60s (the #18827
  failure window).
