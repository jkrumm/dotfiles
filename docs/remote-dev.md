# Remote dev — MacBook → Mac mini

The Mac mini is the always-on dev host: agents, LaunchAgents, Docker, dev
servers. The IU MacBook (`iumac`) is the thin client — editing, the Herdr app, biometric
1Password. Agents run on the mini and outlive the MacBook.

Inventory of machines, repos, agents and doors: `docs/architecture.md`.
Day-to-day commands: the `/remote-dev` skill.

## The mental model

Three layers, each solving exactly one problem. **No layer substitutes for
another.**

| Layer | Tool | Solves | Cannot solve |
|-|-|-|-|
| Reachability | **Tailscale** | Stable address + NAT traversal | Nothing above it |
| Persistence + UI | **herdr-core** (`hc`, on the mini) + the Herdr app | Terminals stay alive; per-terminal agent state | Anything about the network |
| Service exposure | **Caddy** | Dev servers over the tailnet, real HTTPS, working WebSockets | Anything about terminals |

Riding on top, independent of all three: **Claude Remote Control**
(first-party, one session at a time; the whole-herd view is Collie). Raw
`claude --bg` is no longer a lane (`docs/agent-platform.md`).

**`mini` resolves two ways and the resolver picks silently.** The bare name is
LAN-first and `ssh_config` pins neither, so at home the tailnet is not in the
path and the ACL is inert — key-only sshd is the sole boundary there. The
consequence: **an ACL change cannot be verified from the couch.** Test ACL edits
off-network, or against the MagicDNS FQDN explicitly.

## Connecting — the Herdr app

The Herdr app on the MacBook is the window. It links the mini's core as machine `mini` (`hc machine add mini --name mini`,
once; ssh config host `mini`), so the mini's spaces and terminals sit next to the MacBook's (`herdr-app --skill`, MacBook
only, is its manual; the `herdr` skill holds the rules). The core and every terminal run on the mini and the link is
ssh/TCP, so a roam or lid-close ends the *link*, never a terminal: the app reconnects. Terminal-only fallback, no app:
`ssh -t mini hc` (pick a terminal and attach, Ctrl+\ detaches; only while `launchctl print gui/$(id -u)/com.jkrumm.herdr-core` shows the core running, since an `hc` call with no core starts one without the keychain). `desk` (classic's `--remote` attach) stays only until
Wave 7 deletes classic.

- **No ssh to the mini needs a 1Password approval, and plain `ssh mini` never
  touches the 1Password agent.** `Host mini` authenticates with the dedicated
  `~/.ssh/id_ed25519_mini` (`IdentitiesOnly yes`; public half
  `config/ssh/authorized_keys.mini`, installed on the mini only by `make
  authorized-keys`, as `restrict,pty,port-forwarding`), so scripts, `rd` and
  herdr-core's launchd-run machine link connect with no agent. It sets
  `IdentityAgent none` + `ForwardAgent no`: connecting to the agent socket inside
  1Password's group container raises macOS's "access data from other apps"
  (AppData) dialog, attributed to whichever background chain ran ssh (seen as
  `gtimeout` from the statusline's usage refresh). OpenSSH disables forwarding
  under `IdentityAgent none`, so **`ssh mini-fwd`** is the alias for the rare
  time the mini needs the human key (1Password agent, `ForwardAgent yes`, own
  ControlPath); the mini's git push uses its own credential. `make doctor`
  asserts both (`ssh -G mini`, `ssh-add -l` over `mini-fwd`).
- **ControlMaster shares one connection across the machine link's several.** `Host mini`
  sets `ControlMaster auto` / `ControlPath ~/.ssh/cm/%r@%h:%p` /
  `ControlPersist 10m` (`mini-fwd` uses `~/.ssh/cm/fwd-%r@%h:%p`, so it never
  reuses the agent-less master); the link, `rd` and scripts open several. `_setup-ssh`
  creates `~/.ssh/cm` — ssh will not, and connections fail without it.
- **`~/.zshenv` is the only file a non-interactive `ssh mini -- cmd` sources**
  (macOS runs `path_helper` from the *login* file `/etc/zprofile`). Without the
  guarded block `_setup-zshenv` appends, remote commands land with no Homebrew on
  PATH. It carries Homebrew and `~/.local/bin` (`claude`, `secrets-run`,
  `imgcli`), and is appended, not symlinked — other installers write to it too.
- `SetEnv TERM=xterm-256color` on `Host *` pins a universally-present terminfo;
  TERM is the one variable `SetEnv` passes without server-side `AcceptEnv`.

## herdr-core on the mini

`com.jkrumm.herdr-core` runs `hc serve` as a KeepAlive **LaunchAgent bootstrapped into `gui/<uid>`** (`make herdr-core-setup`,
both machines; `make herdr-core-status` prints its state and `hc server status`). It holds state with no viewer attached.
Design, launcher, updates, verified facts: `docs/herdr-core.md`.

- **Never start a core from ssh.** Any `hc` call, `hc connect` and the MacBook's link included, auto-starts one when none runs,
  and a core born in an ssh session has no keychain (the `ssh mini 'claude …'` trap, below). Scripts check
  `launchctl print gui/<uid>/com.jkrumm.herdr-core` first.
- **A core's environment is every terminal's**, and `hc run` forwards nothing: an account is chosen on the command
  (`env CLAUDE_CONFIG_DIR=… claude`, none = `iu`), never inherited. launchd's clean env also keeps `CLAUDECODE` out of every terminal.
- **The only restart is `launchctl kickstart -k gui/$(id -u)/com.jkrumm.herdr-core`**; terminals keep their pids. Never `hc update`,
  `hc server restart|stop` or `hc machine update mini` on the mini (they restart the core outside launchd's view). Updates are the
  daily `com.jkrumm.herdr-core-update` job (`docs/herdr-core.md` §Updates); keep both machines on one `hc` version (`hc machine ls`).
- **The job's program is a launcher** (`~/.local/libexec/herdr-core-launcher`) that holds Full Disk Access once, so no program in a
  terminal freezes on a TCC dialog nobody sees. Changing the job's program needs a `bootout`, which ends every live terminal:
  `make herdr-core-setup YES=1`, human-timed, and a rebuilt launcher needs a new grant. `make tcc-probe` proves it (`docs/tcc.md`).
- **A core restart loses no process; a lost program is replaced by a shell.** `hooks/hc-session-label.ts` labels a Claude terminal
  (`jk.claude.session`, `jk.claude.config`) and `com.jkrumm.hc-resume` (`make hc-resume-setup`) types `claude --resume <id>`
  under that account into the kept shell. Model, effort and the `c` launcher's env are not restored; shells, servers and the
  in-flight turn are lost.
- **Janitor and recorder.** `com.jkrumm.hc-reap` (`make hc-reap-setup`, every 30 min → `rd reap`, log
  `~/Library/Logs/hc-reap.log`) closes terminals of finished agents. `com.jkrumm.hc-events` (`make hc-events-setup`) appends the
  core's event stream to `~/.local/share/herdr-events/YYYY-MM-DD.jsonl`, with a gap marker on `missed` or a core restart. Classic
  `herdr-reap`/`herdr-events` run beside them until Wave 7.
- **`HC_TERMINAL_ID` is how an agent knows it is in a core terminal** (`t7`; `mini/t7` from another machine), which makes the
  `herdr` skill inert on a plain shell. It is inherited at spawn, not tracked: `hc get` is the live state.
- **cmd-e opens `Projects/<repo>.md`** from `~/SourceRoot/brain` in `$EDITOR`: the `jk-keys` mod runs `scripts/brain-note.sh` for
  the focused terminal's repo as a peek over the tab (`scripts/herdr-app-keys.sh` binds the key). The script creates the page if
  absent (house frontmatter, wikilinked from `Projects/Projects.md` — new pages must stay wikilinked or `vault-lint` warns).
  **Per repo, not per space.** A mini terminal edits the mini's checkout, where the brain-sync lane never commits — the note
  lands via the nightly `brain-backup` sweep.

### Janitor rules and `rd wave` detail

Moved verbatim from `AGENTS.md`.

- **`rd wave <repo> '<prompt>'`:** long work the owner watches or steers; adds a `wave <n>` **tab** to the repo's space in the Herdr app (a space only if the repo has none), solo Claude (Max subscriptions only, never IU), bounded by `RD_WAVE_MAX`. With the factory answering, `rd wave
- **`rd reap`:** `rd reap [--dry-run]` — the janitor (`scripts/hc-reap.py`, `com.jkrumm.hc-reap` every 30 min): closes tabs whose agent was done/idle > `REAP_IDLE_H` (12) with a clean, pushed checkout and no `active` wave; closes an `rd fan` tab (worktree carries the `rd-fan` marker) as soon as its branch is merged (PR MERGED/CLOSED whose head contains HEAD, or patch-equal to the default) or deleted on origin, active wave or not, never with a working/unknown agent, a dirty/unpushed tree, or a mother/lead/`wave <n>`/`-w<n>` tab; messages dirty/unpushed ones; stops `claude --bg` leftovers > 24 h. Log: `~/Library/Logs/hc-reap.log`

### Sidebar groups

The Herdr app's `jk-spaces` mod draws the folders: `config/herdr-app/groups.json`
declares the taxonomy (linked to `~/.config/herdr-app/groups.json` by `make
herdr-app-setup`), a space joins the group naming its repo, the rest land in
`OTHER`, and `jk-board` files its repo cards under the same folders. Adding a
repo is one line in the JSON; an unopened space is skipped, so listing one early
costs nothing. Classic's separator-workspace headers (`make herdr-groups`) are gone: the folders replaced them.

## Putting work on the mini

The app answers "how do I go look at the mini". The commoner question is "how do I
put work there and check on it", which needs no terminal.

`scripts/remote-dev.sh` (`rd`) routes off the `~/.config/secrets/backend` marker
— local on the mini, one ssh hop from the MacBook. Commands take a repo **name,
never a path**; resolution happens on the far side across `~/SourceRoot` and
`~/IuRoot`.

| Command | Does |
|-|-|
| `repos [filter]` | repos on the host, branch + dirty count |
| `work <repo>` | labelled tab + claude in the repo's space, **idempotent** (reports a running agent, never stacks) |
| `wave <repo> '<prompt>'` | tab + solo claude, the prompt as its argument; `fan <repo> <brief…>`: worktree + hidden child per brief |
| `agents` | every roster, one line per agent (`SOURCE NAME STATUS CWD ID`), deduped on Claude session id |
| `rd read <agent>` / `rd say <agent> '…'` / `rd close <agent>` | watch / steer / end without attaching; all take an address, a terminal name, a repo name or a cwd |

**On herdr-core (`hc`).** Every verb runs on the core (`docs/herdr-core.md` §Port design, §Spawn contract); the factory
is tried first and hc-direct is the fallback (below). Four rules hold:

- **`rd` never starts a core.** Any `hc` call, `hc connect` included, auto-starts one when none runs, and a core born in
  an ssh session has no keychain. So every verb that touches terminals first asks `launchctl print gui/<uid>/com.jkrumm.herdr-core` and stops
  with `launchctl kickstart -k gui/$(id -u)/com.jkrumm.herdr-core` in the error when launchd has no running core. No verb
  calls `hc update` or `hc server restart|stop`. `HC_SESSION` (a scratch core in tests) skips the launchd check.
- **A spawn goes over the API** (`hc connect`, `terminal.run`), because the CLI's `hc run` cannot pass `env` and a core's
  own environment is every terminal's. It always sets `cwd`, `keep`, a `name` (the agent name; `f-<hash>-…` when it would
  read like an address, `t7`), argv `["claude", flags…, "<prompt>"]` (the prompt is the last argument, nothing is typed
  later; a prompt starting with `-` is refused) and `env`: `FACTORY_SESSION`, `FACTORY_ROLE` (when there is a role),
  `USAGE_LANE`, and the pick: `CLAUDE_CONFIG_DIR` for a Claude account, **absent for `iu`**, never empty, never
  inherited, plus the `CLAUDE_ACCOUNT_PICKED` marker.
- **Tabs and workers.** `work` and `wave` (a chain's next wave included) are tabs: labels `herdr.space=<id>` +
  `herdr.tab=tb-<hash of the agent name>` and `no_parent`, so the terminal outlives whoever spawned it; the tab is then
  named by compare-and-set `doc.set` on the `herdr-app` doc (retried on `conflict`, best effort). The space is the doc
  entry whose `folder` is the repo root, else `sp-<repo>-<hash of the full root>` — HcRunner's rule, so a factory spawn
  and an `rd` spawn land in the same space. `RD_ORCHESTRATED=1 rd wave` keeps the calling terminal as `parent`
  (labelled tab, so the lead's notes and `hc wait --children` see it). `fan` workers are hidden children: `parent` =
  `$HC_TERMINAL_ID`, no labels (the app lists them as the orchestrator's sub-agents), and `outlive_parent: true` like the
  orchestrated wave's tab, so losing or closing the orchestrator never kills a working child and its uncommitted work. Without a calling terminal on the dev host (a MacBook shell) a worker is a tab.
- **Bounded, and only ours.** Every `hc` call runs under the host's `timeout`/`gtimeout` (`RD_HC_TIMEOUT_S`, 30 s). A
  spawn that gets no answer reports `uncertain` and points at `rd agents`; it is never retried. `close`, `read`, `say`
  and the `wave` checks see only the dev host's own terminals (a linked machine's `mini/t3` is dropped; `rd agents`
  lists them all). `close` and `fan --clean` treat only a known `idle`/`done` status as finished (`fan --clean` judges
  every agent in the worktree and keeps it unless every terminal was ended). One refused `fan` spawn is reported and
  the next brief still goes; the exit code is non-zero at the end. A `fan` from the owner's own terminal on the dev host
  (`HC_TERMINAL_ID` set, no `FACTORY_SESSION`) goes hc-direct, so the workers are its children.
- **Waiting.** hc types a note into the parent when a child finishes, blocks or exits, and `hc wait --children all|any`
  waits for them. Factory spawns keep `factory session wait --on workers` (a held spawn has no terminal yet).

`rd agents` prints one line per agent: `SOURCE  NAME  STATUS  CWD  ID`, the status being hc's own word (`working`,
`idle`, `done`, `blocked`). **That text is a contract**: iris' `mother-watch.sh` greps it for `iris-w<n>` and `blocked`
(pinned by `scripts/remote-dev-wave.test.sh`). Sources: `hc` (an agent terminal: it reports a status or runs `claude`
itself — a plain shell is not one), `herdr` (classic, until Wave 7), `bg` and `interactive` (`claude agents --json`).

`say` on an hc terminal is `hc send`: it pastes the text and presses Enter once nobody is typing. A **blocked** agent is
refused (`NOT delivered: … blocked on a dialog`; the text would answer its dialog; `rd read` it and answer by hand),
and a working one queues the message (`queued: agent busy`). `close` is `hc kill` + `hc rm` after the existing checks
(agent not working or blocked, checkout clean, nothing unpushed) and one more: the terminal's own program must be
`claude`, i.e. rd or the factory started it. `read` is `hc read --lines N` (`[src]`: a line count, `visible` for the
screen). Names resolve against the live agents' address, terminal name, `factory.key` label, cwd and the cwd's
basename; two matches stop with the candidates listed.

**Classic fallback (until Wave 7).** A token hc does not know falls through to classic herdr's old paths for `read`, `say` and `close`;
`agents` lists both rosters, and `wave`/`work`/`fan --clean` also check classic agents for a second editor. Wave 7 deletes the
branch. Hermetic suites: `scripts/remote-dev-{say,wave,factory,factory-env}.test.sh` against `scripts/remote-dev-fake-hc.sh`
(a fake core; never a real one).

`work` is idempotent because two agents in one checkout is the file-ownership
hazard, except across terminals where you cannot see it happen. `agents` dedupes on
the Claude session id (hc: the `jk.claude.session` label; a classic agent: its session value; the daemon:
`sessionId`) — otherwise one Claude in a terminal reads as two agents racing a tree.

Two lanes start agent work (`docs/agent-platform.md`): `@implementer` and an `rd wave` tab (also `rd fan` for N independent changes). `agent-dispatch` and
`rd bg` were removed 2026-10-04.

**Never `ssh mini 'claude …'`.** Claude Code's Max credential lives in the
**login keychain**, unreachable from an ssh session, so that spelling comes up
`Not logged in`, silently falls back to API billing, and still looks healthy in
`claude agents`. The core is a LaunchAgent inside the GUI session, so
anything it spawns (terminals, `rd wave`/`rd work`) has keychain access, and the mini's
auto-login brings the keychain up unlocked at boot.

**`config/zsh/claude-auth.zsh` is an armed fallback** (inside the one `claude()` zsh function, which also picks the account — `docs/claude-accounts.md`): it resolves `op://mini/claude/oauth-token` via `secrets-run` into
`CLAUDE_CODE_OAUTH_TOKEN` — **never `ANTHROPIC_API_KEY`**, which flips billing to
API credits. It probes the keychain credential first and **uncached** (a cached
verdict once suppressed the fallback for an hour while `claude` ran with no
credential at all). It is a **function**, not a `~/.local/bin` shim (the updater
rewrites that path), passes the token by **prefix assignment** (not `env VAR=…`,
which leaks into `ps auxww`), and self-gates on the `cache` backend marker. Only
the keychain-dead-*and*-token-dead state fails the heartbeat. **Restore the
keychain credential with `/login` in a core terminal on the mini** rather than
minting a token: it is a one-year credential with no refresh and no reliable
revocation. The token applies to the **default account only**
(`CLAUDE_CONFIG_DIR` unset = `iu`); a non-default account dir never gets it, a dead
login there just prints a `/login` hint.

**Accounts on spawn** (`docs/claude-accounts.md`): `rd work`, `rd wave` and `rd fan` run
`claude-account pick --lane interactive|wave|fan` on the host before creating the terminal and pass the
result as `CLAUDE_CONFIG_DIR` in the spawn's `env` (absent for `iu`); the output line
carries the pick reason. No Claude account with room pauses the spawn (`rd` refuses to spill to IU;
`--kind opencode` is rejected). `rd agents` / `rd read` merge `claude agents --json` across every
enabled account.

**Factory session key.** `rd work`, `rd wave` and `rd fan` also pass `FACTORY_SESSION=<agent name>` in the spawn's `env`
(`spawn_env` in `scripts/remote-dev.sh`; the name is the terminal's name, e.g. `myrepo-w4`). The software-factory hooks in `config/settings.template.json` (`docs/hooks.md`) run
only when it is set, so the owner's own sessions never report. Covered by `scripts/remote-dev-factory-env.test.sh`.

**Role table (`--role`).** `rd wave|fan|work --role <role>` (`mother|lead|wave|worker|mechanical`) takes the
tier and effort from the factory's role table: `factory role get <role> --format json` →
`{"role","tier":"haiku|sonnet|opus","effort":"low|medium|high|xhigh|max"}`, no token needed. The tier goes to
Claude as `--model <tier>` (the alias, never a model id), the effort as `--effort`. Precedence, per value:
`RD_WAVE_MODEL` / `RD_WAVE_EFFORT` (explicit env) over `--role` over today's defaults (Sonnet, effort from
`config/claude-effort.json`). Without `--role`, `rd wave` behaves as `--role wave` and `rd fan` as
`--role worker`; `rd work` starts bare, as before, unless `--role` is given. **Fail open:** `factory` missing,
non-zero exit, no answer within 2 s, or JSON off the schema costs one stderr line
(`rd: factory role '<r>' unavailable (<why>) - using the default model and effort`) and the spawn keeps
today's defaults — a dead factory never stops a spawn. Only a factory that answers the role does not exist
(`error.kind` `not_found`, or an "unknown role" message) or a malformed role name is a usage error (exit 2),
raised before anything is created. One lookup per `rd fan`, not per brief. Covered by
`scripts/remote-dev-factory-env.test.sh`.

**`rd` and the factory (which path, when).** `wave`, `fan`, `say` and `close` ask `factory health` first
(`timeout 3`, once per command; `RD_NO_FACTORY=1` skips it; a host with no `timeout`/`gtimeout` has no factory path, since an unbounded call could stall the repair). Answers → the factory path; anything else (not
installed, down, slow, non-zero) → hc directly (above), and every terminal it makes carries
`FACTORY_ROLE=<role>` next to `FACTORY_SESSION` (`rd work` only when `--role` is given). A dead factory
never stops the waves that would repair it: every call is bounded and every failure before a spawn exists
falls back. `RD_DRY_RUN=1` never probes.

| Verb | Factory answers | Falls back to hc when |
|-|-|-|
| `wave`, `fan` | `factory spawn create <agent> --repo <path> --prompt … --role <role> [--space <main checkout>]`, then poll `factory spawn get` (every `RD_FACTORY_POLL_S`, 2 s; up to `RD_FACTORY_WAIT_S`, 120 s) | `create` fails **certainly**: the call never ran (no `factory`, no `timeout` binary) or the factory answered with an `error` object. A silent failure (a dropped hop, a timeout) may come after the factory recorded the spawn: `spawn get` showing it is followed, anything else is an error (look at `factory spawn get <key>` before re-running), never a second terminal under the same name |
| `say` | `factory session note <agent> <text>`: held while the agent works, typed at its next prompt, confirmed by its next turn | the factory answers `error.kind` `not_found` for the session, or the agent has no name. Any other failure (a timeout, a dropped hop) may have recorded the note: NOT delivered, never re-sent |
| `close` | none on an hc terminal (`hc kill` + `hc rm` after the safety checks); a classic agent still asks `factory session get` for its tab | classic only: the factory has no such session, so the tab must be labelled `wave <n>` |

Spawn outcomes, from `factory spawn get` `.status`: `started` (`.pane`, `.tab`, `.workspace` set) prints today's
line plus `via the factory` and the account; `queued` with `.hold` set (`drain|pace|wave`) prints `queued: <hold>`
and `waiting` (no capacity) prints `queued: no capacity until <resumeAt>`, both exit 0 (the factory starts it later;
the hc path dies with "paused"); a `queued` spawn without a hold is waited on like `starting` (claimed) until the
wait ends, then reports `queued: not claimed yet`; `failed` exits non-zero with `.error`. An empty or unknown status
after an answered create is an error. A spawn that
fails after it exists never falls back to hc (two sessions on one name). `rd fan` keeps going after a
failed or queued brief and exits non-zero at the end if any failed. On the factory path the factory picks
the account and the model: `rd` runs no `claude-account pick`, and `RD_WAVE_MODEL` / `RD_WAVE_EFFORT` do
not reach the spawn (one stderr line says so). `close` keeps its refusals on both paths (agent working,
checkout dirty, anything unpushed). Under a `drain` the factory holds the
spawn (`queued: drain`) and starts it when the drain lifts; `wave-gate.py` no longer asks the factory, so
`rd wave` exits 0 and a chain wave counts it as its successor spawned. Covered by
`scripts/remote-dev-factory.test.sh` and `scripts/wave-gate.test.py`.

## Dev-server doors

**`config/Caddyfile` is the single app registry.** Every
`<name>.test { reverse_proxy localhost:PORT }` block automatically gets a clean
tailnet door — a new app needs nothing else. `~/.config/caddy-tailnet.ports` is
**opt-out only** (`exclude <name>`), not a second list; it used to be one and the
two drifted silently (17 apps vs 4). `~/.config/caddy-tailnet.conf` carries
`DEV_DOMAIN` and the Cloudflare token path.

Apps that must not be named in the tracked Caddyfile (work repos, internal services) go in the
untracked `~/.config/caddy-tailnet.apps` instead — one `<name> <port> [rewrite]` per line, merged into the same
registry; they get the clean tailnet door only, no `.test` twin.

To also serve a registry app at a fully-qualified name outside `DEV_DOMAIN`, list it in the untracked
`~/.config/caddy-tailnet.hosts` (`CADDY_TAILNET_HOSTS` overrides the path) — one `<fqdn> <app-name>` per line,
`#` comments and blanks ignored, a missing file means no extra doors. Each line becomes its own site block after
the wildcard block (a wildcard cert never covers another zone's names), with its own Let's Encrypt cert via the same
Cloudflare DNS-01 token, the same homelab/VPS source guard and the app's own path restriction / Host rewrite, but no
landing page. The generator refuses a name that is or sits under `DEV_DOMAIN`, the landing page's host, an unknown or
excluded app, or a duplicate. The A record pointing `<fqdn>` at the host's tailnet IP is a DNS-only step; the IP
never enters git. Covered by `make caddy-tailnet-test`.

| Door | URL | Scope |
|-|-|-|
| Local | `https://<name>.test` | this machine only (`bind 127.0.0.1`; dnsmasq wildcards `*.test` → 127.0.0.1) |
| Clean | `https://<name>.mini.jkrumm.com` | tailnet — one wildcard site block, Cloudflare DNS-01 cert, ACL `tag:devhost → tag:mac/tag:phone/tag:tablet` on `tcp:443` |

While the ACL still grants `tag:homelab` / `tag:vps` `tcp:443` on the whole mini (a portless grant cannot be narrower; removal is pending a MacBook-side `make tailscale-acl-push`), `scripts/caddy-tailnet.sh` reads those peers' tailnet addresses from `tailscale status` and makes the wildcard block answer `403` to them for every host. Drop `GUARD_SRC_TAGS` once the grant is gone.

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
Remote Control (first-party, one session), and **Collie** — a standalone bridge on herdr-core +
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
  daemon, a core terminal and a shell. It is deliberately **not** Hermes's read-only
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
  raises Touch ID on the MacBook and resolves once approved (verified
  2026-09-14, `op://Private/*` included); it fails fast (exit 1) only when
  1Password there is not signed in. Go through `ask-human.sh … --push`, never bare.
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
- **Also the transport for `ask-human.sh … --push`** (see *human-queue*, below):
  it runs `human-queue.sh gui-run` over this same key, non-interactively. That
  is exactly the "arbitrary commands non-interactively" reach this section
  already describes — `gui-run` doesn't widen it, it puts a human dialog in
  front of it for this one path.

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
running in full behind the password prompt — the core, every agent, SSH, Tailscale.
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
Two ways the request then gets in front of a human: the MacBook drains on its
own schedule (`make human-queue`), or the mini **triggers the approval itself**
as a native dialog there — **the default since 2026-09-15**; the Slack notify
hook only fires when that push could not resolve the request.

| Side | Command | Runs on |
|-|-|-|
| Enqueue | `ask-human.sh ask "<text>" [--cmd <command>] [--wait <seconds>] [--no-push]` | mini |
| Trigger the dialog for an already-enqueued request | `ask-human.sh push <id>` | mini |
| Inspect own request | `ask-human.sh list` / `status <id>` | mini |
| Drain | `make human-queue` (walks each pending request) · `-list` · `-count` · `-show/-run/-deny ID=<id>` | MacBook |
| Dialog trigger target (not for interactive use) | `human-queue.sh gui-run` (request JSON on stdin) | MacBook, invoked over ssh by `push` |

State is `<id>.req` + `<id>.res` under
`${XDG_STATE_HOME:-$HOME/.local/state}/human-queue/` on the mini (dir 700, files
600); pending = no `.res`. `--wait <seconds>` polls every 5 s, exiting 0/1/2/3
for done/denied/failed/timeout; the default is **0** (return at once) because
the median resolution is about seven days — the queue drains when a MacBook
session happens to be open — so a polling default only ever timed out. The default push
takes precedence over `--wait`: it already resolves synchronously over one ssh
round trip, so there is nothing left to poll for. An unreachable MacBook (69)
or an unanswered dialog (75) leaves the request pending and fires the notify
hook; `--no-push` / `HUMAN_QUEUE_PUSH=0` enqueues only.

- **The transport is the existing MacBook→mini ssh hop** for a manual drain, and
  the mini's own **`ssh iumac`** reach (see *mini → iumac*, below) for `--push` —
  neither is a new credential, and no inbound door opens on either machine. Both
  scripts refuse to run on the `cache` backend (the mini).
- **There is still no path that skips a present human.** The mini only ever
  *proposes* a command string. `run <id>` (manual drain) prints it verbatim and
  requires a typed `yes` on a real TTY; `gui-run` (the `--push` target) shows it
  in a native macOS dialog (`osascript display dialog`, buttons "Deny"/"Run",
  default "Deny", a `giving up after ${HUMAN_QUEUE_DIALOG_SECONDS:-600}` seconds
  timeout) and only executes on a click. Every string reaches AppleScript as
  **argv**, never spliced into the script source, so a crafted request can't
  inject AppleScript the way a raw ESC byte could once make a terminal show
  something other than what would run — `printable()` still strips control
  bytes from what's *displayed*, same as `run`'s `print_req`. A command longer
  than ~2500 chars after that stripping never reaches the dialog at all — no
  "Run" button is offered for a string that can't be shown in full. The dialog
  is a **second** gate next to the typed-yes TTY gate, not a bypass: it exists
  because the ssh key behind `--push` already lets the mini run arbitrary
  commands non-interactively on the MacBook, and turns that reach back into
  something a human approves per request, by reading the exact string. A
  misbehaving mini can put a string in front of a human either way, never open a
  shell on its own.
- **The default drain walks the queue instead of printing it**, prompting
  `[r]un / [d]eny / [s]kip / [q]uit` per request. That is ergonomics only: it
  reuses the same `run_one` gate, so the TTY requirement, the typed `yes` and the
  control-byte stripping are unchanged, and the ids it walks come *from the mini*
  and are re-validated against the id pattern before reaching any command string.
  Declining one request returns rather than exits, so it no longer ends the walk.
- **`--push`'s outcomes**: `done`/`failed` write the `.res` locally on the mini
  (no extra ssh hop back — `ask-human.sh` already has the result from the same
  round trip) and exit with the command's own exit code; `denied` writes `.res`
  and exits 1; `unanswered` (dialog timed out, or the command was too long to
  show) leaves the request pending, unchanged, for `make human-queue`, exit 75;
  an ssh failure or an unparseable response also leaves it pending, exit 69.
  `push` refuses an id that already has a `.res`.
- **No LaunchAgent drains it, deliberately** — a manual drain sits behind the
  per-use biometric 1Password agent, so a poller means an unattended Touch ID
  prompt on a schedule forever, and `--push` needs an actual click, which is the
  same objection restated. `hooks/machine-role.ts` folds a count into
  SessionStart on the `op` backend only, with a 2500 ms timeout collapsing to
  silence.

### Human queue notifications

`ask-human.sh` fires `~/.config/human-queue/notify-hook` (backgrounded, output
discarded) with `<id> <text>` right after the request is durably on disk.
`make setup` installs it on the cache backend only, as a symlink to
`scripts/human-queue-notify-hook.sh`: one Slack line to `#agents` through Argo's
Slack proxy (`POST /slack/channels/<id>/messages`, bearer from
`secrets-run read op://common/api/SECRET`, channel id resolved by name from
`GET /slack/channels`), with
the question and the `make human-queue` hint.

- **Every failure is soft** — no token, no channel, Argo down: the hook exits 0
  and the request is still queued. The queue is the source of truth; Slack is
  the nudge. The `no notify hook at …` note from `ask-human.sh` means the hook
  was never installed on this machine (`make setup`), not a failed push.
- **No poller on the other end, still** — the notification tells the human a
  request exists; draining stays a `make human-queue` on the MacBook.

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
  `make colima-status` asserts the same on demand; `make herdr-core-status` prints the core job's state and pid.
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
`make colima-{start,stop,restart,status}`, never bare `colima stop` (KeepAlive
undoes it) and never `brew services restart colima`: brew regenerates the stock
plist and bootstraps that, so the repaired file never reaches launchd — the VM
keeps running under the inverted KeepAlive while `ls` shows a converged file.
`colima-restart` converges, then bootout + bootstrap (the only reload that
re-reads a plist; `kickstart -k` does not). `colima-start` re-arms only if
launchd's loaded `program` is not the wrapper, so it never bounces a healthy VM.
The wrapper adopts a VM that was started detached (stops it, restarts it in the
foreground, one hop) instead of hot-looping on `colima start -f`'s instant
"already running" rc=0 under bare KeepAlive.

- **The plist's `KeepAlive` is repaired, and the repair is load-bearing.**
  Homebrew generates `KeepAlive { SuccessfulExit => true }` (restart only on a
  *zero* exit) while `colima start -f` runs the VM in the foreground — inverted,
  so a dirty Lima image leaves Docker down until a human logs in.
  `{ Crashed => true }` is not the fix (that is death by *signal*).
  `_setup-colima` converges onto bare `KeepAlive => true` plus
  `colima/colima-start.sh`, a bounded-retry wrapper (5 fast attempts, then a
  600 s cool-off, never latching off). **Brew regenerates the plist on every
  `brew services start/restart` and every `brew upgrade colima`, silently** — so
  every `colima-*` target re-converges and `colima-status` asserts the file AND
  the loaded job's `program`.
- **And since Homebrew 6, it regenerates it under a different NAME** —
  `homebrew.mxcl.<name>` → `sh.brew.<name>`, written on the next `brew services
  start|restart` (the old file is deleted then, not at upgrade time), so both
  names are live across these two machines. `scripts/lib/brew-service.sh` is the
  single resolver every caller goes through; nothing hardcodes a label. The old
  hardcoded path turned the converge step into `plist absent — nothing to
  supervise`, exit 0, over the stock plist it exists to repair.
- `COLIMA_CPU` / `COLIMA_MEMORY` / `COLIMA_DISK` default per machine off the
  backend marker — mini **4 / 12 / 60**, MacBook **2 / 4 / 30** — because
  `colima-restart` writes cpu/memory back into `~/.colima/default/colima.yaml`
  on every run. Ceilings, not reservations; disk only grows via recreate.
- **`colima delete` orphans the data disk.** It leaves
  `~/.colima/_lima/_disks/colima/datadisk` (sparse, tens of GB) behind, unlisted
  by `limactl disk list` and `colima list`, and a fresh `colima start` silently
  reuses it — defeating a `--disk` resize. Remove it explicitly before recreating.
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
  a whole-device capability and `tag:mac` would expose the work MacBook; `:10000` —
  **Funnel, public internet**, Athena Teamchat, same tag and grant. Those two ports
  are the machine's entire public surface.
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
| `make doctor` | Read-only, self-routing. Both machines: LaunchAgent grading, core running + managed install + `hc` version parity, architecture-map check, brew pins/outdated. Mini: the drift report without pushing. MacBook: the remote path (Tailscale, ssh, ControlMaster reuse, agent forwarding, git push dry-run), Kuma monitor states, then the mini's doctor over ssh |
| `make status` | Prerequisites + symlink health, then `doctor --local` |
| `make devhost-health-check` | One heartbeat run, per-component (`docs/devhost-health.md`) |
| `make colima-status` / `make herdr-core-status` | Colima's boot path asserted, not just "the process is up" / the core job's state, pid and `hc server status` |
| `make tailscale-serve-check` | Serve drift against the declared file |
| `bash scripts/architecture-check.sh` | Every loaded/on-disk launchd label appears in `docs/architecture.md` |

By hand after a change to this stack: start agents in the app, close the lid,
reopen it — all still there.

**The heartbeat asserts the GitHub credential resolves, not that a push
succeeds** — the real `git push --dry-run` lives in `make doctor`, because at a
300 s cadence a provider outage would page as "dev host down". That split earned
itself once already: the credential resolved fine while the deployed helper still
pointed at a read-only token, and only the dry-run saw it.

## Fan-out and the merge train

`rd fan <repo> <brief…>` cuts one worktree per brief from **fetched** `origin/<default>`
(`scripts/fan-worktree.sh`; the repo's `.wtp.yml` hooks run when it has one), starts a
hidden Claude child per brief in it (the spawn contract above) and delivers
the brief with a `Base: origin/<default> @ <sha>` line prepended. Each brief names its
branch on a `Branch:` line. `rd merge <repo> <branch…>` (`scripts/merge-train.sh`) rebases
each onto the current origin default, installs from the lockfile present (`bun.lock`/`bun.lockb`,
`pnpm-lock.yaml`, `package-lock.json`; a failed install is a red check; `--no-check` skips it),
runs `make check`, pushes with lease, readies a draft PR (`gh pr ready`), waits for the PR's
CI on the pushed sha, merges the PR by rebase and re-fetches before the next; GitHub only. The
CI gate polls one `gh pr view --json headRefOid,statusCheckRollup` (every `RD_CI_POLL` s, default
10; each gh call bounded by `timeout`) and trusts it only while the head equals the pushed sha.
A failed or cancelled check dies at once with its name and run URL (the PR URL when the check
has none). A pass is never declared before `RD_CI_GRACE` (30 s; a push's check suite exists 0–5 s
after the push, measured over 11 pushes) has passed since the push, and needs one non-skipping
check, so a partial or skipping-only list cannot merge early. None or skipping-only after the
grace merges as no-CI; pending past `RD_CI_TIMEOUT` (1200 s) dies; `--no-ci` skips the gate.
Needs `jq`. `rd fan --clean <repo>` removes
clean, fully merged worktrees and their terminals, but only those `rd fan` created (a `rd-fan` marker in the worktree's git dir;
others, and ones made before the marker, are kept); `--all` judges every extra worktree. A `rd wave` without `(Wave <n>)` takes the next
free tab number whose `<repo>-w<n>` is not a live agent name; an explicit `(Wave <n>)` whose
name is live is refused. Hermetic suites: `make fan-test`.
Prompt delivery for `rd wave` and `rd fan`: the prompt travels in argv (the spawn contract), so there is no delivery check or re-send; a spawn that never reaches `working` shows in `rd agents` / `rd read`.

**Waiting on spawned agents.** Nothing polls. The spawner is the worker's parent: `factory session wait --on workers`, then end the turn; the factory's wake note ("workers done: …") starts the next one, and a held `queued:` spawn is a worker too. One wake per declaration, so declare `--on workers` again after each new spawn or `rd say` fix. A finished child counts as done even while a fix note is still queued, so after `rd say` check `factory status` in the foreground, bounded by `timeout` (a few minutes): note delivered and worker `working` → declare; worker idle again after delivery → read its diff, no wait; note still queued (an idle worker is not proof the fix ran) → `rd read` it, then escalate to the owner. Only `rd fan` and `RD_ORCHESTRATED=1 rd wave` make the caller the parent (a plain chain `rd wave` is parentless by design), and a session without `FACTORY_SESSION`, or an `rd` that fell back to hc direct, has no factory wake: wait with `timeout <s> hc wait --children all` (`any` for the next news; it returns early on a note, then wait again). `rd read <agent>` and `factory status` are how a woken orchestrator looks.
