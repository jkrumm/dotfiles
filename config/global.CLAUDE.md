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
- **PR-required repos** (`/ship` uses PR flow; `protect-branches.ts` enforces): `basalt-ui` (NPM published — also always a separate commit), `free-planning-poker`, `rollhook`, `rollhook-action`. Everything else is direct-to-master. The list is a single source of truth in `dotfiles/config/pr-required-repos.json` (symlinked to `~/.claude/pr-required-repos.json`), read by both the hook and `github-config.sh` — edit that file, not the code.
- **GitHub branch protection has two tiers** (applied by `make github-config`): PR-required repos + any repo with a collaborator get the **full** ruleset (require PR to master); all other public repos get the **lite** ruleset (no PR rule, just no-force/no-deletion/linear) so direct pushes are clean with no bypass warning. Random people can never push to your repos regardless; private repos can't be protected server-side on the free tier (gap is documented in the script).
- **All `~/IuRoot/` repos require PRs** (against `main`). Detected by path — no list to maintain.

#### Repository map

| Repo | Purpose |
|-|-|
| `dotfiles` | This setup — Claude Code config, hooks, skills, rules, localai stack (retired — see `audio-proxy`). Source of truth. |
| `homelab` | Main homelab stack (25+ containers) + Uptime Kuma config. |
| `homelab-private` | **Private stack** (do not reference outside this repo): media pipeline behind ProtonVPN, Jellyfin, **Tailscale ACLs**. **Never reference services, hostnames, or details of this repo from anywhere else** — not in `homelab`, not in CLAUDE.md, not in commits outside this repo. Self-contained. |
| `vps` | Production VPS (Cloudflare Tunnel, three compose stacks: networking, infra, monitoring). |
| `sideclaw` | Claude Code MCP daemon — `check` / `review` / `research` / `implement` tools, all running on DeepSeek-V4-Pro (EU/GDPR) via a local LiteLLM bridge so workers never touch Max quota. Hosts notes and Excalidraw integration. |
| `hermes-agent` | Hermes — Mac Mini-only personal AI (Slack interface, Sonnet 4.6 brain, seven skill domains). |
| `usage-tracker` | Local SQLite token/cost telemetry. Per-source collectors (Claude Code, LiteLLM bridge, Hermes, Feuer, OpenCode, audio-proxy) normalize into one `usage_record` table with central pricing; LaunchAgent ingests every 15 min. Staging layer for an eventual Argo dashboard. |
| `audio-proxy` | OpenAI-compatible audio proxy on `:7716` (macOS LaunchAgent) in front of the IU unified audio endpoint. STT: downgrades `gpt-4o-transcribe` to `json` and synthesizes the rich envelope (timestamps) clients demand, plus language steering. TTS: passthrough, plus a native **Gemini 3.1 Flash** expressive pipeline (prep-LLM chunking → per-chunk synth → ffmpeg MP3/Opus, default voice Charon) that Hermes consumes. Logs usage to local SQLite (ingested by `usage-tracker`). |
| `basalt-ui` | Tailwind v4 design system (NPM: `basalt-ui`). **Always commit separately from consumer apps.** |
| `basalt-ui-playground` | Component preview / dev environment for basalt-ui. |
| `argo` | Personal API server + dashboard — the AI-agent backbone. Hermes and other agents call it to read TickTick tasks, Gmail, calendar (personal + work), Teams messages, Garmin health (HRV, sleep, recovery, daily metrics), strength training (workouts, e1RM, volume), and homelab/VPS state (UptimeKuma, Docker). Elysia + Bun + Postgres + Drizzle; OpenAPI spec at `argo.jkrumm.com/api/openapi/json` is the agent contract. |
| `rollhook` | Webhook-triggered zero-downtime rolling deployments for Docker Compose. |
| `rollhook-action` | GitHub Action wrapping rollhook. |
| `modelpick` | Decides which models to use for what (LLM/TTS/STT) and keeps it current — ranks IU unified-endpoint models against external leaderboards + live probes, records my committed stack, flags drift. **Source of truth for model-choice rationale** (`docs/decisions/`); see its `CLAUDE.md`. TanStack Start + Mantine + Drizzle/Postgres. |
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
The main session is the **orchestrator**. Keep its context clean: hold the plan, the user's intent, and the cross-skill state. Push verbose work (logs, diffs, fetch bodies, test output) into one of the four execution modes below. The orchestrator **decides and verifies** — it should not be the thing grinding through reads, multi-file edits, and validation loops. Delegate by default (see **Offloading discipline** below). **Don't switch the orchestrator's model mid-session** — that invalidates the prompt cache for at least one turn and is the biggest avoidable cost in a long conversation.

### Four execution modes for skills

> The **why** behind this framework (model tiers, the cache argument, EU/GDPR routing) is consolidated in `modelpick/docs/decisions/execution-modes.md`. The directives below are the operational contract — keep them here.

| Mode | When to use | Cost profile |
|-|-|-|
| **inline** (no `model:` frontmatter) | Conversational/orchestrating skills that benefit from session context: `commit`, `pr`, `ship`, `git-cleanup`, `secrets`, `grill`, `implement`. | Runs on the current session model. Zero switch cost. Output lands in main context — keep it short. |
| **subprocess** (`claude -p` shelled from the skill body via the `claude_iu` / `claude_bridge` zsh helpers in `claude.zsh` — never hand-rolled env blocks) | Read-heavy work with large isolated output that doesn't need structured guarantees: `analyze`. | Free of Max quota (IU per-token). Output fully isolated. Cold spawn ~500ms. No prompt cache reuse across calls. `claude_iu` = IU native Anthropic transport (Claude models like haiku); `claude_bridge` = LiteLLM bridge → DeepSeek-V4-Pro / -Flash (EU/GDPR, Azure Spain), used for EU-bound subprocess work (`analyze` runs on `DeepSeek-V4-Flash`). |
| **MCP (sideclaw)** | Heavy work that benefits from JSON-schema output: `check`, `review`, `research`, `implement`, `otel`. | Schema-validated structured output (`runSession` Zod-validates worker output via `zodValidator` — the worker ignores `--json-schema`). Workers run on DeepSeek-V4-Pro (EU) via the LiteLLM bridge — IU per-token billing, zero Max quota. Best for things `/ship` parses programmatically. **`check`/`review`/`research`/`implement` are async** — see the async-job contract below. |
| **fork** (`context: fork`) | Wrap deferred MCP tools whose responses are token-heavy: `browse` (chrome-devtools). | Burns Max quota (uses Agent tool). Use only when sideclaw can't host the MCP and inline output would bloat main. |

### Routing decisions
- Does the skill need the orchestrator's conversation context? → **inline**
- Is the work fully describable by inputs and the output verbose? → **subprocess**
- Do callers parse the output programmatically, or does the run last >30s? → **MCP (sideclaw)**
- Does it need a live MCP server the main session has registered (e.g. chrome-devtools)? → **fork**

**Never** put `model: haiku|sonnet` in skill frontmatter when the skill body already shells out to `claude -p` with its own `--model` flag — that creates a redundant main-thread switch for trivial orchestration.

### Offloading discipline — delegate by default

The orchestrator's turns are the scarcest, most expensive resource (Max quota + context). **Bias hard toward pushing work off it.** Before doing multi-file edits, deep reads, or validation inline, ask: *can a DeepSeek worker or subagent do this and hand back only the conclusion?* If the work is fully describable by inputs and the output is verbose, it belongs in a worker.

Delegate-by-default rules:
- **Mechanical edits with a settled plan → `mcp__sideclaw__implement`** (DeepSeek, off Max). Don't hand-edit 3+ files yourself once the plan is clear — write the task + context, offload, review the returned diff. **It's a literal executor:** it does exactly what the spec says, no more — so give acceptance criteria + exact file paths + the precise mapping/shape. Vague specs get vague results. **Fitness check before routing:** offload only work that is (a) fully specified, (b) independently verifiable, and (c) latency-tolerant — a worker run is 10–20 min wall-clock even for ~50-line changes, so it's worth it *only* when you parallelize other work alongside it. Small (1-2 file), coupled, or latency-sensitive edits stay inline; don't sit and wait on a worker. Verify every returned line against source before committing — the worker's report is not a substitute for review. **On non-Node repos (Python/uv, Rust, Go), pass `validateCmd`** (the exact self-verify command, e.g. `.venv/bin/pyrefly check && .venv/bin/pytest -q`) — without it the worker burns its whole turn budget, and may hit the 20-min timeout, hunting for the test runner before its edits ever validate.
- **Any validation → `mcp__sideclaw__check`.** Never run format/lint/tsc/test loops inline. It auto-detects Node/Bun, Python/uv, Makefile, Rust, and Go; on non-Node repos pass `commands` (e.g. `['.venv/bin/ruff check', '.venv/bin/pytest -q']`) to skip ecosystem discovery.
- **Code review → `/review`** (`mcp__sideclaw__review`, off Max, dynamic angle router).
- **Library/API/version questions → `/research`** (`mcp__sideclaw__research`). Never answer from memory (see `research-first` rule).
- **Exploration → `Agent` (Explore subagent).** Never read 10 files into the orchestrator to find one thing.
- **Anything past a one-line edit → reach for `/implement`.** It encodes the tier scaling and the delegation choices — don't reinvent that judgment ad hoc.

**sideclaw async-job contract (important).** `mcp__sideclaw__{check,review,research,implement}` are **asynchronous**: the call returns `{ jobId, status }` immediately — **not** the result. The job runs in sideclaw's always-on HTTP server (durable across `/mcp` reconnects) on DeepSeek, off Max. To get the result:
1. Submit → note the `jobId`.
2. Call **`mcp__sideclaw__job_wait({ jobId })`** — it blocks ~50s with heartbeats and returns the result when the job finishes. If it returns `stillRunning: true`, call it again with the same `jobId` (loop until false). Use `job_status` for a non-blocking peek while doing other work.
3. Read `result` (the tool's structured output) when `status: "done"`; read `error` on `"failed"`/`"interrupted"`.

This is what makes long (10-min+) offload safe — a worker run never blocks/destabilizes the MCP transport. **Parallel fan-out:** submit N jobs in one turn (each returns a jobId), then `job_wait` each; a global concurrency cap queues the excess so you can't 429 the bridge. Don't treat the submit call as the answer.

**File ownership while a job runs.** Treat a running `implement` job as the *exclusive owner* of the files it touches until it reaches a terminal state. Do NOT run your own validation (`check`, a test suite, a build) over those paths while the job is still editing — you'll race its half-written intermediate state and hit spurious failures (a fixture `FileExistsError`, a type error mid-edit) that vanish once it settles. Parallelize on *disjoint* files only; for the job's own files, wait for `done` before touching or validating them. If a job's `status` stays `running` long past when you expect (the result is opaque mid-flight — there's no per-turn progress signal yet), don't trust the lifecycle blindly: peek at the files/`git status` to see whether the work actually landed.

The orchestrator holds the plan and the verdicts, not the raw material.

### Parallel & background orchestration

Cheapest parallelism first — escalate a tier only when the one below can't do the job:

| Tier | Mechanism | Max cost | Use when |
|-|-|-|-|
| 1 | **Parallel `mcp__sideclaw__*` calls in one turn** | ~0 (DeepSeek workers) | Independent verifiable work: check N repos, review + research at once, implement N independent file groups. The default for fan-out. |
| 2 | **subprocess** (`claude_iu` / `claude_bridge`) | ~0 (IU per-token) | Read-heavy isolated output. |
| 3 | **Background `Agent`** (`run_in_background: true`) driving sideclaw MCP tools | Moderate (thin Max orchestrator) | Long, multi-step work you want to detach from and resume (`SendMessage`). Keep the bg agent thin — it delegates to DeepSeek workers, doesn't grind itself. |
| 4 | **Foreground `Agent` / subagent on Opus** | Full Max (isolated cache) | Novel hard logic needing the best model. |
| 5 | **Agent teams / `/ultrareview`** | N× Max or $$$ cloud | Genuinely hard parallel reasoning only. Rarely worth it for personal-infra repos. |

Key facts:
- **Parallel MCP calls are free parallelism** — emit several `mcp__sideclaw__*` tool_use blocks in a single turn; they run as concurrent DeepSeek workers while the orchestrator just awaits. Under-used — prefer it over serial calls whenever the units are independent.
- **Background agents and agent teams run on Max** — they buy detachment and coordination, not cheap parallelism. A background agent that fans out to sideclaw MCP keeps its own Max cost low.
- **Worktree isolation is an up-front, orchestrator-level decision — not something `/implement` does mid-flow.** If a task needs an isolated branch (parallel streams, risky change), create the worktree at the start (`wtp add <branch>`) and run the *whole* session there — orchestrator and every sideclaw worker (they inherit the `cwd` you pass) work in the same tree. Don't spawn worktree-isolated sub-agents ad hoc; that splits work across trees you then have to reconcile.
- **`Task*` tools** (TaskCreate/List/Update) are a built-in coordination layer (lead creates, workers claim, deps unblock) — not MCP-backed, they don't reach sideclaw.
- **Routines / `/schedule`** run in Anthropic's cloud and **cannot reach the local sideclaw MCP** (localhost) or the LiteLLM bridge — don't route sideclaw offload through them.

### API offloading (manual)
For ad-hoc heavy work outside a skill. Use `ANTHROPIC_AUTH_TOKEN` (not `ANTHROPIC_API_KEY`) and strip any inherited key: with a logged-in Max session the `claude` CLI sends its Max OAuth bearer to the IU gateway → 401. `AUTH_TOKEN` forces `Authorization: Bearer <IU-token>`, which the gateway accepts and which takes precedence over the login.
```bash
env -u ANTHROPIC_API_KEY \
ANTHROPIC_AUTH_TOKEN=$(security find-generic-password -s claude-sdk-api-key -w) \
ANTHROPIC_BASE_URL=$(security find-generic-password -s claude-sdk-base-url -w) \
  claude -p --model haiku "task here"
```

### File reading
Read files with purpose. Use Grep to locate relevant sections before reading entire large files. Never re-read a file you've already read in this session. For files over 500 lines, use offset/limit.

### Responses
Don't echo back file contents you just read. Don't narrate tool calls. Keep explanations proportional to complexity.

---

## Skills

Skills live globally at `~/.claude/skills/` (symlinked from `dotfiles/skills/`). They load in every Claude Code session regardless of cwd. Per-repo skills (e.g. `/iu-endpoint`, `/hermes-update`) live committed in their repo's `.claude/skills/` and load only when Claude is started inside that repo.

| Skill | Mode | Notes |
|-|-|-|
| `/commit [options]` | inline | Smart conventional commits. `--split`, `--amend`. |
| `/pr [action]` | inline | GitHub PR workflow (create / status / merge). |
| `/ship` | inline | Full flow: check → review → commit → PR → CodeRabbit → merge → release. |
| `/git-cleanup` | inline | Group noisy branch commits. |
| `/check` | MCP (sideclaw) | Format, lint, typecheck, test. |
| `/review` | MCP (sideclaw) | Multi-angle review (dynamic angle router) + CodeRabbit CLI. `--deep` adds native correctness + security on Max. |
| `/research <query>` | MCP (sideclaw) | Context7 + Tavily + curl with cross-verification (runs on DeepSeek-V4-Pro). |
| `/grill` | inline | Question until clear direction, generate PRD. |
| `/implement` | inline (sonnet subagent) | Guided implementation; tiers scale to parallel sideclaw offload + subagents. |
| `/browse` | fork (haiku) | Chrome DevTools debugging. |
| `/analyze` | subprocess (haiku) | Deep static analysis (fallow). |
| `/otel [env] [intent]` | MCP (sideclaw) | Debug OTEL traces/logs/metrics in ClickHouse (worker uses `query.py`, kept in dotfiles). |
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
- `~/SourceRoot/dotfiles/.claude/skills/` — `/iu-endpoint` (validate IU endpoint + discover models); `/localai` (**retired** — local mlx-audio/Fish stack, replaced by the cloud audio-proxy)
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

## Shell Commands

Git worktree management via **wtp** (`brew install satococoa/tap/wtp`):

| Command | Purpose |
|-|-|
| `wtp add <branch>` | Create worktree with hooks |
| `wtp cd <name>` | Navigate to worktree |
| `wtp remove <name> --with-branch` | Remove worktree + branch |
| `gback` | Alias for `git reset --soft HEAD~1` |

Worktrees land at `<repo>.worktrees/<branch>` — adjacent to the repo, so the 1Password routing helper still resolves the right account via the worktree's main repo path.

### Node.js runtime
Use **fnm**, not nvm, for Node version management. Ensure you don't suggest nvm commands or rely on nvm-specific paths.

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
- Use `/check` for validation (sideclaw MCP — schema-validated, runs on the DeepSeek-V4-Pro EU bridge).
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
- `~/.claude/rules/` ← `dotfiles/rules/` — attribution, commits, TypeScript, security, code style, formatting, docker-makefile, dependency-hygiene, research-first, visx-charts.

Global skills:
- `~/.claude/skills/` ← `dotfiles/skills/` (global skills).

Per-project rules (scoped patterns with `paths:` frontmatter): `<repo>/.claude/rules/`.
Per-project skills (committed project skills): `<repo>/.claude/skills/`.

Update CLAUDE.md in the same commit as related code changes. CLAUDE.md-only changes use `docs:` prefix.
