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

| Mode | Use for | Cost |
|-|-|-|
| **inline** | Work needing this session's conversation context: `commit`, `pr`, `ship`, `git-cleanup`, `secrets`, `grill`, `implement`. | Session model. Output lands in main context — keep it short. |
| **native subagent** (`Agent` / `~/.claude/agents/`) | **The primary offload.** `@implementer` (Sonnet, settled implementation), `Explore` (read-only search), an Opus subagent (novel-hard logic). | On Max but **its own prompt cache** — no orchestrator-cache penalty. Fresh context, returns a summary, edits hit the live checkout. |
| **MCP (sideclaw)** | Heavy work wanting schema-validated output: `check`, `review`, `otel`. | Sonnet/Haiku workers, currently on Max (`SIDECLAW_WORKER_BACKEND=max`); unset → IU endpoint, off Max quota. **Async.** |

*Niche:* `/analyze` shells `claude_bridge` (DeepSeek subprocess, off Max); `/browse`
forks chrome-devtools. Details live in those skills.

### Routing

| Work | Route to |
|-|-|
| Settled multi-file edit **in this repo** | `@implementer` — or `/implement` when it needs research-gating + validation |
| Bounded episode **in another repo** | `mcp__sideclaw__dispatch` |
| Search across many files | `Agent` → `Explore` |
| Any format / lint / tsc / test loop | `mcp__sideclaw__check` — never inline |
| Code review | `/review` |
| Library / API / version facts | `/research` — never from memory |
| Needs this session's conversation context | inline |

### Rules

- **Fire `@implementer` explicitly.** Auto-delegation by description match is
  unreliable — name it, or use `/implement`. Brief it completely: exact paths, the
  change, acceptance criteria, intent, scope limits. It is a literal executor *with
  judgment*, not a planner. It loads the full CLAUDE.md hierarchy, so it writes
  house-style code an external worker can't.
- **Research reaches the worker through the brief.** A subagent cannot see research
  you already did — bake resolved versions, signatures, and import paths in. Its own
  `/research` is the fallback for what you omitted.
- **It owns its files until it returns.** No parallel validation or edits over those
  paths — you'll race half-written state and chase failures that vanish. Parallelize
  implementers on **disjoint** file groups only.
- **Editorial work stays inline** — distilling notes, summarizing a doc already in
  context. Delegating means re-passing all the source in the brief.
- **Delegate for context, not latency.** Sonnet returns in seconds-to-minutes. The
  reason to offload is keeping verbose material out of the orchestrator.
- **Don't switch the orchestrator's model mid-session** (cache invalidation, the
  biggest avoidable cost in a long conversation). Subagents have their own cache —
  switching *there* is free.
- **Worktree isolation is opt-in, up front, only when asked** (native worktree
  session, or `isolation: worktree` on a one-off `Agent` call). Subagent edits hit
  the live checkout by default. Don't spawn worktree-isolated agents mid-flow —
  that splits work across trees you then have to reconcile.

### `dispatch` — one episode inside another repo

`mcp__sideclaw__dispatch` hands a single bounded episode to a Claude Code session
running **inside a named repo**, so that repo's own CLAUDE.md, rules, and skills are
in its context. This is the lane for "work on repo X while I'm sitting in repo Y" —
every repo lives on this machine, so it comes up often.

Three tiers: `investigate` (read-only → verdict), `author` (→ verdict + GitHub
issue), `implement` (write → verdict + branch + **draft** PR). One episode, one
verdict, **no steering** — mid-run redirection is `rd bg` + `rd say`, not this.

**Every tier runs in its own worktree**, including the read-only ones. That is not
belt-and-braces: `readOnly: true` disables Edit and Write but **not Bash**, and the
brief is attacker-influenced (anyone can file an issue on a public repo, and its
body reaches the episode's context). A read tier in the live checkout was one
injected `sed -i` away from editing a repo other agents are working in.

### sideclaw async-job contract

`mcp__sideclaw__{check,review,dispatch,otel}` return `{ jobId, status }` immediately
— **not the result**. Submit → note `jobId` → call `job_wait({jobId})` (blocks ~50s
with heartbeats; loop while `stillRunning: true`) → read `result` on
`status: "done"`, `error` on failed/interrupted. `job_status` is the non-blocking
peek. This is what makes 10-min offload safe. **The submit call is not the answer.**

### Parallelism — cheapest tier first

| Tier | Mechanism | Max cost | Use when |
|-|-|-|-|
| 1 | **Parallel `mcp__sideclaw__*` in one turn** | Max (or ~0 on IU workers) | Independent verifiable work — check/review N repos. The default for fan-out; under-used. |
| 2 | **subprocess** (`claude_iu` / `claude_bridge`) | ~0 (IU per-token) | Read-heavy, isolated output. |
| 3 | **Background `Agent`** (`run_in_background: true`) | Moderate | Long multi-step work to detach from and resume (`SendMessage`). Keep it thin — it delegates to workers, doesn't grind. |
| 4 | **Foreground `Agent` on Opus** | Full Max (isolated cache) | Novel hard logic needing the best model. |
| 5 | **Agent teams / `/ultrareview`** | N× Max | Genuinely hard parallel reasoning. Rarely worth it here. |

- Emit several `mcp__sideclaw__*` tool_use blocks in **one turn** — they run
  concurrently while the orchestrator just awaits. A concurrency cap queues excess.
- Implementation fan-out is parallel `@implementer` subagents on disjoint files.
- `Task*` tools (TaskCreate/List/Update) are a built-in coordination layer — not
  MCP-backed, they don't reach sideclaw.
- Routines / `/schedule` run in Anthropic's cloud and **cannot reach** sideclaw
  (localhost) or research-gateway (tailnet).

### Reading files

Grep to locate before reading. Never re-read a file already read this session.
Files over 500 lines → `offset`/`limit`. Never read 10 files into the orchestrator
to find one thing — that's `Explore`'s job.

### Prompt cache

Every turn re-sends the whole conversation. Cached prefix reads are ~10–20× cheaper
than fresh input, so **the dominant cost lever is not writing less — it is not
breaking the cache.** TTL here is 1 hour of inactivity.

The cache keys on an exact prefix, so **anything that mutates the prefix
invalidates it**: switching the orchestrator's model, changing effort level,
connecting or disconnecting an MCP server, or a Claude Code upgrade. Mid-session,
avoid all of them. Subagents and sideclaw workers hold **their own** caches — model
choice *there* is free, which is the real argument for delegating.

When the cache is gone it is gone — don't nurse a cold session. `/compact` to carry
a summary forward, or `/clear` outright: the repo, the diff, and the commit history
usually hold everything needed to resume.

Full rationale: `modelpick/docs/decisions/execution-modes.md`.

---

## Workspaces

### `~/SourceRoot/` — personal

1Password `tkrumm` · GitHub · no ticket prefixes · **direct-to-master by default**.

PR-required repos are a single source of truth in
`dotfiles/config/pr-required-repos.json` (read by `protect-branches.ts` **and**
`github-config.sh` — edit the file, not the code): `basalt-ui` (NPM-published, also
always its own commit), `free-planning-poker`, `rollhook`, `rollhook-action`.

Branch protection has two tiers, applied by `make github-config`: PR-required repos
and any repo with a collaborator get the **full** ruleset (PR required to master);
other public repos get **lite** (no PR rule — just no-force, no-deletion, linear) so
direct pushes are clean with no bypass warning. Private repos can't be protected on
the free tier.

| Repo | Purpose |
|-|-|
| `dotfiles` | This setup — Claude config, hooks, skills, rules, machine bootstrap. Source of truth. |
| `dotfiles-private` | Secrets data half: `headless.refs`, the encrypted cache, `.sops.yaml`, tailnet ACL + serve declarations. |
| `homelab` | Home stack (25+ containers) + Uptime Kuma config (`make uk-sync`). |
| `homelab-private` | **Self-contained.** Never reference its services, hostnames, or details from any other repo, doc, or commit. |
| `vps` | Production VPS (Cloudflare Tunnel, 3 compose stacks) + image CDN (imgproxy over a private B2 `img/` prefix → `img.jkrumm.com`). |
| `argo` | Personal API + dashboard, the agent backbone — TickTick, Gmail, calendar (personal + work), Teams, Garmin health, strength training, homelab/VPS state. Elysia/Bun/Postgres/Drizzle; the OpenAPI spec at `argo.jkrumm.com/api/openapi/json` is the agent contract. |
| `sideclaw` | Local Claude Code MCP daemon — `check` / `review` / `dispatch` / `otel` / excalidraw / read-image. Workers on claude-sonnet-5 + claude-haiku-4-5, currently Max via `SIDECLAW_WORKER_BACKEND=max`. LiteLLM/DeepSeek bridge retained but dormant. |
| `research-gateway` | Standalone VPS research service behind `/research` (Elysia + Bun + AI SDK v6) at `research.jkrumm.com`. **Tailnet-only** (grey-cloud DNS, not behind the Tunnel), bearer-auth'd REST + OpenAPI + an MCP facade at `/mcp` with the same submit→poll job trio. IU models, off Max. Mac/tailnet only — cloud routines can't reach it. |
| `hermes-agent` | Hermes — mini-only personal AI (Slack interface, DeepSeek-V4-Flash brain with `claude-sonnet-4-6-eu` failover). `HERMES_SKILLS` in its Makefile is the source of truth for its skill domains — don't restate the count here, it drifts. |
| `linewatch` | Home-line / connectivity watcher — bearer-auth'd routes, bucketed metrics, router poller. |
| `vibe-stack` | The "factory" repo — generates a Cloudflare + Mantine v9 + D1 starter kit plus German-language guided onboarding for non-technical friends. Editing the factory ≠ editing what it produces. |
| `king-smith-walkingpad-mac` | Go LaunchAgent + Raycast extension driving a WalkingPad P1 over BLE, syncing sessions to Argo. Milestone 0 / POC. |
| `audio-gateway` | OpenAI-compatible STT + expressive Gemini TTS, VPS container at `audio-gateway.jkrumm.com` over the tailnet. Consumed by Hermes, Argo, local MacWhisper. |
| `basalt-ui` | Mantine v9 + visx design system (NPM). **No Tailwind** since the 2026-07 zinc redesign. **Always a separate commit** from consumer apps. |
| `brain` | Git-backed Obsidian vault. Two layers: top-level `wiki/` = agentic knowledge (strict lint), PARA `Projects`/`Areas` = curated human surface (light lint) linking down into `wiki/`. No `Resources` tier. Door is `obsidian-cli`, a **client of the running app** — it exits 1 on every subcommand when Obsidian is down (`make obsidian-autostart` keeps it up). Direct-to-master, validated by `vault-lint`. Use `/brain`. |
| `modelpick` | Which models for what, and why — ranks IU models against leaderboards + live probes, flags drift. **Source of truth for model-choice rationale** (`docs/decisions/`). |
| `usage-tracker` | Local SQLite token/cost telemetry. Per-source collectors (Claude Code, LiteLLM, Hermes, Feuer, OpenCode) → one `usage_record` table; LaunchAgent ingests every 15 min. |
| `image-share` | Private image layer on the HomeLab — filesystem-truth index, token-role public share pages, bearer OpenAPI admin/agent API. Via `/img` (`imgcli share`/`publish`); deploy config lives in `homelab`. |
| `image-gen` / `rb` | Image-generation studio. Primary artifact is a Tauri v2 macOS app (`ImageGen.app`, `com.jkrumm.image-gen`) built + installed on the mini (`make app` → `/Applications`, `make up` also deploys + proves both); stores generations on local disk (`~/Pictures/ImageGen/<id>/` + `metadata.json`) and pushes one-way into image-share. Gateway is a separate Docker container on the **VPS** (`:7716`, Traefik, tailnet-only), deployed by RollHook. · `rb` = single-user learning tracker (mini, Tailscale-only). |
| `rollhook` / `rollhook-action` | Webhook-triggered zero-downtime compose deploys + its GitHub Action. |
| `bun-email-api`, `free-planning-poker`, `podcast-generator`, `sy-serendipity`, `ticktick-raycast`, `clawbar`, `jkrumm.com`, `kobo-mods`, `photo-flow` | Smaller apps / utilities. |

### `~/IuRoot/` — work (IU)

1Password `careerpartner` · GitLab · **`EP-XX` ticket prefixes** on branches and
commits · **all repos require PRs against `main`** (detected by path; exceptions are
`directToMain` in `pr-required-repos.json`, currently `prometheus-feuer-agent`).
Stack: DDD, NestJS backends, Vue frontends, micro-frontend SPA orchestrator. Some
repos carry their own CLAUDE.md.

Main: `epos.student-enrolment` (backend for academic-profile + booking, own
CLAUDE.md), `epos_fe.academic-profile`, `epos_fe.booking`,
`epos_fe.spa-orchestrator` (micro-frontend host shell), `prometheus-scripts` (work
investigations — Jupyter MCP + Python analysis). Rarely touched:
`epos.crm-bridge`, `epos.dam`, `epos.exam`, `epos.finance-bridge`, `epos.iam`,
`epos.study-progress`, `crm-bridge-retry-tool`, `cfn-kafka`, `terraform-monitoring`.

`~/Obsidian/Vault/` is a **cold backup only** — the live vault is
`~/SourceRoot/brain`. Leave it closed. Tasks live in TickTick.

---

## Machines

| Host | Reach | Repos | 1P vaults |
|-|-|-|-|
| HomeLab | `ssh homelab` — Tailscale SSH, keyless | `~/homelab`, `~/homelab-private` | `homelab` + `common` |
| VPS | `ssh vps` — Tailscale SSH, keyless | `~/vps` | `vps` + `common` |
| Mac mini | `ssh mini` / `mosh mini` — **OpenSSH + key** (remote dev needs agent forwarding + ControlMaster) | **all** SourceRoot repos | n/a — cache backend |
| MacBook (`iumac`) | reached FROM the mini: `ssh iumac` / `rsync … iumac:…` — dedicated `~/.ssh/id_ed25519_iumac` key, `restrict,pty`, no agent forwarding | `dotfiles`, `dotfiles-private`, `photo-flow`, `brain` | both accounts — biometric (present-human only) |

The mini's reach back is live (rename to `iumac` landed 2026-08-06): non-interactive
file/state pulls (`usage-tracker`/`brain`), no biometric. Full model:
`dotfiles/docs/remote-dev.md` §10, `dotfiles-private/docs/access-model.md`.

### The mini is the dev host; the MacBook is the client

Agents run on the mini and outlive the MacBook. Stack: Tailscale → mosh → **herdr**
(owns the workspace model, runs *on the mini*) → Caddy. `claude --bg` daemons
survive independently of all of it. cmux is the client window, tmux the fallback.

**The MacBook's sanctioned set is `dotfiles`, `dotfiles-private`, `photo-flow`,
`brain`.** Every other repo lives on the mini and is reached there. Don't clone one
back "just to look" — that is how the two trees diverged. MacBook-unique history is
preserved in `~/SourceRoot-archive` (git bundles + un-gitted projects). **Known
drift, unresolved:** the MacBook also carries a `homelab-private` checkout,
verified from the mini 2026-08-06 — not on the sanctioned list above and not yet
either deleted or documented as a second exception; pick one.

**`brain` is a deliberate exception, not drift — do not "clean it up".** It is the
vault's only offline copy and a *writing* mirror: edit it on either machine freely.
`com.jkrumm.brain-sync` reconciles both through GitHub every 5 min — the MacBook
pulls, commits, pushes; the mini pulls and pushes but never commits (obsidian-git is
deliberately not installed — a second committer racing for `.git/index.lock`).
**Conflicts are never auto-resolved**: the rebase aborts, the tree is untouched, a
human picks the side. Full model: `brain/docs/brain-access.md`.

Two separate questions — collapsing them is the usual confusion:

| Want | Command |
|-|-|
| A terminal *on* the mini | `dev` (mosh, roams, survives lid-close) · `desk` (`herdr --remote`, TCP, local keybindings + image paste) |
| Work *placed on* the mini | `rd` — needs no terminal at all |

`rd` (`dotfiles/scripts/remote-dev.sh`) routes off the secrets-backend marker, so
the same words work from both machines: `repos [filter]`, `work <repo>` (herdr
workspace + claude, idempotent), `rd bg <repo> '<task>'` (durable daemon), `agents`
(both lanes, deduped), `rd read <agent>`, `rd say <agent> '…'`. Shorthands `work` /
`agents` / `repos`. Commands take a repo **name, never a path** — resolution happens
on the host.

Three facts worth holding without loading the skill:

- A herdr crash **restores the layout and loses every process in it** → durable work
  belongs in a `claude --bg` daemon, not a pane.
- A `kind: interactive` session dies with its connection.
- **Never `ssh mini 'claude --bg …'`** — an ssh session can't reach the login
  keychain, so the daemon comes up `Not logged in`, silently falls back to API
  billing, and still looks healthy in `claude agents`. `rd bg` spawns through a herdr
  pane precisely to avoid this.

Use **`/remote-dev`** for anything touching this stack; `make remote-dev-doctor`
when it's broken. Full model: `dotfiles/docs/remote-dev.md`.

**human-queue** — SSH gives the mini reach, not a fingerprint: for work that
needs a *present human* (biometric `op`, the Tailscale ACL push, any
person-only decision), an agent there enqueues with
`ask-human.sh ask "…" [--cmd …] [--wait]` instead of editing a handover doc;
the human drains it with `make human-queue` (`human-queue.sh run/deny <id>` —
never auto-executed, always a typed `yes`).

### Sudo on a server

`sudo -S` reads the password from stdin, so none of these need `ssh -t` — which
matters, because a `!`-prefixed command in a Claude Code session gets **no TTY** and
`ssh -t` fails there with "Pseudo-terminal will not be allocated".

```bash
ROOT_PW=$(op read "op://Private/homelab-server/password" --account tkrumm) && ssh homelab "echo '$ROOT_PW' | sudo -S <cmd>"
ROOT_PW=$(op read "op://Private/vps-server/password" --account tkrumm) && ssh vps "echo '$ROOT_PW' | sudo -S <cmd>"   # NOPASSWD sudo
ROOT_PW=$(op read "op://Private/mac-mini-server/password" --account tkrumm) && ssh mini "echo '$ROOT_PW' | sudo -S <cmd>"
```

`~/.ssh/config` is generated from `config/ssh_config` — all four hosts are MagicDNS
short names, so it installs identically on a headless machine (no secret, no `op`
call).

The mini's password is `op://Private/*` and deliberately **MacBook-only** — the seed
refuses it unconditionally, so reading it is biometric-gated on a present-human
machine. **Do not "fix" that refusal to make it more convenient.** Since 2026-08-01
physical possession of the mini does yield root anyway (FileVault off + auto-login
for unattended reboot, so `/etc/kcpassword` holds it under a reversible XOR) — which
reaches every ref in `headless.refs` **and** `headless.iu.refs` (work: Feuer
identity, Artifactory, Jira, read-only prod DB). `make lock-at-boot-setup` closes the
walk-up path; Thunderbolt Sharing Mode is a FileVault question and stays open. Full
trade: `docs/remote-dev.md` → "What used to take this down".

### Local dev proxy

Caddy + dnsmasq serve `*.test` over HTTPS; ports assigned in
`dotfiles/config/Caddyfile`. Every app: static port,
`npx kill-port PORT && … --strictPort`, an entry in the Caddyfile. Adding one: edit
Caddyfile → `caddy-reload` → commit in dotfiles. On the mini each `.test` block also
gets a tailnet door at `https://<name>.mini.jkrumm.com` automatically.

### basalt-ui consumers

Mantine, not Tailwind. Canonical reference: `argo/apps/dashboard`.

```ts
// vite.config.ts — shipped helper: optimizeDeps.include for @mantine/*,
// resolve.dedupe, define['process.env.NODE_ENV'] (basalt bans import.meta.env)
import { basaltViteConfig } from 'basalt-ui/vite'
```
```tsx
// main.tsx — CSS layer order is load-bearing
import '@mantine/core/styles.layer.css'  // the .layer.css variant, NOT styles.css
// ...other @mantine/*/styles.layer.css
import 'basalt-ui/styles.css'            // declares @layer mantine, basalt
// then: <BasaltProvider theme={createBasaltTheme()} defaultColorScheme="dark">
```

Primitives (Button, TextInput, Modal, …) come from themed `@mantine/core`; basalt-ui
adds its own modules (shell, dashboard, charts, data, content, agent-chat, forms,
notifications). Color via `--vx-*` tokens (`basalt-ui/tokens` → `VX.*` + `alpha()`),
**never raw hex**. `BasaltProvider` hard-requires `@tanstack/react-query` at build
time. After editing basalt-ui: `bun run build` before testing consumers.

---

## Secrets

`op_account_for_cwd` / `op_run` (in `~/.zsh/conf.d/secrets.zsh`, worktree-safe via
`git rev-parse --git-common-dir`) resolve the account from cwd. Skills touching
1Password call the helper; SourceRoot-only infra scripts may hardcode `tkrumm`.

**The mini is headless — a direct `op read` / `op run` there HANGS** on a biometric
prompt no one can answer. Use the `secrets-run` shim, which mirrors `op` and resolves
each ref from an age-encrypted, `op://`-keyed offline cache (decrypted in memory, no
plaintext on disk, no network, fails closed on a missing ref):

```bash
secrets-run read op://vault/item/field                  # ~ op read
secrets-run run [--env-file=<tpl>]... -- <cmd>          # ~ op run (repeats; last wins)
```

Same app code and same `op://` refs on both machines — only
`~/.config/secrets/backend` (`cache` on the mini, `op` on the MacBook) differs. The
active backend is injected each session by the `machine-role.ts` hook; **trust it
over guessing**.

What the mini may hold offline is the explicit allowlist
`dotfiles-private/headless.refs`; `make secrets-seed` reseals the cache (biometric,
present-human). **Tiering guardrail:** only T0/T1 refs are ever cached —
`op://Private/*` and T2/prod are refused by the seed (argo's `op://vps/argo/*` is an
owner-classified exception). Ops via **`/secrets`**; full model in
`dotfiles-private/{PRD.md,docs/design.md,docs/runbook.md}`.

**Any edit to `secrets-run`** takes the full guardrail: `make secrets-test` +
`shellcheck` + design.md/security-review.md in the same change + an adversarial
`/review`. It is the sole secret path on the mini.

---

## Skills

Global skills at `~/.claude/skills/` (← `dotfiles/skills/`) load in every session
regardless of cwd. Per-repo skills in `<repo>/.claude/skills/` load only inside that
repo.

| Skill | Mode | Notes |
|-|-|-|
| `/commit` | inline | Conventional commits. `--split`, `--amend`. |
| `/pr [action]` | inline | Create / status / merge. `create` errors on the default branch, proposes a rename, runs `/commit` if dirty, offers `/git-cleanup` at ≥3 commits, `/check` pre-flight. |
| `/ship` | inline | check → review → commit → PR → CodeRabbit → merge → release. Auto-detects state; direct-to-master vs PR. |
| `/git-cleanup` | inline | Semantically group + squash noisy branch commits. |
| `/check` | MCP | Format, lint, typecheck, test. Auto-detects Node/Bun, Python/uv, Makefile, Rust, Go; on non-Node repos pass `commands` (e.g. `['.venv/bin/ruff check', '.venv/bin/pytest -q']`) to skip discovery. |
| `/review` | MCP | Multi-angle review (dynamic angle router) + CodeRabbit CLI. `--deep` adds native correctness + security. |
| `/research <query>` | MCP | Agentic Tavily + Context7 + fetch, cross-verified cited report. Off Max. |
| `/implement` | inline | Guided implementation; orchestrates the `@implementer` Sonnet subagent. |
| `/grill` | inline | Question until direction is clear, then a PRD. |
| `/ralph [cmd]` | inline (sonnet) | Autonomous multi-group implementation loop. |
| `/browse` | fork (haiku) | Chrome DevTools — console, network, DOM, screenshots. |
| `/analyze` | subprocess | Deep static analysis (fallow + DeepSeek). |
| `/otel [env] [intent]` | MCP | Traces / logs / metrics in ClickHouse, local + prod. |
| `/read-drawing` | MCP | Interpret Excalidraw (vision + structural JSON). |
| `/secrets` · `/cloudflare` | inline | 1Password ops · Cloudflare DNS + tunnel ingress. Both use `op_account_for_cwd`. |
| `/upgrade-deps` | inline | Researched, one-at-a-time dependency upgrades. |
| `/brain` | inline | Vault read/write. `obsidian-cli` door with filesystem fallback; contract in the repo's `AGENTS.md`. |
| `/distill` | inline | Human-owned 7-step prose pipeline (loads `voice.md` at Draft). |
| `/img` | inline | Public CDN uploads + imgproxy transform URLs, and the private share layer. `--json` on every command. |
| `/dataviz` · `/frontend-design` · `/excalidraw-diagram` | inline | visx + Mantine charts · production UI · diagrams. |
| `/remote-dev` | inline | The mini as dev host — herdr, mosh, `--bg` agents, heartbeat, failure modes. |
| `/skill-creator` · `/update-agent-rules` | inline | Author/test skills · sync upstream framework rules. |

Per-repo: `dotfiles` → `/iu-endpoint`, `/sync` (MacBook-only), `/localai` (retired);
`hermes-agent` → `/hermes-validate`, `/hermes-update`; `homelab` → `/audit`,
`/docs`, `/upgrade-stack`; `vps` → `/audit`, `/docs`; `sideclaw` → `/claude-cli`;
`free-planning-poker` → `/release-fpp`; `homelab-private` → `/prowlarr`;
`ticktick-raycast` → `/raycast-extension`, `/ticktick-api`;
`brain` → `/wildrift-refresh`.

---

## Workflow

`/commit` per logical concern → `/git-cleanup` if ≥3 noisy commits → `/ship` for the
full flow. `/ship` auto-detects state; just run it. `/pr status` warns on
uncommitted/unpushed work and shows CodeRabbit feedback.

- Check `package.json` or the repo Makefile for available scripts.
- Fix errors **in changed files only** — don't refactor untouched code.
- **Never start dev servers** — he validates running apps manually.
- Node version manager is **fnm**, not nvm. Never suggest nvm paths.
- `gback` = `git reset --soft HEAD~1`.
- Worktrees: Claude Code's **native** feature, requested up front. Not `wtp`.
- Docker: Makefile targets only (`rules/docker-makefile.md`).

---

## Config hierarchy

- **Global**: `~/.claude/CLAUDE.md` ← `dotfiles/config/global.CLAUDE.md` (this file).
- **Per-project**: `<repo>/CLAUDE.md`, plus `<repo>/.claude/rules/` and
  `<repo>/.claude/skills/`.
- **Rules**: `~/.claude/rules/` ← `dotfiles/rules/`. No `paths:` frontmatter → always
  on (attribution, commit-conventions, typescript, security, code-style, formatting,
  docker-makefile, dependency-hygiene, research-first). With `paths:` → lazy
  (dockerfile, makefile-conventions, visx-charts, elysia, react-best-practices,
  tanstack-query/router/start).
- **Output style**: `~/.claude/output-styles/Direct.md` ←
  `dotfiles/config/output-styles/`, activated by `outputStyle` in settings.json. It
  carries the response-shape and autonomy contract; this file carries the facts.
  Styles are read at session start and do **not** reach subagents — a subagent's tone
  lives in its own `agents/*.md`.

Optimize these files for **density, not length** — every line either changes a
decision or gets deleted. Long narrative rationale belongs in `docs/` behind a link;
facts, gotchas, and non-obvious conventions stay here regardless of line count.

Update CLAUDE.md in the same commit as the code it describes. CLAUDE.md-only changes
use the `docs:` prefix.
