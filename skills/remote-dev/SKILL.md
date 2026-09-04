---
name: remote-dev
description: Operate the Mac mini remote dev host — connecting from the MacBook over herdr --remote, running and reattaching many Claude Code agents, herdr workspaces/panes and its socket API, claude --bg durable daemons, the Uptime Kuma readiness heartbeat, and the failure modes specific to a headless always-on Mac. Use when the user mentions herdr, the mini, "remote dev", "dev host", detaching or reattaching agents, "did my agent survive", sessions dying on lid-close, or asks how to reach a dev server running on the mini.
---

# Remote dev — the mini as dev host

The Mac mini is the always-on dev host; the MacBook is a thin client. Agents run
on the mini and outlive the MacBook.

**Orientation first.** Almost every mistake here comes from not knowing which
machine you are on. The SessionStart hook says: `Backend: cache` = the mini,
`Backend: op` = the MacBook.

## Three layers — never collapse them

| Layer | Tool | Solves | Cannot solve |
|-|-|-|-|
| Reachability + transport | Tailscale + ssh | stable address, NAT traversal, encrypted transport | persistence |
| Persistence + UI | herdr (on the mini) | panes stay alive, per-pane agent state | anything about the network |
| Service exposure | Caddy | dev servers with real HTTPS + working WebSockets | anything about terminals |

Plus one thing that rides on top of all three and depends on none of them:
`claude --bg`.

## Two different questions

Keep these apart — collapsing them is what makes this stack feel complicated:

| Question | Answer |
|-|-|
| How do I *go look* at the mini? | `desk` — herdr's remote attach |
| How do I *put work on* the mini and check on it? | `rd` / `agent-dispatch` — no terminal needed at all |

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

`agent-dispatch bg <repo> '<task>'` / `agent-dispatch work <repo>` is the
one-command router on top of `rd`: for a mini-resident repo it *is* `rd bg` /
`rd work`; for a MacBook-resident repo (`dotfiles`, `dotfiles-private`, `brain`,
`photo-flow`, `shutterflow`) it runs a local `claude -p` against the IU Keychain
creds instead, since that repo has no counterpart on the mini. It refuses to
nest inside an interactive Claude Code session — use `rd`/`work` directly there.
Reach for `agent-dispatch` when you don't already know which machine a repo
lives on; reach for `rd` directly once you do.

## Connecting from the MacBook

The way in is one shell function (`config/zsh/remote-dev.zsh`):

```bash
desk [session]  # herdr --remote mini — client stays on the MacBook, over ssh
```

Persistence lives entirely on the mini — the herdr server and its panes survive
regardless of the client. A roam or lid-close ends the ssh/TCP attach; re-run
`desk` to reattach, nothing is lost.

`herdr attach` is **not a command** — the real forms are `herdr session attach <name>`
and `herdr agent attach <target>`.

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
| Connection **times out**, nothing in any log | The Tailscale ACL has no grant for that port. `tag:mac → tag:mac` covers `tcp:22`, `tcp:5900`, `tcp:7700-7799` — anything else needs adding, exactly as rb's `:7730` did |
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
in", exit 1), it does not hang, so the biometric gate holds. `make doctor`
checks this leg from the MacBook. Full model: `dotfiles/docs/remote-dev.md` §10.

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

One composite heartbeat (herdr + sshd + tailscaled) pushes to the
`MacMini Dev Host - Push` Uptime Kuma monitor every 5 minutes.

```bash
make devhost-health-check      # run once, prints per-component status
make devhost-health-setup      # install the LaunchAgent (mini only)
tail ~/Library/Logs/devhost-health.log
```

Push, not probe: the ACL grants `tag:homelab → tag:vps` but **not**
`tag:homelab → tag:mac`, so Uptime Kuma cannot reach the mini at all. The mini
reports on itself over the already-granted outbound path.

**`make doctor`** is the read-only counterpart, and it self-routes: run on the
mini it reports the local half; run on the MacBook it verifies the path FROM
the MacBook first (the mini-side heartbeat structurally cannot — the mini has
no key for itself and cannot ssh to itself, so it can't see inbound auth,
`ControlMaster` reuse, agent forwarding, or the herdr `--remote` path), then
ssh's into the mini and runs the mini's own doctor there — one composite report
covering both machines with a single command.

### The maintenance round

`make doctor` is the whole picture in one read-only command — reachability,
herdr, sshd, and (from the MacBook) the mini's own health in one report.

Order, when something is red:

1. **Unlock 1Password first.** Its agent signs `ssh mini`, so a lock takes the
   entire host away and presents as `signing failed … agent refused operation`
   → `Permission denied (publickey)`. That reads like a transport fault and is
   not one. A short auto-lock makes every mini action need a touch.
2. `make doctor` — read it before changing anything.
3. On the mini, **detached**: `make brew-upgrade`. It asserts its four
   invariants (caddy's DNS module, colima's repaired KeepAlive, herdr's
   session-leader boot path, and its other pinned invariants). Detached because
   upgrading the `tailscale` formula restarts tailscaled — the transport the ssh
   session is riding.
4. `make mini-macos-update` from the MacBook, if one is pending. `Restarting...`
   is a *request*, not an event: the prepare runs for minutes afterwards and the
   machine reboots itself. **Never force a reboot there** — it aborts the prepare
   and boots the old OS with every artifact still looking armed.
5. One attended applier per remaining drift row — `make collie-upgrade` (needs a
   TTY; without one it prints changelog + diffstat + scope verdict and refuses,
   which is the review), a reviewed `XCADDY_VERSION` bump + `make
   caddy-dns-build`, `make secrets-seed` from the MacBook.
6. `make doctor` again.

A reseal aborts on any ref whose 1Password item was deleted — it now names
**every** dead ref in one pass, so fix or comment them out and re-run rather
than paying a Touch ID per ref.

## Failure modes specific to this host

| Symptom | Cause |
|-|-|
| `herdr --remote mini` asks "restart the remote server now? [y/N]", warning it "may not survive SSH connection loss" | **Answer `N`.** False positive for this host: the server is the brew service, PID owned by launchd (PPID 1), so no ssh disconnect can reach it — verified continuously up across a whole session of opening and closing connections. Answering `y` restarts it outside `brew services` supervision *and* kills every process in every pane |
| `launchctl print … sshd` says `state = not running` | socket-activation idle, **not** a fault. Check `netstat -an \| grep '\.22 .*LISTEN'` |
| `ssh localhost` fails on the mini | By design — the mini has no key for itself (its one private key, `id_ed25519_iumac`, is outbound-only for `iumac`). Inbound auth is the *connecting* machine's key, so the mini **cannot test its own inbound ssh**. Verify from the MacBook |
| A direct `op read` / `op run` hangs on the mini | No biometric prompt to answer. Use `secrets-run`. `op whoami` fails fast, so preflight guards are safe |
| `op signin` "worked" but the next command says not signed in | The session lives in the shell that ran it. Chain them: `op signin --account tkrumm && <cmd>` |
| Agent died when the lid closed | It was `kind: interactive`. Use `rd bg` |
| A `--bg` agent runs but does nothing; `claude logs` shows `Not logged in · Please run /login` and the banner says *API Usage Billing* instead of *Claude Max* | It was spawned over ssh, which cannot reach the login keychain. Spawn through a herdr pane — that is exactly what `rd bg` does. Never `ssh mini 'claude --bg …'` |
| `rd` says "herdr server is not running" | `brew services restart herdr` on the mini; `make doctor` to confirm the rest of the path |
| Workspace came back but the work is gone | herdr server restarted — layout persists, processes do not |
| `claude: command not found` over non-interactive ssh to the mini | **Fixed** — `make setup`'s `_setup-zshenv` block now puts both Homebrew and `~/.local/bin` on the non-interactive PATH. If it recurs, that block is missing: re-run `make setup` on the mini |
| `ssh mini` fails `signing failed … agent refused operation` → `Permission denied (publickey)` | **1Password is locked**, not a transport fault — its agent holds the key. Unlock it |
| A service on the mini **accepts the connection and then never answers** — curl prints `Connected` and times out on *every* path, while the app's own log says it is listening | **Application Firewall**, not the app. ALF completes the handshake in the kernel and never hands the socket to a non-allowed binary, so it does not look like a refusal. It keys on the BINARY: replacing it drops the grant, and a running process keeps its old one until it restarts — which is why this can surface at a reboot days later. Diagnosed by serving `http.server` off the same address with an allow-listed python (200 in 24 ms) and the app's own (hung). Fix: `sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add <binary> && … --unblockapp <binary>` |
| `git push` on the mini fails with `could not read Username for 'https://github.com'` | The credential helper returned nothing. Fix: `make git-headless`, and reseed with `make secrets-seed` if the cache is stale. The helper exits 0 with an empty body when the token is unresolvable, which is why the failure looks like a transport fault |
| Any remote-dev symptom you can't immediately place | Run `make doctor` first — it names the failing layer instead of guessing |

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
