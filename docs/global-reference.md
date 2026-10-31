# Global reference — what `~/.claude/CLAUDE.md` links to

The global CLAUDE.md loads in every session and routes; this file holds the
detail it points at. Repo descriptions live only in `docs/architecture.md`
§Repos, model ids only in `agw routes`.

## Parallelism — cheapest tier first

| Tier | Mechanism | Use when |
|-|-|-|
| 1 | Parallel `/check` / `/review` (`agw`) calls in **one turn** | Independent verifiable *reads and checks* (`check`, `review`). Independent *changes* in one repo are `/wave` fan-out |
| 2 | Background `Agent` (`run_in_background: true`) | Long work to detach from and resume (`SendMessage`); keep it thin |
| 3–4 | Foreground `Agent` on a stronger model · agent teams | Novel hard logic only; rarely worth it |

`Task*` tools are a built-in coordination layer, not MCP-backed. Routines /
`/schedule` run in Anthropic's cloud and **cannot reach** agent-workflows (localhost/tailnet).

## Async-job contract

- `/check`, `/review`, `/research` and `/otel` are not jobs you poll: `agw check` / `agw review` /
  `agw research` / `agw otel` block up to `AGW_WAIT_BUDGET_S` (default 110 s), then exit 10
  naming the run; resume with `agw run wait <runId>` until the exit is not 10.

## Reading files and the prompt cache

Grep to locate before reading; never re-read a file already read this session;
files over 500 lines → `offset`/`limit`. Cached prefix reads are ~10–20× cheaper
than fresh input (TTL 1 h idle), so the dominant cost lever is not breaking the
cache: switching the orchestrator's model or effort, connecting/disconnecting an
MCP server, or a Claude Code upgrade all invalidate it. Subagents and agw
workers hold their own caches — the argument for delegating. When it is gone:
`/compact` or `/clear`.

## Skills by mode

Everything routed through `agw` exists only on the mini.

| Mode | Skills |
|-|-|
| `agw` CLI (sync, exit-10 resume `agw run wait <runId>`) | `/research` · `/otel` (`agw otel`, `agw hdx`) · `/check` · `/review` (`--deep` adds correctness + security) · `/prose` (`agw prose` + `agw prose-gate`, rewrite in-session) · `/podcast` (`agw podcast`) · `/img` (`agw image`) · `/excalidraw-diagram` (`agw diagram`) · `/brain` lookups (`agw brain`) |
| MCP · subagent | `/browse` (chrome-devtools, haiku) · `/analyze` (fallow in a native subagent) |
| inline — git | `/commit` (`--split`/`--amend`) · `/pr` · `/ship` · `/git-cleanup` |
| inline — build | `/wave` · `/implement` · `/upgrade-deps` · `/archify` |
| inline — ops | `/secrets` · `/cloudflare` · `/remote-dev` · `/herdr` (hc + the Herdr app) · `/router` (`routerctl`) |
| inline — writing | `/brain` · `/distill` |

Per-repo: `dotfiles` → `/iu-endpoint`; `hermes-agent` → `/hermes-validate`,
`/hermes-update`; `homelab` → `/audit`, `/docs`, `/upgrade-stack`; `vps` →
`/audit`, `/docs`; `free-planning-poker` →
`/release-fpp`; `homelab-private` → `/prowlarr`; `tinycast-extensions` →
`/tinycast`, `/raycast-extension`, `/ticktick-api`; `brain` → `/wildrift-refresh`.

## Workspaces

**`~/SourceRoot/`** — 1Password `tkrumm`, GitHub, no ticket prefixes,
direct-to-master by default. PR-required repos are one list in
`config/pr-required-repos.json` (read by `protect-branches.ts` and
`github-config.sh` — edit the file): `basalt-ui`, `free-planning-poker`,
`rollhook`, `rollhook-action`. `make github-config` applies two tiers: those repos
and any with a collaborator get the full ruleset; other public repos get lite (no
PR rule). Private repos can't be protected for free.

**GitHub Actions on private repos run on the VPS, never `ubuntu-latest`.** The
account's free hosted minutes for private repos run out mid-month (2026-10:
every run failed before its first job until the month reset); self-hosted
minutes are free. A personal account has no account-level runners, so each
private repo gets its own registration `vps-<repo>` (labels `self-hosted`,
`vps`) on the VPS, under one isolated user with its own rootless Docker (no
access to the prod daemon or secrets). Live: `shutterflow`, `weatherorb`, `rb`.

- Workflows: `runs-on: [self-hosted, vps]` plus a `timeout-minutes` per job; install
  toolchains per job (`setup-bun`, `setup-uv`, …), the host has only git/curl/unzip/
  rootless docker. `jkrumm/rollhook-action` builds and deploys from it unchanged.
  Service containers: loopback + dynamic port (`127.0.0.1::5432`).
- New private repo with workflows: `make -C ~/SourceRoot/vps gh-runner-sync` (from the
  mini or MacBook; registers every private repo that lacks a runner, `DRY_RUN=1`
  previews), then switch its `runs-on`. Remove: `make gh-runner-remove`.
- **Never on a public repo** (a fork PR would run code on the prod host); the setup
  script refuses. Public repos keep `ubuntu-latest` — hosted minutes are free there.
- Model, security, add/remove, operate: `vps/docs/gh-runner.md`.

Workflow facts per repo:

| Repo | Fact |
|-|-|
| `homelab-private` | Self-contained. Never reference its services, hostnames or details from any other repo, doc or commit. |
| `hermes-agent` | `HERMES_SKILLS` in its Makefile is the source of truth for skill domains. |
| `basalt-ui` | Mantine v9 + TanStack Charts (`@tanstack/charts`) since 2.0; visx in 1.x (NPM). No Tailwind. Always its own commit. |
| `brain` | `wiki/` = agentic knowledge (strict lint); PARA `Projects`/`Areas` = human surface; use `/brain`. |
| `modelpick` | Source of truth for model-choice rationale. |

**`~/IuRoot/`** — 1Password `careerpartner`, GitLab, `EP-XX` ticket prefixes on
branches and commits, all repos require PRs against `main` (exceptions are
`directToMain` in `pr-required-repos.json`, currently `prometheus-feuer-agent`).
Stack: DDD, NestJS backends, Vue frontends, a micro-frontend SPA orchestrator.
Main repos: `epos.student-enrolment` (own CLAUDE.md), `epos_fe.{academic-profile,
booking,spa-orchestrator}`, `prometheus-scripts`. Rarely touched:
`epos.{crm-bridge,dam,exam,finance-bridge,iam,study-progress}`,
`crm-bridge-retry-tool`, `cfn-kafka`, `terraform-monitoring`. `~/Obsidian/Vault/`
is a cold backup only — the live vault is `~/SourceRoot/brain`. Tasks: TickTick.

## Sudo on a server

`sudo -S` reads the password from stdin, so no `ssh -t` is needed (a `!`-prefixed
command gets no TTY). Pipe the password in on local stdin — never interpolate it
into the remote command, where it lands in the remote argv and `ps`.

```bash
# HOST = homelab | vps (NOPASSWD) | mini; REF = homelab-server | vps-server | mac-mini-server
op read "op://Private/<REF>/password" --account tkrumm | ssh <HOST> 'sudo -S <cmd>'
```

The mini's password is `op://Private/*` and deliberately MacBook-only: the seed
refuses it unconditionally. Do not "fix" that refusal.

## Local dev proxy

Caddy + dnsmasq serve `*.test` over HTTPS; `config/Caddyfile` is both the port
assignment and the app registry. Every app: static port, `npx kill-port PORT && …
--strictPort`, one Caddyfile entry, `caddy-reload`, commit. On the mini each
`.test` block also gets a tailnet door at `https://<name>.mini.jkrumm.com`, listed
at `https://apps.mini.jkrumm.com`. Detail: `docs/remote-dev.md` §Dev-server doors.

## basalt-ui consumers

Mantine, not Tailwind; canonical reference `argo/apps/dashboard`. Primitives come
from themed `@mantine/core`; basalt-ui adds shell, dashboard, charts, data,
content, agent-chat, forms, notifications. Colour via `--vx-*` tokens
(`basalt-ui/tokens` → `VX.*` + `alpha()`), never raw hex. `BasaltProvider`
hard-requires `@tanstack/react-query` at build time. After editing basalt-ui:
`bun run build` before testing consumers.

```ts
// vite.config.ts — optimizeDeps.include for @mantine/*, resolve.dedupe,
// define['process.env.NODE_ENV'] (basalt bans import.meta.env)
import { basaltViteConfig } from 'basalt-ui/vite'

// main.tsx — CSS layer order is load-bearing
import '@mantine/core/styles.layer.css'  // the .layer.css variant, NOT styles.css
// ...other @mantine/*/styles.layer.css
import 'basalt-ui/styles.css'            // declares @layer mantine, basalt
// then: <BasaltProvider theme={createBasaltTheme()} defaultColorScheme="dark">
```

## Launchers

One table: `AGENTS.md` §Claude Code launchers (and `docs/codex.md` for the
non-Anthropic lane: `cx`, `cxa`, `astra`). Rationale:
`brain/wiki/engineering/model-routing.md`.
