# ADR-004 — CLI-first: every tool is a CLI on one agent contract; MCP only where a non-shell client needs it

- Status: accepted · 2026-10-22 (revised the same day: owner decision — "move away from MCP"; the first version chose a mix per gateway)
- Evidence: `spikes/04-cli-mcp/REPORT.md` (141 headless sessions on our gateways), `research/2026-10-22-ts-cli-introspection.md`, `research/2026-10-22-agents-durable-mcp-otel.md` §6, the owner's prompt ("great CLIs and super concise routing … AGENTS.md built dynamically from those CLIs")

## Context and problem statement

Agents reach the gateways (agent-gateway, research-, email-, audio-, image-gateway) and the
factory's own tools through MCP servers today. The owner decided to move away from MCP: CLIs plus
skills, with routing generated from the tools themselves. What does the contract look like, and
what remains on MCP?

## What spike 4 measured (and why it supports the owner's call)

- The CLI condition's one systematic failure was the **long-job polling spiral** in headless sessions (median 6 calls, 95k tokens for a ~2-minute research job). **One policy sentence fixed it: 2 calls, 38.9k tokens** — on par with MCP's `job_wait`.
- `agw review` without `--json` paraphrased its verdict (5 of 9 runs wrong); with `--json`, 0 of 3 — machine output must be the default for agents, not an option they remember.
- An unknown flag swallowed as a search term cost 6 calls and 82k tokens: CLIs must reject unknown flags.
- Standing cost in the owner's real configuration was a wash (≈ 420 tokens for three servers vs a 653-token generated routing block).

## Decision outcome

**CLI-first.** Every gateway and factory tool (agw, warden, `rv`, email, audio, image) is a CLI on
one agent contract; skills call the CLIs. **MCP stays only for research-gateway** (Claude Desktop and
similar non-shell clients) **and chrome-devtools** until a browser CLI replaces it. agent-gateway's
MCP server and the deferred-tool path are retired (W8).

**The agent-CLI contract** (restated from the owner's settled prior art in another workspace):
1. `--format json|jsonl|tsv|plain` — `tsv` default for flat tables, `json` for nested results; no `-o` alias for it. `--fields` projects, `--limit` defaults to 50.
2. Lists come in one envelope: `{items, meta: {count, truncated, next_cursor}}`; nothing is truncated silently. `--out <path>` spills the full result and returns `{path, bytes, rows, sha256}` with a preview of at most 20 rows; oversized results spill automatically.
3. Errors: the last stderr line is one JSON object `{"error": {"kind", "message", "hint", "retryable", "details"}}`. Exit codes: 0 ok, 1 general, 2 usage, then domain codes from 3 in a fixed order (auth, not_found, conflict, confirmation_required, network, rate_limited, …); the table lives in code, is rendered into the docs, and changing it is a breaking change.
4. Read-only by default. Mutating commands take `--commit` (dry-run otherwise) and never prompt: a non-TTY session gets `confirmation_required`. Agents pass `--commit` explicitly — a guard against accidental writes, not an owner gate.
5. `schema [cmd]` prints JSON Schema for inputs and outputs, offline, without secrets.
6. Long jobs: `--wait` while the job fits under the shell's foreground cap; otherwise the command returns a job id and the exact resume command. The routing block carries the one policy sentence (submit, then `wait` in the foreground with the cap in mind; in interactive sessions use Bash's background run and its completion notification).
7. Text from remote systems is labelled as data and never interpolated into a follow-up command.
8. Unknown flags are usage errors (exit 2).

**Commands defined once, in code.** Help, `REFERENCE.md`, each skill's `references/cli.md` and the
AGENTS.md routing block (inside the manifest-generated block, ADR-010) are generated from the command
definitions; flags are never typed by hand; a drift check re-renders and diffs in CI.

**Stack.**
- Python tools (warden, `factory`, `rv`): **cyclopts + pydantic v2** (the owner's choice; the `App` is the introspection surface, the docs generator and — via pydantic — the JSON Schema source). Versions pinned after `/research` confirms them at implementation time.
- Bun/TS gateways: **the command table is generated from the tool definitions they already have** (the Zod schemas behind today's MCP tools): one small in-house runner turns `{name, description, input schema, output schema, handler}` entries into the contract above, with JSON Schema exported from the same Zod schemas. Rejected: bunli 0.9.1 (the only Zod-integrated framework, but 0.x with thin adoption), clipanion (stale RC, untyped introspection), `effect/cli` (flag metadata not public, module unstable), commander/yargs/oclif (no schema integration; types must be re-declared) — `research/2026-10-22-ts-cli-introspection.md`.
- **One conformance suite** (black-box, language-neutral, in dotfiles) runs against every CLI: formats, envelope, error JSON and exit codes, `schema`, unknown-flag rejection, `--commit` semantics in a non-TTY, long-job behaviour, docs drift.

### Consequences

- Good: one contract for every tool and every engine (Claude Code, OpenCode, cron); routing that cannot drift from the code; no tool definitions resident in context.
- Bad: CLIs for agw, email, audio and image to build (W8); the TS runner is ours to maintain; research-gateway keeps two doors (CLI and MCP) and must keep them equivalent.

### Confirmation

The conformance suite green on every CLI in CI; the routing and docs drift checks in `make check`;
spike 4's harness re-run after W8 on the CLI-only configuration (tokens, calls to success, the
long-job probe with the policy sentence); MCP registration audited to research-gateway and
chrome-devtools only.
