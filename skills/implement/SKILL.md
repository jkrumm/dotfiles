---
name: implement
description: Guided implementation with research, exploration, and validation. Scales from quick inline edits to multi-subagent workflows based on task complexity.
---

# Implement — Guided Implementation

Context-aware implementation flow. Scales its approach based on task complexity — from quick focused edits to multi-subagent orchestration. Not a full `/ralph` loop, but capable of handling substantial tasks while keeping the main agent's context window lean.

> **sideclaw tools are async.** `mcp__sideclaw__{check,review}` return `{ jobId }`, not the result — then `mcp__sideclaw__job_wait({ jobId })` (loop while `stillRunning`) yields the structured output. (`/research` is the separate **research-gateway** MCP — a blocking call, no jobId.) **Implementation runs on the native `@implementer` Sonnet subagent** (synchronous, on Max, its own prompt cache — no orchestrator-cache penalty), not on sideclaw. See the async-job contract in global CLAUDE.md.

## When to Use

- You have a clear task (from `/grill`, a PRD, or a direct request)
- The task touches one or many files — complexity is handled by scaling the approach
- You want research + explore + implement + validate in one coordinated flow

## Default Stance: Action Bias

**When the user runs `/implement`, they've already decided to ship it.** Scope is assumed clear; the agent decides along the way. Default to action — don't gate on confirmation, don't propose alternatives, don't ask "should I proceed?". Research and minor judgment calls happen inline as needed.

**Only stop to ask when:**
- A genuinely **major** uncertainty exists (architectural fork, breaking change, data migration risk, security implication)
- A **decision the user must own** is still open (which of two incompatible patterns to follow, which library to adopt, naming of a public API)
- The task as stated is **internally inconsistent** or contradicts something visible in the codebase

Otherwise: pick the obvious option, note it in the plan bullet, and go. The user can redirect in the sign-off step.

---

## Complexity Tiers

Assess the task first and pick the appropriate tier:

| Tier | Signal | Approach |
|-|-|-|
| **Quick** | 1-2 files, clear pattern, no research needed | Skip tasks, skip explore subagent, implement inline, run `/check` |
| **Standard** | 3-8 files, some unknowns, familiar libraries | Full process below — explore subagent, plan, inline impl, `/check` |
| **Heavy** | 9+ files, multiple concerns, external libs, or high uncertainty | Full process + implementation delegated to the `@implementer` Sonnet subagent (parallel, one per **disjoint** file group; an Opus subagent for novel-hard logic) + runtime validation |

For Quick tasks: skip the formality, just implement and validate. State the tier upfront.

---

## Subagent Delegation Rules

**Primary goal: keep the orchestrator's context window small.**

All subagent work uses the native `Agent` tool with an explicit `subagent_type`. Subagents have their own prompt cache — switching models inside a subagent does **not** invalidate the orchestrator's cache. The `@implementer` subagent runs Sonnet 4.6 at high effort (the implementor-tier default — ≈ Opus on SWE-bench at ~1/5 the cost). Fan out Sonnet implementers on **disjoint** file groups freely; reserve Opus subagents for novel-hard reasoning. Note: parallel subagents run on Max — they buy detachment and context isolation, not free parallelism.

| Phase | Quick | Standard | Heavy |
|-|-|-|-|
| Explore | Skip | `Agent` with `subagent_type: Explore` | `Agent` with `subagent_type: Explore` |
| Research | Skip | `/research` (MCP) if external libs | `/research` (MCP) if external libs |
| Plan | 1-liner inline | 3-5 bullets inline | `Agent` with `subagent_type: Plan` for non-trivial plans, else inline; wait for approval |
| Implement | Inline | Inline or `@implementer` (Sonnet) subagent | `@implementer` (Sonnet) subagent, one call per independent file group in parallel; `Agent` with `subagent_type: general-purpose, model: opus` for novel-hard logic — see below |
| Validate (static) | `/check` (MCP) | `/check` (MCP) | `/check` (MCP) |
| Validate (runtime) | Only if obvious | Assess need | Always assess |

**Heavy implementer choice (delegate to protect orchestrator CONTEXT — implementation now runs on Max/Sonnet):**
- **Settled multi-file work**: delegate to **`@implementer`** (native Sonnet 4.6, effort high). Pass a complete brief — exact paths, the change/shape, acceptance criteria, intent, and explicit scope limits (no extra features, no refactoring untouched code). It loads the CLAUDE.md rules automatically (house-style fidelity a foreign worker can't match) and returns a diff summary. It has `Read`/`Grep`, so pass **file pointers, not pre-extracted snippets**, to save orchestrator context. Review the actual diff before committing.
- **Independent file groups**: fire **multiple `@implementer` calls in one turn** (one per group). Parallelize **only on disjoint file sets** — never two implementers on the same file. Remember parallel = N× Sonnet-on-Max (detachment, not free).
- **Novel hard logic, complex decomposition, multi-system reasoning**: keep it on Opus — `Agent` with `subagent_type: general-purpose`, `model: opus, effort: high`. The worker is a literal executor, not a planner.
- **Mass mechanical migration (codemod across many files)**: parallel `@implementer` subagents on disjoint groups, or the `for f in ...; claude -p ... --allowedTools` fan-out (optionally pointed at the IU endpoint to keep it off Max). The retired sideclaw implement worker is **not** an option.
- **Mass parallel search across the repo**: spawn multiple `Explore` agents in parallel (single message, multiple `Agent` tool calls) — `Explore` already defaults to fast.
- **Need branch isolation?** Decide it **up front, at the orchestrator level** — not mid-flow. A subagent inherits the orchestrator's `cwd`, and **by default its `Edit`/`Write` land in your LIVE checkout** — so create the worktree with Claude Code's native worktree feature and run the whole `/implement` flow there (or set `isolation: worktree` on a one-off `Agent` call for a single risky run). Don't spawn a separate worktree-isolated background agent and reconcile trees afterward.

Never do exploration or research inline in Standard/Heavy tiers.

---

## Process

### 0. Assess + Create Tasks (Standard/Heavy only)

State the tier. Then use `TaskCreate` (native deferred tool) to create one task per phase:

- "Explore codebase"
- "Research" (if needed)
- "Plan"
- "Implement"
- "Validate"

Mark each complete via `TaskUpdate` as soon as it's done — don't batch.

### 1. Explore + Research (parallel subagents, Standard/Heavy)

Launch both in a single message (multiple `Agent` tool calls in one block — they run concurrently):

**`Agent` with `subagent_type: Explore`** — be specific about what to find:
- Which files are relevant to this task
- Existing patterns to follow (naming, structure, error handling)
- Any related code that could conflict or should be reused
- Return: file paths + line numbers + key patterns found
- For broad searches across multiple naming conventions, set search breadth to "medium" or "very thorough" in the prompt

**`/research <query>` via the `Skill` tool** — only if the task involves:
- External libraries
- APIs that may have changed
- Patterns not visible in the codebase

Mark both tasks complete when done. Summarize findings in 3-5 bullets max — do NOT echo full subagent output.

### 2. Plan

State your approach in 3-5 bullets and **proceed**. Include:
- Which files you'll change and why
- Patterns you'll follow from the exploration findings
- Any obvious-call decisions made (one line each — "going with X over Y because Z")

**Do not wait for approval by default.** Only pause when a major uncertainty / user-owned decision (per the Action Bias section) is genuinely open. Otherwise, state the plan and start implementing in the same turn.

### 3. Implement

**Quick (≤2 files): implement inline.**

**Standard / Heavy settled work: delegate to the `@implementer` subagent** (native Sonnet 4.6, high effort). **Heavy novel-hard logic: `Agent` with `subagent_type: general-purpose`, `model: opus, effort: high`.** Either way the executor has zero prior context, so the `task` + `context` must include:
- The full task description and acceptance criteria
- Exploration findings (file paths + line numbers + patterns)
- Research findings (if any)
- Explicit constraints: no extra features, no refactoring untouched code, follow existing patterns
- The `@implementer` subagent returns a diff summary + validation result + assumptions — treat it as a **claim**: review the actual diff against source before committing. It has `Read`/`Grep`, so pass file pointers rather than pre-extracted snippets to save orchestrator context

During implementation (inline or subagent):
- Follow existing patterns exactly — match naming, structure, error handling
- Keep changes minimal and focused on the ask
- Don't refactor untouched code
- Don't add features beyond what was asked
- If you discover something that should change but wasn't asked: note it, don't change it

Mark the Implement task complete.

### 4. Validate

**Static** — always run `/check` as a subprocess. Never skip. Fix errors in YOUR changed files only. Report but don't fix issues in untouched files.

**Runtime** — assess whether the change needs runtime verification:

| Scenario | Tool | Notes |
|-|-|-|
| UI/frontend change | `/browse` skill | haiku fork — screenshots, console, DOM inspection |
| Backend/API change with OTEL | `/otel` skill | query traces/logs for the affected service |
| Server not running | Ask the user | Check for `Makefile` first (`make dev`, `make start`), then `package.json` scripts — suggest `! make dev` so output lands in session |
| Server already running | `/browse` or HTTP check | Use what's available |

To find the right start command:
1. Check for `Makefile` — prefer `make dev` or `make start`
2. Fall back to `package.json` scripts (`dev`, `start`)
3. Ask the user if neither is clear

If runtime validation is warranted but requires a server the user hasn't started:
> "To validate visually, please start the dev server (`! make dev`). I'll inspect it via `/browse` once it's up."

Mark the Validate task complete.

### 5. Human Sign-off

Always end with a short summary and an explicit ask:
- What was changed (1-3 bullets)
- How you validated it (static / runtime / OTEL)
- What to look for when the user tests manually

Ask the user to confirm the outcome looks correct before considering the task done.

### 6. Document Learnings (if non-obvious)

If you discovered a gotcha, a constraint, or a reusable pattern:
- Add to project CLAUDE.md if it'll help future sessions
- Mention to the user if one-time

---

## Rules

- State the tier (Quick/Standard/Heavy) upfront
- Never do exploration or research inline in Standard/Heavy — use `Agent` with `subagent_type: Explore` + `/research` (MCP)
- Never switch the **orchestrator's** model mid-session (kills prompt cache). Switch freely **inside** subagents — they have their own cache
- Never echo full subagent output — summarize in ≤5 bullets
- Always run `/check` before declaring done
- Assess runtime validation need — don't skip it silently
- Check `Makefile` before `package.json` for server start commands
- Never start long-lived servers — ask the user to run them with `!`
- Always ask for human sign-off at the end
- **Action bias is the default**: small decisions are the agent's to make. Only escalate major uncertainty or user-owned decisions (see Default Stance section)
- Implementation subagent must receive all context upfront (it has no prior conversation)
- The `@implementer` subagent runs Sonnet at high effort and loads CLAUDE.md automatically — **do not re-specify the rules** in the brief; **do** specify exact paths, the change, acceptance criteria, intent, and scope limits
