---
name: check
description: Run validation (format, lint, tsc, test) via the agw CLI (agent-workflows)
---

# Check — via `agw`

1. Run `agw check --cwd <repo root> --format json` via Bash. Add `--commands '["cmd1","cmd2"]'` (JSON array, run verbatim) only when the caller names commands; otherwise it runs `make check`, else discovers format/lint/typecheck/test.
2. Exit 10 = still running (wait budget `AGW_WAIT_BUDGET_S`, default 110 s). The JSON names the run: run `agw run wait <runId> --format json`, repeat until the exit is not 10. Never wrap it in a short timeout.
3. Exit 0 = the run finished, **not** that validation passed. Read `output.passed` first; if false, inspect `output.steps[n].errors`. `output.summary` is the one-liner.

Exit codes a caller acts on (`agw schema --exit-codes`):

| Code | Meaning | Action |
|-|-|-|
| 0 | run finished | read `output.passed` |
| 10 | still running | `agw run wait <runId>` |
| 1 | run failed/cancelled, or a 5xx | state is on stdout; report it |
| 2 | bad flag/value | fix the call |
| 3 | no secret, or 401/403 | credentials in `~/.config/agw/env` |
| 7 | host unreachable | report; don't retry-loop |
| 8 | rate limited | retry after `details.retryAfterS` |
