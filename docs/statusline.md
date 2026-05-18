# Claude Code Statusline

## Overview

A 2–3 line custom statusline rendered by `~/.claude/statusline.sh`, configured
in `~/.claude/settings.json` as:

```json
"statusLine": { "type": "command", "command": "~/.claude/statusline.sh" }
```

The script receives a JSON payload on stdin with session context and prints
1–3 lines to stdout. Each line becomes a separate statusline row.

## Output Format

```
Claude Sonnet 4.6 | 86k/170k 51% | +660 -52 | 308k | 23min
~/SourceRoot/basalt-ui | * feat/add-button
```

**Line 1** — Session metrics:
- Model name
- Context: `{used}k/{usable}k {color-coded %}` — usable = total minus 30k autocompact buffer
- Lines changed: `+{added} -{removed}` (Claude's edits this session)
- Total tokens (cumulative input + output), formatted as `308k` or `1.2M`
- Session duration
- Subscription usage: `26%/5h ↺23m · 14%/wk` — real plan percentages from Claude.ai API (cached, non-blocking)

**Line 2** — Location:
- CWD (home-shortened, worktree-aware: `WT·SE proj/path` for student-enrolment worktrees)
- Git branch + status: `✓` clean, `*` dirty, `!!` merge conflicts

## Context Color Coding

| Usage | Color |
|-|-|
| < 50% of usable | Green |
| 50–74% | Yellow |
| ≥ 75% | Red |

"Usable" = `context_window_size - 30000` (30k reserved for autocompact buffer).

## Usage Stats Implementation

Data source: `https://claude.ai/api/organizations/{org_id}/usage` — the same endpoint the
Claude.ai web UI uses. Returns real plan utilization percentages, not computed token counts.

Auth: Chrome cookies (`sessionKey` + `cf_clearance`) extracted from macOS via:
1. AES-128 key derived from `Chrome Safe Storage` Keychain entry (PBKDF2-SHA1, `saltysalt`, 1003 iters)
2. Chrome SQLite cookie DB decrypted (v10 format: strip 3-byte prefix + 32-byte salt block)

Script: `~/.claude/fetch_usage.py` (symlinked from `scripts/fetch_usage.py`), run via `uv run`.
Cache: `/tmp/claude_sl/usage_api.json`, 5-min TTL, background refresh via `disown`.

API response fields used:
- `five_hour.utilization` — 5h rolling window % (color-coded green/yellow/red)
- `five_hour.resets_at` — reset timestamp → converted to "↺Nm" countdown
- `seven_day.utilization` — weekly plan % (all models)

Org UUID read from `~/.claude/.claude.json` → `.oauthAccount.organizationUuid`.

## Known Gotchas

- `grep -c` on macOS exits 1 when there are no matches, which can corrupt
  arithmetic via `|| echo 0` producing double output. Fixed with `${var:-0}` fallback.
- Script must end with `exit 0` — otherwise the last command's exit code
  leaks out and Claude Code may suppress the statusline display.
- Branch detection uses `| head -1` to prevent multi-line output from
  poisoning the variable (can happen in detached HEAD state).
