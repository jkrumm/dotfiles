#!/usr/bin/env bash
set -eu
# Hermetic test for tcc-check.sh: fake LaunchAgents dir, ad-hoc signed copy of /bin/ls.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/la" "$T/bin"
cp /bin/ls "$T/bin/adhoc-tool"; codesign -f -s - "$T/bin/adhoc-tool" 2>/dev/null
mkplist() { rm -f "$T/la/$1.plist"; /usr/bin/plutil -create xml1 "$T/la/$1.plist" && /usr/bin/plutil -insert Label -string "$1" "$T/la/$1.plist" \
  && /usr/bin/plutil -insert ProgramArguments -array "$T/la/$1.plist" && /usr/bin/plutil -insert ProgramArguments.0 -string "$2" "$T/la/$1.plist"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
run() { TCC_CHECK_LAUNCHAGENTS="$T/la" TCC_CHECK_LIST="$T/list.json" TCC_CHECK_LAUNCHER="$T/bin/launcher" bash "$HERE/tcc-check.sh"; }

echo '{"programs":{}}' > "$T/list.json"
mkplist com.test.stable /bin/ls
run >/dev/null || fail "an Apple-signed program must pass"

mkplist com.test.adhoc "$T/bin/adhoc-tool"
if out=$(run); then fail "unclassified ad-hoc program must fail"; fi
case "$out" in *com.test.adhoc*"ad-hoc signed"*) ;; *) fail "message names label and reason: $out" ;; esac

echo '{"programs":{"com.test.adhoc":{"class":"no-grant","why":"test"}}}' > "$T/list.json"
run >/dev/null || fail "a classified program must pass"

mkplist com.jkrumm.herdr-core "$T/bin/adhoc-tool"
if out=$(run); then fail "core job not on the launcher must fail"; fi
case "$out" in *"not the launcher"*) ;; *) fail "core message: $out" ;; esac
cp "$T/bin/adhoc-tool" "$T/bin/launcher"
mkplist com.jkrumm.herdr-core "$T/bin/launcher"
echo '{"programs":{"com.test.adhoc":{"class":"no-grant","why":"t"},"com.jkrumm.herdr-core":{"class":"launcher","why":"t"}}}' > "$T/list.json"
run >/dev/null || fail "core on the launcher must pass"
mkplist com.jkrumm.opbackup /bin/bash
if out=$(run); then fail "an op job outside the launcher must fail"; fi
case "$out" in *"com.jkrumm.opbackup"*"not the launcher"*) ;; *) fail "opbackup message: $out" ;; esac
mkplist com.jkrumm.opbackup "$T/bin/launcher"
run >/dev/null || fail "an op job on the launcher must pass"
echo "tcc-check.test.sh: ok"
