---
name: remote-dev
description: Operate the Mac mini remote dev host — connecting from the MacBook through the Herdr app (or `ssh -t mini hc`), running, waiting on and closing Claude Code agents (`rd wave`, wave tabs, orchestrated waves) in herdr-core terminals, the core under launchd and its resume/reap/events jobs, the Uptime Kuma readiness heartbeat, and the failure modes specific to a headless always-on Mac. Use when the user mentions herdr-core, hc, the Herdr app, the mini, "remote dev", "dev host", detaching or reattaching agents, "did my agent survive", sessions dying on lid-close, or asks how to reach a dev server running on the mini.
---

# Remote dev — the mini as dev host

**Orientation first.** The SessionStart hook says which machine you're on:
`Backend: cache` = the mini, `Backend: op` = the MacBook. The model behind every
command below (why three layers, why a core restart is survivable, why ssh
can't reach the keychain) lives in `dotfiles/docs/remote-dev.md` and
`dotfiles/AGENTS.md` §Machines & remote dev — this file is the command
reference and the troubleshooting table, not the rationale.

## Put work on the mini (no terminal)

Most days this is the only thing you need. Commands take a repo **name**, never
a path:

```bash
repos [filter]                    # what's on the dev host, with branch + dirty count
work <repo>                       # a tab with claude in the repo's space (idempotent)
rd wave <repo> '<prompt>'   # a fresh `wave <n>` tab, solo agent, prompted
rd close <agent>                  # close a finished wave tab (clean + pushed only)
rd fan <repo> <brief…>            # fan-out: worktree (from fetched origin) + hidden Claude child per brief file
rd fan --clean <repo>             # reclaim clean, merged worktrees rd fan made + their terminals (--all: any worktree)
rd merge <repo> [--check cmd] <branch…>   # merge train: rebase, check, merge by rebase (GitHub only)
agents                            # every agent on the host
rd read <agent>                   # read its output without attaching
rd say <agent> "…"                # hc send: refuses a blocked agent, queues for a working one
```

Agents `rd` starts run on the Max subscriptions only (`sonnet` default, `RD_WAVE_MODEL`
overrides). `--kind opencode` is rejected, and with no account room `rd` pauses
instead of spilling to IU.

Two lanes start agent work: `@implementer`, `rd wave` (a tab you watch; `rd fan`
for N independent changes). `agent-dispatch` and
`rd bg` no longer exist, and `claude --bg` is not a lane.

### Wave tabs and the orchestrator

`/wave` owns the contract (chain vs orchestrated mode, the green gate). The
mechanics this skill owns: `rd wave` adds a tab labelled `wave <n>` to the repo's
space and prints the agent name (`<repo>-w<n>`); `<n>` is the plan's wave number from `(Wave <n>)` in the prompt (the live tab counter only when the prompt has none). Prompts are delivery-checked: no `working` within 30 s means one re-send. `rd fan` does the same per brief, as hidden children of the orchestrator. An orchestrator does not poll: `factory session wait --on workers`, end the turn, and the factory's wake note ("workers done: …") starts the next one (`/wave` documents both modes). To look at one agent by hand: `rd read <agent>`, or `hc wait <t>` (returns when it stops working; `--children all|any`
for helpers; `hc wait --help`). A wake can mean `blocked` (an approval/question UI): read it before answering.

### Scripting hc directly (stack rules on top of the `herdr` skill)

The global `herdr` skill is the reference: `hc` run/read/send/wait/labels/machines, placing a terminal in a space and tab, the
API. Read `hc --skill` before a flag. What it does not know about this stack:

- **The account is chosen on the command** (`env CLAUDE_CONFIG_DIR=… claude`, none = `iu`), never inherited: a core's env is
  every terminal's. `rd` and the factory do it for you.
- **launchd owns the core** (`com.jkrumm.herdr-core`). The only restart is `launchctl kickstart -k gui/$(id -u)/com.jkrumm.herdr-core`;
  never `hc update`, `hc server restart|stop` or `hc machine update` on the mini, and never start a core from ssh (no keychain).
- **Never `ssh mini 'claude …'`** (below). Reach a terminal through `rd` or the app.
- **Placement is labels** (`herdr.space`, `herdr.tab`), set by `rd`/the factory; the app adopts them. A worker is an unlabelled child.
- Address agents by name or terminal id, never by what the owner has focused. A non-empty input line in a terminal is the owner's
  unsent draft: never press Enter on it or re-send it through `hc send`; name it in the report, or relay the authorized next step in
  your own words. Pass the owner's brief verbatim when steering.
- After steering an agent in a repo whose files are symlinked live (dotfiles, hermes-agent), restore its branch
  (`git -C <repo> switch master`): the branch *is* the running configuration.
- Never close a terminal, tab or space you did not create. `rd close` enforces it for agents.

## Go look at the mini

Open the Herdr app on the MacBook: it links the mini's core as machine `mini`, so its spaces and terminals show next to yours
(`hc machine ls` says whether the link is up). Terminal only: `ssh -t mini hc` (pick a terminal, Ctrl+\ detaches).

A roam or lid-close ends the link only — reopen, nothing is lost.

## Durable work

A core restart (kickstart) keeps every terminal and its programs. A *lost* program (crash, `kill -9`) is replaced by a shell:
`com.jkrumm.hc-resume` types `claude --resume` into a Claude terminal, but shells, dev servers and loops are gone and a resumed
agent lost its in-flight turn. Do not leave work that must not be interrupted in a bare shell. **Never `ssh mini 'claude …'`**: the session comes up
logged out of Max and silently bills API credits while still looking healthy —
a terminal spawned by the launchd core (`rd wave`/`rd work`) inherits the keychain.

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
| `launchctl print … sshd` says `state = not running` | Socket-activation idle, not a fault. Check `netstat -an \| grep '\.22 .*LISTEN'` |
| `ssh localhost` fails on the mini | By design — the mini has no key for itself. Verify inbound auth from the MacBook |
| A direct `op read`/`op run` hangs on the mini | No biometric prompt to answer. Use `secrets-run` |
| `op signin` "worked" but the next command says not signed in | Session lives in the shell that ran it — chain them |
| Agent died when the lid closed | It did not — the lid ends the link only. A *lost* program (not a core kickstart) is replaced by a shell; `hc-resume` brings Claude back, not shells or the in-flight turn |
| An agent runs but does nothing, shows `Not logged in` / API Usage Billing | Spawned over ssh, can't reach the login keychain. Spawn through the core (`rd wave`/`rd work`) — never `ssh mini 'claude …'` |
| `rd` says "herdr-core is not running" | `launchctl kickstart -k gui/$(id -u)/com.jkrumm.herdr-core` on the mini (terminals survive), or `make doctor`. Never an `hc` call to "wake" it: that starts a stray core |
| A `claude` in a core terminal has no transcript / `--resume` finds nothing | The core was started from inside a Claude session and passed `CLAUDECODE` to every terminal; launchd's clean env is the fix, so restart through launchd |
| A program in a terminal hangs at 0 % CPU on `~/Documents`, `~/Desktop`, `~/Downloads` | TCC dialog nobody sees: the launcher lost its Full Disk Access (a rebuilt launcher is a new identity). `make tcc-probe`, `docs/tcc.md` |
| A Claude terminal came back as a bare shell | Its program was lost and `hc-resume` has not typed yet (or the terminal had no `jk.claude.session` label). `hc read <t>`, `make hc-resume-status` |
| The app shows no tab for an `rd` spawn | Placement is by label and adopted when the app next sees the core: `hc get <t>` for `herdr.space`/`herdr.tab`; a worker has none by design (listed under its parent) |
| `claude: command not found` over non-interactive ssh | `make setup`'s `_setup-zshenv` puts Homebrew + `~/.local/bin` on the non-interactive PATH — re-run `make setup` if missing |
| `ssh mini` fails `signing failed … agent refused` → `Permission denied (publickey)` | 1Password is locked. Unlock it |
| A mini service accepts the connection then never answers, though its own log says it's listening | Application Firewall keys on the binary — `sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add <binary> && … --unblockapp <binary>` |
| `git push` on the mini fails `could not read Username for 'https://github.com'` | Credential helper returned nothing — `make git-headless`, reseed with `make secrets-seed` if stale |
| Anything else | Run `make doctor` first — it names the failing layer instead of guessing |

## Rules

- Restart the core only through launchd (`kickstart -k`); upgrades are the daily `com.jkrumm.herdr-core-update` job, never `hc update`.
  A change to the job's program is `make herdr-core-setup YES=1` and ends every live terminal: human-timed.
- Never run a validation loop or an edit over files a running `@implementer`
  subagent owns — applies across terminals too.
- Do not add `tailscale serve` bindings for dev servers; use Caddy.
- The `:8443` Funnel row is the IU dashboard, public **by design** — don't
  "clean it up".

Full model and rationale: `dotfiles/docs/remote-dev.md`; the core, spawn contract and facts: `dotfiles/docs/herdr-core.md`.
Access/auth model: `dotfiles-private/docs/access-model.md`.
