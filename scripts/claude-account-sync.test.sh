#!/usr/bin/env bash
# claude-account-sync.test.sh — hermetic suite for scripts/claude-account-sync.sh.
# A stub `hc` stands in for `hc exec --on mini` (cats a fixture file); nothing outside the temp dir is touched.
#
# Usage: scripts/claude-account-sync.test.sh   (exit 0 = all pass)
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC="$HERE/claude-account-sync.sh"

pass=0
fail=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; [[ -n "${2:-}" ]] && printf '         %s\n' "$2"; fail=$((fail + 1)); }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
assert_contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "[$3] does not contain [$2]" ;; esac; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ca-sync-test.XXXXXX")" || exit 2
trap 'rm -rf "$TMP"' EXIT
DEST="$TMP/share"; REMOTE="$TMP/remote"
mkdir -p "$REMOTE"

# hc stub: `hc exec --on mini sh -c <cmd>` -> the fixture file (or $FILE_OVERRIDE), or fail when HC_FAIL is set.
cat >"$TMP/hc" <<STUB
#!/bin/bash
[ -z "\${HC_FAIL:-}" ] || { echo "no route to mini" >&2; exit 3; }
cat "\${FILE_OVERRIDE:-$REMOTE/claude-account}"
STUB
chmod +x "$TMP/hc"

export CLAUDE_ACCOUNT_SYNC_DIR="$DEST" CLAUDE_ACCOUNT_SYNC_HC="$TMP/hc"
RC=0; OUT=""
run() { OUT="$(bash "$SYNC" "$@" 2>&1)"; RC=$?; }
# build <tag> [name]: a fake built file (bun shebang, like the real one) whose --version prints the package name and the tag.
build() { printf '#!/usr/bin/env bun\necho "%s 0.1.0 (%s)"\n' "${2:-@software-factory/accounts}" "$1" >"$REMOTE/claude-account"; }
# `bun` stub on PATH: skips the shebang line and runs the rest with bash.
mkdir -p "$TMP/bin"
printf '#!/bin/bash\nf="$1"; shift\ntail -n +2 "$f" | bash -s -- "$@"\n' >"$TMP/bin/bun"; chmod +x "$TMP/bin/bun"
export PATH="$TMP/bin:$PATH"

echo "== first run installs"
build one
run
assert_eq "rc" "0" "$RC"
assert_contains "says updated" "(updated)" "$OUT"
assert_contains "names the package" "@software-factory/accounts 0.1.0 (one)" "$OUT"
assert_eq "live copy is the pulled file" "$(cat "$REMOTE/claude-account")" "$(cat "$DEST/claude-account")"
[[ -x "$DEST/claude-account" ]] && ok "executable" || bad "not executable"

echo "== second run is current"
run
assert_eq "rc" "0" "$RC"
assert_contains "says current" "(current)" "$OUT"

echo "== a changed file is swapped"
build two
run
assert_contains "says updated" "(updated)" "$OUT"
assert_contains "new version" "(two)" "$OUT"
[[ ! -e "$DEST/claude-account.old" ]] && ok "no .old left behind" || bad ".old left behind"

echo "== a file that is not the package leaves the running copy"
build three "something-else"
run
assert_eq "rc 1" "1" "$RC"
assert_contains "names the reason" "not the accounts package" "$OUT"
assert_contains "running copy still two" "(two)" "$("$DEST/claude-account" --version)"

echo "== a file that does not run leaves the running copy"
printf '#!/usr/bin/env bun\nexit 7\n' >"$REMOTE/claude-account"
run
assert_eq "rc 1" "1" "$RC"
assert_contains "names the reason" "does not run" "$OUT"
assert_contains "running copy still two" "(two)" "$("$DEST/claude-account" --version)"

echo "== not a bun script, empty file, the mini unreachable"
printf 'hello\n' >"$REMOTE/claude-account"; run
assert_eq "no shebang: rc 1" "1" "$RC"; assert_contains "no shebang: reason" "not a bun script" "$OUT"
: >"$REMOTE/claude-account"; run
assert_eq "empty: rc 1" "1" "$RC"; assert_contains "empty: reason" "empty" "$OUT"
build four
HC_FAIL=1 run
assert_eq "unreachable: rc 1" "1" "$RC"; assert_contains "unreachable: reason" "cannot read claude-account" "$OUT"
assert_contains "running copy still two" "(two)" "$("$DEST/claude-account" --version)"

echo "== arguments and locks"
run now; assert_eq "an argument is refused" "1" "$RC"
mkdir "$DEST/.sync.lock"
run
assert_eq "a held lock: rc 0" "0" "$RC"; assert_contains "a held lock: busy" "busy" "$OUT"
[[ -d "$DEST/.sync.lock" ]] && ok "a held lock is left alone" || bad "the held lock was removed"
rmdir "$DEST/.sync.lock"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
