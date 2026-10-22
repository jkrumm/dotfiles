# ADR-004 — CLI-first: every tool is a CLI on one agent contract; MCP only where a non-shell client needs it

- Status: accepted · 2026-10-22 (revised the same day: owner decision — "move away from MCP"; the first version chose a mix per gateway; revised again after panel pass 1: dx-3…dx-6, dx-8, dur-8, sim-1)
- Evidence: `spikes/04-cli-mcp/REPORT.md` (141 headless sessions on our gateways), `research/2026-10-22-ts-cli-introspection.md`, `research/2026-10-22-agents-durable-mcp-otel.md` §6, the owner's prompt ("great CLIs and super concise routing … AGENTS.md built dynamically from those CLIs")

## Context and problem statement

Agents reach the gateways (agent-gateway, research-, email-, audio-, image-gateway) and the
factory's own tools through MCP servers today. The owner decided to move away from MCP: CLIs plus
skills, with routing generated from the tools themselves. What does the contract look like, and
what remains on MCP?

## What spike 4 measured (and why it supports the owner's call)

- The CLI condition's one systematic failure was the **long-job polling spiral** in headless sessions (median 6 calls, 95k tokens for a ~2-minute research job). **One policy sentence fixed it: 2 calls, 38.9k tokens** — on par with MCP's `job_wait`. A sentence is prose enforcement, and reviews (median 258 s) and checks (median 372 s) already exceed the foreground cap, so the decision moves the behaviour into the CLI (contract item 6).
- `agw review` without `--json` paraphrased its verdict (5 of 9 runs wrong); with `--json`, 0 of 3 — machine output must be the default for agents, not an option they remember.
- An unknown flag swallowed as a search term cost 6 calls and 82k tokens: CLIs must reject unknown flags.
- Standing cost in the owner's real configuration was a wash (≈ 420 tokens for three servers vs a 653-token generated routing block).

## Decision outcome

**CLI-first.** Every gateway and factory tool is a CLI on one agent contract; skills call the CLIs.
**One factory CLI:** `factory` and `rv` fold into warden as subcommands (`warden manifest …`,
`warden project …`, `warden artifact …`) — one binary, one store, the loops as phases of one warden
process (sim-1). **Contract scope** is every factory binary on PATH (`~/.local/bin`) plus the
gateway CLIs (agw, email, audio, image); the conformance suite enumerates them, so nothing is opted
in by memory. `rd` joins in W4 (the cutover that rewrites it); `hl`, `secrets-run`, `ask-human`,
`jobrun`, `imgcli` and the research CLI join in W8. **MCP stays only for research-gateway** (Claude Desktop and
similar non-shell clients) **and chrome-devtools** until a browser CLI replaces it. agent-gateway's
MCP server and the deferred-tool path are retired (W8).

**The agent-CLI contract** (restated from the owner's settled prior art in another workspace):
1. `--format json|jsonl|tsv|plain` — `tsv` default for flat tables, `json` for nested results; no `-o` alias for it. `--fields` projects, `--limit` defaults to 50.
2. Lists come in one envelope: `{items, meta: {count, truncated, next_cursor}}`; nothing is truncated silently. `--out <path>` spills the full result and returns `{path, bytes, rows, sha256}` with a preview of at most 20 rows; oversized results spill automatically.
3. Errors: the last stderr line is one JSON object `{"error": {"kind", "message", "hint", "retryable", "details"}}`. Exit codes: 0 ok, 1 general, 2 usage, then domain codes from 3 in a fixed order (auth, not_found, conflict, confirmation_required, network, rate_limited, …); the table lives in code, is rendered into the docs, and changing it is a breaking change.
4. Read-only by default. Mutating commands take `--commit` (dry-run otherwise) and never prompt: a non-TTY session gets `confirmation_required`. Agents pass `--commit` explicitly — a guard against accidental writes, not an owner gate. `--idempotency-key` is required on every mutating command an agent calls; the server keeps `(verb, subject, key)` unique and returns the original result on a repeat, so a retry after a client-side timeout never creates a second Task or a second steer. Hermes derives the key from the message id; Argo mints one per rendered form (ADR-015).
5. `schema [cmd]` prints JSON Schema for inputs and outputs, offline, without secrets.
6. Long jobs: `--wait` is the default and blocks until a budget read from an env var the harness sets (the session hook for Claude Code, the OpenCode plugin, a cron default), then exits with the domain code `pending`; its stderr JSON carries the exact resume command. The agent decides nothing about caps or session type, and the routing block carries no long-job policy sentence.
7. Text from remote systems is labelled as data and never interpolated into a follow-up command.
8. Unknown flags are usage errors (exit 2).

**Commands defined once, in code.** Help, `REFERENCE.md`, each skill's `references/cli.md` and the
tool routing are generated from the command definitions; flags are never typed by hand.
- **One IR:** `<cli> schema --all --format json` is the cross-language intermediate representation, committed and CI-checked in each CLI's own repo. dotfiles renders only from those snapshots, by repo@sha, and stamps the source shas into each generated header; drift is a stamp mismatch, caught by `make check`. Nothing parses help text.
- **Where routing lands:** tool routing renders **once**, into a global generated rules file (a Claude Code rule plus the same file in OpenCode's `instructions`). The per-repo AGENTS.md block (ADR-010) holds only manifest facts, so a flag change in one CLI touches that CLI's repo and one global file, not every repo.

**Stack.**
- Python tool (warden, which now carries the manifest and artifact subcommands): **cyclopts + pydantic v2** (the owner's choice; the `App` is the introspection surface, the docs generator and — via pydantic — the JSON Schema source). Versions pinned after `/research` confirms them at implementation time.
- Bun/TS gateways: **the command table is generated from the HTTP contract** — the Elysia route schemas (Zod or TypeBox) exported to JSON Schema — not from the MCP tools W8 deletes: one small in-house runner turns `{route, description, input schema, output schema}` entries into the contract above. W8's entry gate: every route the CLI exposes has an input and an output schema (a gateway without a schema layer gets one first). Rejected: bunli 0.9.1 (the only Zod-integrated framework, but 0.x with thin adoption), clipanion (stale RC, untyped introspection), `effect/cli` (flag metadata not public, module unstable), commander/yargs/oclif (no schema integration; types must be re-declared) — `research/2026-10-22-ts-cli-introspection.md`.
- **One conformance suite** (black-box, language-neutral, in dotfiles) enumerates every binary in scope and runs against each: formats, envelope, error JSON and exit codes, `schema`, unknown-flag rejection, `--commit` semantics in a non-TTY, `--idempotency-key` replay, long-job behaviour (a short budget on a longer job exits `pending`; the resume completes), docs drift.

### Consequences

- Good: one contract for every tool and every engine (Claude Code, OpenCode, cron); routing that cannot drift from the code, rendered once; one factory CLI instead of three; no tool definitions resident in context.
- Bad: CLIs for agw, email, audio and image to build (W8), plus schema layers where routes lack them; the TS runner is ours to maintain; each harness must export the wait budget; research-gateway keeps two doors (CLI and MCP) and must keep them equivalent.

### Confirmation

The conformance suite green on every binary it enumerates; the routing and docs drift checks
(schema-snapshot stamps) in `make check`; renaming one flag changes that CLI's repo and one global
file only; spike 4's harness re-run after W8 on the CLI-only configuration (tokens, calls to
success, the long-job probe **without** the policy sentence, in headless Claude Code, OpenCode and
cron — ≤ 2 calls each, spike 4's fixed-probe result); MCP registration audited to research-gateway
and chrome-devtools only.
