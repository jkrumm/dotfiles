# 13. Decisions

**No decision is open.** You left durable execution to me on 25 October: no DBOS, an Issue state
machine with an inbox (§6). W1 starts on your sign-off of this version.

## Choices you may want to override

Each is decided, and the plan runs on it; each is cheap to flip before its wave.

| Choice | Decided | Alternative | Why this way |
|-|-|-|-|
| Who reasons | the lead does everything from root cause to production; cheap models only sort and word | cheap models investigate and plan first (v2.1) | your call: the strongest model reasons best from facts, not from a weaker model's guess |
| Agents | two layers: an orchestrator over one lead per Issue (§4) | a mother per project plus a steward (v2.2) | your model; Warp's factories make the same split, one level deep |
| Where sessions run | interactive Claude Code in herdr, behind a `Runner` port (§6) | Claude Code background sessions; `claude -p`; the Agent SDK | interactive sessions get the cheaper meter (headless costs ≈ 1.8× the 5-hour window per token, claude-code#97074); herdr works today and lets you and the orchestrator watch and type; Postgres owns the work, so a herdr restart costs one turn; background sessions get a W3 spike while in research preview; the SDK's subscription use is contested |
| Durable execution | an Issue state machine with an inbox in Postgres (§6) | DBOS | engrams' own ADRs: a lifecycle of days must not be one run, and DBOS's version gating stranded their runs |
| Dedup judge | one candidate, in shadow until it earns trust (§8) | a head-to-head of two judges (v2.2) | one thing to measure, on real cases; leads catch duplicates either way |
| Failure in production | the lead fixes forward; a revert is its call | the factory rolls back automatically (v2.1) | infra, dotfiles and data rarely roll back cleanly, and the lead still holds the context |
| Unit of work | the Issue; an initiative's waves are child Issues | Issues plus Tasks (v2.1) | one concept fewer, and the CLI is `factory issue …` |
| Lead model | Sonnet at medium by default; Haiku for mechanical work; Opus for large, novel or second attempts | Opus everywhere | the 5-hour window on `me`; the tuning job moves the defaults from measured outcomes |
| Concurrency | one lead per repo, plus one urgent | several leads per repo | fewer merge fights; the queue is the backlog |
| Orchestrator sessions | a fresh session per event; Sonnet at medium, Opus for initiatives | one always-on orchestrator session | an always-on context grows and compacts; a fresh session per event costs minutes, and a crash loses one wake |
| Language | TypeScript; oRPC + trpc-cli | Python with cyclopts | one language and one database with Argo; trpc-cli gives the code-derived CLI you liked in cyclopts |
| Push | Argo web push | ntfy | one app fewer; ntfy if iOS web push proves unreliable |

## A third subscription

Another Claude account is one registry line; the picker uses it on the next spawn. A ChatGPT plan would
add Codex as a second code engine from another model family, useful for verification, with its own
launcher and picker lane, about a day of work. *Factory* shows hours waited per class, the number that
says whether it pays.
