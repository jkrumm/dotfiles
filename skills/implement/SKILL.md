---
name: implement
description: Guided implementation with research, exploration, and validation. Scales from quick inline edits to multi-subagent workflows based on task complexity.
---

# Implement — Guided Implementation

Context-aware implementation flow. Scales its approach based on task complexity — from quick focused edits to multi-subagent orchestration, while keeping the main agent's context window lean.

> **sideclaw tools are async.** `mcp__sideclaw__{check,review,dispatch}` return `{ jobId }`, not the result — then `mcp__sideclaw__job_wait({ jobId })` (pass `maxWaitMs` up to 29 min rather than looping on the ~50s default) yields the structured output. (`/research` is the separate **research-gateway** MCP: submit returns `{ jobId }`, then a single `mcp__research-gateway__job_wait({ jobId })` normally covers the whole job — it blocks rather than returning every 50 s.) **Settled implementation now defaults to `mcp__sideclaw__dispatch`** (tier `implement`: isolated worktree → branch → draft PR, `DeepSeek-V4-Pro`, off Max). The native `@implementer` Sonnet subagent (synchronous, on Max, its own prompt cache) stays the path when the edit needs this session's **live** uncommitted tree or **tight iteration** — it can't reach the IU endpoint, so it can't run the cheap model. The same jobs are reachable without MCP via the `sideclaw` CLI — `sideclaw dispatch --repo R --tier implement [--workspace in-place] "<brief>"` (`--json`, `--no-wait`) — which is how OpenCode/Codex/cron drive them. See the async-job contract in global CLAUDE.md.

## When to Use

- You have a clear task (a PRD or a direct request)
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
| **Heavy** | 9+ files, multiple concerns, external libs, or high uncertainty | Full process + implementation via `mcp__sideclaw__dispatch` (tier `implement`, parallel, one per **disjoint** file group) unless the edit needs the live tree, then `@implementer`; an Opus subagent for novel-hard logic + runtime validation |

For Quick tasks: skip the formality, just implement and validate. State the tier upfront.

---

## Subagent Delegation Rules

**Primary goal: keep the orchestrator's context window small.**

All subagent work uses the native `Agent` tool with an explicit `subagent_type`, or `mcp__sideclaw__dispatch` for settled work off Max. Subagents have their own prompt cache — switching models inside a subagent does **not** invalidate the orchestrator's cache. The `@implementer` subagent runs the `sonnet` alias at high effort; `dispatch`'s `implement` tier runs `DeepSeek-V4-Pro`, off Max, in its own worktree. Fan out either on **disjoint** file groups freely; reserve Opus subagents for novel-hard reasoning. Note: parallel `@implementer` calls run N× Sonnet-on-Max (detachment, not free) — parallel `dispatch` calls don't.

| Phase | Quick | Standard | Heavy |
|-|-|-|-|
| Explore | Skip | `Agent` with `subagent_type: Explore` | `Agent` with `subagent_type: Explore` |
| Research | Skip | `/research` (MCP) if external libs | `/research` (MCP) if external libs |
| Plan | 1-liner inline | 3-5 bullets inline | `Agent` with `subagent_type: Plan` for non-trivial plans, else inline; wait for approval |
| Implement | Inline | Inline, `mcp__sideclaw__dispatch` (implement tier), or `@implementer` for live-tree work | `mcp__sideclaw__dispatch` (implement tier), one call per independent file group in parallel; `@implementer` when the edit needs the live tree; `Agent` with `subagent_type: general-purpose, model: opus` for novel-hard logic — see below |
| Validate (static) | `/check` (MCP) | `/check` (MCP) | `/check` (MCP) |
| Validate (runtime) | Only if obvious | Assess need | Always assess — via `@verifier` |

**Heavy implementer choice (delegate to protect orchestrator CONTEXT and cost — settled implementation now defaults to `mcp__sideclaw__dispatch`, off Max):**
- **Settled multi-file work**: default to **`mcp__sideclaw__dispatch`** (tier `implement`, `DeepSeek-V4-Pro`, off Max: `workspace: "worktree"` (default) → branch → draft PR, or `workspace: "in-place"` — edits the live checkout, commits nothing, returns `changedFiles` for the owner to review, the reach-for in a direct-to-master repo or when the caller wants the edits in their own tree). Pass a complete brief — exact paths, the change/shape, acceptance criteria, intent, and explicit scope limits (no extra features, no refactoring untouched code); `job_wait` for the result, then review the draft PR's diff. Use **`@implementer`** (native `sonnet` alias, effort high, on Max) instead when the edit must land in this session's **live uncommitted tree** or needs **tight iteration** with the orchestrator — dispatch can't do either, since it works in its own worktree with no steering. `@implementer` loads the CLAUDE.md rules automatically and has `Read`/`Grep`, so pass **file pointers, not pre-extracted snippets**.
- **Independent file groups**: fire **multiple `mcp__sideclaw__dispatch` calls in one turn** (one per group, each its own worktree — no cross-talk), or, on the live-tree path, multiple `@implementer` calls. Parallelize **only on disjoint file sets** — never two workers on the same file.
- **Novel hard logic, complex decomposition, multi-system reasoning**: keep it on Opus — `Agent` with `subagent_type: general-purpose`, `model: opus, effort: high`. The worker is a literal executor, not a planner. State the one-clause reason neither dispatch nor Sonnet fits in the call's `description` — Opus is not hook-blocked, but it is not free either, and an unjustified reach for it is a decision worth being able to grep for later.
- **Mass mechanical migration (codemod across many files)**: parallel `mcp__sideclaw__dispatch` calls on disjoint groups, or the `for f in ...; claude -p ... --allowedTools` fan-out (pointed at the IU endpoint to keep it off Max).
- **Mass parallel search across the repo**: spawn multiple `Explore` agents in parallel (single message, multiple `Agent` tool calls) — `Explore` already defaults to fast.
- **Need branch isolation?** `mcp__sideclaw__dispatch` gives it by default (its own worktree + branch + draft PR). For `@implementer`'s live-tree path, decide isolation **up front, at the orchestrator level** — not mid-flow: create the worktree with Claude Code's native worktree feature and run the whole `/implement` flow there (or set `isolation: worktree` on a one-off `Agent` call for a single risky run). Don't spawn a separate worktree-isolated background agent and reconcile trees afterward.

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

**Standard / Heavy settled work: delegate to `mcp__sideclaw__dispatch`** (tier `implement`, `DeepSeek-V4-Pro`, off Max) — or **`@implementer`** (native `sonnet` alias, high effort, on Max) when the edit needs the live tree or tight iteration. **Heavy novel-hard logic: `Agent` with `subagent_type: general-purpose`, `model: opus, effort: high`.** Either way the executor has zero prior context, so the brief must include:
- The full task description and acceptance criteria
- Exploration findings (file paths + line numbers + patterns)
- Research findings (if any)
- Explicit constraints: no extra features, no refactoring untouched code, follow existing patterns
- `dispatch` returns a draft PR (review the diff before merge); `@implementer` returns a diff summary + validation result + assumptions landed straight in the live tree — either way treat it as a **claim**: review the actual diff against source before committing. `@implementer` has `Read`/`Grep`, so pass file pointers rather than pre-extracted snippets to save orchestrator context

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

**Heavy tier: delegate to `@verifier`** (`Agent` with `subagent_type: verifier`) rather than calling `/browse`/`/otel` inline — it already wraps both instruments and a `curl`/`/check` fallback, and its whole point is keeping screenshots and trace dumps out of the orchestrator's context. Give it the concrete claims to check (routes, expected states, endpoints) — it returns a `PASS`/`FAIL`/`INCONCLUSIVE` verdict with evidence, not the raw dump. Same server-not-running handling applies: it will not start one, and reports that as a finding.

**Quick/Standard: the direct routing below** — proportionate at that volume, and screenshotting one component doesn't need a subagent hop.

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
- Add to project AGENTS.md if it'll help future sessions
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
- Settled multi-file work defaults to `mcp__sideclaw__dispatch` (tier `implement`, off Max); `@implementer` runs Sonnet at high effort on Max for live-tree/tight-iteration work. Both load CLAUDE.md → AGENTS.md automatically — **do not re-specify the rules** in the brief; **do** specify exact paths, the change, acceptance criteria, intent, and scope limits
- **A subjective goal needs a measurable acceptance criterion, or it comes back "done" unchanged.** "Make it less verbose", "tidy this up", "improve the naming" are unfalsifiable as written: the worker fixes something adjacent and reports success. Convert to a number the worker must measure and report (word count before/after, file count, the specific line that must be gone), or to the exact named sites that must change. A goal stated only in adjectives regressed twice in one project before the brief demanded a count
