# Spike: one OpenCode 2 server, many isolated agent setups (2026-10-26)

Question: can one `opencode serve` host several independent agent setups, each with its own
AGENTS.md, agent prompt, skills, commands and code? This is the "modular monolith of desks" in
`design/gateways.md`. Or would that need one server per setup?

Setup: OpenCode **2.0.32** (the estate pin), private `opencode serve` on :7799 with its own `XDG_*`
roots, IU provider config via `OPENCODE_CONFIG_CONTENT`. Two git dirs `/tmp/oc-spike/{A,B}`, each
with `AGENTS.md` (marker), `.opencode/agents/spec-<x>.md` (marker in the system prompt),
`.opencode/skills/skill-<x>/SKILL.md`, `.opencode/commands/hello-<x>.md` and
`.opencode/tools/tool_<x>.ts` (plain v1-style tool object). Reads were made through the API with
`?location[directory]=…`. One DeepSeek V4.1 Flash prompt per location asked for its tool list,
every `MARKER*` word in its context, and a call to its `tool_*`.

## Result

| Per-location thing | Isolated on one server? | Evidence |
|-|-|-|
| Agents (`.opencode/agents/*.md`) | **yes** | `GET /api/agent` → A lists `spec-a` only, B `spec-b` only |
| Commands (`.opencode/commands/*.md`) | **yes** | `GET /api/command` → `hello-a` vs `hello-b` |
| AGENTS.md + agent system prompt | **yes** | model in A quoted `MARKER_SYSTEM_A, MARKER_AGENTS_A`; B only the B pair |
| Skills (`.opencode/skills/`) | **yes, after one switch** | default: every location also sees all 25 `~/.claude/skills` (Claude Code compat). `OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=true` → A `[OpenCode, Report, skill-a]`, B `[OpenCode, Report, skill-b]` (2 built-ins) |
| Custom tools (`.opencode/tools/*.ts`, v1 shape) | **not loaded** | neither model saw `tool_*`. v2 has no tool-file loader among its builtin plugins; code extensions go through the v2 plugin API (`Plugin.define`), which runs in-process in the shared server |
| Plugins | per location (`GET /api/plugin?location…`) | v2 itself is ~90 builtin plugins, incl. `opencode.config.location-watcher` (config hot reload) |

Other facts:
- **Locations are first-class.** `GET /api/debug/location` lists the loaded locations;
  `DELETE` evicts one so its next use boots fresh; `POST /api/location/reload` exists. Services
  are cached per location, so one server is many lightweight "instances".
- **The first read after boot comes back empty**: `/api/skill` returned `[]` until the location warmed. A caller
  must warm or retry.
- The prompt body in v2 is `{text, files?, agents?, skills?, delivery?, resume?}`. `parts` is v1 and
  gets a 400.
- Baseline cost: 5,099 input tokens, **$0.001 per turn** on DeepSeek V4.1 Flash with no tools
  restricted.
- Useful endpoints for a desk host: `/api/experimental/session/{id}/skill` (activate a skill),
  `/api/experimental/session/{id}/instructions/entries` (API-managed instructions per session),
  `/api/experimental/session/stats` (usage and tool reliability per range/project),
  `/api/experimental/session/{id}/export` + `/import`.
- Asked for its tool list, the B model also named `opencode.worktree_*` / `session_*` built-ins
  that A didn't list. Same server, same agent shape. Don't trust a model's self-reported toolset.
  Permissions decide what it has.

## Verdict

The concept holds: **one server, one desk = one location directory**, each with its own
AGENTS.md, agent prompt, skills and commands, all isolated, and one process, version, DB and cost
stream. Two caveats shape the design:

1. **Code doesn't live in the desk as OpenCode tools.** Reusable code pieces are CLIs (and
   libraries behind them), reached through the desk's shell allowlist. In-process v2 plugins are
   platform-level only (telemetry, guards), owned by agent-gateway, because a plugin runs inside
   the one shared server.
2. **The host sets `OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=true`**, or every desk inherits the
   owner's Claude Code skills.
