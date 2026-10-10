# AGENTS.md as the shared instruction file

One instruction file per directory that Claude Code, OpenCode and Codex all read,
without losing anything Claude Code has today. Proven 2026-09-23 on Claude Code
2.1.280, OpenCode 1.18.30, Codex 0.155.1 with a canary repo (a unique marker per
file, each agent asked which markers are in its context), plus an interactive
`/memory` check in a herdr pane.

## The pattern

```
AGENTS.md            ← all content, tool-neutral, no @imports
sub/AGENTS.md        ← nested content
.claude/rules/*.md   ← unchanged
.claude/skills/*/    ← unchanged
```

**AGENTS.md is the only per-repo instruction file.** No `CLAUDE.md`, root or
nested: any `CLAUDE.md` in cwd or above suppresses Claude Code's direct
AGENTS.md reading (root and nested alike). That includes `CLAUDE.local.md` —
**never commit one**, and keep personal notes out of repo roots (`sc-note.md` is
gitignored for that reason).

Global: `~/.claude/CLAUDE.md` stays as is — Claude and OpenCode both load it.
OpenCode gets the rules through `instructions` globs in its global config.

## History — why the shim existed, why it is gone

Through Claude Code 2.1.280, AGENTS.md was read only when the session fetched
Anthropic feature flags (`tengu_agents_md_mod`), so a cold `CLAUDE_CONFIG_DIR`
(fresh machine, isolated worker) silently dropped project instructions. A
`CLAUDE.md` containing `@AGENTS.md` was the only setup that worked on every lane,
at the price of one 11-byte file per directory and of nested AGENTS.md being
suppressed by a root CLAUDE.md (so each nested dir needed its own shim).

Re-measured 2026-10-09 on 2.1.295: AGENTS.md alone loaded on the IU endpoint with
a cold config dir and with a warm one; per the docs the flag dependency ended in
v2.1.281. 2026-10-10 on 2.1.296 (Max, mini): root and nested AGENTS.md both load
with no CLAUDE.md anywhere in the tree. Every shim in SourceRoot was deleted in
Wave 11 (`docs/waves/PLAN.md`).

Not re-measured 2026-10-10 (the mini holds no IU credentials; `codex exec`
printed nothing): IU warm/cold, `rd wave`, an agent-gateway Claude-harness
worker, OpenCode, Codex. OpenCode and Codex never depended on CLAUDE.md; if a
cold lane ever stops loading instructions, restore the shim for that repo and
re-run *Reproduce* below.

Hooks: `InstructionsLoaded` does not fire for directly-read AGENTS.md. None is in
use today.

## Permissions in checked-in settings

A repo's checked-in `.claude/settings.json` carries **no `ask` rules**. An `ask`
rule still prompts under `--dangerously-skip-permissions`, so it stalls every
unattended agent (push, glab) with nobody to answer. Hard stops go in `deny`;
personal prompts belong in the untracked `settings.local.json`. Swept
2026-10-10: no SourceRoot repo had any.

## Measured matrix

| Source | Claude (all lanes) | OpenCode | Codex |
|-|-|-|-|
| root AGENTS.md | yes | yes | yes |
| `@imports` inside AGENTS.md | no (not needed — none in use) | **no** | **no** |
| nested `sub/AGENTS.md` | yes (2.1.296, no CLAUDE.md anywhere) | yes, lazily | from cwd upward only |
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
    "~/.claude/rules/dependency-hygiene.md",
    "~/.claude/rules/formatting.md", "~/.claude/rules/research-first.md",
    "~/.claude/rules/security.md", "~/.claude/rules/typescript.md"
  ]
}
```

Provider wiring (verified 2026-09-24): `anthropic` → `{env:IU_ANTHROPIC_BASE}/v1`
for Claude ids, and `iu` (`"npm": "@ai-sdk/openai-compatible"`) →
`{env:IU_OPENAI_BASE}` for the default DeepSeek id (per-model
`options.reasoningEffort` + `variants`). Both keys are `{env:IU_KEY}` — env
substitution keeps the host out of git. Full block: `config/opencode/opencode.json`.

## Repo contract — how agents learn a repo

**This section is the authority** (rationale: `docs/agent-platform.md`). Every
repo with a runtime ships four Make targets and four AGENTS.md sections, so no
central component (warden, agent-gateway, Hermes) holds per-repo knowledge.

| Make target | Contract |
|-|-|
| `make check` | all local validation; non-zero on failure; no side effects |
| `make deploy` | ships the merged default branch; CI-deployed repos print `deployed by CI on push` and exit 0; self-hosting repos (warden, agent-gateway, hermes-agent) roll back to the previous commit if their own health check fails |
| `make verify` | probes production; exit 0 = live and healthy |
| `make logs` | bounded tail of production logs, then exits |

Aliases and thin wrappers around existing scripts are fine; the names are the
interface. AGENTS.md carries exactly these sections, in this order, among its own:

| Section | Holds |
|-|-|
| `## Validate` | what `make check` runs, and anything it does not cover |
| `## Deploy` | how the default branch ships (CI, RollHook, `make deploy`) and the rollback story |
| `## Verify & Monitor` | the **full** health URL, the Kuma monitor name, the OTel `service.name` |
| `## Gotchas` | the traps that cost someone an hour |

Repos without a runtime (`brain`, `kobo-mods`, `dotfiles-private`) need `check`
only, and only if trivial. A signal is routed to a repo by its own label (Kuma
tag, OTel `service.name`, GitHub repo); the fallback is triage reading candidate
repos' `## Verify & Monitor`. Never put hostnames or secrets in these sections
for repos that are public (`rules/security.md`).

## Rules per repo

1. Content lives in `AGENTS.md`, root and nested. Never add a `CLAUDE.md` or
   `CLAUDE.local.md` to a repo.
2. No `@path` imports (OpenCode/Codex ignore them). A design-system file gets a
   plain pointer in AGENTS.md ("read `DESIGN.md` before UI work").
3. Wording: say "agents", not "Claude", where the fact is tool-neutral. Skill
   names (`/check`, `/commit`) stay — OpenCode loads the same skills.
4. Exceptions: `modelpick/fixtures/bench/house-rules/CLAUDE.md` is a benchmark
   fixture — don't touch. `basalt-ui/packages/basalt-ui/AGENTS.md` ships in the
   NPM package; maintainer-only content must not land in it.
5. Keep `.claude/rules` and `.claude/skills` where they are.
6. basalt-ui's managed `<!-- basalt:begin -->` block is placed in **AGENTS.md**
   (basalt-ui ≥ the Wave 11 release); the CLI migrates an old CLAUDE.md block out.

## Reproduce

Canary repo: `AGENTS.md`, an `@import`, `sub/AGENTS.md`, `.claude/rules/poc.md`,
`.claude/skills/poc-skill/`, each carrying a `CANARY-*` marker. Ask with no
tools: "list every `CANARY-[A-Z-]+` string in your context". Cold lane:
`CLAUDE_CONFIG_DIR=$(mktemp -d)` + the IU `ANTHROPIC_BASE_URL`/`AUTH_TOKEN`.
Nested: ask the agent to Read `sub/x.txt` first. OpenCode: `opencode debug skill`
lists discovered skills; `opencode run -m <model> '<prompt>'`.
