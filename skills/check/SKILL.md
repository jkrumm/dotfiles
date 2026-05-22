---
name: check
description: Run validation (format, lint, tsc, test) via sideclaw MCP tool
---

# Check — via sideclaw MCP

`mcp__sideclaw__check` is **asynchronous** (runs as a background job on Kimi, off Max):

1. Call `mcp__sideclaw__check` with `cwd` set to the target repo root → returns `{ jobId }`.
2. Call `mcp__sideclaw__job_wait({ jobId })` to block until it finishes (loop while `stillRunning: true`).
3. On `status: "done"`, read `result`: check `passed` first; if false, inspect `steps[n].errors`.

The submit call does **not** return the pass/fail result — always poll `job_wait`.
