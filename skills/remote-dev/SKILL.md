---
name: remote-dev
description: Operate the Mac mini remote dev host — connecting from the MacBook over herdr --remote, running and reattaching many Claude Code agents, herdr workspaces/panes and its socket API, claude --bg durable daemons, the Uptime Kuma readiness heartbeat, and the failure modes specific to a headless always-on Mac. Use when the user mentions herdr, the mini, "remote dev", "dev host", detaching or reattaching agents, "did my agent survive", sessions dying on lid-close, or asks how to reach a dev server running on the mini.
---

# Remote dev — the mini as dev host

**Orientation first.** The SessionStart hook says which machine you're on:
`Backend: cache` = the mini, `Backend: op` = the MacBook. The model behind every
command below (why three layers, why herdr crashes are survivable, why ssh
can't reach the keychain) lives in `dotfiles/docs/remote-dev.md` and
`dotfiles/AGENTS.md` §Machines & remote dev — this file is the command
reference and the troubleshooting table, not the rationale.

## Put work on the mini (no terminal)

Most days this is the only thing you need. Commands take a repo **name**, never
a path:

```bash
repos [filter]         # what's on the dev host, with branch + dirty count
work <repo>            # herdr workspace + claude for that repo (idempotent)
rd bg <repo> <task…>   # durable claude --bg daemon, survives everything
agents                 # every agent on the host, both lanes, deduped
rd read <agent>        # read its output without attaching
rd say <agent> "…"     # send it a prompt
```

`agent-dispatch bg <repo> '<task>'` / `agent-dispatch work <repo>` is the
one-command router on top of `rd` — use it when you don't already know which
machine the repo lives on (it resolves mini-resident vs MacBook-resident and
picks `rd bg`/`rd work` or a local `claude -p`). It refuses to nest inside an
interactive Claude Code session (`CLAUDECODE` set) — use `rd`/`work` directly
there instead.

## Go look at the mini (a terminal)

```bash
desk [session]                 # herdr --remote mini — client here, server+panes there
herdr session list|attach|stop
herdr status                   # client + server state
```

A roam or lid-close ends the ssh/TCP attach only — re-run `desk`, nothing is
lost. `herdr attach` is **not** a command.

Server lifecycle is `brew services`, never `herdr server stop` (KeepAlive just
relaunches it):

```bash
brew services restart herdr
```

### Scripting a pane directly (the agent-facing door)

```bash
herdr workspace list|create|focus|close
herdr pane list|current|zoom
herdr agent list
herdr agent read <target> [--source visible|recent|recent-unwrapped|detection]
herdr agent prompt <target> "<text>" [--wait]
herdr agent wait <target> --until <status>   # idle|working|blocked|done|unknown
herdr agent start <name> --kind claude --pane <id>
```

If every pane reports `agent_status: "unknown"`, run `make herdr-setup`
(installs herdr's Claude Code integration hook; opt-in, not part of `make
setup`, needs running on each client machine separately).

## Durable agents — `claude --bg`

```bash
rd bg <repo> '<task>'        # the supported way to launch one
claude agents --json         # list; check `kind`: interactive vs background
claude attach|logs|stop <id>
```

**Never `ssh mini 'claude --bg …'` directly** — spawn through `rd bg` (which
goes via a herdr pane) instead, or the daemon comes up logged out of Max and
silently bills API credits while still looking healthy. Anything that must
survive a herdr crash (which restores the layout but kills every process in it)
belongs in `claude --bg`, never a bare pane.

## Reaching a dev server on the mini

```bash
# on the mini
vim ~/.config/caddy-tailnet.ports   # PORT [label], one per line
make caddy-tailnet                  # regenerate + reload, prints the URLs
```

Never `tailscale serve` for a dev server (issue #18827 drops WebSockets every
10-40s — HMR breaking on a timer); `serve` is right only for the always-on rows
(`:7730` rb, `:8443` Funnel).

| Symptom | Cause |
|-|-|
| Connection times out, nothing in any log | No ACL grant for that port — add one (`dotfiles-private`, needs a present human) |
| Caddy won't start / dev server can't bind | Generated block missing `bind <tailnet-ip>`, collided with the dev server on `127.0.0.1:PORT` |
| **403** from the app itself | Vite 5.4.12+ DNS-rebinding guard — add the MagicDNS host to `server.allowedHosts` |

## Moving things between the Macs

| Moving | Route |
|-|-|
| A one-off file, human-driven | `~/Shuttle` SMB mount (`smb://mini/jkrumm`) |
| Code / a repo | `rd`, or git |
| Vault pages | brain-sync through GitHub |
| Anything a mini-side agent/LaunchAgent reads | put it **on the mini** — the SMB mount is client-side and dies with the MacBook |
| A file/state pull the other direction | `ssh iumac` / `rsync … iumac:…` from the mini (`usage-tracker` stats, syncing `brain`) — MacBook-side `op` goes through `ask-human.sh … --push` (dialog, then Touch ID), never a bare `ssh iumac 'op …'` |

If the SMB mount fails, check `SMB-NT` before suspecting the tailnet — see
`dotfiles/AGENTS.md` → *File shuttle* for the deterministic check.

## human-queue — the present-human channel

```bash
ask-human.sh ask "<text>" [--cmd <command>] [--wait <seconds>] [--push]  # on the mini
ask-human.sh push <id>    # trigger the dialog for an already-enqueued request
make human-queue          # walk pending requests (run/deny/skip each), on the MacBook
make human-queue-count    # just the count, on the MacBook
```

Two ways a request reaches a human: the MacBook drains on its own schedule
(`make human-queue`, typed `yes` on a real TTY, no non-interactive path), or
the mini triggers it right away with `--push` — `ssh iumac` runs
`human-queue.sh gui-run` there, showing the exact string in a native dialog
that only executes on a click. Still no path that skips a present human;
`--push` just moves *when* they see it. `--wait` polls and exits 0/1/2/3 for
done/denied/failed/timeout; default 0 (return at once, median resolution ~7
days) — `--push` takes precedence over `--wait` and resolves synchronously.
Full model: `dotfiles/docs/remote-dev.md` → *human-queue*.

## Monitoring and the maintenance round

```bash
make devhost-health-check      # run once, prints per-component status
make devhost-health-setup      # install the LaunchAgent (mini only)
tail ~/Library/Logs/devhost-health.log
make doctor                    # read-only; self-routes mini vs MacBook
```

When something is red, in order:

1. **Unlock 1Password first** — its agent signs `ssh mini`; a lock reads as a
   transport fault (`Permission denied (publickey)`) and isn't one.
2. `make doctor` — read it before changing anything.
3. On the mini, detached: `make brew-upgrade` (detached because it restarts
   tailscaled, the transport the ssh session rides on).
4. `make mini-macos-update` from the MacBook, if one is pending — never force a
   reboot mid-prepare.
5. One attended applier per remaining drift row: `make collie-upgrade` (needs a
   TTY), a reviewed `XCADDY_VERSION` bump + `make caddy-dns-build`,
   `make secrets-seed` from the MacBook.
6. `make doctor` again.

## Failure modes specific to this host

| Symptom | Cause |
|-|-|
| `herdr --remote mini` asks to restart the remote server, warning about SSH loss | **Answer `N`.** False positive — the server is the brew service (PPID 1), no ssh disconnect reaches it. `y` restarts it outside supervision *and* kills every pane |
| `launchctl print … sshd` says `state = not running` | Socket-activation idle, not a fault. Check `netstat -an \| grep '\.22 .*LISTEN'` |
| `ssh localhost` fails on the mini | By design — the mini has no key for itself. Verify inbound auth from the MacBook |
| A direct `op read`/`op run` hangs on the mini | No biometric prompt to answer. Use `secrets-run` |
| `op signin` "worked" but the next command says not signed in | Session lives in the shell that ran it — chain them |
| Agent died when the lid closed | It was `kind: interactive`. Use `rd bg` |
| `--bg` agent runs but does nothing, `claude logs` shows `Not logged in` / API Usage Billing | Spawned over ssh, can't reach the login keychain. Spawn through a herdr pane (`rd bg`) — never `ssh mini 'claude --bg …'` |
| `rd` says "herdr server is not running" | `brew services restart herdr` on the mini |
| Workspace came back but the work is gone | herdr server restarted — layout persists, processes don't |
| `claude: command not found` over non-interactive ssh | `make setup`'s `_setup-zshenv` puts Homebrew + `~/.local/bin` on the non-interactive PATH — re-run `make setup` if missing |
| `ssh mini` fails `signing failed … agent refused` → `Permission denied (publickey)` | 1Password is locked. Unlock it |
| A mini service accepts the connection then never answers, though its own log says it's listening | Application Firewall keys on the binary — `sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add <binary> && … --unblockapp <binary>` |
| `git push` on the mini fails `could not read Username for 'https://github.com'` | Credential helper returned nothing — `make git-headless`, reseed with `make secrets-seed` if stale |
| Anything else | Run `make doctor` first — it names the failing layer instead of guessing |

## Rules

- Manage the herdr server with `brew services`, never a bare `herdr server stop`.
- **Never run `herdr update`** — it breaks the Brewfile's supply-chain audit
  trail. Upgrade with `brew upgrade herdr`, deliberately.
- Never run a validation loop or an edit over files a running `@implementer`
  subagent owns — applies across panes too.
- Do not add `tailscale serve` bindings for dev servers; use Caddy.
- The `:8443` Funnel row is the IU dashboard, public **by design** — don't
  "clean it up".

Full model and rationale: `dotfiles/docs/remote-dev.md`.
Access/auth model: `dotfiles-private/docs/access-model.md`.
