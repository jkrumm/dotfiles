# Claude Code Hooks

## Overview

There are no desktop notifications — herdr's native agent-state notifications
cover "input required" and "done". `~/.claude/hooks/session-env.ts` (which replaced
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

The template registers four more of this repo's hooks alongside it — symlinked
live from `dotfiles/hooks/`, so an edit takes effect on the next tool call — plus
herdr's own state reporter:

| Hook | Event | Does |
|-|-|-|
| `protect-branches.ts` | PreToolUse (Bash) | blocks pushes to protected branches (`config/pr-required-repos.json`) |
| `docker-makefile.ts` | PreToolUse (Bash) | blocks raw `docker` where a Makefile exists; tokenizes the command so a *mention* is not an invocation |
| `model-discipline.ts` | PreToolUse (Agent) | denies a worker on `model: fable` outright, and `subagent_type: fork` whenever the caller (read from its own transcript) is Fable/Opus — `model: opus` is deliberately left open, see the file's own header |
| `machine-role.ts` | SessionStart | injects this machine's secrets backend + outbound-access routing |
| `herdr-agent-state.sh` | SessionStart (`*`) | reports agent state to herdr; guarded, so it no-ops where herdr's integration was never installed |

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
