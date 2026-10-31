#!/usr/bin/env bash
# Hermetic test for herdr-app-keys.sh: merges into a temp keys.json, never the app's own.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0
ok() { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fail=1; }
expect() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: want '$3', got '$2'"; fi; }

BASE='{"global":{"cmd-q":"app.quit","cmd-shift-b":"layout.toggle:board"},"terminal":{"cmd-c":"terminal.copy","cmd-left":"send:\u0001"}}'

# 1. fresh: our key added, nothing else touched
echo "$BASE" > "$T/keys.json"
"$HERE/herdr-app-keys.sh" "$T" >/dev/null
expect "binds cmd-e" "$(jq -r '.global["cmd-e"]' "$T/keys.json")" "jk-keys.brain-note"
expect "other bindings unchanged" "$(jq -c 'del(.global["cmd-e"])' "$T/keys.json")" "$(echo "$BASE" | jq -c .)"
expect "terminal section unchanged" "$(jq -c .terminal "$T/keys.json")" "$(echo "$BASE" | jq -c .terminal)"

# 2. idempotent
cp "$T/keys.json" "$T/once.json"
"$HERE/herdr-app-keys.sh" "$T" >/dev/null
if cmp -s "$T/once.json" "$T/keys.json"; then ok "second run changes nothing"; else bad "second run changed the file"; fi

# 3. a key the owner bound to something else stays theirs
echo "$BASE" | jq '.global["cmd-e"]="tab.new"' > "$T/keys.json"
out="$("$HERE/herdr-app-keys.sh" "$T")"
expect "taken key kept" "$(jq -r '.global["cmd-e"]' "$T/keys.json")" "tab.new"
case "$out" in *"is taken (tab.new)"*) ok "reports the clash";; *) bad "no clash report: $out";; esac

# 4. no global section yet
echo '{"terminal":{}}' > "$T/keys.json"
"$HERE/herdr-app-keys.sh" "$T" >/dev/null
expect "creates .global" "$(jq -r '.global["cmd-e"]' "$T/keys.json")" "jk-keys.brain-note"

# 5. no file: a no-op, no file created; not an object: refused untouched
rm "$T/keys.json"; "$HERE/herdr-app-keys.sh" "$T" >/dev/null
if [ ! -e "$T/keys.json" ]; then ok "missing keys.json is left missing"; else bad "created keys.json"; fi
echo '[1]' > "$T/keys.json"
if "$HERE/herdr-app-keys.sh" "$T" >/dev/null 2>&1; then bad "accepted a non-object"; else ok "refuses a non-object"; fi
expect "non-object untouched" "$(cat "$T/keys.json")" "[1]"

if [ "$fail" -eq 0 ]; then echo "herdr-app-keys: all passed"; else echo "herdr-app-keys: FAILED"; exit 1; fi
