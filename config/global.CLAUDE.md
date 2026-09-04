# Claude Code — Personal Configuration

Johannes Krumm — solo senior full-stack dev / tech lead. Iterative and
quality-focused: prefers several small verified steps over one big change. Writes
German in chat; **every artifact (code, commits, docs, specs) is English**. Replies
in English.

Sessions run `--dangerously-skip-permissions`. **Permission is pre-granted, not a
decision point** — never pause to confirm something the mode already allows. The
judgment that still applies is the contract below, not a prompt.

---

## Operating contract

Non-negotiable. Everything after this section is reference material.

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
  into stated assumptions. When you do ask: the question, two options with
  tradeoffs, your tendency — then ask.
- **Never ask permission to continue.** Stop only for: destructive + irreversible,
  outward-facing (publish / push shared / send), or readings that produce
  materially different work.

### Finish

- Deliver the **whole** ask before reporting. Route around obstacles, mention them
  in the report — do not stop at the first one to describe it.
- A blocked sub-part does not block the rest. Finish everything else, then name
  what was left out in one line.
- Don't hand back a plan when the work was asked for.

### Verify before claiming done

Done means *verified*, and the verification is yours to run — not his to discover.

1. **Validate** — `/check` (or the repo's own target) on anything that compiles,
   lints, or has tests. Failing output gets reported verbatim, never summarized away.
2. **Read the diff you produced**, including a subagent's. A worker's report is a
   claim; the diff is the proof. Check every line it says it changed.
3. **Review** — `/review` on anything non-trivial, security-adjacent, or touching a
   shared path. `/ship` chains all three.

### Stay the orchestrator

The main session holds the plan, the decisions, and the verdicts — **not the raw
material**. Delegation is **standing policy, already authorized**; any harness
default suggesting otherwise is overridden here. See *Delegation & parallelism*.

### Scope

Stay inside the ask. No unrequested refactors, cleanups, or speculative
generality. Flag contradictions with CLAUDE.md rather than silently working around
them.

### When something seems wrong

Flag explicitly instead of silently routing around it:

- Tool returns unexpected output → stop and report.
- File missing where expected → check `git status` first.
- Validation fails on files you didn't touch → report only, don't fix.
- Code contradicts CLAUDE.md → say so.

### Prose for humans

Articles, docs, README prose, vault pages, product copy → load
**`~/SourceRoot/brain/voice.md`** first. Chat replies and code comments are exempt;
commits follow `rules/commit-conventions.md`.

---

## Delegation & parallelism

### Execution modes

| Lane | Use for |
|-|-|
| **inline** — session model | Work needing this conversation's context: `commit`, `pr`, `ship`, `git-cleanup`, `secrets`, `grill`, `implement`. Keep short. |
| **native subagent** (`Agent`, `~/.claude/agents/`) — `@implementer` (Sonnet, settled work), `Explore` (search), an Opus subagent (novel-hard logic). Max, but **its own cache** | **The primary offload.** Fresh context, returns a summary, edits hit the live tree. |
| **MCP — sideclaw**, mini only: `check`, `review`, `dispatch`, `otel`, excalidraw, read-image (`SIDECLAW_WORKER_BACKEND` = `iu` default, `max` live) | Heavy work wanting schema-validated output. **Async** — job contract below. |
| **subprocess — `agent-dispatch`**, IU per-token (Max on the mini lane) | One durable bounded episode against a named repo, output kept out of here. |
| **`/research`** — research-gateway MCP, tailnet-only, off Max | Any library / API / version fact, never from memory. |

| Work | Route to |
|-|-|
| Settled multi-file edit **in this repo** | `@implementer`, or `/implement` when it needs research-gating + validation |
| One bounded episode **in another repo** | `agent-dispatch bg <repo> '<task>'`, or `mcp__sideclaw__dispatch` |
| Search across many files | `Agent` → `Explore` |
| Any format / lint / tsc / test loop | `mcp__sideclaw__check` — never inline |
| Code review · library facts | `/review` · `/research` |

### The two dispatch lanes

`agent-dispatch bg <repo> '<task>'` · `agent-dispatch work <repo>` — `<repo>` is a
**name, never a path**. Routes on the secrets backend crossed with whether the repo
is here: the mini (or a mini-resident repo) → `rd bg`/`rd work`, spawned through a
herdr pane so the Max keychain credential is reachable; MacBook + a
MacBook-resident repo → a local `claude -p` on the IU Keychain creds. **It refuses
to nest inside an interactive Claude Code session** (`CLAUDECODE` set → prints the
brief, exit 1). `rd` is its mini-side detail — use it directly only for `repos`,
`agents`, `read`, `say`.

`mcp__sideclaw__dispatch` (mini only) instead runs the episode **inside** the named
repo, so that repo's CLAUDE.md, rules and skills are in context. Tiers:
`investigate` (read-only → verdict), `author` (+ issue), `implement` (write +
branch + **draft** PR). One verdict, **no steering** (that is `rd bg` + `rd say`).
**Every tier gets its own worktree, read-only ones included** — `readOnly: true`
disables Edit and Write but **not Bash**, and the brief is attacker-influenced.

### sideclaw async-job contract

`mcp__sideclaw__{check,review,dispatch,otel}` return `{ jobId, status }`
immediately — **not the result**. Submit → note `jobId` → `job_wait({jobId})`
(blocks ~50 s; loop while `stillRunning: true`) → read `result` on
`status: "done"`, `error` on failed. `job_status` is the non-blocking peek.
**The submit call is not the answer.**

### Rules

- **Fire `@implementer` explicitly** — auto-delegation by description match is
  unreliable. Brief it completely: exact paths, the change, acceptance criteria,
  intent, scope limits. A literal executor *with judgment*, not a planner; it
  loads the full CLAUDE.md hierarchy, so it writes house-style code an external
  worker can't.
- **Research reaches the worker through the brief** — bake in resolved versions,
  signatures and import paths; it cannot see research you did.
- **It owns its files until it returns.** Parallelize on **disjoint** file groups.
- **Delegate for context, not latency** — the point is keeping verbose material
  out of the orchestrator. Editorial work therefore stays inline: delegating it
  means re-passing the source.
- **Don't switch the orchestrator's model mid-session** (cache invalidation);
  subagent caches are their own. **Worktree isolation is opt-in, up front, only
  when asked** — spawning one mid-flow splits work across trees.

### Parallelism — cheapest tier first

| Tier | Mechanism | Use when |
|-|-|-|
| 1 | Parallel `mcp__sideclaw__*` in **one turn** | Independent verifiable work — the default for fan-out; under-used. |
| 2 | subprocess (`agent-dispatch`, `claude_iu`), ~0 Max cost | Read-heavy, isolated output. |
| 3 | Background `Agent` (`run_in_background: true`) | Long work to detach from and resume (`SendMessage`). Keep it thin. |
| 4–5 | Foreground `Agent` on Opus (own cache) · agent teams / `/ultrareview` (N× Max) | Novel hard logic · genuinely hard parallel reasoning. Rarely worth it. |

`Task*` tools are a built-in coordination layer, not MCP-backed. Routines /
`/schedule` run in Anthropic's cloud and **cannot reach** sideclaw (localhost) or
research-gateway (tailnet).

### Reading files, and the prompt cache

Grep to locate before reading; never re-read a file already read this session;
files over 500 lines → `offset`/`limit`. Never read 10 files into the orchestrator
to find one thing — `Explore`'s job.

Cached prefix reads are ~10–20× cheaper than fresh input, so **the dominant cost
lever is not writing less, it is not breaking the cache** (TTL 1 h idle). It keys
on an exact prefix: switching the orchestrator's model or effort level,
connecting/disconnecting an MCP server, or a Claude Code upgrade all invalidate
it. Subagents and sideclaw workers hold **their own** caches — the real argument
for delegating. When it's gone it's gone: `/compact` or `/clear` rather than nurse
a cold session.

---

## Workspaces

### `~/SourceRoot/` — personal

1Password `tkrumm` · GitHub · no ticket prefixes · **direct-to-master by default**.

PR-required repos are a single source of truth in
`dotfiles/config/pr-required-repos.json` (read by `protect-branches.ts` **and**
`github-config.sh` — edit the file, not the code): `basalt-ui` (NPM-published,
also always its own commit), `free-planning-poker`, `rollhook`, `rollhook-action`.
`make github-config` applies two tiers: those repos and any with a collaborator
get the **full** ruleset; other public repos get **lite** (no PR rule — just
no-force, no-deletion, linear). Private repos can't be protected for free.

| Repo | Purpose |
|-|-|
| `dotfiles` · `dotfiles-private` | This setup (Claude config, hooks, skills, rules, bootstrap) · its secrets half: refs lists, encrypted cache, ACL + serve state. |
| `homelab` · `vps` | Home stack + Uptime Kuma config (`make uk-sync`) · production VPS + the imgproxy CDN behind `img.jkrumm.com`. |
| `homelab-private` | **Self-contained.** Never reference its services, hostnames or details from any other repo, doc or commit. |
| `argo` | Personal API + dashboard, the agent backbone. Elysia/Bun/Postgres/Drizzle; its OpenAPI spec is the contract. |
| `sideclaw` | Local Claude Code MCP daemon — check/review/dispatch/otel/excalidraw/read-image. **Mini only.** |
| `research-gateway` | VPS service behind `/research`, **tailnet-only** — bearer REST + an MCP facade, same submit→poll trio. Cloud routines can't reach it. |
| `hermes-agent` · `hermes-webui` | Mini-only personal AI over Slack; `HERMES_SKILLS` in its Makefile is the source of truth for its skill domains · the UI is an **upstream fork checkout**. |
| `basalt-ui` | Mantine v9 + visx design system (NPM). No Tailwind. **Always its own commit.** |
| `brain` · `basalt-ui-obsidian` | Obsidian vault — `wiki/` = agentic knowledge (strict lint), PARA `Projects`/`Areas` = curated human surface linking into it, no `Resources` tier; use `/brain` · the plugin building the `brain-web` reader. |
| `modelpick` | IU models vs leaderboards + live probes. **Source of truth for model-choice rationale**, backs `cap`. |
| `meteo` | Weather/wave service — 8 mini LaunchAgents, VPS-deployed; 6 have no in-repo plist template (known gap). |
| `dispatch-scratch` · `photo-flow` · `shutterflow` | Disposable dispatch target · the two MacBook-resident photography apps. |
| `audio-gateway`, `image-share`, `image-gen`, `usage-tracker`, `linewatch`, `rollhook`(`-action`), `rb`, `king-smith-walkingpad-mac`, `bun-email-api`, `free-planning-poker`, `podcast-generator`, `ticktick-raycast`, `clawbar`, `jkrumm.com`, `kobo-mods` | Services and smaller apps, all mini-resident. |

### `~/IuRoot/` — work (IU)

1Password `careerpartner` · GitLab · **`EP-XX` ticket prefixes** on branches and
commits · **all repos require PRs against `main`** (detected by path; exceptions
are `directToMain` in `pr-required-repos.json`, currently
`prometheus-feuer-agent`). Stack: DDD, NestJS backends, Vue frontends, a
micro-frontend SPA orchestrator; some carry their own CLAUDE.md.

Main: `epos.student-enrolment` (own CLAUDE.md), `epos_fe.{academic-profile,
booking,spa-orchestrator}`, `prometheus-scripts` (Jupyter MCP + Python
investigations). Rarely touched: `epos.{crm-bridge,dam,exam,finance-bridge,iam,
study-progress}`, `crm-bridge-retry-tool`, `cfn-kafka`, `terraform-monitoring`.
`~/Obsidian/Vault/` is a **cold backup only** — the live vault is
`~/SourceRoot/brain`; leave it closed. Tasks live in TickTick.

---

## Machines

**The mini is the dev host; the MacBook is the client** — agents run on the mini
and outlive the MacBook. **`dotfiles/docs/architecture.md` is the map**: every
machine, repo, launchd job and its owner, every door, the secrets flow, what
monitors what. Read it, don't restate it.

| Host | Reach | Repos |
|-|-|-|
| Mac mini | `ssh mini` — OpenSSH + key, agent forwarding + ControlMaster | **all** SourceRoot repos; cache backend |
| MacBook (`iumac`) | reached FROM the mini: `ssh iumac` — dedicated key, `restrict,pty`, no agent forwarding, onto a userland sshd on **:2222** (MDM owns the system :22) | the sanctioned set only; both 1P accounts, biometric |
| HomeLab · VPS | `ssh homelab` / `ssh vps` — Tailscale SSH, keyless | `~/homelab`(`-private`) · `~/vps` |

**The MacBook's sanctioned set is `dotfiles`, `dotfiles-private`, `brain`,
`photo-flow`, `shutterflow`.** Every other repo lives on the mini and is reached
there — don't clone one back "just to look". `brain` is a deliberate *writing*
mirror, not drift: the vault's only offline copy, reconciled through GitHub every
5 min (the MacBook commits, the mini never does — a second committer would race
`.git/index.lock`). **Conflicts are never auto-resolved.**

Two separate questions — collapsing them is the usual confusion: `desk [session]`
(= `herdr --remote mini`) puts a **terminal on** the mini, client-side, server and
panes there; `rd` and `agent-dispatch` (above) put **work on** it with no
terminal. Two facts worth holding:

- A herdr crash **restores the layout and loses every process in it** → durable
  work belongs in a `claude --bg` daemon, not a pane. A roam or lid-close ends
  `desk`'s *connection*, never the panes — re-run it.
- **Never `ssh mini 'claude --bg …'`** — an ssh session can't reach the login
  keychain, so the daemon comes up `Not logged in`, silently falls back to API
  billing, and still looks healthy in `claude agents`. `rd bg` spawns through a
  herdr pane precisely to avoid this.

**`/remote-dev`** for this stack, **`make doctor`** when it's broken. Work needing
a *present human* (biometric `op`, the ACL push, any person-only decision) is
enqueued on the mini with `ask-human.sh ask "…" [--cmd …]` and drained on the
MacBook with `make human-queue` — never auto-executed, always a typed `yes`.

### Sudo on a server

`sudo -S` reads the password from stdin, so none of these need `ssh -t` (a
`!`-prefixed command in a Claude Code session gets **no TTY**).

```bash
# HOST = homelab | vps (NOPASSWD) | mini; REF = homelab-server | vps-server | mac-mini-server
ROOT_PW=$(op read "op://Private/<REF>/password" --account tkrumm) && ssh <HOST> "echo '$ROOT_PW' | sudo -S <cmd>"
```

The mini's password is `op://Private/*` and deliberately **MacBook-only**: the
seed refuses it unconditionally. **Do not "fix" that refusal.**

### Local dev proxy

Caddy + dnsmasq serve `*.test` over HTTPS; `dotfiles/config/Caddyfile` is both the
port assignment and the app registry. Every app: static port, `npx kill-port PORT
&& … --strictPort`, one Caddyfile entry, `caddy-reload`, commit. On the mini each
`.test` block also gets a tailnet door at `https://<name>.mini.jkrumm.com`, all
listed at `https://apps.mini.jkrumm.com`.

### basalt-ui consumers

Mantine, not Tailwind; canonical reference `argo/apps/dashboard`. Primitives come
from themed `@mantine/core`, basalt-ui adds its own modules (shell, dashboard,
charts, data, content, agent-chat, forms, notifications). Color via `--vx-*`
tokens (`basalt-ui/tokens` → `VX.*` + `alpha()`), **never raw hex**.
`BasaltProvider` hard-requires `@tanstack/react-query` at build time. After
editing basalt-ui: `bun run build` before testing consumers.

```ts
// vite.config.ts — shipped helper: optimizeDeps.include for @mantine/*,
// resolve.dedupe, define['process.env.NODE_ENV'] (basalt bans import.meta.env)
import { basaltViteConfig } from 'basalt-ui/vite'

// main.tsx — CSS layer order is load-bearing
import '@mantine/core/styles.layer.css'  // the .layer.css variant, NOT styles.css
// ...other @mantine/*/styles.layer.css
import 'basalt-ui/styles.css'            // declares @layer mantine, basalt
// then: <BasaltProvider theme={createBasaltTheme()} defaultColorScheme="dark">
```

---

## Secrets

`op_account_for_cwd` / `op_run` (`~/.zsh/conf.d/secrets.zsh`, worktree-safe)
resolve the account from cwd: **`tkrumm`** in `~/SourceRoot/`, **`careerpartner`**
in `~/IuRoot/`. Skills call the helper, never bare `op`.

**The mini is headless — a direct `op read` / `op run` there HANGS** on a
biometric prompt no one can answer. Use `secrets-run`: it mirrors `op` and
resolves each ref from an age-encrypted, `op://`-keyed offline cache (decrypted in
memory, no plaintext on disk, no network, fails closed).

```bash
secrets-run read op://vault/item/field                  # ~ op read
secrets-run run [--env-file=<tpl>]... -- <cmd>          # ~ op run (repeats; last wins)
```

Same app code and same refs on both machines — only `~/.config/secrets/backend`
differs (`cache` on the mini, `op` on the MacBook), and `machine-role.ts` injects
the active one each session: **trust it over guessing**. `make secrets-seed`
reseals the cache (biometric, present-human) from `dotfiles-private/headless.refs`;
**only T0/T1 refs are ever cached** — `op://Private/*` and prod are refused.
Work refs *are* cached, so an agent on the mini reaches IU credentials with no
human present: a standing, enumerated exposure. Ops via **`/secrets`**; model in
`dotfiles-private/docs/`.

**Any edit to `secrets-run`** takes the full guardrail: `make secrets-test` +
`shellcheck` + design.md/security-review.md in the same change + an adversarial
`/review` — it is the sole secret path on the mini.

---

## Skills

Global skills at `~/.claude/skills/` (← `dotfiles/skills/`) load everywhere;
per-repo skills in `<repo>/.claude/skills/` load only inside that repo. Each
carries its own description — this table is only the **mode**, which decides what
a call costs. **Everything routed through sideclaw exists only on the mini.**

| Mode | Skills |
|-|-|
| **MCP (sideclaw, async)** | `/check` (format·lint·tsc·test; pass `commands` on non-Node repos) · `/review` (multi-angle + CodeRabbit; `--deep` adds correctness + security) · `/otel` · `/read-drawing` · `/excalidraw-diagram` |
| **MCP · fork · subprocess** | `/research` (research-gateway, off Max) · `/browse` (chrome-devtools, haiku) · `/analyze` (fallow + `claude_iu`) |
| **inline — git** | `/commit` (`--split`/`--amend`) · `/pr` · `/ship` · `/git-cleanup` |
| **inline — build** | `/implement` (drives `@implementer`) · `/grill` · `/ralph` · `/upgrade-deps` · `/dataviz` · `/frontend-design` · `/skill-creator` · `/update-agent-rules` |
| **inline — ops** | `/secrets` · `/cloudflare` (via `op_account_for_cwd`) · `/remote-dev` · `/herdr` (inert unless `HERDR_ENV=1`) · `/img` (`--json`) |
| **inline — writing** | `/brain` (via `obsidian-cli`) · `/distill` · `/podcast` |

Per-repo: `dotfiles` → `/iu-endpoint`; `hermes-agent` → `/hermes-validate`,
`/hermes-update`; `homelab` → `/audit`, `/docs`, `/upgrade-stack`; `vps` →
`/audit`, `/docs`; `sideclaw` → `/claude-cli`; `free-planning-poker` →
`/release-fpp`; `homelab-private` → `/prowlarr`; `ticktick-raycast` →
`/raycast-extension`, `/ticktick-api`; `brain` → `/wildrift-refresh`.

---

## Workflow

`/commit` per logical concern → `/git-cleanup` if ≥3 noisy commits → `/ship` for
the full flow; `/pr status` warns on uncommitted or unpushed work.

- Check `package.json` or the repo Makefile for available scripts.
- Fix errors **in changed files only** — don't refactor untouched code.
- **Never start dev servers** — he validates running apps manually.
- Node version manager is **fnm**, not nvm. `gback` = `git reset --soft HEAD~1`.
  Worktrees are Claude Code's **native** feature, requested up front, not `wtp`;
  Docker via Makefile targets only.

**Launchers:** `c` = Max · `cs`/`cf` = Max pinned to Sonnet/Fable · `ca [model]` =
the same `~/.claude` config over the IU endpoint's native Anthropic route (off
Max; `claude-sonnet-5[1m]` default) · `cap` = pick a model from measured data,
then launch `ca` · `claude_iu` = the headless `claude -p` helper. `[1m]` and
`_CA_CTX` rules: `dotfiles/CLAUDE.md`.

---

## Config hierarchy

- **Global**: `~/.claude/CLAUDE.md` ← `dotfiles/config/global.CLAUDE.md` (this file).
- **Per-project**: `<repo>/CLAUDE.md` + `<repo>/.claude/{rules,skills}/`.
- **Rules**: `~/.claude/rules/` ← `dotfiles/rules/`. No `paths:` → always on
  (attribution, code-style, commit-conventions, dependency-hygiene,
  docker-makefile, formatting, research-first, security, typescript); with
  `paths:` → lazy (dockerfile, elysia, makefile-conventions,
  react-best-practices, tanstack-{query,router,start}, visx-charts).
- **Output style**: `~/.claude/output-styles/Direct.md` (via `outputStyle` in
  settings.json) carries the response-shape and autonomy contract, this file the
  facts. Read at session start; does **not** reach subagents (their tone lives in
  `agents/*.md`).

Optimize these files for **density, not length** — every line either changes a
decision or gets deleted; long narrative belongs in `docs/` behind a link. Update
CLAUDE.md in the same commit as the code it describes; CLAUDE.md-only changes use
the `docs:` prefix.
