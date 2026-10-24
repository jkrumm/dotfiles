# 11. What we take from whom

Projects are named because a concept was taken, not for completeness. Sources:
`research/2026-10-24-factories-landscape.md`, `…-dbos-postgres.md`, `…-cli-codegen.md`,
`…-learned-correlation.md`, `…-pele-secaudit-umami.md`, and v1's `research/`.

## Software factories

| Project | What it is | Taken | Not taken |
|-|-|-|-|
| **Swamp** (swamp-club.com; AGPL, daily releases, account required) | automation built from typed behaviours composed into DAG workflows; agents write definitions, code executes | typed steps in code + definitions as data; `assert` as a first-class step; approve ≠ resume, with a decision record; guarded re-runs → §9 jobs, §4 decisions | the runtime (account-gated, AGPL, no per-step cost tracking) |
| **Sandcastle** (mattpocock, MIT, 0.12) | a TypeScript harness for unattended coding agents in worktrees | harness in code, judgment in the prompt; the two-call tracker seam (`ready`, `close`) → our ready queue with `SKIP LOCKED`; a branch per task; structured output as the agent→orchestrator contract; idle timeout distinct from completion → §4 | sandboxes per task (herdr panes on the mini are the sandbox) |
| **Agent Orchestrator** (OrchestratorInc) | desktop app + Go daemon + `ao` CLI; one session = one task + agent + workspace | store facts, derive status at read time; change log → notify → SSE as the event spine; conservative death detection; a settlement window after "done"; at most one stuck-interrupt per three minutes → §4 Witness, §6 | the desktop app |
| **oh-my-hermes** (rlaope) | an operating layer around Nous' Hermes Agent | the claim ladder — planned · reported done · verified — with append-only receipts; model chains that fail over instead of silently downgrading → §4 "done means observed", §5 | its workflows (Hermes stays thin) |
| **pstack** (Lauren Tan / @poteto, Cursor plugin, MIT) | 23 playbooks behind `/poteto-mode`; self-reported 2,000–2,500 PRs a month | the brief as the product, re-sent on every spawn and resume; verdicts keyed by (PR, head SHA) — a new head voids them; one writer per branch; verifier on another model family; a project-local verify command → §4, §7 make contract | the Cursor plugin |
| **Gas Town / Beads** (Yegge) | a multi-agent town (Mayor, Polecats, Witness, Refinery) on a git-backed issue tracker | the ready queue with blockers; Witness as the agent observer; Refinery as the merge train → §4 | beads' runtime: cross-repo deps were inert (0 of 9), a fixed 5-minute lease, writes into work repos (v1 spike 1) |

## Building blocks

| Project | Decision |
|-|-|
| **DBOS Transact** (TS 5.x, MIT) | adopted for durable workflows on Postgres, gated by W1 (§6) |
| Absurd, Hatchet, Temporal, Restate, pg-boss, Graphile Worker, pgflow | not adopted: no version model (Absurd), extra daemons (Hatchet, Temporal, Restate), queues without durable execution (pg-boss, Graphile), a Supabase dependency (pgflow) |
| **oRPC + trpc-cli** | adopted for the API and the CLI from one router (§10) |
| cyclopts, incur | admired, not adopted: Python for a TypeScript consumer; incur is 0.7 |
| **pele** (obsidianmd, 1.x) | adopted for diagrams: Mermaid syntax, zero dependencies, SVG themed by CSS variables, renders headless in Bun (this document's diagrams). It is three weeks old, so the version is pinned |
| **Umami v3** | its events, goals, funnels and read API feed *Traffic*; anomalies are computed by the job (§9) |
| **Cloudflare security-audit skill** | quarterly `quick` runs per fleet repo, on lapsing capacity (§9) |
| Keep | not adopted: grouped no better than singletons on the golden set (v1 spike 3) |
| Renovate | not adopted: upgrades are agentic waves (§9) |

## Cockpit UX

v1's research (`research/2026-10-22-cockpit-ux-patterns.md`, Blume and the open-source dashboards) stays
the reference for Argo: exception-first home, every number with its age, one view per question,
dense tables over cards, detail on demand.
