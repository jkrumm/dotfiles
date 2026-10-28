---
name: review
description: Multi-angle code review via the agw CLI (agent-workflows). Add --deep to also run Anthropic's native correctness + security review on the orchestrator's Max model.
---

# Review

## Default — `agw review`

1. Run `agw review --cwd <repo root> [--scope <scope> | --pr N | --branch B] --format json` via Bash. Parse args for the scope (default `uncommitted`): e.g. `head` (last commit only), `HEAD~3` (a bare ref = the range up to HEAD, i.e. the **last 3 commits** — not the single commit), `main..HEAD` (explicit range), `path/to/file.ts`. Strip any leading flags (like `--deep`) before extracting the scope. `--pr` and `--branch` review a throwaway clone and exclude `--scope`. Pass `--depth light|standard|deep` or `--context '<intent>'` through only when the caller gave one; otherwise the router picks the depth.
2. Exit 10 = still running (wait budget `AGW_WAIT_BUDGET_S`, default 110 s). The JSON names the run: run `agw run wait <runId> --format json`, repeat until the exit is not 10. Never wrap it in a short timeout.
3. Read `output` (REVIEW_OUTPUT, `schemaVersion: 2`; fields per `agw schema review` and the review workflow's `schema.ts`): `outcome` (`clean` / `actionable` / `needs-human`), `blocking`, `discussions`, `improvements` (findings: `file`, `line?`, `message`, `angle`), `testGaps` (strings), `escalationCategory?`, `summary`, `degraded?`. Failure: exit 1 with `status: "failed"` and `error: { kind, message }`.

This runs the deterministic floor (architect and senior-dev angles) plus a router that adds content-driven angles — security, performance, concurrency, data-migration, api-contract, resilience, and others — and an adversary pass when the diff warrants them.

## `--deep` — add native correctness + security (on the orchestrator's Max model)

When the args contain `--deep`, ALSO run Anthropic's native reviewers and merge
them with the `agw review` result. These run on the orchestrator's Max model and are
tuned for real correctness bugs — complementary to the angle reviewers'
architecture / framework / style view. **Reserve `--deep` for pre-ship gates or risky changes**,
not routine reviews — it spends Max. `--deep` does not map to `--depth deep`.

1. Run `agw review` (as above).
2. Invoke the native **`code-review`** skill at high effort over the same scope
   (Skill tool, `args: "high"`). It targets correctness bugs the angle reviewers
   may miss.
3. **Conditionally** invoke the native **`security-review`** skill if the diff
   touches security-sensitive surface — auth/authz, secrets or credentials,
   crypto, SQL/command/path construction from input, file uploads, shelling out,
   or env-var handling. Skip it otherwise.
4. Merge all findings into one verdict, deduplicated against the `agw review`
   findings. Map native **Important** → blocking, **Nit** → improvements. Keep
   the review's outcome classification (`clean` / `actionable` / `needs-human`); if
   the native pass surfaces a blocking bug, the merged outcome is at least
   `actionable`.

## Provider-balance failure — degrade to in-session `/code-review`

Trigger: `output.degraded === "provider_balance"` (outcome `needs-human`, `escalationCategory: spend`: the IU provider is out of balance even after the fallback), or a non-zero exit whose error message names a provider balance (402, "Insufficient Balance", "PaymentRequired").

- **Never retry or resubmit** the review.
- Say in one line that `agw review` is degraded by provider balance, then run `/code-review high <target>` (Skill tool) over the same scope on this session's own Claude (Max).
- Record the review step as "agw review degraded (provider balance) → in-session /code-review".
- **Partial** (`needs-human` because only some reviewers failed — `discussions` entries with angle `(review pipeline)` naming a balance failure — while the rest returned findings): keep those findings, still run `/code-review high <target>` for the missing view, and say so.
- A balance-degraded `needs-human` is **not** an owner escalation — the in-session verdict decides the outcome.
- With `--deep`, the native `code-review` pass already covers this; don't run it twice.

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
