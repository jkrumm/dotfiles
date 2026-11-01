#!/usr/bin/env bash
set -eu
# Hermetic test for herdr-core-launcher-build.sh: scratch LAUNCHER_BIN, stub ask-human, no live launcher touched.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/repo/scripts"
fail() { echo "FAIL: $*" >&2; exit 1; }
cat > "$T/ask-ok" <<S
#!/bin/sh
echo "\$@" >> "$T/asks"
S
printf '#!/bin/sh\nexit 1\n' > "$T/ask-bad"; chmod +x "$T/ask-ok" "$T/ask-bad"
cp "$HERE/herdr-core-launcher.c" "$T/repo/scripts/"
build() { LAUNCHER_BIN="$T/lib/launcher" DOTFILES_DIR="$T/repo" ASK_HUMAN="$1" bash "$HERE/herdr-core-launcher-build.sh"; }
dr() { codesign -dr- "$T/lib/launcher" 2>&1 | sed -n 's/^# designated => //p; s/^designated => //p'; }

# 1. first build: re-grant queued, then installed
out=$(build "$T/ask-ok") || fail "first build: $out"
[ -s "$T/asks" ] || fail "first build must queue the re-grant"
grep -q "$T/lib/launcher" "$T/asks" || fail "ask must name the exact path"
grep -q "make tcc-probe" "$T/asks" || fail "ask must name make tcc-probe"
[ "$(dr)" = 'identifier "com.jkrumm.herdr-core-launcher"' ] || fail "DR must be identifier-only: $(dr)"
# 2. unchanged: no rebuild
out=$(build "$T/ask-bad") || fail "up-to-date run must not need ask-human"
case "$out" in *"up to date"*) ;; *) fail "expected up to date: $out" ;; esac
# 3. source change: new cdhash, same DR, grant holds, no ask
echo 'const char herdr_touched[] = "x";' >>"$T/repo/scripts/herdr-core-launcher.c"
cdh_before=$(shasum "$T/lib/launcher")
: > "$T/asks"
out=$(build "$T/ask-bad") || fail "same-DR rebuild must not need ask-human: $out"
[ ! -s "$T/asks" ] || fail "same-DR rebuild must not ask"
[ "$(shasum "$T/lib/launcher")" != "$cdh_before" ] || fail "binary should differ"
[ "$(dr)" = 'identifier "com.jkrumm.herdr-core-launcher"' ] || fail "DR must survive a rebuild"
# 4. legacy cdhash-bound ad-hoc launcher (old marker, no explicit DR): migration must queue, and refuse when it cannot
cc -o "$T/lib/launcher" "$T/repo/scripts/herdr-core-launcher.c"; codesign -f -s - --identifier com.jkrumm.herdr-core-launcher "$T/lib/launcher" 2>/dev/null
echo "deadbeef" > "$T/lib/launcher.src-sha"
if out=$(build "$T/ask-bad"); then fail "migration without a queued re-grant must refuse"; fi
case "$out" in *"could not be queued"*) ;; *) fail "refusal message: $out" ;; esac
[ ! -e "$T/lib/launcher.new" ] || fail "refused build must clean up"
codesign -dr- "$T/lib/launcher" 2>&1 | grep -q cdhash || fail "refusal must leave the old launcher in place"
: > "$T/asks"
build "$T/ask-ok" >/dev/null || fail "migration with a queued re-grant must install"
[ -s "$T/asks" ] || fail "migration must queue"
[ "$(dr)" = 'identifier "com.jkrumm.herdr-core-launcher"' ] || fail "migrated DR"
echo "herdr-core-launcher-build.test.sh: ok"
