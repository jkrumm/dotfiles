# AGENTS.md as the shared instruction file

One instruction file per directory that Claude Code, OpenCode and Codex all read,
without losing anything Claude Code has today. Proven 2026-09-23 on Claude Code
2.1.280, OpenCode 1.18.30, Codex 0.155.1 with a canary repo (a unique marker per
file, each agent asked which markers are in its context), plus an interactive
`/memory` check in a herdr pane.

## The pattern

```
AGENTS.md            ← all content, tool-neutral, no @imports
CLAUDE.md            ← "@AGENTS.md" (+ Claude-only lines below it, e.g. "@./DESIGN.md")
sub/AGENTS.md        ← nested content
sub/CLAUDE.md        ← "@AGENTS.md" — needed, see below
.claude/rules/*.md   ← unchanged
.claude/skills/*/    ← unchanged
```

Global: `~/.claude/CLAUDE.md` stays as is — Claude and OpenCode both load it.
OpenCode gets the rules through `instructions` globs in its global config.

## Why not a bare AGENTS.md (no CLAUDE.md)

Claude Code reads AGENTS.md directly only when the session fetches Anthropic
feature flags. Measured:

| Setup | Max (`c`, `claude -p`) | IU endpoint, warm `~/.claude` | IU endpoint, cold config dir |
|-|-|-|-|
| AGENTS.md only | loads (root + nested) | loads — rides the flag cached by a Max session | **nothing loads** |
| `CLAUDE.md` = `@AGENTS.md` | loads | loads | loads |

The warm-IU case works only because a Max session cached
`tengu_agents_md_mod` into `~/.claude.json` — any cold config (a fresh machine,
an isolated worker `CLAUDE_CONFIG_DIR`) silently drops the project instructions.
The shim is the only setup that works on every lane. The import never
double-loads (documented, and `/memory` shows `./CLAUDE.md → AGENTS.md
@-imported`).

`pluginConfigs["agents-md@builtin"].options.instructionFiles =
"claude-md-and-agents-md"` would make nested AGENTS.md load next to a root
CLAUDE.md — but it is a feature-flag path too, so it fails the same cold lanes.
Not used.

## Measured matrix (shim in place)

| Source | Claude (all lanes) | OpenCode | Codex |
|-|-|-|-|
| root AGENTS.md | via import | yes | yes |
| `@imports` inside AGENTS.md | yes | **no** | **no** |
| nested `sub/AGENTS.md` | only with `sub/CLAUDE.md` shim (a root CLAUDE.md suppresses nested AGENTS.md) | yes, lazily | from cwd upward only |
| `.claude/rules/*.md` | yes (`paths:` honoured) | only via `instructions` glob — loaded always, `paths:` ignored | no |
| `.claude/skills/` + `~/.claude/skills/` | yes | yes, natively (symlinks fine) | no — `.agents/skills` symlink would work, deliberately not done |
| global | `~/.claude/CLAUDE.md` | `~/.claude/CLAUDE.md` (fallback when no `~/.config/opencode/AGENTS.md`) | `~/.codex/AGENTS.md` |
| subagents | `general-purpose`/`implementer` see it; `Explore` skips project instructions (as with CLAUDE.md today) | — | — |

## OpenCode global config (the rules half)

Verified with `OPENCODE_CONFIG`; relative globs resolve from subdirectories too.
List only the always-on global rules — a `paths:`-scoped rule would load on
every turn.

```json
{
  "$schema": "https://opencode.ai/config.json",
  "instructions": [
    ".claude/rules/*.md",
    "~/.claude/rules/agent-limits.md", "~/.claude/rules/attribution.md",
    "~/.claude/rules/code-style.md", "~/.claude/rules/commit-conventions.md",
    "~/.claude/rules/dependency-hygiene.md", "~/.claude/rules/docker-makefile.md",
    "~/.claude/rules/formatting.md", "~/.claude/rules/research-first.md",
    "~/.claude/rules/security.md", "~/.claude/rules/typescript.md"
  ]
}
```

Provider wiring (verified 2026-09-24): `anthropic` → `{env:IU_ANTHROPIC_BASE}/v1`
for Claude ids, and `iu` (`"npm": "@ai-sdk/openai-compatible"`) →
`{env:IU_OPENAI_BASE}` for `deepseek-v4.1-flash` (the default; per-model
`options.reasoningEffort` + `variants`). Both keys are `{env:IU_KEY}` — env
substitution keeps the host out of git. Full block: `config/opencode/opencode.json`.

## Migration rules per repo

1. Move `CLAUDE.md` content to `AGENTS.md` verbatim; `CLAUDE.md` becomes
   `@AGENTS.md`. Same for every nested `CLAUDE.md`.
2. Any `@path` import line (`@./DESIGN.md` in argo, image-gen, rb,
   linewatch/web) moves to `CLAUDE.md` below `@AGENTS.md`; AGENTS.md gets a
   plain pointer ("Design system: read `DESIGN.md` before UI work") so
   OpenCode/Codex still find it. Lines like `@router.get(...)` are code, not
   imports — leave them.
3. Wording: say "agents", not "Claude", where the fact is tool-neutral. Skill
   names (`/check`, `/commit`) stay — OpenCode loads the same skills.
4. **Special cases:** `brain/AGENTS.md` is already the Hermes traversal
   contract and `brain/CLAUDE.md` only *mentions* it — merge deliberately, don't
   overwrite. `basalt-ui/packages/basalt-ui/AGENTS.md` ships in the NPM package
   for consumers — it is not the maintainer file; leave it and keep that
   directory's CLAUDE.md as-is. `modelpick/fixtures/bench/house-rules/CLAUDE.md`
   is a benchmark fixture — don't touch.
5. Keep `.claude/rules` and `.claude/skills` where they are.

## Reproduce

Canary repo: `AGENTS.md`, an `@import`, `sub/AGENTS.md`, `.claude/rules/poc.md`,
`.claude/skills/poc-skill/`, each carrying a `CANARY-*` marker. Ask with no
tools: "list every `CANARY-[A-Z-]+` string in your context". Cold lane:
`CLAUDE_CONFIG_DIR=$(mktemp -d)` + the IU `ANTHROPIC_BASE_URL`/`AUTH_TOKEN`.
Nested: ask the agent to Read `sub/x.txt` first. OpenCode: `opencode debug skill`
lists discovered skills; `opencode run -m <model> '<prompt>'`.
