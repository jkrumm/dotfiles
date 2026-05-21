# OpenCode — global agent instructions

You are running via **OpenCode** as a fallback to Claude Code (used when the
Claude Code Max subscription quota is exhausted). Models are served through the
IU unified endpoint.

The user's full Claude Code configuration is authoritative and is loaded for you
via the `instructions` key in `opencode.json`:

- `~/.claude/CLAUDE.md` — global personal config, workspace map, conventions
- `~/.claude/rules/<each>.md` — the global always-on rules, listed explicitly
  (attribution, code-style, commit-conventions, docker-makefile, formatting,
  research-first, security, typescript, visx-charts)
- `.claude/rules/*.md` — per-project rules (when present)
- per-project `CLAUDE.md` — auto-loaded by OpenCode's native CLAUDE.md fallback

Follow all of those exactly. They override defaults. In particular:

- ALL written artifacts (code, commits, docs) in English.
- Never add AI/tool attribution to any artifact.
- Senior-to-senior tone: concise, precise, critical over validating.
- Stay within requested scope.

Note: OpenCode does not honor the `paths:` frontmatter Claude Code uses for lazy
loading. The global rules are therefore listed individually in `instructions` and
deliberately exclude the path-scoped framework rules (`react-best-practices`,
`tanstack-*`, `elysia`) so they don't load in unrelated projects. When such a
project needs them, put them in its project `CLAUDE.md` or `.claude/rules/`.
