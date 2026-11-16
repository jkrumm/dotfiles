---
description: Where a service on the Mac mini runs, how it is declared, what never runs there. Five placement questions, tiers, what each kind declares, the never list, what Docker gave and what replaces it, the registry check.
paths: ["**/compose.y*ml", "**/compose.*.y*ml", "**/docker-compose*.y*ml", "**/*.plist", "**/*.plist.tpl", "**/*.plist.template", "**/mini-services.yaml", "**/config/mini/services.yaml"]
---

# Run on the mini

Applies to what runs on the Mac mini. A compose file deployed to the VPS or the HomeLab follows `rules/dockerfile.md` and that
repo's own rules, where `restart: unless-stopped` is right. On 2026-11-14 the mini held 16 GiB in services nobody had placed:
88 plists from ten repos, 18 containers in two always-on VMs, every one `restart: unless-stopped`. Each repo had decided alone.
The procedure is the skill `mini-service`; the registry is `config/mini/services.yaml` (`docs/mini-registry.md`).

## Placing a service

Ask in this order; the first yes decides. Five times no: it does not run on the mini yet, raise a Decision.

| # | Question | Runs as |
|-|-|-|
| 1 | Can it run elsewhere: needs no macOS, home LAN, local files, agent sessions or privacy? | an app on the VPS, or on the HomeLab for home data |
| 2 | Is it only files? | Caddy `file_server`, no process |
| 3 | Does it run and exit on a schedule? | `jobrun` under launchd |
| 4 | Is it our own code that runs on macOS (bun, node, python, go)? | a native launchd service on a 127.0.0.1 port behind a Caddy door |
| 5 | Is it a third-party image or Linux-only? | a compose project in the one VM; always-on only as tier `core`, with the reason in its entry |

A cheaper rung beats a higher one: a rewrite to native is a plan row, never a reason to stay in Docker.

## Tiers

| Tier | Behaviour |
|-|-|
| `core` | runs always and reports a heartbeat, routed at the factory's door |
| `on-demand` | starts on the first request to its door, stops after its idle window. The default for a new service; `core` needs the reason (who reaches it, why it must always answer) in `note` |
| `manual` | started and stopped by a verb or a profile (`work`, `dev-db`) |

## What each kind declares

Every service has one entry in its repo's `mini-services.yaml`: owner, kind, tier and `memory_mib`. The budget is 1.5 times its
footprint after an hour of use, read from `make mini-ps` (`top`'s mem column summed over the process tree). No budget fails the check.

- **Schedule:** `jobrun <label> --owner <repo> --every <s> --timeout <s>`, label `com.jkrumm.<repo>-<job>`, plist template in the owner repo, installed by its `make <x>-setup`. launchd starts it: no door, no start or stop command.
- **Native service:** an installed release directory, a launch script that reads secrets through `secrets-run`, logs under `~/Library/Logs`, a port on 127.0.0.1 and a door in `config/Caddyfile`, its start/stop/status command, a heartbeat when core.
- **Compose project:** `restart: "no"` (core: `unless-stopped` allowed), `mem_limit` on every service, ports on 127.0.0.1, a healthcheck, named volumes for data, `needs: [vm]` in its entry and a make target that starts it. The sum of the limits of a VM's core services fits the VM.
- **Database:** a role and a database in `config/postgres/cluster.yaml`, sized for what its clients measure. **Cache or queue (Valkey, Redis):** one native instance under launchd, like the one Postgres, added by the first service that needs one through its own plan row; later services take a logical database or key prefix. None runs today; do not install one on spec.
- **Browser:** the shared headless Chrome (`shared-chrome ensure`); which browser a suite, a check or a page read gets: `rules/browser.md`. **Heavy tests or builds:** `factory slot run`; the full suites run in CI.

## Never on the mini

- A second Postgres, a second VM or Colima profile, a Postgres or cache image in a compose service (`shared-infrastructure`).
- `restart: always` or `unless-stopped` on an `on-demand` or `manual` service.
- A KeepAlive agent that polls in a loop: a schedule is a schedule.
- A job whose program lives in a worktree.
- A browser MCP registered for a session or a project, or a Chrome per agent outside a test slot.
- A port on 0.0.0.0.
- A dev server left running: its door starts it, the idle stop ends it.
- A long-running compose project started from a worktree. A container a test needs runs inside `factory slot run`, is removed when the step ends and takes its project name from the slot. `hooks/docker-makefile.ts` denies a `make` target whose recipe runs `docker compose up` or `docker run -d` from a worktree in a factory session; it cannot see a target that reaches docker through a script, a variable or a second Makefile.
- Docker as a build tool: a check uses the native toolchain when the mini has one. A run-and-exit container is allowed inside a slot.

## What Docker gave, and what replaces it

| Docker | Native |
|-|-|
| restart policy | launchd `KeepAlive` |
| healthcheck | the service's heartbeat to Uptime Kuma (routed with `factory door route-set`) plus the door's `/_up/<name>` status route; schedules are graded by `jobrun` |
| `depends_on` | none: the launch script checks its dependency (`pg_isready`, a port) and exits non-zero, `KeepAlive` retries |
| isolation, a foreign userland | nothing native: the reason a third-party image stays in Docker |

## The check

`make mini-ps` and `make doctor` (the heartbeat component `check_registry`) grade every registered service. A breach with no record
FAILs, naming service and rule: `restart-policy`, `no-memory-limit`, `port-binding`, `second-vm`, `shared-infrastructure`,
`no-budget`, `worktree-program`. The check reads containers through `docker inspect`, so a compose file is judged once its
container exists; the factory's weekly hygiene probe reads the files.

A breach that exists today is recorded once on the entry: `debt: { <rule>: <plan row or issue> }`, or `exception: { <rule>: <reason> }`
when it is allowed (a dev stack that mirrors production). A field whose breach is gone FAILs as stale: delete it. Build-tool targets
that call docker sit in the `debt:` list at the foot of `config/mini/services.yaml`. A private repo's breaches stay in its own
`mini-services.yaml`. `make mini-ps` and `mini-registry debt` print the list; fixing a row means deleting its field.
