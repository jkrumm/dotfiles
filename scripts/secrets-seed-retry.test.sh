#!/usr/bin/env bash
# Regression tests for secrets-seed.sh's op-read retry loop.
#
# Separate from secrets-seed.test.sh because that suite is mini-gated (it refuses
# to run unless the backend marker says `cache`, to avoid an ssh to the mini).
# This one must run on the MacBook, since the MacBook is where the failure it
# guards actually happens.
#
# WHAT IT GUARDS. The reseed resolves a few hundred refs with one `op read`
# PROCESS each. A small number of those handshakes with the 1Password desktop app
# fail transiently (`response: promptError`, `You are not currently signed in`)
# or hang outright on a dialog that never renders. Before the retry loop, the
# first such hiccup threw away the whole run — after the human had already spent
# a Touch ID approval — and armed a 6h backoff. That is why the mini's cache sat
# 11 days stale on 2026-08-17 across repeated automated attempts.
#
# It drives the loop by EXTRACTING it from the real script rather than
# duplicating it, so the two cannot drift apart quietly: if the markers move, the
# extraction comes back short and the test fails loudly instead of testing a
# stale copy of the logic.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/secrets-seed.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/secrets-seed-retry.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# --- the op stub --------------------------------------------------------------
# A PATH stub, deliberately NOT a shell function: `op_read_once` invokes op
# through coreutils `timeout`, which execs the binary it finds on PATH and would
# sail straight past a function. A first draft of this test used a function, hit
# the REAL op, and "passed" while proving nothing — the error text in the output
# was the giveaway (it named actual vaults).
mkdir -p "$TMP/bin"
cat >"$TMP/bin/op" <<'EOF'
#!/usr/bin/env bash
# argv: read --account <acct> <ref>
ref="${4:-}"
n_file="$FAKE_OP_COUNT_DIR/$(echo "$ref" | tr -c 'a-zA-Z0-9' _)"
n=$(cat "$n_file" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" >"$n_file"
case "$ref" in
  # Fails twice with the exact transient error observed in the wild, then works.
  op://flaky/a/b)   if [ "$n" -lt 3 ]; then
                      echo "[ERROR] error initializing client: response: promptError" >&2; exit 1
                    fi
                    echo "flaky-value" ;;
  # Hangs on a dialog that never renders — must be killed by the timeout bound.
  op://hang/a/b)    sleep 60; echo "never" ;;
  # A genuinely absent ref. Not a hiccup: must fail on the FIRST attempt.
  op://missing/a/b) echo '[ERROR] "a" isn'"'"'t an item in the "missing" vault' >&2; exit 1 ;;
  *) echo "ok-value" ;;
esac
EOF
chmod +x "$TMP/bin/op"

# --- extract the loop under test ---------------------------------------------
DRIVER="$TMP/drive.sh"
cat >"$DRIVER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
die() { echo "DIE: $*" >&2; exit 1; }
indent() { sed 's/^/      /'; }
refs=("$@")
accts=(); for _ in "${refs[@]}"; do accts+=(tkrumm); done
EOF
sed -n '/^OP_READ_TIMEOUT=/,/^echo "    ✓ resolved/p' "$SCRIPT" >>"$DRIVER"

# Guard the extraction itself. A silently-empty range would make every assertion
# below vacuous, which is the one way a test like this rots without going red.
grep -q 'op_read_transient' "$DRIVER" || {
  echo "extraction failed: the retry block was not found in $SCRIPT — did the markers move?" >&2
  exit 1
}
grep -q 'attempt >= OP_READ_ATTEMPTS' "$DRIVER" || {
  echo "extraction failed: the attempt loop was not found in $SCRIPT" >&2
  exit 1
}
bash -n "$DRIVER"

export PATH="$TMP/bin:$PATH"
export FAKE_OP_COUNT_DIR="$TMP/counts"
mkdir -p "$FAKE_OP_COUNT_DIR"
# 2s per attempt keeps the hang case bearable; the real default is 30s.
export SECRETS_SEED_OP_READ_TIMEOUT=2

calls_for() { cat "$FAKE_OP_COUNT_DIR/$(echo "$1" | tr -c 'a-zA-Z0-9' _)" 2>/dev/null || echo 0; }

run_ref() {  # $1=ref → prints output; sets RC
  set +e
  OUT=$(bash "$DRIVER" "$1" 2>&1)
  RC=$?
  set -e
}

# --- a transient promptError must be retried, and the run must survive it ------
run_ref op://flaky/a/b
test "$RC" -eq 0 || { echo "flaky ref should have resolved, rc=$RC: $OUT" >&2; exit 1; }
test "$(calls_for op://flaky/a/b)" -eq 3 \
  || { echo "expected 3 op calls for the flaky ref, got $(calls_for op://flaky/a/b)" >&2; exit 1; }
case "$OUT" in *"resolved 1 value"*) ;; *) echo "expected a resolved value: $OUT" >&2; exit 1 ;; esac

# --- a genuinely missing ref must NOT be retried ------------------------------
# Retrying it only delays an error a human has to fix, and on a few hundred refs
# that is minutes of pointless waiting per broken entry.
run_ref op://missing/a/b
test "$RC" -ne 0 || { echo "missing ref should have aborted: $OUT" >&2; exit 1; }
test "$(calls_for op://missing/a/b)" -eq 1 \
  || { echo "missing ref must not be retried, got $(calls_for op://missing/a/b) calls" >&2; exit 1; }
case "$OUT" in *"cache untouched"*) ;; *) echo "expected the untouched-cache abort: $OUT" >&2; exit 1 ;; esac

# --- a hanging read must be bounded, retried, and then abort ------------------
# Unbounded, this wedges the LaunchAgent until the next tick collides with it.
start=$(date +%s)
run_ref op://hang/a/b
elapsed=$(( $(date +%s) - start ))
test "$RC" -ne 0 || { echo "hanging ref should have aborted: $OUT" >&2; exit 1; }
test "$(calls_for op://hang/a/b)" -eq 3 \
  || { echo "expected 3 bounded attempts, got $(calls_for op://hang/a/b)" >&2; exit 1; }
# 3 attempts x 2s, plus 3s + 6s of backoff. Generous ceiling; the point is that
# it terminated at all rather than sitting on the stub's 60s sleep.
test "$elapsed" -lt 45 \
  || { echo "hanging ref was not time-bounded: ${elapsed}s" >&2; exit 1; }

printf '%s\n' 'secrets-seed-retry: all tests passed'
