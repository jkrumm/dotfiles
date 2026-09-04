# Claude Code Hooks — notify.ts

## Overview

A single Bun script (`~/.claude/hooks/notify.ts`) handles all four Claude Code
hook events. It provides rich macOS notifications, workspace identification by
sound, and session timing.

## Hook Events Handled

| Event | What Triggers It | Handler Behavior |
|-|-|-|
| `SessionStart` | Claude session opens (startup/resume/clear/compact) | Record session start time, capture project/branch context |
| `Notification` | Claude needs user input (idle_prompt) or permission | Send "Input Required" notification with context |
| `Stop` | Claude finishes a task | Send completion notification with project/branch/duration |
| `SessionEnd` | Claude session closes | Send session summary with total duration |

## Registration

Hooks are registered in `config/settings.template.json`, which `make setup`
merges into the live `~/.claude/settings.json` — never edit the live file for a
persistent change. `notify.ts` is wired to four events:

```json
"SessionStart": [{ "matcher": "startup|resume|clear|compact", "hooks": [
  { "type": "command", "command": "~/.claude/hooks/notify.ts" },
  { "type": "command", "command": "~/.claude/hooks/machine-role.ts" } ] }],
"Notification": [{ "matcher": "", "hooks": [{ "type": "command", "command": "~/.claude/hooks/notify.ts" }] }],
"Stop":         [{ "matcher": "", "hooks": [{ "type": "command", "command": "~/.claude/hooks/notify.ts" }] }],
"SessionEnd":   [{ "matcher": "", "hooks": [{ "type": "command", "command": "~/.claude/hooks/notify.ts" }] }]
```

The hook receives a JSON payload on stdin describing the event and its context.

The template registers three more of this repo's hooks alongside it — symlinked
live from `dotfiles/hooks/`, so an edit takes effect on the next tool call — plus
herdr's own state reporter:

| Hook | Event | Does |
|-|-|-|
| `protect-branches.ts` | PreToolUse (Bash) | blocks pushes to protected branches (`config/pr-required-repos.json`) |
| `docker-makefile.ts` | PreToolUse (Bash) | blocks raw `docker` where a Makefile exists; tokenizes the command so a *mention* is not an invocation |
| `machine-role.ts` | SessionStart | injects this machine's secrets backend + outbound-access routing |
| `herdr-agent-state.sh` | SessionStart (`*`) | reports agent state to herdr; guarded, so it no-ops where herdr's integration was never installed |

Run `make hooks-test` (`bun test hooks/`) after any hook edit.

## Notification Routing

Native macOS notification via `osascript`. `terminal-notifier` is deliberately
**not** used — it hangs in multiplexer environments.

```typescript
await $`osascript -e 'display notification ...'`.quiet();
```

## Workspace Sound Identification

Different macOS sounds per workspace — hear which project completed without
looking at the screen:

| Workspace | Sound | Detection |
|-|-|-|
| `SourceRoot` | Hero | `input.cwd` contains `/SourceRoot/` |
| `IuRoot` | Ping | `input.cwd` contains `/IuRoot/` |
| Other | Tink | Fallback |

## Context Extraction

Notifications show: `project • branch • duration`

- **SourceRoot**: extracts 2 path levels — `basalt-ui/packages/web` → `"basalt-ui/packages/web"`
- **IuRoot**: extracts 1 path level — `epos.student-enrolment` → `"epos.student-enrolment"`
- **Branch**: extracted from Claude's transcript, skips `main`/`master` (not interesting)
- **Duration**: elapsed time since `SessionStart` stored in `~/.claude/notification-state.json`

## State Persistence

Between hook invocations, state is written to `~/.claude/notification-state.json`:

```typescript
interface NotificationState {
  sessionStartTime?: number;   // ms timestamp
  projectName?:      string;
  gitBranch?:        string;
  workspace?:        "SourceRoot" | "IuRoot" | "Other";
}
```

## Debug Logs

`notify.ts` writes structured JSONL to `~/.claude/logs/YYYY-MM-DD.jsonl`
(`fetch_usage.py` writes there too), with a 3-day cleanup on every invocation.
`jq 'select(.event == "stop_decision")'` for hook decisions,
`jq 'select(.src == "fetch_usage")'` for statusline fetch errors.

## Exit Codes

| Code | Meaning |
|-|-|
| 0 | Normal — session ends |
| non-zero | Hook error — shown in Claude UI |
