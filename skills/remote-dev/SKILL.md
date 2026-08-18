---
name: remote-dev
description: Operate the Mac mini remote dev host — connecting from the MacBook over mosh or herdr --remote, running and reattaching many Claude Code agents, herdr workspaces/panes and its socket API, claude --bg durable daemons, the Uptime Kuma readiness heartbeat, and the failure modes specific to a headless always-on Mac. Use when the user mentions herdr, mosh, the mini, "remote dev", "dev host", detaching or reattaching agents, "did my agent survive", sessions dying on lid-close, or asks how to reach a dev server running on the mini.
---

# Remote dev — the mini as dev host

The Mac mini is the always-on dev host; the MacBook is a thin client. Agents run
on the mini and outlive the MacBook.

**Orientation first.** Almost every mistake here comes from not knowing which
machine you are on. The SessionStart hook says: `Backend: cache` = the mini,
`Backend: op` = the MacBook.

## Four layers — never collapse them

| Layer | Tool | Solves | Cannot solve |
|-|-|-|-|
| Reachability | Tailscale | stable address, NAT traversal | anything above it |
| Transport | mosh | keystrokes survive lid-close + roaming | multiplexing, port-forwarding, persistence |
| Persistence + UI | herdr (on the mini) | panes stay alive, per-pane agent state | anything about the network |
| Service exposure | Caddy | dev servers with real HTTPS + working WebSockets | anything about terminals |

Plus one thing that rides on top of all four and depends on none of them:
`claude --bg`.

## Two different questions

Keep these apart — collapsing them is what makes this stack feel complicated:

| Question | Answer |
|-|-|
| How do I *go look* at the mini? | `dev` / `desk` — the transport layers below |
| How do I *put work on* the mini and check on it? | `rd` — no terminal needed at all |

Most days are the second one. The MacBook's sanctioned repos are `dotfiles`,
`dotfiles-private`, `photo-flow`, `brain` — everything else lives on the mini, so
`rd` resolves every project-repo path on the host; that is why its commands take
a repo **name**, never a path.

```bash
repos [filter]         # what's on the dev host, with branch + dirty count
work <repo>            # herdr workspace + claude for that repo (idempotent)
rd bg <repo> <task…>   # durable claude --bg daemon
agents                 # every agent on the host, both lanes, deduped
rd read <agent>        # read its output without attaching
rd say <agent> "…"     # send it a prompt
```

`work`, `agents`, `repos` are shorthands; `bg`/`read`/`say` stay behind `rd`
because the bare names are a zsh builtin, a zsh builtin and `/usr/bin/say`.

`rd` routes itself off the secrets-backend marker — local exec on the mini, one
ssh hop from the MacBook — so the same words work on both machines.

## Connecting from the MacBook

The normal way in is two shell functions (`config/zsh/remote-dev.zsh`):

```bash
dev [session]   # moshes into the mini, lands in herdr there
desk [session]  # herdr --remote mini — client stays on the MacBook
```

Two mutually exclusive shapes. **Persistence is identical either way** — the
herdr server and its panes live on the mini regardless. This is purely a
client-experience choice.

```bash
mosh mini            # then run `herdr` there. Client runs ON THE MINI. `dev` expands to this.
herdr --remote mini  # herdr's native attach over ssh. Client runs LOCALLY. `desk` expands to this.
```

| | transport | client on | roaming |
|-|-|-|-|
| `dev` (`mosh mini` → `herdr`) | mosh/UDP | mini | survives lid-close with **no reattach** |
| `desk` (`herdr --remote mini`) | ssh/TCP | MacBook | connection ends; re-run to reattach |

`dev` pins `--experimental-remote-ip=remote` — load-bearing, not cosmetic. mosh's
default proxy mode passes `-S none` to ssh (disabling multiplexing), so every
launch opened a fresh connection and popped its own 1Password biometric
approval — exactly the friction the `ControlMaster` block in `ssh_config`
exists to remove. `remote` mode reuses the master.

**`--remote` at the desk, mosh on the road.** mosh does not forward the SSH
agent (upstream refuses it), nor port forwarding, OSC 52 clipboard, or
sixel/kitty graphics — and its predictive echo only engages on a laggy link, so
over a LAN-latency tailnet hop it buys nothing ssh wasn't already doing. Its
value is specific and real: a bad link, and roaming without reattaching.

`herdr attach` is **not a command** — the real forms are `herdr session attach <name>`
and `herdr agent attach <target>`.

mosh needs the ACL's `udp:60000-61000` grant. Without it the ssh handshake
succeeds and the session then hangs forever — it reads as a broken mosh, not a
blocked port.

## herdr day to day

```bash
herdr                          # launch or attach the persistent session
herdr --session <name>         # named session
herdr session list|attach|stop
herdr status                   # client + server state
```

Server lifecycle is **brew services**, not `herdr server stop` — it runs with
`KeepAlive`, so a bare stop just gets relaunched (same as colima):

```bash
brew services restart herdr
```

### The socket API is the agent-facing door

Every pane is scriptable without attaching a TUI, which is what makes herdr
usable *from* an agent rather than only by a human:

```bash
herdr workspace list|create|focus|close
herdr pane list|current|zoom
herdr agent list                             # per-agent status
herdr agent read <target> [--source visible|recent|recent-unwrapped|detection]  # default: recent
herdr agent prompt <target> "<text>" [--wait]
herdr agent wait <target> --until <status>   # idle|working|blocked|done|unknown
herdr agent start <name> --kind claude --pane <id>
```

`herdr workspace create` works with **zero clients attached** — the server is
genuinely headless.

### Agent status needs the integration hook

`make herdr-setup` installs herdr's first-party Claude Code integration. Without
it every pane reports `agent_status: "unknown"`, which throws away the one thing
herdr has over tmux. It is safe on any machine — the hook exits 0 immediately
unless `HERDR_ENV` / `HERDR_SOCKET_PATH` / `HERDR_PANE_ID` are set.

`make herdr-setup` is opt-in and **not** part of the `setup` chain. It has not been
run on the MacBook, which has the guarded settings entry but no
`~/.claude/hooks/herdr-agent-state.sh` — that is exactly what the `test -f` guard
below covers. Run it there too if you want pane status from a MacBook-side client.

The settings entry is tracked in `dotfiles/config/settings.template.json`,
because `make setup` merges settings.json with the **template winning on
`hooks`** — an entry added only by `herdr integration install claude` gets
deleted on the next `make setup`. If pane status ever goes back to `unknown`,
that is the first thing to check.

## Durable agents — `claude --bg`

```bash
rd bg <repo> '<task>'        # the supported way — see the keychain trap below
claude agents --json         # list; check `kind` — interactive vs background. The bare form needs a TTY
claude attach|logs|stop <id>
```

`--bg` reparents to PID 1 as `claude daemon run`, so it survives ssh death,
herdr death and lid-close **independently of every layer above**.

### It survives independently; it cannot be *launched* independently

`--bg` is freestanding once running, which is not the same as freestanding at
spawn time — and the difference fails silently.

> **Never `ssh mini 'claude --bg …'` directly.** Claude Code's Max credentials
> live in the **login keychain**, which an ssh session cannot reach. The daemon
> starts anyway, prints `Not logged in · Please run /login`, falls back to
> **API Usage Billing**, and still looks healthy in `claude agents`. You get a
> running agent that is off Max and doing nothing.

The herdr server is a brew service under launchd **inside the user's GUI
session**, so anything it spawns inherits keychain access. `rd bg` therefore
launches through a throwaway herdr pane and closes it once the daemon exists.
Verified both directions 2026-07-27: identical command, `Not logged in` over
ssh, `Claude Max` through a pane.

The same reasoning covers anything else on the mini that needs the login
keychain — a LaunchAgent, a cron line, a daemon started from a script. Being on
the tailnet is not the same as being in the GUI session.

**This matters more than it looks.** A `kill -9` of the herdr server brings the
workspace back by name but with a new `terminal_id` — the layout is restored and
every process inside it is gone. herdr is pre-1.0. So:

> Anything that must not die goes in `claude --bg`, not in a herdr pane.

An interactive session is exactly the kind that dies with its connection. If the
user says "my agent should keep running", check `claude agents --json` for
`kind: interactive` before assuming it will.

## Reaching a dev server on the mini

A dev server bound to `127.0.0.1:PORT` on the mini is reachable from any Mac on
the tailnet as `https://<mini-magicdns>:PORT`, with a real cert.

```bash
# on the mini
vim ~/.config/caddy-tailnet.ports   # PORT [label], one per line
make caddy-tailnet                  # regenerate + reload, prints the URLs
```

Do **not** use `tailscale serve` for dev servers — issue #18827 drops WebSockets
every 10-40s, which is HMR breaking on a timer. `serve` stays right for the
always-on rows (`:7730` rb, `:8443` IU dashboard Funnel).

Three failure modes, all silent:

| Symptom | Cause |
|-|-|
| Connection **times out**, nothing in any log | The Tailscale ACL has no grant for that port. `tag:mac → tag:mac` covers `tcp:22`, `tcp:5900`, `tcp:7700-7799`, `udp:60000-61000` — anything else needs adding, exactly as rb's `:7730` did |
| Caddy won't start, or the dev server can't bind its port | The generated block is missing `bind <tailnet-ip>`, so Caddy took `0.0.0.0:PORT` and collided with the dev server on `127.0.0.1:PORT` |
| **403** from the app itself | Vite 5.4.12+ DNS-rebinding guard. Add the MagicDNS host to `server.allowedHosts` (rb does a `.ts.net` suffix match) |

Changing the ACL needs a **present human**, not a second machine: `tailscale-acl-push`
needs the Tailscale API key, which is `op://Private/*` and refused by the mini's cache
by design — the blocker is purely biometric. The repo (`dotfiles-private`) lives on
the MacBook already, so edit and push there; a mini-side edit can be pulled over
`ssh iumac` first if needed.

## The reverse leg: mini → iumac

Access used to be one-way (MacBook → mini only). Since 2026-08-06 the mini can
also reach back: `ssh iumac` / `rsync … iumac:…`, over a dedicated
`~/.ssh/id_ed25519_iumac` key (`restrict,pty`, no agent forwarding, never enters
1Password or the secrets cache). It is for file/state pulls off the MacBook —
`usage-tracker` stats, syncing `brain`/`dotfiles` — not for anything needing
`op://Private/*`: `op` over `ssh iumac` fails **fast** ("account is not signed
in", exit 1), it does not hang, so the biometric gate holds. `make
remote-dev-doctor` checks this leg (layer 5, mini-only). Full model:
`dotfiles/docs/remote-dev.md` §10.

## Moving files between the Macs

`~/Shuttle` on the mini, reached from the MacBook as a mounted SMB share
(`smb://mini/jkrumm`, `tcp:445` granted `tag:mac → tag:mac`). Recommend it over
one-off `scp`/`rsync` invocations for **ad-hoc human file movement** — an export,
a screenshot, an installer. Route everything else the way it already goes:

| Moving | Route |
|-|-|
| A one-off file between the Macs | the **Shuttle** mount |
| Code / a repo | `rd`, or git |
| Vault pages | brain-sync through GitHub |
| Anything a mini-side agent or LaunchAgent reads | onto the **mini** — the mount is client-side and dies with the MacBook |

**No offline copy** — but the table above is not an uptime argument. Repos need
history, the vault is edited on both machines, and the mount is client-side; all
three hold however reliable the mini is (and it is — days-to-weeks of uptime is
normal). The end that actually goes away is the **MacBook**: corp network,
travel, a Tailscale hiccup. A stale mount then hangs Finder rather than failing
cleanly, so a file you need while disconnected does not belong here.

If a mount fails: check `SMB-NT` before suspecting the tailnet. macOS mints no
NTLM credential for a local account until the user is ticked in System Settings →
Sharing → File Sharing ⓘ → Options, and without it `smbd` refuses everything
**including on its own loopback**, so a loopback failure settles it as a server
problem, not a network one. The deterministic check, run on the server:

```bash
sudo plutil -extract ShadowHashData.0 raw -o - \
  /var/db/dslocal/nodes/Default/users/<user>.plist | base64 -D | plutil -p - | grep SMB-NT
```

No match → the account was never enabled, and no amount of ACL work will fix it.
Full model: `dotfiles/CLAUDE.md` → *File shuttle*.

## human-queue — the present-human channel

SSH gave the mini reach into the MacBook; it did not give it a fingerprint. For
work that genuinely needs a present human — biometric `op` (`make
secrets-seed`), the Tailscale ACL push, any judgment call — an agent on the mini
enqueues instead of blocking or editing a handover doc nobody may read for days:

```bash
ask-human.sh ask "<text>" [--cmd <command>] [--wait [seconds]]   # on the mini
make human-queue          # list pending requests, on the MacBook
make human-queue-count    # just the count, on the MacBook
```

Draining (`human-queue.sh run <id>`) happens only on the MacBook and requires a
typed `yes` on a real TTY — there is no non-interactive path to it, so a
compromised or misbehaving mini can only ever put a string in front of a human,
never execute one. `--wait` polls for the result and exits 0/1/2/3 for
done/denied/failed/timeout. Full model: `dotfiles/docs/remote-dev.md` §9.

## Monitoring

One composite heartbeat (herdr + sshd + tailscaled + mosh) pushes to the
`MacMini Dev Host - Push` Uptime Kuma monitor every 5 minutes.

```bash
make devhost-health-check      # run once, prints per-component status
make devhost-health-setup      # install the LaunchAgent (mini only)
tail ~/Library/Logs/devhost-health.log
```

Push, not probe: the ACL grants `tag:homelab → tag:vps` but **not**
`tag:homelab → tag:mac`, so Uptime Kuma cannot reach the mini at all. The mini
reports on itself over the already-granted outbound path.

**`make remote-dev-doctor`** (`scripts/remote-dev-doctor.sh`) is the MacBook-side
counterpart — it verifies the path FROM the MacBook, which the mini-side
heartbeat structurally cannot: the mini has no key for itself and cannot ssh to
itself, so it can't see inbound auth, `ControlMaster` reuse, agent forwarding,
or the mosh UDP path. Read-only, currently 10/10 passing: tailscale reachability
(direct vs DERP), ssh, ControlMaster, agent forwarding, mosh installed locally,
`mosh-server` on the mini's non-interactive PATH, `mosh-server` in the mini's
Application Firewall allowlist, herdr server running, the agent-state hook
present, and a resolvable GitHub credential.

## Failure modes specific to this host

| Symptom | Cause |
|-|-|
| `mosh mini` hangs after a clean ssh handshake | ACL missing `udp:60000-61000`. Verified present 2026-07-26 — check the Application Firewall row below first, it presents identically |
| `herdr --remote mini` asks "restart the remote server now? [y/N]", warning it "may not survive SSH connection loss" | **Answer `N`.** False positive for this host: the server is the brew service, PID owned by launchd (PPID 1), so no ssh disconnect can reach it — verified continuously up across a whole session of opening and closing connections. Answering `y` restarts it outside `brew services` supervision *and* kills every process in every pane |
| mosh prints `Error: vector` and exits | The client's terminal has no window size (a 0×0 pty). Real terminals are fine; this bites scripted/automated launches — set `TIOCSWINSZ` before exec |
| Doubled keystrokes over ssh | `TERM=xterm-ghostty` reaching a host without that terminfo (cmux #2969). `ssh_config` pins `SetEnv TERM=xterm-256color` |
| `launchctl print … sshd` says `state = not running` | socket-activation idle, **not** a fault. Check `netstat -an \| grep '\.22 .*LISTEN'` |
| `ssh localhost` fails on the mini | By design — the mini has no key for itself (its one private key, `id_ed25519_iumac`, is outbound-only for `iumac`). Inbound auth is the *connecting* machine's key, so the mini **cannot test its own inbound ssh**. Verify from the MacBook |
| A direct `op read` / `op run` hangs on the mini | No biometric prompt to answer. Use `secrets-run`. `op whoami` fails fast, so preflight guards are safe |
| `op signin` "worked" but the next command says not signed in | The session lives in the shell that ran it. Chain them: `op signin --account tkrumm && <cmd>` |
| Agent died when the lid closed | It was `kind: interactive`. Use `rd bg` |
| A `--bg` agent runs but does nothing; `claude logs` shows `Not logged in · Please run /login` and the banner says *API Usage Billing* instead of *Claude Max* | It was spawned over ssh, which cannot reach the login keychain. Spawn through a herdr pane — that is exactly what `rd bg` does. Never `ssh mini 'claude --bg …'` |
| `rd` says "herdr server is not running" | `brew services restart herdr` on the mini; `make remote-dev-doctor` to confirm the rest of the path |
| Workspace came back but the work is gone | herdr server restarted — layout persists, processes do not |
| `claude: command not found` over non-interactive ssh to the mini | **Fixed** — `make setup`'s `_setup-zshenv` block now puts both Homebrew and `~/.local/bin` on the non-interactive PATH. If it recurs, that block is missing: re-run `make setup` on the mini |
| mosh connects over ssh then hangs / "did not make a successful connection to \<ip\>:\<port\>" | `mosh-server` missing from the mini's Application Firewall allowlist. Fix: `make mosh-firewall`. Re-run after `brew upgrade mosh` |
| `git push` on the mini fails with `could not read Username for 'https://github.com'` | The credential helper returned nothing. Fix: `make git-headless`, and reseed with `make secrets-seed` if the cache is stale. The helper exits 0 with an empty body when the token is unresolvable, which is why the failure looks like a transport fault |
| Any remote-dev symptom you can't immediately place | Run `make remote-dev-doctor` first — it names the failing layer instead of guessing |

## Rules

- Manage the herdr server with `brew services`, never a bare `herdr server stop`.
- **Never run `herdr update`.** It downloads and installs over the
  brew-managed binary, so the version stops matching the Brewfile — the repo's
  supply-chain audit trail — and `make brew-check` starts reporting drift.
  Upgrade with `brew upgrade herdr`, deliberately, one package at a time.
  herdr is pre-1.0 and ships often; that cadence is a reason to gate upgrades
  through the manifest, not to bypass it.
- Never run a validation loop or an edit over files a running `@implementer`
  subagent owns — that applies here too, across panes.
- Do not add `tailscale serve` bindings for dev servers; use Caddy. Tailscale
  issue #18827 drops WebSockets through serve/funnel every 10-40s, which is HMR
  breaking on a timer.
- The `:8443` Funnel row is the IU dashboard, public **by design**, gated by
  `tag:iu-dashboard-funnel` — an additive single-device tag that keeps Funnel
  capability off the work MacBook. Do not "clean it up".

Full model and rationale: `dotfiles/docs/remote-dev.md`.
Access/auth model: `dotfiles-private/docs/access-model.md`.
