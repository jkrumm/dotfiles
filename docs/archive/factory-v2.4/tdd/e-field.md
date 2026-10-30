# E. The field: words, peers, and where this factory sits

**This is a software factory by every published definition except Warp's "it runs in the cloud", and
it differs from the company factories on purpose, wherever one person, one always-on machine and two
subscriptions change the answer.** The general field guide, written to outlive this design, is in the
brain: `wiki/engineering/software-factories.md`. Sources: `research/2026-10-25-warp-factories.md`,
`research/2026-10-25-industry-vocabulary.md`, `research/2026-10-25-session-runtimes.md`.

## Four definitions that disagree

| Who | Definition | What it stresses |
|-|-|-|
| Warp | "a cloud-based automation loop around the software development lifecycle — triage, spec, implementation, review, verification, shipping, and monitoring — where agents do the repeatable work and humans stay in the loop at decision points" | the cloud, human decision points, measured and improved, defined in code |
| Factory (factory.ai) | "a managed model for producing software with repeatable inputs, standardized tooling, measurable output, and enough retained context to reconstruct how a change was made" | repeatability and provenance |
| Cortex | "an organizational system that turns customer needs into shipped, reliable software, with AI agents doing the building while engineers move up a level to design and operate the system itself" | an operating model, graded by DRIVE |
| StrongDM | "non-interactive development where specs + scenarios drive agents that write code, run harnesses, and converge without human review" | dark: no human writes or reviews code |

They agree on two things: the unit is a loop around delivery, and the loop is measured. The phrase you
heard, "a self-improving platform, as code", is principle 7 here and the core of Warp's "closed loop".

## The words, and what they are called here

| Term (source) | Means | Here |
|-|-|-|
| Work item (Warp) | one request from intake to handoff; replies continue it, repeat deliveries don't duplicate it | the Issue |
| Foreman (Warp), supervisor/worker | the coordinating agent over worker agents, one level deep | the orchestrator over the leads (§4); it decides, the factory's code moves the work |
| Stage agents (Warp) | one agent per stage: triage, spec, implement, review, verify | one lead does every stage; handoffs cost context |
| Harness (Böckeler: Agent = Model + Harness) | guides that steer before (rules, skills, specs) and sensors that check after (tests, linters, review) | guides: AGENTS.md, skills, the brief, the make contract. Sensors: `make check`, review, `make verify`, probes, scorers |
| In, on, out of the loop (Kief Morris) | whether you review the code, change the system that writes it, or neither | on the loop: you change the factory, not the code |
| Human gate, checkpoint | where the factory waits for a person | four business classes as decision cards; never a pull request |
| Factory as code (Warp: "Terraform for factories") | the definition is versioned, validated and applied atomically | `project.yaml`, rules, runbooks and prompts in repos, changed only through Issues (principle 7) |
| Scorer, LLM-as-judge (Warp) | a cheap model grades finished runs against a rubric | the scorers job (§9) |
| Self-improvement (Warp) | repeated failures open changes against the factory itself | scorer failures and scorecard misses open upkeep Issues |
| Replay benchmark (Warp) | real tasks rerun at their pinned state under another configuration | later, on upkeep capacity, once a routing choice depends on it |
| Factory engineering vs product engineering (Warp) | improving the machine vs shipping through it | your job shifts toward the first |
| Context engineering (Anthropic) | choosing what enters the context window | the brief: facts, never a cheap model's diagnosis |
| 12-factor agents (HumanLayer) | own your control flow, context and state; pause and resume by API; reach humans through tool calls | the factory owns flow and state; leads reach you through `factory issue ask` |
| Ralph loop (Huntley) | a shell loop that feeds one prompt to fresh agents, greenfield only | the opposite of a lead that keeps its context through the hold |
| Background agents, cloud agents | agents that run without anyone at the keyboard | the leads, on the mini |
| Stop the line (Cortex DRIVE) | red production halts new work | §5 |
| Autonomy, touches per PR (Warp); change failure rate, rework rate (DORA) | how much needs a human; how often a change breaks something | the scorecard (§9), outcomes first |

## The company factories

Stripe's Minions, Ramp's Inspect and Spotify's Honk share one shape:
- **Environment:** a pre-warmed, isolated dev environment per task.
- **Trigger:** a thin surface, usually Slack first.
- **Tools:** a curated set behind one MCP server.
- **Checks:** deterministic, and they run before a pull request exists.
- **Merge:** a human or a code owner.

Their numbers are self-reported:
- **Stripe:** "over 1,300" merged agent PRs a week.
- **Spotify:** "more than 2.5 million automated maintenance PRs", most auto-merged.
- **Shopify:** its River agent coauthors one merged PR in eight.

## Solo and company: where the answers differ, and why

| | Company factory | This factory | Why |
|-|-|-|-|
| Where agents run | a fresh sandbox per run, in the cloud | interactive Claude Code on one always-on mini | one trusted user; Max covers the real Claude Code binary, not a hosted harness with API keys (Warp's own FAQ: no consumer subscriptions) |
| What limits throughput | dollars, per-team concurrency caps | two 5-hour windows and two weekly ones | so admission is quota-aware (§5) and cost is window share per Issue |
| Where it ends | a mergeable pull request (Warp, Stripe, Ramp) | production evidence after a 30-minute hold and probes | nobody else deploys or watches production |
| Human gate | spec approval and merge review | four business classes | a single reviewer is the bottleneck the factory exists to remove |
| Orchestrator | an LLM foreman in every work item's path | code moves Issues; the orchestrator wakes only to decide | deterministic paths, agentic where needed (Swamp's lesson) |
| Projects | one factory per product surface (Warp) | one factory over many unrelated repos; a manifest adds automation | a solo developer's portfolio is the product surface |
| Statistics | thousands of runs a week | tens | score every run, and read small numbers with care |
| Governance | RBAC, budgets, audit | Postgres facts and the scorecard | one user |

**What stays individual:** the sources and triggers, the gates, the environment, the capacity model and
the project set. Warp: "This loop is going to look different in its details at every company, on every
team." **What does not:** the loop's shape (in, dedup, work, verify, learn), a work item that keeps its
identity, idempotent intake, evidence before done, outcomes measured before throughput, and a
definition in code that changes like code.

## Where this sits on the ladders

- **Warp's crawl, walk, run.** Today is crawl: point automations (warden's triage, `rd` waves). W1–W4
  is walk: one factory end to end, starting on simple surfaces (homelab self-heal, small requests).
  Run comes after the observation period: routing by measured outcome, and the loop closed in
  production for every project.
- **Shapiro's levels.** For code this is level 5: no human reviews a change before production, and
  evidence, the hold and probes do the reviewer's job. For decisions it stays lit: the four business
  classes reach you. Warp calls fully dark factories "not realistic right now"; a factory that is dark
  for code and lit for decisions is the position to defend.
