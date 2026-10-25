# 7. Projects

Every repo is a project with the same shape, so the factory, CI, agent-gateway and you run the same
commands everywhere.

## `project.yaml`

```yaml
apiVersion: factory/v2
name: weatherorb
deploy:
  mode: auto               # auto: a push deploys · make: the lead runs `make deploy`
                           # agentic: deploying needs an agent · none: nothing to deploy
  targets: [{ name: prod, host: vps, verify: https://weatherorb.example.com/health }]
  hold: 30m
  migrations: [apps/api/drizzle/]   # additive ships like code; dropping data is a decision
  probes:                  # user journeys, pass or fail; never edited inside a fix
    - { name: forecast-loads, http: https://weatherorb.example.com/api/forecast?q=berlin, expect: 200 }
ship:                      # first match wins
  - { paths: ["**"], mode: auto }          # auto: the lead merges and deploys once its checks pass
signals:
  kuma: [weatherorb-web, weatherorb-api]
  hyperdx: { service: weatherorb-api }
  umami: { website: weatherorb }
heal:
  - { when: kuma.down, grace: 5m, runbook: make restart, max: 2 }
jobs: [deps, docs, code-health]
ticktick: { list: WeatherOrb }
```

A drift check runs in CI and in the factory: valid against the published JSON Schema, every
integration key resolves, every make target and runbook parses. A broken manifest becomes an upkeep
Issue, never a silent skip, and the factory keeps running on the last valid version (Warp's rule).

## The make contract

| Target | Means | When it lands |
|-|-|-|
| `make check` | format, lint, types | W1 for the factory and the first repos leads ship to; W4 for every repo with signals or Issues |
| `make test` | tests | same |
| `make deploy` | deploy the current commit to `TARGET`; records the deploy | same, deployable repos |
| `make verify` | post-deploy smoke: health, the deployed version, the project's key checks | same, deployable repos |
| `make restart` | restart the running target — the first runbook | W1 for the homelab; W4 for the rest |
| `make quality` | duplication, dead code, size (fallow) | W6, with the code-health job |
| `make logs` / `make status` | recent logs; running or not, which version | when a runbook or Argo needs them |

`check`, `test` and `quality` accept `BASE=<ref>` to limit work to the changeset (default: the
merge-base with the default branch); full runs on `BASE=` empty. Every target ends with a one-line
verdict, so leads and the factory read the result without parsing tool output. The contract is
built in the order it is used: a repo is onboarded when it first has signals or Issues, with the
targets that path needs. Leads use the contract; the factory itself only runs `restart` (runbooks) and
`verify` (after the hold).

## Directory contract

```
project.yaml     the manifest
AGENTS.md        prose + a generated block (routing, make targets)
docs/waves/      initiative plans: prose and Issue ids, the orchestrator's memory between wakes;
                 state lives in the factory
```

No CLAUDE.md anywhere.

## Factory projects and plain repos

| Kind | Repos | What happens there |
|-|-|-|
| Factory project | every repo with a `project.yaml`: the homelab from W2, then each repo as it gets signals or Issues (W4) | intake, leads, initiatives, the hold, probes, learning |
| Plain repo | the brain, your website and anything else without a manifest | nothing automatic; you work in herdr sessions, and Hermes starts one for you on request |
| Work | IuRoot: not in W1–W6 | — |

Adding the manifest makes a repo a factory project; the minimal one is four lines.

## TickTick and the brain

- **TickTick** stays your list of things only you can do. A project's manifest names its list; Argo
  shows the open items on the project page, and an item tagged `#factory` becomes a request. When an
  Issue needs a human hand (a payment, a login, a cable), the factory adds an item to that list,
  linked back to the Issue.
- **The brain** keeps one page per project (`brain/Projects/<project>.md`). The factory writes only its
  *Changelog* section, compiled daily by a cheap model from the leads' three-line summaries (§9).

## Work repos

IuRoot manifests live in `dotfiles-private/projects/<repo>/`, linked in and git-excluded, so nothing
factory-specific lands in a work repo. The factory never reads their signals or starts work there.
Your own sessions follow a path-scoped rule in dotfiles (W4), not a file in the work repo: in
prometheus-scripts and in StudentEnrolment's data-analysis paths, merge your own merge request once
`make check` and `make test` pass; in domain code, open the merge request and stop.

Later, perhaps: the factory tracks the lifecycle of waves you start in a work repo, with no signals and
no triage. Not before the 14 days of observation; it would add a second account world to a factory
that has to prove itself first.

## homelab-private

A session project that stays self-contained: its manifest lives inside homelab-private, and nothing
about its services appears in any other repo's generated files.
