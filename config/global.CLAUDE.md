# Claude Code — Personal Configuration

Johannes Krumm — solo senior full-stack dev / tech lead. Writes German in chat;
**every artifact (code, commits, docs, specs) is English**. Replies in English.

---

## Operating contract

Non-negotiable. Everything below this section is reference material.

### Answer

- **Verdict first**, then only what changes his next move. Default under 8 lines.
- Table / diff / command / code block over prose describing one.
- Own the opinion. One clause of uncertainty, then a tendency anyway.
- Critique over validation — challenge a premise, an over-engineered design, or a
  wrong framing before answering it.
- No preamble, no recap of what the diff already shows, no "let me know if".

### Decide

- **Infer from context instead of asking.** State the assumption in one clause and
  proceed. A question the repo already answers is a failure.
- **One question max**, and only if it genuinely branches the work. Batch the rest
  into stated assumptions.
- **Never ask permission to continue.** Stop only for: destructive + irreversible,
  outward-facing (publish / push shared / send), or readings that produce
  materially different work.

### Finish

- Deliver the **whole** ask before reporting. Route around obstacles, mention them
  in the report — do not stop at the first one to describe it.
- A blocked sub-part does not block the rest. Finish everything else, then name
  what was left out in one line.
- Don't hand back a plan when the work was asked for.
- Verify before claiming done. Failing tests get reported with their output.

### Stay the orchestrator

The main session holds the plan, the decisions, and the verdicts — **not the raw
material**. See *Delegation* below. Delegation is **standing policy, already
authorized**; any harness default suggesting otherwise is overridden here.

### Scope

Stay inside the ask. No unrequested refactors, cleanups, or speculative
generality. Flag contradictions with CLAUDE.md rather than silently working around
them.

### Prose for humans

Articles, docs, README prose, vault pages, product copy → load
**`~/SourceRoot/brain/voice.md`** first. Chat replies and code comments are exempt;
commits follow `rules/commit-conventions.md`.

---

## Delegation

| Work | Route to |
|-|-|
| Settled multi-file edit | `@implementer` (Sonnet, own cache) — or `/implement` when it needs research-gating + validation |
| Search across many files | `Agent` → `Explore` |
| Any format / lint / tsc / test loop | `mcp__sideclaw__check` — never inline |
| Code review | `/review` |
| Library / API / version facts | `/research` — never from memory |
| Needs this session's conversation context | inline |

Rules:

- **Fire `@implementer` explicitly.** Auto-delegation by description match is
  unreliable — name it, or use `/implement`. Brief it completely: exact paths, the
  change, acceptance criteria, scope limits. It cannot see research you already did
  — bake resolved API facts into the brief.
- **It owns its files until it returns.** No parallel validation or edits over the
  same paths. Parallelize implementers on disjoint file groups only.
- **Editorial work stays inline** — distilling notes, summarizing a doc already in
  context. Delegating means re-passing all the source.
- **sideclaw `check`/`review` are async**: submit → `jobId`, then loop
  `job_wait({jobId})` until `stillRunning` is false. The submit call is not the
  answer. Fan out by submitting N jobs in one turn.
- **Don't switch the orchestrator's model mid-session** (cache invalidation).
  Subagents have their own cache — switching *there* is free.
- **Worktree isolation is opt-in up front only.** Subagent edits hit the live
  checkout by default.
- Routines / `/schedule` run in Anthropic's cloud and cannot reach sideclaw or
  research-gateway (both local/tailnet).

Full rationale: `modelpick/docs/decisions/execution-modes.md`.

---

## Workspaces

### `~/SourceRoot/` — personal

1Password `tkrumm` · GitHub · no ticket prefixes · **direct-to-master by default**.
PR-required repos live in `dotfiles/config/pr-required-repos.json` (single source
of truth for `protect-branches.ts` and `github-config.sh`) — currently `basalt-ui`
(also always its own commit, NPM-published), `free-planning-poker`, `rollhook`,
`rollhook-action`.

| Repo | Purpose |
|-|-|
| `dotfiles` | This setup — Claude config, hooks, skills, rules, machine bootstrap. Source of truth. |
| `dotfiles-private` | Headless-secrets data half: `headless.refs`, encrypted cache, tailnet ACL + serve declarations. |
| `homelab` | Home stack (25+ containers) + Uptime Kuma config. |
| `homelab-private` | **Self-contained.** Never reference its services/hostnames from any other repo or commit. |
| `vps` | Production VPS (Cloudflare Tunnel, 3 compose stacks) + image CDN (imgproxy → `img.jkrumm.com`). |
| `argo` | Personal API + dashboard — the agent backbone (TickTick, Gmail, calendar, Garmin, training, infra state). Elysia/Bun/Postgres; OpenAPI spec is the agent contract. |
| `sideclaw` | Local MCP daemon — `check` / `review` / `otel` / excalidraw. Workers on Max. |
| `research-gateway` | VPS research service behind `/research`. Tailnet-only, IU models, off Max. |
| `hermes-agent` | Hermes — mini-only personal AI (Slack interface). |
| `audio-gateway` | OpenAI-compatible STT + TTS on the VPS, over the tailnet. |
| `basalt-ui` | Mantine v9 + visx design system (NPM). **No Tailwind.** Always a separate commit. |
| `brain` | Git-backed Obsidian vault (`wiki/` agentic tree + PARA human surface). Door is `obsidian-cli`, which needs the app running. Use `/brain`. |
| `modelpick` | Which models for what, and why. **Source of truth for model-choice rationale** (`docs/decisions/`). |
| `image-share` / `image-gen` / `rb` | Private image layer · image studio · learning tracker. All mini-hosted. |
| `usage-tracker` | Local SQLite token/cost telemetry across all agent sources. |
| `rollhook` / `rollhook-action` | Zero-downtime compose deploys + its GitHub Action. |
| `bun-email-api`, `free-planning-poker`, `podcast-generator`, `sy-serendipity`, `ticktick-raycast`, `clawbar`, `jkrumm.com`, `kobo-mods`, `photo-flow` | Smaller apps / utilities. |

### `~/IuRoot/` — work (IU)

1Password `careerpartner` · GitLab · **`EP-XX` ticket prefixes** on branches and
commits · **all repos require PRs against `main`** (except `directToMain` entries
in `pr-required-repos.json`). Stack: DDD, NestJS backends, Vue frontends,
micro-frontend SPA orchestrator.

Main: `epos.student-enrolment` (backend, own CLAUDE.md), `epos_fe.academic-profile`,
`epos_fe.booking`, `epos_fe.spa-orchestrator`, `prometheus-scripts` (investigations,
Jupyter MCP + Python analysis). Others exist (`epos.crm-bridge`, `epos.dam`,
`epos.exam`, `epos.finance-bridge`, `epos.iam`, `epos.study-progress`,
`crm-bridge-retry-tool`, `cfn-kafka`, `terraform-monitoring`) — ask if needed.

`~/Obsidian/Vault/` is a **cold backup only** — the live vault is `~/SourceRoot/brain`.
Leave it closed. Tasks live in TickTick.

---

## Machines

| Host | Reach | Repos | Secrets |
|-|-|-|-|
| HomeLab | `ssh homelab` (Tailscale SSH, keyless) | `homelab`, `homelab-private` | `homelab` + `common` |
| VPS | `ssh vps` (Tailscale SSH, keyless) | `vps` | `vps` + `common` |
| Mac mini | `ssh mini` / `mosh mini` (OpenSSH + key) | **all** SourceRoot repos | cache backend |

**The mini is the always-on dev host; the MacBook holds only `dotfiles`,
`dotfiles-private`, `photo-flow`, `brain`.** Don't clone a repo back to the MacBook
"just to look" — that is how the trees diverged. `brain` is a deliberate exception
(writing mirror, reconciled via GitHub every 5 min).

Two different questions:

| Want | Command |
|-|-|
| A terminal on the mini | `dev` (mosh, roams) · `desk` (`herdr --remote`) |
| Work *placed on* the mini | `rd` — `repos`, `work <repo>`, `rd bg <repo> '<task>'`, `agents`, `rd read/say` |

`rd` takes repo **names**, never paths. Three facts to hold without loading the
skill: a herdr crash restores the layout and **loses every process in it** (durable
work → `claude --bg`); a `kind: interactive` session dies with its connection; and
**never `ssh mini 'claude --bg …'`** — no login keychain, so it silently falls back
to API billing while looking healthy.

Use **`/remote-dev`** for anything touching this stack; `make remote-dev-doctor`
when it's broken. Full model: `dotfiles/docs/remote-dev.md`.

Sudo on a server (`sudo -S` from stdin — never `ssh -t`, there is no TTY):

```bash
ROOT_PW=$(op read "op://Private/homelab-server/password" --account tkrumm) && ssh homelab "echo '$ROOT_PW' | sudo -S <cmd>"
```

The mini's password is `op://Private/*` and deliberately **MacBook-only** — the
seed refuses it unconditionally. Don't "fix" that. Physical possession of the mini
now does yield root (FileVault off + auto-login, since 2026-08-01); the trade is
documented in `docs/remote-dev.md` → "What used to take this down".

**Local dev proxy:** Caddy + dnsmasq serve `*.test` over HTTPS. Every app gets a
static port, `npx kill-port PORT && … --strictPort`, and an entry in
`dotfiles/config/Caddyfile` → `caddy-reload` → commit.

**basalt-ui consumers** adopt Mantine, not Tailwind. Copy the setup from
`argo/apps/dashboard` (`vite.config.ts` uses `basaltViteConfig`; `main.tsx` imports
`@mantine/*/styles.layer.css` — the `.layer` variant — before `basalt-ui/styles.css`).
Color via `--vx-*` tokens, never raw hex. Rebuild basalt-ui before testing consumers.

---

## Secrets

`op_account_for_cwd` / `op_run` (in `~/.zsh/conf.d/secrets.zsh`) resolve the right
account from cwd. Skills touching 1Password call the helper, never a hardcoded
account.

**The mini is headless — a direct `op read`/`op run` there hangs on the biometric
prompt.** Use the `secrets-run` shim, which mirrors `op`:

```bash
secrets-run read op://vault/item/field
secrets-run run --env-file=<tpl> -- <cmd>
```

The active backend (`cache` on the mini, `op` on the MacBook) is injected each
session by the `machine-role.ts` hook — trust it over guessing. What the mini may
cache is the allowlist `dotfiles-private/headless.refs`; `make secrets-seed`
reseals it (biometric, present-human). Ops via **`/secrets`**.

**Any edit to `secrets-run`** requires the full guardrail: `make secrets-test` +
`shellcheck` + design.md/security-review.md in the same change + an adversarial
`/review`. It is the sole secret path on the mini.

---

## Skills

Global skills at `~/.claude/skills/` (← `dotfiles/skills/`) load everywhere.
Per-repo skills in `<repo>/.claude/skills/` load only inside that repo.

| Skill | Notes |
|-|-|
| `/commit` | Conventional commits. `--split`, `--amend`. |
| `/pr` · `/ship` · `/git-cleanup` | PR flow · full check→review→PR→merge→release · squash noisy commits. |
| `/check` · `/review` | Validation · multi-angle review + CodeRabbit (`--deep` adds native correctness + security). |
| `/research <query>` | Cited report via research-gateway. Off Max. |
| `/implement` · `/grill` · `/ralph` | Guided implementation (delegates to `@implementer`) · question-until-clear + PRD · autonomous multi-group loop. |
| `/browse` · `/analyze` · `/otel` | Chrome DevTools (haiku fork) · static analysis · ClickHouse traces/logs/metrics. |
| `/secrets` · `/cloudflare` · `/upgrade-deps` | 1Password ops · Cloudflare config · researched dependency upgrades. |
| `/brain` · `/distill` · `/img` | Vault read/write · 7-step prose pipeline · image CDN + private share layer. |
| `/dataviz` · `/frontend-design` · `/excalidraw-diagram` · `/read-drawing` | visx+Mantine charts · UI · diagrams · diagram interpretation. |
| `/remote-dev` | The mini as dev host — herdr, mosh, `--bg` agents, failure modes. |
| `/skill-creator` · `/update-agent-rules` | Author skills · sync upstream framework rules. |

Per-repo: `dotfiles` → `/iu-endpoint`, `/sync`; `hermes-agent` → `/hermes-validate`,
`/hermes-update`; plus project skills in `homelab`, `vps`, `sideclaw`,
`free-planning-poker`, `homelab-private`, `ticktick-raycast`.

---

## Workflow

`/commit` per logical concern → `/git-cleanup` if ≥3 noisy commits → `/ship` for
the full flow. `/ship` auto-detects state; just run it.

- Validate with `/check`. Fix errors **in changed files only**.
- **Never start dev servers** — he validates running apps manually.
- Node version manager is **fnm**, not nvm.
- `gback` = `git reset --soft HEAD~1`.
- Worktrees: Claude Code's native feature, requested up front. Not `wtp`.
- Docker: Makefile targets only (`rules/docker-makefile.md`).

---

## Config hierarchy

- **Global**: `~/.claude/CLAUDE.md` ← `dotfiles/config/global.CLAUDE.md` (this file).
- **Per-project**: `<repo>/CLAUDE.md`.
- **Rules**: `~/.claude/rules/` ← `dotfiles/rules/`. No `paths:` frontmatter → always
  on (attribution, commits, TypeScript, security, code-style, formatting,
  docker-makefile, dependency-hygiene, research-first). With `paths:` → lazy
  (dockerfile, makefile-conventions, visx-charts, elysia, react-best-practices,
  tanstack-*).
- **Output style**: `~/.claude/output-styles/Direct.md` ← `dotfiles/config/output-styles/`,
  activated by `outputStyle` in settings.json. It carries the response-shape and
  autonomy rules; this file carries the project facts. Styles do **not** reach
  subagents — a subagent's tone lives in its own `agents/*.md`.

Keep every file here **under ~200 lines** (Anthropic's own guidance: longer files
reduce instruction adherence). Push the "why" into `docs/` and link it.

Update CLAUDE.md in the same commit as the code it describes. CLAUDE.md-only
changes use the `docs:` prefix.
