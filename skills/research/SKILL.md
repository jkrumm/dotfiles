---
name: research
description: Deep technical research via the agw CLI (agent-workflows) — one agent with web search and page fetch, returns a cited markdown report with per-claim confidence
---

# Research — via `agw`

1. Run `agw research "<question>" --depth quick|standard|deep --format json` via Bash (`standard` is the default). Add `--context "<background>"` for what the caller already knows: it is treated as established, never re-searched, never cited. `quick` = one fact, `standard` = a few sources, `deep` = a survey.
2. Set the wait budget to fit the depth: `AGW_WAIT_BUDGET_S=300 agw research …` for `standard`, up to 540 for `deep` (default 110 s; stay under the Bash tool's 600 s foreground limit). Exit 10 = still running: resume once with `agw run wait <runId> --format json`, never in a loop; if it is still pending, run the wait in the background and end the turn. Never pipe agw into `head`/`tail` (the pipe hides the exit code and cuts the error envelope).
3. Exit 0 = the run finished. Read `status` (`done` | `failed` | `cancelled`), then `output`:
   - `report` — narrative, cited answer in markdown
   - `citations` — `[{ claim, url, confidence }]`, each key claim tied to a source, carrying the researching agent's `high` | `medium` | `low` confidence in that specific claim
   - `sources` — deduplicated list of all URLs consulted
   - `unverified` — `[{ topic, url, reason }]`, things the run could NOT confirm against a source (unreachable, paywalled, thin). Empty on a clean run.
   - `status` (`ok` | `partial`), `warnings`, `grounding`

   **Read `confidence` and `unverified` before passing a claim on.** A citation only means the agent tied that claim to that URL — it is not proof the page supports it. Treat `low` confidence and anything in `unverified` as a lead to check, not a fact; for a crisp value (version number, EOL date, API signature) where the report names a primary source, opening that source directly is a cheap confirmation.

   **`output.status` / `warnings` / `grounding`:** `output.status: "partial"` means the run finished with gaps — the `warnings` array says which, and `grounding` is the code-computed check of citations against fetched pages (`citations` vs `grounded`, `pagesRetrieved` vs `pagesFailed`), not the model's opinion. Treat a partial result as leads. When the run `failed`, `error.message` says why.

**Never answer from memory when research fails.** Say it failed (quote the exit code and `error`) and, if the question matters, retry once or look the primary source up directly.

**Follow-up on a finished report:** `agw research "<new question>" --follow-up <runId>`, with the `runId` of a `done` research run. The earlier question, report and citations become the agent's context; the answer has the same shape. `--context` stays for background the caller brings itself.

Exit codes: `agw schema --exit-codes`.

A cut-off session recovers with `agw run wait <runId>`, never by resubmitting.
