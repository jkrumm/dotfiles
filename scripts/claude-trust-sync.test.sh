#!/usr/bin/env bash
# claude-trust-sync.test.sh — hermetic: scratch HOME and registry, never touches a real .claude.json.
# Usage: scripts/claude-trust-sync.test.sh   (exit 0 = all pass)
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC="$HERE/claude-trust-sync.sh"
pass=0; fail=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; [[ -n "${2:-}" ]] && printf '         %s\n' "$2"; fail=$((fail + 1)); }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/trust-sync-test.XXXXXX")" || exit 2
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME/.claude-me" "$HOME/.claude-x"
cat > "$TMP/registry.json" <<'JSON'
{"accounts":{"iu":{"dir":null,"enabled":true},"me":{"dir":"~/.claude-me","enabled":true},"x":{"dir":"~/.claude-x","enabled":true},"gone":{"dir":"~/.claude-gone","enabled":true}}}
JSON
export CLAUDE_ACCOUNTS_REGISTRY="$TMP/registry.json"
run() { bash "$SYNC" 2>&1; }
t() { jq -r --arg p "$2" '.projects[$p].hasTrustDialogAccepted' "$1"; }

# default: /a /b trusted, /c explicitly not, /d trusted with extra keys
cat > "$HOME/.claude.json" <<'JSON'
{"projects":{"/a":{"hasTrustDialogAccepted":true},"/b":{"hasTrustDialogAccepted":true,"allowedTools":["x"]},"/c":{"hasTrustDialogAccepted":false},"/d":{"hasTrustDialogAccepted":true,"history":[1]}},"theme":"dark"}
JSON
# me: /a missing, /b false, /c true already (default says false: must stay), /e its own, other keys
cat > "$HOME/.claude-me/.claude.json" <<'JSON'
{"oauthAccount":{"x":1},"projects":{"/b":{"hasTrustDialogAccepted":false,"allowedTools":["me"]},"/c":{"hasTrustDialogAccepted":true},"/e":{"hasTrustDialogAccepted":true}},"theme":"light"}
JSON
chmod 600 "$HOME/.claude-me/.claude.json"
echo '{"numStartups":3}' > "$HOME/.claude-x/.claude.json"   # no projects key at all
cp "$HOME/.claude.json" "$TMP/default.before"

echo "copies trust only where the default trusts"
out=$(run); rc=$?
assert_eq "exit 0 (an account without a .claude.json is skipped)" 0 "$rc"
me="$HOME/.claude-me/.claude.json"
assert_eq "/a added" true "$(t "$me" /a)"
assert_eq "/b false -> true" true "$(t "$me" /b)"
assert_eq "/d added" true "$(t "$me" /d)"
assert_eq "/c stays as the extra had it (default false never loosens)" true "$(t "$me" /c)"
assert_eq "/e (not in default) untouched" true "$(t "$me" /e)"
assert_eq "other keys untouched" "light" "$(jq -r .theme "$me")"
assert_eq "oauthAccount untouched" 1 "$(jq -r .oauthAccount.x "$me")"
assert_eq "other project keys untouched" '["me"]' "$(jq -c '.projects["/b"].allowedTools' "$me")"
assert_eq "no key added for a path the default distrusts" null "$(jq -c '.projects["/c"].allowedTools' "$me")"
assert_eq "file mode kept" 600 "$(stat -f %Lp "$me" 2>/dev/null || stat -c %a "$me")"
assert_eq "no stray temp files" 0 "$(find "$HOME/.claude-me" -name '.claude.json.*' | wc -l | tr -d ' ')"
x="$HOME/.claude-x/.claude.json"
assert_eq "extra without a projects key gets the trusted set" '["/a","/b","/d"]' "$(jq -c '.projects | keys' "$x")"
assert_eq "extra's unrelated keys kept" 3 "$(jq -r .numStartups "$x")"
assert_eq "default file never written" "$(cat "$TMP/default.before")" "$(cat "$HOME/.claude.json")"

echo "idempotent"
cp "$me" "$TMP/me.before"; m1=$(stat -f %m "$me" 2>/dev/null || stat -c %Y "$me")
sleep 1; out=$(run); rc=$?
assert_eq "second run: exit 0" 0 "$rc"
assert_eq "second run: byte-identical" "$(cat "$TMP/me.before")" "$(cat "$me")"
assert_eq "second run: no rewrite at all" "$m1" "$(stat -f %m "$me" 2>/dev/null || stat -c %Y "$me")"
case $out in *"already in sync"*) ok "second run says in sync" ;; *) bad "second run says in sync" "$out" ;; esac

echo "failure modes"
echo 'not json' > "$HOME/.claude-x/.claude.json"
out=$(run); rc=$?
assert_eq "invalid extra file: exit 1" 1 "$rc"
assert_eq "invalid extra file left alone" "not json" "$(cat "$HOME/.claude-x/.claude.json")"
assert_eq "the other account still synced" true "$(t "$me" /a)"
rm "$HOME/.claude.json"
out=$(run); rc=$?
assert_eq "no default .claude.json: nothing to do, exit 0" 0 "$rc"
echo 'not json' > "$HOME/.claude.json"
out=$(run); rc=$?
assert_eq "invalid default file: exit 1" 1 "$rc"

echo
if (( fail )); then printf '\033[31m%d failed\033[0m, %d passed\n' "$fail" "$pass"; exit 1; fi
printf '\033[32mall %d passed\033[0m\n' "$pass"
