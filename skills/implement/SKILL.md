---
name: implement
description: Guided implementation with research, exploration, and validation. Scales from quick inline edits to multi-subagent workflows based on task complexity.
---

# Implement — Guided Implementation

Context-aware implementation flow. Scales its approach based on task complexity — from quick focused edits to multi-subagent orchestration. Not a full `/ralph` loop, but capable of handling substantial tasks while keeping the main agent's context window lean.

## When to Use

- You have a clear task (from `/grill`, a PRD, or a direct request)
- The task touches one or many files — complexity is handled by scaling the approach
- You want research + explore + implement + validate in one coordinated flow

---

## Complexity Tiers

Assess the task first and pick the appropriate tier:

| Tier | Signal | Approach |
|-|-|-|
| **Quick** | 1-2 files, clear pattern, no research needed | Skip tasks, skip explore subagent, implement inline, run `/check` |
| **Standard** | 3-8 files, some unknowns, familiar libraries | Full process below — explore subagent, plan, inline impl, `/check` |
| **Heavy** | 9+ files, multiple concerns, external libs, or high uncertainty | Full process + implementation delegated to sonnet subagent + runtime validation |

For Quick tasks: skip the formality, just implement and validate. State the tier upfront.

---

## Subagent Delegation Rules

**Primary goal: keep the main agent's context window small.**

| Phase | Quick | Standard | Heavy |
|-|-|-|-|
| Explore | Skip | Explore subagent | Explore subagent |
| Research | Skip | `/research` (MCP) if needed | `/research` (MCP) if needed |
| Plan | 1-liner | 3-5 bullets | 3-5 bullets, wait for approval |
| Implement | Inline | Inline | Sonnet subagent |
| Validate (static) | `/check` (MCP) | `/check` (MCP) | `/check` (MCP) |
| Validate (runtime) | Only if obvious | Assess need | Always assess |

Never do exploration or research inline in Standard/Heavy tiers. Use the Explore subagent for codebase navigation and `/research` (MCP) for external lookups.

---

## Process

### 0. Assess + Create Tasks (Standard/Heavy only)

State the tier. Then create tasks:

```
TaskCreate: "Explore codebase"
TaskCreate: "Research (if needed)"
TaskCreate: "Plan"
TaskCreate: "Implement"
TaskCreate: "Validate"
```

### 1. Explore + Research (parallel subagents, Standard/Heavy)

Launch both in a single message if research is needed, otherwise just explore:

**Explore agent prompt** — be specific about what to find:
- Which files are relevant to this task
- Existing patterns to follow (naming, structure, error handling)
- Any related code that could conflict or should be reused
- Return: file paths + line numbers + key patterns found

**Research subprocess** — only if the task involves:
- External libraries (use `/research <query>`)
- APIs that may have changed
- Patterns not visible in the codebase

Mark both tasks complete when done. Summarize findings in 3-5 bullets max — do NOT echo full subagent output.

### 2. Plan

State your approach in 3-5 bullets. Include:
- Which files you'll change and why
- Patterns you'll follow from the exploration findings
- Anything uncertain (ask the user before proceeding)

Wait for user approval on Heavy tasks or non-obvious plans.

### 3. Implement

**Quick / Standard (≤8 files): implement inline.**

**Heavy (9+ files or high complexity): delegate to a sonnet subagent.** The subagent prompt must include:
- The full task description
- Exploration findings (file paths, patterns)
- Research findings (if any)
- Explicit constraints: no extra features, no refactoring untouched code, follow existing patterns
- Return: list of files changed + brief summary of what changed

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
- Never do exploration or research inline in Standard/Heavy — use Explore subagent + `/research` (MCP)
- Never echo full subagent output — summarize in ≤5 bullets
- Always run `/check` before declaring done
- Assess runtime validation need — don't skip it silently
- Check `Makefile` before `package.json` for server start commands
- Never start long-lived servers — ask the user to run them with `!`
- Always ask for human sign-off at the end
- If blocked, ask the user — don't guess
- Implementation subagent must receive all context upfront (it has no prior conversation)
