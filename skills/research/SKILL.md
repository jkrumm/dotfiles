---
name: research
description: Deep technical research via sideclaw MCP tool — Context7, WebSearch, WebFetch with cross-verification and quota-aware routing
---

# Research — via sideclaw MCP

`mcp__sideclaw__research` is **asynchronous** (runs as a background job on Kimi, off Max):

1. Call `mcp__sideclaw__research` with `query` set to the user's question. Optionally pass `cwd` (defaults to $HOME) and `depth` (`quick` | `standard` | `deep`, default `standard`) → returns `{ jobId }`.
2. Call `mcp__sideclaw__job_wait({ jobId })` to block until it finishes (loop while `stillRunning: true`).
3. On `status: "done"`, read `result`: `summary`, `findings`, `recommendation`, `confidence`, `sources`. Inspect `confidence` first.

Heavy fetch content stays in the worker — only the structured findings come back. The submit call does **not** return the findings; always poll `job_wait`.
