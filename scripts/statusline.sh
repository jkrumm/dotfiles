#!/bin/bash

# Claude Code Statusline — 2 line layout
#
# Line 1: Auth (MAX/IU) · Model · Effort | Context (usable) | Session tokens | Cache hit | Duration | Usage (5h/wk)
# Line 2: CWD · Git branch & dirty flag

input=$(cat)

# ── Auth mode (MAX subscription vs IU direct API) ───────────────────────────────
# `c()` exports ANTHROPIC_BASE_URL="" (Max subscription); `ca()` exports it set to
# the IU unified endpoint. Inherited live by this subprocess — no log lookup needed.
if [ -n "$ANTHROPIC_BASE_URL" ]; then
  auth_mode="IU"
else
  auth_mode="MAX"
fi

# ── One jq pass over stdin ─────────────────────────────────────────────────────
# Unit separator, not tab: tab is IFS whitespace, so `read` would collapse an
# empty field and shift every later one.
IFS=$'\x1f' read -r model effort thinking cwd context_size used_percentage \
  session_id transcript_path duration_ms \
  rl_5h rl_5h_reset rl_wk cache_requests cache_hit cache_warm rl_wk_reset < <(
  echo "$input" | jq -r '[
    .model.display_name // "Unknown",
    .effort.level // "auto",
    (.thinking.enabled | tostring),
    .workspace.current_dir // "~",
    .context_window.context_window_size // 200000,
    (.context_window.used_percentage // 0 | floor),
    .session_id // "",
    .transcript_path // "",
    (.cost.total_duration_ms // 0 | floor),
    (.rate_limits.five_hour.used_percentage // "" | if . == "" then . else round end),
    .rate_limits.five_hour.resets_at // "",
    (.rate_limits.seven_day.used_percentage // "" | if . == "" then . else round end),
    .prompt_cache.requests // 0,
    .prompt_cache.hit_ratio // "",
    (.prompt_cache.warm | tostring),
    .rate_limits.seven_day.resets_at // ""
  ] | map(tostring) | join("\u001f")'
)

# ── Claude account (docs/claude-accounts.md) ───────────────────────────────────
# `claude-account` is the one resolver, but it is a Bun process: a render only READS the small file it leaves
# per CLAUDE_CONFIG_DIR ("<id> <badge>"); it is rewritten in the background (missing file, and inside the 60 s
# usage throttle below). The badge is empty unless more than one account is enabled.
_CA_PATH="$HOME/.local/bin:/opt/homebrew/bin:$PATH"
_ca_key="${CLAUDE_CONFIG_DIR:-default}"
_ca_file="/tmp/claude_sl/account_v2_${_ca_key//\//_}"
account_id=""
account_badge=""
[ -s "$_ca_file" ] && IFS=' ' read -r account_id account_badge < "$_ca_file"

# Resolve id + badge into $_ca_file; with "record" also feeds the quota cache (args: the rate_limits flags).
_ca_resolve() {
  local id badge tmp
  id=$(PATH="$_CA_PATH" claude-account account 2>/dev/null)
  if [ -z "$id" ]; then
    rm -f "$_ca_file"   # drop the placeholder so the next render retries
    return 0
  fi
  badge=$(PATH="$_CA_PATH" claude-account account --badge 2>/dev/null)
  tmp=$(mktemp "${_ca_file}.XXXXXX") || return 0
  printf '%s %s\n' "$id" "$badge" > "$tmp" && mv "$tmp" "$_ca_file" || rm -f "$tmp"
  if [ "$1" = "record" ] && [ "$id" != "?" ]; then
    shift
    PATH="$_CA_PATH" claude-account record --account "$id" "$@" >/dev/null 2>&1
  fi
}
if [ ! -e "$_ca_file" ]; then
  mkdir -p /tmp/claude_sl
  # noclobber: only the render that wins the create resolves; the placeholder stops later renders respawning
  if ( set -o noclobber; : > "$_ca_file" ) 2>/dev/null; then
    ( _ca_resolve ) >/dev/null 2>&1 &
    disown 2>/dev/null
  fi
fi

# ── Model ──────────────────────────────────────────────────────────────────────
# Effort comes from stdin: it is per-model since 2.1.251, so settings.json's
# effortLevel is not what the session runs at.
[ "$thinking" = "false" ] && effort="${effort} ·no-think"

# ── Working directory ──────────────────────────────────────────────────────────
# Show just the project name (last path segment). For worktrees, the last segment
# is the project (wtp's layout: <repo>.worktrees/<branch>/<repo>), so basename
# collapses both regular repos and worktree checkouts to the same display.
if [ "$cwd" = "$HOME" ]; then
  cwd_display="~"
else
  cwd_display=$(basename "$cwd")
fi

# ── Context window ─────────────────────────────────────────────────────────────
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

# ── Session tokens (main loop + all subagents, cache reads excluded) ───────────
# Subagent transcripts carry the *same* sessionId as their parent (usage-tracker's
# claude-code collector relies on this — see collectors/claude-code.ts) and live
# alongside the main transcript at <project>/<sessionId>/subagents/*.jsonl. Sum
# usage across all of them for a true per-session total, not just the main loop.
# cache_read_input_tokens is the FULL accumulated prior context re-read from
# cache on *every* turn (Anthropic prompt-caching docs), so summing it across a
# transcript counts the same tokens again and again — it also doesn't count
# toward Anthropic's rate/quota limits for most models. Only input_tokens +
# output_tokens + cache_creation_input_tokens are genuinely new per turn.
tokens_fmt=""
if [ -n "$session_id" ] && [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
  subagents_dir="$(dirname "$transcript_path")/${session_id}/subagents"
  shopt -s nullglob
  sub_files=("$subagents_dir"/*.jsonl)
  shopt -u nullglob

  # Cheap size signature to skip re-parsing multi-MB transcripts on every render.
  main_size=$(stat -f%z "$transcript_path" 2>/dev/null || echo 0)
  sub_size=0
  if [ ${#sub_files[@]} -gt 0 ]; then
    sub_size=$(stat -f%z "${sub_files[@]}" 2>/dev/null | awk '{s+=$1} END{print s+0}')
  fi
  sig="${main_size}:${#sub_files[@]}:${sub_size}"

  _tok_cache_dir="/tmp/claude_sl"
  _tok_cache="${_tok_cache_dir}/tokens_${session_id}.json"
  mkdir -p "$_tok_cache_dir"

  cached_sig=""
  cached_total=""
  if [ -f "$_tok_cache" ]; then
    cached_sig=$(jq -r '.sig // empty' "$_tok_cache" 2>/dev/null)
    cached_total=$(jq -r '.total // empty' "$_tok_cache" 2>/dev/null)
  fi

  if [ "$cached_sig" = "$sig" ] && [ -n "$cached_total" ]; then
    total_tokens="$cached_total"
  else
    total_tokens=$(jq '. as $l | select($l.type=="assistant" and $l.message.usage != null) | ($l.message.usage.input_tokens // 0) + ($l.message.usage.output_tokens // 0) + ($l.message.usage.cache_creation_input_tokens // 0)' "$transcript_path" "${sub_files[@]}" 2>/dev/null | awk '{s+=$1} END{print s+0}')
    printf '{"sig":"%s","total":%d}' "$sig" "$total_tokens" > "$_tok_cache"
  fi

  if [ "$total_tokens" -ge 1000000 ]; then
    tokens_fmt=$(LC_NUMERIC=C awk "BEGIN {printf \"%.1fM\", $total_tokens/1000000}")
  elif [ "$total_tokens" -ge 1000 ]; then
    tokens_fmt=$(LC_NUMERIC=C awk "BEGIN {printf \"%.0fk\", $total_tokens/1000}")
  else
    tokens_fmt="$total_tokens"
  fi
fi

# ── Duration ───────────────────────────────────────────────────────────────────
duration_s=$((duration_ms / 1000))
hours=$((duration_s / 3600))
minutes=$(((duration_s % 3600) / 60))
if [ "$hours" -ge 1 ]; then
  duration="${hours}h ${minutes}min"
else
  duration="${minutes}min"
fi

# ── Subscription usage ─────────────────────────────────────────────────────────
# Primary: stdin `rate_limits` (Max only, present from the first API response on).
# Fallback until then: fetch_usage.py (Keychain OAuth → api.anthropic.com/api/oauth/
# usage), cached 5 min, refreshed in the background — so it only ever spawns at
# session start, and never on the IU lane, which has no subscription windows.
_USAGE_CACHE="/tmp/claude_sl/usage_api.json"
_USAGE_ACCOUNTS="/tmp/claude_sl/usage_accounts.json"   # every account, written by the same fetch_usage.py run
_FETCH_SCRIPT="$HOME/.claude/fetch_usage.py"
_now_s=$(date +%s)

_5h_pct="$rl_5h"
_5h_reset="$rl_5h_reset"
_wk_pct="$rl_wk"
usage_parts=""

if [ -z "$_5h_pct" ] && [ "$auth_mode" = "MAX" ]; then
  _fetched_at=0
  [ -f "$_USAGE_CACHE" ] && _fetched_at=$(jq -r '.fetched_at // 0' "$_USAGE_CACHE" 2>/dev/null)
  if [ $(( _now_s - ${_fetched_at:-0} )) -gt 300 ]; then
    ( /opt/homebrew/bin/uv run "$_FETCH_SCRIPT" >/dev/null 2>&1 ) &
    disown 2>/dev/null
  fi
  if [ -f "$_USAGE_CACHE" ] && jq -e '.error != null' "$_USAGE_CACHE" >/dev/null 2>&1; then
    usage_parts="\033[33m⚠ claude.ai login${reset}"
  elif [ -n "$account_id" ] && [ "$account_id" != "?" ] && [ -f "$_USAGE_ACCOUNTS" ] \
    && [ "$(jq -r '.default_account // ""' "$_USAGE_ACCOUNTS" 2>/dev/null)" != "$account_id" ]; then
    # usage_api.json only ever holds the default account: a non-default session reads its own row or shows nothing.
    IFS=$'\x1f' read -r _5h_pct _5h_reset _wk_pct < <(jq -r --arg a "$account_id" '.accounts[$a] // {} | [
      (.five_hour.utilization // "" | if . == "" then . else round end),
      .five_hour.resets_at_epoch // "",
      (.seven_day.utilization // "" | if . == "" then . else round end)
    ] | map(tostring) | join("\u001f")' "$_USAGE_ACCOUNTS" 2>/dev/null)
  elif [ -f "$_USAGE_CACHE" ]; then
    IFS=$'\x1f' read -r _5h_pct _5h_reset _wk_pct < <(jq -r '[
      (.five_hour.utilization // "" | if . == "" then . else round end),
      .five_hour.resets_at_epoch // "",
      (.seven_day.utilization // "" | if . == "" then . else round end)
    ] | map(tostring) | join("\u001f")' "$_USAGE_CACHE" 2>/dev/null)
  fi
fi

# Stdin figures also feed agent-gateway's quota view (POST /api/usage, the same body
# fetch_usage.py sends) — throttled to once a minute, fire-and-forget.
if [ -n "$rl_5h" ]; then
  _push_stamp="/tmp/claude_sl/usage_push_${_ca_key//\//_}.stamp"   # per account: one account's sessions must not starve the other's POST
  _pushed_at=$(cat "$_push_stamp" 2>/dev/null)
  if [ $(( _now_s - ${_pushed_at:-0} )) -gt 60 ]; then
    mkdir -p /tmp/claude_sl && echo "$_now_s" > "$_push_stamp"
    _mins=null
    [[ "$rl_5h_reset" =~ ^[0-9]+$ ]] && [ "$rl_5h_reset" -gt "$_now_s" ] && _mins=$(( (rl_5h_reset - _now_s) / 60 ))
    # Account: the badge's resolution (claude-account account). Unknown (not resolved yet, "?" for an unregistered
    # dir, anything off-pattern) means no POST: never guess iu.
    _acct="${account_id:-}"
    if [[ "$_acct" =~ ^[a-z][a-z0-9-]{0,15}$ ]]; then
      ( _body=$(jq -nc --arg f "$rl_5h" --arg m "$_mins" --arg w "${rl_wk:-}" --arg a "$_acct" \
          '{five_hour_pct: ($f | tonumber), five_hour_mins_left: (if $m == "null" then null else ($m | tonumber) end),
            seven_day_pct: (if $w == "" then null else ($w | tonumber) end), account: $a}' 2>/dev/null) \
        && curl -s -m 1 -X POST -H 'Content-Type: application/json' -d "$_body" http://localhost:7705/api/usage >/dev/null 2>&1 ) &
    fi
    disown 2>/dev/null
    # Same throttle: resolve the account and feed its quota sample (claude-account record, atomic).
    _rec=(--s "$rl_5h")
    [[ "$rl_5h_reset" =~ ^[0-9]+$ ]] && _rec+=(--s-reset "$rl_5h_reset")
    [ -n "$rl_wk" ] && _rec+=(--w "$rl_wk")
    [[ "$rl_wk_reset" =~ ^[0-9]+$ ]] && _rec+=(--w-reset "$rl_wk_reset")
    ( _ca_resolve record "${_rec[@]}" ) >/dev/null 2>&1 &
    disown 2>/dev/null
  fi
fi

if [ -n "$_5h_pct" ]; then
  if [ "$_5h_pct" -lt 50 ]; then
    _uc="\033[32m"
  elif [ "$_5h_pct" -lt 75 ]; then
    _uc="\033[33m"
  else
    _uc="\033[31m"
  fi

  # Minutes until the 5h window resets (epoch seconds; anything else is skipped)
  _mins_left=""
  if [[ "$_5h_reset" =~ ^[0-9]+$ ]] && [ "$_5h_reset" -gt "$_now_s" ]; then
    _mins_left=" ↺$(( (_5h_reset - _now_s) / 60 ))m"
  fi

  usage_parts="${_uc}${_5h_pct}%${reset}/5h${_mins_left}"
  [ -n "$_wk_pct" ] && usage_parts="${usage_parts} · ${_wk_pct}%/wk"
fi

# ── Prompt cache ───────────────────────────────────────────────────────────────
# Hit ratio of this session's main loop; `cold` once the TTL has lapsed, i.e. the
# next turn re-writes the whole prefix. Shown only after the first request.
cache_part=""
if [ "${cache_requests:-0}" -gt 0 ] && [ -n "$cache_hit" ]; then
  _hit=$(LC_NUMERIC=C awk -v r="$cache_hit" 'BEGIN { if (r <= 1) r *= 100; printf "%d", r + 0.5 }')
  if [ "$_hit" -ge 80 ]; then
    _cc="\033[32m"
  elif [ "$_hit" -ge 50 ]; then
    _cc="\033[33m"
  else
    _cc="\033[31m"
  fi
  cache_part="⚡${_cc}${_hit}%${reset}"
  [ "$cache_warm" = "false" ] && cache_part="${cache_part} \033[36mcold${reset}"
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
line1="${auth_mode}${account_badge:+ $account_badge} · ${model} · ${effort} | ${used_k}k/${usable_k}k ${pct_colored}"
[ -n "$tokens_fmt" ] && line1="${line1} | Σ${tokens_fmt}"
[ -n "$cache_part" ] && line1="${line1} | ${cache_part}"
line1="${line1} | ${duration}"
[ -n "$usage_parts" ] && line1="${line1} | ${usage_parts}"
echo -e "$line1"
echo -e "${cwd_display}${git_section}"
exit 0
