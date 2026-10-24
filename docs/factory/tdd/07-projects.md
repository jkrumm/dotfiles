# 7. Projects

Every repo is a project with the same shape, so the factory, CI, agent-gateway and you run the same
commands everywhere.

## `project.yaml`

```yaml
apiVersion: factory/v2
name: weatherorb
class: fleet               # fleet: has a mother for multi-wave plans · session: workers only
deploy:
  mode: auto               # auto: a push deploys · make: the factory runs `make deploy`
                           # agentic: deploying needs an agent · none: nothing to deploy
  targets: [{ name: prod, host: vps, verify: https://weatherorb.example.com/health }]
  hold: 30m
  migrations: [apps/api/drizzle/]   # additive ships like code; dropping data is a decision
ship:                      # first match wins
  - { paths: ["**"], mode: auto }          # auto: merge + deploy when verification passes
signals:
  kuma: [weatherorb-web, weatherorb-api]
  hyperdx: { service: weatherorb-api }
  umami: { website: weatherorb }
heal:
  - { when: kuma.down, grace: 5m, runbook: make restart, max: 2 }
jobs: [deps, docs, code-health]
ticktick: { list: WeatherOrb }
```

A drift check runs in CI and in the factory: valid schema, every integration key resolves, every
make target and runbook parses. A broken manifest becomes an upkeep Issue, never a silent skip.

## The make contract

| Target | Means | When it lands |
|-|-|-|
| `make check` | format, lint, types | W2 for the factory and the first repos it ships to; W4 for every repo with signals or Tasks |
| `make test` | tests | same |
| `make deploy` | deploy the current commit to `TARGET`; records the deploy | same, deployable repos |
| `make verify` | post-deploy smoke: health, the deployed version, the acceptance checks | same, deployable repos |
| `make restart` | restart the running target — the first runbook | W1 for the homelab; W4 for the rest |
| `make quality` | duplication, dead code, size (fallow) | W6, with the code-health job |
| `make logs` / `make status` | recent logs; running or not, which version | when a runbook or Argo needs them |

`check`, `test` and `quality` accept `BASE=<ref>` to limit work to the changeset (default: the
merge-base with the default branch); full runs on `BASE=` empty. Every target ends with a one-line
verdict, so agents and the ship step read the result without parsing tool output. The contract is
built in the order it is used: a repo is onboarded when it first has signals or Tasks, with the
targets that path needs.

## Directory contract

```
project.yaml     the manifest
AGENTS.md        prose + a generated block (routing, make targets)
docs/waves/      wave plans: prose and task ids; state lives in the factory
docs/notes/      fleet only: the mother's notes for a fresh wake
```

No CLAUDE.md anywhere.

## Fleet and session

| Class | Projects |
|-|-|
| fleet | basalt-ui, argo, weatherorb, shutterflow, factory |
| session | dotfiles and every other SourceRoot repo |
| work | IuRoot — not monitored, never touched by the factory |

Promoting a project is one line in its manifest.

## TickTick and the brain

- **TickTick** stays your personal list. A project's manifest names its list; Argo shows the open items
  on the project page, and an item tagged `#factory` becomes a request.
- **The brain** keeps one page per project (`brain/Projects/<project>.md`). The factory writes only its
  *Changelog* section, grouped from conventional commits — no model involved.

## Work repos

IuRoot manifests live in `dotfiles-private/projects/<repo>/`, linked in and git-excluded, so nothing
factory-specific lands in a work repo. The factory never reads their signals or starts work there.
Your own sessions follow a path-scoped rule in dotfiles (W4), not a file in the work repo: in
prometheus-scripts and in StudentEnrolment's data-analysis paths, merge your own merge request once
`make check` and `make test` pass; in domain code, open the merge request and stop.

## homelab-private

A session project that stays self-contained: its manifest lives inside homelab-private, and nothing
about its services appears in any other repo's generated files.
