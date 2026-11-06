#!/usr/bin/env bash
# opbackup-auto.test — hermetic regression suite for scripts/opbackup-auto.sh,
# the guarded hourly trigger for the 1Password vault backup.
#
# The script runs from a SANDBOX COPY whose /usr/sbin/ioreg, /usr/bin/pgrep and
# /usr/bin/osascript are rewritten to stubs; ssh, date, the backup script and the
# secrets-cache seed guard are stubs too, HOME and the stamp dir are scratch, and
# `date +%s` is fixed — so stamp ages are exact and nothing reads the clock.
#
# Asserted: WHEN it runs vs skips and WHY — each gate in cheapest-first order
# (backend, success freshness, attempt backoff, locked screen, 1Password
# running, remote reachable), the strict `<` boundaries, that --force bypasses
# only the freshness/backoff/lock gates, the stamps a run leaves behind, and how
# a failed seed guard folds into the exit code. Skips exit 0.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/opbackup-auto.sh"
[ -f "$SRC" ] || { echo "✗ $SRC not found"; exit 1; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/opbackup-auto-test.XXXXXX") || exit 1
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
mkdir -p "$BIN" "$SB"
NOW=1800000000
DAY=86400
HOUR=3600

sed -e "s|/usr/sbin/ioreg|$BIN/ioreg|g" \
    -e "s|/usr/bin/pgrep|$BIN/pgrep|g" \
    -e "s|/usr/bin/osascript|$BIN/osascript|g" \
    "$SRC" > "$SB/opbackup-auto.sh"

cat > "$BIN/date" <<EOF
#!/bin/sh
if [ "\$1" = "+%s" ]; then echo $NOW; else echo "2027-01-15 08:00:00"; fi
EOF
cat > "$BIN/ioreg" <<'EOF'
#!/bin/sh
cat "$ST/ioreg_out"
EOF
cat > "$BIN/pgrep" <<'EOF'
#!/bin/sh
[ -f "$ST/no_1password" ] && exit 1
exit 0
EOF
cat > "$BIN/osascript" <<'EOF'
#!/bin/sh
echo "$*" >> "$ST/notify.log"
EOF
cat > "$BIN/ssh" <<'EOF'
#!/bin/sh
# reachability probe: last arg is `true`; seed mode: last arg is the ls command
for last; do :; done
if [ "$last" = true ]; then [ -f "$ST/remote_down" ] && exit 255; exit 0; fi
[ -f "$ST/remote_down" ] && exit 255
cat "$ST/remote_listing"
EOF
cat > "$TMP/backup.sh" <<'EOF'
#!/bin/sh
echo run >> "$ST/backup.log"
[ -f "$ST/backup_fail" ] && exit 1
exit 0
EOF
cat > "$TMP/seed.sh" <<'EOF'
#!/bin/sh
echo run >> "$ST/seed.log"
exit "$(cat "$ST/seed_rc")"
EOF
chmod +x "$BIN"/* "$TMP/backup.sh" "$TMP/seed.sh"

export PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin"
export HOME="$TMP/home"
export OPBACKUP_STATE_DIR="$TMP/state"
export OPBACKUP_SCRIPT="$TMP/backup.sh" OPBACKUP_SEED_AUTO_SCRIPT="$TMP/seed.sh"
unset OPBACKUP_MAX_AGE_DAYS OPBACKUP_RETRY_HOURS OPBACKUP_REMOTE_HOST

set_age() {  # $1 file, $2 seconds before NOW
  mkdir -p "$OPBACKUP_STATE_DIR"
  python3 -c 'import os,sys; t=int(sys.argv[2]); os.utime(sys.argv[1], (t, t)) if os.path.exists(sys.argv[1]) else (open(sys.argv[1],"w").close(), os.utime(sys.argv[1], (t, t)))' "$1" $((NOW - $2))
}
SUCCESS="$OPBACKUP_STATE_DIR/last-success"; ATTEMPT="$OPBACKUP_STATE_DIR/last-attempt"

# reset: a present-human machine that is due — backend op, success 10d old, no
# attempt, screen unlocked, 1Password up, remote reachable, seed guard green.
reset() {
  rm -rf "$ST" "$HOME" "$OPBACKUP_STATE_DIR"
  mkdir -p "$ST" "$HOME/.config/secrets"
  echo op > "$HOME/.config/secrets/backend"
  : > "$ST/ioreg_out"; echo 0 > "$ST/seed_rc"
  set_age "$SUCCESS" $((10 * DAY))
}
OUT=""; RC=0
run() { RC=0; OUT=$(/bin/bash "$SB/opbackup-auto.sh" "$@" 2>&1) || RC=$?; }
ran()  { [ -f "$ST/backup.log" ] && echo yes || echo no; }
mtime_of() { /usr/bin/stat -f %m "$1" 2>/dev/null || echo none; }

echo "usage"
reset; run --bogus
assert_eq "unknown flag exits 2" "$RC" 2
assert_contains "usage printed" "$OUT" "usage: opbackup-auto.sh [--force] [--seed-stamp]"

echo "gate 1: present-human machine only"
reset; echo cache > "$HOME/.config/secrets/backend"; run
assert_eq "cache backend skips with exit 0" "$RC" 0
assert_contains "names the backend" "$OUT" "skip — secrets backend is 'cache', not 'op'"
assert_eq "backup not run" "$(ran)" no
reset; rm "$HOME/.config/secrets/backend"; run
assert_contains "no backend file reads as unset" "$OUT" "backend is 'unset'"
reset; echo cache > "$HOME/.config/secrets/backend"; run --force
assert_eq "--force does not override the backend gate" "$(ran)" no

echo "gate 2: success freshness (strict <)"
reset; set_age "$SUCCESS" $((1 * DAY)); run
assert_contains "1d old is fresh" "$OUT" "skip — last backup 1d old (< 5d)"
assert_eq "fresh: not run" "$(ran)" no
reset; set_age "$SUCCESS" $((5 * DAY - 1)); run
assert_contains "just under 5d is still fresh" "$OUT" "skip — last backup 4d old (< 5d)"
reset; set_age "$SUCCESS" $((5 * DAY)); run
assert_eq "exactly 5d is due" "$(ran)" yes
reset; rm "$SUCCESS"; run
assert_eq "no success stamp at all is due" "$(ran)" yes
reset; set_age "$SUCCESS" $((2 * DAY)); OPBACKUP_MAX_AGE_DAYS=1 run
assert_eq "max age is overridable" "$(ran)" yes

echo "gate 3: attempt backoff (strict <)"
reset; set_age "$ATTEMPT" $((1 * HOUR)); run
assert_contains "attempt 1h ago backs off" "$OUT" "skip — attempted 60m ago (backoff 6h)"
assert_eq "backoff: not run" "$(ran)" no
reset; set_age "$ATTEMPT" $((6 * HOUR - 60)); run
assert_contains "just under 6h still backs off" "$OUT" "attempted 359m ago"
reset; set_age "$ATTEMPT" $((6 * HOUR)); run
assert_eq "exactly 6h is due" "$(ran)" yes
reset; set_age "$ATTEMPT" $((1 * HOUR)); OPBACKUP_RETRY_HOURS=1 run
assert_eq "retry window is overridable" "$(ran)" yes

echo "gate 4: locked screen"
reset; printf '    | "CGSSessionScreenIsLocked" = Yes\n' > "$ST/ioreg_out"; run
assert_contains "locked screen skips" "$OUT" "skip — screen is locked"
assert_eq "locked: not run" "$(ran)" no
reset; printf '    | "CGSSessionScreenIsLocked" = No\n' > "$ST/ioreg_out"; run
assert_eq "an explicit No is not locked" "$(ran)" yes
reset; run
assert_eq "key absent (unlocked) runs" "$(ran)" yes

echo "--force bypasses freshness, backoff and lock"
reset; set_age "$SUCCESS" $((1 * DAY)); set_age "$ATTEMPT" $((1 * HOUR))
printf '"CGSSessionScreenIsLocked" = Yes\n' > "$ST/ioreg_out"; run --force
assert_eq "--force runs through all three" "$(ran)" yes
assert_eq "--force exits 0" "$RC" 0

echo "gate 5/6: 1Password running, remote reachable"
reset; touch "$ST/no_1password"; run
assert_contains "1Password not running skips" "$OUT" "skip — 1Password desktop is not running"
assert_eq "no 1Password: not run" "$(ran)" no
assert_eq "no 1Password: no attempt stamp (no prompt was spent)" "$(mtime_of "$ATTEMPT")" none
reset; touch "$ST/no_1password"; run --force
assert_eq "--force does not override 1Password gate" "$(ran)" no
reset; touch "$ST/remote_down"; run
assert_contains "unreachable remote skips before the prompt" "$OUT" "skip — homelab unreachable"
assert_eq "unreachable: not run" "$(ran)" no
assert_eq "unreachable: no attempt stamp" "$(mtime_of "$ATTEMPT")" none
reset; touch "$ST/remote_down"; OPBACKUP_REMOTE_HOST=other run
assert_contains "remote host is overridable" "$OUT" "skip — other unreachable"

echo "a run"
reset; run
assert_eq "exit 0" "$RC" 0
assert_eq "backup ran once" "$(cat "$ST/backup.log")" run
assert_contains "logs the last-success age" "$OUT" "running — last success 10d ago"
assert_contains "logs completion" "$OUT" "done"
assert_eq "attempt stamp set at NOW-ish (touched, not backdated)" "$([ "$(mtime_of "$ATTEMPT")" != none ] && [ "$(mtime_of "$ATTEMPT")" != "$((NOW - 10 * DAY))" ] && echo yes)" yes
assert_eq "success stamp refreshed" "$([ "$(mtime_of "$SUCCESS")" != "$((NOW - 10 * DAY))" ] && echo yes)" yes
assert_contains "user is told to approve Touch ID" "$(cat "$ST/notify.log")" "approve the Touch ID prompt"
assert_contains "user is told it completed" "$(cat "$ST/notify.log")" "Complete — encrypted copy sent to homelab"

reset; touch "$ST/backup_fail"; run
assert_eq "failed backup exits 1" "$RC" 1
assert_contains "failure says it will retry" "$OUT" "FAILED — see above; will retry after 6h"
assert_eq "failed backup leaves the success stamp alone" "$(mtime_of "$SUCCESS")" "$((NOW - 10 * DAY))"
assert_eq "failed backup still sets the attempt stamp (backoff)" "$([ "$(mtime_of "$ATTEMPT")" != none ] && echo yes)" yes
assert_contains "failure is notified" "$(cat "$ST/notify.log")" "1Password backup failed"
reset; touch "$ST/backup_fail"; run
set_age "$ATTEMPT" $((10 * 60)); run
assert_contains "after a failed attempt the next hourly fire backs off" "$OUT" "attempted 10m ago"
assert_eq "…without running again" "$(wc -l < "$ST/backup.log" | tr -d ' ')" 1

echo "seed guard folds into the exit code"
reset; echo 3 > "$ST/seed_rc"; run
assert_eq "seed guard ran" "$(cat "$ST/seed.log")" run
assert_contains "seed failure is logged, vault backup continues" "$OUT" "secrets-cache seed failed (exit 3); continuing with vault backup"
assert_eq "vault backup still ran" "$(ran)" yes
assert_contains "mixed outcome is logged" "$OUT" "vault backup succeeded, but secrets-cache seed failed"
assert_eq "run exits with the seed code" "$RC" 3
reset; echo 3 > "$ST/seed_rc"; set_age "$SUCCESS" $((1 * DAY)); run
assert_eq "a skip carries the seed code too" "$RC" 3
reset; echo 3 > "$ST/seed_rc"; touch "$ST/backup_fail"; run
assert_eq "failed backup wins with exit 1" "$RC" 1
reset; OPBACKUP_SEED_AUTO_SCRIPT="$TMP/missing.sh" run
assert_contains "missing guard is logged, not fatal" "$OUT" "secrets-cache guard missing"
assert_eq "missing guard: run proceeds" "$(ran)" yes
assert_eq "missing guard: exit 0" "$RC" 0

echo "--seed-stamp"
reset; rm "$SUCCESS"
printf '1password-2026-10-30.json.age\n1password-2026-11-01.json.age\nnotes.txt\n' > "$ST/remote_listing"; run --seed-stamp
assert_eq "seed mode exits 0" "$RC" 0
assert_contains "success stamp is backdated to the newest remote backup" "$OUT" "success stamp backdated to 2026-11-01"
assert_eq "stamp date is the newest backup's day" "$(/usr/bin/stat -f %Sm -t %Y-%m-%d "$SUCCESS")" 2026-11-01
assert_eq "seed mode never runs the backup" "$(ran)" no
reset; rm "$SUCCESS"; : > "$ST/remote_listing"; run --seed-stamp
assert_contains "no remote backup leaves the stamp unset" "$OUT" "no remote backup found, leaving stamp unset"
assert_eq "no stamp was created" "$(mtime_of "$SUCCESS")" none
reset; rm "$SUCCESS"; touch "$ST/remote_down"; run --seed-stamp
assert_eq "unreachable remote in seed mode exits 0" "$RC" 0
assert_eq "unreachable remote leaves no stamp" "$(mtime_of "$SUCCESS")" none

echo
if [ "$fails" -eq 0 ]; then echo "opbackup-auto: all passed"; else echo "opbackup-auto: $fails failed"; exit 1; fi
