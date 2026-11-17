# hooks

Hooks are symlinked live into `~/.claude/hooks/`, so a change applies on the next tool call with no install step. Run `make hooks-test` (`bun test hooks/`) after any edit. The map of every hook: `docs/hooks.md`.

## broad-kill-guard

`hooks/broad-kill-guard.ts` denies pattern kills (`pkill -f`, `killall`, `kill` fed by `pgrep -f`) because they reach other agents' sessions. Kill by pid.

## herdr-core-guard

`hooks/herdr-core-guard.ts` denies, in every session, restarting, stopping, updating or starting the core (`hc server restart|stop|start`, `hc update`, `hc machine update`, `make herdr-core-update`, `launchctl` on its label), reboot, shutdown and halt, and killing herdr-core and its wrappers at `~/.local/bin/{hc,herdr-core}`. The one update path is `make herdr-core-update`, by the owner by hand (`docs/incident-2026-11-13-mini-panic.md`).

## nested-agents

`hooks/nested-agents.ts` hands an agent that edits or writes a file the nested `AGENTS.md` files of that directory (Claude Code loads them only on a Read), once per session and subagent, at most about 9,500 bytes a call; it never blocks.

## review-bypass-guard

`hooks/review-bypass-guard.ts` denies review bypasses in factory sessions (`FACTORY_SESSION`); the owner does those by hand:

- `gh pr merge --admin`, except on the owner's `ADMIN_MERGE_REPOS`. The repo is the one the command names or, when it names none, the one the cwd's remotes name. A `cd`, `GH_REPO`, `GH_HOST` or `GIT_*` in the command is denied with a hint to name the repo.
- `gh api` merge, ruleset and branch-protection writes.
- The GitHub config sync is allowed but runs tighten-only in a factory session (`scripts/github-config.sh` forces it): a lead runs `make github-config` itself when a repo joins `config/pr-required-repos.json` or a ruleset or rule is added, and it applies on its own. Naming `FACTORY_SESSION` or `TIGHTEN_ONLY`, or `env -i`, in that command is denied.
- A loosening (a repo leaves the list, a rule, approval or check dropped, enforcement lowered, a bypass actor added) or a state it cannot compare is skipped with exit 3: the lead raises an Errand for the owner's `make github-config`, and never edits the list or the script around it.

## Debug logs

`hooks/session-env.ts` and `scripts/fetch_usage.py` write structured JSONL to `~/.claude/logs/YYYY-MM-DD.jsonl`, cleaned after 3 days. Filter with `jq 'select(.event == "session_env")'` or `select(.src == "fetch_usage")`.
