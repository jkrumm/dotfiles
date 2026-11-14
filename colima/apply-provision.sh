#!/usr/bin/env bash
# Rewrite the `provision:` block of a colima.yaml to ONE `after-boot` step that carries a script (colima/vm-dns-guest.sh),
# so every start, and a recreated VM, derives its resolver before the container runtime starts. This file owns the
# whole block: any other provision entry is replaced. Everything else in the file is kept byte for byte.
# Idempotent; prints "changed" or "unchanged". Applied on the next `colima start`.
#   apply-provision.sh <colima.yaml> <script>
set -euo pipefail

yaml="$1"
script="$2"
[ -f "$yaml" ] || { echo "apply-provision: $yaml is missing" >&2; exit 1; }
[ -s "$script" ] || { echo "apply-provision: $script is missing or empty" >&2; exit 1; }

block=$(mktemp)
out=$(mktemp)
trap 'rm -f "$block" "$out"' EXIT
{
  echo "provision:"
  echo "  - mode: after-boot"
  echo "    script: |"
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -n "$line" ]; then printf '      %s\n' "$line"; else echo; fi
  done <"$script"
} >"$block"

awk -v blockfile="$block" '
  function emit(  l) { while ((getline l < blockfile) > 0) print l; close(blockfile) }
  /^provision:/ { emit(); skip = 1; found = 1; next }
  skip && /^([ \t]|-)/ { held = ""; next }
  skip && /^$/ { held = held "\n"; next }
  { if (skip && held != "") printf "%s", held; held = ""; skip = 0; print }
  END { if (!found) { print ""; emit() } }
' "$yaml" >"$out"

if cmp -s "$out" "$yaml"; then
  echo unchanged
else
  cat "$out" >"$yaml"
  echo changed
fi
