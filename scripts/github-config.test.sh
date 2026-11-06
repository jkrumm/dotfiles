#!/usr/bin/env bash
# github-config.test — hermetic regression suite for scripts/github-config.sh.
#
# `gh` is a stub that records every call (and the request body) and answers from
# scratch fixtures; the stub runs the script's own --jq filters through real jq,
# so those filters are exercised too. The script runs from a SANDBOX COPY with a
# fixture config/ (pr-required list, empty secrets) plus the REAL ruleset JSON,
# so the payload-shape assertions guard config/github-ruleset-{full,lite}.json.
# Nothing touches GitHub, 1Password or the network.
#
# Asserted: the denylist / collaborator / solo tier decision and its precedence,
# the dry-run preview mutates nothing, private repos get no ruleset, FULL vs LITE
# payload shape ($comment stripped, PR rule only on FULL, bypass kept), create
# (POST) vs update-in-place (PUT) of the one ruleset name, the merge-settings
# PATCH, and the Done summary counting a failed ruleset.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/github-config.sh"
CONF="$HERE/../config"
[ -f "$SRC" ] || { echo "✗ $SRC not found"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "✗ jq required"; exit 1; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/github-config-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

fails=0
ok()  { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fails=$((fails + 1)); }
assert_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — got '$2', want '$3'"; fi
}
assert_contains() {
  if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1 — missing '$3' in: $2"; fi
}
assert_not_contains() {
  if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1 — unexpected '$3' in: $2"; fi
}

ST="$TMP/st"; BIN="$TMP/bin"; SB="$TMP/sandbox"
export ST
mkdir -p "$BIN" "$SB/scripts" "$SB/config"
ln -s "$(command -v jq)" "$BIN/jq"
cp "$SRC" "$SB/scripts/github-config.sh"
cp "$CONF/github-ruleset-full.json" "$CONF/github-ruleset-lite.json" "$SB/config/"
printf '{"repos":["basalt-ui","rollhook"],"directToMain":["solo"]}\n' > "$SB/config/pr-required-repos.json"
printf '{"secrets":[]}\n' > "$SB/config/github-secrets.json"

cat > "$BIN/gh" <<'EOF'
#!/bin/sh
echo "gh $*" >> "$ST/gh.log"
filter=""; prev=""; method=GET
for a in "$@"; do
  [ "$prev" = --jq ] && filter=$a
  [ "$prev" = -X ] && method=$a
  prev=$a
done
if [ "$1 $2" = "auth status" ]; then [ -f "$ST/auth_fail" ] && exit 1; exit 0; fi
if [ "$1 $2" = "repo list" ]; then jq -r "$filter" < "$ST/repos.json"; exit 0; fi
[ "$1" = api ] || exit 0
path=$2
repo=$(echo "$path" | cut -d/ -f3)
case "$method:$path" in
  GET:*/collaborators)
    [ -f "$ST/collab_fail" ] && exit 1
    f="$ST/collab/$repo"; [ -f "$f" ] || f="$ST/empty.json"
    jq -r "$filter" < "$f" ;;
  GET:*/rulesets)
    f="$ST/rulesets/$repo"; [ -f "$f" ] || f="$ST/empty.json"
    jq -r "$filter" < "$f" ;;
  *)
    kind=patch; case "$path" in */rulesets*) kind=ruleset ;; esac
    if [ "$kind" = ruleset ]; then cat > "$ST/body.$method.$repo"; fi
    echo "$method $path" >> "$ST/writes.log"
    [ -f "$ST/fail_${kind}_$repo" ] && exit 1
    exit 0 ;;
esac
EOF
chmod +x "$BIN/gh"
export PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin"
export HOME="$TMP/home"; mkdir -p "$HOME"

reset() {
  rm -rf "$ST"; mkdir -p "$ST/collab" "$ST/rulesets"
  echo '[]' > "$ST/empty.json"; : > "$ST/gh.log"; : > "$ST/writes.log"
  cat > "$ST/repos.json" <<'JSON'
[{"name":"basalt-ui","isPrivate":false},
 {"name":"solo","isPrivate":false},
 {"name":"shared","isPrivate":false},
 {"name":"hidden","isPrivate":true}]
JSON
  echo '[{"login":"jkrumm"},{"login":"friend"}]' > "$ST/collab/shared"
  echo '[{"login":"jkrumm"}]' > "$ST/collab/solo"
}
OUT=""; RC=0
run() { RC=0; OUT=$(/bin/bash "$SB/scripts/github-config.sh" 2>&1) || RC=$?; }

echo "unit: is_pr_required / has_collaborator / choose_tier (extracted verbatim)"
OWNER=jkrumm; PR_REQUIRED_FILE="$SB/config/pr-required-repos.json"; export OWNER PR_REQUIRED_FILE   # read by the extracted functions
for fn in is_pr_required has_collaborator choose_tier apply_ruleset; do
  eval "$(awk -v f="$fn() {" 'index($0, f) == 1 { p = 1 } p { print } p && /^}/ { exit }' "$SRC")"
done
reset
is_pr_required basalt-ui && ok "denylisted repo is PR-required" || bad "denylisted repo is PR-required"
is_pr_required solo && bad "unlisted repo is not PR-required" || ok "unlisted repo is not PR-required"
is_pr_required "basalt" && bad "denylist match is exact, not a prefix" || ok "denylist match is exact, not a prefix"
is_pr_required "" && bad "empty name is not PR-required" || ok "empty name is not PR-required"
has_collaborator shared && ok "a second login is a collaborator" || bad "a second login is a collaborator"
has_collaborator solo && bad "the owner alone is not a collaborator" || ok "the owner alone is not a collaborator"
has_collaborator nobody && bad "no collaborators -> false" || ok "no collaborators -> false"
touch "$ST/collab_fail"
has_collaborator shared && bad "gh failure counts as none (fail-open to LITE)" || ok "gh failure counts as none"
rm "$ST/collab_fail"
assert_eq "choose_tier: denylist" "$(choose_tier basalt-ui)" "full|PR-required (denylist)"
assert_eq "choose_tier: collaborator" "$(choose_tier shared)" "full|has collaborator"
assert_eq "choose_tier: solo" "$(choose_tier solo)" "lite|direct-to-master"
echo '[{"login":"friend"}]' > "$ST/collab/basalt-ui"
assert_eq "choose_tier: denylist wins over collaborator" "$(choose_tier basalt-ui)" "full|PR-required (denylist)"
: > "$ST/gh.log"; choose_tier basalt-ui >/dev/null
assert_eq "denylist hit makes no API call" "$(cat "$ST/gh.log")" ""

echo "unit: apply_ruleset payload and create-vs-update"
reset
apply_ruleset solo "$SB/config/github-ruleset-lite.json"
assert_eq "no existing ruleset -> POST to the collection" "$(cat "$ST/writes.log")" "POST repos/jkrumm/solo/rulesets"
body="$ST/body.POST.solo"
assert_eq "\$comment is stripped" "$(jq 'has("$comment")' "$body")" false
assert_eq "payload is the file minus \$comment" "$(jq -S . "$body")" "$(jq -S 'del(.["$comment"])' "$SB/config/github-ruleset-lite.json")"
assert_eq "ruleset name is the shared one" "$(jq -r .name "$body")" protect-default-branch
reset
echo '[{"id":11,"name":"other"},{"id":77,"name":"protect-default-branch"}]' > "$ST/rulesets/solo"
apply_ruleset solo "$SB/config/github-ruleset-full.json"
assert_eq "existing ruleset -> PUT in place by id" "$(cat "$ST/writes.log")" "PUT repos/jkrumm/solo/rulesets/77"
assert_eq "update carries the FULL payload" "$(jq -r '[.rules[].type] | join(",")' "$ST/body.PUT.solo")" "pull_request,non_fast_forward,deletion,required_linear_history"
reset; touch "$ST/fail_ruleset_solo"
apply_ruleset solo "$SB/config/github-ruleset-lite.json" && bad "apply_ruleset propagates a failed write" || ok "apply_ruleset propagates a failed write"

echo "ruleset tiers (real config)"
for t in full lite; do
  f="$CONF/github-ruleset-$t.json"
  assert_eq "$t: admin bypass kept (actor 5, always)" "$(jq -c '.bypass_actors' "$f")" '[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}]'
  assert_eq "$t: protects master and main" "$(jq -c '.conditions.ref_name.include' "$f")" '["refs/heads/main","refs/heads/master"]'
  for r in non_fast_forward deletion required_linear_history; do
    assert_eq "$t: $r rule" "$(jq --arg r "$r" '[.rules[].type] | index($r) != null' "$f")" true
  done
done
assert_eq "FULL requires a PR" "$(jq '[.rules[].type] | index("pull_request") != null' "$CONF/github-ruleset-full.json")" true
assert_eq "LITE has no PR rule" "$(jq '[.rules[].type] | index("pull_request") != null' "$CONF/github-ruleset-lite.json")" false

echo "preconditions"
reset; touch "$ST/auth_fail"; run
assert_eq "unauthenticated gh exits 1" "$RC" 1
assert_contains "unauthenticated message" "$OUT" "not authenticated with gh CLI"
reset; mv "$SB/config/github-ruleset-lite.json" "$TMP/lite.bak"; run
assert_eq "missing ruleset config exits 1" "$RC" 1
assert_contains "names the missing file" "$OUT" "required config not found"
mv "$TMP/lite.bak" "$SB/config/github-ruleset-lite.json"

echo "dry run"
reset; DRY_RUN=1 run
assert_eq "dry run exits 0" "$RC" 0
assert_contains "denylist -> FULL" "$OUT" "[dry] jkrumm/basalt-ui — FULL (PR-required (denylist))"
assert_contains "collaborator -> FULL" "$OUT" "[dry] jkrumm/shared — FULL (has collaborator)"
assert_contains "solo public -> LITE" "$OUT" "[dry] jkrumm/solo — LITE (direct-to-master)"
assert_contains "private -> no ruleset" "$OUT" "[dry] jkrumm/hidden — PRIVATE (no ruleset"
assert_eq "dry run writes nothing" "$(cat "$ST/writes.log")" ""

echo "apply"
reset; run
assert_eq "exits 0" "$RC" 0
assert_contains "all four counted" "$OUT" "Done: 4 configured, 0 failed"
assert_contains "denylisted repo gets FULL" "$OUT" "✓ full ruleset (PR-required (denylist))"
assert_contains "collaborator repo gets FULL" "$OUT" "✓ full ruleset (has collaborator)"
assert_contains "solo repo gets LITE" "$OUT" "✓ lite ruleset (direct-to-master)"
assert_contains "private repo explains the gap" "$OUT" "private repo — server-side protection needs GitHub Pro"
assert_eq "basalt-ui payload has the PR rule" "$(jq '[.rules[].type] | index("pull_request") != null' "$ST/body.POST.basalt-ui")" true
assert_eq "shared payload has the PR rule" "$(jq '[.rules[].type] | index("pull_request") != null' "$ST/body.POST.shared")" true
assert_eq "solo payload has no PR rule" "$(jq '[.rules[].type] | index("pull_request") != null' "$ST/body.POST.solo")" false
assert_eq "private repo: no ruleset written" "$([ -e "$ST/body.POST.hidden" ] && echo yes || echo no)" no
assert_eq "every repo (private too) gets the merge settings" "$(grep -c '^PATCH repos/jkrumm/[a-z-]*$' "$ST/writes.log")" 4
assert_contains "merge settings are rebase-only + auto-delete" "$(grep 'api repos/jkrumm/solo -X PATCH' "$ST/gh.log")" "allow_merge_commit=false --field allow_squash_merge=false --field allow_rebase_merge=true --field delete_branch_on_merge=true"
reset; echo '[{"id":5,"name":"protect-default-branch"}]' > "$ST/rulesets/solo"; run
assert_contains "existing ruleset updated, not duplicated" "$(cat "$ST/writes.log")" "PUT repos/jkrumm/solo/rulesets/5"
assert_not_contains "no POST for the existing one" "$(cat "$ST/writes.log")" "POST repos/jkrumm/solo/rulesets"
reset; touch "$ST/fail_ruleset_solo"; run
assert_contains "a failed ruleset is reported" "$OUT" "✗ lite ruleset failed"
assert_contains "failure is counted, the rest continue" "$OUT" "Done: 3 configured, 1 failed"
reset; touch "$ST/fail_patch_solo"; run
assert_contains "failed merge-settings update is reported" "$OUT" "✗ merge settings update failed"

echo
if [ "$fails" -eq 0 ]; then echo "github-config: all passed"; else echo "github-config: $fails failed"; exit 1; fi
