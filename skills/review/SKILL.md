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

## What the gates cannot catch — check these yourself

A green run is not evidence of correctness. A four-round dashboard overhaul
passed typecheck, lint, the palette guard and 807 tests while drawing unmeasured
time as clean measured time; only the adversarial pass caught it. Two classes
recur, and neither is visible to any tool:

- **Comments that assert something false about the code they sit on.** Seen
  twice in one change: a 12-line block justifying a wrapper by describing
  behaviour the wrapped component did not have, and a docblock stating the exact
  opposite of its own function after a dependency upgrade widened an enum. Both
  would have misled the next reader into deleting a live guard as dead. When a
  comment makes a load-bearing factual claim — about a library's behaviour, a
  sibling module, or a threshold — **verify it against source**, not against
  plausibility.
- **Half-fixes reported as fixes.** A subagent's report is a claim. Findings that
  came back "fixed" included dead code no caller wired up, and the one example
  string the user had named by hand still present. Check the specific site named
  in the request, not the general area.

**For a subjective ask, demand a measurable acceptance criterion.** "Reduce the
text bloat" got measurably *worse* across two rounds — every pass added
explanatory prose while fixing something else — until the criterion became "count
user-visible words before and after". It then went down 10%. If the request
cannot be checked by a number or a named site, it will be reported as done
regardless of what happened.

**Worker caveats when consuming findings:**
- **Line numbers are unreliable** — the worker often cites lines that don't exist (e.g. L688 in a 600-line file). The *substance* is usually accurate; the location isn't. Before reporting or acting on a finding, **grep for the symbol/code, not the cited line.**
- **Angle reviewers explore the live tree**, not just the diff (they have Bash/Read/Grep). A finding may reference current code outside the reviewed scope — useful, but verify it's in-scope before treating it as introduced by the change.
- Before claiming a finding is wrong, verify it in the actual code — don't dismiss it on the bad line number alone.
