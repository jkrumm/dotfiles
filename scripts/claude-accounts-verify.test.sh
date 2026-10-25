#!/usr/bin/env bash
# claude-accounts-verify.test.sh — the login/<id> rows of claude-accounts-verify.sh, graded from fixture answers of
# `claude-account expiry --json` (a stub script in a scratch DOTFILES_DIR). Only the login/* rows are asserted: the
# rest of the suite runs against the scratch setup and may FAIL there, which is irrelevant here.
# Usage: scripts/claude-accounts-verify.test.sh   (exit 0 = all pass)
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0; fail=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; [[ -n "${2:-}" ]] && printf '         %s\n' "$2"; fail=$((fail + 1)); }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }

command -v bun >/dev/null && command -v jq >/dev/null || { echo "✗ bun and jq are required"; exit 2; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/verify-test.XXXXXX")" || exit 2
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/dot/scripts" "$TMP/dot/config" "$TMP/bin"
cat > "$TMP/registry.json" <<JSON
{"accounts":{
 "iu":{"dir":null,"plan":"x","units":{"session":1,"weekly":1},"homeLanes":[],"enabled":true},
 "pass":{"dir":"$TMP/d1","plan":"x","units":{"session":1,"weekly":1},"homeLanes":[],"enabled":true},
 "warn":{"dir":"$TMP/d2","plan":"x","units":{"session":1,"weekly":1},"homeLanes":[],"enabled":true},
 "fail":{"dir":"$TMP/d3","plan":"x","units":{"session":1,"weekly":1},"homeLanes":[],"enabled":true},
 "unread":{"dir":"$TMP/d4","plan":"x","units":{"session":1,"weekly":1},"homeLanes":[],"enabled":true},
 "silent":{"dir":"$TMP/d5","plan":"x","units":{"session":1,"weekly":1},"homeLanes":[],"enabled":true}}}
JSON
# the stub answers `expiry --json` with fixtures (nothing for "silent"); every other subcommand fails like an unreadable setup.
# severity is what claude-account computes: the grade, but a non-default account never exceeds WARN.
cat > "$TMP/dot/scripts/claude-account.ts" <<'TS'
if (process.argv[2] === "expiry") {
  console.log(JSON.stringify({ accounts: [
    { id: "iu", default: true, grade: process.env.IU_SEV ?? "PASS", severity: process.env.IU_SEV ?? "PASS", detail: "login valid until 2026-11-20 (20 d left)" },
    { id: "pass", default: false, grade: "PASS", severity: "PASS", detail: "login valid (9 d left)" },
    { id: "warn", default: false, grade: "WARN", severity: "WARN", detail: "login valid (5 d left)" },
    { id: "fail", default: false, grade: "FAIL", severity: "WARN", detail: "login expired" },
    { id: "unread", default: false, grade: "WARN", severity: "WARN", detail: "login expiry unreadable (Keychain)" },
  ] }))
} else process.exit(1)
TS
printf '#!/bin/sh\necho "{\\"loggedIn\\": false}"\n' > "$TMP/bin/claude"; chmod +x "$TMP/bin/claude"

verify() { # [env…] — the verify script against the scratch setup
  env "$@" DOTFILES_DIR="$TMP/dot" CLAUDE_ACCOUNTS_REGISTRY="$TMP/registry.json" CLAUDE_BIN="$TMP/bin/claude" CLAUDE_ACCOUNTS_STATE_DIR="$TMP/state" CLAUDE_ACCOUNTS_CACHE_DIR="$TMP/cache" \
    USAGE_TRACKER_DB="$TMP/none.db" AGW_SESSION_RUNNER="$TMP/none.ts" RD_SCRIPT="$TMP/none.sh" CLAUDE_LOG_DIR="$TMP/logs" bash "$HERE/claude-accounts-verify.sh" 2>&1
}
out=$(verify IU_SEV=PASS)
row() { grep -E "^(PASS|WARN|FAIL) +login/$1 " <<<"$out" | awk '{print $1}'; }
assert_eq "login/iu: > 7 d is PASS" PASS "$(row iu)"
assert_eq "login/pass: PASS" PASS "$(row pass)"
assert_eq "login/warn: <= 7 d is WARN" WARN "$(row warn)"
assert_eq "login/fail: a non-default account past its end is capped at WARN, like auth/<id>" WARN "$(row fail)"
assert_eq "login/unread: unreadable item is WARN, not FAIL" WARN "$(row unread)"
assert_eq "login/silent: no answer for the account is WARN" WARN "$(row silent)"
out_fail=$(verify IU_SEV=FAIL)
assert_eq "login/iu: the default account keeps FAIL, like auth/iu" FAIL "$(grep -E '^(PASS|WARN|FAIL) +login/iu ' <<<"$out_fail" | awk '{print $1}')"
assert_eq "one row per enabled account" 6 "$(grep -cE '^(PASS|WARN|FAIL) +login/' <<<"$out")"

echo
if (( fail )); then printf '\033[31m%d failed\033[0m, %d passed\n' "$fail" "$pass"; exit 1; fi
printf '\033[32mall %d passed\033[0m\n' "$pass"
