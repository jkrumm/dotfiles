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
jq -n \
  --arg t "$LONG" --arg s "$SHORT" --arg q "$QUOTED" --arg e "$INJECT" \
  '{"op://test/app/token":$t,"op://test/app/short":$s,"op://test/app/quoted":$q,"op://test/injected/evil":$e,"_seeded_at":"2026-07-15T00:00:00Z"}' \
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

# --- summary -----------------------------------------------------------------
echo
echo "  $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
