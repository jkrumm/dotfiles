---
description: Makefile authoring conventions — default help target, 1Password signing inside make targets, lifecycle-target design
paths: ["Makefile", "**/Makefile"]
---

# Makefile Conventions

- **Default target:** set `.DEFAULT_GOAL := help` and make `help` the first target, so a bare `make` prints the target list instead of running the first real target.
- **1Password in Makefiles:** always pass an explicit `--account <name>` to `op` calls inside a Makefile, and guard with a signin check — the interactive shell's cached 1Password session does not carry into `make`'s subshell:
  ```makefile
  @op whoami --account <name> >/dev/null 2>&1 || op signin --account <name>
  @op run --account <name> --env-file=... -- <cmd>
  ```
  See `prometheus-scripts/mcp-hub/Makefile` (`hub-up`) for the pattern in practice.

## Lifecycle targets

Worked reference for everything below: `prometheus-scripts/analysis/Makefile` (`dashboard-up`).

- **One canonical target per lifecycle verb.** Never ship a second target that is "the same thing but more thorough" (`dashboard-up` vs `dashboard-rebuild`, `deploy` vs `deploy-clean`). It forces a decision on every run — "which one do I need?" — and that decision is the uncertainty the Makefile exists to remove. A `dashboard-rebuild` existed for "when the cache misbehaves"; its premise was false (Docker layer-cache keys *are* content checksums), and when a real staleness bug appeared the escape hatch got pulled three times, failed mysteriously each time, and delayed the actual diagnosis.
- **Overrides express policy, not doubt.** `FORCE=1` to override "refuse while a job is in flight" is legitimate — an operational judgement the human is entitled to make. `CLEAN=1` / `--no-cache` to override "I'm not sure the build is fresh" is not — it lets you skip a diagnosis. Policies get overrides; doubts get assertions.
- **Assert, don't nuke.** A lifecycle target should *prove* its result, not offer a way to distrust it. `dashboard-up` fingerprints the running container's source tree against the working tree and fails loudly on mismatch (~1s; see `analysis/dashboard/codesum.py`). That catches staleness from any cause — cache, forgotten rebuild, wrong image, stray bind mount. A nuclear rebuild option cannot even tell you whether the cache was the problem.
- **Lifecycle targets must terminate.** Never end one by attaching a foreground watcher/tailer (`docker compose watch`, `tail -f`). Split "do the thing" from "watch the thing" (`dashboard-up` / `dashboard-logs`). An agent or script invoking a non-terminating target blocks until its tool call times out — and a target that never exits invites the next anti-pattern.
- **Never `pkill -f '<broad pattern>'`.** That target used `pkill -f 'compose watch'` to clear a previous run's watcher; a second invocation SIGTERMed the first terminal's `make`, surfacing as `make[1]: *** [target] Terminated: 15` and getting misread as a crash for weeks. If a target needs exclusive access, take a real lock or make it idempotent — do not pattern-match other people's processes.
- **Guard destructive or outward-facing targets, and fail open.** A guard that can block the command when the guard itself is broken is worse than no guard. `dashboard-up`'s repair-wave guard is the pattern: it queries the running service's own HTTP API, and treats every error (service down, no token, timeout, parse failure) as "nothing to protect" and proceeds.
- **Guard against tool-emitted shadow artifacts where a resolver prefers them.** `tsc -b --noEmit false` emitted `.js` next to `.tsx`; Vite resolves `.js` first, so every later source edit was silently invisible in the built bundle while builds reported success. It reads exactly like a cache bug. Scan the whole package, not just `src/` — the same emit produced a `vite.config.js` that shadowed `vite.config.ts`.
