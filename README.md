# dotfiles

Version-controlled source of truth for Johannes's local Claude Code setup.
Config files live here and are symlinked outward — `~/.zshrc`, `~/.gitconfig`,
`~/.claude/` hooks/scripts/skills/rules all point into this repo.

## Strategy

**Token-efficient, model-routed Claude Code setup** optimized for a solo senior developer hitting daily 5h subscription windows.

### Architecture Principles

| Principle | Implementation |
|-|-|
| Lean context | CLAUDE.md files <150 lines each, conventions in `.claude/rules/` |
| Model routing | Opus for strategy, Sonnet for implementation, Haiku for all delegation |
| Fresh over fork | Haiku subagents with fresh context, not conversation forks |
| No MCPs in main | Chrome DevTools MCP with deferred loading (~400 tokens). Research/search via CLI/API |
| API offloading | `claude -p` with Keychain-cached API key for expensive repetitive tasks |
| Rules > CLAUDE.md | Focused `.claude/rules/*.md` files (96% adherence vs 92% for monolithic CLAUDE.md) |

### Token Budget per Session

| Layer | Tokens | Content |
|-|-|-|
| Global CLAUDE.md | ~2,000 | Personal context, workspaces (SourceRoot + IuRoot + Obsidian), 1P routing, skills, workflow |
| Global rules (8 files) | ~1,400 | Attribution, commits, TS, code style, security, formatting, research, docker-makefile |
| Chrome DevTools (deferred) | ~400 | Tool names only — schemas loaded on demand |
| **Total baseline** | **~3,800** | Single CLAUDE.md (no workspace-level intermediate layer) |

### Model Routing

| Model | Use | Skills |
|-|-|-|
| Opus | Strategy, planning, PRD, architecture | `/grill`, main conversation |
| Sonnet | Implementation, complex code changes | `/ralph`, `/implement` |
| Sonnet | Reasoning-heavy subprocesses | `/review`, `/research` (subprocess, subscription) |
| Haiku | Mechanical subprocesses + orchestration | `/check`, `/analyze`, `/otel`, `/read-drawing` (subprocess, API) + `/browse` (fork) + `/commit`, `/pr`, `/ship`, `/secrets`, `/git-cleanup` (main) |

### Workflow

```text
Idea → /grill → PRD → /ralph or /implement → /ship
                                                ↓
                                 check → review → commit → PR
                                 → CodeRabbit iteration → merge → release
```

Small tasks (infra, config): implement → `/ship` (auto-detects direct-to-master).

## Structure

```text
dotfiles/
├── config/          global.CLAUDE.md, zshrc, zsh modules, gitconfig, ghostty,
│                    Caddyfile, settings.template.json
├── rules/           8 global rules (→ ~/.claude/rules/)
├── hooks/           notify.ts (all 4 events), protect-branches.ts, docker-makefile.ts
├── scripts/         statusline.sh, fetch_usage.py, github-config.sh, wakeup.sh
├── skills/          21 global Claude Code skills (→ ~/.claude/skills/)
├── .claude/skills/  Per-repo skills (e.g. /localai)
├── localai/         Per-machine mlx-audio + Fish-S2-Pro TTS/STT stack
└── Makefile         Bootstrap + idempotent setup
```

## Bootstrap

```bash
git clone git@github.com:jkrumm/dotfiles.git ~/SourceRoot/dotfiles
cd ~/SourceRoot/dotfiles
make setup        # idempotent — safe to re-run after any change
coderabbit auth login   # one-time CodeRabbit CLI auth (GitHub OAuth)
```

`make setup` handles: symlinks, Homebrew tools, 1Password auth, API key caching (Anthropic SDK + Tavily → Keychain), Chrome DevTools MCP registration, settings.json merge.

## Symlink Map

| dotfiles | Live path |
|-|-|
| `config/global.CLAUDE.md` | `~/.claude/CLAUDE.md` |
| `rules/` | `~/.claude/rules/` |
| `skills/{name}/` | `~/.claude/skills/{name}/` |
| `config/zshrc` | `~/.zshrc` |
| `config/zsh/` | `~/.zsh/conf.d/` |
| `config/gitconfig*` | `~/.gitconfig*` |
| `config/gitignore_global` | `~/.gitignore_global` |
| `config/ghostty/` | `~/.config/ghostty/` |
| `hooks/notify.ts` | `~/.claude/hooks/notify.ts` |
| `hooks/protect-branches.ts` | `~/.claude/hooks/protect-branches.ts` |
| `hooks/docker-makefile.ts` | `~/.claude/hooks/docker-makefile.ts` |
| `scripts/statusline.sh` | `~/.claude/statusline.sh` |
| `scripts/fetch_usage.py` | `~/.claude/fetch_usage.py` |

**Not symlinked:** `~/.claude/settings.json` (machine-specific permissions — jq-merged from template).

## Skills

**21 global skills** at `~/.claude/skills/` — load everywhere (SourceRoot, IuRoot, anywhere). Source of truth: `skills/{name}/SKILL.md` in this repo.

Execution modes (full table with mode + worker model in `config/global.CLAUDE.md`):

| Mode | Examples | Cost profile |
|-|-|-|
| **inline** | `commit`, `pr`, `ship`, `git-cleanup`, `secrets`, `grill`, `implement`, `frontend-design`, `skill-creator`, `upgrade-deps`, `excalidraw-diagram`, `cloudflare`, `ralph` (sonnet) | Runs on session model — no model switch, no fork |
| **subprocess** (`claude -p`) | `analyze`, `otel`, `read-drawing` | API credits via Keychain, output isolated |
| **MCP (sideclaw)** | `check`, `review`, `research` | Schema-validated JSON, quota-aware Max↔IU routing |
| **fork** (`context: fork`) | `browse` | Wraps the chrome-devtools MCP — Max quota |

**Per-repo skills** (committed in their repo's `.claude/skills/`, auto-load when Claude starts inside):
- `dotfiles/.claude/skills/localai/` — manage the mlx-audio + Fish-S2-Pro stack
- `hermes-agent/.claude/skills/{hermes-update,hermes-validate}/` — manage Hermes
- Project-committed skills in other SourceRoot repos (release-fpp, audit, docs, prowlarr, raycast-extension, etc.)

## API Keys (Keychain-cached)

| Key | Source | Purpose |
|-|-|-|
| `claude-sdk-api-key` | `op://common/anthropic/API_KEY` | API offloading via `claude -p` |
| `claude-sdk-base-url` | `op://common/anthropic/BASE_URL` | Custom API endpoint |
| `tavily-api-key` | `op://common/tavily/API_KEY` | Web search in `/research` skill |

## Key Tooling

| Tool | Purpose |
|-|-|
| **notify.ts** | All 4 Claude Code events: timing, notifications, session end |
| **statusline.sh** | Model/context/tokens/duration, cwd/branch |
| **coderabbit** | Local code review CLI (free: 3 reviews/hr) |
| **wtp** | Git worktree management with post-create hooks |

## Per-Repo AI Files (globally gitignored)

| File | Purpose |
|-|-|
| `sc-note.md` | Session notes — surfaced by the sideclaw dashboard |
