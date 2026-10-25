#!/usr/bin/env bash
# statusline.test.sh — regression harness for the two-account segments of scripts/statusline.sh
# (other account, pool, routing reason, pace hint; docs/statusline.md).
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
# render [env VAR=val …] — own account iu/IU (or $OWN), stdin figures 43%/5h, $WK %/wk resetting $WKRESET
render() {
  local own=${OWN:-iu} badge=${BADGE-IU}
  printf '%s %s\n' "$own" "$badge" > "$SLD/account_v2_default"
  echo "$NOW" > "$SLD/usage_push_default.stamp"
  echo "$NOW" > "$SLD/usage_accounts.stamp"
  jq -nc --arg model "${MODEL:-Opus 5.5}" --argjson wk "${WK:-17}" --argjson wr "${WKRESET:-$((NOW + 302400))}" --argjson now "$NOW" '
    {model: {display_name: $model}, workspace: {current_dir: "/tmp"},
     rate_limits: {five_hour: {used_percentage: 43, resets_at: ($now + 5430)}, seven_day: {used_percentage: $wk, resets_at: $wr}}}' |
    env -i HOME="$TMP/home" PATH="$PATH" CLAUDE_SL_DIR="$SLD" "$@" /bin/bash "$SL"
}
plain() { sed $'s/\033\\[[0-9;]*m//g'; }
line1() { render "$@" | head -1; }

FRESH_IU=$(acct max20x 2 17 30 true true)
FRESH_ME=$(acct max5x 21 19 30 true true)

echo "both accounts fresh"
accounts_file "$FRESH_IU" "$FRESH_ME"
raw=$(line1 CLAUDE_ACCOUNT_REASON=pace); out=$(plain <<<"$raw")
assert_contains "own subscription numbers stay first and unchanged" "MAX IU · Opus 5.5 · auto" "$out"
assert_contains "own 5h/wk unchanged" "43%/5h ↺90m · 17%/wk" "$out"
assert_contains "other account compact 5h/wk" "me 21/19" "$out"
assert_contains "pool is plan-weighted (20x/5x, own live wk 17)" "pool 17%" "$out"
assert_contains "routing reason after the badge" "IU·pace" "$out"
case $out in *"17%/wk"*"me 21/19"*"pool 17%"*"IU·pace"*) ok "segment order: own, other, pool, reason" ;; *) bad "segment order" "$out" ;; esac
assert_contains "other account coloured green by the own thresholds" $'\033[32m21\033[0m/\033[32m19\033[0m' "$raw"

echo "own account me, other iu (weighted 90% on 20x)"
accounts_file "$(acct max20x 2 90 30 true true)" "$FRESH_ME"
out=$(OWN=me BADGE=ME WK=19 line1 | plain)
assert_contains "other is iu with its figures" "iu 2/90" "$out"
assert_contains "pool = (20*90 + 5*19) / 25" "pool 76%" "$out"
raw=$(OWN=me BADGE=ME WK=19 line1)
assert_contains "iu weekly 90 is red" $'/\033[31m90\033[0m' "$raw"

echo "pool without plan multiples counts accounts equally"
accounts_file "$(acct null 2 17 30 true true)" "$FRESH_ME"
assert_contains "equal weights: (17 + 19) / 2" "pool 18%" "$(line1 | plain)"

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
assert_lacks "no figures at all: no other-account segment" "me " "$out"
assert_contains "no figures: pool falls back to the own account" "pool 17%" "$out"
accounts_file "$FRESH_IU" "$(acct max5x 21 19 30 true true | jq -c '.five_hour.value_resets_at_epoch = 1 | .seven_day.value_resets_at_epoch = 1')"
assert_contains "elapsed windows count as 0" "me 0/0" "$(line1 | plain)"

echo "single account / missing data: nothing, no errors"
accounts_file "$FRESH_IU" "$(acct max5x 21 19 30 true false)"
out=$(BADGE='' line1 | plain)
assert_lacks "single enabled account: no other account" "me " "$out"
assert_lacks "single enabled account: no pool" "pool" "$out"
assert_contains "single account: own numbers intact" "43%/5h ↺90m · 17%/wk" "$out"
accounts_file "$FRESH_IU" "$FRESH_ME"
out=$(BADGE='' line1 | plain)
assert_lacks "no badge (one account enabled in the registry): no other account" "me 21" "$out"
assert_lacks "no badge: no pool" "pool" "$out"
rm -f "$SLD/usage_accounts.json"
out=$(render 2>&1 | plain)
assert_lacks "missing accounts file: no other account" "me " "$out"
assert_lacks "missing accounts file: no pool" "pool" "$out"
assert_lacks "missing accounts file: no error output" "rror" "$out"
assert_contains "missing accounts file: own numbers intact" "43%/5h ↺90m · 17%/wk" "$out"
echo '{not json' > "$SLD/usage_accounts.json"
out=$(render 2>&1 | plain)
assert_lacks "corrupt accounts file: no pool" "pool" "$out"
assert_contains "corrupt accounts file: still renders" "43%/5h" "$out"
accounts_file "$FRESH_IU" "$FRESH_ME"
out=$(OWN='?' line1 | plain)
assert_lacks "unresolved own account: no other account" "me 21" "$out"

echo "routing reason"
out=$(line1 | plain)
assert_lacks "reason absent: nothing shown" "IU·" "$out"
out=$(line1 CLAUDE_ACCOUNT_REASON=home | plain)
assert_contains "reason home" "IU·home" "$out"
out=$(line1 'CLAUDE_ACCOUNT_REASON=bad reason;x' | plain)
assert_lacks "malformed reason: ignored" "bad reason" "$out"
accounts_file "$FRESH_IU" "$(acct max5x 21 19 30 true false)"
out=$(BADGE='' line1 CLAUDE_ACCOUNT_REASON=home | plain)
assert_contains "no badge: bare ·reason" "17%/wk | ·home" "$out"

echo "weekly pace hint (own account, weekly% > elapsed + 15)"
accounts_file "$FRESH_IU" "$FRESH_ME"
out=$(WK=80 WKRESET=$((NOW + 6 * 86400)) line1 | plain)
assert_contains "80% used one day into the week: over pace" "80%/wk ↑pace" "$out"
out=$(WK=17 WKRESET=$((NOW + 302400)) line1 | plain)
assert_lacks "17% at half the week: on pace" "↑pace" "$out"
out=$(WK=60 WKRESET=$((NOW + 302400)) line1 | plain)
assert_lacks "60% at 50% elapsed (margin 15): still on pace" "↑pace" "$out"
out=$(WK=66 WKRESET=$((NOW + 302400)) line1 | plain)
assert_contains "66% at 50% elapsed: over the margin" "↑pace" "$out"

echo "width: reason and pace hint go first past ~150 columns"
out=$(MODEL="Opus 5.5 $(printf 'x%.0s' {1..70})" WK=80 WKRESET=$((NOW + 6 * 86400)) line1 CLAUDE_ACCOUNT_REASON=pace | plain)
assert_lacks "too wide: reason dropped" "IU·pace" "$out"
assert_lacks "too wide: pace hint dropped" "↑pace" "$out"
assert_contains "too wide: other account kept" "me 21/19" "$out"
assert_contains "too wide: pool kept" "pool" "$out"
out=$(WK=80 WKRESET=$((NOW + 6 * 86400)) line1 CLAUDE_ACCOUNT_REASON=pace | plain)
cols=$(printf '%s' "$out" | LC_ALL=C tr -d '\200-\277' | wc -c | tr -d ' ')
assert_contains "typical line keeps both extras" "↑pace" "$out"
(( cols <= 150 )) && ok "typical line with everything is $cols columns (<= 150)" || bad "typical line too wide" "$cols columns"

echo "single-account line is unchanged"
accounts_file "$FRESH_IU" "$(acct max5x 21 19 30 true false)"
out=$(BADGE='' line1 | plain)
case $out in "MAX · Opus 5.5 · auto | "*" | 0min | 43%/5h ↺90m · 17%/wk") ok "line 1 ends at the own limits" ;; *) bad "single-account line 1" "$out" ;; esac

echo
echo "statusline: $pass passed, $fail failed"
(( fail == 0 ))
