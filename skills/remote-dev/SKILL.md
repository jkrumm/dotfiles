---
name: remote-dev
description: Operate the Mac mini remote dev host — connecting from the MacBook over herdr --remote, running, waiting on and closing Claude Code / OpenCode agents (`rd wave`, wave tabs, orchestrated waves), herdr workspaces/panes and its socket API, the Uptime Kuma readiness heartbeat, and the failure modes specific to a headless always-on Mac. Use when the user mentions herdr, the mini, "remote dev", "dev host", detaching or reattaching agents, "did my agent survive", sessions dying on lid-close, or asks how to reach a dev server running on the mini.
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
repos [filter]                    # what's on the dev host, with branch + dirty count
work <repo> [--kind opencode]     # herdr workspace + claude for that repo (idempotent)
rd wave <repo> [--kind opencode] '<prompt>'   # a fresh `wave <n>` tab, solo agent, prompted
rd close <agent>                  # close a finished wave tab (clean + pushed only)
agents                            # every agent on the host
rd read <agent>                   # read its output without attaching
rd say <agent> "…"                # send it a prompt
```

`--kind opencode` starts OpenCode on the IU endpoint (default model `iu/…` from
`oc`; `RD_WAVE_MODEL` overrides) instead of Claude Code (`sonnet`).

Four lanes start agent work: `@implementer`, `agw dispatch`, `rd wave`
(a tab you watch), `warden run` (unattended, tracked). `agent-dispatch` and
`rd bg` no longer exist, and `claude --bg` is not a lane.

### Wave tabs and the orchestrator

`/wave` owns the contract (chain vs orchestrated mode, the green gate). The
mechanics this skill owns: `rd wave` adds a tab labelled `wave <n>` to the repo's
workspace and prints the agent name (`<repo>-w<n>`). Waiting on it:

```bash
herdr agent wait <agent> --until working --timeout 60000   # prompt landed
herdr agent wait <agent> --until idle --until done --until blocked
```

**Wait on all three settled states, never `--until done` alone.** `done` is idle
*plus* unseen — if you are looking at the wave's tab it reports `idle`, and a
`done`-only wait never returns. `blocked` means an approval/question UI: read
the pane (`rd read`) before answering it.

### Scripting herdr directly (stack rules on top of the `herdr` skill)

The `herdr` skill is the raw CLI reference — syntax, ids, `agent`/`pane`/`tab`
groups. What it does not know about this stack:

- Address agents by **name or pane id** (`wR:pK`), never by focus — the focused
  pane is the owner's. `HERDR_PANE_ID` is your own.
- `herdr agent prompt` and `agent wait` exit 0 on some failures — read the JSON
  body for `"error"`.
- Never close a workspace, tab or pane you did not create. `rd close` enforces it
  for wave tabs.
- Never `herdr server stop` or kill the herdr process: every pane dies with it.
  Server changes are `make herdr-restart YES=1` / `make herdr-upgrade`, human-timed.
- If every pane reports `agent_status: "unknown"`, run `make herdr-setup`
  (installs herdr's Claude Code integration hook; per machine, not in `make setup`).

## Go look at the mini (a terminal)

```bash
desk [session]                 # herdr --remote mini — client here, server+panes there
herdr session list|attach|stop
herdr status                   # client + server state
```

A roam or lid-close ends the ssh/TCP attach only — re-run `desk`, nothing is
lost. `herdr attach` is **not** a command.

## Durable work

Anything that must survive a herdr restart is `warden run <repo> <<'BRIEF'` (brief on stdin; or `--brief-file <path>`), not
a bare pane: a restart restores the layout and resumes Claude panes
(`claude --resume`), but shells, dev servers and loops die and a resumed agent
lost its in-flight turn. **Never `ssh mini 'claude …'`**: the session comes up
logged out of Max and silently bills API credits while still looking healthy —
a pane spawned by herdr (`rd wave`/`rd work`) inherits the keychain.

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
| A file/state pull the other direction | `ssh iumac` / `rsync … iumac:…` from the mini (`usage-tracker` stats, syncing `brain`) — MacBook-side `op` goes through `ask-human ask … --cmd …` (dialog, then Touch ID), never a bare `ssh iumac 'op …'` |

If the SMB mount fails, check `SMB-NT` before suspecting the tailnet — see
`dotfiles/AGENTS.md` → *File shuttle* for the deterministic check.

## human-queue — the present-human channel

```bash
ask-human ask "<text>" [--cmd <command>] [--wait <seconds>] [--no-push]  # on the mini; pushes by default
ask-human push <id>       # trigger the dialog for an already-enqueued request
make human-queue          # walk pending requests (run/deny/skip each), on the MacBook
make human-queue-count    # just the count, on the MacBook
```

Two ways a request reaches a human: the mini pushes it right away (the default
— `ssh iumac` runs `human-queue.sh gui-run` there, showing the exact string in
a native dialog that only executes on a click), or, with `--no-push` /
`HUMAN_QUEUE_PUSH=0` or an unreachable MacBook, it queues and the MacBook drains
it with `make human-queue` (typed `yes` on a real TTY). Still no path that skips
a present human. `--wait` polls and exits 0/1/2/3 for done/denied/failed/timeout;
it is ignored when the push resolves synchronously.
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
| Agent died when the lid closed | It did not — the lid ends the ssh/TCP attach only. A herdr *restart* resumes Claude panes and loses shells and the in-flight turn; unattended-critical work is `warden run` |
| An agent runs but does nothing, shows `Not logged in` / API Usage Billing | Spawned over ssh, can't reach the login keychain. Spawn through a herdr pane (`rd wave`/`rd work`) — never `ssh mini 'claude …'` |
| `rd` says "herdr server is not running" | `make herdr-restart YES=1` on the mini (kills every pane — human-timed) |
| Workspace came back but the work is gone | herdr server restarted — layout persists, processes don't |
| `claude: command not found` over non-interactive ssh | `make setup`'s `_setup-zshenv` puts Homebrew + `~/.local/bin` on the non-interactive PATH — re-run `make setup` if missing |
| `ssh mini` fails `signing failed … agent refused` → `Permission denied (publickey)` | 1Password is locked. Unlock it |
| A mini service accepts the connection then never answers, though its own log says it's listening | Application Firewall keys on the binary — `sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add <binary> && … --unblockapp <binary>` |
| `git push` on the mini fails `could not read Username for 'https://github.com'` | Credential helper returned nothing — `make git-headless`, reseed with `make secrets-seed` if stale |
| Anything else | Run `make doctor` first — it names the failing layer instead of guessing |

## Rules

- Manage the herdr server with `make herdr-restart` / `make herdr-upgrade`,
  never a bare `herdr server stop` or `kickstart -k`.
- **Never run `herdr update`** — it breaks the Brewfile's supply-chain audit
  trail. A version bump is `make herdr-upgrade`.
- Never run a validation loop or an edit over files a running `@implementer`
  subagent owns — applies across panes too.
- Do not add `tailscale serve` bindings for dev servers; use Caddy.
- The `:8443` Funnel row is the IU dashboard, public **by design** — don't
  "clean it up".

Full model and rationale: `dotfiles/docs/remote-dev.md`.
Access/auth model: `dotfiles-private/docs/access-model.md`.
