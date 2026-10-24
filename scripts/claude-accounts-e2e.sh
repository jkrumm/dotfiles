#!/usr/bin/env bash
# claude-accounts-e2e — manual end-to-end proof of account routing and attribution (docs/claude-accounts.md §Operate).
#   scripts/claude-accounts-e2e.sh [--subagent] [--no-run]
# Spends a few Haiku tokens per account (one `claude -p "reply ok" --model haiku` each; --subagent adds one Haiku run
# that spawns a subagent; --no-run skips the real runs and does the break tests only). Prints a pass/fail table, exits 1 on any FAIL.
#
#   real runs    each enabled account: the launcher's env construction -> claude -p -> usage-tracker ingest ->
#                usage_record rows say billing=max + the expected account, session_env says the account
#   break tests  no tokens, all against a throw-away copy of the cache dir / picks log / registry (the real
#                ones are never written); a trap removes every temp dir, so nothing needs restoring
#
# BASH 3.2.
set -u -o pipefail

DOTFILES_DIR="${DOTFILES_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REGISTRY="${CLAUDE_ACCOUNTS_REGISTRY:-$DOTFILES_DIR/config/claude-accounts.json}"
USAGE_DB="${USAGE_TRACKER_DB:-$HOME/.local/share/usage-tracker/usage.db}"
USAGE_TRACKER_DIR="${USAGE_TRACKER_DIR:-$HOME/SourceRoot/usage-tracker}"
CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude 2>/dev/null || echo "$HOME/.local/bin/claude")}"
export PATH="$HOME/.local/bin:$HOME/.bun/bin:/opt/homebrew/bin:$PATH"
CA=(bun "$DOTFILES_DIR/scripts/claude-account.ts")
WITH_SUBAGENT=0
NO_RUN=0
for arg in "$@"; do
  case "$arg" in
    --subagent) WITH_SUBAGENT=1 ;;
    --no-run) NO_RUN=1 ;;
    *) echo "usage: $(basename "$0") [--subagent] [--no-run]" >&2; exit 2 ;;
  esac
done

T=$(mktemp -d "${TMPDIR:-/tmp}/claude-accounts-e2e.XXXXXX")
trap 'rm -rf "$T"' EXIT

fails=0
printf '%-4s  %-34s %s\n' RESULT CHECK DETAIL
res() { # <ok:0|1> <check> <detail>
  if [[ "$1" == 0 ]]; then printf '%-4s  %-34s %s\n' PASS "$2" "$3"; else fails=$((fails + 1)); printf '%-4s  %-34s %s\n' FAIL "$2" "$3"; fi
}
expect() { # <check> <want> <got> [detail]
  if [[ "$2" == "$3" ]]; then res 0 "$1" "${4:-$3}"; else res 1 "$1" "want '$2', got '$3'"; fi
}

jq -e '.accounts' "$REGISTRY" >/dev/null 2>&1 || { res 1 registry "$REGISTRY unreadable"; exit 1; }
ENABLED=$(jq -r '.accounts | to_entries | sort_by(.value.dir != null) | .[] | select(.value.enabled) | .key' "$REGISTRY")
DEFAULT_ID=$(jq -r '.accounts | to_entries[] | select(.value.dir == null) | .key' "$REGISTRY")

# The launchers' env construction (config/zsh/claude.zsh _claude_launch): the picker line decides CLAUDE_CONFIG_DIR,
# a non-default account sheds credentials meant for the default one, ANTHROPIC_* stay empty (Max billing).
run_claude() { # <account id> <extra claude args...> -> JSON on stdout
  local id=$1 line; shift
  line=$("${CA[@]}" env "$id") || return 1
  (
    cd "$DOTFILES_DIR" || exit 1
    eval "$line"
    [[ "$line" == "unset CLAUDE_CONFIG_DIR" ]] || unset CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY
    ANTHROPIC_API_KEY="" ANTHROPIC_BASE_URL="" "$CLAUDE_BIN" -p "$@" --output-format json
  )
}
db() { sqlite3 "$USAGE_DB" "$1" 2>/dev/null; }

# ── real runs ──────────────────────────────────────────────────────────────────
declare_sessions=""
for id in $ENABLED; do
  (( NO_RUN )) && break
  out=$(run_claude "$id" "reply ok" --model haiku 2>"$T/$id.err") || out=""
  sid=$(jq -r '.session_id // empty' <<<"$out" 2>/dev/null)
  if [[ -z "$sid" ]]; then res 1 "run/$id" "no session_id from claude -p: $(head -c 200 "$T/$id.err")$(head -c 200 <<<"$out")"; continue; fi
  res 0 "run/$id" "session $sid"
  declare_sessions="$declare_sessions $id:$sid"
  if (( WITH_SUBAGENT )) && [[ "$id" != "$DEFAULT_ID" ]]; then
    sub=$(CLAUDE_CODE_SUBAGENT_MODEL=haiku run_claude "$id" "Use the Task tool to start a general-purpose subagent that replies with the single word ok. Then reply ok." --model haiku 2>/dev/null) || sub=""
    ssid=$(jq -r '.session_id // empty' <<<"$sub" 2>/dev/null)
    [[ -n "$ssid" ]] && declare_sessions="$declare_sessions $id/subagent:$ssid" || res 1 "run/$id/subagent" "no session_id"
  fi
done

if [[ -n "$declare_sessions" ]]; then
  if (cd "$USAGE_TRACKER_DIR" && bun run src/cli.ts ingest >"$T/ingest.log" 2>&1); then
    res 0 ingest "usage-tracker ingest ok"
  else
    res 1 ingest "usage-tracker ingest failed: $(tail -n 3 "$T/ingest.log" | tr '\n' ' ')"
  fi
  for pair in $declare_sessions; do
    label=${pair%%:*}; sid=${pair#*:}; id=${label%%/*}
    n=$(db "select count(*) from usage_record where json_extract(raw,'\$.sessionId')='$sid';")
    if [[ -z "$n" || "$n" == 0 ]]; then res 1 "usage_record/$label" "no rows for session $sid"; continue; fi
    wrong=$(db "select count(*) from usage_record where json_extract(raw,'\$.sessionId')='$sid' and (billing != 'max' or account is not '$id');")
    expect "usage_record/$label" 0 "$wrong" "$n row(s), all billing=max account=$id"
    se=$(db "select account from session_env where session='$sid';")
    expect "session_env/$label" "$id" "$se" "session_env account=$id"
  done
fi

# ── break tests (no tokens, isolated state) ────────────────────────────────────
mkdir -p "$T/cache"
[[ -d "${CLAUDE_ACCOUNTS_CACHE_DIR:-$HOME/.cache/claude-accounts}" ]] && cp -R "${CLAUDE_ACCOUNTS_CACHE_DIR:-$HOME/.cache/claude-accounts}/." "$T/cache/" 2>/dev/null
rm -f "$T"/cache/*.refresh.claim "$T"/cache/*.exhausted.json "$T"/cache/*.auth.json
CAENV=(env CLAUDE_ACCOUNTS_CACHE_DIR="$T/cache" CLAUDE_ACCOUNTS_PICKS="$T/picks.jsonl")
for id in $ENABLED; do "${CAENV[@]}" "${CA[@]}" record --account "$id" --s 1 --w 1 || res 1 "setup/$id" "cannot seed a fresh sample"; done # fresh samples: a pick never refreshes
last_pick() { tail -n 1 "$T/picks.jsonl" | jq -r "\"\(.picked) \(.reason)\""; }

OTHER=$(printf '%s\n' $ENABLED | grep -vx "$DEFAULT_ID" | head -1)
if [[ -z "$OTHER" ]]; then
  res 1 "break/exhausted" "no second enabled account in the registry"
else
  out=$("${CAENV[@]}" "${CA[@]}" pick --lane wave); expect "break/wave-home" "$OTHER home" "$(last_pick)" "wave -> $OTHER (home)"
  "${CAENV[@]}" "${CA[@]}" exhausted --account "$OTHER" --until $(( $(date +%s) + 3600 ))
  out=$("${CAENV[@]}" "${CA[@]}" pick --lane wave); expect "break/exhausted-spill" "$DEFAULT_ID spill" "$(last_pick)" "$OTHER exhausted -> wave picks $DEFAULT_ID (spill), $out"
  rm -f "$T/cache/$OTHER.exhausted.json"
  out=$("${CAENV[@]}" "${CA[@]}" pick --lane wave); expect "break/mark-removed" "$OTHER home" "$(last_pick)" "mark removed -> wave back on $OTHER"
fi

# unregistered CLAUDE_CONFIG_DIR: no account, and the SessionStart hook logs null (run under a throw-away HOME)
mkdir -p "$T/home"
acct=$(CLAUDE_CONFIG_DIR="$T/unregistered" "${CA[@]}" account)
expect "break/unregistered-dir" "?" "$acct" "claude-account account -> ?"
echo '{"session_id":"e2e-unregistered","hook_event_name":"SessionStart"}' | HOME="$T/home" CLAUDE_CONFIG_DIR="$T/unregistered" bun "$DOTFILES_DIR/hooks/session-env.ts" >/dev/null 2>&1
logged=$(cat "$T"/home/.claude/logs/*.jsonl 2>/dev/null | jq -c 'select(.event=="session_env") | .data | if has("account") and .account == null then "null" else "other" end' | tail -n 1)
expect "break/hook-null" '"null"' "$logged" "session-env hook logs account null"

# registry moved away: the pick still answers (iu), exit 4, never silently
rc=0; out=$(CLAUDE_ACCOUNTS_REGISTRY="$T/no-such-registry.json" "${CA[@]}" pick --lane wave 2>/dev/null) || rc=$?
expect "break/registry-missing" "4 unset CLAUDE_CONFIG_DIR" "$rc $out" "pick exit 4 + unset"

# a me login that does not exist: a config dir with no credentials (its Keychain service has no entry; the real keychain is never touched)
if [[ -n "$OTHER" ]]; then
  mkdir -p "$T/nologin"
  jq --arg id "$OTHER" --arg d "$T/nologin" '.accounts[$id].dir = $d' "$REGISTRY" > "$T/registry-nologin.json"
  st=$(env -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_API_KEY CLAUDE_CONFIG_DIR="$T/nologin" USER="${USER:-$(id -un)}" "$CLAUDE_BIN" auth status 2>/dev/null | jq -r '.loggedIn // false')
  expect "break/no-login-status" false "$st" "claude auth status in a credential-less dir: loggedIn=false"
  rm -f "$T/cache/$OTHER".*.json
  NL=(env CLAUDE_ACCOUNTS_REGISTRY="$T/registry-nologin.json" CLAUDE_ACCOUNTS_CACHE_DIR="$T/cache" CLAUDE_ACCOUNTS_PICKS="$T/picks.jsonl")
  "${NL[@]}" "${CA[@]}" refresh --ids "$OTHER" >/dev/null 2>&1
  "${NL[@]}" "${CA[@]}" pick --lane wave >/dev/null 2>&1
  expect "break/no-login-ineligible" "$DEFAULT_ID spill" "$(last_pick)" "$OTHER without a login is never picked; wave goes to $DEFAULT_ID"
  usage=$("${NL[@]}" "${CA[@]}" usage --json | jq -r --arg id "$OTHER" '.accounts[] | select(.id == $id) | .auth_ok')
  expect "break/no-login-auth-mark" false "$usage" "refresh marked $OTHER auth failed"
fi

# subagents run inside the parent process and inherit its account: the --subagent run above asserts every row
# of that session (subagent messages included) carries the parent's account
(( WITH_SUBAGENT )) || printf '%-4s  %-34s %s\n' SKIP subagent-inherit "run with --subagent to assert it (one extra Haiku run)"

echo "---"
(( fails == 0 )) && echo "all passed" || echo "$fails FAILED"
(( fails == 0 ))
