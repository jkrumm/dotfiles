#!/usr/bin/env bash
# secrets-reseal-request.test.sh — hermetic harness for secrets-reseal-request.sh.
#
# Contract under test: the request is raised ONCE per missing-ref set (a key per set), names
# the exact refs and accounts, runs the incremental path, carries a `needed` check, replaces
# an older set's request, and clears itself when the cache is complete. No 1Password, no
# sops, no factory: the cache is a JSON file whose KEYS are what the script reads (keys are
# plaintext in SOPS-JSON), and ask-human is a stub that records its calls.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REQ="$HERE/secrets-reseal-request.sh"
command -v jq >/dev/null || { echo "✗ jq missing"; exit 2; }

pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; fail=$((fail + 1)); }
assert_eq()       { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
assert_contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "[$3] does not contain [$2]" ;; esac; }

T="$(mktemp -d "${TMPDIR:-/tmp}/secrets-reseal-request.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/repo/cache" "$T/state"

# ask-human stub: `ask` records the call and opens its key, `list --json` shows open keys,
# `clear <key>` closes one. One line per call in calls.log.
cat > "$T/ask-human.sh" <<'STUB'
#!/usr/bin/env bash
T="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sub="$1"; shift
case "$sub" in
  ask)
    key=""; args=("$@")
    for ((i = 0; i < ${#args[@]}; i++)); do [[ "${args[$i]}" == --key ]] && key="${args[$((i+1))]}"; done
    printf 'ask\t%s\n' "$(printf '%s' "$*" | tr '\n' '|')" >> "$T/calls.log"
    printf '%s\n' "$key" >> "$T/open.keys"
    for ((i = 0; i < ${#args[@]}; i++)); do [[ "${args[$i]}" == --cmd ]] && printf '%s' "${args[$((i+1))]}" > "$T/last-cmd"; done
    echo errand_stub ;;
  list)
    printf '['; sep=""
    while IFS= read -r k; do [[ -n "$k" ]] && { printf '%s{"key":"%s"}' "$sep" "$k"; sep=","; }; done < "$T/open.keys" 2>/dev/null
    printf ']\n' ;;
  clear)
    k="$1"; printf 'clear\t%s\n' "$*" >> "$T/calls.log"
    grep -vxF "$k" "$T/open.keys" > "$T/open.keys.new" 2>/dev/null; mv "$T/open.keys.new" "$T/open.keys" 2>/dev/null; echo "cleared 1" ;;
esac
STUB
chmod +x "$T/ask-human.sh"

req() {  # runs the script under test against the fake repo; sets OUT / RC
  OUT="$(SECRETS_PRIVATE_REPO="$T/repo" SECRETS_RESEAL_STATE_DIR="$T/state" SECRETS_RESEAL_ASK_HUMAN="$T/ask-human.sh" \
    SECRETS_RESEAL_CHECK_SCRIPT="/canonical/secrets-reseal-request.sh" bash "$REQ" "$@" 2>&1)"
  RC=$?
}
asks()  { local n; n=$(grep -c "^ask" "$T/calls.log" 2>/dev/null || true); echo "${n:-0}"; }
reset() { rm -f "$T/calls.log" "$T/open.keys" "$T/state/last-key"; : > "$T/open.keys"; }
cache_with() {  # keys of the sealed cache (values are irrelevant: only keys are read)
  printf '%s\n' "$@" | jq -R . | jq -s 'map({(.): "ENC[x]"}) | add + {"_seeded_at":"x","sops":{}}' > "$T/repo/cache/secrets.enc.json"
}
refs()    { printf '%s\n' "# header" "" "$@" > "$T/repo/headless.refs"; }
iu_refs() { printf '%s\n' "$@" > "$T/repo/headless.iu.refs"; }

# --- 1. nothing missing: nothing raised, status clean ------------------------
reset; refs "op://mini/a/one" "op://mini/a/two"; iu_refs "op://Athena/x/y"
cache_with "op://mini/a/one" "op://mini/a/two" "careerpartner|op://Athena/x/y"
req status;  assert_eq "1. status exits 0 when the cache is complete" "0" "$RC"
req needed;  assert_eq "1. the Errand check is false (exit 1) when nothing is missing" "1" "$RC"
req;         assert_eq "1. request exits 0" "0" "$RC"
assert_eq "1. nothing raised" "0" "$(asks)"

# --- 2. one new ref: ONE request, naming it, incremental, with a check -------
refs "op://mini/a/one" "op://mini/a/two" "op://mini/software-factory/TOKEN"
req status;  assert_eq "2. status exits 1 with a missing ref" "1" "$RC"
assert_contains "2. status names the ref" "op://mini/software-factory/TOKEN" "$OUT"
req needed;  assert_eq "2. the Errand check is true (exit 0) while a ref is missing" "0" "$RC"
req
assert_eq "2. exactly one request raised" "1" "$(asks)"
call="$(grep '^ask' "$T/calls.log")"
assert_contains "2. says 'one new ref'" "1 new ref" "$call"
assert_contains "2. names the exact ref" "op://mini/software-factory/TOKEN" "$call"
assert_contains "2. names the account" "account tkrumm" "$call"
assert_contains "2. runs the incremental path" "make secrets-seed-new" "$call"
assert_contains "2. carries a key per set" "--key secrets-reseal-" "$call"
assert_contains "2. carries the needed check" "needed" "$call"
assert_contains "2. the check names the canonical script" "/canonical/secrets-reseal-request.sh" "$call"

# --- 3. asking again for the same set is a no-op -----------------------------
req
assert_eq "3. a second request for the same set raises nothing" "1" "$(asks)"
assert_contains "3. says it is already requested" "already requested" "$OUT"

# --- 4. the same set in a different order is the same set --------------------
refs "op://mini/software-factory/TOKEN" "op://mini/a/two" "op://mini/a/one"
req
assert_eq "4. list order does not change the set" "1" "$(asks)"

# --- 5. a changed set replaces the old request --------------------------------
old_key="$(cat "$T/state/last-key")"
iu_refs "op://Athena/x/y" "op://Athena/new/ref"
req
assert_eq "5. a changed set raises a new request" "2" "$(asks)"
assert_contains "5. the older request is cleared as superseded" "clear	$old_key --as superseded" "$(grep '^clear' "$T/calls.log")"
call="$(grep '^ask' "$T/calls.log" | tail -1)"
assert_contains "5. the new IU ref is named" "op://Athena/new/ref" "$call"
assert_contains "5. the IU account is named" "account careerpartner" "$call"
assert_contains "5. sign-in hint lists both accounts" "tkrumm, careerpartner" "$call"
assert_eq "5. only one request is open" "1" "$(grep -c . "$T/open.keys")"

# --- 6. the cache catches up: the open request is cleared --------------------
cache_with "op://mini/a/one" "op://mini/a/two" "op://mini/software-factory/TOKEN" "careerpartner|op://Athena/x/y" "careerpartner|op://Athena/new/ref"
req
assert_contains "6. complete cache: nothing to request" "nothing to request" "$OUT"
assert_eq "6. the open request is closed" "0" "$(grep -c . "$T/open.keys")"
assert_eq "6. no new ask" "2" "$(asks)"

# --- 7. a bare ref in the IU list does not satisfy the namespaced key --------
reset; refs "op://mini/a/one"; iu_refs "op://Athena/x/y"
cache_with "op://mini/a/one" "op://Athena/x/y"        # the tkrumm key spelling: wrong account
req status
assert_eq "7. the IU ref is still missing (keys are namespaced per account)" "1" "$RC"

# --- 8. no cache at all: every ref is missing --------------------------------
rm -f "$T/repo/cache/secrets.enc.json"
refs "op://mini/a/one" "op://mini/a/two"; rm -f "$T/repo/headless.iu.refs"
req status
assert_contains "8. no cache: both refs listed" "2 ref(s) missing" "$OUT"

# --- 9. the Errand check never closes the request on a setup problem ---------
# The factory reads exit 1..125 from a check as "no longer needed". Setup failures must
# read as "still needed" (exit 0); only a deliberately complete cache answers 1.
SECRETS_PRIVATE_REPO="$T/nowhere" bash "$REQ" needed >/dev/null 2>&1; rc=$?
assert_eq "9. no refs file: the check answers 'still needed' (0), not 'done'" "0" "$rc"
printf '%s\n' "op://mini/a/one" > "$T/repo/headless.refs"; rm -f "$T/repo/headless.iu.refs"
printf 'not json' > "$T/repo/cache/secrets.enc.json"
req needed
assert_eq "9. an unreadable cache: every ref is missing, still needed (0)" "0" "$RC"

# --- 10. the MacBook command itself: pull over the 1Password agent, assert the refs ---
# Run the generated --cmd under a fake $HOME with stub git/hc: a checkout that lacks a
# missing ref must stop before sealing (nothing may be read and reported as success); one
# that has it (even with spaces in the ref) must reach `make secrets-seed-new`.
reset
refs "op://mini/a/one" "op://Athena Internal/x y/z"
rm -f "$T/repo/headless.iu.refs"; cache_with "op://mini/a/one"
req
mac="$T/mac"; mkdir -p "$mac/SourceRoot/dotfiles-private" "$mac/SourceRoot/dotfiles" "$mac/bin"
cat > "$mac/bin/git" <<'GITSTUB'
#!/usr/bin/env bash
printf 'sock=%s\n' "${SSH_AUTH_SOCK:-}" >> "$HOME/git.log"; exit 1
GITSTUB
cat > "$mac/bin/hc" <<'HCSTUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HOME/hc.log"
HCSTUB
chmod +x "$mac/bin/git" "$mac/bin/hc"
macrun() { HOME="$mac" PATH="$mac/bin:$PATH" bash -c "$(cat "$T/last-cmd")" 2>&1; }
printf 'op://mini/a/one\n' > "$mac/SourceRoot/dotfiles-private/headless.refs"
out="$(macrun)"; rc=$?
assert_eq "10. checkout lacking the ref: the command stops (nonzero)" "1" "$rc"
assert_contains "10. and says why" "is not in this Mac's dotfiles-private checkout" "$out"
assert_eq "10. nothing was sealed" "" "$(cat "$mac/hc.log" 2>/dev/null)"
assert_contains "10. the pull used the 1Password ssh agent socket" "sock=$mac/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock" "$(cat "$mac/git.log")"
printf 'op://mini/a/one\n  op://Athena Internal/x y/z \r\n' > "$mac/SourceRoot/dotfiles-private/headless.refs"
out="$(macrun)"; rc=$?
assert_eq "10. checkout holding the ref (despite a failed pull): runs" "0" "$rc"
assert_contains "10. a failed pull is announced, not fatal" "pull failed" "$out"
assert_contains "10. and runs the incremental seal" "make secrets-seed-new" "$(cat "$mac/hc.log")"

echo; echo "  $pass passed, $fail failed"
[[ $fail -eq 0 ]]
