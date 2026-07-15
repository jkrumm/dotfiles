# Claude Code — Personal Configuration

## Personal Context

- **Name:** Johannes Krumm
- **Role:** Solo Senior Full-Stack Developer and TechLead
- **Working Style:** Iterative, careful, quality-focused — prefer multiple small steps over one big change
- **Language:** User may write in German for chat; ALL written artifacts (code, commits, docs, specs) MUST be in English. AI responses default to English unless clarifying requirements.

---

## Workspaces

The Mac has three workspace "regions" plus a cold Obsidian backup. Skills, hooks, and rules are **global** (`~/.claude/`); workspace conventions live in this file; each repo can still add its own `CLAUDE.md`.

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
| `dotfiles` | This setup — Claude Code config, hooks, skills, rules, localai stack (retired — see `audio-gateway`). Source of truth. |
| `homelab` | Main homelab stack (25+ containers) + Uptime Kuma config. |
| `homelab-private` | **Private stack** (do not reference outside this repo): media pipeline behind ProtonVPN, Jellyfin, **Tailscale ACLs**. **Never reference services, hostnames, or details of this repo from anywhere else** — not in `homelab`, not in CLAUDE.md, not in commits outside this repo. Self-contained. |
| `vps` | Production VPS (Cloudflare Tunnel, three compose stacks: networking, infra, monitoring). |
| `sideclaw` | Claude Code MCP daemon — `check` / `review` tools, running on DeepSeek-V4-Pro via a local LiteLLM bridge so workers never touch Max quota. (`research` migrated 2026-06 to the standalone `research-gateway` service; `implement` retired 2026-06 — implementation moved to the native Sonnet 4.6 `@implementer` subagent on Max.) Hosts notes and Excalidraw integration. |
| `research-gateway` | Standalone agentic research HTTP service (Elysia + Bun + AI SDK v6) on the VPS at `research.jkrumm.com` — **Tailscale-only** (grey-cloud DNS-only A record → VPS Tailscale IP, not behind the Cloudflare Tunnel; same pattern as `audio-gateway`). Replaces sideclaw's `/research`. One research brain over a bearer-auth'd typed contract (REST + OpenAPI) plus a bearer MCP facade at `/mcp` exposing an async job trio — `research` (submit → jobId) + `job_wait`/`job_status`, mirroring sideclaw's submit→poll contract so long/deep research never trips the client's ~60s MCP HTTP timeout; bearer is defense-in-depth over the tailnet gate. Runs on IU models, off Max; consumed via the `/research` skill (Mac/tailnet only — cloud routines can't reach it). |
| `hermes-agent` | Hermes — Mac Mini-only personal AI (Slack interface, Sonnet 4.6 brain, seven skill domains). |
| `usage-tracker` | Local SQLite token/cost telemetry. Per-source collectors (Claude Code, LiteLLM bridge, Hermes, Feuer, OpenCode) normalize into one `usage_record` table with central pricing; LaunchAgent ingests every 15 min. Staging layer for an eventual Argo dashboard. |
| `audio-gateway` | OpenAI-compatible audio service (STT + expressive Gemini TTS) — VPS Docker container at `audio-gateway.jkrumm.com`, reached over the tailnet. Consumed by Hermes (Mac mini), Argo, and local MacWhisper (`https://audio-gateway.test/v1`). Source at `~/SourceRoot/audio-gateway`. |
| `basalt-ui` | Tailwind v4 design system (NPM: `basalt-ui`). **Always commit separately from consumer apps.** |
| `argo` | Personal API server + dashboard — the AI-agent backbone. Hermes and other agents call it to read TickTick tasks, Gmail, calendar (personal + work), Teams messages, Garmin health (HRV, sleep, recovery, daily metrics), strength training (workouts, e1RM, volume), and homelab/VPS state (UptimeKuma, Docker). Elysia + Bun + Postgres + Drizzle; OpenAPI spec at `argo.jkrumm.com/api/openapi/json` is the agent contract. |
| `rollhook` | Webhook-triggered zero-downtime rolling deployments for Docker Compose. |
| `rollhook-action` | GitHub Action wrapping rollhook. |
| `modelpick` | Decides which models to use for what (LLM/TTS/STT) and keeps it current — ranks IU unified-endpoint models against external leaderboards + live probes, records my committed stack, flags drift. **Source of truth for model-choice rationale** (`docs/decisions/`); see its `CLAUDE.md`. TanStack Start + Mantine + Drizzle/Postgres. |
| `brain` | Private second brain — a git-backed Obsidian vault at `~/SourceRoot/brain`, shared by Claude Code (`/brain`) and Hermes. Two layers: a top-level `wiki/` tree = agentic knowledge (strict lint); the PARA `03_Projects`/`04_Areas` = curated human surface (light lint) that links down into `wiki/` (no `Resources` tier — reference material is a `wiki/` note or an Area page). Agent door: `obsidian-cli`. LiveSync is continuous cross-device backup; `git diff` is the deliberate review gate. Direct-to-master; validated by `vault-lint`. |
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

### `~/Obsidian/Vault/` — cold backup (not the live vault)

The live vault relocated into `~/SourceRoot/brain` (git-backed, LiveSync-synced, see the `brain` repo-map row and the `/brain` skill). `~/Obsidian/Vault` is retained only as a cold backup — leave it closed, do not read/write it. Tasks managed externally in TickTick.

---

## 1Password routing

A helper resolves the right `--account` automatically based on cwd (worktree-safe via `git rev-parse --git-common-dir`):

```bash
op_account_for_cwd  # → "tkrumm" or "careerpartner"
op_run              # convenience: invokes `op --account "$(op_account_for_cwd)" ...`
```

Helper lives in `~/.zsh/conf.d/secrets.zsh`. Skills that touch 1Password (`/secrets`, `/cloudflare`, `/otel`) call the helper instead of hardcoding `tkrumm`. SourceRoot-only infra scripts (e.g. `dotfiles/scripts/github-config.sh`) may keep `tkrumm` hardcoded.

### Headless secrets — the `secrets-run` shim (mini vs MacBook)

The always-on **Mac mini is headless**: `op` is **not** interactively signed in, so a direct
`op read` / `op run` there **hangs** on the biometric prompt (no human to approve it). Secrets
instead resolve from an age-encrypted, `op://`-keyed **cache** via **`secrets-run`** — a drop-in
`op` shim. The active backend is injected into context each session by a SessionStart hook
(`machine-role.ts`); trust it over guessing.

- **`cache` backend (mini)** — `secrets-run` decrypts the offline cache; no `op`, no network, no
  prompt. **Do not call `op` directly on the mini** (it hangs). Use the shim.
- **`op` backend (MacBook, human present)** — `secrets-run` passes through to live biometric `op`.

Same app code + same `op://` refs on both machines; only `~/.config/secrets/backend`
(`cache`|`op`) differs. Interface mirrors `op`:

```bash
secrets-run read op://vault/item/field                       # ~ op read
secrets-run run [--env-file=<tpl>]... -- <cmd>               # ~ op run (--env-file repeats; last wins)
```

Which refs the mini may hold offline is the **explicit allowlist** `dotfiles-private/headless.refs`
— editing it + `make secrets-seed` (biometric, present-human, MacBook or interactive-mini) seals the
cache. **Tiering guardrail:** only T0/T1 refs are ever cached; `op://Private/*` and T2/prod are
refused by the seed (argo's `op://vps/argo/*` is an owner-classified personal exception). Full model:
`dotfiles-private/{PRD.md,docs/design.md,docs/runbook.md}`; ops via **`/secrets`**. **Any edit to
`secrets-run` → full guardrail:** `make secrets-test` + `shellcheck` + design.md/security-review.md
in the same change + an adversarial `/review` (it is the sole secret path on the mini).

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
Never add AI/tool attribution to any artifact (code, commits, PRs, docs). Full rule: always-on `~/.claude/rules/attribution.md`.

---

## Token Efficiency

### Orchestrator role
The main session is the **orchestrator**. Keep its context clean: hold the plan, the user's intent, and the cross-skill state. Push verbose work (logs, diffs, fetch bodies, test output) into one of the execution modes below. The orchestrator **decides and verifies** — it should not be the thing grinding through reads, multi-file edits, and validation loops. Delegate by default (see **Offloading discipline** below). **Don't switch the orchestrator's model mid-session** — that invalidates the prompt cache for at least one turn and is the biggest avoidable cost in a long conversation.

### Execution modes

> The **why** behind this framework (model tiers, the cache argument) is consolidated in `modelpick/docs/decisions/execution-modes.md`. The directives below are the operational contract — keep them here.

| Mode | When to use | Cost / notes |
|-|-|-|
| **inline** (no `model:` frontmatter) | Conversational/orchestrating skills that need session context: `commit`, `pr`, `ship`, `git-cleanup`, `secrets`, `grill`, `implement`. | Runs on the session model. Output lands in main context — keep it short. |
| **native subagent** (`Agent` tool / `~/.claude/agents/`) | The primary offload. `@implementer` (Sonnet, settled implementation), `Explore` (Haiku, read-only search), an Opus subagent (novel-hard logic). | On Max but **own prompt cache** — no orchestrator-cache penalty. Fresh isolated context; returns a summary; edits hit the live checkout. |
| **MCP (sideclaw)** | Heavy work that benefits from schema-validated output, off Max: `check`, `review`, `otel`. | DeepSeek-V4-Pro via the LiteLLM bridge — zero Max quota; `runSession` Zod-validates the output. **Async** — see the job contract below. |

*Niche:* `/analyze` shells `claude_bridge` (DeepSeek subprocess, isolated output, off Max); `/browse` forks chrome-devtools (deferred MCP, on Max). Details live in those two skills.

### Routing decisions
- Needs the orchestrator's conversation context? → **inline**
- Settled, self-contained, verifiable work to keep off the orchestrator's context? → **native subagent** (`@implementer` / `Explore` / Opus)
- Parsed output, or a long (>30s) verifiable run you want off Max? → **MCP (sideclaw)**

### Offloading discipline — delegate by default

**Bias hard toward pushing work off the orchestrator** (the *Orchestrator role* above is the why). Before doing multi-file edits, deep reads, or validation inline, ask: *can a worker or subagent do this and hand back only the conclusion?* If the work is fully describable by inputs and the output is verbose, delegate it.

Delegate-by-default rules:
- **Settled multi-file edits → the native `@implementer` subagent** (Sonnet 4.6, effort `high`; defined at `~/.claude/agents/implementer.md`). It runs on Max but in its **own prompt cache** — switching model *inside* a named subagent does **not** invalidate the Opus orchestrator's cache (only forks share the parent's), so the "never switch the orchestrator's model mid-session" rule does not apply here. It loads the full CLAUDE.md hierarchy, so it writes house-style code an external worker can't. Give it a complete brief — exact paths, the change/shape, acceptance criteria, intent, scope limits; it's a literal executor *with judgment*, not a planner. **Fitness check:** delegate work that is (a) fully specified and (b) independently verifiable — the latency term is **gone** (Sonnet returns in seconds-to-minutes, not the 10–20 min DeepSeek async), so offload to protect orchestrator **context**, not to save quota. Small/coupled/tight-iteration edits stay inline. It runs the repo's own validators itself; still verify every returned line against source before committing — the report is a claim, not proof. **Editorial distillation stays with the reader:** judgment tightly coupled to source you've just loaded (migrating/distilling notes, summarizing a doc in context) is *not* a delegation candidate even when it writes several files — handing it off means re-passing all the source in the brief. Delegate the mechanical, fully-specified edits; keep the coupled editorial pass inline.
- **Any validation → `mcp__sideclaw__check`.** Never run format/lint/tsc/test loops inline. It auto-detects Node/Bun, Python/uv, Makefile, Rust, and Go; on non-Node repos pass `commands` (e.g. `['.venv/bin/ruff check', '.venv/bin/pytest -q']`) to skip ecosystem discovery.
- **Code review → `/review`** (`mcp__sideclaw__review`, off Max, dynamic angle router).
- **Library/API/version questions → `/research`** (`mcp__research-gateway__research`). Never answer from memory (see `research-first` rule).
- **Exploration → `Agent` (Explore subagent).** Never read 10 files into the orchestrator to find one thing.
- **Anything past a one-line edit → reach for `/implement`.** It encodes the tier scaling and the delegation choices — don't reinvent that judgment ad hoc.

**Reaching `@implementer` (native subagent vs the `/implement` skill).** The Opus orchestrator *can* auto-delegate to `@implementer` by `description` match, but auto-delegation is unreliable — it often just does the work inline. Fire it deterministically via **explicit `@implementer`** or **`/implement`** (which invokes it at its implement step). The two are **complementary, not competing** — there is no native "auto-run a workflow for everything" (workflows / `ultracode` are explicit opt-in), so hand-orchestrating isn't fighting a smarter native path. Division of labor: small fully-specified edit → inline or `@implementer`; multi-step feature needing research-gating + validation → `/implement`; independent parallel groups → parallel `@implementer` on disjoint file groups. Don't run the full `/implement` pipeline on a one-file change. **Research reaches the worker via the brief first** — a subagent can't see research you already did, so bake resolved library facts (versions / signatures / imports) into the brief; the implementer's own `/research` (Skill → research-gateway) is a conditional fallback for what the brief omits. Its `description` deliberately omits "use proactively" so the literal-executor never grabs under-specified or mid-planning work.

**sideclaw async-job contract (important).** `mcp__sideclaw__{check,review}` are **asynchronous**: the call returns `{ jobId, status }` immediately — **not** the result. The job runs in sideclaw's always-on HTTP server (durable across `/mcp` reconnects) on DeepSeek, off Max. To get the result:
1. Submit → note the `jobId`.
2. Call **`mcp__sideclaw__job_wait({ jobId })`** — it blocks ~50s with heartbeats and returns the result when the job finishes. If it returns `stillRunning: true`, call it again with the same `jobId` (loop until false). Use `job_status` for a non-blocking peek while doing other work.
3. Read `result` (the tool's structured output) when `status: "done"`; read `error` on `"failed"`/`"interrupted"`.

This is what makes long (10-min+) offload safe — a worker run never blocks/destabilizes the MCP transport. **Parallel fan-out:** submit N jobs in one turn (each returns a jobId), then `job_wait` each; a global concurrency cap queues the excess so you can't 429 the bridge. Don't treat the submit call as the answer.

**File ownership while an `@implementer` subagent runs.** A running `@implementer` subagent is the *exclusive owner* of the files it touches until it returns — its `Edit`/`Write` land in your **live checkout** by default. Do NOT run your own validation (`/check`, a test suite, a build) or edits over those paths mid-flight — you'll race its half-written state and hit spurious failures that vanish once it settles. Parallelize implementers on *disjoint* files only. (sideclaw's remaining `check`/`review` jobs are read-only, so this caveat doesn't apply to them.)

The orchestrator holds the plan and the verdicts, not the raw material.

### Parallel & background orchestration

Cheapest parallelism first — escalate a tier only when the one below can't do the job:

| Tier | Mechanism | Max cost | Use when |
|-|-|-|-|
| 1 | **Parallel `mcp__sideclaw__*` calls in one turn** | ~0 (DeepSeek workers) | Independent verifiable work: check N repos, review several at once. The default for fan-out. |
| 2 | **subprocess** (`claude_iu` / `claude_bridge`) | ~0 (IU per-token) | Read-heavy isolated output. |
| 3 | **Background `Agent`** (`run_in_background: true`) driving sideclaw MCP tools | Moderate (thin Max orchestrator) | Long, multi-step work you want to detach from and resume (`SendMessage`). Keep the bg agent thin — it delegates to DeepSeek workers, doesn't grind itself. |
| 4 | **Foreground `Agent` / subagent on Opus** | Full Max (isolated cache) | Novel hard logic needing the best model. |
| 5 | **Agent teams / `/ultrareview`** | N× Max or $$$ cloud | Genuinely hard parallel reasoning only. Rarely worth it for personal-infra repos. |

Key facts:
- **Parallel MCP calls are free parallelism** — emit several `mcp__sideclaw__*` tool_use blocks in a single turn; they run as concurrent DeepSeek workers while the orchestrator just awaits. Under-used — prefer it over serial calls whenever the units are independent.
- **Implementation fan-out is parallel `@implementer` (Sonnet) subagents** on *disjoint* file groups — N× Sonnet on Max (detachment, not free); the retired sideclaw `implement` is no longer a lane.
- **Background agents and agent teams run on Max** — they buy detachment and coordination, not cheap parallelism. A background agent that fans out to sideclaw MCP keeps its own Max cost low.
- **Worktree isolation is opt-in and up-front — only when you ask for it.** Subagent edits hit your live checkout by default (see *File ownership* above). If a task needs an isolated branch (parallel streams, a risky change), say so at the start: use Claude Code's native worktree feature for the session, or set `isolation: worktree` on a one-off `Agent` call. Don't spawn worktree-isolated sub-agents ad hoc mid-flow; that splits work across trees you then have to reconcile.
- **`Task*` tools** (TaskCreate/List/Update) are a built-in coordination layer (lead creates, workers claim, deps unblock) — not MCP-backed, they don't reach sideclaw.
- **Routines / `/schedule`** run in Anthropic's cloud and **cannot reach the local sideclaw MCP** (localhost) or the LiteLLM bridge — don't route sideclaw offload through them.

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
| `/research <query>` | MCP (research-gateway) | Agentic Tavily + Context7 + fetch, cross-verified cited report — standalone VPS service on IU models, off Max. |
| `/grill` | inline | Question until clear direction, generate PRD. |
| `/implement` | inline | Guided implementation; inline orchestration delegating execution to the native `@implementer` Sonnet subagent (replaces the retired sideclaw implement). |
| `/browse` | fork (haiku) | Chrome DevTools debugging. |
| `/analyze` | subprocess | Deep static analysis (fallow + `claude_bridge` → DeepSeek). |
| `/otel [env] [intent]` | MCP (sideclaw) | Debug OTEL traces/logs/metrics in ClickHouse (worker uses `query.py`, kept in dotfiles). |
| `/read-drawing` | MCP (sideclaw) | Interpret Excalidraw (gemini-3.5-flash vision + structural JSON parse). |
| `/secrets` | inline | 1Password vault ops (uses `op_account_for_cwd`). |
| `/cloudflare` | inline | Cloudflare config (uses `op_account_for_cwd`). |
| `/upgrade-deps` | inline | Dependency upgrade assistant. |
| `/excalidraw-diagram` | inline | Create Excalidraw diagrams. |
| `/frontend-design` | inline | Production-grade frontend interfaces. |
| `/dataviz` | inline | Professional data-viz / chart styling (visx + Mantine, centralized palette). |
| `/brain` | inline | Second brain (`~/SourceRoot/brain` vault). `obsidian-cli` agent door with filesystem fallback; full contract in the repo's `AGENTS.md`. |
| `/skill-creator` | inline | Create, modify, and test skills. |
| `/ralph [cmd]` | inline (sonnet) | Autonomous multi-group implementation loop. |
| `/update-agent-rules` | inline | Sync upstream agent rules (React, TanStack, Elysia best practices) into `dotfiles/rules/`. |

**Per-repo skills** that only load when Claude is started inside their repo:
- `~/SourceRoot/dotfiles/.claude/skills/` — `/iu-endpoint` (validate IU endpoint + discover models); `/localai` (**retired** — local mlx-audio/Fish stack, replaced by the cloud audio-gateway)
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

- `gback` — alias for `git reset --soft HEAD~1`.
- **Worktrees:** use Claude Code's **native** worktree feature, and only when explicitly requested up front (see *Worktree isolation* above). Not `wtp`.

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
- Use `/check` for validation (sideclaw MCP — schema-validated, runs on the DeepSeek-V4-Pro bridge).
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
- `~/.claude/rules/` ← `dotfiles/rules/` — attribution, commits, TypeScript, security, code style, formatting, docker-makefile, makefile-conventions, dependency-hygiene, research-first, visx-charts.

Global skills:
- `~/.claude/skills/` ← `dotfiles/skills/` (global skills).

Per-project rules (scoped patterns with `paths:` frontmatter): `<repo>/.claude/rules/`.
Per-project skills (committed project skills): `<repo>/.claude/skills/`.

Update CLAUDE.md in the same commit as related code changes. CLAUDE.md-only changes use `docs:` prefix.
