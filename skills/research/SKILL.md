---
name: research
description: Deep technical research via the research-gateway MCP — agentic Tavily + Context7 + page-fetch with cross-verification, returns a cited markdown report
---

# Research — via research-gateway MCP

The standalone research-gateway service (Elysia + Bun, native on the Mac mini, Tailscale-only) runs the agentic loop on IU models, off Max. It uses an **async job contract** (mirrors sideclaw's `check`/`review`): submit → wait → read. The submit never blocks; `job_wait` then blocks for the WHOLE job (the server holds the stream open with 15s keep-alives), so one wait call is normally the entire interaction.

1. **Submit.** Call `mcp__research-gateway__research` with `query` set to the user's question, optionally `depth` (`quick` | `standard` | `deep`, default `standard`). It returns IMMEDIATELY with `{ jobId, status }` — **not** the report. Note the `jobId`; do not treat this response as the answer.
2. **Wait.** Call `mcp__research-gateway__job_wait({ jobId })` — once. It blocks until the job actually finishes (quick ~40s, standard ~2min, deep up to ~20min) and returns the terminal state. Only if it comes back with `stillRunning: true` — meaning the wait was cut short, not that the job failed — call it again with the same `jobId`. (`job_status({ jobId })` is a non-blocking peek if you want to do other work meanwhile.)
3. **Read the result.** When `status` is `done`, the `result` field (also `structuredContent`) is a `ResearchReport`:
   - `report` — narrative, cited answer in markdown
   - `citations` — `[{ claim, url, confidence }]`, each key claim tied to a source, carrying the researching worker's `high` | `medium` | `low` confidence in that specific claim
   - `sources` — deduplicated list of all URLs consulted
   - `unverified` — `[{ topic, url, reason }]`, things the run could NOT confirm against a source (unreachable, paywalled, thin). Empty on a clean run.

   **Read `confidence` and `unverified` before passing a claim on.** A citation only means a worker tied that claim to that URL — it is not proof the page supports it. Treat `low` confidence and anything in `unverified` as a lead to check, not a fact; for a crisp value (version number, EOL date, API signature) where the report names a primary source, opening that source directly is a cheap confirmation.

   On `done`, the text content already inlines the report plus a Citations and Sources section, so text-only clients still get the full picture. When `status` is `error`, `error` holds the failure message.

Depth: `quick` = fast, snippet-level; `standard` (default) balances quality and speed; `deep` = most thorough but slowest. Submit is instant at every depth, and one `job_wait` covers any of them — only how long that single call blocks grows with depth, so `deep` is safe to use. If the gateway refuses the submit, `research` returns an `isError` whose text says which of three reasons it was — `queue_full` (backlog), memory pressure (it is shedding new work to protect running jobs), or draining (it is restarting). All three mean retry shortly, not that the query was bad.

**Durable job ids.** A finished job stays readable for 7 days, so a wait cut short (a closed session, a gateway restart) is recovered with `job_wait({ jobId })` or `job_status`, never by resubmitting. Pass `idempotencyKey` on `research` when a submit might be retried; the same key returns the original job.

**When the MCP tools are missing** (the server was unreachable at session start, so Claude Code never loaded them): use the CLI over the REST door instead of giving up: `research "<question>" --depth standard` (`--json` for the full report object, `--no-wait` then `research wait <jobId>`). It needs no session state and retries transport errors itself. On the mini it defaults to the local gateway; elsewhere set `RESEARCH_GATEWAY_URL`. The bearer comes from `RESEARCH_GATEWAY_TOKEN` or the `research-gateway-token` Keychain entry. Exit codes: 0 done, 1 job error, 2 usage/auth/refused, 3 unreachable.
