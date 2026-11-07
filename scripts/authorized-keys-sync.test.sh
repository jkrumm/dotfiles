#!/usr/bin/env bash
# authorized-keys-sync.test.sh — regression harness for scripts/authorized-keys-sync.sh
# (replace-by-key-blob install, backups, validation, rollback) and for the real
# config/ssh/authorized_keys.iumac key line.
#
# Hermetic: throwaway keys from ssh-keygen, temp targets only. Never touches
# ~/.ssh.
#
# Usage: scripts/authorized-keys-sync.test.sh   (exit 0 = all pass)

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC="$HERE/authorized-keys-sync.sh"
IUMAC_FILE="$HERE/../config/ssh/authorized_keys.iumac"
IUMAC_BLOB="AAAAC3NzaC1lZDI1NTE5AAAAIABPkPsMROlF6nF0127jSEkNFlJ+Iqtkpy0T3nuMEOoJ"

pass=0
fail=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; [[ -n "${2:-}" ]] && printf '         %s\n' "$2"; fail=$((fail + 1)); }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }

[[ -x "$SYNC" ]] || { echo "✗ $SYNC not found/executable"; exit 2; }
command -v ssh-keygen >/dev/null 2>&1 || { echo "✗ ssh-keygen missing"; exit 2; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/akeys-test.XXXXXX")" || exit 2
trap 'rm -rf "$TMP"' EXIT

for n in a b c; do ssh-keygen -q -t ed25519 -N '' -C "key-$n" -f "$TMP/k$n" >/dev/null; done
pub() { awk '{print $1 " " $2}' "$TMP/k$1.pub"; }   # "<type> <blob>"
blob() { awk '{print $2}' "$TMP/k$1.pub"; }
OPTS='restrict,command="/bin/true"'

mode() { stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"; }
count_in() { grep -cF -- "$2" "$1" 2>/dev/null; }   # <file> <fixed string>
backups() { ls "$1".bak-* 2>/dev/null | wc -l | tr -d ' '; }

echo "== fresh install"
T="$TMP/t1/authorized_keys"
printf '# header\n%s\n' "$OPTS $(pub a) a-restricted" >"$TMP/s1"
"$SYNC" "$T" "$TMP/s1" >/dev/null; rc=$?
assert_eq "exit 0" "0" "$rc"
assert_eq "key present once" "1" "$(count_in "$T" "$(blob a)")"
assert_eq "mode 600" "600" "$(mode "$T")"
assert_eq "no backup for a fresh file" "0" "$(backups "$T")"

echo "== replace by blob"
T="$TMP/t2/authorized_keys"
mkdir -p "$TMP/t2"
{
  echo "# my keys"
  echo "$(pub a) old-unrestricted-comment"
  echo "no-pty $(pub b) unrelated"
  echo "restrict,pty $(pub a) older-line"
} >"$T"
"$SYNC" "$T" "$TMP/s1" >/dev/null; rc=$?
assert_eq "exit 0" "0" "$rc"
assert_eq "key a exactly once" "1" "$(count_in "$T" "$(blob a)")"
assert_eq "new line present" "1" "$(count_in "$T" "$OPTS $(pub a) a-restricted")"
assert_eq "old lines gone" "0" "$(grep -cE 'old-unrestricted-comment|older-line' "$T")"
assert_eq "unrelated key kept untouched" "1" "$(count_in "$T" "no-pty $(pub b) unrelated")"
assert_eq "comment line kept" "1" "$(count_in "$T" "# my keys")"
assert_eq "one backup" "1" "$(backups "$T")"
bak="$(ls "$T".bak-*)"
assert_eq "backup mode 600" "600" "$(mode "$bak")"
assert_eq "backup holds the old unrestricted line" "1" "$(count_in "$bak" "old-unrestricted-comment")"

echo "== idempotent"
cp "$T" "$TMP/t2.before"
"$SYNC" "$T" "$TMP/s1" >/dev/null; rc=$?
assert_eq "exit 0" "0" "$rc"
cmp -s "$T" "$TMP/t2.before" && ok "byte-identical" || bad "byte-identical"
assert_eq "no new backup" "1" "$(backups "$T")"

echo "== rollback"
"$SYNC" --rollback "$T" >/dev/null; rc=$?
assert_eq "exit 0" "0" "$rc"
assert_eq "old line restored" "1" "$(count_in "$T" "old-unrestricted-comment")"
assert_eq "replaced file kept as .pre-rollback" "1" "$(count_in "$T.pre-rollback" "$OPTS $(pub a) a-restricted")"
assert_eq "mode 600 after rollback" "600" "$(mode "$T")"
"$SYNC" --rollback "$TMP/t1/authorized_keys" >/dev/null 2>&1; rc=$?
assert_eq "rollback with no backup: exit 1" "1" "$rc"

echo "== backups capped"
T="$TMP/t3/authorized_keys"
mkdir -p "$TMP/t3"
for i in 1 2 3 4 5 6 7 8; do
  printf '%s\n' "$OPTS $(pub a) rev-$i" >"$TMP/s3"
  "$SYNC" "$T" "$TMP/s3" >/dev/null
done
assert_eq "at most 5 backups" "5" "$(backups "$T")"
assert_eq "newest line live" "1" "$(count_in "$T" "rev-8")"
"$SYNC" --rollback "$T" >/dev/null
assert_eq "rollback restores the newest backup (rev-7)" "1" "$(count_in "$T" "rev-7")"

echo "== validation failure leaves the target untouched"
T="$TMP/t4/authorized_keys"
mkdir -p "$TMP/t4"
printf '%s\n' "$(pub b) keep" >"$T"
cp "$T" "$TMP/t4.before"
printf '%s\n' "ssh-ed25519 AAAAnotakey broken" >"$TMP/s4"
"$SYNC" "$T" "$TMP/s4" >"$TMP/t4.out" 2>&1; rc=$?
assert_eq "exit 1" "1" "$rc"
cmp -s "$T" "$TMP/t4.before" && ok "target byte-identical" || bad "target byte-identical"
assert_eq "no backup made" "0" "$(backups "$T")"
case "$(cat "$TMP/t4.out")" in *"validation failed"*) ok "reason printed" ;; *) bad "reason printed" "$(cat "$TMP/t4.out")" ;; esac
"$SYNC" "$T" "$TMP/does-not-exist" >/dev/null 2>&1; rc=$?
assert_eq "missing source: exit 1" "1" "$rc"
assert_eq "no temp files left behind" "1" "$(ls "$TMP/t4" | wc -l | tr -d ' ')"

echo "== several sources"
T="$TMP/t5/authorized_keys"
printf '%s\n' "$(pub b) b-line" >"$TMP/s5a"
printf '%s\n' "$OPTS $(pub c) c-line" >"$TMP/s5b"
"$SYNC" "$T" "$TMP/s5a" "$TMP/s5b" >/dev/null
assert_eq "both installed" "2" "$(grep -c 'ssh-ed25519' "$T")"

echo "== real config/ssh/authorized_keys.iumac"
T="$TMP/t6/authorized_keys"
mkdir -p "$TMP/t6"
printf '%s\n' "restrict,pty ssh-ed25519 $IUMAC_BLOB mini->iumac" >"$T"
"$SYNC" "$T" "$IUMAC_FILE" >/dev/null; rc=$?
assert_eq "installs and parses" "0" "$rc"
line="$(grep -F "$IUMAC_BLOB" "$T")"
assert_eq "key line exactly once" "1" "$(grep -cF "$IUMAC_BLOB" "$T")"
assert_eq "key blob unchanged" "1" "$(ssh-keygen -l -f "$T" | grep -c 'mini->iumac')"
case "$line" in restrict,*) ok "starts with restrict" ;; *) bad "starts with restrict" "$line" ;; esac
case "$line" in *'command="/bin/bash \"$HOME/SourceRoot/dotfiles/scripts/iumac-gate.sh\""'*) ok "forced command to the gate" ;; *) bad "forced command to the gate" "$line" ;; esac
case "$line" in *pty*) bad "no pty option" "$line" ;; *) ok "no pty option" ;; esac
case "$line" in *"restrict"*"ssh-ed25519 $IUMAC_BLOB"*) ok "options precede the key" ;; *) bad "options precede the key" ;; esac

echo "== result file and --rollback-to"
T="$TMP/t7/authorized_keys"
R="$TMP/t7.result"
printf '%s\n' "$OPTS $(pub a) v1" >"$TMP/s7a"
printf '%s\n' "$OPTS $(pub a) v2" >"$TMP/s7b"
AUTHORIZED_KEYS_SYNC_RESULT="$R" "$SYNC" "$T" "$TMP/s7a" >/dev/null
assert_eq "new target: created" "created" "$(cat "$R")"
AUTHORIZED_KEYS_SYNC_RESULT="$R" "$SYNC" "$T" "$TMP/s7a" >/dev/null
assert_eq "no change: unchanged" "unchanged" "$(cat "$R")"
AUTHORIZED_KEYS_SYNC_RESULT="$R" "$SYNC" "$T" "$TMP/s7b" >/dev/null
res="$(cat "$R")"
BAK="${res#backup }"
case "$res" in "backup $T.bak-"*) ok "change: backup <path>" ;; *) bad "change: backup <path>" "$res" ;; esac
assert_eq "named backup holds the replaced file" "1" "$(count_in "$BAK" "v1")"
# a newer backup appears (another run) — --rollback-to still restores the named one
cp "$T" "$T.bak-99999999999999"
echo "$OPTS $(pub a) v3" >"$T"
"$SYNC" --rollback-to "$BAK" "$T" >/dev/null; rc=$?
assert_eq "rollback-to: exit 0" "0" "$rc"
assert_eq "restores exactly the named backup" "1" "$(count_in "$T" "v1")"
assert_eq "replaced file kept as .pre-rollback" "1" "$(count_in "$T.pre-rollback" "v3")"
assert_eq "mode 600 after rollback-to" "600" "$(mode "$T")"
"$SYNC" --rollback-to "$TMP/nope" "$T" >/dev/null 2>&1; rc=$?
assert_eq "rollback-to missing backup: exit 1" "1" "$rc"

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
