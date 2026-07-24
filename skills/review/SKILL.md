---
name: review
description: Multi-angle code review via sideclaw MCP tool (claude-sonnet-5, currently on Max per SIDECLAW_WORKER_BACKEND=max; IU unified endpoint fallback when unset). Add --deep to also run Anthropic's native correctness + security review, also on Max.
---

# Review

## Default (currently on Max) — sideclaw multi-angle

`mcp__sideclaw__review` is **asynchronous** (background job on claude-sonnet-5, currently on Max per `SIDECLAW_WORKER_BACKEND=max`; falls back to the IU unified endpoint when unset):
1. Call `mcp__sideclaw__review` with `cwd` set to the repo root → returns `{ jobId }`. Parse args for `scope` (default `uncommitted`): e.g. `head` (last commit only), `HEAD~3` (a bare ref = the range up to HEAD, i.e. the **last 3 commits** — not the single commit), `main..HEAD` (explicit range), `path/to/file.ts`. Strip any leading flags (like `--deep`) before extracting the scope.
2. Call `mcp__sideclaw__job_wait({ jobId })` to block until it finishes (loop while `stillRunning: true`); read `result` on `status: "done"`. The submit call does **not** return the findings.

This runs the deterministic floor (architect, senior-dev, and file-type angles)
plus a triage router that adds content-driven angles — security, performance,
concurrency, data-migration, api-contract — when the diff warrants them. All on
claude-sonnet-5, **currently on Max** per `SIDECLAW_WORKER_BACKEND=max` (IU
unified endpoint fallback when unset). Use this by default.

## `--deep` — add native correctness + security (also on Max)

When the args contain `--deep`, ALSO run Anthropic's native reviewers and merge
them with the sideclaw result. These run on the orchestrator's Max model and are
tuned for real correctness bugs — complementary to sideclaw's architecture /
framework / style angles. **Reserve `--deep` for pre-ship gates or risky changes**,
not routine reviews — it spends Max.

1. Run the sideclaw review (as above).
2. Invoke the native **`code-review`** skill at high effort over the same scope
   (Skill tool, `args: "high"`). It targets correctness bugs the angle reviewers
   may miss.
3. **Conditionally** invoke the native **`security-review`** skill if the diff
   touches security-sensitive surface — auth/authz, secrets or credentials,
   crypto, SQL/command/path construction from input, file uploads, shelling out,
   or env-var handling. Skip it otherwise.
4. Merge all findings into one verdict, deduplicated against the sideclaw
   findings. Map native **Important** → blocking, **Nit** → improvements. Keep
   sideclaw's outcome classification (`clean` / `actionable` / `needs-human`); if
   the native pass surfaces a blocking bug, the merged outcome is at least
   `actionable`.

## Output

Present one consolidated verdict — outcome, blocking, improvements, discussions,
testGaps, summary — noting the catching reviewer per finding. Don't echo each
tool's raw output; synthesize.

**Worker caveats when consuming findings:**
- **Line numbers are unreliable** — the worker often cites lines that don't exist (e.g. L688 in a 600-line file). The *substance* is usually accurate; the location isn't. Before reporting or acting on a finding, **grep for the symbol/code, not the cited line.**
- **Angle reviewers explore the live tree**, not just the diff (they have Bash/Read/Grep). A finding may reference current code outside the reviewed scope — useful, but verify it's in-scope before treating it as introduced by the change.
- Before claiming a finding is wrong, verify it in the actual code — don't dismiss it on the bad line number alone.
