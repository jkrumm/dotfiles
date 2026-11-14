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
| Checked by | `make doctor` (section *Service registry*) and the heartbeat component `check_registry` |

## Tiers

| Tier | Rule | Members today |
|-|-|-|
| `core` | always on | herdr-core, the factory, agent-workflows, Postgres, Caddy, hermes, the home jobs, iris, argo, finances, modelpick, linewatch, rb, the schedules, the teamchat api and broker |
| `on-demand` | starts on the first request, stops after an idle window | dev servers behind `.test` doors (basalt, rollhook, fpp, ...), the teamchat sandbox and its VM, `research-chrome` |
| `manual` | started and stopped as a profile | `work` (VPN, dashboard, token minters, deploy gates), `dev-db` (mariadb, redis, clickstack); weatherorb's disabled jobs have no profile |

A tier is a promise the registry holds, not yet one the host keeps: nothing is moved here. The on-demand wake, the idle
stop and the VM that starts only when a service needs it are the rows that follow (`docs/plan.yaml`: `mini-apps-page`,
`mini-docker-idle`, `mini-work-profile`).

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
| `shared_memory` | Postgres: every process's footprint counts the shared buffers again (below) |
| `start`, `stop`, `status` | The owner repo's own command (`make -C <repo> <target>`; `~/` expands). A launchd job without `start`/`stop` gets `launchctl bootstrap`/`kickstart` and `bootout`; anything else refuses the verb |
| `note` | One line for whoever reads the table |

A repo that adds a job registers it in the same commit: a `mini-services.yaml` at its root with the same `services:`
list (only the repo's own entries; `repo` may be omitted). A duplicate name or label across files is an error, and a
registry that does not parse or validate FAILs the check.

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
  container, containers the registry does not know, doors no service claims, and disabled leftovers whose plist is still installed.
- `FORMAT=json make mini-ps` is the same data for the apps page.

The label families are `com.jkrumm.*`, `com.iu.*`, `ai.hermes.*`, `homebrew.mxcl.*`, `sh.brew.*` and `com.colima.*`.

## `make mini-up`, `mini-down`, `mini-profile`

They run the registered command and nothing else: a name from the command line picks an entry, it never reaches a shell.
An unknown name is refused, and so is stopping a `core` service unless `FORCE=1`. `mini-profile` runs the verb over every
`manual` service of the profile, stopping in reverse order, and runs a command shared by several members once. A single-service verb starts and stops that service only, so the owner repo must have a per-service command: `make -C
~/SourceRoot/vps dev-mariadb-up` stops only mariadb with `dev-mariadb-down`. (`make up` there also starts redis, and `make down`
removes the whole dev project; an earlier version of the registry used them and started redis by accident.) A service with
no such command has none registered and the verb refuses. `mini-profile` runs the commands of its members, one by one.

## Where the findings go

| Finding | `make doctor` | Heartbeat `check_registry` (detail monitor, routed to dotfiles at the factory door) |
|-|-|-|
| a loaded job the registry does not know | FAIL | FAIL, the factory files an Issue |
| a job whose program is inside a worktree | FAIL | FAIL |
| a registry that does not parse or validate | FAIL | FAIL |
| a footprint above its budget | WARN | WARN (named in the message) |

`com.jkrumm.orb.corpus-obs` shows up here on purpose: its program lives in a weatherorb worktree (Issue 1005 owns the
fix), so both FAIL lines name it until that job is installed from a release dir and registered.

## Budgets

Budgets start at 1.5 times what each job used on 2026-11-14 (50 MiB for a timer between runs). They exist to make a
leak visible, not to cap anything. A budget that keeps warning is a number to raise, with the reason in the commit.
Postgres carries 1.5 GiB since row `pg-buffers` set `shared_buffers` to 512 MB (it was 3.5 GiB).
