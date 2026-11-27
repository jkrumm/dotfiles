# Global reference — what `~/.claude/CLAUDE.md` links to

The global CLAUDE.md loads in every session and routes; this file holds the
detail it points at. Repo descriptions live only in `docs/architecture.md`
§Repos, model ids only in `agw routes`.

## Parallelism — cheapest tier first

| Tier | Mechanism | Use when |
|-|-|-|
| 1 | Parallel `/check` calls (agw) in **one turn** | Independent verifiable *reads and checks* (`check`); `/review` runs in-session (host commands plus a foreground reviewer agent), not as a parallel call. Independent *changes* are factory Issues |
| 2 | Background `Agent` (`run_in_background: true`) | Long work to detach from and resume (`SendMessage`); keep it thin |
| 3–4 | Foreground `Agent` on a stronger model · agent teams | Novel hard logic only; rarely worth it |

`Task*` tools are a built-in coordination layer, not MCP-backed. Routines /
`/schedule` run in Anthropic's cloud and **cannot reach** agent-workflows (localhost/tailnet).

## Async-job contract

- `/check`, `/research` and `/otel` are not jobs you poll (`/review` is host commands plus an in-session agent, no run to wait on): the agw verbs
  behind them block up to `AGW_WAIT_BUDGET_S` (default 110 s), then exit 10
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

Everything routed through agw exists only on the mini.

| Mode | Skills |
|-|-|
| agw CLI (sync, exit-10 resume `agw run wait <runId>`; every command: `agw schema --index`) | `/research` · `/otel` · `/check` · `/review` (reviewer agent in-session) · `/prose` (rewrite in-session) · `/podcast` · `/img` · `/excalidraw-diagram` · `/brain` lookups |
| CLI + MCP · subagent | `/browse` (`browser` agent, haiku: playwright-cli on the shared Chrome, chrome-devtools CLI for traces, Lighthouse and CSS; see *Shared browser*) · `/analyze` (fallow in a native subagent) |
| Workflow fan-out | `/lenses` (expert lenses on one undertaking, only on an explicit ask. Seam form for a system that exists: 8 to 20 lenses, one session per lens in a Herdr tab, two challengers, one plan. Wide form for a new concept: 40 to 90 Workflow agents, source audit, gap rounds, synthesis handover; tens of millions of tokens) |
| inline — git | `/commit` (`--split`/`--amend`) |
| inline — build | `/upgrade-deps` · `/archify` |
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
`rollhook`, `rollhook-action`, `software-factory`, `weatherorb`. `make github-config` applies two tiers: those repos
and any with a collaborator get the full ruleset; other public repos get lite (no
PR rule). Private repos can't be protected for free. In a factory session it runs
tighten-only (`make github-config-tighten`): it writes what adds or strengthens
protection and skips, with exit 3, any repo it would loosen — that one is the owner's
by hand, so a lead raises an Errand for it.

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
Main repos (GitHub `IU-Group-Engineering`): `epos-studentenrolment-{backend,frontend}`
(the frontend merges the former booking and academic-profile applets),
`epos-{orchestrator,customers,grades}-frontend`, `epos-studyprogress-backend`,
`epos-dam-backend`, `epos-tool-athena`. Rarely touched (GitLab):
`epos.{crm-bridge,exam,finance-bridge,iam}`,
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
content, agent-chat, forms, notifications. Colour via basalt tokens (`--vx-*` on 2.x, `--basalt-*` from 3.0)
(`basalt-ui/tokens` → `VX.*` on 2.x, `BASALT.*` from 3.0, + `alpha()`), never raw hex. `BasaltProvider`
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

One table: `config/zsh/AGENTS.md` (and `docs/codex.md` for the
non-Anthropic lane: `cx`, `cxa`, `astra`). Rationale:
`brain/wiki/engineering/model-routing.md`.

## Shared browser

One headless Chrome serves every browser check (`/browse`, `agents/browser.md`), replacing a chrome-devtools-mcp plus its own Chrome
per agent (about 135 MiB for the server, wrapper and watchdog, 0.35 to 0.45 GiB for Chrome).

| | |
|-|-|
| Command | `shared-chrome --help` lists the verbs (`ensure` prints `http://127.0.0.1:9223`); `make shared-chrome-status` |
| Process | Chrome headless, profile `~/.local/share/shared-chrome` (never signed in anywhere), DevTools on `127.0.0.1:9223` only. The port drives the browser for anything on the machine that can reach it |
| Supervisor | `scripts/shared-chrome.ts run` under `com.jkrumm.shared-chrome` (loaded, not running; `ensure` kickstarts it; with no job loaded `ensure` runs it detached). Registry: shared-chrome, on-demand |
| Idle | a context whose pages did not open, close, navigate or retitle for 15 min is closed (the same 15 min is `playwright-cli attach --idle-timeout`, which detaches and closes the session's context); 60 s without a context, Chrome stops and the supervisor exits. A crashed Chrome ends the supervisor and the next `ensure` restarts both |
| Drive | playwright-cli 0.1.24 (`make setup`, npm global; `playwright-cli --help` lists the verbs). Attach over CDP, one isolated context per agent. A new context is 1280x720; `resize` sets the viewport and the screenshot size is the check |
| Performance | chrome-devtools 1.13.0 (`make setup`, npm global, CLI only) for traces with insights, Lighthouse and `get_css_styles`: one background daemon per user, attached to `127.0.0.1:9223`, started by `shared-chrome devtools` and stopped by the supervisor with Chrome; an agent never runs its `start` or `stop`, and a daemon attached elsewhere (`--autoConnect`) is never touched; a stray one with its own Chrome (no attach flag) is reaped at 10 min. It works on the tab playwright-cli opened. `shared-chrome status` shows it; detail and measurements: `docs/browser.md` §chrome-devtools CLI |
| Not covered | basalt-ui's own harness (starts its own Chrome in test slots) and the research Chrome on `:9222` (`agw web`). Every browser on the mini, what each costs and which one a job gets: `docs/browser.md`, `rules/browser.md` |
| Log | `~/Library/Logs/shared-chrome.log` |
