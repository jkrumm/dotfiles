# SourceRoot - Personal Projects Configuration

## Workspace Context

- **Location:** `/Users/johannes.krumm/SourceRoot/`
- **Version Control:** GitHub
- **No ticket numbers** (no JK-XX or EP-XX prefixes in this workspace)

---

## Infrastructure

### Servers

| Server | SSH | Repos | Secrets Vault |
|-|-|-|-|
| HomeLab | `ssh homelab` | `~/homelab`, `~/homelab-private` | `homelab` + `common` |
| VPS | `ssh vps` | `~/vps` | `vps` + `common` |

SSH config is in `~/.ssh/config` — key auth via Tailscale IPs. For sudo on servers:

```bash
# Homelab (requires password for sudo)
ROOT_PW=$(op read "op://Private/homelab-server/password" --account tkrumm) && ssh homelab "echo '$ROOT_PW' | sudo -S <cmd>"
# VPS (has NOPASSWD sudo — root pw rarely needed)
ROOT_PW=$(op read "op://Private/vps-server/password" --account tkrumm) && ssh vps "echo '$ROOT_PW' | sudo -S <cmd>"
```

### Repos

| Repo | Location | Purpose |
|-|-|-|
| `homelab` | `~/SourceRoot/homelab` | Main homelab stack — 25+ containers |
| `homelab-private` | `~/SourceRoot/homelab-private` | Additional private homelab services |
| `vps` | `~/SourceRoot/vps` | VPS stack — 3 compose files |
| `dotfiles` | `~/SourceRoot/dotfiles` | Claude Code dotfiles, hooks, skills, localai stack |
| `hermes-agent` | `~/SourceRoot/hermes-agent` | Hermes Agent setup (Mac Mini-only) — config, skills, patches, cron |

### Secrets (1Password)

All secrets managed via 1Password. **Always pass `--account tkrumm`** to every `op` CLI command in this workspace.

```bash
op read "op://vault/item/field" --account tkrumm
op run --account tkrumm --env-file=.env.tpl -- <command>
```

Use `/secrets` skill for vault ops.

---

## Local Dev Proxy

All services use static ports with `.test` domains (HTTPS via Caddy + dnsmasq).
Port assignments and domains are in `~/SourceRoot/dotfiles/config/Caddyfile` — that's the source of truth.

**Every app:** static port, kill port before starting (`npx kill-port PORT && ...`), `--strictPort`, entry in Caddyfile.
**Adding a service:** add block to Caddyfile, run `caddy-reload`, commit in `dotfiles`.

---

## BasaltUI Integration

**Repository:** https://github.com/jkrumm/basalt-ui
**Main CSS:** `packages/basalt-ui/src/index.css`

**Detection:** Check for `basalt-ui` in dependencies, `@import "basalt-ui/css"` in global styles.

**Config requirements** for apps using basalt-ui:
```js
// vite config
optimizeDeps: { exclude: ['basalt-ui'] }
```
```css
/* global CSS — source basalt-ui for Tailwind v4 custom utilities */
@source "../path/to/packages/basalt-ui/src";
```

**After changing components in packages/basalt-ui**: always run `bun run build` before testing.

### Component Placement Rule
- Blueprint-styled ShadCN components → `packages/basalt-ui/src/components/`
- Consumer apps re-export: `export { Button } from 'basalt-ui'`
- Commit basalt-ui first, app second (separate commits — NPM published)

---

## Skills Available

| Skill | Purpose | Context | Model |
|-|-|-|-|
| `/commit [options]` | Smart conventional commits | main | haiku |
| `/check` | Format, lint, typecheck, test | **subprocess** | haiku |
| `/review` | Multi-angle code review + CodeRabbit CLI | **subprocess** | sonnet |
| `/research <query>` | Deep technical research (WebSearch + WebFetch) | **subprocess** | sonnet |
| `/grill` | Question until clear direction, generate PRD | main | (inherits) |
| `/implement` | Guided implementation with research + explore + check | main | sonnet subagent |
| `/ship` | Full flow: check → review → commit → PR → CodeRabbit → merge → release | main | haiku |
| `/browse` | Chrome DevTools debugging via subagent | **fork** | haiku |
| `/analyze` | Deep static analysis (fallow — dead code, dupes, complexity) | **subprocess** | haiku |
| `/git-cleanup` | Squash and group noisy branch commits | main | haiku |
| `/pr [action]` | GitHub PR workflow (create, status, merge) | main | haiku |
| `/ralph [cmd]` | Autonomous multi-group implementation loop | main | sonnet |
| `/otel [env] [intent]` | Debug OTEL traces/logs/metrics in ClickHouse | **subprocess** | haiku |
| `/secrets` | 1Password vault ops, .env.tpl patterns | main | haiku |
| `/upgrade-deps` | Dependency upgrade assistant | main | (inherits) |
| `/excalidraw-diagram` | Create Excalidraw diagrams | main | haiku |
| `/read-drawing` | Interpret Excalidraw diagrams | **subprocess** | haiku |
| `/frontend-design` | Production-grade frontend interfaces | main | (inherits) |
| `/skill-creator` | Create, modify, and test skills | main | (inherits) |
| `/localai [cmd]` | Manage local AI stack (setup, status, update, monitor, swap-model) | main | haiku |
| `/hermes-validate` | Test Hermes skill routing, read session traces, fix SOUL.md/SKILL.md | main | (inherits) |
| `/hermes-update` | Update upstream Hermes Agent, re-apply local patches, restart gateway | main | (inherits) |

`/hermes-validate` and `/hermes-update` ship from `~/SourceRoot/hermes-agent/cc-skills/` (symlinked into `~/SourceRoot/.claude/skills/` by `make setup` there).

---

## Git Workflow Pipeline

```
/commit          → Commit work (one logical concern at a time)
/git-cleanup     → Group noisy commits (if ≥3 on branch)
/ship            → Full flow: check → review → PR → CodeRabbit → merge → release
```

**Or use `/ship` directly** — it auto-detects state and runs the right steps.

**Direct-to-master repos:** homelab, homelab-private, vps, dotfiles, hermes-agent, sideclaw, basalt-ui-playground — `/ship` skips PR flow.

**`/pr create` automatically:** errors on default branch, proposes branch rename, runs `/commit` if uncommitted, offers `/git-cleanup` if ≥3 commits, runs `/check` pre-flight.

**`/pr status` automatically:** warns on uncommitted/unpushed work, shows CodeRabbit feedback, offers to implement fixes.

