---
name: review
description: Code review via agw review v4 (prepare/submit host commands, no LLM in agw) with one reviewer agent on this session's Max. Rounds converge by disposition; `covered` proves a range was reviewed.
---

# Review

Args: `[scope (default uncommitted; head, <ref>, <a>..<b>) | --pr N | --branch B] [--min light|standard|deep] [--context '<intent>'] [--thread <key>]`. `--pr`/`--branch` review a throwaway clone and never touch the main checkout; they exclude a scope. The scope always goes to `agw review prepare` as `--scope <scope>`, never positional. `--thread` takes the thread key or the thread id `status` prints. Every `agw review` call below passes `--cwd "$(git rev-parse --show-toplevel)"`. A bare `<ref>` means `merge-base(ref, HEAD)..HEAD`, not the single commit.

## Flow

1. **Prepare:** `agw review prepare --cwd "$(git rev-parse --show-toplevel)" [--scope <scope> | --pr N | --branch B] [--min …] [--context '…'] [--thread …] --account "$(claude-account account)" --commit --format json`. Pass `--context` with the intent (the brief, plan step, PR body) whenever you have it. Without `--account` the ceiling is `unjudged`.
2. **By `status`:**
   - `skipped`: tier none. Report the `rule`; nothing to review.
   - `held`: the ceiling or the deep cap. Report `reason`, never lower the tier, stop. The review waits; re-run later.
   - `needs-human`: the 4th round on the thread is refused. Step back (below).
   - `ready`: Agent tool, `subagent_type: reviewer`, `model` = `seat.model`, `effort` = `seat.effort`, `prompt` = prepare's `prompt` verbatim, foreground.
3. **Submit the reply verbatim**, byte for byte, never shortened, reformatted or edited (a Wave 9 lesson):
   ```
   agw review submit <jobId> --attempt 1 --commit --format json <<'REVIEW_REPLY_EOF'
   <the agent's reply>
   REVIEW_REPLY_EOF
   ```
   Refused (bad JSON, schema, `files` differs from stat.txt): run the agent once more with the error appended to the prompt, submit with `--attempt 2`. Refused again: stop, needs-human.
4. **Present REVIEW_OUTPUT v4** (`agw schema review`): `outcome` (`clean` / `actionable` / `needs-human`), `summary`, `tier` and `rule`, then `findings` by tag (`important`, `nit`, `pre-existing`) with `id`, `file:line`, `class`, `message`, `failureScenario`, `fix`, `votes`; `criteria` as a met / not-met / unclear table when present; `checked` when it explains a clean result; `stepBack` if set. Synthesize; don't echo raw JSON.

## Fix loop

Every finding gets a disposition. Fix it, then `agw review dispose <jobId> <findingId> fixed|wrong|intentional|irrelevant [--reason '…'] --commit`. `wrong`, `intentional` and `irrelevant` need a reason you would defend; `pre-existing` never blocks. Then re-run `/review` on the same scope (same thread: round 2 reviews only what changed since the last reviewed head). Clean: done.

- Round 3 with `important` left: `stepBack` is set. Stop fixing, reconsider the approach, report it.
- Round 4 is refused (`needs-human`).

## Status and coverage

- `agw review status --cwd <dir>` shows a running review and the newest jobs; with a `jobId` its thread findings.
- `agw review cancel <jobId> --commit` abandons a `prepared` job nobody will submit: an in-session one at once; a hidden one only if the factory has not started it.
- `agw review stats [--by tier|rule|prompt|repo] [--since <iso>]` has the ledger numbers: clean rate, findings, precision, anchoring, per reviewer prompt fingerprint.
- `agw review covered --cwd <dir> --range a..b --format json`: is every first-parent commit of the range reviewed at its required tier with no open important finding. `uncovered` lists the shas.

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
- A finding may reference code outside the reviewed scope: verify it is in-scope before treating it as introduced by the change (`pre-existing` findings never block).
- Before claiming a finding is wrong, verify it in the actual code — don't dismiss it on the bad line number alone.
