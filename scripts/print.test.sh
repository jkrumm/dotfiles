#!/usr/bin/env bash
# print.test.sh: regression harness for scripts/print.sh.
#
# Hermetic: HOME is a temp tree and `bun` is a stub on PATH that echoes the entry and the arguments it
# was given. No printer, no checkout of the real repo.
#
# Usage: scripts/print.test.sh   (exit 0 = all pass)

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAP="$HERE/print.sh"
pass=0
fail=0
ok() { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; [[ -n "${2:-}" ]] && printf '         %s\n' "$2"; fail=$((fail + 1)); }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
assert_contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "[$3] does not contain [$2]" ;; esac; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/print-test.XXXXXX")" || exit 2
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
H="$TMP/home"
EXT="$H/SourceRoot/tinycast-extensions/extension"
mkdir -p "$TMP/bin" "$H"

cat >"$TMP/bin/bun" <<'STUB'
#!/bin/sh
printf 'bun'
for a in "$@"; do printf ' [%s]' "$a"; done
printf '\n'
STUB
chmod +x "$TMP/bin/bun"
run() { HOME="$H" PATH="$TMP/bin:/usr/bin:/bin" "$WRAP" "$@"; }

# 1. no checkout: one JSON failure line, exit 1
out="$(run --check)"; rc=$?
assert_eq "no checkout exits 1" "1" "$rc"
assert_contains "no checkout names the checkout" "tinycast-extensions" "$out"
assert_contains "no checkout prints JSON" '"ok":false' "$out"

# 2. source only: runs print.ts with the arguments in order
mkdir -p "$EXT/scripts"
: >"$EXT/scripts/print.ts"
out="$(run doc.pdf --dry-run --pages '1-3')"; rc=$?
assert_eq "source entry exits with the stub's 0" "0" "$rc"
assert_eq "source entry forwards the arguments" "bun [$EXT/scripts/print.ts] [doc.pdf] [--dry-run] [--pages] [1-3]" "$out"

# 3. bundle present: the bundle wins over the source
mkdir -p "$EXT/assets"
: >"$EXT/assets/print-cli.js"
out="$(run --check)"
assert_eq "bundle preferred over source" "bun [$EXT/assets/print-cli.js] [--check]" "$out"

echo
echo "print.test.sh: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
