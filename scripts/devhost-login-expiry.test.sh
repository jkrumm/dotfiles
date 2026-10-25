#!/usr/bin/env bash
# devhost-login-expiry.test.sh — check_claude_auth's login-expiry grading in the heartbeat (devhost-health-check.sh),
# with stub claude / claude-account / secrets-run binaries and a scratch registry. The functions are cut out of the
# script (it runs its whole main at load), so nothing else of the heartbeat executes.
# Usage: scripts/devhost-login-expiry.test.sh   (exit 0 = all pass)
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0; fail=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; [[ -n "${2:-}" ]] && printf '         %s\n' "$2"; fail=$((fail + 1)); }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
assert_contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "[$3] does not contain [$2]" ;; esac; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/devhost-login-test.XXXXXX")" || exit 2
trap 'rm -rf "$TMP"' EXIT
sed -n '/^claude_token_works()/,/^# Claude Code auto-updates/p' "$HERE/devhost-health-check.sh" > "$TMP/fn.sh"
[[ -s "$TMP/fn.sh" ]] || { echo "✗ could not cut the functions out of devhost-health-check.sh"; exit 2; }
echo '{"accounts":{"iu":{"dir":null,"enabled":true},"me":{"dir":"~/.claude-me","enabled":true}}}' > "$TMP/registry.json"

# claude: logged in when CLAUDE_CONFIG_DIR is set (extra account) or the cached token is injected; the default
# keychain login is dead when STUB_IU_DEAD=1
cat > "$TMP/claude" <<'STUB'
#!/bin/sh
ok() { echo '{"loggedIn":true,"subscriptionType":"max"}'; }
if [ -n "${CLAUDE_CONFIG_DIR:-}" ] || [ "${STUB_IU_DEAD:-0}" != 1 ]; then ok
elif [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ "${STUB_TOKEN_DEAD:-0}" != 1 ]; then ok
else echo '{"loggedIn":false}'
fi
STUB
printf '#!/bin/sh\necho cached-token\n' > "$TMP/secrets-run"
cat > "$TMP/ca" <<'STUB'
#!/bin/sh
echo "$CLAUDE_ACCOUNTS_REGISTRY" > "$TMP_DIR/registry-seen"
case "${STUB_CA:-ok}" in
  fail) exit 1 ;;
  garbage) echo "not json" ;;
  nolist) echo '{"x":1}' ;;
  ok) echo '{"accounts":[{"id":"iu","severity":"PASS","detail":"login valid"},{"id":"me","severity":"PASS","detail":"login valid"}]}' ;;
  me-warn) echo '{"accounts":[{"id":"iu","severity":"PASS","detail":"ok"},{"id":"me","grade":"FAIL","severity":"WARN","detail":"login valid until 2026-10-30 (1 d left)"}]}' ;;
  iu-expired) echo '{"accounts":[{"id":"iu","default":true,"grade":"FAIL","severity":"FAIL","expired":true,"detail":"login expired 2026-10-01"},{"id":"me","severity":"PASS","detail":"ok"}]}' ;;
esac
STUB
chmod +x "$TMP/claude" "$TMP/secrets-run" "$TMP/ca"
export TMP_DIR="$TMP"

grade() { # <case> [env…] -> "rc|message" and stderr in $TMP/err
  local c=$1; shift
  env -u CLAUDE_CONFIG_DIR -u CLAUDE_CODE_OAUTH_TOKEN -u CLAUDE_ACCOUNT_PICKED "$@" STUB_CA="$c" bash -c '
    JQ_BIN=/usr/bin/jq; CLAUDE_BIN="${T_CLAUDE_BIN:-'"$TMP"'/claude}"; CLAUDE_ACCOUNT_BIN="${T_CA_BIN:-'"$TMP"'/ca}"
    CLAUDE_ACCOUNTS_REGISTRY='"$TMP"'/registry.json; SECRETS_RUN_BIN='"$TMP"'/secrets-run
    source '"$TMP"'/fn.sh
    rc=0; msg=$(check_claude_auth) || rc=$?; echo "$rc|$msg"' 2>"$TMP/err"
}

echo "the check could not run: WARN, never PASS, never FAIL, reason logged"
out=$(grade ok); assert_eq "healthy logins: rc 0" "0" "${out%%|*}"
assert_eq "registry is passed through to claude-account" "$TMP/registry.json" "$(cat "$TMP/registry-seen")"
out=$(grade fail); assert_eq "helper exits non-zero: rc 2" "2" "${out%%|*}"
assert_contains "...named in the message" "login expiry check could not run (claude-account expiry failed)" "$out"
assert_contains "...and logged" "claude-account expiry failed" "$(cat "$TMP/err")"
out=$(grade garbage); assert_eq "non-JSON answer: rc 2" "2" "${out%%|*}"
assert_contains "...named" "could not run (claude-account expiry gave no account list)" "$out"
out=$(grade nolist); assert_eq "JSON without an account list: rc 2" "2" "${out%%|*}"
out=$(grade ok T_CA_BIN="$TMP/missing"); assert_eq "helper missing: rc 2" "2" "${out%%|*}"
assert_contains "...named" "is not executable" "$out"
assert_contains "...and logged" "not executable" "$(cat "$TMP/err")"
out=$(grade ok T_CLAUDE_BIN="$TMP/none"); assert_eq "no claude CLI at all (absent by design): skipped, rc 0" "0" "${out%%|*}"
assert_contains "...says skipped" "skipped" "$out"

echo "grades"
out=$(grade me-warn); assert_eq "extra account near its end: WARN" "2" "${out%%|*}"
assert_contains "...with its detail" "me login valid until 2026-10-30 (1 d left)" "$out"
out=$(grade iu-expired); assert_eq "expired default login, claude auth logged in: WARN (policy has not failed)" "2" "${out%%|*}"
out=$(grade iu-expired STUB_IU_DEAD=1); assert_eq "keychain dead + cached token works (accepted state): stays WARN, not FAIL" "2" "${out%%|*}"
assert_contains "...accepted state still named" "cached oauth token" "$out"
out=$(grade iu-expired STUB_IU_DEAD=1 STUB_TOKEN_DEAD=1); assert_eq "keychain dead AND token dead + expired: FAIL (the iu policy fails)" "1" "${out%%|*}"
out=$(grade ok STUB_IU_DEAD=1 STUB_TOKEN_DEAD=1); assert_eq "...same FAIL without any expiry finding" "1" "${out%%|*}"

echo
if (( fail )); then printf '\033[31m%d failed\033[0m, %d passed\n' "$fail" "$pass"; exit 1; fi
printf '\033[32mall %d passed\033[0m\n' "$pass"
