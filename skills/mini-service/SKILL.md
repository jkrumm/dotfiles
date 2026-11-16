---
name: mini-service
allowed-tools: Bash(jobrun --help *)
description: "Add or move a service on the Mac mini: place it, declare it in the registry, wire its files. Use when adding a LaunchAgent or plist, a background job or schedule (jobrun records and grades a run), a compose file or container, a dev server door, a database or cache, or anything that should keep running on the mini; also when `make mini-ps` or `make doctor` names a run-rule breach."
---

# Add a service to the mini

The ruling is `rules/run-on-mini.md` (placement, tiers, never list, the check); this page is the procedure. The registry is
`config/mini/services.yaml` plus a `mini-services.yaml` at the root of the owner repo (`docs/mini-registry.md`).

jobrun wraps a scheduled job (`--owner` takes the repo name), live from the CLI (if you see the command and not its output, run it):

!`jobrun --help 2>&1 || echo "jobrun is not on this machine"`

## 1. Place it

Walk the five questions of the rule in order; the first yes decides. Write the answer and its kind (schedule, native service,
compose project, database) in one line before touching a file. Five times no: stop, raise a Decision (`factory issue ask`).
Tier is `on-demand` unless the entry's `note` says who reaches it and why it must always answer, then `core`.

## 2. Write the files for the kind

| Kind | Files |
|-|-|
| Schedule | a plist template in the owner repo running `jobrun <label> --owner <repo> --every <s> --timeout <s> -- <cmd>`, label `com.jkrumm.<repo>-<job>`; a `make <x>-setup` target that installs and loads it (copy `~/SourceRoot/linewatch/collector/*.plist.template` and its target); log under `~/Library/Logs` |
| Native service | a launch script (secrets through secrets-run, dependency check that exits non-zero, e.g. `pg_isready`), an installed release directory, a plist with `KeepAlive`, a port on 127.0.0.1, a door: `<name>.test { reverse_proxy localhost:PORT }` in `config/Caddyfile`, then `make caddy-tailnet`; start/stop/status as make targets |
| Compose project | `restart: "no"` (core: `unless-stopped`), `mem_limit` and a healthcheck on every service, ports `127.0.0.1:HOST:CONTAINER`, named volumes, no `container_name` clash across repos, make targets for up and down per service (the registry's `start`/`stop` act on one service); the project runs in the default VM |
| Database | a role and a database in `config/postgres/cluster.yaml`, then `make pg-plan` and `make pg-apply` |
| Cache or queue | none installed today. The first service that needs one adds the one native Valkey under launchd through its own plan row; later services take a logical database or key prefix. Never a container per app |

## 3. Declare it

One entry in the owner repo's `mini-services.yaml` (in a new repo, create the file): `name`, `kind`, `tier`, `label` or
`container`, `door`, `needs: [vm]` for compose, `start`/`stop`, and `memory_mib`. The budget is 1.5 times the footprint after an
hour of use: start it, wait an hour, read `make -C ~/SourceRoot/dotfiles mini-ps`, set the number. Never ship 0 or a guess.

Add `bun ~/SourceRoot/dotfiles/scripts/mini-registry.ts lint` to the repo's `make check` (guard it with `[ ! -f … ] ||` where CI has no dotfiles): a name, label or container another registry already claims then fails before the merge (`docs/mini-registry.md`).

## 4. Route the heartbeat

A core service reports a heartbeat: `factory door route-set --source <source> --monitor <monitor> --repo <repo> --issue <id>`
(door token: `factory door token new <source>`).

## 5. Prove it

Done when all hold, each stated in the ship:

- `make -C ~/SourceRoot/dotfiles mini-ps` lists it with its state and footprint under budget;
- `make -C ~/SourceRoot/dotfiles doctor` shows the *Service registry* section with no FAIL for it;
- its door answers (`curl -sf https://<name>.test/` or its `/_up/<name>` status route), and with an on-demand tier it stops again after the idle window;
- a core service's monitor has a route at the factory's door.

A breach the check names (`restart-policy`, `no-memory-limit`, `port-binding`, `second-vm`, `shared-infrastructure`,
`no-budget`, `worktree-program`): fix the file. A breach that cannot be fixed now goes on the entry as
`debt: { <rule>: <plan row or issue> }`, or `exception: { <rule>: <reason> }` if allowed; delete the field when the breach is gone,
the check FAILs a stale one.
