#!/usr/bin/env bash
# herdr-glance-sync.test.sh — hermetic suite for scripts/herdr-glance-sync.sh.
# Stubs stand in for `hc exec --on mini` (tars a fixture tree) and `herdr-app` (check / status / do); nothing outside
# the temp dir is touched.
#
# Usage: scripts/herdr-glance-sync.test.sh   (exit 0 = all pass)
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC="$HERE/herdr-glance-sync.sh"

pass=0
fail=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; [[ -n "${2:-}" ]] && printf '         %s\n' "$2"; fail=$((fail + 1)); }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
assert_contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "[$3] does not contain [$2]" ;; esac; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/glance-sync-test.XXXXXX")" || exit 2
trap 'rm -rf "$TMP"' EXIT
DEST="$TMP/share"; AH="$TMP/app"; REMOTE="$TMP/remote"; APPLOG="$TMP/app.log"
mkdir -p "$AH/mods" "$REMOTE/jk-glance"

# hc stub: `hc exec --on mini sh -c <cmd>` -> tar of $REMOTE/jk-glance (or $TAR_OVERRIDE), or fail when HC_FAIL is set.
cat >"$TMP/hc" <<STUB
#!/bin/bash
[ -z "\${HC_FAIL:-}" ] || { echo "no route to mini" >&2; exit 3; }
[ -z "\${TAR_OVERRIDE:-}" ] || { cat "\$TAR_OVERRIDE"; exit 0; }
tar -C "$REMOTE" -cf - jk-glance
STUB
# herdr-app stub: logs every call; check fails when the mod's main.js says BROKEN; status fails when APP_DOWN is set.
cat >"$TMP/app-stub" <<STUB
#!/bin/bash
echo "\$*" >>"$APPLOG"
case "\$1" in
  check) grep -q BROKEN "\$2/main.js" && { echo "syntax error in main.js"; exit 1; }; touch "\$2/gpui-kit.d.ts"; exit 0 ;;
  status) [ -z "\${APP_DOWN:-}" ] || exit 1; echo '{"layout": "main"}'; exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$TMP/hc" "$TMP/app-stub"

export HERDR_GLANCE_DIR="$DEST" HERDR_APP_HOME="$AH" HERDR_GLANCE_HC="$TMP/hc" HERDR_GLANCE_APP="$TMP/app-stub"
RC=0; OUT=""
run() { OUT="$(bash "$SYNC" "$@" 2>&1)"; RC=$?; }
mod() { printf '%s\n' "$1" >"$REMOTE/jk-glance/main.js"; printf '{"v":"%s"}\n' "$1" >"$REMOTE/jk-glance/mod.json"; }
live_sum() { (cd "$DEST/jk-glance" && cat main.js mod.json | shasum -a 256 | cut -c1-12); }
reloads() { grep -c 'layout.switch' "$APPLOG" 2>/dev/null || true; }

echo "== first run installs, links, reloads"
mod one
: >"$APPLOG"
run
assert_eq "rc" "0" "$RC"
assert_contains "says updated" "(updated)" "$OUT"
assert_eq "live copy has the mod" "$(cat "$REMOTE/jk-glance/main.js")" "$(cat "$DEST/jk-glance/main.js")"
assert_eq "mods link points at the live copy" "$DEST/jk-glance" "$(readlink "$AH/mods/jk-glance")"
assert_eq "layout reloaded main + jk" "2" "$(reloads)"
[[ ! -e "$DEST/jk-glance/gpui-kit.d.ts" ]] && ok "check never wrote into the live dir" || bad "check wrote into the live dir"

echo "== second run is current and does not reload"
: >"$APPLOG"
run
assert_eq "rc" "0" "$RC"
assert_contains "says current" "(current)" "$OUT"
assert_eq "no reload" "0" "$(reloads)"

echo "== a changed mod is swapped"
mod two
: >"$APPLOG"
run
assert_contains "says updated" "(updated)" "$OUT"
assert_eq "live copy is the new one" "two" "$(cat "$DEST/jk-glance/main.js")"
assert_eq "reloaded" "2" "$(reloads)"
[[ ! -e "$DEST/jk-glance.old" ]] && ok "no .old left behind" || bad ".old left behind"

echo "== a broken mod leaves the running copy"
mod BROKEN
: >"$APPLOG"
run
assert_eq "rc 1" "1" "$RC"
assert_contains "names the reason" "syntax error in main.js" "$OUT"
assert_eq "live copy untouched" "two" "$(cat "$DEST/jk-glance/main.js")"
assert_eq "no reload" "0" "$(reloads)"

echo "== app not running: copied, no reload"
mod three
: >"$APPLOG"
APP_DOWN=1 run
assert_contains "updated" "(updated)" "$OUT"
assert_eq "no reload" "0" "$(reloads)"

echo "== the mini unreachable"
HC_FAIL=1 run
assert_eq "rc 1" "1" "$RC"
assert_contains "names the reason" "cannot read the glance" "$OUT"
assert_eq "live copy untouched" "three" "$(cat "$DEST/jk-glance/main.js")"

echo "== the reload is skipped on request"
mod four
: >"$APPLOG"
HERDR_GLANCE_NO_RELOAD=1 run
assert_contains "updated" "(updated)" "$OUT"
assert_eq "no reload" "0" "$(reloads)"

echo "== hostile tars are refused"
mkdir -p "$TMP/evil/jk-glance" && echo x >"$TMP/evil/jk-glance/main.js" && echo '{}' >"$TMP/evil/jk-glance/mod.json"
ln -s /etc/passwd "$TMP/evil/jk-glance/link"
tar -C "$TMP/evil" -cf "$TMP/link.tar" jk-glance
TAR_OVERRIDE="$TMP/link.tar" run
assert_eq "symlink: rc 1" "1" "$RC"; assert_contains "symlink: reason" "link or special" "$OUT"
rm "$TMP/evil/jk-glance/link"; echo y >"$TMP/evil/other"
tar -C "$TMP/evil" -cf "$TMP/path.tar" jk-glance other
TAR_OVERRIDE="$TMP/path.tar" run
assert_eq "outside path: rc 1" "1" "$RC"; assert_contains "outside path: reason" "outside jk-glance" "$OUT"
TAR_OVERRIDE=/dev/null run
assert_eq "empty tar: rc 1" "1" "$RC"
assert_eq "live copy still four" "four" "$(cat "$DEST/jk-glance/main.js")"

echo "== arguments and locks"
run now; assert_eq "an argument is refused" "1" "$RC"
mkdir "$DEST/.glance-sync.lock"
run
assert_eq "a held lock: rc 0" "0" "$RC"; assert_contains "a held lock: busy" "busy" "$OUT"
[[ -d "$DEST/.glance-sync.lock" ]] && ok "a held lock is left alone" || bad "the held lock was removed"
rmdir "$DEST/.glance-sync.lock"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
