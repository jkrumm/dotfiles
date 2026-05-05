# Claude Code - Personal Configuration

## Personal Context

- **Name:** Johannes Krumm
- **Role:** Solo Senior Full-Stack Developer and TechLead
- **Working Style:** Iterative, careful, quality-focused — prefer multiple small steps over one big change
- **Language:** User may write in German for chat discussions, but ALL written artifacts (code, commits, docs, specs) MUST be in English. AI responses should default to English unless specifically discussing/clarifying requirements.

---

## Workspaces

### Personal Projects: `~/SourceRoot/`
- GitHub for version control and PRs
- Has its own CLAUDE.md with conventions and workflow
- Skills: `/cloudflare`, `/commit`, `/pr`, `/check`, `/research`, `/review`, `/ship`, `/upgrade-deps`
- **1Password account:** `tkrumm` — always pass `--account tkrumm` to all `op` CLI commands

### Dotfiles: `~/SourceRoot/dotfiles/` (canonical path)
When I say "dotfiles" I mean **this repo**. It is the source of truth for personal global Claude Code configuration:
- `dotfiles/skills/<name>/SKILL.md` → symlinked to `~/SourceRoot/.claude/skills/<name>/` by `make setup` (SourceRoot-scoped — visible to vps/homelab/dotfiles, hidden from IuRoot)
- `dotfiles/rules/*.md` → universal conventions (attribution, commits, TS, security, code style)
- `dotfiles/hooks/` → Claude Code hooks (e.g. docker-makefile.ts)
- `dotfiles/config/global.CLAUDE.md` → this file (symlinked to `~/.claude/CLAUDE.md`)
- `dotfiles/config/settings.template.json` → Claude Code settings template

Edits to skills/rules/hooks/global-CLAUDE.md should happen in the dotfiles repo and be committed there — the symlinks ensure the runtime picks them up immediately.

### Work Projects: `/Users/johannes.krumm/IuRoot/`
- Project-specific CLAUDE.md files (e.g., `epos.student-enrolment/CLAUDE.md`)
- Each project has its own conventions (DDD, NestJS, Vue patterns)
- No root-level configuration (colleagues have own setups)
- **1Password account:** `careerpartner` — always pass `--account careerpartner` to all `op` CLI commands

---

## AI Interaction Preferences

### Communication Style
- Senior-to-senior communication: concise, precise, technical
- Critical feedback over validation: question assumptions, suggest better approaches
- No superlatives or over-explanation: avoid "great", "excellent", "amazing"
- No repetition: don't restate what was already understood
- Challenge immature or over-engineered solutions

### Scope Discipline
- **ONLY implement what I explicitly ask for**
- Don't implement the entire plan at once
- Research/plan fully, THEN build piece by piece
- Wait for me to ask for each specific piece
- Don't add features, refactorings, or improvements I didn't request
- If unclear about scope, ask instead of assuming more work

### When Uncertain
When uncertain: state the question, list 2 options with tradeoffs, give tendency, ask.

### No Attribution
Never add AI or tool attribution to any artifact — code comments, commits, PR descriptions, or docs. This includes Claude, CodeRabbit, SonarQube, Copilot, or any other tooling. See `~/.claude/rules/attribution.md`.

---

## Token Efficiency

### Model Routing
- **Opus**: Main conversation — planning, grilling, PRD, architecture decisions
- **Sonnet**: Implementation — ralph runner, complex code changes, `/ship` orchestration
- **Haiku**: All delegated work — `/check`, `/review`, `/research`, `/commit`, `/pr`, `/browse`, `/analyze`, `/otel`

### Delegation Rules
- If the task is read-only or produces structured output → haiku subagent (fresh context)
- If it writes code → sonnet subagent or inline
- If it reasons about strategy → opus (main thread)
- Under ~50k context: prefer inline for <5 tool calls
- Over ~50k context: prefer subagents even for simple tasks

### API Offloading
For expensive repetitive tasks (heavy web research, Chrome DevTools sessions, batch validation), offload to API credits:
```bash
ANTHROPIC_API_KEY=$(security find-generic-password -s claude-sdk-api-key -w) \
ANTHROPIC_BASE_URL=$(security find-generic-password -s claude-sdk-base-url -w) \
  claude -p --model haiku "task here"
```

### File Reading
Read files with purpose. Use Grep to locate relevant sections before reading entire large files.
Never re-read a file you've already read in this session.
For files over 500 lines, use offset/limit to read only the relevant section.

### Responses
Don't echo back file contents you just read. Don't narrate tool calls. Keep explanations proportional to complexity.

---

## Task Queue (`sc-queue.md`)

Automates unattended multi-task Claude Code sessions. The Stop hook pops the next task from per-repo `sc-queue.md` and injects it as the next user message.

Edit `sc-queue.md` directly to add tasks. Blocks separated by `\n---\n`. Append `STOP` as a standalone block to end the session.

---

## Shell Commands

Git worktree management via **wtp** (`brew install satococoa/tap/wtp`):

| Command | Purpose |
|-|-|
| `wtp add <branch>` | Create worktree with hooks |
| `wtp cd <name>` | Navigate to worktree |
| `wtp remove <name> --with-branch` | Remove worktree + branch |
| `gback` | Alias for `git reset --soft HEAD~1` |

---

## Development Workflow

### Standard Flow
1. Understand request thoroughly
2. Propose plan if non-trivial (wait for approval)
3. Implement changes (use `/implement` for guided flow)
4. Run `/check` for validation
5. Run `/commit` for intelligent commit generation
6. Run `/ship` for PR + review + merge + release

### Validation
- Check `package.json` for available scripts and validation commands
- Use `/check` skill for validation (haiku fork — token efficient)
- Fix errors in changed files only (don't refactor untouched code)
- I validate running apps manually (don't run `dev` servers for me)

### When Something Seems Wrong
Flag explicitly rather than working around silently:
- Tool returns unexpected output → stop and report
- File missing where expected → check git status
- Validation fails on untouched files → report only
- Code/patterns contradict CLAUDE.md → flag it

---

## CLAUDE.md Hierarchy

- **Global** (`~/.claude/CLAUDE.md` → `dotfiles/config/global.CLAUDE.md`): This file — personal preferences, workflow
- **Global rules** (`~/.claude/rules/` ← `dotfiles/rules/`): Universal conventions (attribution, commits, TS, security, code style)
- **SourceRoot skills** (`~/SourceRoot/.claude/skills/` ← `dotfiles/skills/`): Personal-projects-scoped skills (`/cloudflare`, `/commit`, `/pr`, …)
- **Workspace** (`~/SourceRoot/CLAUDE.md`): Personal project conventions
- **Project** (`~/SourceRoot/<project>/CLAUDE.md`): Project-specific patterns
- **Project rules** (`~/SourceRoot/<project>/.claude/rules/`): Subdirectory patterns with `paths:` frontmatter

All `~/.claude/...` and `~/SourceRoot/.claude/...` paths are symlinks managed by `dotfiles/Makefile`. Edit in dotfiles, commit, the runtime sees the change immediately.

Update CLAUDE.md in same commit as related code changes. CLAUDE.md-only changes use `docs:` prefix.
