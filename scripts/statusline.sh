#!/bin/bash

# Claude Code Statusline — 2 line layout
#
# Line 1: Model · Context (usable) · Session lines · Total tokens · Duration · Usage (5h/wk/mo)
# Line 2: CWD · Git branch & dirty flag

input=$(cat)

# ── Model ──────────────────────────────────────────────────────────────────────
model=$(echo "$input" | jq -r '.model.display_name // "Unknown"')
effort=$(jq -r '.effortLevel // "auto"' "$HOME/.claude/settings.json" 2>/dev/null || echo "auto")

# ── Working directory ──────────────────────────────────────────────────────────
cwd=$(echo "$input" | jq -r '.workspace.current_dir // "~"')
cwd_display="${cwd/#$HOME/~}"
cwd_display="${cwd_display/#~\/IuRoot\/worktrees\/student-enrolment\//WT·SE }"

# ── Context window ─────────────────────────────────────────────────────────────
total_input=$(echo "$input" | jq -r '.context_window.total_input_tokens // 0')
total_output=$(echo "$input" | jq -r '.context_window.total_output_tokens // 0')
context_size=$(echo "$input" | jq -r '.context_window.context_window_size // 200000')
used_percentage=$(echo "$input" | jq -r '.context_window.used_percentage // 0')

# Subtract ~30k autocompact buffer to show usable space
autocompact_buffer=30000
usable_size=$((context_size - autocompact_buffer))
usable_k=$((usable_size / 1000))
used_tokens=$((used_percentage * context_size / 100))
used_k=$((used_tokens / 1000))

if [ "$usable_size" -gt 0 ]; then
  usable_pct=$((used_tokens * 100 / usable_size))
else
  usable_pct=0
fi

if [ "$usable_pct" -lt 50 ]; then
  color="\033[32m"   # green
elif [ "$usable_pct" -lt 75 ]; then
  color="\033[33m"   # yellow
else
  color="\033[31m"   # red
fi
reset="\033[0m"
pct_colored=$(printf "${color}%d%%${reset}" "$usable_pct")

# ── Session lines changed (Claude's edits this session) ────────────────────────
lines_added=$(echo "$input" | jq -r '.cost.total_lines_added // 0')
lines_removed=$(echo "$input" | jq -r '.cost.total_lines_removed // 0')

# ── Total tokens (cumulative) ──────────────────────────────────────────────────
total_tokens=$((total_input + total_output))
if [ "$total_tokens" -ge 1000000 ]; then
  tokens_fmt=$(awk "BEGIN {printf \"%.1fM\", $total_tokens/1000000}")
elif [ "$total_tokens" -ge 1000 ]; then
  tokens_fmt=$(awk "BEGIN {printf \"%.0fk\", $total_tokens/1000}")
else
  tokens_fmt="$total_tokens"
fi

# ── Duration ───────────────────────────────────────────────────────────────────
duration_ms=$(echo "$input" | jq -r '.cost.total_duration_ms // 0')
duration_s=$((duration_ms / 1000))
hours=$((duration_s / 3600))
minutes=$(((duration_s % 3600) / 60))
if [ "$hours" -ge 1 ]; then
  duration="${hours}h ${minutes}min"
else
  duration="${minutes}min"
fi

# ── Subscription usage (Claude.ai API, non-blocking cached) ────────────────────
# fetch_usage.py extracts Chrome cookies + calls claude.ai/api/…/usage.
# Cache TTL: 5 min. Background refresh on miss; stale value shown immediately.
_USAGE_CACHE="/tmp/claude_sl/usage_api.json"
_FETCH_SCRIPT="$HOME/.claude/fetch_usage.py"
_now_s=$(date +%s)

# Trigger background refresh when cache is stale or missing
if [ -f "$_USAGE_CACHE" ]; then
  _fetched_at=$(jq -r '.fetched_at // 0' "$_USAGE_CACHE" 2>/dev/null)
else
  _fetched_at=0
fi
if [ $(( _now_s - ${_fetched_at:-0} )) -gt 300 ]; then
  ( /opt/homebrew/bin/uv run "$_FETCH_SCRIPT" >/dev/null 2>&1 ) &
  disown 2>/dev/null
fi

usage_parts=""
if [ -f "$_USAGE_CACHE" ] && jq -e '.error != null' "$_USAGE_CACHE" >/dev/null 2>&1; then
  usage_parts="\033[33m⚠ claude.ai login${reset}"
elif [ -f "$_USAGE_CACHE" ] && jq -e '.five_hour.utilization != null' "$_USAGE_CACHE" >/dev/null 2>&1; then
  _5h_util=$(jq -r '.five_hour.utilization' "$_USAGE_CACHE")
  _5h_reset=$(jq -r '.five_hour.resets_at_epoch // 0' "$_USAGE_CACHE")
  _wk_util=$(jq -r '.seven_day.utilization // empty' "$_USAGE_CACHE")

  _5h_pct=$(jq -rn "$_5h_util | round")

  # Color-code the 5h percentage
  if [ "${_5h_pct:-0}" -lt 50 ]; then
    _uc="\033[32m"
  elif [ "${_5h_pct:-0}" -lt 75 ]; then
    _uc="\033[33m"
  else
    _uc="\033[31m"
  fi

  # Minutes until 5h window resets
  _mins_left=""
  if [ "${_5h_reset:-0}" -gt "$_now_s" ]; then
    _mins=$(( (_5h_reset - _now_s) / 60 ))
    _mins_left=" ↺${_mins}m"
  fi

  usage_parts="${_uc}${_5h_pct}%${reset}/5h${_mins_left}"

  if [ -n "$_wk_util" ]; then
    _wk_pct=$(jq -rn "$_wk_util | round")
    usage_parts="${usage_parts} · ${_wk_pct}%/wk"
  fi
fi

# ── Git ────────────────────────────────────────────────────────────────────────
git_section=""
if git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
  branch=$(git -C "$cwd" -c core.useBuiltinFSMonitor=false rev-parse --abbrev-ref HEAD 2>/dev/null | head -1)
  [ -z "$branch" ] && branch="?"
  # Truncate long branch names at 22 chars
  if [ ${#branch} -gt 22 ]; then
    branch="${branch:0:22}…"
  fi

  if git -C "$cwd" diff-index --quiet HEAD -- 2>/dev/null; then
    status_icon="✓"
  elif git -C "$cwd" diff --name-only --diff-filter=U 2>/dev/null | grep -q .; then
    status_icon="!!"
  else
    status_icon="*"
  fi

  git_section=" | ${status_icon} ${branch}"
fi

# ── Output ─────────────────────────────────────────────────────────────────────
line1="${model} · ${effort} | ${used_k}k/${usable_k}k ${pct_colored} | +${lines_added} -${lines_removed} | ${tokens_fmt} | ${duration}"
[ -n "$usage_parts" ] && line1="${line1} | ${usage_parts}"
echo -e "$line1"
echo -e "${cwd_display}${git_section}"
exit 0
