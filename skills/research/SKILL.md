---
name: research
description: Deep technical research via the research-gateway MCP — agentic Tavily + Context7 + page-fetch with cross-verification, returns a cited markdown report
---

# Research — via research-gateway MCP

The standalone research-gateway service (Elysia + Bun on the VPS, Tailscale-only) runs the agentic loop on IU models, off Max. It uses an **async job contract** (mirrors sideclaw's `check`/`review`): submit → wait → read. No single call blocks for the whole run, so long/deep research can't trip the MCP HTTP transport's ~60s first-byte timeout.

1. **Submit.** Call `mcp__research-gateway__research` with `query` set to the user's question, optionally `depth` (`quick` | `standard` | `deep`, default `standard`). It returns IMMEDIATELY with `{ jobId, status }` — **not** the report. Note the `jobId`; do not treat this response as the answer.
2. **Wait.** Call `mcp__research-gateway__job_wait({ jobId })`. It blocks up to ~50s (with progress heartbeats) and returns the job state. If `stillRunning` is `true`, call `job_wait` again with the same `jobId` — loop until `stillRunning` is `false`. (`job_status({ jobId })` is a non-blocking peek if you want to do other work between checks.)
3. **Read the result.** When `status` is `done`, the `result` field (also `structuredContent`) is a `ResearchReport`:
   - `report` — narrative, cited answer in markdown
   - `citations` — `[{ claim, url }]`, each key claim tied to a source
   - `sources` — deduplicated list of all URLs consulted

   On `done`, the text content already inlines the report plus a Citations and Sources section, so text-only clients still get the full picture. When `status` is `error`, `error` holds the failure message.

Depth: `quick` = fast, snippet-level; `standard` (default) balances quality and speed; `deep` = most thorough but slowest. Submit is instant at every depth — only the number of `job_wait` loops grows with depth, so `deep` is now safe to use. If the gateway is at capacity, `research` returns an error (`isError`) — retry shortly.
