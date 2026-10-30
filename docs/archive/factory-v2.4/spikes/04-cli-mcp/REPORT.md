# Spike 4 — CLI vs MCP, measured on our gateways

- Status: result, input to ADR-004. Date 2026-10-22. 141 headless sessions, 132 passed. The spike agent could not write this file (subagent report writes are refused); this is its final report, saved verbatim by the orchestrator.

Spike 4 ran in full (141 sessions, 132 passed), but `REPORT.md` was not written. The harness blocked my Write call, since subagents may not write report files, and I did not work around it. This message is the report. Every table regenerates with `python3 scripts/tables.py all`.

Everything is in `~/SourceRoot/dotfiles/docs/factory/spikes/04-cli-mcp/`: `scripts/`, `raw/` (`runs.jsonl`, `summary.json`, `turn1.json`, inventories, `drift-demo.txt`) and `routing-block.md`. The redaction check passes. Scratch, with the full transcripts, is `~/.local/share/factory/spikes/04-cli-mcp/`.

**Setup.** Headless sessions on the IU Claude tier (Sonnet class), on Claude Code 2.1.308, with every flag checked against `claude --help`. Each session loads exactly one MCP server or none. I rejected `--bare` because it trims MCP descriptions and halves the apparent agent-gateway cost.

There were 12 tasks × 3 conditions × N=3: three core tasks per gateway, a capability probe, and two long-job probes. All three gateways have an MCP door. Only agent-gateway and research-gateway already had a CLI; for email-gateway I wrote a 50-line scratch CLI `mailgw` over its REST API.

**Standing cost (first-turn tokens, marginal).**
- Inline MCP: agent-gateway +17.9k, research +2.06k, email +1.90k.
- Deferred MCP, lab: +1.3k, +1.14k, +1.19k. About 1.1k of that is the ToolSearch tool itself.
- CLI: the generated routing block is +650 for all three gateways. The Bash tool definition (+4.8k) is already in every real session.
- Your real config (all built-ins, deferral at its default): MCP costs +260, +57 and +105. That is about 420 tokens in total, so standing cost is a wash against the block.

**Medians per gateway × condition (n=9 each).**
Total input is summed over all API calls. The parenthesised figure removes the Bash and ToolSearch definitions that real sessions already carry. Wall time excludes agent-gateway queue wait.

| Gateway | Condition | Passed | Turn-1 | Total input | Tool calls | Wall s |
|-|-|-|-|-|-|-|
| agent-gateway | CLI | 8/9 | 10.9k | 22.7k (13.1k) | 1 | 11.8 |
| agent-gateway | MCP inline | 9/9 | 23.4k | 71.8k | 2 | 12.2 |
| agent-gateway | MCP deferred | 9/9 | 6.8k | 42.9k (37.5k) | 4 | 19.3 |
| research | CLI | 9/9 | 10.5k | 23.7k (14.1k) | 1 | 32.0 |
| research | MCP inline | 9/9 | 7.1k | 24.7k | 2 | 31.1 |
| research | MCP deferred | 9/9 | 6.2k | 38.6k (33.2k) | 4 | 33.0 |
| email | CLI (scratch) | 9/9 | 10.4k | 23.3k (13.7k) | 1 | 9.3 |
| email | MCP inline | 9/9 | 6.9k | 16.1k | 1 | 8.1 |
| email | MCP deferred | 9/9 | 6.2k | 21.7k (18.4k) | 2 | 13.0 |

A one-line hint ("load the submit tool and `job_wait` in one ToolSearch call") takes deferred from 4 to 3 calls and cuts tokens 17–18%.

**Probes (N=3 each).**
- **Long jobs, research standard (~2 min).**
  - MCP: 2 calls, 3/3 passed.
  - CLI: median 6 calls (range 1–15) and 95k tokens, against 37k for MCP. Two of three runs hit Bash's 120 s foreground cap. In headless `-p` there is no background-task notification, so they spiralled into polling.
  - One added policy sentence fixes it. With a no-wait sentence the CLI took 2 calls and 38.9k tokens. With a foreground-timeout sentence it took 2 calls and 43.0k.
- **Real agent-gateway job durations** (frozen snapshot, `scripts/job_durations.py`):
  - Reviews: median 258 s, 85% over 120 s (n=1,163).
  - Checks: median 372 s (n=38).
  - Dispatch: p90 921 s.
  - Decide and triage: 2 s or less.
  - My 2 s lab check is the best case for the CLI.
- **CLI output loses the verdict.**
  - `agw review` without `--json` paraphrases the result ("approved" instead of `clean`). Without `--json`, 5 of 9 CLI review runs gave wrong fields; with `--json`, 0 of 3.
  - Across all conditions, MCP review runs were wrong in 0 of 15.
  - The `scope` values and the outcome enum appear only in the MCP descriptions, not in `--help`.
- **Capability gap (email unread count).**
  - Neither a calendar nor an unread count exists in email-gateway. I substituted needs-action, find-invoice and read-invoice tasks, plus this unread probe.
  - CLI over REST passed 3/3 (61k tokens). MCP passed 1/3, inline and deferred alike; the other runs honestly abstained.
  - MCP exposes 7 of about 25 REST routes.
- **Unknown-flag hazard.** `mailgw` swallowed an unknown `--json` flag as a search term. That took 6 calls and 82k tokens, against 1 call and 21k when fixed. The block itself had suggested `--json`.

**Recommendation per gateway.**
- **agent-gateway (medium-high).** In Claude Code, use MCP deferred plus the generated hint: results are structured and `job_wait` is the only reliable long wait. Never load it inline. Use the CLI with `--json` for OpenCode, Codex, cron and the short verbs.
- **research-gateway (medium).** Keep MCP inline, since deferral costs more than it saves for 4 tools. Keep the CLI for non-MCP clients, with the long-job policy sentence in the block.
- **email-gateway (medium-low, fixture only).** Keep MCP inline: 1 call, cheapest. Don't build a CLI. Add list/count verbs to the shared service layer so MCP matches REST.
- **ADR outcome.** A mix, decided per gateway by job length against the 120 s shell cap and by definition size.

**Routing block.** `scripts/render_routing.py`, configured by `scripts/routing.config.json`, renders 15 lines (653 tokens) for the three CLIs. It parses each CLI's `--help` Usage section; the config adds an expose list and one policy sentence. It fails if the block exceeds 15 lines or an exposed command disappears.

`--check FILE` re-renders and diffs: exit 0 in sync, 1 on drift (unified diff), 2 if it cannot render or the block is missing. `raw/drift-demo.txt` shows a simulated flag rename.

**Caveats.**
- **Usage-tracker side effect.** I forgot `--no-session-persistence`, so Claude Code wrote my sessions under `~/.claude/projects`. usage-tracker ingested 1,070 rows from them: 551 booked as `max` ($4.36 of phantom Max spend) and 519 as `iu`. I did not touch `usage.db`; KPI scripts should exclude project paths containing `04-cli-mcp`. I then deleted my 143 session directories, and the harness now passes the flag.
- **Agent-gateway queue.** My parallel reviews saturated the agent-gateway job queue (3 sessions at once) for about 25 minutes. Other jobs waited up to about 65 s.
- **Scope of the evidence.**
  - One model, N=3, and a lab config with hooks, skills and CLAUDE.md off.
  - Interactive sessions get background-task notifications, so the long-job CLI failure is a headless-`-p` finding.
  - OpenCode and Codex deferral support is unmeasured.
  - Email ran on a scratch instance of the same code, because the production bearer is not on the mini.
- **Wall times and cost.** Wall times are indicative: up to 8 concurrent sessions, agent-gateway queue waits subtracted. Cost is Claude Code's own estimate, about $4.17 in total.
