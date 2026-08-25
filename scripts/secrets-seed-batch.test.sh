#!/usr/bin/env bash
# secrets-seed-batch.test.sh — harness for secrets-seed.sh's BATCHED resolve path.
#
# Separate from secrets-seed.test.sh on purpose: that one is mini-only (its preflight
# demands the `cache` backend so local delivery is hermetic), which left the batch
# path — the one that decides how many 1Password dialogs a reseal costs — untestable
# on the machine where a human actually runs `make secrets-seed`. This harness needs
# no account, no biometric prompt, no age key and no cache backend, so it runs
# anywhere and is wired into `make secrets-lint`.
#
# Focused harness for secrets-seed.sh's batched resolve. Sources the two new helpers
# out of the script (they are pure) with a stub `op inject`, so it needs no 1Password
# account, no biometric prompt and no cache backend — it runs on any machine.
# File-scoped shellcheck exception (deliberate):
#   SC2034 — SEED_MARK, OP_BATCH_TIMEOUT, refs[], accts[] and vals[] are the SEED's
#            own globals. Each case sets them up and the helpers sourced out of
#            secrets-seed.sh read them; shellcheck cannot see through that
#            indirection and calls every one of them unused.
# shellcheck disable=SC2034
set -uo pipefail
pass=0; fail=0
ok(){ printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad(){ printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEED="$HERE/secrets-seed.sh"
# Pull just the helper definitions out of the seed (everything from run_bounded to
# the end of resolve_batch), so we test the SHIPPED code, not a copy.
HELPERS="$(mktemp "${TMPDIR:-/tmp}/seed-helpers.XXXXXX")"
trap 'rm -f "$HELPERS"' EXIT
sed -n '/^run_bounded() {/,/^}/p;/^resolve_batch() {/,/^}/p' "$SEED" > "$HELPERS"
grep -q 'resolve_batch' "$HELPERS" || { echo "could not extract helpers"; exit 2; }

die(){ echo "DIE: $*" >&2; exit 70; }
indent(){ sed 's/^/      /'; }
SEED_MARK="@@test-mark@@"
OP_BATCH_TIMEOUT=10
rerr=$(mktemp)
# shellcheck source=/dev/null
. "$HELPERS"

STUBDIR=$(mktemp -d); export PATH="$STUBDIR:$PATH"
# Quoted delimiter: every expansion below must happen at the STUB's run time, not
# while we write it. The mode is passed by file, not interpolated.
cat > "$STUBDIR/op" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
[[ "${1:-}" == "inject" ]] || exit 1
mode=$(cat "${OP_STUB_MODE_FILE}")
while IFS= read -r line; do
  case "$line" in
    '{{ '*' }}')
      ref="${line#\{\{ }"; ref="${ref% \}\}}"
      case "$mode" in
        multiline) printf 'one\ntwo\n' ;;
        failing)   echo "could not read secret: item not found" >&2; exit 1 ;;
        *)         printf 'v-%s\n' "${ref##*/}" ;;
      esac ;;
    *) printf '%s\n' "$line" ;;
  esac
done
STUB
chmod +x "$STUBDIR/op"
export OP_STUB_MODE_FILE="$STUBDIR/mode"
make_stub() { printf '%s' "$1" > "$OP_STUB_MODE_FILE"; }

# --- case 1: happy path, one call, values land by index ----------------------
make_stub normal
refs=("op://a/x/one" "op://a/y/two" "op://a/z/three"); accts=(t t t); vals=()
if resolve_batch t 0 1 2; then
  if [[ "${vals[0]}" == "v-one" && "${vals[1]}" == "v-two" && "${vals[2]}" == "v-three" ]]; then
    ok "batch resolves every ref in order"
  else
    bad "batch resolves every ref in order" "got [${vals[*]}]"
  fi
else
  bad "batch resolves every ref in order" "resolve_batch returned non-zero"
fi

# --- case 2: only the requested indices are filled ---------------------------
refs=("op://a/x/one" "op://a/y/two" "op://b/z/three"); accts=(t t c); vals=()
resolve_batch t 0 1 >/dev/null 2>&1
if [[ -z "${vals[2]+set}" ]]; then
  ok "an unrequested index is left untouched"
else
  bad "an unrequested index is left untouched" "vals[2]=[${vals[2]:-}]"
fi

# --- case 3: a multi-line value is refused, never silently misaligned --------
make_stub multiline
refs=("op://a/x/one" "op://a/y/two"); accts=(t t); vals=()
out=$( resolve_batch t 0 1 2>&1 ); rc=$?
if [[ $rc -eq 70 && "$out" == *multi-line* ]]; then
  ok "a multi-line value aborts instead of corrupting the mapping"
else
  bad "a multi-line value aborts instead of corrupting the mapping" "rc=$rc out=[$out]"
fi

# --- case 4: op failing is reported, not treated as success ------------------
make_stub failing
refs=("op://a/x/one"); accts=(t); vals=()
if resolve_batch t 0 >/dev/null 2>&1; then
  bad "a failing op is not reported as success"
else
  ok "a failing op is reported as failure (caller falls back per-ref)"
fi

# --- case 5: run_bounded enforces its deadline without coreutils timeout -----
start=$SECONDS
run_bounded 1 sleep 30 >/dev/null 2>&1; rc=$?
elapsed=$(( SECONDS - start ))
if [[ $rc -eq 124 && $elapsed -lt 8 ]]; then
  ok "run_bounded kills an overrunning command and reports 124 (${elapsed}s)"
else
  bad "run_bounded kills an overrunning command" "rc=$rc elapsed=${elapsed}s"
fi

# --- case 6: a fast command is NOT delayed by the watchdog -------------------
start=$SECONDS
out=$(run_bounded 30 printf 'quick'); rc=$?
elapsed=$(( SECONDS - start ))
if [[ $rc -eq 0 && "$out" == "quick" && $elapsed -lt 3 ]]; then
  ok "run_bounded returns immediately on success (${elapsed}s)"
else
  bad "run_bounded returns immediately on success" "rc=$rc out=[$out] elapsed=${elapsed}s"
fi

# --- case 7: no coreutils timeout/gtimeout anywhere in the op path -----------
if grep -qE '(^|[^-[:alnum:]])(g?timeout)[[:space:]]+-k' "$SEED"; then
  bad "op is never wrapped in coreutils timeout" "found a 'timeout -k' invocation"
else
  ok "op is never wrapped in coreutils timeout (TCC responsible process stays bash)"
fi

rm -rf "$STUBDIR" "$rerr"
echo; echo "  $pass passed, $fail failed"
[[ $fail -eq 0 ]]
