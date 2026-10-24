# 7. Projects

Every repo is a project with the same shape, so the factory, CI, agent-gateway and you all run the
same commands everywhere. v1's manifest schema (`design/model.md` §6) and directory contract (§6.1)
carry over; v2 adds the make contract and per-path autonomy.

## `project.yaml`

```yaml
apiVersion: factory/v2
name: weatherorb
class: fleet            # fleet → a mother; session → a fresh worker per task
owner: personal         # personal | work (IuRoot: never monitored)
deploy:
  mode: auto            # auto: a push deploys (RollHook / CI) · make: the factory runs `make deploy`
                        # agentic: deploying needs an agent (migrations, manual steps) · none: library
  targets: [{ name: prod, host: vps, verify: https://weatherorb.example.com/health }]
ship:                   # autonomy, first match wins
  - { paths: ["**"], mode: auto }          # auto: merge + deploy when the ladder passes
  # - { paths: ["src/domain/**"], mode: pr }   # pr: open the PR, stop
  # - { paths: ["**"], mode: propose }         # propose: plan only
signals:
  kuma: [weatherorb-web, weatherorb-api]
  hyperdx: { service: weatherorb-api }
  umami: { website: weatherorb }
heal:
  - { when: kuma.down, grace: 5m, runbook: make restart, max: 2 }
jobs: [deps, docs, code-health, upstream-basalt, security]
```

The drift check runs in CI and in the factory: schema valid, every integration key resolves, every
make target the contract requires exists (`make -n`), every runbook command parses. A repo without a
valid manifest gets an Issue, not a silent skip.

## The make contract

Every repo implements the targets that apply to it. CI calls them, the factory calls them,
agent-gateway's `check` and `review` call them — one definition of "it works" per repo.

| Target | Means | Changeset-aware |
|-|-|-|
| `make check` | format check, lint, type check | yes: `BASE=<ref>` limits to files changed since `BASE` (default: merge-base with the default branch) |
| `make test` | unit and integration tests | yes where the runner supports it (`vitest --changed`, `bun test` on changed packages); full on `BASE=` empty |
| `make quality` | static analysis: duplication, dead code, size, complexity (fallow) | yes |
| `make deploy` | deploy the current commit to `TARGET` (default prod); records a Deploy with the artifact digest | — |
| `make verify` | post-deploy smoke against the running target: health, version matches the deployed digest | — |
| `make logs` | recent logs of the running target | — |
| `make status` | running or not, which version | — |
| `make restart` | restart the running target (runbook target) | — |

`check`, `test` and `verify` exit non-zero on failure and print a one-line summary last, so agents and
the ship step read the verdict without parsing tool output. A repo that has no deployable target
omits `deploy`, `verify`, `logs`, `status` and `restart` and says `deploy.mode: none`.

Today several repos already follow most of this (Argo: `check`, `deploy`, `verify`, `logs`). W4
fills the gaps from per-type templates (`factory project new <name> --type bun-service|vite-app|
library|infra|vault`).

## Directory contract

```
project.yaml          the manifest
AGENTS.md             hand-written prose + a generated block (routing, make targets, links)
docs/waves/           wave plans (prose + task ids; state lives in the factory)
docs/adr/             decisions
docs/artifacts/       reports and plans submitted for review
docs/notes/           the mother's durable notes for a fresh wake
.factory/             local cache, git-ignored
```

No CLAUDE.md anywhere. Holdout scenarios never live in the repo they judge.

## Fleet and session

| Class | Projects | How work runs |
|-|-|-|
| fleet | basalt-ui, argo, weatherorb, shutterflow, factory | a mother per project, woken per Task, may fan out workers |
| session | dotfiles, agent-gateway, research-gateway, audio-gateway, email-gateway, image-gateway, hermes-agent, usage-tracker, brain, homelab, homelab-private, vps, jkrumm.com, rollhook, free-planning-poker, linewatch, rb, sy-serendipity, … | a fresh worker per Task |
| work (IuRoot) | prometheus-scripts, StudentEnrolment, prometheus-epx, … | only what you start; not monitored |

v1's rule (≥ 10 planned units in 90 days and ≥ 25 commits a week) still decides fleet; warden's slot
goes to `factory`, and dotfiles moves to session at your call. Promoting a project is one line in its
manifest.

## Work repos

`project.yaml` for IuRoot repos lives in `dotfiles-private/projects/<repo>/`, linked in and excluded
from git there, so nothing factory-specific lands in a work repo. Autonomy by your rule:

| Repo / paths | Mode |
|-|-|
| prometheus-scripts | auto-merge when checks pass |
| StudentEnrolment data-analysis paths | auto-merge when checks pass |
| domain code everywhere else | `pr`: open the PR, stop |

The factory never ingests signals from work repos and never starts work there on its own.

## Homelab-private

Stays self-contained: its manifest lives inside homelab-private, its signals reach the factory under
its own project name, and nothing about its services appears in any other repo's generated files.
