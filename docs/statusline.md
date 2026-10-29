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
MAX ME · Opus 5.5 · high | 120k/970k 12% | Σ594k | ⚡93% | 25min | iu 2/90 · me 43/17 ↺90m · ∑76%
dotfiles | * master
```

**Line 1** — Session metrics:
- Lane (`MAX`/`IU`) · model · effort — effort is stdin `.effort.level` (per-model
  since 2.1.251, so `settings.json`'s `effortLevel` is not what runs); `·no-think`
  when `.thinking.enabled` is false
- Context: `{used}k/{usable}k {color-coded %}` — usable = the auto-compact point (`autoCompactWindow`, 600k) or, unset, total minus a 30k buffer
- Total tokens (main loop + subagents, cache reads excluded), formatted as `308k` or `1.2M`
- Prompt cache: `⚡{hit ratio}` from stdin `.prompt_cache`, `cold` once the TTL lapsed
- Session duration
- Accounts, one final segment (Max only): `iu 2/90 · me 41/22 ↺90m · ∑76%` — every enabled
  account as `<id> <5h%>/<wk%>` in registry order, then `∑<pool>%` (weekly use weighted by
  plan multiple, `max20x` 20 / `max5x` 5, all 1 when one is unknown; the formula of Tinycast's
  `usage/summary.ts`; only with more than one account). Numbers are coloured by the context
  thresholds (green < 50, yellow < 75, red). The session's own account is **bold** and shows
  the live `rate_limits` numbers from stdin; the others come from `usage_accounts.json` and go
  grey when their sample is over 1 h old, plus `✗login` when their login failed (omitted
  without figures). A single account shows `<id> 5h/wk` and no `∑`. The own 5h reset countdown
  ` ↺90m` follows the own entry only while line 1 stays within 130 visible columns (typical
  line: about 105 with it). `⚠ claude.ai login` (fallback fetch failed) stays as its own segment.
  The routing reason (`CLAUDE_ACCOUNT_REASON`) and any pace hint are not rendered.

**Line 2** — Location:
- CWD (home-shortened, worktree-aware: `WT·SE proj/path` for student-enrolment worktrees)
- Git branch + status: `✓` clean, `*` dirty, `!!` merge conflicts

### Accounts segment (files only)

The render reads `usage_accounts.json` for the other accounts and the pool, and never spawns `claude-account`/bun or the network.
`fetch_usage.py --accounts` rewrites it in the background, at most once a minute
(`usage_accounts.stamp`), from `claude-account usage --json`: per account `plan`, and per
window the fresh `utilization` plus the last known `value`/`value_resets_at_epoch` and
`age_s`. A window whose reset has passed counts as 0; a missing or unreadable file means no
extras, no error. `CLAUDE_SL_DIR` relocates the render caches (test seam,
`scripts/statusline.test.sh`, run by `make claude-launcher-test`).

## Context Color Coding

| Usage | Color |
|-|-|
| < 50% of usable | Green |
| 50–74% | Yellow |
| ≥ 75% | Red |

"Usable" = `autoCompactWindow` (env `CLAUDE_CODE_AUTO_COMPACT_WINDOW` wins) when below the model window, else `context_window_size - 30000`.

## Usage Stats Implementation

**Primary: stdin `.rate_limits`** (`five_hour`/`seven_day` → `used_percentage`,
`resets_at` epoch seconds). Max sessions only, and only from the first API
response on. Every render that has them also reports them to the agent-workflows host with
`agw quota-report` (throttled to once a minute per account via `/tmp/claude_sl/usage_push_<dir>.stamp`,
fire-and-forget; a silent no-op without `agw`, e.g. on the MacBook) — that is what keeps the host's quota view fed. The same throttled render also records a
per-account sample (`claude-account record`, account = registry id resolved from
`CLAUDE_CONFIG_DIR`, unset → `iu`) into `~/.cache/claude-accounts/<id>.sample.json`
(`docs/claude-accounts.md`). An `IU`/`ME` badge after the auth mode shows only when
more than one account is enabled.

**Fallback until then: `fetch_usage.py`** — `https://api.anthropic.com/api/oauth/usage`
with the Claude Code OAuth token from the macOS Keychain (`Claude Code-credentials`)
plus `anthropic-beta: oauth-2025-04-20`. Run via `uv run`, cache
`/tmp/claude_sl/usage_api.json`, 5-min TTL, background refresh via `disown`; it
also reports through `agw quota-report`. Never spawned on the IU lane. Since claude-accounts W0
it first serves a **fresh (<5 min) default-account (`iu`) sample from the quota cache** (same
`usage_api.json` shape, `source: claude-accounts`, no `limits`/`extra_usage`) and
calls the API only when that sample is stale; it also writes
`/tmp/claude_sl/usage_accounts.json` (all accounts). The API path retires in W2.

- On the headless mini the Keychain read fails (`security` exit 36, locked
  keychain), the cache holds `{"error": …}` and the line shows `⚠ claude.ai login`
  until the first response brings `rate_limits` — which is why the push moved here.
- The endpoint is **rate-limited** (per-token 429s within a few requests/min) —
  on 429 the existing cache is kept rather than blanked.
- Fields used: `five_hour.utilization` (5h window %, color-coded),
  `five_hour.resets_at` → the "↺Nm" countdown, `seven_day.utilization` (weekly).
  `seven_day_sonnet` is also captured (legacy; `null` on current plans).
- Additive keys for other consumers (tinycast-extensions' Claude Usage):
  `limits` — the endpoint's generic limit list, normalized to `{kind, group,
  label, percent, resets_at_epoch, severity, is_active,
  allowance_percent_of_weekly}`; `kind` is `session` / `weekly_all` /
  `weekly_scoped`, and a scoped limit's `label` is the model name (Fable on a
  Max plan as of 2026-10) — and `extra_usage` (passed through as returned).
  The unmodified response lands in `/tmp/claude_sl/usage_raw.json` for
  checking what the endpoint returns today.
- Errors are written into the cache file as `{"error": …}` and logged to
  `~/.claude/logs/YYYY-MM-DD.jsonl` (`src: fetch_usage`), 3-day cleanup.

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
