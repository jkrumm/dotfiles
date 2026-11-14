#!/usr/bin/env bash
# Hermetic test for colima/apply-mounts.sh: a temp colima.yaml, never the live one.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail=0
ok() { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; fail=1; }

cat >"$t/colima.yaml" <<'EOF'
cpu: 4
memory: 4
# Colima default behaviour: $HOME is mounted as writable.
# Default: []
mounts: []

# Specify a custom disk image for the virtual machine.
diskImage: ""
EOF
cat >"$t/list" <<'EOF'
# comment
~/a rw
~/b ro
EOF

[ "$("$here/apply-mounts.sh" "$t/colima.yaml" "$t/list")" = changed ] && ok "first run changes" || bad "first run changes"
grep -q '^mounts: \[\]' "$t/colima.yaml" && bad "empty mounts replaced" || ok "empty mounts replaced"
grep -q -- '  - location: ~/a' "$t/colima.yaml" && grep -A1 -- '- location: ~/a' "$t/colima.yaml" | grep -q 'writable: true' && ok "rw is writable: true" || bad "rw is writable: true"
grep -A1 -- '- location: ~/b' "$t/colima.yaml" | grep -q 'writable: false' && ok "ro is writable: false" || bad "ro is writable: false"
grep -q '^diskImage: ""' "$t/colima.yaml" && grep -q '^cpu: 4' "$t/colima.yaml" && ok "other keys kept" || bad "other keys kept"
grep -q '^# Specify a custom disk image' "$t/colima.yaml" && ok "comments after the block kept" || bad "comments after the block kept"
cp "$t/colima.yaml" "$t/before"
[ "$("$here/apply-mounts.sh" "$t/colima.yaml" "$t/list")" = unchanged ] && cmp -s "$t/before" "$t/colima.yaml" && ok "second run is a no-op" || bad "second run is a no-op"
cat >"$t/list" <<'EOF'
~/c rw
EOF
"$here/apply-mounts.sh" "$t/colima.yaml" "$t/list" >/dev/null
[ "$(grep -c -- '- location:' "$t/colima.yaml")" = 1 ] && grep -q -- '- location: ~/c' "$t/colima.yaml" && ok "a new list replaces the old block" || bad "a new list replaces the old block"
echo "# nothing" >"$t/list"
"$here/apply-mounts.sh" "$t/colima.yaml" "$t/list" >/dev/null 2>&1 && bad "an empty list is refused" || ok "an empty list is refused"
cat >"$t/list" <<'EOF'
~/d rwx
EOF
"$here/apply-mounts.sh" "$t/colima.yaml" "$t/list" >/dev/null 2>&1 && bad "a bad mode is refused" || ok "a bad mode is refused"
exit "$fail"
