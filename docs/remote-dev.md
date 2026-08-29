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
the less common question. The MacBook's sanctioned repos are `dotfiles`,
`dotfiles-private`, `photo-flow`, `brain` — no project repos — so the daily motion
is "start work over there and check on it", which needs no terminal.

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

4. **Quitting the macsys app is not enough — it must be removed.** The first
   version of this migration left the app in place "so rollback stays cheap".
   The first reboot test destroyed that assumption, which is precisely what the
   test was for. macOS relaunches the app itself at boot as the container for
   its still-activated system extension; `TailscaleStartOnLogin = 0` does not
   stop it, because no login item is involved. Two Tailscale stacks then contest
   the tunnel.

   The symptom is the nastiest one in this whole document, because **the node
   looks perfectly healthy**: `BackendState Running`, right IP, all three tags,
   29 peers, `tailscale ping` answering in 25ms. `tailscale serve` ports keep
   serving — they terminate *inside* tailscaled. Everything that needs delivery
   to a host process is silently dropped. Measured 2026-08-06 after reboot #1:

   | Port | Terminates in | Result |
   |-|-|-|
   | 7730, 8443 | tailscaled itself | **up** |
   | 22 (sshd), 443 (caddy), ICMP | the host network stack | **dead** |

   Quitting the app restored all of them instantly. `systemextensionsctl
   uninstall` cannot remove the extension — SIP blocks it, and disabling SIP to
   tidy up an extension is not a trade worth making. Removing the container app
   is the supported route: with no app, macOS has nothing to launch. It is
   *moved*, not deleted, to `/Users/Shared/tailscale-macsys-rollback`.

Rollback stays available while the `mini-old` node record exists — that record,
not the app bundle, is the real rollback. Restoring: `sudo brew services stop
tailscale`, `mv` the app back from `/Users/Shared/tailscale-macsys-rollback`,
re-enable the login item, relaunch.

**Reboot is a required acceptance test for this host, not an optional one.**
Every claim in this section about starting before login and surviving unattended
is a claim about boot, and boot is the one path that cannot be verified any other
way. The failure above was invisible to every other check — including the
heartbeat, which would have gone on reporting a healthy tailnet.

What this still does not give you is a genuinely independent path. If tailscaled
fails to start at all, physical access remains the only recovery — but launchd's
`keep_alive` plus starting before login makes that a much narrower window than a
quittable GUI app ever was. A `cloudflared` door behind Cloudflare Access is the
designated upgrade if that ever proves insufficient.

### 9. human-queue — the async present-human channel from the mini

The mini can now `ssh iumac` (§10, a dedicated restricted key), so a network
path back to the MacBook exists — but SSH gives it reach, not a fingerprint.
This queue is for the part reach doesn't buy: work that needs a *present
human* — biometric `op` (`make secrets-seed`), the Tailscale ACL push, or any
decision only a person can make. Before this existed, an agent on the mini
signalled blocked-on-human work by editing prose handover docs, which the
human might not read for days. human-queue is the async channel instead: an
agent on the mini enqueues a request; the human on the MacBook lists,
inspects, and runs or denies it; a result lands back on the mini for a
waiting agent to pick up.

| Side | Command | Runs on |
|-|-|-|
| Enqueue | `ask-human.sh ask "<text>" [--cmd <command>] [--wait [seconds]]` | the mini |
| Inspect (own request) | `ask-human.sh list` / `ask-human.sh status <id>` | the mini |
| Drain — count | `make human-queue-count` (`human-queue.sh count`) | the MacBook |
| Drain — list | `make human-queue` (`human-queue.sh list`) | the MacBook |
| Drain — inspect | `human-queue.sh show <id>` | the MacBook |
| Drain — act | `human-queue.sh run <id>` / `human-queue.sh deny <id> [reason]` | the MacBook |

Queue state is two small files per request under
`${XDG_STATE_HOME:-$HOME/.local/state}/human-queue/` on the mini (mode 700
dir, mode 600 files): `<id>.req` (written by `ask-human.sh`) and `<id>.res`
(written back by `human-queue.sh`). A request is "pending" for as long as no
`.res` exists yet. `--wait` polls for the `.res` every 5s and exits
0/1/2/3 for done/denied/failed/timeout, so a blocked agent can sit on the call
instead of polling itself.

**The transport is the existing MacBook→mini ssh hop, not a new credential.**
`human-queue.sh` reuses the same `ssh mini` (`BatchMode=yes`,
`ConnectTimeout=8`) this whole document is about — no inbound door opens on
the MacBook, and the mini gains no new way to reach out. It refuses to run at
all on the cache backend (use `ask-human.sh` there instead), the same
marker-driven routing `remote-dev.sh` already uses.

**The mini only ever *proposes* a command string — it never executes one.**
`human-queue.sh run <id>` prints the request (including any `cmd`, verbatim
and clearly delimited), warns that it was authored by an agent on the mini and
is about to run on the MacBook with the human's full privileges, and requires
a typed `yes` on a real TTY — anything else, or no TTY at all, aborts with no
side effects. There is no non-interactive path to `run`. That is the actual
security property: a compromised or misbehaving mini can only ever put a
string in front of a human, never open a shell on its own.

**No LaunchAgent drains this, and that is deliberate.** Every other queue in
this repo (devhost-health, secrets-freshness) is polled by a plist. This one
isn't, because the ssh hop it rides sits behind the 1Password SSH agent, which
is per-use biometric — a poller would mean an unattended Touch ID prompt
firing on its own schedule, forever, which is not a trade worth making for a
convenience feature. Draining is something the human does.

`hooks/machine-role.ts` folds a one-line nudge into the SessionStart context
on the `op` backend only, calling `human-queue.sh count` with a hard 2500ms
timeout — any failure (unreachable mini, missing script, non-numeric output)
collapses to silence, never an error, matching that hook's existing contract
that a secrets/context hint must never block a session.

### 10. mini → iumac — the reverse reach

Access used to be one-way: MacBook → mini (OpenSSH, the human's 1P key), plus
mini → homelab/vps (Tailscale SSH, keyless). The mini had no path back to the
MacBook. That blocked concrete jobs with no queue-shaped substitute — pulling
`usage-tracker` stats off the MacBook, syncing `brain`/`dotfiles`, general
file transfer — so `ssh iumac` / `rsync … iumac:…` from the mini is now
allowed, over a dedicated key.

The Tailscale ACL already grants `tag:mac → tag:mac` on `tcp:22`,
symmetrically — both Macs carry `tag:mac`, so no ACL change was needed. What
was missing is auth: macOS ships no Tailscale SSH server, and the MacBook's
sshd offers `publickey` only, so a key is required. `~/.ssh/id_ed25519_iumac`
on the mini (mode 600, no passphrase, never leaves the mini, never enters
1Password or the secrets cache) is that key; its public half is installed via
`config/ssh/authorized_keys.iumac` + `make authorized-keys`, restricted
(`restrict,pty`) so it carries no port/agent forwarding, no X11, no user-rc.
That file installs only on a present-human machine (backend marker != cache)
— `make authorized-keys` skips it on the mini itself, since the mini holding
both halves of this keypair would turn an outbound-only credential into an
inbound one on the machine most likely to be compromised first.
Agent forwarding off is the load-bearing restriction — without it the mini
could borrow the human's 1Password-held GitHub/commit-signing key on every
connection. `pty` is re-enabled after `restrict` so interactive shells still
work; scp/rsync/sftp/git are unaffected by `restrict`.

`Host iumac` in `ssh_config` pins `IdentityAgent none` — not optional on the
mini, since `SSH_AUTH_SOCK` there still points at the 1Password agent socket
and any target that consults it hangs rather than fails. `IdentitiesOnly yes`
so only this key is ever offered; `ControlMaster` for the same reason as
`Host mini` — repeated handshakes on an rsync/git loop.

**Live since 2026-08-06**, verified from the mini rather than assumed:
`ssh iumac 'whoami'` → the MacBook account; `rsync -a iumac:SourceRoot/…`
transferred a real file; `~/.claude/projects` is reachable (89 transcripts,
42M — the `usage-tracker` source that motivated this). The restrictions were
verified positively too, not trusted: `ssh -A iumac` leaves `SSH_AUTH_SOCK`
**unset** on the remote side, and `-R` remote port forwarding is refused.
Note `-L` is *not* a valid test of `no-port-forwarding` — a local forward needs
no server-side setup, so it "succeeds" with the restriction fully in force.

Two rollout gotchas, both of which cost a diagnosis round:

- **`tailscale set --hostname` does not move MagicDNS** on an already-registered
  device. It set `"HostName": "iumac"` while `DNSName` stayed
  `iu-mac-book.<tailnet>`, so `ssh iumac` failed at *name resolution* while
  looking like a broken key. MagicDNS follows the control-plane machine name;
  only the admin console (Machines → device → Edit machine name) rewrites it.
  Verify `DNSName`, not `HostName`, after any rename.
- **macOS Remote Login is access-listed, and MDM owns the list.**
  `com.apple.access_ssh` on the IU MacBook contains `IT-Admin` plus gid 80
  (`admin`) — the account is admitted only by way of `admin` membership, which
  is not ours to guarantee. If a policy push drops it, this path breaks as an
  *accepted* key followed by an immediate post-auth close with **no sshd log
  line**. `make remote-dev-doctor` now names all three failure modes
  (unresolvable / key missing / accepted-then-closed) because they are
  indistinguishable from the mini otherwise.

**The honest cost:** the mini now holds a private key that reaches the
human's MacBook account. A mini compromise therefore reaches the MacBook's
*files and user session*, not just its own — a real widening of blast radius,
accepted deliberately for the sync/pull workflows. It does not hand over
`op://Private/*`: that still needs a biometric `op` prompt on the MacBook
itself, which a stolen key cannot answer. Full model:
`dotfiles-private/docs/access-model.md`.

### 10b. The SACL dropped us — userland sshd on :2222 (2026-08-07)

The predicted failure landed. `dseditgroup -o checkmember -m johannes.krumm
com.apple.access_ssh` on iumac reads **NOT a member** — MDM pinned the group to
`IT-Admin` + a nested MDM group and dropped the `admin` membership that used to
admit us. So the mini's `ssh iumac` on **:22 authenticates then closes with no
sshd log line**, exactly the accepted-then-closed mode above.

The fix routes *around* the control rather than fighting it (the `dseditgroup`
re-add is whack-a-mole — MDM re-drops every check-in — and a more direct override
of an employer control). We run our **own** userland sshd on **:2222** that never
consults the group.

**The mechanism — the SACL is a PAM check.** `/etc/pam.d/sshd` enforces it via
`account required pam_sacl.so sacl_service=ssh`, and PAM runs only under `UsePAM
yes`. A second `/usr/sbin/sshd` started with `UsePAM no` + pubkey-only never
invokes PAM → `pam_sacl` never runs → the MDM group is never consulted. Proven
end to end: shell + pty + scp as `johannes.krumm`, zero SACL involvement, no root
(same-user login on a port >1024 needs none).

**The door — `dotfiles/tailnet-sshd/`, `make tailnet-sshd-setup` (MacBook-only):**

- Apple's `/usr/sbin/sshd`, `UsePAM no`, pubkey-only, `AllowUsers johannes.krumm`,
  reusing `~/.ssh/authorized_keys` (the mini's `restrict,pty` key is already there
  from §10, so this door needs no new credential).
- Binds **loopback** `127.0.0.1:2222`; the tailnet door is a `tailscale serve
  --tcp 2222 tcp://127.0.0.1:2222` forwarder. This is Collie's loopback-behind-serve
  shape and it is what makes the door **self-healing**: tailscaled re-applies serve
  across every daemon restart, sshd's loopback socket never flaps, and serve
  forwards by *port* so a node re-auth that changes the tailnet IP doesn't break it.
  Survives reboot, login, sshd crash (`KeepAlive`), tailscaled restart, IP change.
- GUI-session LaunchAgent `com.jkrumm.tailnet-sshd` (`RunAtLoad` + `KeepAlive`,
  logs `~/Library/Logs/tailnet-sshd.{log,err}`). A userland sshd is exactly what
  dodges `pam_sacl`, so this is deliberately not a root LaunchDaemon.
- **Invisible to the corp LAN**: only tailscaled listens externally, so an IT
  portscan of iumac on the LAN finds nothing on 2222 — the door exists only on the
  tailnet, ACL-gated (`tcp:2222` on `tag:mac → tag:mac`) and key-only. This is a
  deliberate route-around of an IT-set control on a work machine; the low profile
  is part of the point.
- `config/ssh_config` pins `Host iumac → Port 2222`, so bare `ssh iumac` from the
  mini lands here once the mini regenerates `~/.ssh/config` (`make setup` /
  `_setup-ssh`). `make tailnet-sshd-status` asserts both halves (loopback listener
  + serve door). Teardown: `make tailnet-sshd-teardown`.

The `op`-fails-fast property and the "honest cost" above are unchanged — :2222 is
still a non-interactive ssh session with no unlocked 1Password.

**TCC boundary — deliberately not solved with Full Disk Access.** The door reads
non-protected paths freely (home root, `~/SourceRoot`, `~/.claude`, `/tmp` — which
is why the usage-tracker/brain pulls work), but macOS TCC blocks the sshd-spawned
process from `~/Downloads`, `~/Desktop`, `~/Documents` and the cloud folders with
`Operation not permitted`. The fix is to **stage the file out** to a non-protected
path (`cp ~/Downloads/x ~/xfer/x`, then pull `iumac:xfer/x`), *not* to grant sshd
Full Disk Access. FDA on `/usr/sbin/sshd` is the most EDR-flagged TCC grant there
is (remote daemon + read-everything = textbook exfil signature), it can't be
scoped to this door (same binary as the system sshd, so IT-Admin sessions would
gain it too), and it undoes the low-profile posture the whole door is built for.
TCC-limited is a feature. Hit + resolved 2026-08-07 pulling a 48 KB CSV.

### 11. File shuttle — SMB mount of the mini — DONE 2026-08-18

`smb://mini/jkrumm` mounted from the MacBook, `~/Shuttle` on the mini as the drop
folder, for ad-hoc human file movement between the two Macs. Everything durable
still routes elsewhere — repos through `rd`/git, the vault through brain-sync,
anything a mini-side agent reads onto the mini itself — because the mount gives
**no offline copy**: mini down or MacBook off the tailnet and Finder hangs on a
stale mount. `tcp:445` on the `tag:mac → tag:mac` grant. Rationale, routing table
and the full setup: `dotfiles/CLAUDE.md` → *File shuttle*.

Worth restating here because it looks like a transport fault and is not: a
listening `:445` and a running `smbd` are **not** a working SMB server. macOS
stores no `SMB-NT` hash for a local account until the user is ticked in File
Sharing → Options, and without it `smbd` refuses *every* principal — guest,
password, Kerberos — over the tailnet and on its own loopback. Minting it is
GUI-only (Screen Sharing, `open vnc://mini`); no `pwpolicy`/`dscl`/`sysadminctl`
verb can. Diagnosed against loopback, which is what ruled out Tailscale in one
step — do that first next time.

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

## Applying a macOS update to the mini — learned 2026-08-29

The drift monitor names a pending macOS update; *applying* it headlessly has one
non-obvious failure mode that cost two spurious reboots and ~25 minutes. All of
it is encoded in **`make mini-macos-update`** (MacBook-only, TTY or `YES=1`);
what follows is what that target does and why, for when it has to be done by
hand.

```bash
# from the MacBook — password twice on one stdin, never in argv
PW=$(op read "op://Private/mac-mini-server/password" --account tkrumm)
printf '%s\n' "$PW" | ssh mini 'read -r pw
  { printf "%s\n" "$pw"; printf "%s\n" "$pw"; } |
    nohup sudo -S softwareupdate -i -a -R --user jkrumm --stdinpass \
      > ~/Library/Logs/macos-update.log 2>&1 &'
```

Three things that shape are answering:

- **Apple Silicon needs volume-owner auth**, hence `--user … --stdinpass`. `sudo -S`
  reads one line from stdin and `--stdinpass` reads the next, so feeding the same
  password twice satisfies both and keeps it out of `ps auxww` — the one thing a
  `sudo … --stdinpass "$PW"` spelling would get wrong. (If sudo's timestamp is
  already warm it consumes nothing and softwareupdate takes line 1; both work.)
- **Detached, logging to `~/Library/Logs`.** The run outlives the ssh connection
  on purpose: a `brew upgrade` of the `tailscale` formula in the same maintenance
  window restarts `tailscaled` — the transport this very session is riding — and
  a foreground installer dies with it.
- Never `/tmp` for the log (see the agent-logs section).

**The trap: the CLI returns in seconds, prints `Restarting...`, and does not
restart.** That line is a *request*, not an event. The real work starts
afterwards and runs for several minutes:

```
pgrep -fl UpdateBrainService      # com.apple.MobileSoftwareUpdate…UpdateBrainService, 70-100% CPU
pgrep -fl SoftwareUpdateLauncher  # …-RootInstallMode YES -SkipConfirm YES
```

Those two processes prepare the update and then restart the machine *themselves*.

**Do not `shutdown -r now` to hurry it along.** Done twice here, and both times
the mini booted straight back into the *old* version: a forced reboot aborts the
prepare, and a staged asset alone does not apply at boot. Nothing errors and
every artifact still looks armed — `/System/Volumes/Update/Update.plist` shows
`personalized-on-preboot` and `do-postupgrade-boot`, `nvram -p` shows
`ota-updateType incremental`, `RecommendedUpdates` still lists the update — so
the only honest check is `sw_vers -productVersion`, never an exit code and never
a plist. Wait for the mini to drop off the tailnet on its own.

**When the request really is swallowed**, neither process is there a minute
after `Restarting...`. The OS can route the restart to a *notification* instead
of performing it — `usernoted` was seen registering the `RESTART_NOW` /
`RESTART_LATER` categories — and a stale GUI session is what makes that happen:
after 22 days of uptime this one had an `EscrowSecurityAlert` modal up and a
Chrome left over from a `/browse` session pinning two cores. Re-running the
same command against a freshly booted session worked first try. So the order
that works is: plain reboot if the session is old, *then* the installer, then
leave it alone.

## Blocking constraint

**The inbound path is not testable from the mini.** Inbound auth depends entirely on the
MacBook's 1Password agent, which cannot sign headlessly, so the mini cannot SSH to itself
— it has no copy of the key that admits it.

> Amended 2026-08-06: the mini is no longer key-free. It now holds
> `~/.ssh/id_ed25519_iumac`, a dedicated *outbound* key for the reverse leg into the
> MacBook (see the mini → iumac section above). That key is not in the mini's own
> `authorized_keys`, so the claim above still holds for the **inbound** path — but the
> older blanket phrasing "no SSH private key material at all" is retired.

Everything that does *not* depend on inbound ssh has now been verified locally: the
installs, the ssh config, the herdr server and its crash semantics, the ACL grant landing
in the live packet filter, and every component of the health check. What is left is
exactly three interactive tests — `mosh mini`, `herdr --remote mini`, and the lid-close
reattach. A non-interactive probe cannot stand in for the first: `mosh mini -- true`
fails at `sign_and_send_pubkey … agent refused operation` because the 1Password agent
will not sign without a human, long before mosh is even reached.

Amended 2026-08-06: the rename landed and `ssh iumac` resolves — see §10 for the full
mini→iumac reach. The dead end this paragraph used to send readers down is documented,
not repeated here: `tailscale set --hostname` does **not** move MagicDNS on an
already-registered device (only the admin console does, Machines → device → Edit
machine name) — see the gotcha at §10 above for the mechanism and how it was diagnosed.

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

---

## CLAUDE.md reference snapshot (moved here 2026-08-27 for length)

Everything below was condensed out of the root `CLAUDE.md` "Remote dev" section
when that file exceeded the 150k-char agent context limit. It documents the
**current, settled state** (not the plan above, which is largely DONE anyway) —
treat it as the fuller version of what CLAUDE.md now states tersely.

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

**`make herdr-setup`** wires three things, and the first two are easy to
confuse because both are "the Claude Code integration". `herdr integration
install claude` writes a SessionStart **hook** (`~/.claude/hooks/herdr-agent-state.sh`)
which is what makes a pane report real agent status instead of
`agent_status: "unknown"` — the entire reason to prefer herdr over tmux. That
tells herdr about the agent. **`scripts/herdr-skill-sync.sh` is the other
direction**: it regenerates `skills/herdr/SKILL.md` from `herdr --skill`, which
is what tells the *agent* about herdr — how to drive panes, tabs, workspaces and
sibling agents over the CLI. It then starts the **server only on the dev host**,
detected by the `cache` backend marker, the same signal `git-headless` uses; a
thin client gets the hook and the skill but no server.

**That skill is GENERATED, never hand-written, and the binary is the
authority.** herdr 0.8.2 (#2847) bundles it and keeps it matched to that
release's CLI and lifecycle behaviour, so a hand-maintained copy is a second
source of truth that goes stale silently on every `brew upgrade herdr` — and
stale CLI syntax is worse than none, because an agent follows it confidently.
It is **tracked anyway** rather than generated straight into `~/.claude`,
because the git diff is the review: an upgrade that changes what agents are told
to do on this machine should arrive as a reviewable diff, the same argument that
makes the Brewfile a supply-chain audit trail. The sync refuses to write a
short or frontmatter-less file and keeps the tracked one instead — a degraded
SKILL.md does not error at load time, it just quietly stops triggering.

Two things follow from herdr's own `--help`, which carries an "Are you an AI?"
block: it points control questions at `herdr --skill` and says to **skip it if a
herdr skill is already in context** — so installing ours is what makes that
block a no-op. The other two URLs there are task-scoped and deliberately *not*
in the skill: `herdr.dev/agent-guide.md` (help a human set herdr up) and
`herdr.dev/llms.txt` (debug herdr itself). Reach for those only for those jobs.

**How an agent knows it is inside herdr: `HERDR_ENV=1`.** herdr injects
`HERDR_ENV`, `HERDR_PANE_ID`, `HERDR_TAB_ID`, `HERDR_WORKSPACE_ID`,
`HERDR_SOCKET_PATH` and `HERDR_BIN_PATH` into every managed pane, and the skill's
first instruction is to test that variable and stop if it is unset. So the same
skill is inert on the MacBook (no server, no vars) and live on the mini with no
per-machine branching. **The vars are inherited at spawn, not tracked** — a
process that outlives its pane keeps whatever `HERDR_PANE_ID` it was born with,
so a `claude --bg` daemon can carry a stale pane ID. Resolve the caller with
`herdr pane current --current` rather than trusting an inherited ID in anything
durable.

Three non-obvious constraints, all load-bearing:

- The server must start as a **session leader**, via
  `herdr/herdr-server-start.py` pinned into the brew plist by
  `_herdr-supervise`. herdr derives `detached_server_daemon` from
  `getsid(0) == getpid()`, and a launchd job is not one — measured on the mini:
  pid 671, pgid 671, **sid 1**. Every `desk` launch therefore asked *"the remote
  server was started by a herdr build that may not survive SSH connection loss …
  restart the remote server now? [y/N]"*, where the only correct answer was N
  forever, because `y` restarts the server outside brew services and destroys
  every pane. The warning is true as asked and false as meant: launchd owns the
  job. setsid(2) fails with EPERM for a process-group leader — exactly what
  launchd hands over — so the wrapper forks and calls it in the child. A/B
  proven against an isolated server started in the launchd process shape:
  `detached_server_daemon` false without it, true with it. **`brew upgrade
  herdr` and every `brew services start/restart` regenerate that plist and strip
  the wrapper silently** (colima's trap, different file); `brew-upgrade.sh`
  asserts it, and the prompt coming back is the symptom. Applying it to the
  *running* server is `make herdr-restart YES=1` — bootout + bootstrap, never
  `brew services restart` (regenerates the plist on the way up) and never
  `launchctl kickstart -k` (restarts from the cached job definition). It **kills
  every pane**, so it is a deliberate, human-timed command, never part of
  `make setup`.
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

**`config/zsh/claude-auth.zsh` is an ARMED fallback, and as of 2026-08-17 it is
what is actually holding the mini up.** This file said "dormant, leave it
unminted" for months; the token has in fact been minted and cached, the mini's
keychain credential is **gone** (bare binary: `loggedIn: false, authMethod:
none`), and every herdr pane has been quietly running on the token instead.
Nothing was broken from the outside, which is exactly why it went unnoticed.

**The fallback is the most likely cause of the failure it covers.** It was
documented as a fallback and coded as a *preemption*: once the ref existed it
injected the token on every zsh `claude` launch, so `command claude` never
touched the keychain. That credential is a short access token plus a **rolling**
refresh token — it renews itself when the binary uses it, and only then. Never
exercised, it ages out. Fixed the same day: probe the real credential (~245ms,
measured), prefer it, fall back only on failure — **every launch, uncached**,
which is also what keeps the keychain's rolling refresh alive.

**The one-hour verdict cache that shipped with that fix is gone, and the reason
is worth keeping.** Within a day it produced a `keychain-ok` stamp on a host
whose bare binary reported `loggedIn: false` — impossible by the code as
written, not reproducible on demand, and not explained by the obvious hypothesis
either (running the binary *with* the token persists no credential; measured
both ways). A wrong positive there suppresses the fallback for a full hour, so
`claude` runs with **no credential at all** and silently bills API credits — the
exact failure the file exists to prevent, reintroduced by the optimisation
guarding it. It was buying 245 ms against a Claude Code startup an order of
magnitude larger. Unexplained mechanism + costly silent failure + negligible
saving = delete it, rather than add a second mechanism to watch the first.

Restoring the good credential is a `/login` in a **herdr pane on the mini**
(`work <repo>` or a pane, then `/login`, paste the URL back) — a GUI-session
child, so the keychain is reachable. Prefer that over re-minting: a `setup-token`
credential is a **one-year token with no refresh and no reliable server-side
revocation**, a downgrade from a keychain credential that refreshes itself
(access ~8h, refresh rolling). `check_claude_auth` now probes **both** paths and
grades three states — keychain ok / keychain dead but token working / neither —
because the bare-binary-only version reported a perfectly working host as the
last one, and a component that overstates is one you learn to skim past.

**The middle state PASSES and is merely named in the msg.** Max billing is
intact, every herdr pane and `rd bg` daemon works, and the cost is a worse
*credential*, not a broken host — so failing there would sit the composite
monitor red indefinitely for a state that has been accepted, which is the nag
the 1Password backup monitor already taught us to avoid. The real failure is not
softened: when the token stops working the check fails loudly, and that is also
what covers the one-year cliff. There is deliberately
**no** separate token-expiry monitor: probing the fallback covers the one-year
cliff by construction.

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
could rot. On a machine where the token was never minted the read simply fails
and the wrapper falls through **silently** — it must not break a working machine
to announce a future step. (On the mini it *has* been minted; see above.) The
reporter for the failure case is `check_claude_auth` in
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

### Database access — MacBook → mini (`make db-tunnel-setup`)

The mini's dev databases bind `127.0.0.1` in their compose files, so a GUI client
on the MacBook needs a forward. `com.jkrumm.db-tunnel` is a `KeepAlive`
LaunchAgent holding one long-lived `ssh -N` with every declared `-L`; declared
state is `dbtunnel/tunnels.conf`, applied by `make db-tunnel-setup`, probed by
`make db-tunnel-status`. **Local ports are the real port + 30000** (33306, 36379)
because this machine runs its *own* copy of the same stack — a forward on 3306
would either fail to bind or silently shadow the local database.

**Not `tailscale serve --tcp`, and the reason is the same one the collie row
gives**: serve would publish a raw MySQL socket to every tagged device, guarded
only by a compose-file `root`/`toor`, where a forward keeps the loopback bind
true and puts an SSH key in front. **Not Caddy either** — MySQL is not HTTP and
this build ships no layer4 module.

Four things that cost a debugging cycle each, all verified under a throwaway
launchd job rather than reasoned about:

- **launchd sets `SSH_AUTH_SOCK`, it does not leave it unset** — to Apple's own
  ssh-agent, a valid socket holding **zero identities**. So `[ -S "$SSH_AUTH_SOCK" ]`
  passes, ssh gets an agent with no keys, and the tunnel fails `Permission denied
  (publickey)` while `ssh-add -l` from a terminal looks perfectly healthy. The
  script prefers 1Password's socket and treats the inherited one as the fallback —
  deliberately the opposite of the obvious ordering. This machine holds **no
  private keys on disk** (`ls ~/.ssh/id_*` is empty); every identity is the
  1Password agent, which *does* sign for a launchd job with no prompt.
- **`-o IdentityAgent=<path>` needs literal quotes inside the value.** 1Password's
  socket lives under "Group Containers", ssh splits an `-o` argument on
  whitespace, and the resulting `keyword identityagent extra arguments at end of
  line` falls through to `Permission denied (publickey)` — which reads as a key
  problem and sends you looking in the wrong place entirely.
- **`ControlMaster=no` + `ControlPath=none` are mandatory.** `ssh_config` sets
  `ControlMaster auto` for mini; a tunnel riding that shared socket dies when the
  last interactive session exits and `ControlPersist` expires.
- **ssh must run in the foreground** (never `-f`). launchd's KeepAlive supervises
  the process it spawned; a forked-away ssh looks like a clean exit and gets
  respawned forever. Reconnect is `ServerAliveInterval=15 × CountMax=3` → ssh
  exits within ~45s → launchd re-dials. No autossh, no wrapper loop.

`ThrottleInterval 30` keeps a closed lid or an off-network mini from filling the
log — an unreachable mini is a normal laptop state, not a fault.

### File shuttle — the mini's home mounted over SMB (`~/Shuttle`)

`smb://mini/jkrumm` mounted from the MacBook, with **`~/Shuttle` on the mini as
the agreed drop folder** — the door for moving a file between the two Macs
without thinking about it. Set up 2026-08-18. macOS auto-shares the
authenticating user's home, so the share is the whole home dir and `Shuttle` is
just a folder inside it; a share point exposing only `Shuttle` would need `sudo
sharing -a ~/Shuttle`, which nothing needs yet.

**`~/Public/Drop Box` is the wrong tool and was rejected.** It is a *multi-user*
permission convention — Public readable by other accounts, Drop Box 733 so
others can write but not list. Both machines are the same human logging in as
the same user, so that asymmetry buys nothing except a folder you cannot browse.

**Use it for ad-hoc human file movement, and nothing else:**

| Moving | Route |
|-|-|
| A one-off file between the Macs (export, screenshot, PDF, installer) | **this mount** |
| Code / a repo | `rd`, or git — repos live on the mini, the MacBook is a thin client |
| Vault pages | brain-sync through GitHub — it has an offline copy on both machines and reconciles every 5 min; never route `brain` through the mount |
| Anything an agent or LaunchAgent on the mini reads | must be **on** the mini — the mount is client-side and dies with the MacBook |

**No offline copy** — but do not over-read that, and note the routing table
above does **not** rest on it. Repos go through git because they need history and
the mini is the dev host; the vault goes through brain-sync because it is edited
on both machines; agent-read files live on the mini because the mount is
client-side. Every one of those holds at 100% uptime.

**The availability risk is the MacBook's, not the mini's.** The mini is the
always-on host and behaves like it (11d17h up when this was written; the
preceding reboots were deliberate). What actually goes away is *this* end — the
IU corp network, travel, a Tailscale hiccup. And a stale SMB mount does not fail
cleanly: Finder beachballs and open file handles hang, which is worse than a file
simply being absent. That is the honest trade against Syncthing. Over the tailnet
(~7 ms) it is otherwise unremarkable.

**`tcp:445` is granted `tag:mac → tag:mac`** in `dotfiles-private/tailscale-acl.jsonc`.
Symmetric, because both Macs carry `tag:mac` — the MacBook is reachable on 445
too; its File Sharing is off, and turning *that* on is what would expose it, not
the grant. Without the grant the mount times out with nothing in any log, the
usual silent ACL failure.

**The gotcha that costs an hour: a listening `:445` and a running `smbd` are not
a working SMB server.** macOS stores no NTLM credential for a local account by
default — `ShadowHashData` holds only `SALTED-SHA512-PBKDF2` and
`SRP-RFC5054-4096-SHA512-PBKDF2` — and `smbd` validates a password against the
**`SMB-NT`** hash. Missing it, the server refuses *every* principal identically:
guest, password, and Kerberos, over the tailnet **and on its own loopback**. The
error is a flat `Authentication error` client-side and
`gss_accept_sec_context … status: 0xc000006d` (STATUS_LOGON_FAILURE) in the
server's log, which reads like a network or Kerberos fault and is neither.

Two corollaries worth holding:

- **`smbutil view -g //localhost` failing does NOT mean guest access is off.** In
  this state everything fails, so that probe cannot distinguish guest from any
  other principal — it was read as proof of "not actually exposed" and proved
  nothing. Check the share flags (`sharing -l` → `guest access`), not a probe.
- **Kerberos is not the escape hatch here.** Every Mac runs an LKDC and Apple
  clients normally authenticate against it with no NT hash — but `kinit` against
  the local realm fails `unable to reach any KDC … tried 0 KDCs` from a
  non-GUI context, and the tailnet ACL grants no port 88 anyway. Over a tailnet,
  NTLM against a Keychain-stored password is the path that actually works.

Minting the hash is **GUI-only and cannot be scripted**: System Settings →
General → Sharing → File Sharing ⓘ → Options → tick the user → type the
password. The prompt is the mechanism, not a formality — the stored login hash
is non-recoverable, so macOS can only compute `MD4(utf-16le(password))` from
plaintext you supply. No `pwpolicy`, `dscl`, `sysadminctl` or `sharing` verb
injects it; `pwpolicy -sethashtypes SMB-NT on` only sets what gets stored *next
password change*. On the mini that means Screen Sharing (`open vnc://mini`,
tcp:5900 already granted). Verify with the data, never the setting:

```bash
ssh mini 'sudo plutil -extract ShadowHashData.0 raw -o - \
  /var/db/dslocal/nodes/Default/users/jkrumm.plist | base64 -D | plutil -p -' \
  | grep SMB-NT
```

**Guest access on a share is a separate switch, and `sharing -g` takes three
digits, not a boolean** — `afp,ftp,smb` in that order, so `-g 0` prints usage and
changes nothing while looking like it worked. `sudo sharing -e <name> -g 000`
disables it, `-g 001` restores SMB guest. The mini's `AppleTV` share carried
`guest access: 1` with `read-only: 0` and was turned off in the same pass.

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

