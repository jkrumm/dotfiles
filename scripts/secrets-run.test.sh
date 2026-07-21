#!/usr/bin/env bash
# File-scoped shellcheck exceptions (all deliberate in a parser test harness):
#   SC2162 — `read` below is the secrets-run VERB (an arg to run()), never the bash builtin.
#   SC2016 — single-quoted `$VAR` strings are intentional: literal template data fed to the
#            code-under-test, and child-shell snippets meant to expand in the child, not here.
# shellcheck disable=SC2162,SC2016
set -uo pipefail

# secrets-run.test.sh — regression harness for the `secrets-run` shim.
#
# Reconstructs (and commits) the previously-ad-hoc verification log from
# dotfiles-private/docs/security-review.md so every future shim change can be proven,
# not re-eyeballed. Per the headless-secrets guardrail: run this + shellcheck after ANY
# change to secrets-run, in the same commit as the docs update.
#
# Hermetic: builds a THROWAWAY SOPS+age cache in a temp repo and points the shim at it
# via SECRETS_PRIVATE_REPO. It uses the machine's real age key + backend marker (`cache`)
# — the config under test — but never touches the real cache or any real secret. Run on
# the mini (backend=cache, age key present).
#
# Usage: scripts/secrets-run.test.sh   (exit 0 = all pass)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHIM="$HERE/secrets-run"
AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"
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
[[ -x "$SHIM" ]]              || { echo "✗ shim not found/executable at $SHIM"; exit 2; }
[[ -f "$AGE_KEY_FILE" ]]      || { echo "✗ age key missing at $AGE_KEY_FILE — run on the mini"; exit 2; }
[[ "$(tr -d '[:space:]' <"$BACKEND_MARKER" 2>/dev/null)" == "cache" ]] \
                             || { echo "✗ backend marker is not 'cache' — run on the mini"; exit 2; }
command -v sops >/dev/null || { echo "✗ sops missing"; exit 2; }
command -v jq   >/dev/null || { echo "✗ jq missing"; exit 2; }
RECIPIENT="$(age-keygen -y "$AGE_KEY_FILE")" || { echo "✗ cannot derive recipient"; exit 2; }

# --- build a throwaway cache in a temp repo ----------------------------------
TESTREPO="$(mktemp -d "${TMPDIR:-/tmp}/secrets-run-test.XXXXXX")"
trap 'rm -rf "$TESTREPO"' EXIT
mkdir -p "$TESTREPO/cache"

# Synthetic ref→value map. Values are fictional. Includes: a long redactable secret, a
# short (sub-threshold) value, a value with a single quote, and an EXTRA ref no template
# declares (the injection-guard probe).
LONG='s3cr3t-token-abcdefghijklmnop'   # >= REDACT_MIN_LEN → redacted
SHORT='ab'                             # <  REDACT_MIN_LEN → NOT redacted
QUOTED="a'b'c"                         # exercises export single-quote escaping
INJECT='--require /tmp/evil.js'        # forged extra key; must never become an env var
# Multi-account (D14). The personal account keys BARE; careerpartner keys NAMESPACED
# as `careerpartner|<ref>`. COLLIDE_* is the crux: the SAME ref op://Private/collide/token
# exists in BOTH accounts with DIFFERENT values, because both accounts really do own a
# vault named `Private`. A flat keyspace would return one value for both.
IU='iu-feuer-token-abcdefghijkl'
COLLIDE_PERSONAL='personal-private-value-aaaa'
COLLIDE_IU='iu-private-value-bbbb'
# A vault name containing a SPACE. Not an edge case for IU: `op://Prometheus Internal/...`
# is the shared team vault and accounts for the large majority of headless.iu.refs, so
# every DB cred on the mini depends on the space surviving seal → lookup → emit. `op`
# allows spaces in vault names and refs are never shell-quoted inside the cache key, so
# any unquoted expansion or word-splitting bug in the parser would word-split this ref
# and silently miss. Cheap to assert; a regression here would strand the whole IU stack.
SPACED='pi-se-prod-pw-abcdefghij'
# A ref containing a literal '|'. 1Password does not forbid pipes in vault/item/field
# names, and a bare (default-account) cache key IS the raw ref — so this is the input
# that breaks any "the first '|' separates account from ref" parser. Sealed BARE.
PIPED='pipe-ref-value-0123456789'
# THE SUFFIX-COLLISION DECOY. A bare-sealed ref that ends with "|op://test/decoy/x".
# A parser that accepts any pipe-free prefix as an account reads this as account
# `op://z` holding `op://test/decoy/x` — a ref never sealed for anyone. Worse, that
# bogus account's cache_key() reconstructs this very key, so acting on the advice
# would hand back THIS value for an unrelated ref. Must never be attributed.
DECOY='decoy-value-must-never-surface'
# An ACCOUNT name containing a space — normalize_account permits it, so the emitted
# remediation must be shell-quoted before a human pastes it.
SPACED_ACCT='spaced-account-value-abcdef'
jq -n \
  --arg t "$LONG" --arg s "$SHORT" --arg q "$QUOTED" --arg e "$INJECT" \
  --arg iu "$IU" --arg cp "$COLLIDE_PERSONAL" --arg ci "$COLLIDE_IU" \
  --arg sp "$SPACED" --arg pp "$PIPED" --arg dc "$DECOY" --arg sa "$SPACED_ACCT" \
  '{"op://test/app/token":$t,"op://test/app/short":$s,"op://test/app/quoted":$q,
    "op://test/injected/evil":$e,
    "op://Private/collide/token":$cp,
    "op://v|t/item/field":$pp,
    "op://z|op://test/decoy/x":$dc,
    "sp ace|op://spaced/acct/ref":$sa,
    "careerpartner|op://Private/feuer/api-server-key":$iu,
    "careerpartner|op://Private/collide/token":$ci,
    "careerpartner|op://Prometheus Internal/se-prod/password":$sp,
    "_seeded_at":"2026-07-15T00:00:00Z"}' \
  | sops --encrypt --age "$RECIPIENT" --input-type json --output-type json /dev/stdin \
      > "$TESTREPO/cache/secrets.enc.json"   # --age (not .sops.yaml) → cwd-independent

run() { SECRETS_PRIVATE_REPO="$TESTREPO" SOPS_AGE_KEY_FILE="$AGE_KEY_FILE" "$SHIM" "$@"; }

# assert_refused <label> <tpl-line>: a template value secrets-run must reject (fail closed),
# because op would escape/interpolate/error on it and the shim does not replicate that.
assert_refused() {
  printf '%s\n' "$2" > "$TESTREPO/refused.env.tpl"
  if run run --env-file="$TESTREPO/refused.env.tpl" -- true >/dev/null 2>&1; then
    bad "$1" "was accepted (expected fail-closed) for: $2"
  else ok "$1"; fi
}

echo "secrets-run harness (temp repo: $TESTREPO)"

# === 1. read present ref =====================================================
assert_eq "read: present ref returns value" "$LONG" "$(run read op://test/app/token 2>/dev/null)"

# === 2. read missing ref fails closed ========================================
if run read op://test/nope/x >/dev/null 2>&1; then bad "read: missing ref fails closed"; else ok "read: missing ref fails closed"; fi

# === 3-4. run injects refs + passes literals through =========================
cat > "$TESTREPO/app.env.tpl" <<'EOF'
TOKEN=op://test/app/token
LITERAL=plain-value
BOOLISH=true        # inline comment must be stripped (the SLACK_ALLOW_ALL_USERS bug)
QUOTED_LIT="has # hash inside"
EOF
# The captured (piped) stream is redacted, so we can't read the raw TOKEN back — assert
# its LENGTH instead (a number is never redacted), which proves the exact value was
# injected. Literals (L/B/Q) aren't cache values, so they pass through unmasked.
out="$(run run --env-file="$TESTREPO/app.env.tpl" -- bash -c 'printf "T=%s|L=%s|B=%s|Q=%s" "${#TOKEN}" "$LITERAL" "$BOOLISH" "$QUOTED_LIT"' 2>/dev/null)"
assert_contains "run: injects op:// ref (by length)"    "T=${#LONG}"       "$out"
assert_contains "run: passes literal through"           "L=plain-value"    "$out"
assert_contains "run: strips inline comment (unquoted)" "B=true"           "$out"
assert_contains "run: keeps # inside quotes"            "Q=has # hash inside" "$out"

# === 4b. parse parity: op edge cases the shim must match (design.md D11) ======
# Single quotes are FULLY literal in op ($ and backslash pass through verbatim); double
# quotes and unquoted values that would need op's escaping/interpolation must fail closed.
cat > "$TESTREPO/parse.env.tpl" <<'EOF'
SQ='a # b'
QC="val"        # trailing comment after a closing quote
NS=color#nope
DQHASH="#FF0000"
SQDOLLAR='p@ss$word'
SQBACK='C:\path\to'
SQBRACE='a${HOME}b'
EMPTY=
WSONLY=
EOF
out="$(run run --env-file="$TESTREPO/parse.env.tpl" -- bash -c 'printf "SQ=[%s]|QC=[%s]|NS=[%s]|DQ=[%s]|D=[%s]|B=[%s]|BR=[%s]|E=[%s]" "$SQ" "$QC" "$NS" "$DQHASH" "$SQDOLLAR" "$SQBACK" "$SQBRACE" "$EMPTY"' 2>/dev/null)"
assert_contains "parse: single-quote content preserved"   "SQ=[a # b]"   "$out"
assert_contains "parse: trailing comment after close quote dropped" "QC=[val]" "$out"
assert_contains "parse: unquoted '#' with no space truncates" "NS=[color]" "$out"
assert_contains "parse: quoted '#hex' preserved"          "DQ=[#FF0000]" "$out"
assert_contains "parse: single-quote '\$' is literal (op parity)"  "D=[p@ss\$word]" "$out"
assert_contains "parse: single-quote backslash is literal"         "B=[C:\\path\\to]" "$out"
assert_contains "parse: single-quote '\${VAR}' not interpolated"   "BR=[a\${HOME}b]" "$out"
assert_contains "parse: empty value is empty"             "E=[]"         "$out"

# === 4c. fail-closed on values op escapes/interpolates or rejects (no silent divergence) ==
assert_refused "refuse: escaped quote in double-quoted value" 'X="a\"b"'
assert_refused "refuse: unterminated quote"               'X="never closed'
assert_refused "refuse: text after closing quote"         'X="val"extra'
assert_refused "refuse: \${VAR} interpolation (double-quoted)" 'X="a${HOME}b"'
assert_refused "refuse: \$ interpolation (unquoted)"      'X=pre$HOME'
assert_refused "refuse: backslash-escaped '#' (unquoted)" 'X=a\#b'
assert_refused "refuse: backslash in unquoted value"      'X=C:\path'

# === 5. redaction masks a long value on piped stdout =========================
out="$(run run --env-file="$TESTREPO/app.env.tpl" -- printenv TOKEN 2>/dev/null)"
assert_not_contains "redact: long secret masked on stdout" "$LONG" "$out"
assert_contains     "redact: replacement marker present"   "<redacted>" "$out"

# === 6. redaction masks on piped stderr ======================================
err="$(run run --env-file="$TESTREPO/app.env.tpl" -- bash -c 'printenv TOKEN 1>&2' 2>&1 1>/dev/null)"
assert_not_contains "redact: secret masked on stderr" "$LONG" "$err"

# === 7. redaction does NOT over-mask a short value ===========================
cat > "$TESTREPO/short.env.tpl" <<'EOF'
SHORTV=op://test/app/short
EOF
out="$(run run --env-file="$TESTREPO/short.env.tpl" -- printenv SHORTV 2>/dev/null)"
assert_eq "redact: sub-threshold value passes through" "$SHORT" "$out"

# === 8. clean $() capture: stdout redacted, stderr not folded in =============
# child writes secret to stderr and a marker to stdout; captured stdout must be marker only.
out="$(run run --env-file="$TESTREPO/app.env.tpl" -- bash -c 'echo MARKER; printenv TOKEN 1>&2' 2>/dev/null)"
assert_eq "capture: stdout is clean (no stderr fold)" "MARKER" "$out"

# === 9. fail-closed when a tpl ref is absent from the cache ==================
cat > "$TESTREPO/missing.env.tpl" <<'EOF'
X=op://test/not/seeded
EOF
if run run --env-file="$TESTREPO/missing.env.tpl" -- true >/dev/null 2>&1; then
  bad "fail-closed: missing tpl ref aborts before run"
else ok "fail-closed: missing tpl ref aborts before run"; fi

# === 10-11. structural injection guard =======================================
# The forged extra cache key op://test/injected/evil is not declared by the template,
# so it must never surface as an env var; and a template cannot smuggle NODE_OPTIONS it
# does not declare. Dump the child env and assert.
childenv="$(run run --env-file="$TESTREPO/app.env.tpl" -- env 2>/dev/null)"
assert_not_contains "inject: forged cache value absent from child env" "$INJECT" "$childenv"
assert_not_contains "inject: no rogue op://injected key leaked"        "injected/evil" "$childenv"

# === 12. export line format + single-quote escaping ==========================
cat > "$TESTREPO/q.env.tpl" <<'EOF'
QV=op://test/app/quoted
EOF
exp="$(run export --env-file="$TESTREPO/q.env.tpl" 2>/dev/null)"
# eval the emitted line in a clean sub-shell and confirm the value round-trips exactly.
got="$(env -i bash -c "$exp"'; printf %s "$QV"')"
assert_eq "export: single-quote-safe round-trip" "$QUOTED" "$got"

# === 13. exit-code propagation through redaction =============================
run run --env-file="$TESTREPO/app.env.tpl" -- bash -c 'exit 7' >/dev/null 2>&1
assert_eq "exit: child code preserved through redaction" "7" "$?"

# === 14. no plaintext secret on disk (cache is ciphertext only) =============
assert_not_contains "disk: no plaintext secret in cache file" "$LONG" "$(cat "$TESTREPO/cache/secrets.enc.json")"

# === 15. empty template is a clean no-op for export =========================
: > "$TESTREPO/empty.env.tpl"
if run export --env-file="$TESTREPO/empty.env.tpl" >/dev/null 2>&1; then ok "export: empty template is a no-op"; else bad "export: empty template is a no-op"; fi

# === 16. PATH self-sufficiency for headless callers (design.md D12) ==========
# cron/launchd invoke the shim with a minimal PATH (/usr/bin:/bin) lacking the Homebrew
# bin dirs where sops/jq live. The shim must prepend Homebrew to its own PATH and still
# resolve — no caller PATH ceremony. (An empty PATH is out of scope: the `env bash`
# shebang can't even load under it, and system tools like `tr` live in /usr/bin.)
minpath_out="$(env PATH="/usr/bin:/bin" SECRETS_PRIVATE_REPO="$TESTREPO" \
  SOPS_AGE_KEY_FILE="$AGE_KEY_FILE" "$SHIM" read op://test/app/token 2>/dev/null)"
assert_eq "path: resolves under minimal PATH lacking Homebrew (D12)" "$LONG" "$minpath_out"

# === 17. multiple --env-file merge (op run parity: later file wins) ==========
# `op run` accepts repeated --env-file and applies them in order; a later file
# OVERRIDES an earlier one for any duplicate key. The shim must mirror that.
# File A declares TOKEN(long) + SHARED(short); file B declares QUOTED + SHARED(long).
# Merged: TOKEN from A, QUOTED from B, SHARED overridden to the long value by B.
cat > "$TESTREPO/mf-a.env.tpl" <<'EOF'
TOKEN=op://test/app/token
SHARED=op://test/app/short
EOF
cat > "$TESTREPO/mf-b.env.tpl" <<'EOF'
QUOTED=op://test/app/quoted
SHARED=op://test/app/token
EOF
# Assert by LENGTH (secret values are redacted on the piped stream; a number is not):
# SHARED length distinguishes last-wins (=len LONG) from first-wins (=len SHORT).
out="$(run run --env-file="$TESTREPO/mf-a.env.tpl" --env-file="$TESTREPO/mf-b.env.tpl" \
  -- bash -c 'printf "T=%s|Q=%s|S=%s" "${#TOKEN}" "${#QUOTED}" "${#SHARED}"' 2>/dev/null)"
assert_contains "multi: key from first --env-file injected"  "T=${#LONG}"   "$out"
assert_contains "multi: key from second --env-file injected" "Q=${#QUOTED}" "$out"
assert_contains "multi: later --env-file overrides dup key"  "S=${#LONG}"   "$out"

# space-form (`--env-file <path>`) is accepted repeatedly too
out="$(run run --env-file "$TESTREPO/mf-a.env.tpl" --env-file "$TESTREPO/mf-b.env.tpl" \
  -- bash -c 'printf "S=%s" "${#SHARED}"' 2>/dev/null)"
assert_contains "multi: repeated space-form --env-file merges" "S=${#LONG}" "$out"

# export over multiple files: a dup key is emitted ONCE (deduped), last value wins.
exp="$(run export --env-file="$TESTREPO/mf-a.env.tpl" --env-file="$TESTREPO/mf-b.env.tpl" 2>/dev/null)"
assert_eq "export multi: dup key emitted once" "1" "$(printf '%s\n' "$exp" | grep -c '^export SHARED=')"
got="$(env -i bash -c "$exp"'; printf %s "${#SHARED}"')"
assert_eq "export multi: last file wins on dup key" "${#LONG}" "$got"

# === 18. multi-account keyspace (D14) ========================================
# Personal (default) refs key BARE; careerpartner refs key `careerpartner|<ref>`.
run_iu() { OP_ACCOUNT=careerpartner run "$@"; }

# An IU ref resolves only under the IU account...
assert_eq "account: IU ref resolves under OP_ACCOUNT=careerpartner" \
  "$IU" "$(run_iu read op://Private/feuer/api-server-key 2>/dev/null)"
# ...and is INVISIBLE to the default account (no cross-account bleed).
if run read op://Private/feuer/api-server-key >/dev/null 2>&1; then
  bad "account: IU ref not visible to personal account"
else ok "account: IU ref not visible to personal account"; fi

# THE collision test: one ref, two accounts, two different values. Both must be
# reachable and each must return ITS OWN value. This is what a flat keyspace
# could not do, and the reason the namespace exists at all.
assert_eq "account: colliding op://Private ref → personal value" \
  "$COLLIDE_PERSONAL" "$(run read op://Private/collide/token 2>/dev/null)"
assert_eq "account: colliding op://Private ref → IU value" \
  "$COLLIDE_IU" "$(run_iu read op://Private/collide/token 2>/dev/null)"

# Account-spelling normalization: `op` accepts both `careerpartner` and
# `careerpartner.1password.com` for one account, and IU call sites use BOTH
# (feuer's Makefile vs analysis/op-env.sh). They must key the SAME entry — a
# regression here is a silent cache miss, not a loud error.
assert_eq "account: .1password.com spelling normalizes to the same key" \
  "$IU" "$(OP_ACCOUNT=careerpartner.1password.com run read op://Private/feuer/api-server-key 2>/dev/null)"

# An unseeded account must fail CLOSED, and say which ref-list to fix.
err="$(run_iu read op://Private/feuer/nope 2>&1 || true)"
assert_contains "account: unseeded IU ref fails closed" "not in cache" "$err"
assert_contains "account: missing IU ref names headless.iu.refs" "headless.iu.refs" "$err"
# ...while a personal miss still names the personal list.
err="$(run read op://test/nope/x 2>&1 || true)"
assert_contains "account: missing personal ref names headless.refs" "headless.refs" "$err"

# CROSS-ACCOUNT DIAGNOSIS. A ref that IS seeded, just under the other account, must
# not be reported as un-seeded: the "add to <list> and reseed" advice is wrong there
# and sends the reader to re-seal a cache that already holds the value. Regression
# for the 2026-07-20 misdiagnosis (a day lost re-seeding + reading secrets out of a
# stale build artifact) — the fix is one env var, so the error must say exactly that.
err="$(run read op://Private/feuer/api-server-key 2>&1 || true)"
assert_contains "cross-account: names the account that holds it" "careerpartner" "$err"
assert_contains "cross-account: gives the OP_ACCOUNT fix" "OP_ACCOUNT=careerpartner" "$err"
assert_contains "cross-account: says no reseed needed" "no reseed needed" "$err"
if [[ "$err" == *"add to headless.refs and reseed"* ]]; then
  bad "cross-account: must NOT advise a pointless reseed"
else ok "cross-account: must NOT advise a pointless reseed"; fi

# The same diagnosis must reach the `run`/template path, not just `read` — that is
# where it actually bit (a whole .env.tpl of IU refs under the default account).
cat > "$TESTREPO/xacct.env.tpl" <<'EOF'
FEUER_TOKEN=op://Private/feuer/api-server-key
EOF
err="$(run run --env-file="$TESTREPO/xacct.env.tpl" -- true 2>&1 || true)"
assert_contains "cross-account: template path gives the OP_ACCOUNT fix" "OP_ACCOUNT=careerpartner" "$err"

# A genuinely-absent ref must still get the reseed advice even when OTHER refs in the
# same template are cross-account — a half-match is a real gap, so the safe hint wins.
cat > "$TESTREPO/mixed.env.tpl" <<'EOF'
FEUER_TOKEN=op://Private/feuer/api-server-key
GENUINELY_ABSENT=op://test/nope/x
EOF
err="$(run run --env-file="$TESTREPO/mixed.env.tpl" -- true 2>&1 || true)"
# Assert the FULL reseed phrase, not just "reseed" — cross_account_advice() ends with
# "(no reseed needed)", so a bare substring check passes on the very regression it
# is meant to catch.
assert_contains "cross-account: mixed template falls back to reseed advice" \
  "add to headless.refs and reseed" "$err"
if [[ "$err" == *"already seeded under account"* ]]; then
  bad "cross-account: mixed template must NOT take the cross-account branch"
else ok "cross-account: mixed template must NOT take the cross-account branch"; fi

# N>1 aggregation: the real incident was a 67-ref template ENTIRELY under the wrong
# account. A single-ref test cannot exercise common_other_account()'s agreement loop.
# Both refs must be careerpartner-ONLY: op://Private/collide/token would resolve here,
# since it also exists bare under the default account, and so would not be missing.
cat > "$TESTREPO/multi.env.tpl" <<'EOF'
FEUER_TOKEN=op://Private/feuer/api-server-key
SE_PROD_PW=op://Prometheus Internal/se-prod/password
EOF
err="$(run run --env-file="$TESTREPO/multi.env.tpl" -- true 2>&1 || true)"
assert_contains "cross-account: N>1 refs under one account still diagnosed" "OP_ACCOUNT=careerpartner" "$err"
assert_contains "cross-account: N>1 reports the full count" "2 ref(s)" "$err"

# PRESENCE, NOT VALUES. The whole security argument for the cross-account probe is
# that it reads cache KEYS only. Assert no fixture secret VALUE reaches the error text.
for v in "$IU" "$COLLIDE_IU" "$COLLIDE_PERSONAL"; do
  if [[ "$err" == *"$v"* ]]; then
    bad "cross-account: diagnostic must never echo a secret value"; break
  fi
done
[[ "$err" != *"$IU"* && "$err" != *"$COLLIDE_IU"* && "$err" != *"$COLLIDE_PERSONAL"* ]] \
  && ok "cross-account: diagnostic must never echo a secret value"

# A ref may itself contain '|' (1Password does not forbid it in vault/item/field
# names) and bare keys ARE the raw ref — so "split on the first '|'" would read the
# bare key `op://v|t/item/field` as account `op://v`, and report NO holder for a ref
# the default account plainly has. Regression for that mis-split (review 2026-07-21).
PIPE_REF='op://v|t/item/field'
assert_eq "pipe-ref: resolves under the default account" \
  "$PIPED" "$(run read "$PIPE_REF" 2>/dev/null)"
err="$(run_iu read "$PIPE_REF" 2>&1 || true)"
assert_contains "pipe-ref: cross-account probe still finds the bare holder" "tkrumm" "$err"
assert_contains "pipe-ref: and advises the account switch, not a reseed" "OP_ACCOUNT=tkrumm" "$err"

# Suffix collision: `op://test/decoy/x` was never sealed for ANY account — only a bare
# ref ENDING in "|op://test/decoy/x" was. It must be reported as a genuine gap, never
# attributed to the pseudo-account `op://z`, because acting on that advice would return
# the decoy's value for a ref nobody sealed.
err="$(run read op://test/decoy/x 2>&1 || true)"
assert_contains "collision: unsealed ref gets the reseed advice" "reseed: make secrets-seed" "$err"
if [[ "$err" == *"op://z"* ]]; then
  bad "collision: must not name a ref fragment as an account"
else ok "collision: must not name a ref fragment as an account"; fi
if [[ "$err" == *"$DECOY"* ]]; then
  bad "collision: decoy value must never reach the error text"
else ok "collision: decoy value must never reach the error text"; fi
# ...and the same under a non-default account, which takes the namespaced lookup path.
err="$(run_iu read op://test/decoy/x 2>&1 || true)"
if [[ "$err" == *"op://z"* ]]; then
  bad "collision: no ref-fragment account under a namespaced lookup"
else ok "collision: no ref-fragment account under a namespaced lookup"; fi

# Holder-set INTERSECTION. op://Private/collide/token is held by BOTH accounts; the IU
# feuer ref by careerpartner only. Under a third account both are missing, and exactly
# one account (careerpartner) holds them all — an implementation that demands a single
# holder per ref would bail to the reseed advice here.
cat > "$TESTREPO/intersect.env.tpl" <<'EOF'
COLLIDE=op://Private/collide/token
FEUER_TOKEN=op://Private/feuer/api-server-key
EOF
err="$(OP_ACCOUNT=thirdparty run run --env-file="$TESTREPO/intersect.env.tpl" -- true 2>&1 || true)"
assert_contains "intersect: one account holding every missing ref is found" \
  "OP_ACCOUNT=careerpartner" "$err"

# An account name may contain a SPACE (normalize_account refuses only '|', '/' and ':').
# Two things must survive it: the holder-set intersection (comm -12 is line-oriented, so
# a space is harmless but worth pinning), and the emitted remediation, which a human is
# invited to paste — unquoted, `OP_ACCOUNT=sp ace secrets-run` would run `ace`.
err="$(OP_ACCOUNT=other run read 'op://spaced/acct/ref' 2>&1 || true)"
assert_contains "spaced-account: holder found across the space" "sp ace" "$err"
assert_contains "spaced-account: remediation is shell-quoted" 'OP_ACCOUNT=sp\ ace' "$err"

# normalize_account must refuse the characters the collision guard depends on.
for badc in 'a/b' 'a:b' 'a|b'; do
  if OP_ACCOUNT="$badc" run read op://test/app/token >/dev/null 2>&1; then
    bad "normalize: OP_ACCOUNT '$badc' must be refused"
  else ok "normalize: OP_ACCOUNT '$badc' must be refused"; fi
done

# === diagnostics module (split out of the shim) ==============================
# The module is SOURCED from the shim's real directory on the miss path only. Two
# properties the split introduced, neither exercised by the tests above.

# 1. It must load through a SYMLINK. This is not academic: the shim is invoked in real
#    life as ~/.local/bin/secrets-run, a symlink into dotfiles/scripts. Resolving the
#    symlink's own directory instead of the target's would look in ~/.local/bin and
#    silently lose the advice exactly where it is used.
LINKDIR="$TESTREPO/linkdir"; mkdir -p "$LINKDIR"
ln -sf "$SHIM" "$LINKDIR/secrets-run"
err="$(SECRETS_PRIVATE_REPO="$TESTREPO" SOPS_AGE_KEY_FILE="$AGE_KEY_FILE" \
  "$LINKDIR/secrets-run" read op://Private/feuer/api-server-key 2>&1 || true)"
assert_contains "diagnostics: module loads through a symlinked shim" "OP_ACCOUNT=careerpartner" "$err"

# 2. A missing module must DEGRADE, never break. Secret resolution is the sole secret
#    path and must not depend on the error-path module; a miss must still fail closed
#    and still name the ref — only the remediation advice is lost.
BAREDIR="$TESTREPO/baredir"; mkdir -p "$BAREDIR"
cp "$SHIM" "$BAREDIR/secrets-run"        # copied WITHOUT secrets-run-diagnostics.sh
bare() { SECRETS_PRIVATE_REPO="$TESTREPO" SOPS_AGE_KEY_FILE="$AGE_KEY_FILE" "$BAREDIR/secrets-run" "$@"; }
assert_eq "diagnostics: absent module leaves resolution working" \
  "$LONG" "$(bare read op://test/app/token 2>/dev/null)"
err="$(bare read op://test/nope/x 2>&1 || true)"
assert_contains "diagnostics: absent module still fails closed" "not in cache" "$err"
assert_contains "diagnostics: absent module still names the ref" "op://test/nope/x" "$err"
if bare read op://test/nope/x >/dev/null 2>&1; then
  bad "diagnostics: absent module must not turn a miss into a success"
else ok "diagnostics: absent module must not turn a miss into a success"; fi

# 3. A symlink CYCLE must not hang. The mini is headless — a wedged secret lookup has
#    nobody to Ctrl-C it — so the walk is hop-capped and degrades to "module unavailable"
#    rather than spinning. Guarded by `timeout`/`gtimeout` where available; the assertion
#    is that the process terminates at all.
CYCDIR="$TESTREPO/cycdir"; mkdir -p "$CYCDIR"
ln -sf "$CYCDIR/link-b" "$CYCDIR/link-a"
ln -sf "$CYCDIR/link-a" "$CYCDIR/link-b"
TIMEOUT_BIN=""
command -v timeout  >/dev/null 2>&1 && TIMEOUT_BIN=timeout
command -v gtimeout >/dev/null 2>&1 && TIMEOUT_BIN=gtimeout
if [[ -n "$TIMEOUT_BIN" ]]; then
  if SECRETS_PRIVATE_REPO="$TESTREPO" SOPS_AGE_KEY_FILE="$AGE_KEY_FILE" \
     "$TIMEOUT_BIN" 10 "$CYCDIR/link-a" read op://test/app/token >/dev/null 2>&1; then
    ok "diagnostics: symlink cycle terminates (did not hang)"
  elif [[ $? -eq 124 ]]; then
    bad "diagnostics: symlink cycle HUNG (hop cap missing or broken)"
  else
    ok "diagnostics: symlink cycle terminates (did not hang)"
  fi
else
  ok "diagnostics: symlink cycle test skipped (no timeout binary)"
fi

# format_missing_list() elision: no "+N more" at exactly the cap, correct count above it.
mk_tpl() {  # $1=path $2=count — a template of N guaranteed-absent refs
  : > "$1"; for ((n = 1; n <= $2; n++)); do printf 'K%d=op://test/absent%d/x\n' "$n" "$n" >> "$1"; done
}
mk_tpl "$TESTREPO/eight.env.tpl" 8
err="$(run run --env-file="$TESTREPO/eight.env.tpl" -- true 2>&1 || true)"
if [[ "$err" == *"more)"* ]]; then bad "elide: exactly 8 refs are not elided"
else ok "elide: exactly 8 refs are not elided"; fi
mk_tpl "$TESTREPO/twelve.env.tpl" 12
err="$(run run --env-file="$TESTREPO/twelve.env.tpl" -- true 2>&1 || true)"
assert_contains "elide: 12 refs elide the trailing 4" "(+4 more)" "$err"
assert_contains "elide: 12 refs still report the true total" "12 ref(s)" "$err"

# `run` (not just `read`) must inject under an account too.
cat > "$TESTREPO/iu.env.tpl" <<'EOF'
FEUER_TOKEN=op://Private/feuer/api-server-key
EOF
out="$(run_iu run --env-file="$TESTREPO/iu.env.tpl" -- bash -c 'printf "F=%s" "${#FEUER_TOKEN}"' 2>/dev/null)"
assert_contains "account: run injects IU ref under OP_ACCOUNT" "F=${#IU}" "$out"
# The same template under the personal account must fail closed, not inject empty.
if run run --env-file="$TESTREPO/iu.env.tpl" -- true >/dev/null 2>&1; then
  bad "account: IU template under personal account fails closed"
else ok "account: IU template under personal account fails closed"; fi

# `export` is the third verb and shares cache_lookup — cover it under an account too.
exp="$(run_iu export --env-file="$TESTREPO/iu.env.tpl" 2>/dev/null)"
got="$(env -i bash -c "$exp"'; printf %s "$FEUER_TOKEN"')"
assert_eq "account: export resolves IU ref under OP_ACCOUNT" "$IU" "$got"

# Account names are CASE-INSENSITIVE to `op`, so they must be to the cache too —
# otherwise the op backend (op matches case-insensitively) and the cache backend
# (string compare) disagree on the same input. Both directions:
assert_eq "account: mixed-case IU account folds to the same key" \
  "$IU" "$(OP_ACCOUNT=CareerPartner run read op://Private/feuer/api-server-key 2>/dev/null)"
assert_eq "account: mixed-case + domain spelling folds to the same key" \
  "$IU" "$(OP_ACCOUNT=CareerPartner.1Password.com run read op://Private/feuer/api-server-key 2>/dev/null)"
# ...and the DEFAULT account still keys bare under any spelling of itself.
assert_eq "account: default keys bare under domain spelling" \
  "$LONG" "$(OP_ACCOUNT=tkrumm.1password.com run read op://test/app/token 2>/dev/null)"
assert_eq "account: default keys bare under mixed case" \
  "$LONG" "$(OP_ACCOUNT=TKRUMM run read op://test/app/token 2>/dev/null)"

# A vault name with a SPACE must survive every verb. `op://Prometheus Internal/...` is
# the bulk of headless.iu.refs (every IU DB cred), so a word-splitting regression in the
# ref parser would strand the mini's whole IU stack — silently, as a cache miss.
assert_eq "account: space in vault name resolves (read)" \
  "$SPACED" "$(run_iu read 'op://Prometheus Internal/se-prod/password' 2>/dev/null)"
cat > "$TESTREPO/spaced.env.tpl" <<'EOF'
DB_SE_PROD_PASS=op://Prometheus Internal/se-prod/password
EOF
# `run`: assert by LENGTH — the piped stream is redacted, so a number proves the exact
# value landed in the child's env (same trick as the injection test above).
out="$(run_iu run --env-file="$TESTREPO/spaced.env.tpl" -- bash -c 'printf "P=%s" "${#DB_SE_PROD_PASS}"' 2>/dev/null)"
assert_contains "account: space in vault name injects (run)" "P=${#SPACED}" "$out"
# `export` is the verb the IU render sites actually use (op run --no-masking has no
# secrets-run equivalent), so cover it directly: it must emit the value UNREDACTED.
exp="$(run_iu export --env-file="$TESTREPO/spaced.env.tpl" 2>/dev/null)"
got="$(env -i bash -c "$exp"'; printf %s "$DB_SE_PROD_PASS"')"
assert_eq "account: space in vault name exports unredacted" "$SPACED" "$got"

# '|' separates account from ref in a namespaced key, so an account containing one
# would make the key ambiguous — refuse it rather than seal an unlookup-able entry.
if OP_ACCOUNT='ev|il' run read op://test/app/token >/dev/null 2>&1; then
  bad "account: '|' in OP_ACCOUNT is refused"
else ok "account: '|' in OP_ACCOUNT is refused"; fi

# === 19. seal/lookup contract: the two cache_key impls must not drift =========
# cache_key()/normalize_account() are hand-duplicated in secrets-run and
# secrets-seed.sh. That duplication is deliberate (sourcing a shared file would add
# a runtime dependency to the mini's SOLE secret path), but it means the seal side
# and the lookup side agreeing is a convention — and a convention on a secrets cache
# is exactly what silently rots. If they ever diverge, the seed seals under one key
# and the shim looks up another: every ref misses. Assert the bodies are identical.
extract_fn() {  # $1=file $2=fn-name → prints the body, comments/blank lines stripped
  awk -v fn="$2" '
    $0 ~ "^" fn "\\(\\) \\{" { inside = 1 }
    inside { sub(/[[:space:]]*#.*$/, ""); if ($0 ~ /[^[:space:]]/) print }
    inside && /^\}/ { exit }
  ' "$1"
}
SEED="$(dirname "$SHIM")/secrets-seed.sh"
if [[ -f "$SEED" ]]; then
  for fn in normalize_account cache_key; do
    a="$(extract_fn "$SHIM" "$fn")"
    b="$(extract_fn "$SEED" "$fn")"
    [[ -n "$a" ]] || { bad "drift: $fn found in secrets-run"; continue; }
    [[ -n "$b" ]] || { bad "drift: $fn found in secrets-seed.sh"; continue; }
    if [[ "$fn" == cache_key ]]; then
      # The shim reads $OP_ACCOUNT implicitly; the seed takes the account as $1 and
      # the ref as $2. Normalize that ONE known signature difference away, then the
      # remaining logic must match byte-for-byte.
      a="${a//normalize_account \"\$OP_ACCOUNT\"/normalize_account \"\$ACCT\"}"
      a="${a//\"\$1\"/\"\$REF\"}"
      b="${b//normalize_account \"\$1\"/normalize_account \"\$ACCT\"}"
      b="${b//\"\$2\"/\"\$REF\"}"
    fi
    assert_eq "drift: $fn identical in secrets-run and secrets-seed.sh" "$a" "$b"
  done
else
  bad "drift: secrets-seed.sh not found next to the shim"
fi

# --- summary -----------------------------------------------------------------
echo
echo "  $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
