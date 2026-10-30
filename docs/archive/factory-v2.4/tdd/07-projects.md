# 7. Projects

Every repo under `~/SourceRoot` is a project and takes requests. A manifest adds automation, and the
make contract gives every repo the same shape, so the factory, CI, agent-gateway and you run the same
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
ship:                      # how the lead merges, per path; first match wins
  - { paths: ["**"], via: push }           # push: rebase and push to the default branch
                                           # pr: a pull request the lead reviews and merges itself
signals:
  kuma: [weatherorb-web, weatherorb-api]
  hyperdx: { service: weatherorb-api }
heal:
  - { when: kuma.down, grace: 5m, runbook: make restart, max: 2 }
jobs: [deps, docs, code-health]
leads: 1                   # leads at once in this repo; 1 without a manifest
ticktick: { list: WeatherOrb }
```

`deploy.mode` says how a merged change reaches production; `ship` says how it is merged. Both are
the lead's to carry out, never a gate for you. W1b ships v0 of the schema (name, `deploy`, `ship`,
`leads`, hold, probes) and W4 extends it. A drift check (`factory project check`, W4) runs in CI and
in the factory: valid against the published JSON Schema, every integration key resolves, every make
target and runbook parses. A broken manifest becomes an upkeep
Issue, never a silent skip, and the factory keeps running on the last valid version (Warp's rule).

## The make contract

| Target | Means | When it lands |
|-|-|-|
| `make check` | format, lint, types | W1b for the factory, dotfiles, jkrumm.com and weatherorb; W4 for every repo with signals; a repo without a manifest uses the targets it has |
| `make test` | tests | same |
| `make deploy` | deploy the current commit to `TARGET`; records the deploy | same, deployable repos |
| `make verify` | post-deploy smoke: health, the deployed version, the project's key checks | same, deployable repos |
| `make restart` | restart the running target — the first runbook | W2 for the homelab; W4 for the rest |
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

## Every SourceRoot repo takes requests

The factory reads and writes only `~/SourceRoot`. A repo needs no manifest to take work; the manifest
adds automation.

| The repo has | What the factory does there |
|-|-|
| no `project.yaml`: the brain, your website, any repo under `~/SourceRoot` | requests only: you, Hermes or a GitHub issue file one, and a lead takes it; one lead at a time; done means the commit or the document |
| a minimal `project.yaml`: a name and how it deploys | the same, plus deploy evidence, the hold and `make verify`; `leads` allows several at once |
| a full `project.yaml` | signals, runbooks, probes, jobs and a TickTick list as well |

A single request wakes the orchestrator only if its lead stalls (§5), so work in a repo without a
manifest is one lead per request. The herdr sessions you start yourself stay
outside the factory, as today; the factory never sees them.

## TickTick and the brain

- **TickTick** stays your list of things only you can do. A project's manifest names its list; Argo
  shows the open items on the project page, and an item tagged `#factory` becomes a request. When an
  Issue needs a human hand (a payment, a login, a cable), the lead reports `factory issue block
  --human "<what>"` and the factory adds an item to that list, linked back to the Issue (W2).
- **The brain** keeps one page per project (`brain/Projects/<project>.md`). The factory writes only its
  *Changelog* section, compiled daily by a cheap model from the leads' three-line summaries (§9).
  homelab-private gets no brain page.

## IuRoot stays outside

The factory never reads IuRoot's signals, files its Issues or starts work there; IuRoot is the
ground of your AthenaTeamchat work. Whether IuRoot needs agent instructions of its own is that work's
question, not the factory's: a lead's standing orders travel in its brief (§4), so the factory needs
no root-level instruction file.

## homelab-private

A session project that stays self-contained: its manifest lives inside homelab-private, and nothing
about its services appears in any other repo's generated files.
