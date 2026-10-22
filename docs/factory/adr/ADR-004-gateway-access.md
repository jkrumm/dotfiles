# ADR-004 — Gateway access: MCP or CLI per gateway, by job length and definition size; routing generated

- Status: accepted · 2026-10-22
- Evidence: `spikes/04-cli-mcp/REPORT.md` (141 headless sessions, 12 tasks × 3 conditions × N=3; tables regenerate with `scripts/tables.py all`), `research/2026-10-22-agents-durable-mcp-otel.md` §6

## Context and problem statement

The owner asked whether the gateways (agent-gateway, research-gateway, email-gateway, …) should
be reached through MCP servers or through CLIs with a generated AGENTS.md routing block and
skills. No independent benchmark could be verified, so it was measured on our gateways.

## Findings that decide it

| Gateway | Inline MCP standing cost | Deferred MCP | CLI | Long jobs |
|-|-|-|-|-|
| agent-gateway | +17.9k tokens (never inline) | +1.3k; 9/9 pass, structured verdicts | 8/9; without `--json` 5 of 9 review runs reported wrong fields | reviews median 258 s, 85 % over Bash's 120 s foreground cap |
| research-gateway | +2.1k | costs more than it saves for 4 tools | 9/9 | headless CLI polling spiralled (median 6 calls, 95k tokens vs 2 calls, 37k with MCP `job_wait`) unless one policy sentence is added |
| email-gateway | +1.9k | — | needs a CLI that does not exist; a scratch one swallowed an unknown flag (6 calls, 82k tokens) | short |

In the owner's real configuration (deferral at its default) all three MCP servers together cost
about 420 standing tokens — a wash against a 650-token routing block.

## Decision outcome

**A mix, per gateway, decided by job length (against the 120 s shell foreground cap) and
definition size:**
- **agent-gateway:** MCP **deferred** in Claude Code, with a generated one-line hint (load the submit tool and `job_wait` in one search: 4 → 3 calls, −17 % tokens); never inline. The CLI with `--json` for OpenCode, Codex, cron and the sub-2-second verbs (decide, triage).
- **research-gateway:** MCP inline (≈ 2k tokens); the CLI for non-MCP clients, with the long-job policy sentence in the routing block.
- **email-gateway:** MCP inline; no CLI. Add the missing list/count verbs to its shared service layer so MCP covers what REST covers (7 of ≈ 25 routes today).
- **Routing block generated** from each CLI's `--help` by `scripts/render_routing.py` (15 lines, 653 tokens), placed in the manifest-generated AGENTS.md block (ADR-010); `--check` exits 1 on drift and runs in `make check`.
- Every CLI used by agents must reject unknown flags (exit non-zero) and offer `--json`.

### Consequences

- Good: the cheapest door per gateway; long jobs never fall into shell polling; drift in CLI surfaces fails CI.
- Bad: two doors for agent-gateway and research-gateway to keep equivalent; the outcome enum and `scope` values live only in MCP descriptions today and must move into `--help`.

### Confirmation

The spike harness re-runs per gateway release (`scripts/tables.py all`); a CI check that every
agent-facing CLI rejects unknown flags; the routing drift check in `make check`.

Note for every transcript KPI: the spike's sessions created usage-tracker rows ($4.36 of phantom Max
spend); KPI scripts exclude project paths containing `04-cli-mcp`.
