# Claude Code — Personal Configuration

## Personal Context

- **Name:** Johannes Krumm
- **Role:** Solo Senior Full-Stack Developer and TechLead
- **Working Style:** Iterative, careful, quality-focused — prefer multiple small steps over one big change
- **Language:** User may write in German for chat; ALL written artifacts (code, commits, docs, specs) MUST be in English. AI responses default to English unless clarifying requirements.

---

## Workspaces

The Mac has three workspace "regions" plus the Obsidian vault. Skills, hooks, and rules are **global** (`~/.claude/`); workspace conventions live in this file; each repo can still add its own `CLAUDE.md`.

### `~/SourceRoot/` — Personal projects

- **1Password account:** `tkrumm` — always pass `--account tkrumm` to every `op` CLI command.
- **VCS:** GitHub. No ticket prefixes.
- **Default: direct-to-master.** Every SourceRoot repo skips the PR flow unless it's on the small PR-required denylist.
- **PR-required repos** (`/ship` uses PR flow; `protect-branches.ts` enforces): `basalt-ui` (NPM published — also always a separate commit), `free-planning-poker`, `rollhook`, `rollhook-action`. Everything else is direct-to-master.
- **All `~/IuRoot/` repos require PRs** (against `main`). Detected by path — no list to maintain.

#### Repository map

| Repo | Purpose |
|-|-|
| `dotfiles` | This setup — Claude Code config, hooks, skills, rules, localai stack. Source of truth. |
| `homelab` | Main homelab stack (25+ containers) + Uptime Kuma config. |
| `homelab-private` | **Private stack** (do not reference outside this repo): media pipeline behind ProtonVPN, Jellyfin, **Tailscale ACLs**. **Never reference services, hostnames, or details of this repo from anywhere else** — not in `homelab`, not in CLAUDE.md, not in commits outside this repo. Self-contained. |
| `vps` | Production VPS (Cloudflare Tunnel, three compose stacks: networking, infra, monitoring). |
| `sideclaw` | Claude Code MCP daemon — `check` / `review` / `research` tools, quota-aware Max↔IU routing. Hosts personal queue, notes, todos, Excalidraw integration. |
| `hermes-agent` | Hermes — Mac Mini-only personal AI (Slack interface, Sonnet 4.6 brain, seven skill domains). |
| `basalt-ui` | Tailwind v4 design system (NPM: `basalt-ui`). **Always commit separately from consumer apps.** |
| `basalt-ui-playground` | Component preview / dev environment for basalt-ui. |
| `argo` | Personal API server + dashboard — the AI-agent backbone. Hermes and other agents call it to read TickTick tasks, Gmail, calendar (personal + work), Teams messages, Garmin health (HRV, sleep, recovery, daily metrics), strength training (workouts, e1RM, volume), and homelab/VPS state (UptimeKuma, Docker). Elysia + Bun + Postgres + Drizzle; OpenAPI spec at `argo.jkrumm.com/api/openapi/json` is the agent contract. |
| `rollhook` | Webhook-triggered zero-downtime rolling deployments for Docker Compose. |
| `rollhook-action` | GitHub Action wrapping rollhook. |
| `bun-email-api`, `free-planning-poker`, `podcast-generator`, `sy-serendipity`, `ticktick-raycast` | Smaller personal apps / utilities. |

#### Infrastructure

| Server | SSH | Repos | 1P vaults |
|-|-|-|-|
| HomeLab | `ssh homelab` | `~/homelab`, `~/homelab-private` | `homelab` + `common` |
| VPS | `ssh vps` | `~/vps` | `vps` + `common` |

SSH config in `~/.ssh/config` (Tailscale-IP key auth, generated from template). For sudo:

```bash
ROOT_PW=$(op read "op://Private/homelab-server/password" --account tkrumm) && ssh homelab "echo '$ROOT_PW' | sudo -S <cmd>"
ROOT_PW=$(op read "op://Private/vps-server/password" --account tkrumm) && ssh vps "echo '$ROOT_PW' | sudo -S <cmd>"  # VPS has NOPASSWD sudo
```

#### Local dev proxy

Caddy + dnsmasq serve `*.test` over HTTPS (port assignments in `dotfiles/config/Caddyfile`). Every app: static port, `npx kill-port PORT && ... --strictPort`, entry in Caddyfile. Adding a service: edit Caddyfile → `caddy-reload` → commit in dotfiles.

#### BasaltUI integration (consumer apps)

```js
// vite config
optimizeDeps: { exclude: ['basalt-ui'] }
```
```css
@source "../path/to/packages/basalt-ui/src";  /* Tailwind v4 custom utilities */
```

After editing components in `basalt-ui`: `bun run build` before testing consumers. Component placement: blueprint-styled ShadCN components → `packages/basalt-ui/src/components/`; consumer apps re-export via `export { Button } from 'basalt-ui'`.

---

### `~/IuRoot/` — Work projects (IU)

- **1Password account:** `careerpartner` — always pass `--account careerpartner`.
- **VCS:** GitLab. **Tickets:** `EP-XX` prefixes on branches and commits.
- **Stack:** Domain-Driven Design (DDD), NestJS backends, Vue frontends, micro-frontend SPA orchestrator.
- Each repo has its own conventions; some carry their own `CLAUDE.md`.

| Repo | Purpose |
|-|-|
| `epos.student-enrolment` | **Backend** for academic profile + booking domains (DDD, NestJS). Has its own CLAUDE.md. |
| `epos_fe.academic-profile` | Frontend: student academic profile (Vue). |
| `epos_fe.booking` | Frontend: booking workflow (Vue). |
| `epos_fe.spa-orchestrator` | Host shell for micro-frontends. |
| `prometheus-scripts` | **Work investigations.** Jupyter MCP stack + Python data-analysis tools. |

Other IuRoot repos exist but are rarely touched directly (`epos.crm-bridge`, `epos.dam`, `epos.exam`, `epos.finance-bridge`, `epos.iam`, `epos.study-progress`, `crm-bridge-retry-tool`, `cfn-kafka`, `terraform-monitoring`) — ask if context is needed.

---

### `~/Obsidian/Vault/` — PKM vault (not a git repo)

Personal knowledge management, journaling, project notes. Has its own `CLAUDE.md` and vault-only skills (`/daily`, `/inbox-process`, `/capture`, `/briefing`, `/journal-import`). Self-contained — start Claude inside the vault to use them. Tasks managed externally in TickTick.

---

## 1Password routing

A helper resolves the right `--account` automatically based on cwd (worktree-safe via `git rev-parse --git-common-dir`):

```bash
op_account_for_cwd  # → "tkrumm" or "careerpartner"
op_run              # convenience: invokes `op --account "$(op_account_for_cwd)" ...`
```

Helper lives in `~/.zsh/conf.d/secrets.zsh`. Skills that touch 1Password (`/secrets`, `/cloudflare`, `/otel`) call the helper instead of hardcoding `tkrumm`. SourceRoot-only infra scripts (e.g. `dotfiles/scripts/github-config.sh`) may keep `tkrumm` hardcoded.

---

## AI Interaction Preferences

### Communication Style
- Senior-to-senior: concise, precise, technical.
- Critical feedback over validation: question assumptions, suggest better approaches.
- No superlatives or filler ("great", "excellent", "amazing").
- No repetition: don't restate what was already understood.
- Challenge immature or over-engineered solutions.

### Scope Discipline
- Stay within the requested scope — don't sprawl into unrelated refactors, features, or cleanups.
- For non-trivial work, plan briefly before building.
- If scope is genuinely ambiguous, ask; otherwise proceed.

### When Uncertain
State the question, list 2 options with tradeoffs, give tendency, ask.

### No Attribution
Never add AI or tool attribution to any artifact — code comments, commits, PR descriptions, docs. This includes Claude, CodeRabbit, SonarQube, Copilot, or any other tooling. See `~/.claude/rules/attribution.md`.

---

## Token Efficiency

### Orchestrator role
The main session is the **orchestrator**. Keep its context clean: hold the plan, the user's intent, and the cross-skill state. Push verbose work (logs, diffs, fetch bodies, test output) into one of the four execution modes below. **Don't switch the orchestrator's model mid-session** — that invalidates the prompt cache for at least one turn and is the biggest avoidable cost in a long conversation.

### Four execution modes for skills

| Mode | When to use | Cost profile |
|-|-|-|
| **inline** (no `model:` frontmatter) | Conversational/orchestrating skills that benefit from session context: `commit`, `pr`, `ship`, `git-cleanup`, `secrets`, `grill`, `implement`. | Runs on the current session model. Zero switch cost. Output lands in main context — keep it short. |
| **subprocess** (`claude -p` shelled from the skill body, API key via Keychain) | Read-heavy work with large isolated output that doesn't need structured guarantees: `analyze`, `otel`, `read-drawing`. | Free of Max quota (API credits). Output fully isolated. Cold spawn ~500ms. No prompt cache reuse across calls. |
| **MCP (sideclaw)** | Heavy work that benefits from JSON-schema output + heartbeat + Max↔IU quota routing: `check`, `review`, `research`. | Schema-validated structured output. Quota-aware routing at ≥70% Max utilization. Best for things `/ship` parses programmatically. |
| **fork** (`context: fork`) | Wrap deferred MCP tools whose responses are token-heavy: `browse` (chrome-devtools). | Burns Max quota (uses Agent tool). Use only when sideclaw can't host the MCP and inline output would bloat main. |

### Routing decisions
- Does the skill need the orchestrator's conversation context? → **inline**
- Is the work fully describable by inputs and the output verbose? → **subprocess**
- Do callers parse the output programmatically, or does the run last >30s? → **MCP (sideclaw)**
- Does it need a live MCP server the main session has registered (e.g. chrome-devtools)? → **fork**

**Never** put `model: haiku|sonnet` in skill frontmatter when the skill body already shells out to `claude -p` with its own `--model` flag — that creates a redundant main-thread switch for trivial orchestration.

### API offloading (manual)
For ad-hoc heavy work outside a skill:
```bash
ANTHROPIC_API_KEY=$(security find-generic-password -s claude-sdk-api-key -w) \
ANTHROPIC_BASE_URL=$(security find-generic-password -s claude-sdk-base-url -w) \
  claude -p --model haiku "task here"
```

### File reading
Read files with purpose. Use Grep to locate relevant sections before reading entire large files. Never re-read a file you've already read in this session. For files over 500 lines, use offset/limit.

### Responses
Don't echo back file contents you just read. Don't narrate tool calls. Keep explanations proportional to complexity.

---

## Skills

Skills live globally at `~/.claude/skills/` (symlinked from `dotfiles/skills/`). They load in every Claude Code session regardless of cwd. Per-repo skills (e.g. `/localai`, `/hermes-update`) live committed in their repo's `.claude/skills/` and load only when Claude is started inside that repo.

| Skill | Mode | Notes |
|-|-|-|
| `/commit [options]` | inline | Smart conventional commits. `--split`, `--amend`. |
| `/pr [action]` | inline | GitHub PR workflow (create / status / merge). |
| `/ship` | inline | Full flow: check → review → commit → PR → CodeRabbit → merge → release. |
| `/git-cleanup` | inline | Group noisy branch commits. |
| `/check` | MCP (sideclaw) | Format, lint, typecheck, test. |
| `/review` | MCP (sideclaw) | Multi-angle review + CodeRabbit CLI. |
| `/research <query>` | MCP (sideclaw) | Context7 + WebSearch + WebFetch with cross-verification. |
| `/grill` | inline | Question until clear direction, generate PRD. |
| `/implement` | inline (sonnet subagent) | Guided implementation with research + explore + check. |
| `/browse` | fork (haiku) | Chrome DevTools debugging. |
| `/analyze` | subprocess (haiku) | Deep static analysis (fallow). |
| `/otel [env] [intent]` | subprocess (haiku) | Debug OTEL traces/logs/metrics in ClickHouse. |
| `/read-drawing` | subprocess (haiku) | Interpret Excalidraw + parse JSON. |
| `/secrets` | inline | 1Password vault ops (uses `op_account_for_cwd`). |
| `/cloudflare` | inline | Cloudflare config (uses `op_account_for_cwd`). |
| `/upgrade-deps` | inline | Dependency upgrade assistant. |
| `/excalidraw-diagram` | inline | Create Excalidraw diagrams. |
| `/frontend-design` | inline | Production-grade frontend interfaces. |
| `/skill-creator` | inline | Create, modify, and test skills. |
| `/ralph [cmd]` | inline (sonnet) | Autonomous multi-group implementation loop. |
| `/update-agent-rules` | inline | Sync upstream agent rules (React, TanStack, Elysia best practices) into `dotfiles/rules/`. |

**Per-repo skills** that only load when Claude is started inside their repo:
- `~/SourceRoot/dotfiles/.claude/skills/` — `/localai` (manage mlx-audio + Fish-S2-Pro stack)
- `~/SourceRoot/hermes-agent/.claude/skills/` — `/hermes-validate`, `/hermes-update` (manage Hermes Agent)
- Other SourceRoot repos with their own project skills (e.g. `homelab/.claude/skills/{audit,docs,upgrade-stack}/`, `vps/.claude/skills/{audit,docs}/`, `sideclaw/.claude/skills/claude-cli/`, `free-planning-poker/.claude/skills/release-fpp/`, `homelab-private/.claude/skills/prowlarr/`, `ticktick-raycast/.claude/skills/{raycast-extension,ticktick-api}/`).

---

## Git Workflow

```
/commit          → Commit one logical concern at a time
/git-cleanup     → Group noisy commits (if ≥3 on branch)
/ship            → Full flow: check → review → PR → CodeRabbit → merge → release
```

Or just `/ship` — auto-detects state. `/pr create` errors on default branch, proposes branch rename, runs `/commit` if uncommitted, offers `/git-cleanup` if ≥3 commits, runs `/check` pre-flight. `/pr status` warns on uncommitted/unpushed work, shows CodeRabbit feedback, offers to implement fixes.

---

## Task Queue (`sc-queue.md`)

Per-repo `sc-queue.md` for unattended multi-task sessions. The Stop hook pops the next task and injects it as the next user message. Blocks separated by `\n---\n`. Append `STOP` as a standalone block to end the session.

---

## Shell Commands

Git worktree management via **wtp** (`brew install satococoa/tap/wtp`):

| Command | Purpose |
|-|-|
| `wtp add <branch>` | Create worktree with hooks |
| `wtp cd <name>` | Navigate to worktree |
| `wtp remove <name> --with-branch` | Remove worktree + branch |
| `gback` | Alias for `git reset --soft HEAD~1` |

Worktrees land at `<repo>.worktrees/<branch>` — adjacent to the repo, so the 1Password routing helper still resolves the right account via the worktree's main repo path.

---

## Development Workflow

### Standard Flow
1. Understand request thoroughly
2. Propose plan if non-trivial (wait for approval)
3. Implement changes (use `/implement` for guided flow)
4. Run `/check` for validation
5. Run `/commit`
6. Run `/ship` for PR + review + merge + release

### Validation
- Check `package.json` (or repo Makefile) for available scripts.
- Use `/check` for validation (sideclaw MCP — schema-validated, quota-aware).
- Fix errors in changed files only (don't refactor untouched code).
- I validate running apps manually (don't run `dev` servers for me).

### When Something Seems Wrong
Flag explicitly rather than silently working around:
- Tool returns unexpected output → stop and report.
- File missing where expected → check git status.
- Validation fails on untouched files → report only.
- Code/patterns contradict CLAUDE.md → flag it.

---

## CLAUDE.md hierarchy

Two layers — no workspace-level intermediate file:

- **Global** (`~/.claude/CLAUDE.md` ← `dotfiles/config/global.CLAUDE.md`): this file. Loads in every session.
- **Per-project** (`<repo>/CLAUDE.md`): project-specific conventions. Loads when Claude is started inside the repo.

Global rules (always-on conventions):
- `~/.claude/rules/` ← `dotfiles/rules/` — attribution, commits, TypeScript, security, code style, formatting, docker-makefile, research-first, visx-charts.

Global skills:
- `~/.claude/skills/` ← `dotfiles/skills/` (global skills).

Per-project rules (scoped patterns with `paths:` frontmatter): `<repo>/.claude/rules/`.
Per-project skills (committed project skills): `<repo>/.claude/skills/`.

Update CLAUDE.md in the same commit as related code changes. CLAUDE.md-only changes use `docs:` prefix.
