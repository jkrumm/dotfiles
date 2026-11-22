# config/mini — service registry

`config/mini/services.yaml` (+ a `mini-services.yaml` at any repo's root) lists every launchd job, container, VM and
dev-server door with owner repo, tier, memory budget and start/stop verbs — `docs/mini-registry.md`. A new job goes in
the registry in the same commit as its plist (the doctor fails on a loaded job it does not know and on a program inside
`/.claude/worktrees/`; the heartbeat component `check_registry` files the same finding as an Issue).

| Tier | Rule |
|-|-|
| `core` | always on (herdr-core, factory, agw, Postgres, Caddy, hermes, home, iris, argo, finances, rb, schedules, the work stack: VPN, teamchat sandbox) |
| `on-demand` | starts on the first request, stops idle (dev servers behind `.test` doors, research-chrome) |
| `manual` | a profile starts it: `work` (the student-enrolment containers), `dev-db` |

**Run rules** (`rules/run-on-mini.md`, skill `mini-service`): five placement questions, a tier and a budget per entry, a never
list (second Postgres or VM, `restart: unless-stopped` outside core, no `mem_limit`, a port off 127.0.0.1, a program in a worktree,
a Postgres or cache image in a container). `make mini-ps` and `make doctor` FAIL on a breach with no record; a record is
`debt: { <rule>: <plan row> }` or `exception: { <rule>: <reason> }` on the entry, FAILs once stale, and prints with
`mini-registry debt`. The doctor never reads compose files; the factory's weekly hygiene probe does.

`make mini-ps` (`FORMAT=json`) · `make mini-up NAME=` · `make mini-down NAME=` (core needs `FORCE=1`) · `make mini-profile NAME=work|dev-db UP=1|0`.
