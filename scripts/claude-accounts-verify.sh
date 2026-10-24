#!/usr/bin/env bash
# claude-accounts-verify — read-only proof that every launcher and spawner lands on the intended Claude
# account with correct attribution (docs/claude-accounts.md §Operate). One line per check:
#   PASS|WARN|FAIL  <check>  <detail>
# Exit 1 on any FAIL, WARN allowed. Spends no tokens and writes nothing: recording the verified Claude Code
# version is `make claude-accounts-stamp`. `make claude-accounts-verify`, also run by `make doctor`.
#
# BASH 3.2 (no associative arrays, no mapfile): doctor.sh and the heartbeat run it under Apple's bash.
set -u -o pipefail

DOTFILES_DIR="${DOTFILES_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REGISTRY="${CLAUDE_ACCOUNTS_REGISTRY:-$DOTFILES_DIR/config/claude-accounts.json}"
CACHE_DIR="${CLAUDE_ACCOUNTS_CACHE_DIR:-$HOME/.cache/claude-accounts}"
STATE_DIR="${CLAUDE_ACCOUNTS_STATE_DIR:-$HOME/.local/state/claude-accounts}"
LOG_DIR="${CLAUDE_LOG_DIR:-$HOME/.claude/logs}"
USAGE_DB="${USAGE_TRACKER_DB:-$HOME/.local/share/usage-tracker/usage.db}"
RD_SCRIPT="${RD_SCRIPT:-$DOTFILES_DIR/scripts/remote-dev.sh}"
AGW_SESSION_RUNNER="${AGW_SESSION_RUNNER:-$HOME/SourceRoot/agent-gateway/server/mcp/session-runner.ts}"
CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude 2>/dev/null || echo "$HOME/.local/bin/claude")}"
export PATH="$HOME/.local/bin:$HOME/.bun/bin:/opt/homebrew/bin:$PATH"

fails=0
warns=0
row() { # <PASS|WARN|FAIL> <check> <detail>
  case "$1" in FAIL) fails=$((fails + 1)) ;; WARN) warns=$((warns + 1)) ;; esac
  printf '%-4s  %-26s %s\n' "$1" "$2" "$3"
}

command -v jq >/dev/null 2>&1 || { echo "FAIL  prerequisites            jq not found"; exit 1; }
command -v bun >/dev/null 2>&1 || { echo "FAIL  prerequisites            bun not found"; exit 1; }
[[ -r "$REGISTRY" ]] || { echo "FAIL  registry                $REGISTRY unreadable"; exit 1; }
jq -e '.accounts' "$REGISTRY" >/dev/null 2>&1 || { echo "FAIL  registry                $REGISTRY unparsable"; exit 1; }
CA=(bun "$DOTFILES_DIR/scripts/claude-account.ts")

# id<TAB>abs dir ("-" = default ~/.claude, env unset) for every enabled account, default first.
ACCOUNTS=$(jq -r '.accounts | to_entries | sort_by(.value.dir != null) | .[] | select(.value.enabled) | "\(.key)\t\(.value.dir // "-")"' "$REGISTRY")
IDS=$(printf '%s\n' "$ACCOUNTS" | cut -f1)
now_s=$(date +%s)
since_iso=$(date -u -r $((now_s - 86400)) +%Y-%m-%dT%H:%M:%S 2>/dev/null)

# ── a. binary / keychain contract ─────────────────────────────────────────────
while IFS=$'\t' read -r id dir; do
  [[ -n "$id" ]] || continue
  if [[ "$dir" == "-" ]]; then
    want_dir="$HOME/.claude"; svc="Claude Code-credentials"
    out=$(env -u CLAUDE_CONFIG_DIR -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_API_KEY USER="${USER:-$(id -un)}" "$CLAUDE_BIN" auth status 2>/dev/null) || out=""
    bad=FAIL
  else
    want_dir="${dir/#\~/$HOME}"
    svc="Claude Code-credentials-$(printf %s "$want_dir" | shasum -a 256 | cut -c1-8)"
    out=$(env -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_API_KEY CLAUDE_CONFIG_DIR="$want_dir" USER="${USER:-$(id -un)}" "$CLAUDE_BIN" auth status 2>/dev/null) || out=""
    bad=WARN # a dead non-default login is routed around by the picker (heartbeat grades it the same way)
  fi
  logged=$(jq -r '.loggedIn // false' <<<"$out" 2>/dev/null) || logged=false
  cfg=$(jq -r '.configDirectory // ""' <<<"$out" 2>/dev/null) || cfg=""
  kc=missing
  security find-generic-password -s "$svc" >/dev/null 2>&1 && kc=present
  if [[ "$logged" == "true" && "$cfg" != "$want_dir" ]]; then
    row FAIL "auth/$id" "configDirectory '$cfg', expected '$want_dir' (Claude Code changed config-dir resolution)"
  elif [[ "$logged" == "true" && "$kc" == "missing" ]]; then
    row FAIL "auth/$id" "logged in but keychain service '$svc' missing — Claude Code changed credential naming"
  elif [[ "$logged" == "true" ]]; then
    row PASS "auth/$id" "loggedIn, configDirectory $want_dir, keychain '$svc' present"
  else
    row "$bad" "auth/$id" "NOT logged in (keychain '$svc' $kc) — /login with ${dir/#-/CLAUDE_CONFIG_DIR unset} in a herdr pane"
  fi
done <<<"$ACCOUNTS"

# ── b. quota contract ──────────────────────────────────────────────────────────
log_files() { # today's and yesterday's JSONL logs, whichever exist
  local d f
  for d in "$(date +%F)" "$(date -v-1d +%F 2>/dev/null || date -d yesterday +%F 2>/dev/null)"; do
    f="$LOG_DIR/$d.jsonl"; [[ -f "$f" ]] && echo "$f"
  done
}
session_env_24h() { # session_env lines of the last 24 h, one JSON per line
  local f
  while IFS= read -r f; do
    jq -c --arg since "$since_iso" 'select(.event == "session_env" and (.ts[0:19] >= $since))' "$f" 2>/dev/null
  done < <(log_files)
}
SE=$(session_env_24h)

while IFS=$'\t' read -r id dir; do
  [[ -n "$id" ]] || continue
  if [[ "$dir" == "-" ]]; then cj="$HOME/.claude.json"; else cj="${dir/#\~/$HOME}/.claude.json"; fi
  cu=$(jq -c '.cachedUsageUtilization // empty' "$cj" 2>/dev/null) || cu=""
  if [[ -z "$cu" ]]; then
    row WARN "quota/$id" "no cachedUsageUtilization in $cj yet (fix: claude-account refresh --ids $id)"
  else
    miss=$(jq -r '[ (if (.fetchedAtMs|type) == "number" then empty else "fetchedAtMs" end),
      (.utilization // {} | to_entries | map(select(.key == "five_hour" or .key == "seven_day")) | map(.key)) as $have
      | ("five_hour","seven_day") as $w
      | (if ($have | index($w)) == null then "utilization.\($w)" else empty end) ] | join(", ")' <<<"$cu" 2>/dev/null)
    shape=$(jq -r '[("five_hour","seven_day") as $w | .utilization[$w] // {} |
      (if (.utilization|type) == "number" and (.resets_at|type) == "string" then empty else "bad" end)] | length' <<<"$cu" 2>/dev/null)
    if [[ -n "$miss" || "$shape" != "0" ]]; then
      row FAIL "quota/$id" "cachedUsageUtilization lost its shape (${miss:-five_hour/seven_day need utilization+resets_at}) — Claude Code renamed the field"
    else
      age=$(jq -r --argjson now "$((now_s * 1000))" '((($now - .fetchedAtMs) / 60000) | floor)' <<<"$cu")
      row PASS "quota/$id" "five_hour/seven_day utilization+resets_at present (fetched ${age} min ago)"
    fi
  fi
  stamp="$CACHE_DIR/$id.statusline.json"
  ts=$(jq -r '.ts // 0' "$stamp" 2>/dev/null) || ts=0
  ran=$(jq -r --arg id "$id" 'select(.src == "hook" and .data.account == $id) | .data.session' <<<"$SE" 2>/dev/null | wc -l | tr -d ' ')
  if (( ts / 1000 >= now_s - 86400 )); then
    row PASS "statusline/$id" "fed the quota cache $(( (now_s - ts / 1000) / 60 )) min ago"
  elif (( ran > 0 )); then
    row WARN "statusline/$id" "no statusline sample in 24 h but $ran session(s) ran — statusline.sh not feeding claude-account record?"
  else
    row PASS "statusline/$id" "no sessions in 24 h, no statusline sample expected"
  fi
done <<<"$ACCOUNTS"

# ── c. launcher matrix (static) ────────────────────────────────────────────────
# An interactive zsh loads the whole user config: bound it (perl alarm survives exec), a hang is a FAIL row.
fn_rc=0
FN=$(perl -e 'alarm 10; exec @ARGV' zsh -ic 'functions c cs cf claude _claude_launch _claude_account_line _claude_enter_account ca cap cdf cdp claude_iu' 2>/dev/null) || fn_rc=$?
fn_body() { # <name> — body of one zsh function from the dump
  awk -v n="$1" '$0 ~ "^" n " \\(\\) \\{" {p=1} p {print} p && /^}/ {exit}' <<<"$FN"
}
if (( fn_rc == 142 )); then
  row FAIL "launchers" "zsh -ic 'functions …' timed out after 10 s (a hanging shell startup)"
elif [[ -z "$FN" ]]; then
  row FAIL "launchers" "zsh -ic 'functions …' printed nothing (rc $fn_rc; config/zsh not loaded?)"
else
  for f in c cs cf; do
    if fn_body "$f" | grep -q '_claude_launch'; then
      row PASS "launcher/$f" "-> _claude_launch"
    else
      row FAIL "launcher/$f" "does not call _claude_launch (the picker path)"
    fi
  done
  if fn_body _claude_launch | grep -q '_claude_account_line' && fn_body _claude_account_line | grep -q 'claude-account pick --lane'; then
    row PASS "launcher/picker" "_claude_launch -> _claude_account_line -> claude-account pick --lane (interactive)"
  else
    row FAIL "launcher/picker" "_claude_launch no longer reaches 'claude-account pick --lane'"
  fi
  # bare `claude` (what herdr types into a pane): one function that picks on ${USAGE_LANE:-interactive} unless
  # CLAUDE_ACCOUNT_PICKED is set, and every chooser sets that marker.
  if fn_body claude | grep -q '_claude_account_line' && fn_body claude | grep -q 'CLAUDE_ACCOUNT_PICKED' && fn_body claude | grep -q 'USAGE_LANE'; then
    row PASS "launcher/claude" "bare claude picks on \${USAGE_LANE:-interactive} unless CLAUDE_ACCOUNT_PICKED is set"
  else
    row FAIL "launcher/claude" "the claude function no longer picks (herdr agent start would land on iu) or ignores the marker"
  fi
  if fn_body _claude_enter_account | grep -q 'CLAUDE_ACCOUNT_PICKED' && fn_body _claude_launch | grep -q '_claude_enter_account'; then
    row PASS "launcher/marker" "c/cs/cf set CLAUDE_ACCOUNT_PICKED (no double pick)"
  else
    row FAIL "launcher/marker" "_claude_launch no longer sets CLAUDE_ACCOUNT_PICKED — bare claude would pick a second time"
  fi
  for f in ca cap cdf cdp; do
    if [[ -n "$(fn_body "$f")" ]]; then row FAIL "launcher/$f" "retired IU-billed launcher is back: Herdr development is Max-only"; fi
  done
  for f in claude_iu; do
    body=$(fn_body "$f")
    if [[ -z "$body" ]]; then
      row FAIL "launcher/$f" "function not found"
    elif grep -q 'CLAUDE_CONFIG_DIR' <<<"$body"; then
      row FAIL "launcher/$f" "touches CLAUDE_CONFIG_DIR — IU-endpoint launchers must stay account-agnostic"
    elif ! grep -q 'ANTHROPIC_BASE_URL' <<<"$body"; then
      row FAIL "launcher/$f" "no longer sets the IU ANTHROPIC_BASE_URL"
    else
      row PASS "launcher/$f" "never sets CLAUDE_CONFIG_DIR, keeps IU env"
    fi
  done
fi
if [[ -r "$RD_SCRIPT" ]]; then
  for lane in wave fan; do
    if grep -q "pick_account $lane" "$RD_SCRIPT"; then
      row PASS "launcher/rd-$lane" "remote-dev.sh calls pick_account $lane"
    else
      row FAIL "launcher/rd-$lane" "remote-dev.sh no longer calls pick_account $lane"
    fi
  done
  if grep -q "CLAUDE_ACCOUNT_PICKED=" "$RD_SCRIPT"; then
    row PASS "launcher/rd-marker" "remote-dev.sh passes CLAUDE_ACCOUNT_PICKED to its panes (herdr --env)"
  else
    row FAIL "launcher/rd-marker" "remote-dev.sh no longer passes CLAUDE_ACCOUNT_PICKED — an rd pane would pick twice"
  fi
else
  row FAIL "launcher/rd" "$RD_SCRIPT unreadable"
fi
if [[ -r "$AGW_SESSION_RUNNER" ]]; then
  if grep -q 'claude-account pick' "$AGW_SESSION_RUNNER"; then
    row PASS "launcher/agent-gateway" "session-runner.ts calls claude-account pick"
  else
    row FAIL "launcher/agent-gateway" "session-runner.ts has no 'claude-account pick' — workers inherit the default account"
  fi
else
  row WARN "launcher/agent-gateway" "$AGW_SESSION_RUNNER not found (agent-gateway not on this machine)"
fi

# ── d. pick table (dry: no picks.jsonl line, no refresh) ──────────────────────
for lane in interactive wave fan agent-gateway:review agent-gateway:dispatch headless; do
  rc=0
  out=$("${CA[@]}" pick --lane "$lane" --dry --why 2>/dev/null) || rc=$?
  why=$(grep '^# ' <<<"$out" | head -1)
  if (( rc != 0 && rc != 3 )); then
    row FAIL "pick/$lane" "claude-account pick exited $rc"
    continue
  fi
  picked=$(sed -n 's/.*picked=\([^ ]*\).*/\1/p' <<<"$why"); reason=$(sed -n 's/.*reason=\([^ ]*\).*/\1/p' <<<"$why")
  if [[ -z "$picked" ]]; then
    row FAIL "pick/$lane" "no '# picked=… reason=…' line"
  elif [[ "$picked" == spill ]]; then
    row PASS "pick/$lane" "spill ($reason) -> caller's IU path"
  else
    row PASS "pick/$lane" "$picked ($reason)"
  fi
done

# ── e. attribution (last 24 h) ─────────────────────────────────────────────────
# Claude Code sessions are the hook lines (and any agent-gateway line on a Max backend); agent-gateway's
# opencode/IU lines are metered, they have no Max account to carry.
if [[ -z "$SE" ]]; then
  row WARN "attribution/session_env" "no session_env lines in the last 24 h"
else
  total=$(jq -s '[.[] | select(.src == "hook" or .data.backend == "max")] | length' <<<"$SE")
  idlist=$(printf '%s\n' "$IDS" | jq -R . | jq -s .)
  nulls=$(jq -s --argjson ids "$idlist" '[.[] | select(.src == "hook" or .data.backend == "max") | select((.data.account // null) == null)] | length' <<<"$SE")
  unknown=$(jq -s --argjson ids "$idlist" '[.[] | select(.src == "hook" or .data.backend == "max") | select(.data.account != null and ((.data.account) as $a | $ids | index($a)) == null)] | length' <<<"$SE")
  last_bad=$(jq -s -r --argjson ids "$idlist" '[.[] | select(.src == "hook" or .data.backend == "max") | select((.data.account // null) == null or (((.data.account) as $a | $ids | index($a)) == null))] | map(.ts) | max // ""' <<<"$SE")
  last_null=$(jq -s -r '[.[] | select(.src == "hook" or .data.backend == "max") | select((.data.account // null) == null) | .ts] | max // ""' <<<"$SE")
  if (( nulls > 0 )); then
    row FAIL "attribution/session_env" "$nulls of $total Claude session_env line(s) carry no account (newest $last_null; lines from before the account field shipped age out within 24 h)"
  elif (( unknown > 0 )); then
    row WARN "attribution/session_env" "$unknown of $total line(s) carry an unregistered account id (legacy ids age out in 24 h; newest $last_bad)"
  else
    row PASS "attribution/session_env" "all $total Claude session_env lines carry a registered account"
  fi
fi
if [[ -z "${USAGE_TRACKER_DB:-}" && ! -d "$HOME/SourceRoot/usage-tracker" ]]; then
  row WARN "attribution/usage-db" "usage-tracker not on this machine (the mini ingests; its mirror reads this machine's logs)"
elif [[ ! -r "$USAGE_DB" ]] || ! command -v sqlite3 >/dev/null 2>&1; then
  row WARN "attribution/usage-db" "usage-tracker DB or sqlite3 not available"
else
  cutoff=$(date -u -r $((now_s - 86400)) +%Y-%m-%dT%H:%M:%S)
  orphan=$(sqlite3 "$USAGE_DB" "select count(*) from usage_record where billing='max' and account is null and ts >= '$cutoff';" 2>/dev/null) || orphan=""
  if [[ -z "$orphan" ]]; then
    row FAIL "attribution/usage-db" "usage_record.account column unreadable (schema changed?)"
  elif (( orphan > 0 )); then
    row FAIL "attribution/usage-db" "$orphan billing='max' usage_record row(s) in the last 24 h have no account (run usage-tracker ingest; else the collector lost the join)"
  else
    row PASS "attribution/usage-db" "no billing='max' row without an account in the last 24 h"
  fi
  while IFS= read -r id; do
    [[ -n "$id" && "$id" != "$(jq -r '.accounts | to_entries[] | select(.value.dir == null) | .key' "$REGISTRY")" ]] || continue
    seen=$(jq -s --arg id "$id" '[.[] | select(.data.account == $id)] | length' <<<"$SE" 2>/dev/null) || seen=0
    (( seen > 0 )) || continue
    have=$(sqlite3 "$USAGE_DB" "select count(*) from usage_record where account='$id';" 2>/dev/null) || have=0
    first=$(jq -s -r --arg id "$id" '[.[] | select(.data.account == $id) | .ts] | min' <<<"$SE")
    first_s=$(date -u -j -f %Y-%m-%dT%H:%M:%S "${first:0:19}" +%s 2>/dev/null) || first_s=$now_s
    if (( have > 0 )); then
      row PASS "attribution/$id-rows" "session_env has $seen $id line(s); usage_record has $have row(s) with account='$id'"
    elif (( now_s - first_s < 7200 )); then
      row WARN "attribution/$id-rows" "$seen $id session_env line(s), first under 2 h ago; no usage_record row yet (ingest lag, FAIL after 2 h)"
    else
      row FAIL "attribution/$id-rows" "$seen $id session_env line(s) but no usage_record row with account='$id' (ingest, or the join is broken)"
    fi
  done <<<"$IDS"
fi

# ── f. Claude Code version (read-only: `make claude-accounts-stamp` records it) ─
ver=$("$CLAUDE_BIN" --version 2>/dev/null | awk '{print $1}') || ver=""
prev=$(cat "$STATE_DIR/verified-version" 2>/dev/null || true)
if [[ -z "$ver" ]]; then
  row FAIL "version" "claude --version printed nothing"
elif [[ "$prev" == "$ver" ]]; then
  row PASS "version" "$ver is the stamped version"
elif (( fails > 0 )); then
  row WARN "version" "$ver is not stamped (last stamped: ${prev:-never}); fix the FAIL rows, then make claude-accounts-stamp"
else
  row WARN "version" "$ver is not stamped (last stamped: ${prev:-never}); run make claude-accounts-stamp"
fi

echo "---"
echo "$fails FAIL, $warns WARN"
(( fails == 0 ))
