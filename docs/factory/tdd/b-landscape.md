# B. What we took from whom

Sources: `research/2026-10-24-*.md`, `research/2026-10-25-*.md` and v1's `research/`.

| Project | What it is | Taken | Not taken |
|-|-|-|-|
| **engrams** (Cortex, open source, AGPL) | a software factory running Claude Code or Codex in microVMs; a Bun orchestrator on DBOS; read in source | stateful entities, short runs (ADR 0119); an inbox per Issue with mandatory idempotency keys; claims with join, queue and supersede; deterministic prompt ids; explicit turn-end events instead of inferred idle; finalize once; golden and replay tests (§4, §6). For agent-gateway's review: a finder and a refute-to-drop verifier | the Rust and microVM platform, its code (AGPL), DBOS as the engine |
| **Cortex DRIVE** (whitepaper, Ganesh Datta) | operational excellence for the AI software factory: five pillars, a weekly review | stop the line; binary journey probes; change failure rate as the headline; action items with age; outcomes over activity counts (§4, §5, §9) | team rollups, sentiment surveys, the human review meeting: one owner, and he wants out of the loop |
| **Swamp** (swamp-club.com) | automation from typed behaviours in DAG workflows; agents write definitions, code executes | typed steps in code, assertions as first-class steps, nothing spent when green; agents author the deterministic path (§3, §9) | the runtime: account-gated, AGPL |
| **Sandcastle** (mattpocock) | a TypeScript harness for unattended coding agents in worktrees | the harness tracks, the agent plans, codes and reviews; a branch per Issue; structured output as the agent's report (§4) | per-task sandboxes — herdr panes on the mini are ours |
| **Agent Orchestrator** | daemon + CLI; one session = one task + agent + workspace | observation in code, the work in the agent; facts stored, status derived; nudges that carry the failing check (§4) | the desktop app |
| **oh-my-hermes** | an operating layer around Hermes Agent | the claim ladder — planned, reported done, verified (§3); a work category that picks model and effort (§5) | its workflows; Hermes stays thin |
| **pstack** (Lauren Tan) | Cursor playbooks behind a very high PR rate | the brief re-sent on every spawn; checks keyed to a commit, voided by a new one; one writer per branch; a reviewer from another model family (§4) | the plugin |
| **Gas Town / Beads** | a multi-agent town on a git-backed tracker | the ready queue with blockers; Witness; a merge lane (§4) | beads' runtime: inert cross-repo deps, fixed 5-minute lease, writes into work repos |
| **DBOS Transact** | durable workflows as a Postgres-backed library | idempotent run ids, a mailbox per entity, step contracts pinned by tests (§6) | the engine: version gating strands in-flight runs on deploy (engrams ADR 0104); recommended against, your decision |
| **oRPC + trpc-cli** | typed RPC with OpenAPI; a CLI from the same router | the factory's API and CLI (§10) | — |
| **cyclopts**, **incur** | code-derived CLIs (Python; TypeScript 0.7) | the standard to meet | Python for a TypeScript consumer; incur too young |
| **pele** (obsidianmd) | Mermaid syntax rendered to themeable SVG, zero dependencies | this document's diagrams; the dataviz skill and Argo next (§10). Pinned: three weeks old | — |
| **Umami v3** | self-hosted analytics with events, goals, funnels and an API | the traffic job's data (§9) | — |
| **Cloudflare security-audit skill** | a six-phase agent audit | quick audits by amount of change (§9) | — |
| Keep, Renovate | alert correlation; dependency PRs | — | Keep grouped no better than singletons on the golden set; upgrades are agentic waves |
| PagerDuty, BigPanda, incident.io, Datadog | incident platforms | deterministic gates, per-rule merge/split counts (§8) | — |
