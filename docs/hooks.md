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

The template registers six more of this repo's hooks alongside it — symlinked
live from `dotfiles/hooks/`, so an edit takes effect on the next tool call:

| Hook | Event | Does |
|-|-|-|
| `protect-branches.ts` | PreToolUse (Bash) | blocks pushes to protected branches (`config/pr-required-repos.json`) |
| `docker-makefile.ts` | PreToolUse (Bash) | blocks raw `docker` where a Makefile exists; tokenizes the command so a *mention* is not an invocation |
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
`rd wave|fan|work` set `FACTORY_SESSION=<agent name>` at spawn (`docs/remote-dev.md`), so without it nothing runs and
the owner's own sessions never see the hooks; without `factory` on `PATH`, or when it fails, the command still
exits 0, so a session is never blocked. They live in the template's `hooks`, which `make setup` renders into
`~/.claude` and into every account dir in `config/claude-accounts.json` (`claude-accounts-setup` →
`_render-settings`). The template wins on merge, so a hand-added live hook is dropped on the next `make setup`.
`factory hook` must print nothing to stdout on `SessionStart` and `UserPromptSubmit` (stdout becomes context).
Tests: `scripts/factory-hooks.test.sh` (in `make fan-test`).

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
