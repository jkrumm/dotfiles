#!/usr/bin/env bash
# statusline.test.sh — regression harness for the two-account segments of scripts/statusline.sh
# (the final accounts segment: <id> <5h>/<wk> per enabled account, own bold, ∑ pool; docs/statusline.md).
#
# Hermetic: the render caches live in a scratch CLAUDE_SL_DIR, the environment is scrubbed (env -i), and the
# fixtures pre-create the account file and both throttle stamps, so a render spawns neither claude-account,
# uv nor curl. Asserts on the colour-stripped line, plus the raw line where grey vs coloured matters.
#
# Usage: scripts/statusline.test.sh   (exit 0 = all pass)

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SL="$HERE/statusline.sh"

pass=0
fail=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; [[ -n "${2:-}" ]] && printf '         %s\n' "$2"; fail=$((fail + 1)); }
assert_contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "[$3] does not contain [$2]" ;; esac; }
assert_lacks()    { case "$3" in *"$2"*) bad "$1" "[$3] contains [$2]" ;; *) ok "$1" ;; esac; }

command -v jq >/dev/null || { echo "✗ jq not found"; exit 2; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/statusline-test.XXXXXX")" || exit 2
trap 'rm -rf "$TMP"' EXIT
SLD="$TMP/sl"; mkdir -p "$SLD" "$TMP/home" "$TMP/work"
NOW=$(date +%s)

# acct <plan|null> <5h|null> <wk|null> <sample age s> <auth_ok> <enabled> [wk reset epoch]
acct() {
  jq -nc --arg plan "$1" --argjson f "$2" --argjson w "$3" --argjson age "$4" --argjson auth "$5" --argjson en "$6" \
    --argjson wr "${7:-$((NOW + 302400))}" --argjson now "$NOW" '
    {plan: (if $plan == "null" then null else $plan end),
     five_hour: {utilization: $f, resets_at_epoch: ($now + 3600), age_s: $age, value: $f, value_resets_at_epoch: ($now + 3600)},
     seven_day: {utilization: $w, resets_at_epoch: $wr, age_s: $age, value: $w, value_resets_at_epoch: $wr},
     sampled_at: ($now - $age), source: "statusline", enabled: $en, auth_ok: $auth, exhausted_until: null}'
}
# accounts_file <iu json> <me json>
accounts_file() {
  jq -nc --argjson iu "$1" --argjson me "$2" --argjson now "$NOW" \
    '{default_account: "iu", accounts: {iu: $iu, me: $me}, fetched_at: $now}' > "$SLD/usage_accounts.json"
}
# render [env VAR=val …] — own account iu/IU (or $OWN), stdin figures $FIVE %/5h (default 43), $WK %/wk (default 17)
render() {
  local own=${OWN:-iu} badge=${BADGE-IU}
  printf '%s %s\n' "$own" "$badge" > "$SLD/account_v2_default"
  echo "$NOW" > "$SLD/usage_push_default.stamp"
  echo "$NOW" > "$SLD/usage_accounts.stamp"
  jq -nc --arg model "${MODEL:-Opus 5.5}" --argjson wk "${WK:-17}" --argjson f "${FIVE:-43}" --argjson wr "$((NOW + 302400))" --argjson now "$NOW" '
    {model: {display_name: $model}, workspace: {current_dir: "/tmp"},
     rate_limits: {five_hour: {used_percentage: $f, resets_at: ($now + 5430)}, seven_day: {used_percentage: $wk, resets_at: $wr}}}' |
    env -i HOME="$TMP/home" PATH="$PATH" CLAUDE_SL_DIR="$SLD" "$@" /bin/bash "$SL"
}
plain() { sed $'s/\033\\[[0-9;]*m//g'; }
line1() { render "$@" | head -1; }

FRESH_IU=$(acct max20x 2 17 30 true true)
FRESH_ME=$(acct max5x 21 19 30 true true)
BOLD=$'\033[1m'

echo "both accounts fresh: every account in registry order, own live and bold, then the pool"
accounts_file "$FRESH_IU" "$FRESH_ME"
raw=$(line1 CLAUDE_ACCOUNT_REASON=pace); out=$(plain <<<"$raw")
assert_contains "badge, model, effort unchanged at the front" "MAX IU · Opus 5.5 · auto" "$out"
assert_contains "one final segment after the duration" "0min | iu 43/17 ↺90m · me 21/19 · ∑17%" "$out"
assert_lacks "old own segment is gone" "%/5h" "$out"
assert_lacks "old own segment is gone (wk)" "%/wk" "$out"
assert_lacks "routing reason is not rendered" "·pace" "$out"
assert_lacks "pool label is the ∑ sign only" "pool" "$out"
assert_contains "own entry is bold" "${BOLD}iu " "$raw"
assert_lacks "other account is not bold" "${BOLD}me" "$raw"
assert_contains "own numbers keep their threshold colours (43 green, 17 green)" $'\033[32m43\033[39m/\033[32m17\033[39m' "$raw"
assert_contains "other account coloured by the same thresholds" $'me \033[32m21\033[39m/\033[32m19\033[39m' "$raw"

echo "own account second in registry order"
accounts_file "$(acct max20x 2 90 30 true true)" "$FRESH_ME"
raw=$(OWN=me BADGE=ME WK=19 FIVE=41 line1); out=$(plain <<<"$raw")
assert_contains "registry order kept, own entry in place" "| iu 2/90 · me 41/19 ↺90m · ∑76%" "$out"
assert_contains "iu weekly 90 is red" $'/\033[31m90\033[39m' "$raw"
assert_contains "own entry bold in the second position" "${BOLD}me " "$raw"
assert_contains "pool = (20*90 + 5*19) / 25" "∑76%" "$out"

echo "own figures over the thresholds"
accounts_file "$FRESH_IU" "$FRESH_ME"
raw=$(FIVE=60 WK=80 line1)
assert_contains "own 60 yellow / 80 red" $'\033[33m60\033[39m/\033[31m80\033[39m' "$raw"
raw=$(FIVE=75 WK=49 line1)
assert_contains "own 75 red / 49 green (boundaries)" $'\033[31m75\033[39m/\033[32m49\033[39m' "$raw"
out=$(OWN=me BADGE=ME WK=19 line1 | plain)
assert_contains "pool uses the live own weekly figure (me 19)" "∑" "$out"

echo "pool without plan multiples counts accounts equally"
accounts_file "$(acct null 2 17 30 true true)" "$FRESH_ME"
assert_contains "equal weights: (17 + 19) / 2" "∑18%" "$(line1 | plain)"

echo "other account stale / login failed / unusable"
accounts_file "$FRESH_IU" "$(acct max5x 21 19 7200 true true)"
raw=$(line1); out=$(plain <<<"$raw")
assert_contains "stale sample still shown" "me 21/19" "$out"
assert_contains "stale sample is grey" $'\033[90mme 21/19' "$raw"
accounts_file "$FRESH_IU" "$(acct max5x 21 19 30 false true)"
raw=$(line1); out=$(plain <<<"$raw")
assert_contains "login failed: grey with a marker" "me 21/19 ✗login" "$out"
assert_contains "login failed is grey" $'\033[90mme 21/19' "$raw"
accounts_file "$FRESH_IU" "$(acct max5x null null 30 true true)"
out=$(line1 | plain)
assert_lacks "no figures at all: that account is omitted" "me " "$out"
assert_contains "no figures: own entry alone, pool falls back to the own account" "iu 43/17 ↺90m · ∑17%" "$out"
accounts_file "$FRESH_IU" "$(acct max5x 21 19 30 true true | jq -c '.five_hour.value_resets_at_epoch = 1 | .seven_day.value_resets_at_epoch = 1')"
assert_contains "elapsed windows count as 0" "me 0/0" "$(line1 | plain)"

echo "single account / missing data"
accounts_file "$FRESH_IU" "$(acct max5x 21 19 30 true false)"
out=$(BADGE='' line1 | plain)
assert_contains "single account: <id> 5h/wk only" "0min | iu 43/17 ↺90m" "$out"
assert_lacks "single account: no other account" "me " "$out"
assert_lacks "single account: no pool" "∑" "$out"
rm -f "$SLD/usage_accounts.json"
out=$(render 2>&1 | plain)
assert_contains "missing accounts file: own entry only" "0min | iu 43/17 ↺90m" "$out"
assert_lacks "missing accounts file: no pool" "∑" "$out"
assert_lacks "missing accounts file: no error output" "rror" "$out"
echo '{not json' > "$SLD/usage_accounts.json"
out=$(render 2>&1 | plain)
assert_lacks "corrupt accounts file: no pool" "∑" "$out"
assert_contains "corrupt accounts file: own entry still renders" "iu 43/17" "$out"
accounts_file "$FRESH_IU" "$FRESH_ME"
out=$(OWN='?' line1 | plain)
assert_lacks "unresolved own account: never rendered as an id" "? " "$out"
assert_contains "unresolved own account: live numbers without an id" "43/17" "$out"

echo "ids from files are validated before they reach echo -e"
accounts_file "$FRESH_IU" "$FRESH_ME"
jq -c '.accounts["me\\033[31mZQ"] = .accounts.me | del(.accounts.me)' "$SLD/usage_accounts.json" > "$SLD/x.json" && mv "$SLD/x.json" "$SLD/usage_accounts.json"
out=$(render 2>&1)
assert_lacks "account id with escape bytes: entry dropped" "ZQ" "$(plain <<<"${out%%$'\n'*}")"
accounts_file "$FRESH_IU" "$FRESH_ME"
out=$(BADGE='X\033[31mY' line1 | plain)
assert_lacks "malformed badge: not rendered" "033" "$out"
out=$(OWN='bad id' line1 | plain)
assert_lacks "malformed own id: not rendered" "bad id" "$out"

echo "CLAUDE_SL_DIR seam: no real refresher is spawned"
accounts_file "$FRESH_IU" "$FRESH_ME"
# the real refresher would be `uv run $HOME/.claude/fetch_usage.py --accounts`: a script there that leaves a marker proves a spawn
mkdir -p "$TMP/home/.claude"
printf 'import sys\nopen(sys.argv[0] + ".ran", "w").close()\n' > "$TMP/home/.claude/fetch_usage.py"
render >/dev/null; echo 0 > "$SLD/usage_accounts.stamp"   # an expired stamp would trigger the refresh
jq -nc --argjson now "$NOW" '{model: {display_name: "x"}, workspace: {current_dir: "/tmp"}, rate_limits: {five_hour: {used_percentage: 1, resets_at: ($now + 600)}, seven_day: {used_percentage: 1, resets_at: ($now + 600000)}}}' |
  env -i HOME="$TMP/home" PATH="$PATH" CLAUDE_SL_DIR="$SLD" /bin/bash "$SL" >/dev/null
sleep 3
[[ -e "$TMP/home/.claude/fetch_usage.py.ran" ]] && bad "refresher spawned despite CLAUDE_SL_DIR" || ok "expired stamp + seam: refresher not spawned"

echo "width: the 5h reset countdown is kept only while line 1 fits 130 columns"
accounts_file "$FRESH_IU" "$FRESH_ME"
out=$(line1 | plain)
cols=$(printf '%s' "$out" | LC_ALL=C tr -d '\200-\277' | wc -c | tr -d ' ')
assert_contains "typical line keeps the countdown" "↺90m" "$out"
(( cols <= 130 )) && ok "typical line is $cols columns (<= 130)" || bad "typical line too wide" "$cols columns"
out=$(MODEL="Opus 5.5 $(printf 'x%.0s' {1..75})" line1 | plain)
assert_lacks "too wide: countdown dropped" "↺" "$out"
assert_contains "too wide: accounts and pool kept" "iu 43/17 · me 21/19 · ∑17%" "$out"

echo
echo "statusline: $pass passed, $fail failed"
(( fail == 0 ))
