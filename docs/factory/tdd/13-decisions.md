# 13. Decisions

**Nothing waits on you.** Your v1 answers settled the five open questions (appendix C); a third
subscription is your call whenever you make it, and the design takes it as one more account.

## Choices you may want to override

Each is decided and the plan runs on it; each is cheap to flip before its wave.

| Choice | Decided | Alternative | Why this way |
|-|-|-|-|
| Durable state | DBOS on Postgres, short workflows, on Node | a hand-written loop in Bun (v1's spike design) | queues, schedules and run history come for free; short workflows avoid DBOS' pitfalls (§6) |
| Language | TypeScript (Node for the factory service, Bun elsewhere); oRPC + trpc-cli | Python with cyclopts | one language and one database with Argo; trpc-cli gives the code-derived CLI you liked in cyclopts |
| Mothers | fleet mothers own multi-wave plans; everything else gets a fresh worker | a mother wakes for every Task in her project | most wakes would be cold after an hour anyway; workers with a good brief cost less |
| CLI name | `factory`, with `wave`, `task`, `issue` under it | `wave` at the top | the CLI covers issues, jobs, projects and decisions too |
| Push | Argo web push | ntfy | one app fewer; ntfy if iOS web push proves unreliable |

## A third subscription

You mentioned buying another Claude or OpenAI plan. Another Claude account is one registry line; the
picker uses it on the next spawn. A ChatGPT plan would add Codex as a second code engine — another
model family, useful for verification — with its own launcher and picker lane, about a day of work.
*Factory → waiting* shows hours waited per class, which is the number that says whether it pays.
