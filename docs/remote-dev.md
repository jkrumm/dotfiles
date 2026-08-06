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
| Service exposure | **Caddy** | Dev servers reachable over the tailnet with real HTTPS + working WebSockets, via TWO doors — a port-based `.ts.net` fallback (zero dependency) and a clean `.mini.jkrumm.com` door (wildcard cert, opt-in) — see step 4b | Anything about terminals |

Two independent extras that ride on top:

- **`claude --bg`** — verified to reparent to PID 1 as `claude daemon run`. Survives
  SSH death, herdr death, and lid-close *independently of every layer above*. This is
  the safety net: use it for anything that must not die. It bounds the blast radius of
  herdr being pre-1.0.
  **But it cannot be *launched* independently** (found 2026-07-27): Max credentials
  live in the login keychain, which an ssh session cannot reach, so
  `ssh mini 'claude --bg …'` comes up `Not logged in`, silently falls back to API
  billing, and still lists healthy. It must be spawned from something inside the GUI
  session — which is what `rd bg` does, via a throwaway herdr pane. See step 3b.
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

### 2b. herdr's config is tracked, and must be identical on both machines — DONE 2026-07-27

`config/herdr/config.toml` is symlinked to `~/.config/herdr/config.toml` by `make setup`
on **both** machines. That is not redundancy. Which machine reads the config depends on
how you came in, and the two paths disagree:

| Entry | herdr process that renders | Config read from |
|-|-|-|
| `dev` (mosh) | the **mini** — output streams over UDP | the mini's |
| `desk` (`herdr --remote`) | the **MacBook** client, which also handles keys (`--remote-keybindings` defaults to `local`) | the MacBook's |

One tracked file makes the question moot. Note it links the **file**, never the directory:
`~/.config/herdr/` also holds `herdr.sock`, `herdr-client.sock` and the rotating logs,
which are machine-local runtime state.

That split is also why the theme is a **named** built-in (`one-dark`/`one-light`) rather
than herdr's `terminal` theme, which inherits the host terminal's ANSI palette. On the
`dev` path herdr renders on the mini, so `terminal` would mean negotiating the palette
through mosh's UDP proxy. A named theme needs no negotiation and looks the same over both
transports.

`auto_switch = true` follows macOS appearance. herdr probes for it with `OSC 10`/`OSC 11`
plus DEC mode `2031` — confirmed by capturing a client in a pty. On the `desk` path the
client is local, so this is reliable; over mosh the probe may not survive the UDP proxy, in
which case `name` is the fallback. That is why `name` is set to the dark member rather than
left unset.

**herdr and the terminal deliberately run different palettes** — herdr on One Dark, the
terminal on a neutral zinc pair. Matching them is what breaks the focused-workspace
highlight: herdr paints that row at `#282C34` and leaves the sidebar transparent, so a
One Dark *terminal* would put the same colour directly behind it. Measurements and the
full reasoning are in `CLAUDE.md` → *The look* and in the config's `[theme]` block.

Apply a change to the running server without dropping panes:

```
herdr config check            # unknown keys + TOML errors; NOT bad theme values
herdr server reload-config    # → {"status":"applied","diagnostics":[]}
```

The full palette rationale (why the One themes are hand-authored, why every color outside
the theme files is an ANSI name and not hex) is in `CLAUDE.md` → *The look*.

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

### 3b. Driving work without a terminal — `rd` — DONE 2026-07-27

Steps 1-3 all answer *how do I get a terminal on the mini*. That turned out to be
the less common question. The MacBook now holds no project repos at all
(`~/SourceRoot` = `dotfiles`, `dotfiles-private`, `photo-flow`), so the daily
motion is "start work over there and check on it", which needs no terminal.

`scripts/remote-dev.sh`, exposed as `rd` with `work`/`agents`/`repos` shorthands:

```bash
repos [filter]         # what's on the host, branch + dirty
work <repo>            # herdr workspace + claude, idempotent
rd bg <repo> '<task>'  # durable daemon
agents                 # both lanes, deduped on session id
rd read <agent>        # watch without attaching
rd say <agent> '…'     # steer without attaching
```

Four decisions worth keeping:

- **One command surface, two machines.** It routes off `~/.config/secrets/backend`
  — the same "am I the dev host" signal `git-headless` and `herdr-setup` already
  use — running locally on the mini and over one ssh hop from the MacBook. Adding
  a second definition of that predicate would be the start of the usual drift.
- **Repo names, not paths.** `$HOME` differs (`$USER` differs), and the MacBook has
  nothing to point at anyway. Resolution happens on the far side across both
  `~/SourceRoot` and `~/IuRoot`.
- **`work` is idempotent.** A second `work argo` refocuses the existing agent rather
  than opening a second one on the same checkout. Two agents in one tree is the
  file-ownership hazard from CLAUDE.md, except across panes where you cannot see it
  happening.
- **`rd bg` spawns through a herdr pane, not over ssh.** This is the keychain
  constraint from the top of this document, and it is the single least obvious thing
  in the whole stack: the ssh path *appears* to work. Verified both directions —
  identical command, `Not logged in` over ssh, `Claude Max` through a pane. The pane
  is closed once the daemon exists, since `--bg` has reparented by then.

`agents` dedupes the two lanes on the Claude session id (herdr exposes it as
`agent_session.value`, the daemon as `sessionId`): a Claude running in a herdr pane
is one process that both lanes report, and showing it twice reads as two agents
racing one checkout.

### 4b. Tailnet dev ports — BUILT 2026-07-27, second door added later

`make caddy-tailnet` on the mini. The **app registry is the tracked
`config/Caddyfile`** — every `<name>.test { reverse_proxy localhost:PORT }`
block in it is a dev app and automatically gets a clean door, so adding an app
is one Caddyfile block and nothing else. `~/.config/caddy-tailnet.ports` is an
**opt-out + flags** file (`exclude <name>`, `portdoor`, `host=rewrite`), not a
second list; it used to be the registry, and the two drifted silently (17 apps
in one, 4 in the other). `~/.config/caddy-tailnet.conf` still carries
`DEV_DOMAIN` + the Cloudflare token path.

The Caddyfile is parsed with `caddy adapt` and the route JSON is walked
(`scripts/lib/caddy-registry.py`), never regexed — the live file defeats regex
via the non-`.test` `metabase.iu-aws.de` block, snippet imports, and
`fpp.test`'s `header_up Host` variant (which is carried over to the tailnet
door automatically). The machine-local include is stripped before parsing
because it holds the Cloudflare token.

Output is `$(brew --prefix)/etc/Caddyfile.d/tailnet.caddy`, which the tracked
Caddyfile picks up through an `import` glob (valid when it matches nothing, so
the MacBook is unaffected). It generates **two doors**, and the second is
additive — the first is never removed:

1. **Port-based** (the original mechanism): a dev server on `localhost:PORT`
   on the mini is `https://<mini-magicdns>:PORT` from any Mac on the tailnet.
   Cert comes from tailscaled itself — no DNS, no ACME, no Cloudflare. The
   permanent fallback if door 2 is ever unavailable, but **opt-in per app**
   via the `portdoor` flag: this door binds the app's own port number on the
   tailnet interface, so it collides with `tailscale serve` and with any dev
   server that binds `0.0.0.0`. Auto-generating one per app would squat ports
   that `docker compose` then fails to bind.
2. **Clean** (default-on for every app): the same app is *also*
   `https://<app>.mini.jkrumm.com` — one `*.mini.jkrumm.com { … }` site block
   on the tailnet IP's `:443`, `host {}` matchers fanning out to
   `localhost:PORT` per app, one wildcard Let's Encrypt cert via Cloudflare
   DNS-01. Only generated once `~/.config/caddy-tailnet.conf` sets
   `DEV_DOMAIN` and a chmod-600 Cloudflare token file exists — an un-seeded
   machine silently gets door 1 only, which is a valid state, not an error.
   Needs `make caddy-dns-build` first (see below).

**`https://apps.mini.jkrumm.com` lists every app** with port, both doors and
live status, and answers on any *unmatched* name too, so a typo shows you what
exists. Status comes from generated `handle /_up/<name>` routes in the same
site block — same-origin, so no daemon and no CORS. `502` = dev server not
running; `403` = running but rejecting the door's Host header (the most common
failure, and the page names the fix). There is no apex door: a
`*.mini.jkrumm.com` cert does not cover `mini.jkrumm.com`.

Things that were not obvious, each of which cost a debugging cycle:

- **The generated file is untracked on purpose.** It names the MagicDNS hostname
  and the Tailscale IP (and, once door 2 is enabled, contains the Cloudflare
  token — chmod 600 for exactly that reason). Regenerate per machine; never
  copy it between them.
- **`bind <tailnet-ip>` is load-bearing.** Without it Caddy takes `0.0.0.0:PORT`
  and collides with the dev server already on `127.0.0.1:PORT`. Binding only the
  tailnet IP lets the port number mean the same thing inside and outside.
- **Dial `localhost:PORT`, never `127.0.0.1:PORT`.** A dev server does not
  reliably bind the IPv4 loopback: Vite, finding the port held on another
  address, falls back to binding **`::1` alone** and still prints `ready`. A
  hardcoded `127.0.0.1` upstream then 502s against an app that is obviously
  running — seen with basalt-playground on 7710 while a port door held the
  tailnet IP. `localhost` resolves to both families and the dialer tries each.
- **The ACL gates it, and failure is silent.** `tag:mac → tag:mac` was
  `tcp:22, tcp:5900, udp:60000-61000`; ports outside that just time out, with
  nothing in any log. Added `tcp:7700-7799` (the dev-server block). This is the
  same lesson rb's dedicated `tcp:7730` grant already encoded — the ACL checks
  the *listener*, so every new listening port needs a grant. Door 2 needed the
  same lesson applied to `:443` — see below.
- **Certs come from tailscaled, not ACME (door 1 only).** `tls { get_certificate
  tailscale }`, supported natively in Caddy 2.11. On macOS there is no
  `/var/run/tailscaled.socket` — the app exposes a TCP port via
  `/Library/Tailscale/ipnport` plus a root-readable `sameuserproof-<port>` token.
  Caddy can read it **because it runs as root**; a non-root Caddy silently
  cannot.
- **`bind 127.0.0.1` on every local `.test` block is what makes door 2 safe.**
  Before this, the `.test` snippets (see `config/Caddyfile`) took the default
  `0.0.0.0`, which made this same Caddy reachable over the LAN and the tailnet
  — and on the mini it collided directly with door 2's own `:443` listener on
  the tailnet IP. After the change, nothing but the deliberate tailnet-bound
  site blocks listens on the tailnet interface's `:443` at all.
- **`servers { protocols h1 h2 }` disables HTTP/3 globally.** quic-go's
  1280-byte initial packet exceeds the tailnet MTU once headers are added
  (caddyserver/caddy#7885), so h3 connections over Tailscale fail — Chrome-only,
  intermittent, and easy to mistake for something else entirely.
- **Door 2 needs a Caddy binary the stock Homebrew formula doesn't ship.**
  `caddy list-modules | grep dns.providers` is empty on stock Homebrew Caddy,
  so DNS-01 has nowhere to run. `make caddy-dns-build` builds Caddy with
  `github.com/caddy-dns/cloudflare` via `xcaddy` (installed via `go install`,
  pinned in the Makefile) and installs it over
  `$(brew --prefix)/opt/caddy/bin/caddy` — the exact path the brew LaunchDaemon
  plist execs. **A later `brew upgrade caddy` silently reverts this binary**;
  nothing errors until the wildcard cert fails to renew ~60 days out. Re-run
  `caddy-dns-build` after any caddy upgrade — `devhost-health-check.sh`'s
  `check_dev_vhosts` catches the drift on every 5-minute run (module presence,
  cert days-left, DNS A-record drift, token/include file permissions) so it
  doesn't sit undetected for two months.

Client-side, each Vite app needs `server.allowedHosts` to accept the MagicDNS
Host header (door 1) or `DEV_DOMAIN` suffix (door 2) or it answers 403 (rb
already does a `.ts.net` suffix match — copy that shape). Astro is
`vite.server.allowedHosts`; **Next.js is `allowedDevOrigins` and does not
understand a leading dot** — it globs whole segments, so use
`*.mini.jkrumm.com` there, not `.mini.jkrumm.com`. A dev server that validates
`Host` on dev-only endpoints and can't be allowlisted gets the `host=rewrite`
flag in `~/.config/caddy-tailnet.ports` instead — same shape as the `fpp.test`
block in `config/Caddyfile`, which the generator already carries over on its
own. The landing page reports this state explicitly rather than leaving it
looking like a proxy fault.

**The ACL grant for door 2 uses an additive tag, same pattern as Funnel and
Collie.** `tag:devhost → tag:mac/tag:phone/tag:tablet` on `tcp:443` —
`tag:devhost` rather than `tag:mac` because both Macs run this same Caddy, and
a `tag:mac → tag:mac` grant on 443 would hand the work MacBook the personal
Caddy too. `tag:tablet` is additive on the tablet alone, narrower than
`tag:client` (which also covers the two TVs, which must never reach dev
servers). Full reasoning: `CLAUDE.md` → *Two dev-server doors*.

**Applying an ACL change now needs both machines.** The repo lives on the mini,
but `tailscale-acl-push` needs the Tailscale API key, which is `op://Private/*`
and refused by the mini's cache unconditionally and by design. So the edit
happens where the repo is and the push happens where the human is. That is a
real cost of the thin-client split, not an oversight. **Both re-taggings** (mini
`+tag:devhost`, tablet `+tag:tablet`) are additionally console-only — no
`make` target can apply a tag to a physical device — so door 2's grant is
inert until both are done by hand.

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

### 5. Phone — BUILT, ACL grant outstanding

Three tiers, not one — each solves a different piece of "check on this from my phone":

| Tier | What | Reach |
|-|-|-|
| ntfy push | Notification hooks fire a push when an agent needs input | Outbound only — tells you something happened, doesn't let you act |
| Claude Remote Control | First-party, zero inbound (phone dials out to Anthropic's relay) | One Claude session at a time |
| Collie | herdr plugin + Bun bridge, phone-friendly PWA over the tailnet | The whole herd — every pane, every agent, one URL |

Claude Remote Control is enabled and covers the common case (babysit one running
agent). It does not scale past one session, and it cannot see herdr's pane/workspace
model at all — for the actual "which of my 5-8 agents is blocked" question, that's
Collie's job.

**Collie over granting the phone ssh+mosh.** Moshi is a perfectly good mosh client, but
the grant behind it is a full interactive shell as `jkrumm` — the whole secrets cache,
including the `careerpartner` work refs, reachable from a device that can be lost,
stolen, or picked up by a kid. Collie's bridge is loopback-bound and fronted by
`tailscale serve`; the phone gets one scoped web surface, not a login shell with
`secrets-run` sitting right there. See CLAUDE.md's "Collie — the phone control
surface" for the full model (what it is, why `COLLIE_SKIP_SERVE=1` is mandatory, the
LaunchAgent it needed because macOS has no systemd) — not duplicated here.

**Outstanding: the ACL grant, MacBook-only.** Collie is installed and declared in
`dotfiles-private/tailscale-serve.mini.conf` (`8788  http://127.0.0.1:8787  no`) — run
`make collie-setup` to put the bridge under a real LaunchAgent (it starts out on
`collie-ctl.sh`'s bare-`nohup` fallback, which does not survive a reboot). Either way,
that serve row is inert until the tailnet ACL grants `tag:phone` a path to it. That
grant can only be applied from the MacBook: the
ACL API key is `op://Private/Tailscale`, which the mini's secrets cache refuses
unconditionally by design (same reason the ACL itself lives in `dotfiles-private`
rather than `homelab-private` — see `## Tailnet ACL — as code` in CLAUDE.md). The
exact grant to add, in `dotfiles-private/tailscale-acl.jsonc`:

```jsonc
{
  "src": ["tag:phone"],
  "dst": ["tag:mac"],
  "ip": ["tcp:8788"]
}
```

The port is deliberately **8788, not 443** — `tailscale serve`'s default port is
shared by every future serve row that doesn't say otherwise, so a grant on 443 would
mean "whatever gets published next", not "collie". A dedicated port keeps the grant
scoped to exactly one service, permanently — same reasoning as rb's dedicated
`tcp:7730` grant. It also sits outside `7700-7799`, which is already granted
`tag:mac → tag:mac` for dev servers, so reusing that range would hand collie to the
work MacBook through an unrelated rule. `src` is narrowed to `tag:phone` alone — the
MacBook already has `dev`/`desk` and doesn't need the web UI; add `tag:mac` only if
browser access from the laptop is wanted. `tag:client` (the two TVs and the tablet)
must never be granted.
`tag:client` (the two TVs and the tablet) must never be added here. Apply with
`make tailscale-acl-diff` (review) then `make tailscale-acl-push` from the MacBook.

### 6. Monitoring — DONE

One composite push monitor, `MacMini Dev Host - Push` (group `Local`), covering herdr +
sshd + tailscaled + mosh (binary and Application Firewall allowlist membership) + the
GitHub push credential + the clean dev-vhost door (`check_dev_vhosts` — Cloudflare DNS
module presence, wildcard cert days-left, DNS A-record drift, token/include file
permissions; see step 4b) — six components. `scripts/devhost-health-check.sh` via the
`com.jkrumm.devhost-health` LaunchAgent, every 5 minutes; `make devhost-health-setup`
installs it and refuses until the push URL exists.

**Push, not probe** — the ACL grants `tag:homelab → tag:vps` but not
`tag:homelab → tag:mac`, so Uptime Kuma cannot reach the mini. The alternative was an
inbound grant: new attack surface for a check the mini can just do itself.
**One monitor, not five** — herdr/sshd/tailscaled/mosh fail together whenever the mini
sleeps or leaves the tailnet, so splitting them buys simultaneous pages and no extra
information. The GitHub push credential and the dev-vhost door are the deliberate
exceptions — neither fails with the rest (a token can expire, a DNS module can get
reverted by `brew upgrade caddy`, on an otherwise perfectly healthy host) — folded in
anyway because a second Kuma push monitor wasn't worth it for either. The dev-vhost check
additionally SKIPS rather than fails on a machine that never set `DEV_DOMAIN`. The failing
component is named in the push `msg`.

The monitor is live — `MacMini Dev Host - Push` (id 204, group `Local`, interval 600,
maxretries 0), created declaratively by `make uk-sync` from
`homelab/uptime-kuma/monitors.yaml`. `uptime-kuma-api` creates push monitors fine on
UK 2.x, so there was never a UI-only step. The LaunchAgent's last run exited 0.

#### Transient tolerance — added 2026-08-01 after the first power-cut test

Services do not all come back at boot together, and the gap is much wider than it
looks. Measured on the real power-cut test:

```
boot                08:53:20
caddy               08:53:34   (+14s)
sideclaw            08:56:08   (+2m48s)
linewatch-collector 08:56:08   (+2m48s)
```

The health agent ran at 08:54:24 — inside that gap — and pushed `FAIL: sideclaw not
answering`. With `maxretries 0` that is a full **DOWN alert on every reboot**,
clearing itself five minutes later.

**Note what this is not.** A first diagnosis concluded those two agents "never load
and were only ever alive because hand-bootstrapped", pointing at Background Task
Management approval. That was wrong — they were merely *late*, both at the identical
second, which is a deferred launchd bootstrap pass, not a fault. Don't go
re-engineering two working plists.

Three changes, in `scripts/devhost-health-check.sh`:

| Knob | Default | Effect |
|-|-|-|
| `DEVHOST_BOOT_GRACE_SECONDS` | 300 | while uptime is under this, **every** failing component reports `(starting, booted Ns ago)` and the push stays UP |
| `DEVHOST_TRANSIENT_FAILS` | 3 | outside the grace, a level-triggered check reports `(degraded n/3, may self-heal)` and only FAILs on the 3rd consecutive run |
| `DEVHOST_REBOOT_NOTE_SECONDS` | 600 | for two intervals after boot the summary carries `host rebooted Ns ago` |

That last one closes a gap worth more than the grace itself: `check_launchd_restarts`
does delta detection on *agents*, not on the host, so **a 3am power cut that recovers
perfectly was previously invisible** — no heartbeat said anything had happened.

Two design points that were both got wrong first and are worth not re-deriving:

- **The boot grace applies to every component, not just liveness ones.** Failures
  cascade at boot — `check_dev_vhosts` needs the tailnet IP, so it fails while
  tailscaled is merely slow. Restricting the grace to a liveness list still paged on
  every reboot, through the cascade. Observed directly while testing.
- **The axis is level-triggered vs edge-triggered, not liveness vs state.** A streak
  counter only works where the condition stays true while broken. An edge-triggered
  check fires once and clears, so a threshold does not delay it — it silences it
  **permanently**. `check_launchd_restarts` is exactly that (a delta against a state
  file, true for one run per restart) and is the sole member of
  `IMMEDIATE_COMPONENTS`.

**What this does not relax:** if the host is gone, no push lands at all and Kuma's own
missed-heartbeat fires on its own schedule. Time-to-DOWN for "the machine died" is
unchanged — only in-band component failures on a machine that is still talking get
slack. That is the property `maxretries 0` was chosen to protect, and it is untouched.

One bug caught in testing, recorded because the class recurs: `sysctl -n kern.boottime`
prints `{ sec = …, usec = … }`, and a leading `.*sec = ` in sed is **greedy** — it
matches the *second* occurrence and captures `usec`. That yielded an uptime of ~1.78e9
on a host up twelve minutes, which silently disables every grace window while every
test still passes. The pattern is anchored at `^{` now, with a plausibility check
(boot before 2020, or negative uptime → treat as unparseable) as the backstop.

### 7. The operating contract lives in a skill

`/remote-dev` (global, `dotfiles/skills/remote-dev/`) is the day-to-day surface: the two
connection forms, herdr's socket API, `claude --bg`, the health check, and a failure-mode
table. This document is the *design*; the skill is the *usage*. Keep it that way — when
something here turns into a routine command, it belongs in the skill.

### 8. Tailscale was a single point of failure — FIXED 2026-08-06 by changing variant

Section 6 monitors the tailnet; it cannot recover it. On this host that gap was
the whole game, because **the mini had exactly one remote access path.** Measured
2026-08-05, not assumed:

| Candidate second path | Verdict |
|-|-|
| homelab as a LAN jump host | **No.** homelab is on `192.168.178.0/24`, the mini on `192.168.1.0/24`. `tcp:22` from homelab to the mini does not connect. |
| Screen Sharing (`tcp:5900`) | **No.** Listening, but it rides the same tunnel — it dies *with* ssh, not instead of it. LAN only. |
| Reboot | Would fix it, but triggering one needs the access that is gone. |

The proximate cause was the **variant**, not the monitoring. The Standalone
(macsys) build couples the tunnel to a GUI app: quit the app and the tunnel
stops. On 2026-08-05 a remote session did exactly that to force a Sparkle update
check and locked itself out mid-operation, recoverable only because the operator
happened to be on the same LAN. The same build also updates through a phased
rollout cohort, which is why the host sat on 1.98.9 with 1.102.2 released and no
way to pull it forward.

A watchdog was built first, and it worked — 83s unattended recovery, measured.
It was then **deleted**, because it treated the symptom. Fixing the variant
removes the failure instead of bounding it.

**The mini now runs the open-source `tailscaled` from Homebrew.** Structurally
this is the same model as systemd on the VPS and homelab:

| | macsys (before) | brew tailscaled (now) |
|-|-|-|
| Runs as | GUI app + system extension | root LaunchDaemon, `keep_alive: always` |
| Starts | after auto-login | **before login** |
| Dies when | the app is quit | launchd restarts it |
| Updates | Sparkle, phased rollout | `brew upgrade`, covered by `make brew-upgrade` + drift-check |

Funnel was the blocking question and was **verified empirically before
migrating**, because the KB contradicts itself on it: a throwaway node on the
brew daemon accepted both `serve --bg 8080` and `funnel --bg 8080`. Port-based
Funnel works; the claim that it needs the App Store or Standalone build is wrong.

**The node identity does not survive the swap.** macsys keeps state inside the
system extension's sandbox, so this creates a new node with a new tailnet IP
(`100.87.73.3` → `100.123.249.18`). Four places hardcoded the old one; three are
regenerated by `make caddy-tailnet`, and argo's `HERMES_BASE_URL` on the VPS is
the one manual edit.

Three traps found during the migration, all of the same shape — **a wrong answer
rather than an error**:

1. **The app-bundle CLI still answers after the migration.** The dormant macsys
   extension is deliberately left installed so rollback stays cheap, and its CLI
   reports a stopped tunnel and the pre-migration IP. `caddy-tailnet.sh`
   regenerated its config with the dead IP that way. Every consumer now goes
   through `scripts/lib/tailscale-cli.sh`; nothing hardcodes a path.
2. **The brew CLI auto-detects the macsys socket** when both are present. The
   socket is always passed explicitly — same wrong daemon, reached another way.
3. **`brew services start` as the user** installs a LaunchAgent, which cannot run
   a root-required service. It must be `sudo brew services start`.

Rollback stays available while the `mini-old` node record exists: `sudo brew
services stop tailscale`, re-enable the login item, relaunch the app.

What this still does not give you is a genuinely independent path. If tailscaled
fails to start at all, physical access remains the only recovery — but launchd's
`keep_alive` plus starting before login makes that a much narrower window than a
quittable GUI app ever was. A `cloudflared` door behind Cloudflare Access is the
designated upgrade if that ever proves insufficient.

## What used to take this down — RESOLVED 2026-08-01, by paying for it

The four layers all assume the mini is *booted into a user session*. Everything
in this design — herdr, Colima, Caddy, every LaunchAgent, every `claude --bg`
daemon — is user-scoped and starts at login. Measured on the mini 2026-07-26:

```
fdesetup status   → FileVault is On
pmset -g          → autorestart 0
autoLoginUser     → unset
```

A reboot or a power blip therefore left the mini at the **pre-boot FileVault
unlock screen**: no user session, no agents, no herdr, no Tailscale login-item,
and nothing in this plan able to reach it. The most likely outage on the box was
the one that was *not* remotely recoverable — the real ceiling on "always-on".

That ceiling is gone. The current posture, verified on a genuine unattended
reboot 2026-07-31 and a power-cut test 2026-08-01:

```
fdesetup status   → FileVault is Off
autoLoginUser     → jkrumm            (/etc/kcpassword written by System Settings)
pmset -g custom   → autorestart 1     (powers itself on after a power cut)
```

**`autorestart 1` is not optional and its absence is silent.** FileVault-off plus
auto-login only solves *"boots into a usable session"*; without `autorestart` the
machine does not power on at all after a cut, and nothing reports that until the
one event the whole arrangement exists to survive.

### Why the keychain is the point

Claude Code's Max OAuth credential lives in the **login keychain**, which is
reachable only from a GUI-session process — this is why `ssh mini 'claude …'`
comes up `Not logged in` and silently bills API credits while looking healthy.
Auto-login performs a real password login, so the keychain comes up **unlocked**
with no human present. Verified directly after an unattended boot:

```
security show-keychain-info …/login.keychain-db  → no-timeout   (unlocked)
claude auth status                               → loggedIn: true, max
```

This settles a question that had been argued from theory in both directions:
`claude setup-token` is **not** required. `config/zsh/claude-auth.zsh` stays
wired and dormant as a fallback — it costs nothing there, and a one-year token
with no refresh and no reliable revocation is not an upgrade over a credential
that refreshes itself.

### What it costs, stated plainly

| Path | With FileVault off |
|-|-|
| Boot the desktop and use it | closed by `lock-at-boot` (below) |
| Pull the SSD, read it elsewhere | protected — the volume key is fused to the Secure Enclave's hardware UID |
| Boot from external media | protected — needs a LocalPolicy on the internal SSD |
| recoveryOS Terminal | Apple documents an admin-password gate |
| **Mac Sharing Mode (Share Disk, Thunderbolt)** | **open — this is the real hole** |

`/etc/kcpassword` also now holds the login password under a trivially reversible
XOR. So the claim that used to sit in CLAUDE.md — *"a stolen mini cannot escalate
to its own root"* — is **false as of this change**, and the justification for
caching work credentials in `headless.iu.refs` ("encrypted at rest") is weaker
than it reads: the age key sits on the same disk that now mounts without a
password. Physical security of the machine is doing real work now, not
ceremonial work.

Sources disagree on whether reaching Share Disk needs the recoveryOS password
first — Apple's docs imply yes, Kolide demonstrates the attack assuming no. The
pessimistic reading is the one to plan against.

### `lock-at-boot` — the mitigation, and its honest scope

`make lock-at-boot-setup` (dev-host only) installs `com.jkrumm.lock-at-boot`, a
`RunAtLoad` agent that locks the screen immediately after the unattended login.
**Screen lock does not lock the keychain** — that re-locks on exactly three
events: the "Lock when sleeping" setting, the "Lock after N minutes" inactivity
timer, and logout. So the session keeps running in full behind a password
prompt: herdr, every agent, every LaunchAgent, SSH, Tailscale.

Two halves, and the agent alone does nothing:

| Half | Command | Why |
|-|-|-|
| Remove the grace period | `sysadminctl -screenLock immediate -password '<pw>'` | one-time, by hand |
| Fire the screen-off at login | the LaunchAgent → `pmset displaysleepnow` | no TCC needed |

**`sysadminctl -screenLock` does not prompt.** Unlike `-autologin`, which has an
explicit interactive form, `-screenLock` requires the password inline and exits
with `Password is required!` otherwise.

Prefer the GUI — it puts the password on no command line at all: System Settings →
Lock Screen → require password after screensaver/display off → **Immediately**
(Systemeinstellungen → Sperrbildschirm → *Sofort*).

If you use the CLI, note that **`histignorespace` is off on this machine**, so the
usual leading-space trick does *not* keep it out of `~/.zsh_history` — run
`setopt histignorespace` in that shell first. The argv exposure itself is moot
here: the same password already sits in `/etc/kcpassword` by design. The shell
history is the part that actually persists.

`make lock-at-boot-setup` **refuses to install** unless the first half is already
in place, because a plist that sleeps the display and leaves the machine unlocked
is worse than no plist — it reads as done.

Two implementation notes that contradict most write-ups online:

- **`CGSession -suspend` does not exist.** The `User.menu` bundle was removed;
  checked on this disk, not inferred. Every "auto-login but locked" recipe that
  recommends it is dead on macOS 26.
- **`osascript` sending ⌃⌘Q is the wrong tool here** — it needs Accessibility
  (TCC), which cannot be granted to a launchd job on a headless machine because
  there is nobody to click Allow. `pmset displaysleepnow` needs no TCC.

Resuming a suspended session over Screen Sharing does **not** start a new
session, so unlocking from the MacBook does not re-fire the agent.

`make lock-at-boot-check` reports FileVault, autologin, autorestart, screenLock,
agent presence, live lock state, keychain lock state, and the agent's last run.

**What this does not do:** it stops someone walking up and using the desktop. It
does nothing about Mac Sharing Mode, which is a FileVault question. Do not let it
stand in for the two things that actually shrink the blast radius — re-deriving
what `headless.iu.refs` really needs to hold, and having a written theft runbook
(Tailscale device removal, `op://mini/github/token` revoke, Claude session
revoke, IU credential rotation, Find My → Erase Mac).

Activation Lock is **Enabled** and Find My is on, which covers the opportunistic
case well: the machine is unsellable and remotely erasable. It does nothing
against someone who wants what is on it.

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
- `make devhost-health-check` on the mini prints **six** components green — or, for
  dev vhosts, `(skipped)` on a machine that never set `DEV_DOMAIN`, which is also a pass
  (herdr, sshd, tailscaled, mosh, GitHub push credential, dev vhosts) — and the Kuma
  monitor goes green within one interval.
- `tailscale serve status` still shows both existing rows (`:7730` tailnet, `:8443` Funnel).
  This plan must not change them.
- Only if you built step 4: a dev server over Caddy keeps HMR alive past 60s (the #18827
  failure window).
- Only if you built door 2 (step 4b): `caddy list-modules | grep dns.providers.cloudflare`
  is non-empty, `https://<app>.mini.jkrumm.com` serves the same app as the `.ts.net` door,
  and the port-based door still works unchanged.
