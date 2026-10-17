#!/usr/bin/env bash
# Regression tests for secrets-seed.sh's per-ref read loop, its circuit breaker and
# the ref-vs-access classifier.
#
# Separate from secrets-seed.test.sh because that suite is mini-gated (it refuses
# to run unless the backend marker says `cache`, to avoid an ssh to the mini).
# This one runs on the MacBook (it is wired into `make secrets-lint`), since the
# MacBook is where the failure it guards actually happens.
#
# WHAT IT GUARDS. Every `op` PROCESS that hits a missing macOS TCC grant raises its
# own "op wants to access data from other apps" dialog, and the dialog's Allow
# button does not persist. The contract:
#   - a genuine ref problem (op's own "isn't an item" family) is collected and the
#     loop continues, so one pass names every dead ref;
#   - an access failure (authorization, handshake, timeout, anything unrecognised)
#     stops the whole loop at the FIRST occurrence with the Full Disk Access
#     instruction — no retry, no next ref.
#
# It drives the code by EXTRACTING it from the real script rather than
# duplicating it, so the two cannot drift apart quietly: if the markers move, the
# extraction comes back short and the test fails loudly instead of testing a
# stale copy of the logic.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/secrets-seed.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/secrets-seed-retry.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "$1" >&2; exit 1; }

# --- the op stub --------------------------------------------------------------
# A PATH stub, deliberately NOT a shell function: a function would be sailed past by
# anything that execs the binary it finds on PATH. A first draft of this test used a
# function, hit the REAL op, and "passed" while proving nothing — the error text in
# the output was the giveaway (it named actual vaults).
mkdir -p "$TMP/bin"
cat >"$TMP/bin/op" <<'EOF'
#!/usr/bin/env bash
# argv: read --account <acct> <ref>
ref="${4:-}"
n_file="$FAKE_OP_COUNT_DIR/$(echo "$ref" | tr -c 'a-zA-Z0-9' _)"
n=$(cat "$n_file" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" >"$n_file"
echo x >>"$FAKE_OP_COUNT_DIR/_all"
case "$ref" in
  # A handshake failure.
  op://flaky/a/b)   echo "[ERROR] error initializing client: response: promptError" >&2; exit 1 ;;
  # The authorization dialog being dismissed.
  op://auth/a/b)    echo "[ERROR] could not read secret '$ref': authorization prompt dismissed" >&2; exit 1 ;;
  # The same, with op's own ref-error phrase inside the echoed item name.
  "op://auth/isn't an item/b") echo "[ERROR] could not read secret '$ref': authorization prompt dismissed" >&2; exit 1 ;;
  # Hangs on a dialog that never renders — must be killed by the timeout bound.
  op://hang/a/b)    sleep 60; echo "never" ;;
  # Genuinely absent refs. Not an access problem: collected, loop continues.
  op://missing/a/b) echo '[ERROR] "a" isn'"'"'t an item in the "missing" vault' >&2; exit 1 ;;
  op://missing2/a/b) echo '[ERROR] "a" isn'"'"'t an item in the "missing2" vault' >&2; exit 1 ;;
  *) echo "ok-value" ;;
esac
EOF
chmod +x "$TMP/bin/op"

# --- extract the code under test ---------------------------------------------
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
grep -q 'op_failure_is_ref_problem' "$DRIVER" \
  || fail "extraction failed: the classifier was not found in $SCRIPT — did the markers move?"
grep -q 'abort_op_access' "$DRIVER" \
  || fail "extraction failed: the access-failure abort was not found in $SCRIPT"
bash -n "$DRIVER"

CLASSIFIER="$TMP/classifier.sh"
sed -n '/^op_failure_is_ref_problem() {/,/^}/p' "$SCRIPT" >"$CLASSIFIER"
grep -q 'return 0' "$CLASSIFIER" || fail "extraction failed: classifier body not found"
ABORT="$TMP/abort.sh"
sed -n '/^abort_op_access() {/,/^}/p' "$SCRIPT" >"$ABORT"
grep -q 'Full Disk Access' "$ABORT" || fail "extraction failed: abort body not found"

export PATH="$TMP/bin:$PATH"
export FAKE_OP_COUNT_DIR="$TMP/counts"
mkdir -p "$FAKE_OP_COUNT_DIR"
# 2s per read keeps the hang case bearable; the real default is 30s. Batching off:
# this harness drives the per-ref loop directly.
export SECRETS_SEED_OP_READ_TIMEOUT=2
export SECRETS_SEED_OP_BATCH=0
OP_REAL="$(realpath "$TMP/bin/op")"

calls_for() { cat "$FAKE_OP_COUNT_DIR/$(echo "$1" | tr -c 'a-zA-Z0-9' _)" 2>/dev/null || echo 0; }
total_calls() {
  local n
  n=$(wc -l <"$FAKE_OP_COUNT_DIR/_all") || return 1   # run_refs always creates it
  echo "${n// /}"
}

run_refs() {  # $@=refs → sets OUT, RC; resets the counters
  rm -rf "$FAKE_OP_COUNT_DIR"; mkdir -p "$FAKE_OP_COUNT_DIR"; : >"$FAKE_OP_COUNT_DIR/_all"
  set +e
  OUT=$(bash "$DRIVER" "$@" 2>&1)
  RC=$?
  set -e
}

assert_fda_abort() {  # $1=label ; uses OUT/RC
  test "$RC" -ne 0 || fail "$1: should have aborted: $OUT"
  case "$OUT" in *"$OP_REAL"*) ;; *) fail "$1: abort must name the resolved op path $OP_REAL: $OUT" ;; esac
  case "$OUT" in *"Full Disk Access"*) ;; *) fail "$1: abort must point at Full Disk Access: $OUT" ;; esac
  case "$OUT" in *"Allow button does NOT persist"*) ;; *) fail "$1: abort must say Allow does not persist: $OUT" ;; esac
  case "$OUT" in *"op signin --account tkrumm"*) ;; *) fail "$1: abort must mention the locked/signed-out case: $OUT" ;; esac
  case "$OUT" in *"cache untouched"*) ;; *) fail "$1: expected the untouched-cache abort: $OUT" ;; esac
}

# --- classifier, table-driven: every accepted phrase is pinned ----------------
# shellcheck source=/dev/null
. "$CLASSIFIER"
rerr="$TMP/rerr"
classify() {  # $1=exit status  $2=stderr text → rc of op_failure_is_ref_problem
  printf '%s\n' "$2" >"$rerr"
  op_failure_is_ref_problem "$1"
}
while IFS= read -r phrase_line; do
  classify 1 "$phrase_line" || fail "allowlisted phrase not accepted as a ref problem: $phrase_line"
done <<'EOF'
[ERROR] 2026/10/17 00:00:00 "x" isn't an item in the "v" vault. Specify the item with its UUID, name, or domain.
[ERROR] 2026/10/17 00:00:00 "x" isn't a vault in this account. Specify the vault with its ID or name.
[ERROR] 2026/10/17 00:00:00 could not read secret 'op://v/i/f': "f" isn't a field in the "i" item
[ERROR] 2026/10/17 00:00:00 More than one item matches "x". Try again and specify the item by its ID:
[ERROR] 2026/10/17 00:00:00 invalid secret reference 'op://v': it needs a vault, an item and a field
[ERROR] 2026/10/17 00:00:00 invalid character in secret reference: '!' in token "op://v/i!/f"
EOF
# negatives: each must fall through to the abort
classify 1 "[ERROR] could not read secret 'op://v/isn't an item/x': authorization prompt dismissed" \
  && fail "an item name containing a ref-error phrase flipped an authorization error to a ref problem"
classify 1 "[ERROR] error initializing client: response: promptError" && fail "handshake error accepted as ref problem"
classify 1 "[ERROR] something op has never said before" && fail "unrecognised error accepted as ref problem"
classify 1 '"x" isn'"'"'t an item in the "v" vault' && fail "a line without op's [ERROR] prefix was accepted"
classify 124 "[ERROR] \"x\" isn't an item in the \"v\" vault" && fail "a timeout was accepted as a ref problem"
classify 137 "[ERROR] \"x\" isn't an item in the \"v\" vault" && fail "a SIGKILL was accepted as a ref problem"

# --- abort text when op is not on PATH -------------------------------------
OUT=$(PATH=/usr/bin:/bin bash -c 'die() { echo "DIE: $*" >&2; exit 1; }; indent() { sed "s/^/      /"; }
  OP_ACCOUNT=tkrumm; rerr="$2"; echo "[ERROR] boom" >"$rerr"; . "$1"; abort_op_access "testing" 1 tkrumm' _ "$ABORT" "$TMP/rerr2" 2>&1 || true)
case "$OUT" in *"op is not on PATH"*) ;; *) fail "missing op must be named explicitly: $OUT" ;; esac
case "$OUT" in *"Full Disk Access"*) fail "missing op must not print an FDA path: $OUT" ;; esac
case "$OUT" in *"op signin --account tkrumm"*) ;; *) fail "missing op still gets the locked/signed-out hint: $OUT" ;; esac

# --- a handshake failure is NOT retried: one op process, FDA abort ------------
run_refs op://flaky/a/b
assert_fda_abort "handshake failure"
test "$(calls_for op://flaky/a/b)" -eq 1 \
  || fail "handshake failure must not be retried, got $(calls_for op://flaky/a/b) calls"

# --- an authorization error stops the loop: the next ref is never read --------
run_refs op://ok/a/b op://auth/a/b op://ok2/a/b op://ok3/a/b
assert_fda_abort "authorization error"
test "$(total_calls)" -eq 2 \
  || fail "loop must stop at the first access failure (2 op processes), got $(total_calls)"
test "$(calls_for op://ok2/a/b)" -eq 0 || fail "ref after the failure must never be read"

# --- a ref-error phrase inside the echoed ref must not flip the verdict -------
run_refs op://ok/a/b "op://auth/isn't an item/b" op://ok2/a/b
assert_fda_abort "echoed phrase"
test "$(total_calls)" -eq 2 || fail "echoed-phrase auth error must stop the loop, got $(total_calls) op processes"

# --- a hanging read is bounded, NOT retried, and aborts -----------------------
# Unbounded, this wedges the LaunchAgent until the next tick collides with it.
start=$(date +%s)
run_refs op://hang/a/b op://ok/a/b
elapsed=$(( $(date +%s) - start ))
assert_fda_abort "hang"
case "$OUT" in *"killed by the watchdog"*) ;; *) fail "timeout abort should say the watchdog killed op: $OUT" ;; esac
test "$(total_calls)" -eq 1 || fail "hanging read must be a single attempt, got $(total_calls) op processes"
test "$elapsed" -lt 20 || fail "hanging ref was not time-bounded: ${elapsed}s"

# --- a genuinely missing ref is collected, not an access failure --------------
run_refs op://missing/a/b
test "$RC" -ne 0 || fail "missing ref should have aborted: $OUT"
test "$(calls_for op://missing/a/b)" -eq 1 \
  || fail "missing ref must not be retried, got $(calls_for op://missing/a/b) calls"
case "$OUT" in *"cache untouched"*) ;; *) fail "expected the untouched-cache abort: $OUT" ;; esac
case "$OUT" in *"Full Disk Access"*) fail "a missing ref must not be reported as an access failure: $OUT" ;; esac

# --- every dead ref is reported, not just the first ---------------------------
# A deleted 1Password item blocks EVERY reseal (fail-closed), and reporting one
# ref per biometric pass turns a five-ref outage into five passes — which is
# exactly what happened on 2026-08-29 with careerpartner's deleted `care-stage`.
run_refs op://missing/a/b op://missing2/a/b op://ok/a/b
test "$RC" -ne 0 || fail "dead refs should still abort: $OUT"
case "$OUT" in *"op://missing/a/b"*) ;; *) fail "first dead ref missing from the report: $OUT" ;; esac
case "$OUT" in *"op://missing2/a/b"*) ;; *) fail "second dead ref missing from the report: $OUT" ;; esac
case "$OUT" in *"cache untouched"*) ;; *) fail "expected the untouched-cache abort: $OUT" ;; esac
test "$(total_calls)" -eq 3 || fail "all three refs should be read exactly once, got $(total_calls)"

# --- a dead ref followed by an access failure: the breaker still trips --------
run_refs op://missing/a/b op://auth/a/b op://ok/a/b
assert_fda_abort "breaker after a dead ref"
test "$(total_calls)" -eq 2 || fail "third ref must not be read after the breaker, got $(total_calls)"

printf '%s\n' 'secrets-seed-retry: all tests passed'
