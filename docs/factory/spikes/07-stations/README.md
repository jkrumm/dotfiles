# Spike 7 — stations, one CLI, one capability layer (2026-10-26)

Proofs of concept for `design/gateways.md` before anything changes in the TDD. Each folder is
owned by one worker and ends in a `REPORT.md` (question, setup, numbers, verdict, caveats).

| Folder | Question |
|-|-|
| `capability/` | Can one typed function (`summarize`, called by route key) be exposed as import + HTTP + CLI from a single definition? In-house `defineCapability` vs Mastra `createTool`, on Node and Bun. |
| `cli-runner/` | Can one generic runner turn a gateway's OpenAPI document into an ADR-004-conformant CLI, so a long job finishes in ≤ 2 agent calls? Proven on research-gateway. |
| `station-host/` | Can a thin host run station packages on ONE private OpenCode 2.0.32 server with typed output, budget, cost and a span per session? |
| `research-ab/` | Engine vs pure-OpenCode research vs station-on-engine on the golden questions (wave 2, after the two above). |

Prior evidence: `../../research/2026-10-26-opencode-v2-locations-spike.md` (one server, isolated
locations), `../04-cli-mcp/REPORT.md` (CLI vs MCP calls/tokens), `../06-telemetry/REPORT.md`.
