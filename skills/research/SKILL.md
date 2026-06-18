---
name: research
description: Deep technical research via the research-gateway MCP — agentic Tavily + Context7 + page-fetch with cross-verification, returns a cited markdown report
---

# Research — via research-gateway MCP

`mcp__research-gateway__research` is a **blocking** call. The standalone research-gateway service (Elysia + Bun on the VPS) runs the agentic loop on IU models, off Max, and returns when the report is ready — there is no jobId / job_wait.

1. Call `mcp__research-gateway__research` with `query` set to the user's question, optionally `depth` (`quick` | `standard` | `deep`, default `standard`). The call blocks until the report is done.
2. Read the result. `structuredContent` is a `ResearchReport`:
   - `report` — narrative, cited answer in markdown
   - `citations` — `[{ claim, url }]`, each key claim tied to a source
   - `sources` — deduplicated list of all URLs consulted

   The text content already inlines the report plus a Citations and Sources section, so text-only clients still get the full picture.

Depth: `quick` = fast, snippet-level; `standard` (default) balances quality and speed; `deep` = most thorough but slowest. A `deep` call can approach a client's tool-call timeout, so prefer `standard` unless the question needs the extra depth. If the gateway is at capacity the call returns an error (`isError`) — retry shortly.
