---
type: Concept
title: The agent platform
description: One worker engine (agent-gateway), one autonomous loop (warden), one conversational front door (Hermes), one human cockpit (herdr), four lanes, one repo contract — the target design, its rollout status, and the loop's nine states. The page a new agent reads first.
tags:
  - engineering
  - agents
  - moc
timestamp: 2026-10-04
---

# Agent platform — target design

**Verdict:** one worker engine (agent-gateway), one autonomous loop (warden), one
conversational front door (Hermes), one human cockpit (herdr). Every repo
describes itself through the same four Make targets and four AGENTS.md
sections, so no central component holds per-repo knowledge. Trust comes from
the infrastructure (Tailscale, the owner's GitHub account); the only gates left
are quality gates.

STATUS: adopted 2026-10-02, rolling out (as of 2026-10-04). This page wins over
any older doc that contradicts it; rollout is tracked in each repo's
`docs/waves/PLAN.md`.

| Part | State |
|-|-|
| Four lanes, lean global CLAUDE.md, `rd close`, `/wave` orchestrated mode, OpenCode parity | **landed** (dotfiles W1–W2) |
| Repo contract (`check`/`deploy`/`verify`/`logs` + AGENTS.md sections) | **landed** across the repos in dotfiles W3; commits in direct-to-master repos not yet pushed, PRs open for PR-required ones |
| agent-gateway: model registry, `triage` job, dispatch git safety, `update_pr`, one source for model ids | **landed** (agent-gateway W1–W4); review angles off Max: senior-dev, typescript, qa adopted (frontend stays on Max, measured) |
| Hermes: loop stopped, one reporting voice, ~20 skills | **landed** (hermes-agent W1–W3) |
| warden: gates cut, nine states, one queue | **landed** (W1–W2) |
| warden: intake fingerprint + triage dedup, revisions as attempts | **landed** (W3) |
| warden: merge train, deploy + verify, automatic revert, fixed-by sweep | **landed** (W4); review is not yet delta-only (needs an agent-gateway PR delta scope) |
| warden: docs, loop split into modules, own `check`/`deploy`/`verify`/`logs` | **landed** (W5) |

## Why this rewrite

Measured 2026-09-08 → 10-01 on the live ledger and logs:

| Symptom | Number | Root cause |
|-|-|-|
| Warden items merged by its own path | ~10 of 414 dispatches | 23 trust/approval/policy gates nobody asked for |
| Items that were duplicates or follow-ups | 30–40 % | raw log titles as identity, revisions filed as new items, no issue↔alert link |
| Failed dispatches from one policy drift | 281 | repo/tier policy defined in warden **and** agent-gateway |
| Hermes skills | 126 (≈105 self-authored) | upstream skill-review nudge + Hermes replying to every warden card |
| Ways to start an agent episode | 10+ | lanes added, never removed |
| Model ids hard-coded in docs | 6+ files, 3 different answers | no single source |

## The picture

Interactive version (pan/zoom, trace, export): [`diagrams/agent-platform.html`](diagrams/agent-platform.html).

```
 trusted sources                       front doors
 GitHub issues (owner/agents)          herdr: orchestrator tab → wave tabs   (owner drives)
 Kuma · HyperDX/OTel alerts            Hermes: Slack/Argo chat               (narrate, answer, route)
 watchdogs · `warden run`                   │
        │                                   │ file work → `warden run` / GitHub issue
        ▼                                   ▼
 WARDEN  intake → triage → investigate → implement → merge train → deploy → verify
        │            │            │             │            │
        │            └── single-shot triage     └────────────┴── agent-gateway jobs
        ▼
 Argo /warden = the one queue · Slack = one line on "done" / "needs decision"

 AGENT-GATEWAY the one worker engine: triage · dispatch(investigate|implement) · review · check
           OpenCode + cheap models by default, Sonnet only where judgment gates a merge
           model ids live ONLY in `GET /api/routing`

 core      ~/.claude (global CLAUDE.md, skills, agents) + per-repo AGENTS.md + Makefile
           read identically by Claude Code, OpenCode and every agent-gateway worker
```

## Roles — one verb each

| Component | Does | Never does |
|-|-|-|
| **warden** | owns the ledger; decides and drives every unattended item to `fixed` | hold per-repo config, ask for approval, edit code itself |
| **agent-gateway** | runs bounded jobs: triage, investigate, implement, review, check | decide what to work on, merge |
| **Hermes** | answers, narrates in one line per item, files work via `warden run` or an issue, opens herdr tabs when asked | dispatch on its own, land PRs, repeat warden cards, author skills unattended |
| **herdr + `rd`** | the owner's cockpit: orchestrator tab spawns wave tabs and waits on them | run unattended work (that is warden) |
| **Argo** | the single status + "needs you" surface | hold state of its own |

## Four lanes — the only ways to start agent work

| Lane | When | Engine |
|-|-|-|
| `@implementer` | edit must land in this session's live tree | native subagent, Sonnet |
| `agw dispatch` | one bounded change, unattended, in a repo you are not working in; result is a branch/PR or a verdict | OpenCode worker |
| `rd fan` (via `/wave`) | N independent changes in one repo, disjoint files | one worktree + Claude tab per change, `rd merge` lands them |
| `rd wave` tab | long work the owner wants to watch or steer | Claude Code / OpenCode in herdr |
| `warden run` / issue | unattended, tracked to `fixed` | warden → agent-gateway |

Deleted: `agent-dispatch`, `rd bg`, the "colleague" lane, raw `claude --bg`,
Hermes kanban/delegation, Hermes hand-merging PRs.

## Repo contract — how agents learn a repo

Every repo with a runtime ships:

| Make target | Contract |
|-|-|
| `make check` | all local validation; non-zero on failure; no side effects |
| `make deploy` | ships the merged default branch; for CI-deployed repos prints `deployed by CI on push` and exits 0; self-hosting repos (warden, agent-gateway, hermes-agent) roll back to the previous commit if their own health check fails |
| `make verify` | probes production; exit 0 = live and healthy |
| `make logs` | bounded tail of production logs, then exits |

AGENTS.md carries exactly these sections, in this order, among its own:
`## Validate` · `## Deploy` · `## Verify & Monitor` (full health URL, Kuma
monitor name, OTel `service.name`) · `## Gotchas`.

Warden reads nothing else about a repo. Routing a signal to a repo uses the
signal's own label (Kuma tag, OTel `service.name`, GitHub repo) and falls back to
the triage step reading the candidate repos' `## Verify & Monitor` sections.

## Warden — the loop

Nine states:

```
new → triaged → working → merging → verifying → fixed
                   │          │          │
                   └──────────┴──────────┴──→ needs_decision | failed
quiet · closed (terminal, with a reason: duplicate | fixed_by | ignored | resolved)
```

1. **Intake.** Every source writes an event. The fingerprint is the title after
   stripping timestamps, hex ids, paths, numbers and the log-file name — the
   same line from two log files is one event.
2. **Triage — single-shot, no tools** (agent-gateway `triage`, cheap single-shot model
   per `GET /api/routing`, ~1–10 s, cents). Input: the new event, the open items of the candidate
   repos, items fixed in the last 14 days with their PR titles. Output:
   `attach(item) | new(repo, title) | fixed_by(item|PR) | ignore(reason)`.
   Debounce stays one knob: alerts need ≥3 occurrences or ≥30 min open;
   issues and `warden run` are immediate.
3. **Investigate → implement** run as one item. The verdict returns a ≤200-char
   `summary`, a `rootCause` key and a `nextAction`. Any confidence goes to
   implement — review is the gate, not the investigator's self-assessment. A
   matching `rootCause` on another open item merges the two.
4. **Revisions are attempts, not items.** A blocked review re-dispatches on the
   same item from the prior branch (agent-gateway cuts the worktree from it). Up to
   4 attempts; the third switches to the stronger implement model.
5. **Merge train, one per repo, single-flight:**
   update the PR onto the latest default branch → `make check` / CI green on that
   SHA → review on that SHA (delta-only if a prior review confirmed) → squash
   merge pinned to the SHA. A conflict is not hand-resolved: the item gets a new
   attempt from the new base with the old diff as context.
6. **Deploy + verify:** `make deploy`, then `make verify` and the item's own
   signal quiet for its window. Failure → automatic `git revert` PR through the
   same train, item back to `working` with the evidence.
7. **Fixed-by sweep:** after every merge, triage re-checks the repo's open items
   against the merged diff; plausible matches move to `verifying` and close when
   their own signal stays quiet.
8. **Retries are the default.** An infrastructure failure (503, synthesis
   error, idle timeout) retries with backoff; three strikes → `failed`, listed
   in Argo, never a page.

**`needs_decision` is the only human exit.** The verdict must name a concrete
question with two options (≤200 chars). Product decisions, irreversible data
operations, spend, and anything touching another person qualify. Missing
permissions, CI, review hiccups and "low confidence" do not.

Kept gates — quality, not trust: CI/`make check` green, review confirmed on the
merged SHA, GitHub rulesets, the debounce, quiet hours for pings.

## Agent-Gateway — the engine

| Job | Default | Why |
|-|-|-|
| `triage`, review router | single-shot `iu-openai` cheap model, JSON | no tools needed; 20–100× cheaper than a `claude -p` session |
| `dispatch` investigate | OpenCode, cheap OpenCode model `high` | measured ~$0.06/episode, 95 % cache hits |
| `dispatch` implement | OpenCode, cheap OpenCode model `max`; escalation model from the registry | strong enough on settled briefs; escalation for attempt 3+ |
| `review` angles | OpenCode cheap model after A/B; security + architect stay Sonnet until measured | angles are ~4 of 5 Max sessions per review |
| `review` synthesis | Sonnet | the judgment that gates every merge |
| `check` | OpenCode or single-shot | mechanical |

One model registry (`server/lib/models.ts`): id, wire (`anthropic` / `chat` /
`responses`), harnesses, limits, rates with source + date, verified date.
Unverified ids are refused. GPT ids run only over the Responses
wire. The dotfiles OpenCode provider block is generated from it. Everything
else points at `GET /api/routing` — never a model id in prose.

Dispatch git safety: worktree from a fresh fetch; revisions cut from the prior
branch by the handler (workers have no credentials); rebase onto the latest base
and re-run checks before push; a per-repo lease for implement episodes from any
caller.

## Hermes — the front door

- Answers and narrates; files work through `warden run` or a GitHub issue; opens
  a herdr tab when the owner asks for one.
- **One reporting format:** one line per item —
  `<icon> <repo>: <what> — <state>[ → next/who] [PR]`, max three lines, then
  `Rest: …`. No ids, PIDs or mechanism unless asked.
- Mentions-only in #agents; never replies to warden's own posts.
- Skill creation by the background nudge is off; ~20 curated skills.
- Reads warden only through its API, never the database.

## herdr — the cockpit

The orchestrator is always a visible tab. `/wave` has two modes: **chain**
(each wave spawns the next) and **orchestrated** (the orchestrator spawns a tab,
blocks on `herdr agent wait` for the settled states idle/done/blocked — `done` alone
never fires on a watched tab — reads `PLAN.md`, decides the next, closes the finished
tab with `rd close`). One active
wave per repo; parallel waves only in different repos. A pane-less supervisor
(`claude --bg` mother) is not a pattern.

## Notifications

| Event | Where |
|-|-|
| item `fixed` | Slack #agents, one line |
| `needs_decision` | Slack #agents, one line with the question + Argo link |
| `failed` | Argo only; daily one-line count |
| everything else | Argo `/warden` |

## Open facts to verify during rollout

- DeepSeek flash rates conflict (agent-gateway 0.15/0.6 vs modelpick 0.50/1.50
  per MTok) — re-probe before cost claims.
- the newest GPT ids, DeepSeek Pro, kimi, minimax on the OpenAI leg are declared but
  never probed — the registry refuses them until verified.
