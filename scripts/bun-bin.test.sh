#!/usr/bin/env bash
# bun-bin.test — hermetic suite for scripts/lib/bun-bin.sh (bun_bin_dir, bunx_path_dir).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/bun-bin-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
fails=0
ok()  { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fails=$((fails + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — got '$2', want '$3'"; fi; }

# shellcheck source=lib/bun-bin.sh
source "$HERE/lib/bun-bin.sh"
export PATH="/usr/bin:/bin"

mkdir -p "$TMP/a" "$TMP/b"
printf '#!/bin/sh\necho "bun-called $*"\n' > "$TMP/a/bun"; chmod +x "$TMP/a/bun"

echo "bunx_path_dir"
assert_eq "bun with no bunx: shim dir returned" "$(bunx_path_dir "$TMP/a" "$TMP/shims")" "$TMP/shims"
[ -x "$TMP/shims/bunx" ] && ok "shim is executable" || bad "shim is executable"
assert_eq "shim runs 'bun x …'" "$("$TMP/shims/bunx" tsc --noEmit)" "bun-called x tsc --noEmit"
cp "$TMP/shims/bunx" "$TMP/a/bunx"
assert_eq "bunx beside bun: bun dir returned" "$(bunx_path_dir "$TMP/a" "$TMP/shims2")" "$TMP/a"
[ -d "$TMP/shims2" ] && bad "no shim dir created when bunx exists" || ok "no shim dir created when bunx exists"
rm "$TMP/a/bunx"
cp "$TMP/shims/bunx" "$TMP/b/bunx"
assert_eq "bunx elsewhere on PATH: bun dir returned" "$(PATH="$TMP/b:$PATH" bunx_path_dir "$TMP/a" "$TMP/shims3")" "$TMP/a"

echo "bun_bin_dir"
assert_eq "bun on PATH resolves its dir" "$(PATH="$TMP/a:$PATH" bun_bin_dir)" "$TMP/a"
mkdir -p "$TMP/inst/bin"; cp "$TMP/a/bun" "$TMP/inst/bin/bun"
assert_eq "BUN_INSTALL/bin used off-PATH" "$(BUN_INSTALL="$TMP/inst" bun_bin_dir)" "$TMP/inst/bin"

echo
if [ "$fails" -eq 0 ]; then echo "bun-bin: all passed"; else echo "bun-bin: $fails failed"; exit 1; fi
