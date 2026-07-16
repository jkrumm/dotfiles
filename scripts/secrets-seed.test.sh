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
# dotfiles-private repo, its cache, or any real secret. Run on the mini (backend =
# cache) so the seed's local-delivery branch is hermetic (no `ssh mac-mini`).
#
# Usage: scripts/secrets-seed.test.sh   (exit 0 = all pass)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEED="$HERE/secrets-seed.sh"
BACKEND_MARKER="$HOME/.config/secrets/backend"

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
[[ "$(tr -d '[:space:]' <"$BACKEND_MARKER" 2>/dev/null)" == "cache" ]] \
                             || { echo "✗ backend marker is not 'cache' — run on the mini (avoids ssh mac-mini)"; exit 2; }
command -v sops       >/dev/null || { echo "✗ sops missing"; exit 2; }
command -v jq         >/dev/null || { echo "✗ jq missing"; exit 2; }
command -v age-keygen >/dev/null || { echo "✗ age-keygen missing"; exit 2; }

# --- build a throwaway dotfiles-private-shaped repo ---------------------------
TESTREPO="$(mktemp -d "${TMPDIR:-/tmp}/secrets-seed-test.XXXXXX")"
trap 'rm -rf "$TESTREPO"' EXIT
mkdir -p "$TESTREPO/bin" "$TESTREPO/cache"

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
  signin) exit 0 ;;
  vault)
    [[ "${2:-}" == "get" ]] || exit 1
    printf '{"id":"%s"}\n' "$(cat "$HERE/fake-uuid.txt")"
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
    if [[ "$ref" == "op://Private/mac-mini age key/public key" ]]; then
      cat "$HERE/recipient.txt"
      exit 0
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
      echo "[ERROR] 2026/07/16 00:00:00 could not read secret: item not found" >&2
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

reset_case() {  # clears per-case state; restores the canonical single-recipient .sops.yaml
  rm -f "$TESTREPO/headless.refs" "$TESTREPO/headless.iu.refs" "$TESTREPO/op-calls.log"
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
  PATH="$TESTREPO/bin:$PATH" SECRETS_PRIVATE_REPO="$TESTREPO" "$SEED" >/dev/null 2>"$errf"
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
reads="$(grep -c "^read .*op://test/app/token$" "$TESTREPO/op-calls.log" || true)"
assert_eq "10. dedupe: repeated ref is read from op exactly ONCE (no second prompt)" "1" "$reads"

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

# --- guards deliberately NOT covered here (documented, not silently skipped) --
# - deliver_remote_cache (ssh mac-mini): needs a live SSH target; local delivery
#   (exercised throughout, since the preflight pins backend=cache) proves the same
#   ciphertext-assembly, sanity-check, and atomic-mv logic identically — only the
#   transport differs, and the transport is a fixed, non-interpolated `ssh` call.
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
