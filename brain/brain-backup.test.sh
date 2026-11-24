#!/usr/bin/env bash
# Regression tests for brain-backup.sh: a failed heartbeat is logged, and a live
# brain-sync lock is waited out (bounded) instead of costing the night.
# Hermetic: a scratch vault over a local bare repo as origin, a lock dir inside the
# scratch dir, and a push URL that refuses connections. No network, no Kuma.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/brain-backup.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/brain-backup-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid

VAULT="$TMP/vault"
LOCK="$TMP/brain-sync.lock"
git init -q --bare -b master "$TMP/origin.git"
git init -q -b master "$VAULT"
git -C "$VAULT" remote add origin "$TMP/origin.git"
echo base >"$VAULT/base.md"
git -C "$VAULT" add base.md
git -C "$VAULT" commit -q -m base
git -C "$VAULT" push -q -u origin master

fail() { echo "FAIL: $*" >&2; exit 1; }
expect_contains() { case "$1" in *"$2"*) ;; *) printf '%s\n' "$1" >&2; fail "output lacks: $2" ;; esac; }
head_subject() { git -C "$VAULT" log -1 --format=%s; }
dirty() { echo "$1" >"$VAULT/$1.md"; }

# Runs one sweep with the test's paths; extra env comes in as arguments.
# Sets OUT and RC.
sweep() {
  RC=0
  OUT="$(env BRAIN_VAULT="$VAULT" BRAIN_SYNC_LOCK_DIR="$LOCK" \
    BRAIN_BACKUP_PUSH_URL_FILE="$TMP/no-url-file" "$@" bash "$SCRIPT" 2>&1)" || RC=$?
}

# 1. A heartbeat that cannot reach Kuma is logged; the sweep still commits and pushes.
dirty failed-beat
sweep BRAIN_BACKUP_PUSH_URL=http://127.0.0.1:1/api/push/unreachable
[ "$RC" -eq 0 ] || fail "failed beat: exit $RC, want 0"
expect_contains "$OUT" "heartbeat (up) did not reach Kuma"
expect_contains "$(head_subject)" "chore(brain): nightly vault sync"

# 2. A live holder that releases within the wait is waited out, then the sweep runs.
dirty waited
sleep 30 &
holder=$!
mkdir "$LOCK"
printf '%s' "$holder" >"$LOCK/pid"
( sleep 2; kill "$holder" 2>/dev/null || true; rm -rf "$LOCK" ) &
sweep BRAIN_BACKUP_LOCK_WAIT=20
[ "$RC" -eq 0 ] || fail "released lock: exit $RC, want 0"
expect_contains "$OUT" "vault lock free after"
expect_contains "$(head_subject)" "chore(brain): nightly vault sync"
wait "$holder" 2>/dev/null || true

# 3. A holder that outlives the wait costs the night: no commit, and brain-sync's lock is left alone.
dirty skipped
before="$(git -C "$VAULT" rev-parse HEAD)"
sleep 30 &
holder=$!
mkdir "$LOCK"
printf '%s' "$holder" >"$LOCK/pid"
sweep BRAIN_BACKUP_LOCK_WAIT=2
kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
[ "$RC" -eq 0 ] || fail "live holder past the wait: exit $RC, want 0"
expect_contains "$OUT" "could not take the vault lock"
[ "$(git -C "$VAULT" rev-parse HEAD)" = "$before" ] || fail "a sweep committed while the lock was held"
[ -f "$LOCK/pid" ] || fail "the sweep removed a lock a live run holds"
rm -rf "$LOCK"

# 4. A lock whose holder is dead is reclaimed at once, as before.
dirty reclaimed
sleep 0 &
dead=$!
wait "$dead" 2>/dev/null || true
mkdir "$LOCK"
printf '%s' "$dead" >"$LOCK/pid"
sweep BRAIN_BACKUP_LOCK_WAIT=20
[ "$RC" -eq 0 ] || fail "dead holder: exit $RC, want 0"
expect_contains "$OUT" "reclaiming the lock"
expect_contains "$(head_subject)" "chore(brain): nightly vault sync"

# 5. A lock that cannot be created at all is bounded by the same wait, never a busy loop.
RC=0
OUT="$(env BRAIN_VAULT="$VAULT" BRAIN_SYNC_LOCK_DIR="$TMP/no-such-dir/brain-sync.lock" \
  BRAIN_BACKUP_LOCK_WAIT=2 BRAIN_BACKUP_PUSH_URL_FILE="$TMP/no-url-file" bash "$SCRIPT" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] || fail "uncreatable lock: exit $RC, want 0"
expect_contains "$OUT" "could not take the vault lock"
[ "$(printf '%s\n' "$OUT" | wc -l)" -lt 10 ] || fail "uncreatable lock: output grew without bound"

echo "brain-backup tests: ok"
