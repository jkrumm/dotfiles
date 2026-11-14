#!/usr/bin/env bash
# Rewrite the `mounts:` block of a colima.yaml from a mounts list (colima/mounts.mini.txt:
# `<path> rw|ro` per line, # comments). Everything else in the file is kept byte for byte.
# Idempotent; prints "changed" or "unchanged". Applied on the next `colima start`.
#   apply-mounts.sh <colima.yaml> <mounts list>
set -euo pipefail

yaml="$1"
list="$2"
[ -f "$yaml" ] || { echo "apply-mounts: $yaml is missing" >&2; exit 1; }
[ -f "$list" ] || { echo "apply-mounts: $list is missing" >&2; exit 1; }

block=$(mktemp)
out=$(mktemp)
trap 'rm -f "$block" "$out"' EXIT
echo "mounts:" >"$block"
n=0
while read -r path mode _; do
  case "$path" in '' | \#*) continue ;; esac
  case "$mode" in rw) w=true ;; ro) w=false ;; *) echo "apply-mounts: $path: mode must be rw or ro, got '$mode'" >&2; exit 1 ;; esac
  printf '  - location: %s\n    writable: %s\n' "$path" "$w" >>"$block"
  n=$((n + 1))
done <"$list"
[ "$n" -gt 0 ] || { echo "apply-mounts: $list lists no mount; refusing to fall back to colima's \$HOME default" >&2; exit 1; }

# Replace the top-level `mounts:` key and its indented or list continuation lines.
awk -v blockfile="$block" '
  function emit(  l) { while ((getline l < blockfile) > 0) print l; close(blockfile) }
  /^mounts:/ { emit(); skip = 1; found = 1; next }
  skip && /^([ \t]|-)/ { next }
  { skip = 0; print }
  END { if (!found) { print ""; emit() } }
' "$yaml" >"$out"

if cmp -s "$out" "$yaml"; then
  echo unchanged
else
  cat "$out" >"$yaml"
  echo changed
fi
