# 13. Decisions

**One decision is yours, and you are researching it: durable execution (§6).** My recommendation is no
DBOS: each Issue is a state machine in Postgres with an inbox, which is where Cortex's own engrams
code ended up after DBOS stranded its long runs. W1 starts either way; only §6's part of it differs.

## Choices you may want to override

Each is decided, and the plan runs on it; each is cheap to flip before its wave.

| Choice | Decided | Alternative | Why this way |
|-|-|-|-|
| Who reasons | the lead does everything from root cause to production; cheap models only sort and word | cheap models investigate and plan first (v2.1) | your call: the strongest model reasons best from facts, not from a weaker model's guess |
| Failure in production | the lead fixes forward; a revert is its call | the factory rolls back automatically (v2.1) | infra, dotfiles and data rarely roll back cleanly, and the lead still holds the context |
| Unit of work | the Issue; an initiative's waves are child Issues | Issues plus Tasks (v2.1) | one concept fewer, and the CLI is `factory issue …` |
| Lead model | Sonnet at medium by default; Haiku for mechanical work; Opus for large, novel or second attempts | Opus everywhere | the 5-hour window on `me`; the tuning job moves the defaults from measured outcomes |
| Concurrency | one lead per repo, plus one urgent | several leads per repo | fewer merge fights; the queue is the backlog |
| Steward | 06:30 daily and on events, Sonnet at medium | an always-on orchestrator session | an always-on context grows and compacts; short runs on a status summary cost little |
| Language | TypeScript; oRPC + trpc-cli | Python with cyclopts | one language and one database with Argo; trpc-cli gives the code-derived CLI you liked in cyclopts |
| Push | Argo web push | ntfy | one app fewer; ntfy if iOS web push proves unreliable |

## A third subscription

Another Claude account is one registry line; the picker uses it on the next spawn. A ChatGPT plan would
add Codex as a second code engine from another model family, useful for verification, with its own
launcher and picker lane, about a day of work. *Factory* shows hours waited per class, the number that
says whether it pays.
