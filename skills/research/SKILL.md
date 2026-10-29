---
name: research
description: Deep technical research via the agw CLI (agent-workflows) — one agent with web search and page fetch, returns a cited markdown report with per-claim confidence
---

# Research — via `agw`

1. Run `agw research "<question>" --depth quick|standard|deep --format json` via Bash (`standard` is the default). Add `--context "<background>"` for what the caller already knows: it is treated as established, never re-searched, never cited. `quick` = one fact, `standard` = a few sources, `deep` = a survey. Ignore `--design` and `--profile`: they are comparison-arm flags, leave them at their defaults.
2. Exit 10 = still running (wait budget `AGW_WAIT_BUDGET_S`, default 110 s). The JSON names the run: run `agw run wait <runId> --format json`, repeat until the exit is not 10. Never wrap it in a short timeout.
3. Exit 0 = the run finished. Read `status` (`done` | `failed` | `cancelled`), then `output`:
   - `report` — narrative, cited answer in markdown
   - `citations` — `[{ claim, url, confidence }]`, each key claim tied to a source, carrying the researching agent's `high` | `medium` | `low` confidence in that specific claim
   - `sources` — deduplicated list of all URLs consulted
   - `unverified` — `[{ topic, url, reason }]`, things the run could NOT confirm against a source (unreachable, paywalled, thin). Empty on a clean run.
   - `status` (`ok` | `partial`), `warnings`, `grounding`

   **Read `confidence` and `unverified` before passing a claim on.** A citation only means the agent tied that claim to that URL — it is not proof the page supports it. Treat `low` confidence and anything in `unverified` as a lead to check, not a fact; for a crisp value (version number, EOL date, API signature) where the report names a primary source, opening that source directly is a cheap confirmation.

   **`output.status` / `warnings` / `grounding`:** `output.status: "partial"` means the run finished with gaps — the `warnings` array says which, and `grounding` is the code-computed check of citations against fetched pages (`citations` vs `grounded`, `pagesRetrieved` vs `pagesFailed`), not the model's opinion. Treat a partial result as leads. When the run `failed`, `error.message` says why.

**Never answer from memory when research fails.** Say it failed (quote the exit code and `error`) and, if the question matters, retry once or look the primary source up directly.

**Follow-up on a finished report:** there is no follow-up flag yet. Ask a new question and pass the report's relevant findings as `--context`, so they are not re-searched.

Exit codes a caller acts on (`agw schema --exit-codes`):

| Code | Meaning | Action |
|-|-|-|
| 0 | run finished | read `status`, then `output.status` |
| 10 | still running | `agw run wait <runId>` |
| 1 | run failed/cancelled, or a 5xx | state is on stdout; report it |
| 2 | bad flag/value | fix the call |
| 3 | no secret, or 401/403 | credentials in `~/.config/agw/env` |
| 7 | host unreachable | report; don't retry-loop |
| 8 | rate limited | retry after `details.retryAfterS` |

A cut-off session recovers with `agw run wait <runId>`, never by resubmitting.
