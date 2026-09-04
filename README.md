# dotfiles

Source of truth for Johannes's Claude Code setup and machine bootstrap. Config
files live here and are symlinked outward — `~/.zshrc`, `~/.gitconfig`,
`~/.claude/` hooks/scripts/skills/rules all point into this repo. Edit at
either end; git always sees the change here.

## Two machines

The Mac mini is the always-on dev host — agents run there and outlive any
client. The MacBook is a thin client: `desk` attaches to the mini's herdr
session over ssh, `rd`/`agent-dispatch` put work on the mini with no terminal
needed at all. Full model, including the reverse `mini → iumac` leg and the
secrets/access split between the two: `docs/architecture.md`.

## Bootstrap

```bash
git clone git@github.com:jkrumm/dotfiles.git ~/SourceRoot/dotfiles
cd ~/SourceRoot/dotfiles
make setup              # idempotent — safe to re-run after any change
coderabbit auth login   # one-time CodeRabbit CLI auth (GitHub OAuth)
```

`make setup` handles: symlinks, Homebrew tools (from `Brewfile`), 1Password
auth, Keychain API-key caching, MCP registration, `settings.json` merge.

## Everyday commands

| Command | Does |
|-|-|
| `make setup` | Converge this machine onto the tracked config. Idempotent. |
| `make status` | Read-only snapshot of this machine's state. |
| `make doctor` | Read-only health check — self-routes: on the MacBook it also runs the mini's doctor over ssh. |
| `make theme` | Apply the terminal/herdr/prompt theme and reload live. |

Machine-specific setup (remote access, battery limiter, backups, etc.) is
opt-in per target — see `CLAUDE.md` for the full list.

## Layout

```text
dotfiles/
├── config/          global.CLAUDE.md, zshrc, zsh modules, gitconfig, ghostty, Caddyfile
├── scripts/         setup/health/maintenance scripts invoked by Makefile targets
├── skills/          Global Claude Code skills (→ ~/.claude/skills/)
├── .claude/skills/  Per-repo skills, committed here (e.g. iu-endpoint)
├── rules/           Global rules (→ ~/.claude/rules/)
├── agents/          Global subagents (→ ~/.claude/agents/), e.g. @implementer
├── hooks/           SessionStart/PreToolUse hooks (→ ~/.claude/hooks/)
├── docs/            Architecture, remote-dev, homebrew, theme, devhost-health
└── Makefile         Bootstrap + every idempotent setup/maintenance target
```

## Full reference

`CLAUDE.md` is the source of truth for everything else: workspaces, machine
reach, secrets strategy, and skill routing. Loaded automatically in every
Claude Code session; read it directly for anything this file doesn't cover.
