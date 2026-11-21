# The mini's service registry

One list of everything that runs on the Mac mini, with a tier, a memory budget and start and stop verbs. Before it,
88 plists from ten repos sat in `~/Library/LaunchAgents`, 18 containers in two Colima profiles and 23 `.test` doors in
`config/Caddyfile`, and nothing could tier, budget, start or stop them in one place. The program is the Spec of
Issue 1177 (*Mini lean*); this page is its first row, the registry and its verbs. It changes nothing that runs.

| | |
|-|-|
| Registry | `config/mini/services.yaml` (the host's list) plus a `mini-services.yaml` at the root of any repo under `~/SourceRoot` or `~/IuRoot` |
| Tool | `scripts/mini-registry.ts` (bun), `scripts/mini-registry.test.ts` |
| Verbs | `make mini-ps` · `make mini-up NAME=<service>` · `make mini-down NAME=<service> [FORCE=1]` · `make mini-profile NAME=<work\|dev-db> UP=1\|0` |
| Checked by | `make check` (`lint`, before a merge), `make doctor` (section *Service registry*) and the heartbeat component `check_registry` |

## Tiers

| Tier | Rule | Members today |
|-|-|-|
| `core` | always on | herdr-core, the factory, agent-workflows, Postgres, Caddy, hermes, the home jobs, iris, argo, finances, modelpick, linewatch, rb, the schedules, the teamchat api, broker and sandbox, and the work stack colleagues reach (VPN, import dashboard, its watcher, the token minters, the dashboard and tool deploy gates, the state backup, the artefact job) |
| `on-demand` | starts on the first request, stops after an idle window | dev servers behind `.test` doors (basalt, rollhook, fpp, ...), `research-chrome`, `shared-chrome` (the `/browse` Chrome) |
| `manual` | started and stopped as a profile | `work` (the student-enrolment containers only), `dev-db` (mariadb, redis, clickstack); weatherorb's disabled jobs have no profile |

A tier is a promise the registry holds. For a dev server behind a tailnet door the host keeps it (§Apps page): the door
starts it, the idle stop ends it.

**One VM, always on, 2.5 GiB.** The mini runs one Colima VM, `default`. The VPN, the import dashboard and the teamchat sandbox
(opencode, relay, egress) run in it, colleagues reach them, so they are `core` and no profile verb stops them: `make
mini-profile NAME=work UP=0` reaches only the student-enrolment containers. The dev databases (`dev-db`) start in the same
VM on demand. The VM's budget is its measured footprint times 1.1 (a vz guest cannot exceed its ceiling by much); its
revert signal is an out-of-memory kill in the guest, answered by `COLIMA_MEMORY=3` (then 4), never by a second VM.

## An entry

```yaml
services:
  - { name: argo, repo: argo, kind: launchd, tier: core, label: com.jkrumm.argo, door: argo-live, memory_mib: 150 }
  - { name: mariadb, repo: vps, kind: compose, tier: manual, profile: dev-db, container: mariadb, project: vps,
      needs: [vm], start: "make -C ~/SourceRoot/vps dev-mariadb-up", stop: "make -C ~/SourceRoot/vps dev-mariadb-down", memory_mib: 200 }
```

| Field | Meaning |
|-|-|
| `name`, `repo` | Unique name; the owner repo (a repo's own file defaults it to the directory) |
| `kind` | `launchd`, `compose`, `vm`, `static`, `dev-server` |
| `tier`, `profile` | A tier; a `manual` service may name a profile (`work`, `dev-db`) |
| `needs` | `[vm]` is the Colima VM of the service's own profile, anything else a service name. `mini-up` starts what is not running first |
| `memory_mib` | The budget, in MiB of physical footprint |
| `door` | The Caddy registry name(s) it serves, as `scripts/lib/caddy-registry.py` yields them |
| `label` | launchd label. A brew service matches `sh.brew.<n>` and `homebrew.mxcl.<n>`; `daemon: true` for `/Library/LaunchDaemons` (read with `launchctl print system/<label>`, `process:` names its process for the footprint) |
| `container`, `project`, `vm` | A compose service: the container, its compose project, the Colima profile (`default` if omitted) |
| `ports` | TCP ports the service listens on (127.0.0.1 only): `ports: [4416, 4417]`. A port two registered services claim fails the check; a port no entry claims is not looked up |
| `process_type` | `interactive`, for a `core` launchd service others wait on: `make mini-ps` and the check fail while it runs lower (§Process type) |
| `shared_memory` | Postgres: every process's footprint counts the shared buffers again (below) |
| `idle_minutes` | A dev server: minutes with no request to its door before the idle stop ends it (default 30) |
| `start`, `stop`, `status` | The owner repo's own command (`make -C <repo> <target>`; `~/` expands). A launchd job without `start`/`stop` gets `launchctl bootstrap`/`kickstart` and `bootout`; anything else refuses the verb |
| `debt`, `exception` | A known breach of a run rule: `debt: { <rule>: <plan row or issue> }`, or `exception: { <rule>: <reason> }` when it is allowed. Rules: `restart-policy`, `no-memory-limit`, `port-binding`, `second-vm`, `shared-infrastructure`, `no-budget`, `worktree-program`, and the ones only a person can see (`keepalive-poll`, `docker-build-tool`) |
| `oneshot` | `true` for a root job that runs once at boot: no process, so a budget of 0 is allowed |
| `note` | One line for whoever reads the table |

A file may end with a top-level `debt:` list of `{ repo, target, rule, plan }` for what belongs to no service (a make target that runs docker as a build tool).

A repo that adds a job registers it in the same commit: a `mini-services.yaml` at its root with the same `services:`
list (only the repo's own entries; `repo` may be omitted). A duplicate name or label across files is an error, and a
registry that does not parse or validate FAILs the check.

**A clash fails in the adding repo, before the merge.** `bun ~/SourceRoot/dotfiles/scripts/mini-registry.ts lint` reads the
repo's `mini-services.yaml` (`--file F`; `--repo R` names the directory it stands for, default the repo's own name even from
a worktree; `--host` for `config/mini/services.yaml`) in place of the checkout's copy and validates it with every other
registry: a duplicate name, a label or container two rows claim, a need nobody provides. It is static (no probe, no host
refusal) and exits 1 naming both rows. A repo with a `mini-services.yaml` runs it in its `make check`, guarded where the
dotfiles checkout can be absent (CI): `[ ! -f ~/SourceRoot/dotfiles/scripts/mini-registry.ts ] || bun ~/SourceRoot/dotfiles/scripts/mini-registry.ts lint`.
This repo's own file is `make mini-registry-lint`, part of `make check`. Before it, the second row for an existing label
(2026-11-14, `com.jkrumm.agent-workflows-host`) was found only after the deploy, by the next lead's Watch.

## `make mini-ps`

Per service: tier, state (`running`, `stopped`, `not loaded`, `disabled`, `not installed`, `absent`) and the live
footprint against its budget. A loaded interval job between runs is `stopped`; a container whose VM is down is `stopped`.

- **Footprint** is the physical footprint, one `top -l 1 -stats pid,ppid,mem,command` pass, summed over the launchd
  job's process tree. Containers come from `docker stats` of each running Colima profile; a VM from its
  `com.apple.Virtualization.VirtualMachine` process (the first one started after the profile's `limactl hostagent`).
- **Postgres** counts the shared buffers again in every process. A `shared_memory: true` service shows the largest
  process plus the others' private part, each capped at 32 MiB: an estimate, not a measurement.
- **Drift** lists loaded jobs of the label families the registry does not know, jobs whose program path contains
  `/.claude/worktrees/`, plists installed but neither loaded nor registered, registry entries with no plist or
  container (a manual compose service whose project is down is normal, not drift), containers the registry does not know, doors no service claims, and disabled leftovers whose plist is still installed.
- **A dev server** is `running` when a process listens on the port of one of its doors (the port comes from `config/Caddyfile`
  through `scripts/lib/caddy-registry.py`, never a second list); its footprint is the process tree of that listener.
- `FORMAT=json make mini-ps` is the same data for the apps page, with `can_start`, `can_stop` and `idle_minutes` per row.
- **Leftovers are findings.** `mini-registry check` (so `make doctor` and the heartbeat) warns on a container no row names and on a
  disabled job whose plist is still installed. A container counts by its name in any VM: one that runs in another VM than its row
  declares is the `second-vm` rule's finding, not an unknown container.
- **`make mini-prune`** lists what to remove, `make mini-prune ARGS=--apply` removes it: the plist of every `launchctl disable`d job
  in `~/Library/LaunchAgents` (registered or not: a retired job's row goes with it, its file stays) and every created or exited
  container no row names (never a running one). A retired service ends here: delete its row and its map row, run the prune.

The label families are `com.jkrumm.*`, `com.iu.*`, `ai.hermes.*`, `homebrew.mxcl.*`, `sh.brew.*` and `com.colima.*`.

## `make mini-up`, `mini-down`, `mini-profile`

They run the registered command and nothing else: a name from the command line picks an entry, it never reaches a shell.
An unknown name is refused, and so is stopping a `core` service unless `FORCE=1`. `mini-profile` runs the verb over every
`manual` service of the profile, stopping in reverse order, and runs a command shared by several members once. A single-service verb starts and stops that service only, so the owner repo must have a per-service command: `make -C
~/SourceRoot/vps dev-mariadb-up` stops only mariadb with `dev-mariadb-down`. (`make up` there also starts redis, and `make down`
removes the whole dev project; an earlier version of the registry used them and started redis by accident.) A service with
no such command has none registered and the verb refuses. `mini-profile` runs the commands of its members, one by one.

## Apps page

`https://apps.mini.jkrumm.com` lists every registry service by tier with its state, footprint against budget and a Start or
Stop button, and wakes a stopped door. Three pieces, none holding a service list of its own:

| Piece | What it does |
|-|-|
| `mini-apps/app.ts` (`com.jkrumm.mini-apps`, `127.0.0.1:7797`, core) | `GET /_apps/status` (the rows of `mini-ps --format json`, cached 5 s), `POST /_apps/start/<name>` and `/_apps/stop/<name>`, `GET /_wake/` and `POST /_wake/start` |
| `scripts/caddy-tailnet.sh` (generated include) | `/_apps/*` on the landing host, `/_wake/*` on every door host, `handle_errors` on a door's 502, the door log |
| `mini-apps/idle.ts` (`com.jkrumm.mini-apps-idle`, every 120 s under `jobrun`) | stops an idle on-demand dev server |

**The endpoint** runs `mini-registry up|down <name>` as an argv array: a request value picks a registry entry and nothing else,
no value reaches a shell. A change needs `POST`, an `Origin` equal to `Host` (and `Sec-Fetch-Site` same-origin when sent), and a
name the registry holds; a `core` service is never stopped from here and a verb with no registered command is refused (409).
Each change logs the caller address (`X-Forwarded-For`, set by Caddy) and the verb. It listens on 127.0.0.1 only; the ACL of the
wildcard tailnet door is the only way in, as for the page.

**The wake.** An app that is not running makes its upstream answer 502; Caddy's `handle_errors` hands exactly that 502 (not a
`/_up` probe, not the landing host) to the endpoint with the door's `Host`:

| Service | Answer |
|-|-|
| `on-demand` with a `start` command | starts it (once, a second request joins the first) and answers a 503 page with `X-Wake: 1` that reloads when the door answers without the header; a failed start shows its log (`~/Library/Logs/mini-apps/<name>.log`) and is not retried for 30 s |
| `manual` | the same page with a Start button; a manual service is never started by a request |
| `core` | a plain 502, nothing starts |
| no `start` command, or no service for that door | a page saying so, or a 502 |

Only `GET` starts anything. A `GET` that starts a service is by design ("open the door and the app comes up"); the cost of a
request from a page that should not send it is one idle window of a dev server. Only the tailnet doors wake: `.test` is the
MacBook's own door and stays plain.

**Starting a dev server** runs its registered `start` command detached (its own process group, output in
`~/Library/Logs/mini-apps/<name>.log`) and waits up to 60 s for a door port to answer. A dev server with a `start` and no
`stop` command ends by signal: its recorded process group, else the trees under the listeners of its doors, SIGKILL after 5 s.
One with no `start` command is never signalled (a door port may belong to something else, a docker forwarder for `rollhook`),
so neither the page, the idle stop nor `mini-down` stops it. `make mini-up
NAME=<dev server>` and `mini-down` do the same from a terminal.

**The idle stop** reads `caddy-doors.log`: the wildcard block writes one JSON line per request to a door (mode 0644, because
Caddy's main access log is root-only), skipping the landing host, `/_up`, `/_wake` and `/_apps`. A running on-demand dev server
whose newest request and first-seen time are both older than its `idle_minutes` is stopped. With no door log the job stops
nothing. The check for the pieces: `make mini-apps-test` (hermetic), `make mini-apps-check` (live), `make caddy-tailnet-test`.

**Which dev servers start.** Registered with a `start` command (the repo's own `package.json` script, no change to any app):
`basalt-playground`, `basalt-marketing`, `jkrumm-com`, `sy-serendipity`, `sy-serendipity-codex`. Without one, so the door wakes
nothing and the page says so: `argo-dev` (its dev API refuses to boot on the mini, `live-guard.sh`), `fpp` (four ports and
logdy), `fpp-next` (three ports), `rollhook` (a docker compose stack), `plannotator` (started by `rv`). Leads still validate against built output and
never start a dev server; the wake is for the owner's browser.

## Process type

A launchd job with no `ProcessType` gets "light resource limits ... throttling its CPU usage and I/O bandwidth"
(`man launchd.plist`). Measured with `ps -o pri=` on 2026-11-14: such a job runs at priority **20**, a job with
`ProcessType` Interactive at **31**, the same as everything a terminal starts (every agent and every test). With all
cores taken by priority-31 work, the services those wait on get almost no CPU: at load 200 the factory Console answered 502,
its stop took 27.9 s on Postgres lock timeouts and a read of Postgres timed out after 88 s.

| Rule | |
|-|-|
| A core service others or a request path wait on | `ProcessType` Interactive, and `process_type: interactive` in its registry entry |
| A scheduled job | unset or Background: it should yield |
| A tenant app the owner uses | unchanged, unless it is measured to starve |

`process_type` is only accepted on a `core` launchd service. It is a promise the check holds the plist to, twice:

- **Running lower:** the main process of a running service (the job's pid; for a system daemon the oldest process named
  `process:`) has a `ps -o pri=` below 31 → `FAIL runs below its declared process type`. The job was loaded before the key
  was in its plist; reload it.
- **The file lost the key:** the plist launchd will read at the next start has no `ProcessType` Interactive → `FAIL plist
  has no ProcessType`. This is what a brew rewrite looks like while the process still runs at 31.

`make mini-ps` shows the priority in a `PRI` column (`BELOW-BAND` marks a miss); `FORMAT=json` carries `pri`, `process_type` and
`below_band`. A stopped service has no priority to grade, but its plist file is still checked: the next start would lose the band. Both findings are FAIL in `make doctor` and the heartbeat's `check_registry`.

A repo declares it in its own `mini-services.yaml` and puts the key in the plist it renders; the registry never writes a plist.
Postgres is the exception that proves why the check exists: brew writes its plist, so the key has a converge step
(`docs/postgres.md` §Process type).

Measured 2026-11-14 before this change (`ps -o pri=` of the main process, 31 = Interactive): the factory server, its
door, agent-workflows-host, research-chrome (on demand) and Postgres at 31 (the factory's own plists and the owner's hand
edit of Postgres had landed that evening); every other core job at 20 (a timer between runs has no process); `walkingpad` at 37.
Declared Interactive here: Postgres, software-factory, factory-door, agent-workflows-host, kuma-door, collie, hc-events,
hc-resume. Left at 20 on purpose: Caddy, dnsmasq and tailscaled (system daemons at 20; their plists are root-owned and a
restart drops every door or the tailnet, so a sudo step of the owner's: `caddy/caddy.plist.template` carries the key and
`make caddy-boot-order` applies it), colima (a restart takes Docker down), the agw gateway and audio (agent-workflows' plists:
signal filed), hermes, argo, iris, modelpick, rb, finances, linewatch, the home jobs and the teamchat jobs (tenant apps, or
another repo's plist, not measured to starve).

## Where the findings go

| Finding | `make doctor` | Heartbeat `check_registry` (detail monitor, routed to dotfiles at the factory door) |
|-|-|-|
| a loaded job the registry does not know | FAIL | FAIL, the factory files an Issue |
| a job whose program is inside a worktree | FAIL | FAIL |
| a registry that does not parse or validate | FAIL | FAIL |
| a service running below its declared `process_type`, or whose plist lost it | FAIL | FAIL |
| a breach of a run rule (`rules/run-on-mini.md`) with no `debt`/`exception` on its entry | FAIL | FAIL |
| a `debt`/`exception` field whose breach is gone | FAIL | FAIL |
| the `memory_mib` budgets of a VM's core services add up to more than the VM's budget (a `mem_limit` cap is a ceiling, not counted) | WARN | WARN |
| a footprint above its budget | WARN | WARN (named in the message) |

A job installed by hand and never registered is exactly this FAIL: it turns the detail monitor DOWN until its row lands
(2026-11-14: `kiri-sample`, `orb.corpus-extend`, `orb.corpus-obs`; 2026-11-15: `orb.site-record`). Register at install time, in the same commit as the
architecture row.

## Budgets

Budgets start at 1.5 times what each job used on 2026-11-14 (50 MiB for a timer between runs). They exist to make a
leak visible, not to cap anything. A budget that keeps warning is a number to raise, with the reason in the commit.
Postgres carries a 2 GiB budget (the estimate swings 1.3 to 1.55 GiB) since row `pg-buffers` set `shared_buffers` to 512 MB (it was 3.5 GiB).

## Run rules

`rules/run-on-mini.md` is the ruling (five placement questions, tiers, the never list); the skill `mini-service` is the procedure.
The check is `ruleBreaches` in `scripts/mini-registry.ts`:

| Rule | A breach is | Read from |
|-|-|-|
| `restart-policy` | `always` or `unless-stopped` on a compose container whose tier is not `core` | `docker inspect` |
| `no-memory-limit` | a compose container with no `mem_limit` | `docker inspect` |
| `port-binding` | a published port whose host address is not 127.0.0.1 | `docker inspect` |
| `second-vm` | a `vm` entry for any Colima profile but `default` | the registry |
| `shared-infrastructure` | a Postgres, Redis, Valkey, KeyDB or Memcached image in a compose container, a second native Postgres, a second native cache | `docker inspect`, the registry |
| `no-budget` | `memory_mib: 0` on anything but a `static` entry or a `oneshot` | the registry |
| `worktree-program` | a loaded job whose program is inside `/.claude/worktrees/` | the plist |

A container is judged once it exists, so a manual project that is down is not graded, and its debt field is not called stale
meanwhile. `make mini-ps` ends with the `RUN RULES` section; `bun scripts/mini-registry.ts debt` prints the recorded list, which
`make doctor` shows under the registry check. A KeepAlive agent that polls in a loop cannot be told from a server here: the
`keepalive-poll` record is declared by hand and left to the factory's hygiene probe.
