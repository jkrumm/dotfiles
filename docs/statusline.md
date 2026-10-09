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
MAX · Opus 5.5 · high | 120k/970k 12% | Σ594k | ⚡93% | 25min | 43%/5h ↺90m · 17%/wk
dotfiles | * master
```

**Line 1** — Session metrics:
- Lane (`MAX`/`IU`) · model · effort — effort is stdin `.effort.level` (per-model
  since 2.1.251, so `settings.json`'s `effortLevel` is not what runs); `·no-think`
  when `.thinking.enabled` is false
- Context: `{used}k/{usable}k {color-coded %}` — usable = total minus 30k autocompact buffer
- Total tokens (main loop + subagents, cache reads excluded), formatted as `308k` or `1.2M`
- Prompt cache: `⚡{hit ratio}` from stdin `.prompt_cache`, `cold` once the TTL lapsed
- Session duration
- Subscription usage: `26%/5h ↺23m · 14%/wk` — Max only (below)

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

**Primary: stdin `.rate_limits`** (`five_hour`/`seven_day` → `used_percentage`,
`resets_at` epoch seconds). Max sessions only, and only from the first API
response on. Every render that has them also POSTs them to agent-gateway's
`/api/usage` (throttled to once a minute via `/tmp/claude_sl/usage_push.stamp`,
fire-and-forget) — that is what keeps agent-gateway's quota view and the devhost
heartbeat's quota component fed.

**Fallback until then: `fetch_usage.py`** — `https://api.anthropic.com/api/oauth/usage`
with the Claude Code OAuth token from the macOS Keychain (`Claude Code-credentials`)
plus `anthropic-beta: oauth-2025-04-20`. Run via `uv run`, cache
`/tmp/claude_sl/usage_api.json`, 5-min TTL, background refresh via `disown`; it
also POSTs to agent-gateway. Never spawned on the IU lane.

- On the headless mini the Keychain read fails (`security` exit 36, locked
  keychain), the cache holds `{"error": …}` and the line shows `⚠ claude.ai login`
  until the first response brings `rate_limits` — which is why the push moved here.
- The endpoint is **rate-limited** (per-token 429s within a few requests/min) —
  on 429 the existing cache is kept rather than blanked.
- Errors are logged to `~/.claude/logs/YYYY-MM-DD.jsonl` (`src: fetch_usage`), 3-day cleanup.

## Known Gotchas

- `grep -c` on macOS exits 1 when there are no matches, which can corrupt
  arithmetic via `|| echo 0` producing double output. Fixed with `${var:-0}` fallback.
- Script must end with `exit 0` — otherwise the last command's exit code
  leaks out and Claude Code may suppress the statusline display.
- stdin is parsed in **one** `jq` pass joined on `\x1f`, not tab: tab is IFS
  whitespace, so `read` would collapse an empty field and shift the rest. And
  never `.field // default` on a boolean — jq's `//` treats `false` as missing.
- Branch detection uses `| head -1` to prevent multi-line output from
  poisoning the variable (can happen in detached HEAD state).
