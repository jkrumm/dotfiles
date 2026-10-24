# B. What we took from whom

Sources: `research/2026-10-24-*.md` and v1's `research/`.

| Project | What it is | Taken | Not taken |
|-|-|-|-|
| **Swamp** (swamp-club.com) | automation from typed behaviours in DAG workflows; agents write definitions, code executes | typed steps in code, assertions as first-class steps, nothing spent when green (§9) | the runtime: account-gated, AGPL |
| **Sandcastle** (mattpocock) | a TypeScript harness for unattended coding agents in worktrees | the harness in code and the judgment in the prompt; a branch per task; structured output as the agent's report (§4) | per-task sandboxes — herdr panes on the mini are ours |
| **Agent Orchestrator** | daemon + CLI; one session = one task + agent + workspace | facts stored, status derived; a settlement window after "done"; one stuck-interrupt per three minutes (§4) | the desktop app |
| **oh-my-hermes** | an operating layer around Hermes Agent | the claim ladder — planned, reported done, verified (§3 "done means observed") | its workflows; Hermes stays thin |
| **pstack** (Lauren Tan) | Cursor playbooks behind a very high PR rate | the brief re-sent on every spawn; checks keyed to a commit, voided by a new one; one writer per branch; a reviewer from another model family (§4) | the plugin |
| **Gas Town / Beads** | a multi-agent town on a git-backed tracker | the ready queue with blockers; Witness; a merge lane (§4) | beads' runtime: inert cross-repo deps, fixed 5-minute lease, writes into work repos |
| **DBOS Transact** | durable workflows as a Postgres-backed library | durable steps, queues, schedules and run history for the factory service (§6) | long-lived workflows — ours stay short |
| **oRPC + trpc-cli** | typed RPC with OpenAPI; a CLI from the same router | the factory's API and CLI (§10) | — |
| **cyclopts**, **incur** | code-derived CLIs (Python; TypeScript 0.7) | the standard to meet | Python for a TypeScript consumer; incur too young |
| **pele** (obsidianmd) | Mermaid syntax rendered to themeable SVG, zero dependencies | this document's diagrams; the dataviz skill and Argo next (§10). Pinned: three weeks old | — |
| **Umami v3** | self-hosted analytics with events, goals, funnels and an API | the traffic job's data (§9) | — |
| **Cloudflare security-audit skill** | a six-phase agent audit | quick audits by amount of change (§9) | — |
| Keep, Renovate | alert correlation; dependency PRs | — | Keep grouped no better than singletons on the golden set; upgrades are agentic waves |
| PagerDuty, BigPanda, incident.io, Datadog | incident platforms | deterministic gates, per-rule merge/split counts (§8) | — |
