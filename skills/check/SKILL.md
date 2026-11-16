---
name: check
description: Run validation (format, lint, tsc, test) via the agw CLI (agent-workflows)
---

# Check — via `agw`

1. Run `agw check --cwd <repo root> --format json` (a relative `--cwd` resolves against the shell's directory) via Bash. Add `--commands '["cmd1","cmd2"]'` (JSON array, run verbatim) only when the caller names commands; otherwise it runs `make check`, else discovers format/lint/typecheck/test.
2. Set the wait budget to fit the repo: `AGW_WAIT_BUDGET_S=540 agw check …` (default 110 s ends a `make check` pending most of the time; stay under the Bash tool's 600 s foreground limit). A run that needs longer goes in the background with its exit code written to a log (`… > .check.log 2>&1; echo rc=$?`), then end the turn. Exit 10 = still running: resume once with `agw run wait <runId> --format json`, never in a loop; a second 10 means run it in the background. Never pipe agw into `head`/`tail` (the pipe hides the exit code).
3. Exit 0 = the run finished, **not** that validation passed. Read `output.passed` first; if false, inspect `output.steps[n].errors`. `output.summary` is the one-liner.

Exit codes: `agw schema --exit-codes`. Never retry-loop on 7.
