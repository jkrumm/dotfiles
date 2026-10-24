# 5. Engines and capacity

## Who pays for what

| Engine | Runs | Paid by | Used for |
|-|-|-|-|
| Deterministic | factory service, jobs, runbooks, make targets | nothing | intake, dedup rules, settle, known fixes, ship, rollback, green job runs |
| Cheap models | agent-gateway → OpenCode v2 server sessions and single-shot calls | IU API | triage residue, investigation, planning, review, briefings, upgrade grouping, job summaries |
| Claude Code | herdr panes, `claude` with the picked account | Max `iu` (20x) and `me` (5x) | all code, in fleet mothers, workers and your sessions |

**IU never writes code.** Since 2026-10-24: `rd` refuses `--kind opencode` and pauses instead of
spilling (dotfiles 691ae1b); the `ca`/`cap`/`cdf`/`cdp` launchers are gone; agent-gateway's
`implement` lane and its escalation run on Max with no IU fallback (§13, Phase 0). IU stays the
right engine for gateways, OpenCode cognition, Hermes and research — that is what it is cheap for.

**The factory never holds a model key.** It calls agent-gateway for every model call, so routing,
model choice and spend stay in one place (`GET /api/routing`).

## The pool

| Account | Plan | Session units | Weekly units | Home lanes |
|-|-|-|-|-|
| `iu` | Max 20x | 4 | 2 | your interactive sessions, agent-gateway review, headless |
| `me` | Max 5x | 1 | 1 | waves, fan-outs, factory mothers and workers |

Units are the measured 20x/5x ratios (`docs/claude-accounts.md`). v1 measured a load of 120 % of one
`iu` weekly window over 30 days; against the combined pool of 3 weekly units that is ≈ 80 %, leaving
≈ 20 % for factory work before any capacity lapses. The picker (`claude-account pick`, rule v1.2)
already does the per-spawn part: eligibility, pace guard, 5-hour balance, expiring capacity first.

## Admission

The scheduler decides *when* a Task may spawn; the picker decides *where*. Four priority classes:

| Class | Examples | Admitted when |
|-|-|-|
| P0 | an owner app is down, data at risk | any account is eligible |
| P1 | a bug in a used feature, a failed deploy follow-up | the picked account is under its weekly pace and its 5-hour window is under 85 % |
| P2 | your requests, planned waves | as P1, and your own interactive lane keeps ≥ 15 % of `iu`'s 5-hour window free |
| P3 | hygiene, upgrades, improvement jobs | only on capacity that would otherwise lapse: an account resets within 24 h with ≥ 30 % of its week unused, or both accounts sit ≥ 15 points under pace |

Otherwise the Task waits — a durable sleep until the next reset or the next quota sample that changes
the answer. Waiting is visible in Argo (*Factory → waiting for capacity*, with the reset time). At
P0, if both accounts are walled, the deterministic parts still run: rollback, restart, runbooks. Code
waits for the reset.

Per repo, one writer per branch and one merge at a time (the merge step is a DBOS queue partitioned
by repo).

## The prompt cache

Two Max accounts are two organisations; a cache never crosses them. Rules, all already enforced or
landing with the scheduler:

- **The account is fixed at spawn.** No switch mid-session; `c --resume` stays on the session's account
  (dotfiles 3dc2d82); Witness resumes a parked session on the same account.
- **Follow-ups go where the cache is warm.** A project's next Task goes to its live mother inside the
  one-hour cache lifetime; the scheduler prefers that over a fresh worker on the other account.
- **Briefs are stable.** The standing-orders part of a brief is byte-identical across spawns, so it
  caches; the task part comes last.

## What it costs

| Line | Now (last 7 d) | With the factory |
|-|-|-|
| IU, review (OCR, adversary, angles) | $136 (56 reviews, ≈ $2.40 each) | + $35–70 / week: one review per shipped Task, 2–4 a day; less once agent-gateway's review-depth gating (logged since 2026-10-23, off) gives small diffs a light review |
| IU, research-gateway | $32 | unchanged |
| IU, agent-gateway dispatch | $4.31 (8 jobs, ≈ $0.55 each) | + $10–20 / week: 3–5 investigations a day after dedup, settle and known fixes |
| IU, dedup judge, briefings, job summaries | — | < $5 / week (single calls on DeepSeek V4.1 Flash / Haiku 5.5) |
| Max | 120 % of one weekly window (v1, 30 d) | the same work plus factory Tasks inside ≈ 85 % of the pool; P3 runs on lapsing capacity only |

v1's open decision D1 (≈ $294/week of IU for mother wakes) is gone: mothers run on Max, and judgment
costs ≈ $50–95 / week in total, most of it review. Review depth gating is the lever, not the judgment model.

## Measured from W2

- **Throughput per window:** Tasks verified and shipped per 1 % of weekly capacity, per account.
- **Waiting:** hours Tasks spent waiting for capacity, per class. Drives the one open decision (§14).
- **Cache:** cache-read share per account and per mother; a fresh wake that could have been a warm
  follow-up is counted.
- **Owner blocked:** minutes your interactive session waited on a wall. Target 0.
