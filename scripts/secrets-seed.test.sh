#!/usr/bin/env bash
# File-scoped shellcheck exception (deliberate, in a hermetic op stub written via a
# quoted heredoc):
#   SC2016 — single-quoted heredoc delimiter ('OPSTUB') is intentional: the stub's
#            own `$1`/`$HERE`/etc. must expand INSIDE the stub at its own run time,
#            never here while we write it out.
# shellcheck disable=SC2016
set -uo pipefail

# secrets-seed.test.sh — regression harness for secrets-seed.sh's `collect_refs`
# policy (docs/design.md D5, D9, D14).
#
# D14's "Known gap (follow-on)" names this as the obvious next hardening: the seed
# now seals TWO accounts under TWO different Private-vault rules (tkrumm: forbidden;
# careerpartner: allowed, owner-classified), and until now that branch logic was only
# hand-verified. A silent regression here has a large blast radius — it is the sole
# secret path onto the mini.
#
# Hermetic: builds a THROWAWAY dotfiles-private-shaped repo (age key, .sops.yaml,
# ref-lists) in a temp dir and stubs `op` on PATH, so no real 1Password account,
# biometric prompt, or network call is ever made. Never touches the real
# dotfiles-private repo, its cache, or any real secret. Runs anywhere with sops, age and
# jq: its own backend marker (below) makes the seed deliver locally, so there is no `ssh mini`.
#
# Usage: scripts/secrets-seed.test.sh   (exit 0 = all pass)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEED="$HERE/secrets-seed.sh"

pass=0
fail=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; [[ -n "${2:-}" ]] && printf '         %s\n' "$2"; fail=$((fail + 1)); }

# assert_eq <label> <expected> <actual>
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
# assert_contains <label> <needle> <haystack>
assert_contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "[$3] does not contain [$2]" ;; esac; }
# assert_not_contains <label> <needle> <haystack>
assert_not_contains() { case "$3" in *"$2"*) bad "$1" "[$3] unexpectedly contains [$2]" ;; *) ok "$1" ;; esac; }

# --- preflight ---------------------------------------------------------------
[[ -x "$SEED" ]]              || { echo "✗ seed not found/executable at $SEED"; exit 2; }
command -v sops       >/dev/null || { echo "✗ sops missing"; exit 2; }
command -v jq         >/dev/null || { echo "✗ jq missing"; exit 2; }
command -v age-keygen >/dev/null || { echo "✗ age-keygen missing"; exit 2; }

# --- build a throwaway dotfiles-private-shaped repo ---------------------------
TESTREPO="$(mktemp -d "${TMPDIR:-/tmp}/secrets-seed-test.XXXXXX")"
trap 'rm -rf "$TESTREPO"' EXIT
mkdir -p "$TESTREPO/bin" "$TESTREPO/cache"
# The seed picks its delivery from a backend marker. This private one says `cache` (the
# seed delivers locally, no ssh) regardless of which machine runs the harness.
printf 'cache\n' > "$TESTREPO/backend-cache"

# Throwaway age key — deliberately NOT the real ~/.config/sops/age/keys.txt. The seed
# only ever needs the RECIPIENT (public key), read out of .sops.yaml, to encrypt; the
# private half here exists solely so this harness can decrypt what got sealed, to
# assert on it.
age-keygen -o "$TESTREPO/key.txt" 2>/dev/null
RECIPIENT="$(age-keygen -y "$TESTREPO/key.txt")"

# Mirrors the real dotfiles-private/.sops.yaml shape (one creation_rule, same
# path_regex) so the seed's `sops --encrypt --filename-override cache/secrets.enc.json`
# resolves a recipient exactly as it would in production.
write_sops_yaml() {  # $1=comma-separated age recipient(s)
  printf 'creation_rules:\n  - path_regex: cache/secrets\\.enc\\.json$\n    age: %s\n' "$1" \
    > "$TESTREPO/.sops.yaml"
}
write_sops_yaml "$RECIPIENT"

# A fixed fake Private-vault UUID. 1Password vault ids are opaque ~26-char strings;
# the seed never validates their shape, only compares them, so any fixed string works.
# Shared between the op stub (served by `vault get`) and this harness (used to build
# UUID-form probe refs for case 4).
FAKE_UUID="zzzzzzzzzzzzzzzzzzzzzzzzzz"
printf '%s' "$FAKE_UUID" > "$TESTREPO/fake-uuid.txt"
printf '%s' "$RECIPIENT" > "$TESTREPO/recipient.txt"

# --- the one true stub-value format (sourced by BOTH the stub and this harness) --
# The op stub runs as a subprocess and cannot call a function defined in this script, so the
# shared definition lives in a file both sides source. Deterministic, non-empty, single-line,
# >= 5 chars (staying above the seed's sub-threshold-redaction warning). Slashes are squashed
# so a value stays one word.
cat > "$TESTREPO/stubfmt.sh" <<'FMT'
stub_value() { printf 'val-%s-%s' "$1" "${2//\//_}"; }
FMT

# --- stub `op` on PATH ---------------------------------------------------------
# Deterministic, hermetic replacement for the 1Password CLI. Every invocation's argv
# is appended to op-calls.log, so a case can assert `op` was NEVER reached — the
# fail-safe ordering that case 1 exists to lock.
cat > "$TESTREPO/bin/op" <<'OPSTUB'
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
printf '%s\n' "$*" >> "$HERE/op-calls.log"
# shellcheck source=/dev/null
. "$HERE/stubfmt.sh"

case "${1:-}" in
  whoami) exit 0 ;;
  signin|account)
    # account get / signin: an account with an `unreachable-<acct>` flag file cannot be reached.
    acct=""; while [[ $# -gt 0 ]]; do [[ "$1" == --account ]] && acct="${2:-}"; shift; done
    [[ -e "$HERE/unreachable-$acct" ]] && exit 1
    exit 0 ;;
  vault)
    [[ "${2:-}" == "get" ]] || exit 1
    printf '{"id":"%s"}\n' "$(cat "$HERE/fake-uuid.txt")"
    ;;
  inject)
    # The seed's fast path. Without this the stub would exit 1 here, resolve_batch
    # would fail, and every case below would silently exercise the per-ref FALLBACK
    # instead of the path that actually runs in production.
    shift
    acct=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --account) acct="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    # An account whose vaults are gone: every batch fails the way op words it.
    if [[ -e "$HERE/vaultgone-$acct" ]]; then
      echo "[ERROR] 2026/11/13 00:00:00 \"Athena Internal\" isn't a vault in this account. Specify the vault with its ID or name." >&2; exit 1
    fi
    # Case 17: op "succeeds" but its output does not start with a marker.
    [[ -e "$HERE/misalign.flag" ]] && printf 'garbage-before-the-first-marker\n'
    while IFS= read -r line; do
      case "$line" in
        '{{ '*' }}')
          ref="${line#\{\{ }"; ref="${ref% \}\}}"
          # Batched refs travel on stdin, so argv logging cannot see them. Log each
          # one separately or case 10 loses the only signal that dedupe works.
          printf '%s\n' "$ref" >> "$HERE/op-injected.log"
          if [[ "$ref" == *multiline* ]]; then printf 'line-one\nline-two\n'; continue; fi
          if [[ "$ref" == *readfail* ]]; then
            echo "[ERROR] 2026/10/17 00:00:00 \"x\" isn't an item in the \"test\" vault" >&2; exit 1
          fi
          # Access-path failures (cases 14-16). Real op 2.x strings: the authorization
          # dialog being dismissed, and a hang that only the watchdog ends.
          if [[ "$ref" == *authfail* ]]; then
            echo "[ERROR] 2026/10/17 00:00:00 could not read secret '$ref': authorization prompt dismissed" >&2; exit 1
          fi
          if [[ "$ref" == *slowinject* ]]; then sleep 30; exit 0; fi
          # A genuine bad ref: op's own wording for an unknown item.
          if [[ "$ref" == *badref* || "$ref" == *authread* ]]; then
            echo "[ERROR] 2026/10/17 00:00:00 could not read secret '$ref': \"x\" isn't an item in the \"test\" vault" >&2; exit 1
          fi
          stub_value "$acct" "$ref"; printf '\n' ;;
        *) printf '%s\n' "$line" ;;
      esac
    done
    ;;
  read)
    shift
    acct="" ref=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --account) acct="$2"; shift 2 ;;
        op://*) ref="$1"; shift ;;
        *) shift ;;
      esac
    done
    if [[ "$ref" == "op://Private/mini age key/public key" ]]; then
      cat "$HERE/recipient.txt"
      exit 0
    fi
    if [[ -e "$HERE/vaultgone-$acct" ]]; then
      echo "[ERROR] 2026/11/13 00:00:00 \"Athena Internal\" isn't a vault in this account. Specify the vault with its ID or name." >&2; exit 1
    fi
    # Probe ref for case 8 (multi-line value guard): any ref containing "multiline"
    # resolves to two lines, which the seed must refuse.
    if [[ "$ref" == *multiline* ]]; then
      printf 'line-one\nline-two\n'
      exit 0
    fi
    # Probe ref for case 11: any ref containing "readfail" makes `op read` fail the way a
    # real one does — non-zero, with a diagnostic on stderr.
    if [[ "$ref" == *readfail* ]]; then
      echo "[ERROR] 2026/07/16 00:00:00 \"x\" isn't an item in the \"test\" vault" >&2
      exit 1
    fi
    # Cases 14-16: authfail/authread = the access path breaks (op names no ref problem);
    # badref = a genuine unknown item.
    if [[ "$ref" == *authfail* || "$ref" == *authread* ]]; then
      echo "[ERROR] 2026/10/17 00:00:00 could not read secret '$ref': authorization prompt dismissed" >&2
      exit 1
    fi
    if [[ "$ref" == *badref* ]]; then
      echo "[ERROR] 2026/10/17 00:00:00 could not read secret '$ref': \"x\" isn't an item in the \"test\" vault" >&2
      exit 1
    fi
    stub_value "$acct" "$ref"; printf '\n'
    ;;
  *) exit 1 ;;
esac
OPSTUB
chmod +x "$TESTREPO/bin/op"

# --- per-case helpers ----------------------------------------------------------
write_refs() {  # $1=headless.refs|headless.iu.refs  $2..=lines (verbatim)
  local file="$1"; shift
  : > "$TESTREPO/$file"
  local line
  for line in "$@"; do
    printf '%s\n' "$line" >> "$TESTREPO/$file"
  done
}

# stub_value is defined ONCE, in $TESTREPO/stubfmt.sh (written above), and sourced by BOTH
# this harness and the op stub subprocess. It was briefly duplicated — the stub generating
# values inline while the harness recomputed the expected value from a hand-mirrored copy.
# That is the same hand-mirroring the D14 drift guard exists to catch in the real code: the
# two would agree by convention until one changed, and cases 2/10 would then compare against
# a stale expectation with no message explaining why. One definition, no drift.
# shellcheck source=/dev/null
. "$TESTREPO/stubfmt.sh"

SEED_ARGS=()
reset_case() {  # clears per-case state; restores the canonical single-recipient .sops.yaml
  SEED_ARGS=()
  rm -f "$TESTREPO/headless.refs" "$TESTREPO/headless.iu.refs" "$TESTREPO/op-calls.log" \
        "$TESTREPO/op-injected.log" "$TESTREPO/misalign.flag" "$TESTREPO"/unreachable-* "$TESTREPO"/vaultgone-*
  rm -rf "$TESTREPO/cache"
  mkdir -p "$TESTREPO/cache"
  write_sops_yaml "$RECIPIENT"
}

# run_seed: invoke the seed under test against $TESTREPO with the op stub prepended
# to PATH. Sets SEED_ERR / SEED_CODE for the following assertions (stdout is only the
# human-review ref echo — not asserted on, so it's discarded rather than captured).
run_seed() {
  local errf
  errf="$(mktemp "$TESTREPO/stderr.XXXXXX")"
  # SECRETS_SEED_OP_BATCH is forwarded EXPLICITLY: a `VAR=x run_seed` prefix sets the
  # variable for the function call but bash does not export it onward to the seed
  # process, so case 13's fallback run would silently have taken the batch path.
  PATH="$TESTREPO/bin:$PATH" SECRETS_PRIVATE_REPO="$TESTREPO" \
    SECRETS_SEED_BACKEND_MARKER="${SECRETS_SEED_BACKEND_MARKER:-$TESTREPO/backend-cache}" SECRETS_SEED_AGE_KEY_FILE="$TESTREPO/key.txt" \
    SECRETS_SEED_OP_BATCH="${SECRETS_SEED_OP_BATCH:-1}" \
    SECRETS_SEED_OP_BATCH_TIMEOUT="${SECRETS_SEED_OP_BATCH_TIMEOUT:-180}" \
    "$SEED" ${SEED_ARGS[@]+"${SEED_ARGS[@]}"} >/dev/null 2>"$errf"
  SEED_CODE=$?
  SEED_ERR="$(cat "$errf")"
  rm -f "$errf"
}

decrypt_cache() {  # prints the sealed cache's plaintext JSON (throwaway key only)
  SOPS_AGE_KEY_FILE="$TESTREPO/key.txt" sops --decrypt --input-type json --output-type json \
    "$TESTREPO/cache/secrets.enc.json" 2>/dev/null
}

assert_refused()  { if [[ "$SEED_CODE" -ne 0 ]]; then ok "$1"; else bad "$1" "exited 0 (expected non-zero)"; fi; }
assert_accepted() { if [[ "$SEED_CODE" -eq 0 ]]; then ok "$1"; else bad "$1" "exited $SEED_CODE (expected 0): $SEED_ERR"; fi; }

assert_cache_absent() {  # $1=label
  if [[ -e "$TESTREPO/cache/secrets.enc.json" ]]; then
    bad "$1" "cache/secrets.enc.json unexpectedly present"
  else
    ok "$1"
  fi
}

assert_op_never_called() {  # $1=label
  if [[ -s "$TESTREPO/op-calls.log" ]]; then
    bad "$1" "op-calls.log unexpectedly non-empty: $(cat "$TESTREPO/op-calls.log")"
  else
    ok "$1"
  fi
}

echo "secrets-seed harness (temp repo: $TESTREPO)"

# === 1. POLICY: op://Private in headless.refs refused before any op call =====
reset_case
write_refs headless.refs "op://test/personal/x" "op://Private/x/y"
run_seed
assert_refused "1. policy: op://Private in headless.refs refused"
assert_contains "1. policy: refusal names the offending ref" "op://Private/x/y" "$SEED_ERR"
assert_op_never_called "1. policy: refusal happens BEFORE any op call (fail-safe ordering)"
assert_cache_absent "1. policy: cache untouched on refusal"

# === 2. POLICY: careerpartner Private (headless.iu.refs) accepted + seals ====
reset_case
write_refs headless.refs "op://test/personal/x"
write_refs headless.iu.refs "op://Private/feuer/api-server-key"
run_seed
assert_accepted "2. policy: careerpartner Private ref (headless.iu.refs) accepted"
keys="$(decrypt_cache | jq -r 'keys[]' | sort | tr '\n' ',')"
assert_contains "2. policy: careerpartner Private ref sealed under a namespaced key" \
  "careerpartner|op://Private/feuer/api-server-key" "$keys"
val="$(decrypt_cache | jq -r '."careerpartner|op://Private/feuer/api-server-key"')"
assert_eq "2. policy: sealed value matches what op resolved" \
  "$(stub_value careerpartner op://Private/feuer/api-server-key)" "$val"

# === 3. POLICY: case-insensitive vault-name check (PRIVATE / pRivate) ========
reset_case
write_refs headless.refs "op://PRIVATE/x/y" "op://pRivate/x/y"
run_seed
assert_refused "3. policy: case-insensitive Private-name check refuses"
assert_contains "3. policy: refusal names the PRIVATE-spelled ref" "op://PRIVATE/x/y" "$SEED_ERR"
assert_contains "3. policy: refusal names the pRivate-spelled ref" "op://pRivate/x/y" "$SEED_ERR"
assert_op_never_called "3. policy: case-insensitive refusal also happens before any op call"

# === 4. UUID BYPASS: refused in EITHER list, not just headless.refs ==========
# A UUID-form Private ref passes the by-NAME check (its vault segment isn't literally
# "private"), so it must be caught by the by-UUID check instead — which the seed
# checks against every ref regardless of which list (and therefore which account
# label) it came from. This is the bypass a review already caught once.
reset_case
write_refs headless.refs "op://test/personal/x" "op://$FAKE_UUID/item/field"
run_seed
assert_refused "4a. uuid: Private-by-UUID refused in headless.refs"
assert_contains "4a. uuid: refusal names the by-UUID Private guard" \
  "references tkrumm's Private vault by UUID" "$SEED_ERR"
assert_cache_absent "4a. uuid: cache untouched (headless.refs bypass attempt)"

reset_case
write_refs headless.refs "op://test/personal/x"
write_refs headless.iu.refs "op://$FAKE_UUID/item/field"
run_seed
assert_refused "4b. uuid: Private-by-UUID refused even when smuggled into headless.iu.refs"
# Assert the GUARD's own message, not just a non-zero exit. Today a disabled UUID guard
# would still be caught here (the ref would sail on to encrypt+deliver, tripping
# assert_cache_absent), so this is not currently a wrong-reason pass — but that is an
# accident of check ORDER, not of the assertion. Naming the guard keeps the case pinned
# to the guard if the seed's checks are ever reordered.
assert_contains "4b. uuid: refusal names the by-UUID Private guard (not an unrelated failure)" \
  "references tkrumm's Private vault by UUID" "$SEED_ERR"
assert_contains "4b. uuid: refusal attributes the ref to the IU list it was smuggled into" \
  "careerpartner list" "$SEED_ERR"
assert_cache_absent "4b. uuid: cache untouched (headless.iu.refs smuggle attempt)"

# === 5. KEY SHAPE: sealed key set matches cache_key() exactly ================
reset_case
write_refs headless.refs "op://test/app/token" "op://test/other/field"
write_refs headless.iu.refs "op://Prometheus Internal/db/password" "op://Private/feuer/api-server-key"
run_seed
assert_accepted "5. shape: mixed personal + IU refs (incl. a spaced vault name) seal"
expected="$(printf '%s\n' \
  '_seeded_at' \
  'careerpartner|op://Private/feuer/api-server-key' \
  'careerpartner|op://Prometheus Internal/db/password' \
  'op://test/app/token' \
  'op://test/other/field' | sort)"
actual="$(decrypt_cache | jq -r 'keys[]' | sort)"
assert_eq "5. shape: sealed key set is EXACTLY tkrumm-bare + careerpartner-namespaced + _seeded_at" \
  "$expected" "$actual"

# === 6. IU LIST OPTIONAL: absent headless.iu.refs seals personal-only (D14) ==
reset_case
write_refs headless.refs "op://test/app/token"
run_seed
assert_accepted "6. optional: absent headless.iu.refs still seeds successfully"
keys="$(decrypt_cache | jq -r 'keys[]' | sort | tr '\n' ',')"
assert_contains "6. optional: personal ref sealed bare" "op://test/app/token" "$keys"
assert_not_contains "6. optional: no careerpartner-namespaced keys present" "careerpartner|" "$keys"

# === 7. Non-op:// line refused, in either list ================================
reset_case
write_refs headless.refs "not-a-ref"
run_seed
assert_refused "7a. policy: non-op:// line in headless.refs refused"
assert_contains "7a. policy: refusal names the bad line" "not-a-ref" "$SEED_ERR"

reset_case
write_refs headless.refs "op://test/app/token"
write_refs headless.iu.refs "also-not-a-ref"
run_seed
assert_refused "7b. policy: non-op:// line in headless.iu.refs refused"
assert_contains "7b. policy: refusal names the bad line" "also-not-a-ref" "$SEED_ERR"

# === 8. Multi-line value refused, cache left UNTOUCHED (D8) ==================
reset_case
# Seed a pre-existing cache file first (arbitrary bytes — the seed never reads an
# existing cache, only potentially overwrites it), to prove D8's "cache untouched"
# contract, not merely "no NEW cache created".
printf 'PRE-EXISTING-CACHE-DO-NOT-TOUCH\n' > "$TESTREPO/cache/secrets.enc.json"
before="$(cat "$TESTREPO/cache/secrets.enc.json")"
write_refs headless.refs "op://test/app/token" "op://test/multiline/value"
run_seed
assert_refused "8. guard: multi-line resolved value refused"
assert_contains "8. guard: refusal names the offending ref" "op://test/multiline/value" "$SEED_ERR"
after="$(cat "$TESTREPO/cache/secrets.enc.json")"
assert_eq "8. guard: pre-existing cache left byte-identical (D8)" "$before" "$after"

# === 9. RECIPIENT PINNING: an extra .sops.yaml recipient is refused (D9.3) ===
reset_case
EXTRA_KEY="$TESTREPO/extra-key.txt"
age-keygen -o "$EXTRA_KEY" 2>/dev/null
EXTRA_RECIPIENT="$(age-keygen -y "$EXTRA_KEY")"
write_sops_yaml "$RECIPIENT,$EXTRA_RECIPIENT"
write_refs headless.refs "op://test/app/token"
run_seed
assert_refused "9. recipient: extra .sops.yaml recipient refused"
assert_contains "9. recipient: refusal names the tampering" \
  "does not match exactly the trusted recipient" "$SEED_ERR"
assert_cache_absent "9. recipient: cache untouched on pinning refusal"

# === 10. Dedupe: a repeated ref is RESOLVED once, not merely sealed once =====
# Not in the required minimum, but a real collect_refs branch (the in-list dedupe loop)
# with no other coverage above.
#
# Assert on the op-read COUNT, not the sealed key count. Mutation-testing proved the
# obvious assertion worthless: with the dedupe loop deleted the suite stayed green,
# because a duplicate ref folds through `jq reduce` — which just overwrites — and still
# yields exactly one cache key. The sealed cache literally cannot distinguish the two
# implementations. What dedupe actually buys is observable one level up: each duplicate
# would otherwise cost a SECOND `op read`, i.e. a second biometric prompt for a value
# already in hand, and inflate the human-review ref count that the explicit-list model
# depends on being accurate.
reset_case
write_refs headless.refs "op://test/app/token" "op://test/app/token" "op://test/other/field"
run_seed
assert_accepted "10. dedupe: repeated ref within one list still seeds successfully"
count="$(decrypt_cache | jq -r 'keys[]' | grep -c '^op://test/app/token$')"
assert_eq "10. dedupe: repeated ref appears exactly once in the sealed cache" "1" "$count"
# Counted across BOTH resolve paths: a batched ref arrives on `op inject`'s stdin
# (op-injected.log) and a fallback ref as `op read` argv (op-calls.log). Asserting on
# only one would silently pass the moment the other path is taken.
reads="$(grep -c "^read .*op://test/app/token$" "$TESTREPO/op-calls.log" || true)"
injected="$(grep -c "^op://test/app/token$" "$TESTREPO/op-injected.log" 2>/dev/null || true)"
injected="${injected:-0}"
assert_eq "10. dedupe: repeated ref is resolved exactly ONCE (no second prompt)" "1" "$(( reads + injected ))"

# === 11. A failing `op read` aborts before any crypto, cache untouched (D5.4) ==
# The seed resolves every ref before it seals anything, so ONE failure must abort with the
# cache untouched — never a partial seal. Untested until now.
reset_case
printf 'PRE-EXISTING-CACHE-DO-NOT-TOUCH\n' > "$TESTREPO/cache/secrets.enc.json"
before="$(cat "$TESTREPO/cache/secrets.enc.json")"
# The stub fails `read` for any ref containing "readfail" (see OPSTUB).
write_refs headless.refs "op://test/app/token" "op://test/readfail/x" "op://test/other/field"
run_seed
assert_refused "11. resolve: a failing op read aborts the seed"
assert_contains "11. resolve: refusal names the failing ref" "op://test/readfail/x" "$SEED_ERR"
assert_contains "11. resolve: refusal states the cache was left alone" "cache untouched" "$SEED_ERR"
after="$(cat "$TESTREPO/cache/secrets.enc.json")"
assert_eq "11. resolve: pre-existing cache left byte-identical (no partial seal)" "$before" "$after"

# === 12. An empty / comment-only headless.refs is refused ====================
# `die "headless.refs has no references"`. Reachable by a bad edit, and sealing an empty
# cache would silently strip every secret from the mini — fail closed instead.
reset_case
write_refs headless.refs "# only a comment" ""
run_seed
assert_refused "12. empty: comment-only headless.refs refused"
assert_contains "12. empty: refusal explains no references were found" "no references" "$SEED_ERR"
assert_cache_absent "12. empty: cache untouched"

# --- case 13: both resolve paths reach the same cache -------------------------
#
# Every case above runs the BATCHED path (one `op inject` per account). The per-ref
# path is not dead code — it is the diagnostic fallback the seed takes whenever a
# batch fails, and it is what produces "which ref is wrong" for a human. A fallback
# that is only exercised when something is already going wrong is a fallback nobody
# has tested, so pin it explicitly and assert the two paths agree byte for byte.
reset_case
write_refs headless.refs "op://test/app/token" "op://test/other/field"
run_seed
assert_accepted "13. paths: batched resolve seals successfully"
batched_keys="$(decrypt_cache | jq -S 'del(._seeded_at)')"
batched_injects="$(grep -c . "$TESTREPO/op-injected.log" 2>/dev/null || true)"
batched_injects="${batched_injects:-0}"   # grep -c on a missing file prints nothing
assert_eq "13. paths: batched resolve used op inject, not per-ref reads" "2" "$batched_injects"

reset_case
write_refs headless.refs "op://test/app/token" "op://test/other/field"
SECRETS_SEED_OP_BATCH=0 run_seed
assert_accepted "13. paths: forced per-ref fallback also seals successfully"
fallback_keys="$(decrypt_cache | jq -S 'del(._seeded_at)')"
fallback_injects="$(grep -c . "$TESTREPO/op-injected.log" 2>/dev/null || true)"
fallback_injects="${fallback_injects:-0}" # the whole point: the file never appears
assert_eq "13. paths: SECRETS_SEED_OP_BATCH=0 really skips the batch" "0" "$fallback_injects"
assert_eq "13. paths: both resolve paths seal an identical cache" "$batched_keys" "$fallback_keys"

# --- cases 14-16: the op access path breaks (TCC / authorization / hang) ---------
#
# Regression for the dialog storm: a batch that died on the macOS "op wants to access
# data from other apps" dialog used to fall back to one `op read` PROCESS per ref, up to
# 3 attempts each, and every process raised its own dialog (dozens, and Allow does not
# persist). Now only a REF problem may fan out; an access failure aborts at once with
# the Full Disk Access instruction, after a small, bounded number of op processes.
OP_REAL="$(realpath "$TESTREPO/bin/op")"
# count_op <inject|read>: ref-resolving op processes only (the recipient read is not one)
count_op() {
  local n=0
  case "$1" in
    inject) n=$(grep -c '^inject ' "$TESTREPO/op-calls.log" 2>/dev/null || true) ;;
    read)   n=$(grep '^read ' "$TESTREPO/op-calls.log" 2>/dev/null | grep -vc 'mini age key' || true) ;;
  esac
  echo "${n:-0}"
}
assert_fda_abort() {  # $1=label prefix
  assert_refused "$1: aborts"
  assert_contains "$1: names the exact resolved op path" "$OP_REAL" "$SEED_ERR"
  assert_contains "$1: points at Full Disk Access" "Full Disk Access" "$SEED_ERR"
  assert_contains "$1: says Allow does not persist" "Allow button does NOT persist" "$SEED_ERR"
  assert_contains "$1: states the cache was left alone" "cache untouched" "$SEED_ERR"
  assert_cache_absent "$1: nothing sealed or delivered"
}

# === 14. batch authorization error: abort, ZERO per-ref reads ================
reset_case
write_refs headless.refs "op://test/app/token" "op://test/authfail/x" "op://test/other/field"
run_seed
assert_fda_abort "14a. access: batch authorization error"
assert_eq "14a. access: exactly one op inject, no per-ref reads (no fan-out)" "1 0" "$(count_op inject) $(count_op read)"

# a failing FIRST account must not go on to start the second account's batch
reset_case
write_refs headless.refs "op://test/authfail/x"
write_refs headless.iu.refs "op://Private/feuer/api-server-key"
run_seed
assert_fda_abort "14b. access: failing first account"
assert_eq "14b. access: the second account's batch never started" "1 0" "$(count_op inject) $(count_op read)"

# === 15. batch hangs (watchdog, rc 124): abort, zero per-ref reads ===========
reset_case
write_refs headless.refs "op://test/app/token" "op://test/slowinject/x"
SECRETS_SEED_OP_BATCH_TIMEOUT=2 run_seed
assert_fda_abort "15. access: batch timeout"
assert_contains "15. access: timeout is reported as the watchdog kill" "killed by the watchdog" "$SEED_ERR"
assert_eq "15. access: exactly one op inject, no per-ref reads (no fan-out)" "1 0" "$(count_op inject) $(count_op read)"

# === 16. bad ref on inject, then per-ref diagnostics (the kept diagnostic path) ===
reset_case
write_refs headless.refs "op://test/app/token" "op://test/badref/x" "op://test/other/field"
run_seed
assert_refused "16a. ref problem: aborts (dead ref)"
assert_contains "16a. ref problem: names the bad ref" "op://test/badref/x" "$SEED_ERR"
assert_contains "16a. ref problem: says it fell back per-ref to find it" "falling back to per-reference reads" "$SEED_ERR"
assert_not_contains "16a. ref problem: is NOT reported as an access failure" "Full Disk Access" "$SEED_ERR"
assert_contains "16a. ref problem: states the cache was left alone" "cache untouched" "$SEED_ERR"
assert_eq "16a. ref problem: one inject, then one read per ref (good refs read too)" "1 3" "$(count_op inject) $(count_op read)"
assert_cache_absent "16a. ref problem: nothing sealed"

# the circuit breaker inside the per-ref loop: a bad ref first (collected), then the
# access path breaks on the second ref -> stop, the third is never read
reset_case
write_refs headless.refs "op://test/badref/x" "op://test/authread/y" "op://test/other/field"
run_seed
assert_fda_abort "16b. breaker: access error mid per-ref loop"
assert_eq "16b. breaker: one inject + exactly two reads (third ref never read)" "1 2" "$(count_op inject) $(count_op read)"

# per-ref mode (batch off): the first access failure stops the loop, no retry
reset_case
write_refs headless.refs "op://test/app/token" "op://test/authfail/x" "op://test/other/field"
SECRETS_SEED_OP_BATCH=0 run_seed
assert_fda_abort "16c. breaker: access error with batching off"
assert_eq "16c. breaker: no inject, reads stop at the failing ref (no retry, no third read)" "0 2" "$(count_op inject) $(count_op read)"


# === 17. batch output misaligned (op succeeded, output untrustworthy): abort, no fan-out ===
reset_case
write_refs headless.refs "op://test/app/token" "op://test/other/field"
: > "$TESTREPO/misalign.flag"
run_seed
assert_fda_abort "17. misaligned batch output"
assert_contains "17. misaligned batch output: names the fault" "did not line up" "$SEED_ERR"
assert_eq "17. misaligned batch output: one inject, zero per-ref reads" "1 0" "$(count_op inject) $(count_op read)"

# === 18. an item name inside an AUTH error must not read as a ref problem ====
# The stub echoes the ref inside the error; this ref's vault name contains op's own
# ref-error phrase. The verdict must come from op's reason clause, not the echo.
reset_case
write_refs headless.refs "op://test/authfail isn't an item/x" "op://test/other/field"
run_seed
assert_fda_abort "18a. echoed phrase, batch"
assert_eq "18a. echoed phrase, batch: one inject, zero per-ref reads" "1 0" "$(count_op inject) $(count_op read)"
reset_case
write_refs headless.refs "op://test/other/field" "op://test/authfail isn't an item/x" "op://test/third/field"
SECRETS_SEED_OP_BATCH=0 run_seed
assert_fda_abort "18b. echoed phrase, per-ref"
assert_eq "18b. echoed phrase, per-ref: stops at the failing ref" "0 2" "$(count_op inject) $(count_op read)"

# === 19-23. INCREMENTAL + PER-ACCOUNT RESEAL (issue 1022) ====================
# The owner was asked to reseal far too often, and one unreachable account (or one new
# ref) made it a full biometric reseal every time. Contract:
#   - --new-only reads ONLY refs the current cache lacks; every other value is kept;
#   - an unreachable account keeps its existing values, is named once, exit 3;
#   - a dead ref in a REACHABLE account still fails the run closed with the full list.
injected_refs() { cat "$TESTREPO/op-injected.log" 2>/dev/null || true; }
read_refs()     { grep '^read ' "$TESTREPO/op-calls.log" 2>/dev/null | grep -v 'mini age key' | sed 's/^read .* //' || true; }
resolved_refs() { { injected_refs; read_refs; } | sort | tr '\n' ' '; }
cache_val()     { decrypt_cache | jq -r --arg k "$1" '.[$k] // "<absent>"'; }
cache_mtime()   { stat -f %m "$TESTREPO/cache/secrets.enc.json"; }
fresh_calls()   { rm -f "$TESTREPO/op-calls.log" "$TESTREPO/op-injected.log"; }
mtime_of_seal() { cache_mtime; }

# --- 19a. adding ONE ref reads exactly that one ref ---------------------------
reset_case
write_refs headless.refs "op://test/a/one" "op://test/a/two"
write_refs headless.iu.refs "op://test/c/three"
run_seed
assert_accepted "19a. baseline full seal"
seeded0="$(cache_val _seeded_at)"; mtime0="$(mtime_of_seal)"
sleep 1                                  # a changed stamp/mtime would now differ
write_refs headless.refs "op://test/a/one" "op://test/a/two" "op://test/a/NEW"
fresh_calls
SEED_ARGS=(--new-only); run_seed
assert_accepted "19a. --new-only with one new ref succeeds"
assert_eq "19a. exactly one ref was read from 1Password" "op://test/a/NEW " "$(resolved_refs)"
assert_eq "19a. the new ref is sealed" "$(stub_value tkrumm op://test/a/NEW)" "$(cache_val op://test/a/NEW)"
assert_eq "19a. an old tkrumm value is kept" "$(stub_value tkrumm op://test/a/one)" "$(cache_val op://test/a/one)"
assert_eq "19a. an old careerpartner value is kept" "$(stub_value careerpartner op://test/c/three)" "$(cache_val 'careerpartner|op://test/c/three')"
assert_eq "19a. _seeded_at keeps the last COMPLETE reseal's stamp" "$seeded0" "$(cache_val _seeded_at)"
assert_eq "19a. the file mtime keeps the last COMPLETE reseal's time" "$mtime0" "$(cache_mtime)"
if grep -q 'account get --account careerpartner' "$TESTREPO/op-calls.log"; then
  bad "19a. an account with nothing new is not contacted" "$(cat "$TESTREPO/op-calls.log")"
else
  ok "19a. an account with nothing new is not contacted"
fi

# --- 19b. nothing new: no 1Password read at all, cache untouched --------------
mtime1="$(cache_mtime)"
fresh_calls
SEED_ARGS=(--new-only); run_seed
assert_accepted "19b. --new-only with nothing new succeeds"
assert_eq "19b. nothing read" "" "$(resolved_refs)"
assert_eq "19b. cache file untouched" "$mtime1" "$(cache_mtime)"

# --- 19c. a ref removed from the list drops out; a full run refreshes the stamp --
write_refs headless.refs "op://test/a/one" "op://test/a/NEW"
SEED_ARGS=(--new-only); run_seed
assert_accepted "19c. --new-only after a removal succeeds"
assert_eq "19c. the removed ref is gone from the cache" "<absent>" "$(cache_val op://test/a/two)"
sleep 1; SEED_ARGS=()
fresh_calls
run_seed
assert_accepted "19c. a plain run is still a full reseal"
assert_eq "19c. full run reads every ref" "op://test/a/NEW op://test/a/one op://test/c/three " "$(resolved_refs)"
if [[ "$(cache_val _seeded_at)" != "$seeded0" ]]; then ok "19c. a complete full reseal refreshes _seeded_at"; else bad "19c. a complete full reseal refreshes _seeded_at"; fi

# --- 19d. no readable cache: --new-only degrades to a full read ----------------
reset_case
write_refs headless.refs "op://test/a/one" "op://test/a/two"
SEED_ARGS=(--new-only); run_seed
assert_accepted "19d. --new-only with no cache yet succeeds"
assert_eq "19d. without a cache every ref is read" "op://test/a/one op://test/a/two " "$(resolved_refs)"

# --- 20. an unreachable account keeps its values; the reachable one still seals --
reset_case
write_refs headless.refs "op://test/a/one"
write_refs headless.iu.refs "op://test/c/old"
run_seed
assert_accepted "20. baseline full seal"
seeded_base="$(cache_val _seeded_at)"; sleep 1   # a refreshed stamp would now differ
write_refs headless.refs "op://test/a/one" "op://test/a/new1"
write_refs headless.iu.refs "op://test/c/old" "op://test/c/new2"
: > "$TESTREPO/unreachable-careerpartner"
fresh_calls
SEED_ARGS=(--new-only); run_seed
assert_eq "20a. partial seal exits 3" "3" "$SEED_CODE"
assert_eq "20a. the reachable account's new ref is sealed" "$(stub_value tkrumm op://test/a/new1)" "$(cache_val op://test/a/new1)"
assert_eq "20a. the unreachable account's old value is kept" "$(stub_value careerpartner op://test/c/old)" "$(cache_val 'careerpartner|op://test/c/old')"
assert_eq "20a. its new ref has no value and is NOT sealed" "<absent>" "$(cache_val 'careerpartner|op://test/c/new2')"
assert_eq "20a. only the reachable account's new ref was read" "op://test/a/new1 " "$(resolved_refs)"
assert_contains "20a. the account is named" "account careerpartner is unreachable" "$SEED_ERR"
assert_contains "20a. the unsealed ref is named" "op://test/c/new2" "$SEED_ERR"
assert_eq "20a. the account is reported exactly once" "1" "$(grep -c 'account careerpartner is unreachable' <<<"$SEED_ERR")"

# a full run with the same account down: tkrumm refreshed, careerpartner kept
SEED_ARGS=()
fresh_calls
run_seed
assert_eq "20b. full run with an account down exits 3" "3" "$SEED_CODE"
assert_eq "20b. full run still reads the reachable account's refs" "op://test/a/new1 op://test/a/one " "$(resolved_refs)"
assert_eq "20b. full run keeps the unreachable account's value" "$(stub_value careerpartner op://test/c/old)" "$(cache_val 'careerpartner|op://test/c/old')"

# --require-complete (secrets-rotate) must refuse a partial cache outright
mtime2="$(cache_mtime)"
SEED_ARGS=(--require-complete); run_seed
assert_refused "20c. --require-complete refuses when an account is unreachable"
assert_eq "20c. and leaves the cache as it was" "$mtime2" "$(cache_mtime)"

# partial seals keep the stamp of the last complete one
assert_eq "20d. partial seals (20a, 20b) did not refresh _seeded_at" "$seeded_base" "$(cache_val _seeded_at)"

# an unreachable account with NO readable cache to keep its values from must refuse, not wipe
reset_case
write_refs headless.refs "op://test/a/one"
write_refs headless.iu.refs "op://test/c/old"
: > "$TESTREPO/unreachable-careerpartner"
run_seed
assert_refused "20e. unreachable account + no readable cache: refuses"
assert_contains "20e. says why" "cannot be read to keep its values" "$SEED_ERR"
assert_cache_absent "20e. nothing delivered"

# --- 21. an account whose vaults are all gone is unreachable, not a dead-ref list --
reset_case
write_refs headless.refs "op://test/a/one"
write_refs headless.iu.refs "op://Athena Internal/x/one" "op://Athena Internal/y/two"
run_seed
assert_accepted "21. baseline full seal"
: > "$TESTREPO/vaultgone-careerpartner"
fresh_calls
run_seed
assert_eq "21. vault-less account: partial seal exits 3 (not a hard failure)" "3" "$SEED_CODE"
assert_eq "21. its old values are kept" "$(stub_value careerpartner 'op://Athena Internal/x/one')" "$(cache_val 'careerpartner|op://Athena Internal/x/one')"
assert_contains "21. the account is named with the reason" "none of its vaults exist" "$SEED_ERR"
assert_eq "21. the other account was still refreshed" "$(stub_value tkrumm op://test/a/one)" "$(cache_val op://test/a/one)"

# --- 21b. ONE new ref with a mistyped vault is a dead ref, not a vanished account --
reset_case
write_refs headless.refs "op://test/a/one"
write_refs headless.iu.refs "op://Athena Internal/x/one"
run_seed
assert_accepted "21b. baseline full seal"
write_refs headless.iu.refs "op://Athena Internal/x/one" "op://Athena Intrenal/x/typo"
: > "$TESTREPO/vaultgone-careerpartner"
SEED_ARGS=(--new-only); run_seed
assert_refused "21b. a single mistyped-vault ref fails closed"
assert_contains "21b. and is named in the dead-ref list" "op://Athena Intrenal/x/typo" "$SEED_ERR"

# --- 22. a dead ref in a REACHABLE account still fails the run closed, full list --
reset_case
write_refs headless.refs "op://test/a/one"
run_seed
assert_accepted "22. baseline full seal"
before="$(decrypt_cache)"
write_refs headless.refs "op://test/a/one" "op://test/badref/x" "op://test/badref/y" "op://test/a/fine"
write_refs headless.iu.refs "op://test/c/one"
: > "$TESTREPO/unreachable-careerpartner"
SEED_ARGS=(--new-only); run_seed
assert_refused "22. dead refs in a reachable account fail closed (even with the other account down)"
assert_contains "22. first dead ref listed" "op://test/badref/x" "$SEED_ERR"
assert_contains "22. second dead ref listed" "op://test/badref/y" "$SEED_ERR"
assert_contains "22. states the cache was left alone" "cache untouched" "$SEED_ERR"
assert_eq "22. the existing cache is byte-for-byte what it was" "$before" "$(decrypt_cache)"

# --- 23. sealing from a MacBook: the current cache is read back over ssh --------
# `ssh mini` is stubbed to run the remote script locally under a fake $HOME whose
# SourceRoot/dotfiles-private is the throwaway repo, so the REMOTE branches (decrypt on
# the mini, mtime-preserving delivery) run for real.
reset_case
FAKEHOME="$(mktemp -d "$TESTREPO/home.XXXXXX")"
mkdir -p "$FAKEHOME/SourceRoot" "$FAKEHOME/.config/sops/age"
ln -s "$TESTREPO" "$FAKEHOME/SourceRoot/dotfiles-private"
cp "$TESTREPO/key.txt" "$FAKEHOME/.config/sops/age/keys.txt"
printf 'op\n' > "$TESTREPO/backend-op"
cat > "$TESTREPO/bin/ssh" <<'SSHSTUB'
#!/usr/bin/env bash
# last argument is the remote script; stdin passes through (the ciphertext)
script="${*: -1}"
HOME="$(cat "$(dirname "${BASH_SOURCE[0]}")/../fakehome")" exec bash -c "$script"
SSHSTUB
chmod +x "$TESTREPO/bin/ssh"
printf '%s' "$FAKEHOME" > "$TESTREPO/fakehome"
write_refs headless.refs "op://test/a/one" "op://test/a/two"
SECRETS_SEED_BACKEND_MARKER="$TESTREPO/backend-op" run_seed
assert_accepted "23. baseline full seal delivered over ssh"
mtime3="$(cache_mtime)"; sleep 1
write_refs headless.refs "op://test/a/one" "op://test/a/two" "op://test/a/NEW"
fresh_calls
SEED_ARGS=(--new-only); SECRETS_SEED_BACKEND_MARKER="$TESTREPO/backend-op" run_seed
assert_accepted "23. --new-only over ssh succeeds"
assert_eq "23. over ssh: exactly one ref read" "op://test/a/NEW " "$(resolved_refs)"
assert_eq "23. over ssh: old value kept (decrypted on the mini)" "$(stub_value tkrumm op://test/a/one)" "$(cache_val op://test/a/one)"
assert_eq "23. over ssh: new value sealed" "$(stub_value tkrumm op://test/a/NEW)" "$(cache_val op://test/a/NEW)"
assert_eq "23. over ssh: mtime of the last complete reseal preserved" "$mtime3" "$(cache_mtime)"
rm -f "$TESTREPO/bin/ssh"

# === 24. the requester and the seed agree on what "missing" means =============
# secrets-reseal-request.sh reads KEYS out of the sealed file; the seed writes them. If the
# two ever spell a key differently, the requester would raise a request that a seal can
# never satisfy. Same lists, real seals, both accounts.
REQ="$HERE/secrets-reseal-request.sh"
needed() { SECRETS_PRIVATE_REPO="$TESTREPO" SECRETS_RESEAL_STATE_DIR="$TESTREPO/reseal-state" bash "$REQ" needed >/dev/null 2>&1; echo $?; }
reset_case
write_refs headless.refs "op://test/a/one"
write_refs headless.iu.refs "op://Prometheus Internal/db/password" "op://Private/feuer/key"
assert_eq "24. before any seal every ref is missing" "0" "$(needed)"
run_seed
assert_accepted "24. full seal"
assert_eq "24. after a full seal nothing is missing (key spelling agrees, both accounts)" "1" "$(needed)"
write_refs headless.iu.refs "op://Prometheus Internal/db/password" "op://Private/feuer/key" "op://Prometheus Internal/db/new"
assert_eq "24. a new IU ref is missing" "0" "$(needed)"
SEED_ARGS=(--new-only); run_seed
assert_accepted "24. incremental seal"
assert_eq "24. after the incremental seal nothing is missing" "1" "$(needed)"

# --- guards deliberately NOT covered here (documented, not silently skipped) --
# - a LIVE ssh target: case 23 drives deliver_remote_cache and the remote read-back of the
#   current cache through an ssh stub that runs the remote script under a fake $HOME, so
#   the remote branches run for real; only the network hop itself is not exercised.
# - the "could not read trusted recipient from 1Password — skipping verification"
#   soft-skip branch: would require the op stub to fail `read` for the trusted-
#   recipient ref specifically, which is a config problem on the 1Password side, not
#   a collect_refs policy question — case 9 already locks the enforcement branch that
#   actually matters here.
# - its sibling, the "could not resolve the Private vault id — UUID-form Private guard
#   skipped" soft-skip (secrets-seed.sh): the stub's `vault get` always succeeds, so no
#   case reaches it. Same shape of blind spot as the one above, and worth naming for the
#   same reason. Note both soft-skips are, by design, the fail-OPEN edges of otherwise
#   fail-closed guards: each degrades to a stderr warning rather than an abort, so a
#   1Password outage cannot brick a seed. That trade is deliberate (design.md D9) but it
#   does mean neither warning path is exercised here — if either is ever tightened into a
#   hard failure, it needs a case.
# - `op signin` fallback after a failing `op whoami`: pure account-preauth plumbing,
#   identical bash control flow for both accounts; the stub's `whoami` always
#   succeeds like a signed-in real `op` would on the mini.
# - the post-encrypt ciphertext sanity checks (missing `ENC[` marker / missing key):
#   would require sops itself to misbehave, not reproducible by a black-box op stub;
#   cases 2/5/6/10 already prove every declared key round-trips into the ciphertext.

# --- summary -----------------------------------------------------------------
echo
echo "  $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
