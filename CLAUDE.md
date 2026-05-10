# dotfiles — Claude Code Instructions

## What This Repo Is

VCS source of truth for Johannes's Claude Code setup. Everything is symlinked
outward — edit at either end, git always sees the change here.

Also contains `localai/` — per-machine `mlx-audio` (TTS + STT only) bound to
`127.0.0.1:8000`. Installed automatically by `make setup` on every Mac.
LLM is not local — Hermes uses cloud Sonnet 4.6 via the IU unified endpoint.
See `localai/README.md` and the `/localai` skill.

**Companion repo: `~/SourceRoot/hermes-agent`** — Hermes Agent setup (Mac Mini-only).
Pulls the `localai-helper` plist template from `localai/com.localai.helper.plist.template`
in this repo, but otherwise self-contained. See `hermes-agent/CLAUDE.md`.

**After any edit: commit here.**

## Symlink Map

| File here | Live path | Notes |
|-|-|-|
| `config/global.CLAUDE.md` | `~/.claude/CLAUDE.md` | Global Claude instructions |
| `config/sourceroot.CLAUDE.md` | `~/SourceRoot/CLAUDE.md` | SourceRoot workspace |
| `config/zshrc` | `~/.zshrc` | Thin loader — sources all modules in conf.d |
| `config/zsh/*.zsh` | `~/.zsh/conf.d/` (dir symlink) | ai, aliases, claude, git, keybindings, path, secrets, tools |
| `config/gitconfig` | `~/.gitconfig` | includeIf per workspace |
| `config/gitconfig-personal` | `~/.gitconfig-personal` | jkrumm@pm.me + 1Password signing |
| `config/gitconfig-work` | `~/.gitconfig-work` | johannes.krumm@iu.org + 1Password signing |
| `config/gitignore_global` | `~/.gitignore_global` | sc-queue.md, sc-note.md |
| `config/ghostty/config` | `~/.config/ghostty/config` | Shell integration + option key settings |
| `config/ghostty/config.cmux` | `~/Library/Application Support/com.mitchellh.ghostty/config` | Primary cmux config — font, theme, cursor, padding |
| `config/ghostty/themes/*` | `~/.config/ghostty/themes/` | Blueprint v6 light/dark terminal themes (copied, not symlinked — cmux symlink bug) |
| `config/Caddyfile` | `$(brew --prefix)/etc/Caddyfile` | Local HTTPS reverse proxy — edit here, then `caddy reload` |
| `scripts/wakeup.sh` | `~/.wakeup` | sleepwatcher hook — runs `caddy reload` on wake |
| `hooks/notify.ts` | `~/.claude/hooks/notify.ts` | All 4 hook events |
| `hooks/protect-branches.ts` | `~/.claude/hooks/protect-branches.ts` | PreToolUse — blocks push to protected branches |
| `hooks/docker-makefile.ts` | `~/.claude/hooks/docker-makefile.ts` | PreToolUse — blocks raw docker commands when Makefile exists |
| `scripts/statusline.sh` | `~/.claude/statusline.sh` | 3-line statusline |
| `scripts/fetch_usage.py` | `~/.claude/fetch_usage.py` | Claude.ai usage % fetcher (uv script) |
| `rules/` | `~/.claude/rules/` (dir symlink) | Global rules (see `rules/*.md`, e.g., attribution, commit conventions, formatting, research-first, security, TypeScript, code style) |
| `skills/{name}/` | `~/SourceRoot/.claude/skills/{name}/` | SourceRoot-only |
| `skills/` (each) | `<repo>/.claude/skills` for each `~/SourceRoot/<repo>/` | Per-project links so Zed's vendored Claude ACP (no `--plugin-dir`) sees shared skills. Whole-dir symlink when project has no local `.claude/skills/`; per-skill symlinks alongside local skills otherwise. Created by `make setup`, refreshed lazily on `c()` launch. Gitignored globally via `.claude/skills`. |
| `config/sourceroot.CLAUDE.md` (via import) | `<repo>/CLAUDE.local.md` for each `~/SourceRoot/<repo>/` | One-line `@~/SourceRoot/CLAUDE.md` import. Zed's ACP doesn't walk parents above workspace root, so SourceRoot CLAUDE.md needs to be reachable from inside each repo. CLAUDE.local.md loads alongside committed CLAUDE.md (concatenated). Created by `make setup`, refreshed lazily on `c()`. Gitignored globally via `CLAUDE.local.md`. |

**Generated (not symlinked):** `~/.ssh/config` — written by `_setup-ssh` from `config/ssh_config` template; hostname injected from `op://Private/iumac-server/hostname`.

**Not symlinked:** `~/.claude/settings.json` — machine-specific permissions.
`make setup` creates from template if missing, otherwise jq-merges:
template wins on structural keys (hooks, statusLine, plugins, env); permissions + model/effortLevel/alwaysThinkingEnabled preserved from live file.

## Secrets Strategy

Two 1Password accounts are configured:
- **`tkrumm`** — personal account, used in `~/SourceRoot/`. Always pass `--account tkrumm` to `op` CLI.
- **`careerpartner`** — work account, used in `~/IuRoot/`. Always pass `--account careerpartner` to `op` CLI.

`make setup` uses `--account tkrumm` (biometric/session token via Touch ID).

`ANTHROPIC_API_KEY` is intentionally **not exported** — Claude Code falls back to the subscription when the key is absent. Exporting it would cause Claude Code to bill API credits instead.

**API keys** cached in macOS Keychain by `make setup`:
- `CLAUDE_SDK_API_KEY` + `CLAUDE_SDK_BASE_URL` — from `op://common/anthropic/API_KEY` and `BASE_URL`. Used for API offloading via `claude -p`.
- `TAVILY_API_KEY` — from `op://common/tavily/API_KEY`. Used by `/research` skill for web search.

**Chrome DevTools MCP** — registered globally with deferred tool loading (~400 tokens overhead). Used exclusively via `/browse` skill (haiku fork) to isolate expensive MCP responses from main context.

**CodeRabbit CLI** — requires one-time auth: `coderabbit auth login` (GitHub OAuth). Free tier: 3 reviews/hour. Used by `/review` and `/ship` skills.

**New machine setup:**
1. Install 1Password + enable CLI integration (Settings → Developer → Enable CLI)
2. `make setup` — will fail fast with instructions if 1Password isn't ready

## Editing Rules

**Adding a skill:** create `skills/{name}/SKILL.md` here, then `make setup`.
Never create directly in `~/SourceRoot/.claude/skills/` — won't be in VCS.

**Adding a global rule:** create `rules/{name}.md` here. The entire `rules/` dir is symlinked to `~/.claude/rules/`. Rules without `paths:` frontmatter load every session. Rules with `paths:` load lazily.

**Skills scope:** loaded only in SourceRoot via `--plugin-dir ~/SourceRoot/.claude`
in `c()`. Not available in IuRoot — intentional. IuRoot uses per-project `.claude/`.

**settings.json changes:** update `config/settings.template.json`, then `make setup`
to merge into the live file. Never edit the live settings.json for persistent changes.

## Debug Logs

Structured JSONL logs at `~/.claude/logs/YYYY-MM-DD.jsonl`. Written by `hooks/notify.ts` and `scripts/fetch_usage.py`. 3-day auto-cleanup on every invocation.

**Query examples:**
```bash
# All events today
cat ~/.claude/logs/$(date +%Y-%m-%d).jsonl | jq .

# Hook stop decisions only
cat ~/.claude/logs/$(date +%Y-%m-%d).jsonl | jq 'select(.event == "stop_decision")'

# Question detection results (why queue fired or paused)
cat ~/.claude/logs/$(date +%Y-%m-%d).jsonl | jq 'select(.event == "question_detect" or .event == "haiku_call" or .event == "haiku_skip")'

# fetch_usage errors
cat ~/.claude/logs/$(date +%Y-%m-%d).jsonl | jq 'select(.src == "fetch_usage")'
```

**Key events to check when debugging:**
- Queue fires on a question → look for `question_detect` (check `reason`, `has_question_mark`) and `haiku_skip` (check `no_api_key`)
- Haiku not called → `haiku_skip` with `reason: "no_api_key"` means `ANTHROPIC_API_KEY` not in hook env
- fetch_usage broken → `fetch_error` with `type` field shows which exception class failed
- Unexpected stop behavior → `stop_decision` shows exact decision taken

## Terminal Setup

**cmux** (`/Applications/cmux.app`) is the primary terminal — a macOS-native multiplexer built on top of Ghostty. It is **not tmux**. cmux reads `~/.config/ghostty/config` for terminal rendering (same syntax as Ghostty) and stores its own app preferences (appearance mode, sidebar, etc.) in macOS defaults under `com.cmuxterm.app`.

**Config files (two separate files, both managed in dotfiles):**
- `~/Library/Application Support/com.mitchellh.ghostty/config` — **primary cmux config** (font, theme, cursor, padding). This is what cmux actually reads.
- `~/.config/ghostty/config` — shell integration + option key settings only; lower priority

**Theme auto-switching:**
- cmux app chrome: `appearanceMode = system` (stored in plist — follows macOS appearance)
- Terminal colors: `theme = dark:basalt-ui-dark,light:basalt-ui-light` in the cmux config above
- Theme files: copied (not symlinked) to `~/.config/ghostty/themes/` — cmux has a bug where it skips symlinked theme files
- Claude Code: `c()` in `claude.zsh` writes `theme` key to `~/.claude.json` via `jq` on each launch

## Key Technical Facts

- `sc-queue.md` blocks separated by `\n---\n`. Block types: plain text (◆), `/slash` (⚡), `STOP` (⏹).
- Stop hook: JSON `{"decision":"block","reason":task}` to stdout + `process.exit(0)` continues session. Queue empties = natural stop.
- STOP exits with code 0 synchronously — no async notification call before exit.
- Skills have optional `model:` frontmatter (`haiku` for fast forks, default = sonnet).
- `c()` in zshrc: sets `--plugin-dir` and `--dangerously-skip-permissions` per workspace.
