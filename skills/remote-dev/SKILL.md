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

## Connecting from the MacBook

Two mutually exclusive shapes. **Persistence is identical either way** — the
herdr server and its panes live on the mini regardless. This is purely a
client-experience choice.

```bash
mosh mini            # then run `herdr` there. Client runs ON THE MINI.
herdr --remote mini  # herdr's native attach over ssh. Client runs LOCALLY.
```

| | transport | client on | roaming |
|-|-|-|-|
| `mosh mini` → `herdr` | mosh/UDP | mini | survives lid-close with **no reattach** |
| `herdr --remote mini` | ssh/TCP | MacBook | connection ends; re-run to reattach |

Pick mosh for a bad link, `--remote` for local keybindings and local image
paste. `herdr attach` is **not a command**.

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
herdr agent list                       # per-agent status
herdr agent read <id>                  # read an agent's terminal output
herdr agent prompt <id> "<text>"       # submit a prompt
herdr agent wait <id> --state <state>  # block until it reaches a state
```

`herdr workspace create` works with **zero clients attached** — the server is
genuinely headless.

## Durable agents — `claude --bg`

```bash
claude --bg '<task>'        # positional prompt; CONFLICTS with -p
claude agents               # list; check `kind` — interactive vs background
claude attach|logs|stop <id>
```

`--bg` reparents to PID 1 as `claude daemon run`, so it survives ssh death,
herdr death and lid-close **independently of every layer above**.

**This matters more than it looks.** A `kill -9` of the herdr server brings the
workspace back by name but with a new `terminal_id` — the layout is restored and
every process inside it is gone. herdr is pre-1.0. So:

> Anything that must not die goes in `claude --bg`, not in a herdr pane.

An interactive session is exactly the kind that dies with its connection. If the
user says "my agent should keep running", check `claude agents` for `kind:
interactive` before assuming it will.

## Monitoring

One composite heartbeat (herdr + sshd + tailscaled + mosh) pushes to the
`MacMini Dev Host - Push` Uptime Kuma monitor every 5 minutes.

```bash
make devhost-health-check      # run once, prints per-component status
make devhost-health-setup      # install the LaunchAgent (mini only)
tail /tmp/devhost-health.log
```

Push, not probe: the ACL grants `tag:homelab → tag:vps` but **not**
`tag:homelab → tag:mac`, so Uptime Kuma cannot reach the mini at all. The mini
reports on itself over the already-granted outbound path.

## Failure modes specific to this host

| Symptom | Cause |
|-|-|
| `mosh mini` hangs after a clean ssh handshake | ACL missing `udp:60000-61000` |
| Doubled keystrokes over ssh | `TERM=xterm-ghostty` reaching a host without that terminfo (cmux #2969). `ssh_config` pins `SetEnv TERM=xterm-256color` |
| `launchctl print … sshd` says `state = not running` | socket-activation idle, **not** a fault. Check `netstat -an \| grep '\.22 .*LISTEN'` |
| `ssh localhost` fails on the mini | By design — the mini holds no private key material. Inbound auth is the *connecting* machine's key, so the mini **cannot test its own inbound ssh**. Verify from the MacBook |
| A direct `op read` / `op run` hangs on the mini | No biometric prompt to answer. Use `secrets-run`. `op whoami` fails fast, so preflight guards are safe |
| `op signin` "worked" but the next command says not signed in | The session lives in the shell that ran it. Chain them: `op signin --account tkrumm && <cmd>` |
| Agent died when the lid closed | It was `kind: interactive`. Use `claude --bg` |
| Workspace came back but the work is gone | herdr server restarted — layout persists, processes do not |

## Rules

- Manage the herdr server with `brew services`, never a bare `herdr server stop`.
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
