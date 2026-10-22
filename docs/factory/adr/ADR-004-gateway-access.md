# ADR-004 — CLI-first: every tool is a CLI on one agent contract; MCP only where a non-shell client needs it

- Status: accepted · 2026-10-22 (revised the same day: owner decision — "move away from MCP"; the first version chose a mix per gateway; revised again after panel pass 1: dx-3…dx-6, dx-8, dur-8, sim-1; after pass 2: dx-1, dx-4…dx-8, sim-2, mig-5)
- Evidence: `spikes/04-cli-mcp/REPORT.md` (141 headless sessions on our gateways), `spikes/04-cli-mcp/raw/agw-job-durations.json` (review and check durations, p50 and p90), `research/2026-10-22-ts-cli-introspection.md`, `research/2026-10-22-agents-durable-mcp-otel.md` §6, `evidence/toil/toil.md` (C18: BSD-vs-GNU failures), the owner's prompt ("great CLIs and super concise routing … AGENTS.md built dynamically from those CLIs")

## Context and problem statement

Agents reach the gateways (agent-gateway, research-, email-, audio-, image-gateway) and the
factory's own tools through MCP servers today. The owner decided to move away from MCP: CLIs plus
skills, with routing generated from the tools themselves. What does the contract look like, and
what remains on MCP?

## What spike 4 measured (and why it supports the owner's call)

- The CLI condition's one systematic failure was the **long-job polling spiral** in headless sessions (median 6 calls, 95k tokens for a ~2-minute research job; two of three runs hit Bash's 120 s foreground cap). **One policy sentence fixed it: 2 calls, 38.9k tokens** — on par with MCP's `job_wait`. A sentence is prose enforcement, and the jobs agents wait on already exceed the cap — review median 258 s, p90 595 s; check median 372 s, p90 517 s (`raw/agw-job-durations.json`) — so the decision moves the behaviour into the CLI (contract item 6).
- `agw review` without `--json` paraphrased its verdict (5 of 9 runs wrong); with `--json`, 0 of 3 — machine output must be the default for agents, not an option they remember.
- An unknown flag swallowed as a search term cost 6 calls and 82k tokens: CLIs must reject unknown flags.
- Standing cost in the owner's real configuration was a wash (≈ 420 tokens for three servers vs a 653-token generated routing block).

## Decision outcome

**CLI-first.** Every gateway and factory tool is a CLI on one agent contract; skills call the CLIs.
**One factory CLI:** `factory` and `rv` fold into `warden` as modules (`warden manifest …`,
`warden project …`, `warden artifact …`; process model in ADR-011 §5; sim-1).

**Contract scope comes from manifests** (dx-7). A repo's `project.yaml` declares what it puts on
PATH: `spec.provides.clis[{name, contract: agent | passthrough}]` (ADR-010). The conformance suite
enumerates the declared set and fails on any `~/.local/bin` entry symlinked from a SourceRoot repo
that no manifest declares, so nothing is opted in by memory and third-party binaries (`claude`,
`opencode`, …) never enter the scope. An **agent-facing CLI** is a binary declared
`contract: agent`; the concept-budget check counts that set (`design/proof.md` §6, sim-2). A
`passthrough` binary is a drop-in shim whose CLI shape belongs to someone else — `secrets-run`
shadows `op`, `hl` fronts rclone, `git-credential-secrets-cache` speaks git's credential protocol —
and the suite tests its compatibility with that tool, not format or envelope. Join order: `rd` in
W4a, the cutover that rewrites it; the gateway CLIs (agw, email, audio, image), `ask-human`,
`jobrun`, `imgcli` and the research CLI in W8, with the passthrough shims.

**MCP stays only for research-gateway** (Claude Desktop and similar non-shell clients) **and
chrome-devtools** until a browser CLI replaces it. agent-gateway's MCP server is unregistered at the
W8 cutover and stays on disk until W12 closes (mig-5); the deferred-tool path is retired with it.

**The agent-CLI contract** (restated from the owner's settled prior art in another workspace):
1. `--format json|jsonl|tsv|plain` — `tsv` default for flat tables, `json` for nested results; no `-o` alias for it. `--fields` projects, `--limit` defaults to 50.
2. Lists come in one envelope: `{items, meta: {count, truncated, next_cursor}}`; nothing is truncated silently. `--out <path>` spills the full result and returns `{path, bytes, rows, sha256}` with a preview of at most 20 rows; oversized results spill automatically.
3. Errors: the last stderr line is one JSON object `{"error": {"kind", "message", "hint", "retryable", "details"}}`. Exit codes: 0 ok, 1 general, 2 usage, then domain codes from 3 in a fixed order (auth, not_found, conflict, confirmation_required, network, rate_limited, contract_mismatch, …); the table lives in code, is rendered into the docs, and changing it is a breaking change.
4. Read-only by default. Mutating commands take `--commit` (dry-run otherwise) and never prompt: a non-TTY session gets `confirmation_required`. Agents pass `--commit` explicitly — a guard against accidental writes, not an owner gate. `--idempotency-key` is required on every mutating command an agent calls; the server keeps `(verb, subject, key)` unique and returns the original result on a repeat, so a retry after a client-side timeout never creates a second Task or a second steer. Hermes derives the key from the message id; Argo mints one per rendered form (ADR-015).
5. `schema [cmd]` prints JSON Schema for inputs and outputs, offline, without secrets.
6. Long jobs: `--wait` is the default and blocks until a budget read from an env var the harness sets (the session hook for Claude Code, the OpenCode plugin, a cron default), then exits with the domain code `pending`; its stderr JSON carries the exact resume command, and the resume blocks for a full budget again, so a job of up to twice the budget finishes in two calls. The agent decides nothing about caps or session type, and the routing block carries no long-job policy sentence. **Budget values** (dx-4, dx-6): each harness sets the budget just below its own foreground cap, and a job of duration d takes ⌈d ÷ budget⌉ calls. Claude Code's default cap is 120 s: a median review (258 s) takes 3 calls and a median check (372 s) 4. The settings template therefore raises Claude Code's Bash default and maximum timeouts (exact env names verified through `/research` at implementation), and the session hook exports the budget just below the raised default. Two calls at the p90 of review (595 s) and check (517 s) need a budget of at least 298 s (595 ÷ 2, rounded up; `raw/agw-job-durations.json`).
7. Text from remote systems is labelled as data and never interpolated into a follow-up command.
8. Unknown flags are usage errors (exit 2).
9. Contract handshake (dx-5): every request carries the contract sha — the sha of the contract snapshot the CLI was generated from (the IR below). A server on a different contract answers with the domain error `contract_mismatch`: `details` name both shas and `hint` is the exact reinstall command. `schema` stays offline, so the mismatch surfaces on the first real call as a typed error, not as a generic 400 or a silently ignored field.

**Commands defined once, in code.** Help, `REFERENCE.md`, each skill's `references/cli.md` and the
tool routing are generated from the command definitions; flags are never typed by hand.
- **One IR:** `<cli> schema --all --format json` is the cross-language intermediate representation, committed and CI-checked in each CLI's own repo. dotfiles renders only from those snapshots, by repo@sha, and stamps the source shas into each generated header; drift is a stamp mismatch, caught by `make check`. Nothing parses help text.
- **Where routing lands:** tool routing renders **once**, into a global generated rules file (a Claude Code rule plus the same file in OpenCode's `instructions`). The per-repo AGENTS.md block (ADR-010) holds only manifest facts, so a flag change in one CLI touches that CLI's repo and one global file, not every repo.
- **Flags in prose are linted** (dx-8). Skills and AGENTS.md files name flags too — 14, 11, 5 and 3 distinct `--flag` mentions in the remote-dev, prose, wave and otel skills today (`panel/pass1/dx.json` dx-8). The doc-contradiction lint (`design/proof.md` §6) fails any `--flag` in a SKILL.md or AGENTS.md that the named CLI's schema snapshot lacks, so prose cannot outlive a renamed flag.
- **Shell syntax is outside the contract.** 530 calls failed on BSD-vs-GNU syntax and unquoted globs in 30 days (360 sessions, 1.65 agent hours: `evidence/toil/toil.md` C18). The fix is C18's PreToolUse rewrite, not GNU tools first on PATH — dotfiles' own Makefile calls BSD `sed -i ''`. W12 re-runs the toil script; the pass-1 panel's bar is under 50 per 30 days (`panel/pass1/dx.json` dx-8).

**Stack.**
- Python tool (warden, which now carries the manifest and artifact subcommands): **cyclopts + pydantic v2** (the owner's choice; the `App` is the introspection surface, the docs generator and — via pydantic — the JSON Schema source). Versions pinned after `/research` confirms them at implementation time.
- Bun/TS gateways: **the command table is generated from the HTTP contract** — the Elysia route schemas (Zod or TypeBox) exported to JSON Schema — not from the MCP tools W8 deletes: one small in-house runner turns `{route, description, input schema, output schema}` entries into the contract above. W8's entry gate: every route the CLI exposes has an input and an output schema (a gateway without a schema layer gets one first). Rejected: bunli 0.9.1 (the only Zod-integrated framework, but 0.x with thin adoption), clipanion (stale RC, untyped introspection), `effect/cli` (flag metadata not public, module unstable), commander/yargs/oclif (no schema integration; types must be re-declared) — `research/2026-10-22-ts-cli-introspection.md`.
- **One conformance suite** (black-box, language-neutral, in dotfiles) enumerates the manifest-declared set and runs against each `agent` binary: formats, envelope, error JSON and exit codes, `schema`, unknown-flag rejection, `--commit` semantics in a non-TTY, `--idempotency-key` replay, `contract_mismatch` (a CLI built from another contract sha is refused with the typed error), long-job behaviour (a short budget on a longer job exits `pending`; the resume completes; each harness's budget sits below the cap read from its live config), docs drift. `passthrough` binaries run the compatibility checks of the tool they shadow.

### Consequences

- Good: one contract for every tool and every engine (Claude Code, OpenCode, cron); routing that cannot drift from the code, rendered once; one factory CLI instead of three; no tool definitions resident in context; a scope that follows from manifests — an installed binary is declared or the suite fails.
- Bad: CLIs for agw, email, audio and image to build (W8), plus schema layers where routes lack them; the TS runner is ours to maintain; each harness must export the wait budget and the settings template must raise Claude Code's Bash timeouts; every repo-installed binary needs a manifest declaration; research-gateway keeps two doors (CLI and MCP) and must keep them equivalent.

### Confirmation

The conformance suite green on every declared binary and red on an undeclared `~/.local/bin`
entry; the routing and docs drift checks (schema-snapshot stamps) and the SKILL.md / AGENTS.md flag
lint in `make check`; renaming one flag changes that CLI's repo and one global file only; a gateway
deployed from another contract sha than the installed CLI answers `contract_mismatch`; **W8's
gate:** spike 4's harness re-run after W8 on the CLI-only configuration (tokens, calls to success,
the long-job probe **without** the policy sentence at the measured p50 and p90 durations, in
headless Claude Code with the raised timeouts, OpenCode and cron — ≤ 2 calls each, spike 4's
fixed-probe result); MCP registration audited to research-gateway and chrome-devtools only; W12's
toil re-run for the BSD-vs-GNU count.
