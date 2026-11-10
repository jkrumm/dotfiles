---
type: Concept
title: The agent platform
description: One worker engine (agent-workflows), one conversational front door (Hermes), one human cockpit (the Herdr app on herdr-core), two lanes (factory Issue, `@implementer`), one repo contract — the design and its status table. Alerts go to Slack and nothing auto-heals; the autonomous remediation loop is archived. The page a new agent reads first.
aliases:
  - agent-estate-model
tags:
  - engineering
  - agents
  - moc
timestamp: 2026-10-04
---

# Agent platform

**Verdict:** one worker engine (agent-workflows), one conversational front door
(Hermes), one human cockpit (the Herdr app on herdr-core). Every repo describes itself through the same
four Make targets and four AGENTS.md sections, so no central component holds
per-repo knowledge. Trust comes from the infrastructure (Tailscale, the owner's
GitHub account); the only gates left are quality gates. Alerts go to ntfy (Slack for Kuma and HyperDX until they move) and a
human acts; there is no autonomous remediation loop.

STATUS: adopted 2026-10-02, landed as of 2026-10-10 (setup round 4 closed the
rename of the worker engine and OpenCode as the worker default). The autonomous remediation
loop was switched off 2026-10-27 by agent-workflows P0; its design and the
status rows that described it are in
`docs/archive/agent-platform-2026-10-warden-era.md`. The workflow platform (`agw`,
agent-workflows) is built; `docs/agent-workflows/concept.md` is its design record. This page wins over any older
doc that contradicts it; open work is the factory's Issues and each repo's `docs/plan.yaml` (skill `factory`).
Before-the-rewrite design: [[agent-platform-history]].

| Part | State |
|-|-|
| Lanes (Issue, `@implementer`), lean global CLAUDE.md, the factory CLI describing its own Issue filing contract (`factory issue schema`), OpenCode parity | **landed** (dotfiles W1–W2) |
| Repo contract (`check`/`deploy`/`verify`/`logs` + AGENTS.md sections) | **landed** across the repos in dotfiles W3; commits in direct-to-master repos not yet pushed, PRs open for PR-required ones |
| Worker engine: model registry, review angles, one source for model ids | **landed**, now in agent-workflows (the predecessor service retired 2026-10-29, Wave 11) |
| Hermes: loop stopped, one reporting voice, ~20 skills | **landed** (hermes-agent W1–W3) |

## The picture

```
 alerts                                front doors
 Kuma · HyperDX/OTel alerts            Herdr: the owner's tabs         (owner drives)
 jobs-grade (job failures)             Hermes: Slack/Argo chat               (narrate, answer)
        │                                   │
        ▼                                   │ opens a Herdr tab when asked
 ntfy alerts → a human reads and acts     ▼
                                       factory Issue · @implementer

 AGENT-WORKFLOWS (`agw`): check · review · research · prose · diagram · brain
           model ids live ONLY in `agw routes`

 core      ~/.claude (global CLAUDE.md, skills, agents) + per-repo AGENTS.md + Makefile
           read identically by Claude Code and OpenCode
```

## Roles — one verb each

| Component | Does | Never does |
|-|-|-|
| **agent-workflows (`agw`)** | `check`, `review`, `prose`, `diagram` and `brain` (`agw check`, `agw review`, `agw prose`, `agw diagram`, `agw brain`) | decide what to work on, merge |
| **Hermes** | answers, narrates, opens Herdr tabs when asked | dispatch on its own, land PRs, author skills unattended |
| **Herdr app + `rd`** | the owner's cockpit: his own `rd work` tabs and the factory's agents, side by side | run unattended work |
| **Argo** | the status surface | hold state of its own |

## The lanes — the only ways to start agent work

| Lane | When | Engine |
|-|-|-|
| Issue (`factory issue new`) | work for a repo that should ship on its own | the software factory: its lead builds, reviews, deploys and verifies (`factory issue list` follows it); no factory, no Issue |
| `@implementer` | edit must land in this session's live tree | native subagent, Sonnet |

Deleted: `agent-dispatch`, `rd bg`, the "colleague" lane, raw `claude --bg`,
Hermes kanban/delegation, Hermes hand-merging PRs.

## Repo contract — how agents learn a repo

Every repo with a runtime ships:

| Make target | Contract |
|-|-|
| `make check` | all local validation; non-zero on failure; no side effects |
| `make deploy` | ships the merged default branch; for CI-deployed repos prints `deployed by CI on push` and exits 0; self-hosting repos (agent-workflows, hermes-agent) roll back to the previous commit if their own health check fails |
| `make verify` | probes production; exit 0 = live and healthy |
| `make logs` | bounded tail of production logs, then exits |

AGENTS.md carries exactly these sections, in this order, among its own:
`## Validate` · `## Deploy` · `## Verify & Monitor` (full health URL, Kuma
monitor name, OTel `service.name`) · `## Gotchas`.

## No headless claude

No script, skill or service runs `claude -p`. Interactive sessions in herdr-core terminals, native
subagents and `agw` workflows are the only lanes. Model ids and per-job routing live in
`agw routes`, never in prose.

The only headless runs, kept on purpose:

- `scripts/claude-accounts-e2e.sh` (`make claude-accounts-e2e`) — tests the launchers
  themselves, a few Haiku tokens per account.
- modelpick's bench (`modelpick/src/server/bench/`) — it measures the Claude Code harness,
  so it has to drive the real binary.

## Where API tokens are spent

The **inference gateway** (`agent-workflows/packages/gateway`, loopback `:7794`, LaunchAgent
`com.jkrumm.agent-workflows-gateway`). It holds the personal IU key and one API key per Claude Console org
(`iu`, `me`, `me2`); `agw`, its OpenCode server, Hermes, dotfiles `oc` and modelpick hold none and reach every model
through it with their own door token (`~/.agent-workflows/data/door-tokens`). The three subscriptions grant a monthly API
credit that expires unspent otherwise; a Claude call spends the soonest-expiring org's credit first, then IU. Claude Code
and Athena Teamchat stay outside it, and a Claude-Code-shaped request never uses a credit org. Every request is one
`usage.records` row (`source='gateway'`) and one pick row. Design: agent-workflows `docs/gateway.md`; pools and their
state: `docs/claude-accounts.md` §Platform; where the keys live: `docs/architecture.md` §Secrets flow.

The one exception is the Codex lane (`cx`, `cxa`, `astra`): its launcher still resolves the personal IU key itself
(`config/zsh/codex.zsh`) and codex calls IU directly.

Development sessions still run on the Max subscriptions only (`rd`, Herdr); the gateway serves workflow steps, review,
research, Hermes and `oc`.

## Hermes — the front door

- Answers and narrates; opens a Herdr tab when the owner asks for one.
- Reaches its models through the inference gateway, with its own door token.
- Mentions-only in #agents.
- Skill creation by the background nudge is off; ~20 curated skills.

## Herdr — the cockpit

The factory's agents show in the app as tabs; the owner steers his own with `rd work <repo>` (a session of his, not a lane an agent starts).
Nothing polls. Waiting is one of three, by who spawned:

| Spawned through | Wait with |
|-|-|
| The factory | nothing: a lead ends its turn after `factory issue defer` and the factory wakes it; anyone else follows with `factory issue list` / `factory read chain` |
| `hc run` / `rd` hc-direct, with the caller as parent | `hc wait --children all\|any`; hc also types a note into the parent when a child finishes, blocks or exits |
| A single terminal | `hc wait <t>` (`--output X` for a program), never `sleep` |

The factory babysits (resume after a quota wall, send-back, blocked notes, the wake); `hc-resume` restores Claude sessions after
a lost program.

## Notifications

Background-job failures (`jobs-grade --ntfy`) go to ntfy topic `alerts`, and the human-queue nudge to topic
`factory`, both on the iPhone and the Mac; Uptime Kuma and HyperDX alerts still go to Slack `#alerts` until their own
moves. A human reads and acts. Source model and thresholds: `docs/ops-signals.md`.

## Open facts to verify

- DeepSeek flash rates conflict (the retired service's registry 0.15/0.6 vs modelpick 0.50/1.50
  per MTok) — re-probe before cost claims.
- the newest GPT ids, DeepSeek Pro, kimi, minimax on the OpenAI leg are declared but
  never probed — the registry refuses them until verified.
