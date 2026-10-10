# Global reference — what `~/.claude/CLAUDE.md` links to

The global CLAUDE.md loads in every session and routes; this file holds the
detail it points at. Repo descriptions live only in `docs/architecture.md`
§Repos, model ids only in `agw routing` (`GET /api/routing`).

## Parallelism — cheapest tier first

| Tier | Mechanism | Use when |
|-|-|-|
| 1 | Parallel `mcp__agent-gateway__*` calls in **one turn** | Independent verifiable *reads and checks* (`check`, `review`, `investigate`). Independent *changes* in one repo are `/wave` fan-out, not parallel dispatch |
| 2 | `agw dispatch` / `claude_iu` subprocess, ~0 Max cost | Read-heavy, isolated output |
| 3 | Background `Agent` (`run_in_background: true`) | Long work to detach from and resume (`SendMessage`); keep it thin |
| 4–5 | Foreground `Agent` on a stronger model · agent teams | Novel hard logic only; rarely worth it |

`Task*` tools are a built-in coordination layer, not MCP-backed. Routines /
`/schedule` run in Anthropic's cloud and **cannot reach** agent-gateway (localhost) or
research-gateway (tailnet).

## Async-job contract — agent-gateway and research-gateway

`mcp__agent-gateway__{check,review,dispatch}` and `mcp__research-gateway__research`
return `{ jobId, … }` immediately — not the result. Submit → note `jobId` →
`job_wait({jobId})` → read `result` on `status: "done"`, `error` on failed.
`job_status` is the non-blocking peek.

- agent-gateway's `job_wait` accepts `maxWaitMs` (up to 29 min) — pass the ceiling
  instead of looping on the ~50 s default.
- research-gateway's MCP wait blocks for the whole job over a kept-alive stream:
  one call is normally the whole wait; call again only on `stillRunning`. Its REST
  door (Hermes's lane) still polls.
- `otel` is the one agent-gateway tool exempt: inline, synchronous, on Max, no `jobId`
  (why: `brain/wiki/engineering/model-routing.md`).

## Reading files and the prompt cache

Grep to locate before reading; never re-read a file already read this session;
files over 500 lines → `offset`/`limit`. Cached prefix reads are ~10–20× cheaper
than fresh input (TTL 1 h idle), so the dominant cost lever is not breaking the
cache: switching the orchestrator's model or effort, connecting/disconnecting an
MCP server, or a Claude Code upgrade all invalidate it. Subagents and agent-gateway
workers hold their own caches — the argument for delegating. When it is gone:
`/compact` or `/clear`.

## Skills by mode

Everything routed through agent-gateway exists only on the mini.

| Mode | Skills |
|-|-|
| MCP (agent-gateway, async; `/otel` sync) | `/check` · `/review` (`--deep` adds correctness + security) · `/otel` · `/excalidraw-diagram` |
| MCP · fork · subprocess | `/research` · `/browse` (chrome-devtools, haiku) · `/analyze` |
| inline — git | `/commit` (`--split`/`--amend`) · `/pr` · `/ship` · `/git-cleanup` |
| inline — build | `/wave` · `/implement` · `/upgrade-deps` · `/archify` |
| inline — ops | `/secrets` · `/cloudflare` · `/remote-dev` · `/herdr` (inert unless `HERDR_ENV=1`) · `/img` |
| inline — writing | `/brain` · `/distill` · `/podcast` |

Per-repo: `dotfiles` → `/iu-endpoint`; `hermes-agent` → `/hermes-validate`,
`/hermes-update`; `homelab` → `/audit`, `/docs`, `/upgrade-stack`; `vps` →
`/audit`, `/docs`; `agent-gateway` → `/claude-cli`; `free-planning-poker` →
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

Workflow facts per repo:

| Repo | Fact |
|-|-|
| `homelab-private` | Self-contained. Never reference its services, hostnames or details from any other repo, doc or commit. |
| `agent-gateway` | Local MCP daemon behind check/review/dispatch/otel. Mini only. |
| `research-gateway` | Behind `/research`, tailnet-only; cloud routines can't reach it. |
| `hermes-agent` | `HERMES_SKILLS` in its Makefile is the source of truth for skill domains. |
| `warden` | The control plane; `DESIGN.md` is authoritative, `STATE.md` the build state. Hermes narrates, it does not dispatch. |
| `basalt-ui` | Mantine v9 + visx (NPM). No Tailwind. Always its own commit. |
| `brain` | `wiki/` = agentic knowledge (strict lint); PARA `Projects`/`Areas` = human surface; use `/brain`. |
| `modelpick` | Source of truth for model-choice rationale; backs `cap`. |

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
