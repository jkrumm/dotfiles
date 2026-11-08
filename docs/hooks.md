# Claude Code Hooks

## Overview

There are no desktop notifications — the Herdr app's native agent-state notifications
(Claude reports to the core over OSC 7501) cover "input required" and "done". `~/.claude/hooks/session-env.ts` (which replaced
the osascript-based `notify.ts`) runs on `SessionStart` and does exactly one thing:
it logs a `session_env` entry (`ANTHROPIC_BASE_URL`, `USAGE_LANE`), which is what
usage-tracker uses to bill each launcher.

## Registration

Hooks are registered in `config/settings.template.json`, which `make setup`
merges into the live `~/.claude/settings.json` — never edit the live file for a
persistent change.

```json
"SessionStart": [{ "matcher": "startup|resume|clear|compact", "hooks": [
  { "type": "command", "command": "~/.claude/hooks/session-env.ts" },
  { "type": "command", "command": "~/.claude/hooks/machine-role.ts" } ] }]
```

The hook receives a JSON payload on stdin describing the event and its context.

The template registers nine more of this repo's hooks alongside it — symlinked
live from `dotfiles/hooks/`, so an edit takes effect on the next tool call (a *new* hook needs one `make setup` to link it and merge its template entry into `settings.json`):

| Hook | Event | Does |
|-|-|-|
| `protect-branches.ts` | PreToolUse (Bash) | blocks pushes to protected branches (`config/pr-required-repos.json`) |
| `docker-makefile.ts` | PreToolUse (Bash) | blocks raw `docker` where a Makefile exists; tokenizes the command so a *mention* is not an invocation |
| `broad-kill-guard.ts` | PreToolUse (Bash) | denies pattern kills: `pkill -f`, `pkill` without `-P`/`-g`, `killall`, and `kill`/`xargs kill`/`pkill -P` fed by `pgrep -f` (incident 2026-11-01: one `pgrep -f` loop SIGTERMed eight agent sessions) |
| `review-bypass-guard.ts` | PreToolUse (Bash) | factory sessions only (`FACTORY_SESSION` set): denies `gh pr merge --admin` (except on the owner's listed repos, `ADMIN_MERGE_REPOS`, when the command names the repo), `gh api` writes to merge endpoints (`pulls/<n>/merge`, `merges`) and to rulesets / branch protection, and GraphQL merge / ruleset / protection mutations (or a query / non-GET endpoint a shell variable completes; `$name` in a single-quoted GraphQL query is denied too). The denial says the bypass is the owner's to do by hand; the owner's own sessions are untouched, a plain `gh pr merge --squash` stays allowed (incident 2026-11-05: a lead admin-merged a work repo's PR past its required review). Not covered: `curl` at api.github.com, `gh alias set` |
| `test-slot.ts` | PreToolUse (Bash) | rewrites a test run in command position (vitest, jest, pytest, `bun test`, `npm`/`pnpm`/`yarn` `test` or `run test*`/`check`, `make check`/`test*`/`e2e*`, `go test`, `cargo test`, `playwright test`, `xcodebuild test`) into `factory slot run --name <repo> <runner> -- env FACTORY_SLOT_ACTIVE=1 VITEST_MAX_WORKERS=<cores/2> PYTEST_XDIST_AUTO_NUM_WORKERS=<cores/2> $SHELL -c '<command>'`, so sessions outside the factory and IuRoot `make check` share the factory's test slots (incident 2026-11-05/06: load 346 on 12 cores). Left alone: inside a slot (`FACTORY_SLOT_ACTIVE`), a command that calls `factory slot` or `agw` (`agw check` takes its own slot), a project whose Makefile/package.json already says `slot run` or `agw check` (no second slot, no deadlock). Fails open: no `factory` on PATH, bad payload; a down server is `factory slot run`'s own open-on-outage. A leading `cd <dir> &&` stays outside the wrapper so the session cwd follows it. Slot count is the server's `FACTORY_SLOTS`; contention waits up to 45 min (`FACTORY_SLOT_WAIT_MS`), longer than a Bash call's default timeout, so a long queue shows as a tool timeout and is retried |
| `permission-allow.ts` | PermissionRequest | answers every permission dialog that survives `bypassPermissions` (an `ask` rule, a tool wanting confirmation) with allow, so an unattended session never stalls; `rm` on `/` or `~` is denied at once instead of the built-in 2-minute wait. PreToolUse denies and `permissions.deny` still win. Cannot answer: MCP tools that require user interaction, MCP elicitation |
| `model-discipline.ts` | PreToolUse (Agent) | denies a worker on `model: fable` outright, and `subagent_type: fork` whenever the caller (read from its own transcript) is Fable/Opus — `model: opus` is denied unless the call's `description` carries `[opus: <reason>]` |
| `iu-model-guard.ts` | UserPromptSubmit + PreToolUse (Agent) | on a metered `ANTHROPIC_BASE_URL` (IU), blocks an Opus/Fable main model (resolved from the process's `--model` → `ANTHROPIC_MODEL` → settings, aliases through `ANTHROPIC_DEFAULT_*`) and an Opus/Fable worker — runs inside every child `claude` process too, so a hand-rolled IU runner is caught (no launcher sets IU any more; this is the backstop) |
| `machine-role.ts` | SessionStart | injects this machine's secrets backend + outbound-access routing |
| `hc-session-label.ts` | SessionStart + SessionEnd | labels its own herdr-core terminal (`jk.claude.session`, `jk.claude.config`) so `hc-resume` can restore the conversation; no-op outside a core terminal (`HC_TERMINAL_ID` unset) |

### Software-factory hooks

Six events call the `factory` CLI (software-factory repo) for sessions `rd` spawned: `SessionStart`,
`UserPromptSubmit`, `Stop`, `StopFailure` (matcher `rate_limit`), `Notification` (matchers `permission_prompt`,
`idle_prompt`, `quota_auto_resume_fired|stale|disabled`) and `SessionEnd`. Each runs

```sh
[ -n "$FACTORY_SESSION" ] && command -v factory >/dev/null && factory hook <event>; exit 0
```

with `<event>` = `session-start`, `user-prompt-submit`, `stop`, `stop-failure`, `notification`, `session-end`.
`rd work` sets `FACTORY_SESSION=<agent name>` at spawn (`docs/remote-dev.md`), so without it nothing runs and
the owner's own sessions never see the hooks; without `factory` on `PATH`, or when it fails, the command still
exits 0, so a session is never blocked. The source is the software-factory repo,
`integrations/claude-code/hooks.json` (the contract lives in that directory's README); this repo carries no copy.
`_render-settings` appends each event's entries to the rendered `settings.json` after the template merge, via the jq
merge in the Makefile (`FACTORY_DIR`, default `~/SourceRoot/software-factory`): entries identical to the factory's
are subtracted first, so a re-render never duplicates them, and the other hooks stay. `make setup` renders into
`~/.claude` and into every account dir in `config/claude-accounts.json` (`claude-accounts-setup` →
`_render-settings`). With `hooks.json` missing the render prints `factory hooks not installed: <path> missing` and
still succeeds, without the factory hooks. The template wins on merge, so a hand-added live hook is dropped on the
next `make setup`.
`factory hook` must print nothing to stdout on `SessionStart` and `UserPromptSubmit` (stdout becomes context).
Tests: `scripts/factory-hooks.test.sh`.

Run `make hooks-test` (`bun test hooks/`) after any hook edit.

## Debug Logs

`session-env.ts` writes structured JSONL to `~/.claude/logs/YYYY-MM-DD.jsonl`
(`fetch_usage.py` writes there too), with a 3-day cleanup on every invocation.
`jq 'select(.event == "session_env")'` for launcher/billing context,
`jq 'select(.src == "fetch_usage")'` for statusline fetch errors.

## Exit Codes

| Code | Meaning |
|-|-|
| 0 | Normal — session ends |
| non-zero | Hook error — shown in Claude UI |
