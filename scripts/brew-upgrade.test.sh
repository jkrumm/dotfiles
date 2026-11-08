#!/usr/bin/env bash
# brew-upgrade.test — hermetic regression suite for scripts/brew-upgrade.sh.
#
# The script runs its main at load, so it is exercised end to end from a SANDBOX
# COPY: the copy has its host-absolute paths (the brew tailscaled, PlistBuddy)
# rewritten to scratch stubs, lib/ is symlinked, and tcc-check.sh is a stub. The
# script under test is not modified. brew, caddy, sqlite3, op, launchctl and
# tailscale are stubs first on PATH; HOME is scratch.
#
# Asserted: pin convergence (and that --dry-run mutates nothing), the
# held/third-party/cask/upgradable partition by FULL name, every post-upgrade
# assertion's pass/fail line and the exit code it drives, the success stamp, and
# the tcc_allows rc contract (0 granted, 1 absent, 2 db unreadable).
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/brew-upgrade.sh"
[ -f "$SRC" ] || { echo "✗ $SRC not found"; exit 1; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/brew-upgrade-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

fails=0
ok()  { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fails=$((fails + 1)); }
assert_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — got '$2', want '$3'"; fi
}
assert_contains() {
  if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1 — missing '$3' in: $2"; fi
}
assert_not_contains() {
  if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1 — unexpected '$3' in: $2"; fi
}

SB="$TMP/sandbox"; BIN="$TMP/bin"; ST="$TMP/st"; TS="$TMP/ts"
mkdir -p "$SB/scripts" "$SB/colima" "$BIN" "$TS"
ln -s "$HERE/lib" "$SB/scripts/lib"
WRAPPER="$(cd "$SB/scripts/.." && pwd)/colima/colima-start.sh"

# The sandbox copy: host-absolute paths -> scratch paths.
sed -e "s|-S /var/run/tailscaled.socket|-f $TS/sock|" \
    -e "s|/var/run/tailscaled.socket|$TS/sock|g" \
    -e "s|/opt/homebrew/bin/tailscale|$TS/tailscale|g" \
    -e "s|/opt/homebrew/opt/tailscale|$TS/opt-tailscale|g" \
    -e "s|/usr/libexec/PlistBuddy|$BIN/PlistBuddy|g" \
    "$SRC" > "$SB/scripts/brew-upgrade.sh"
if grep -q '^ *if \[\[ -x /opt/homebrew' "$SB/scripts/brew-upgrade.sh"; then
  echo "✗ sandbox rewrite missed the tailscale path"; exit 1
fi

# tcc-check stub: passes unless $ST/tcc_fail exists.
cat > "$SB/scripts/tcc-check.sh" <<EOF
#!/bin/sh
[ -f "$ST/tcc_fail" ] && { echo "program x unclassified"; exit 1; }
exit 0
EOF

cat > "$BIN/brew" <<EOF
#!/bin/sh
echo "\$*" >> "$ST/brew.log"
case "\$1" in
  update) exit 0 ;;
  pin) echo "\$2" >> "$ST/pinned"; exit 0 ;;
  list)
    case "\$2" in
      --pinned) cat "$ST/pinned" ;;
      --formula)
        if [ "\$3" = "--versions" ]; then grep -qxF "\$4" "$ST/installed"; exit \$?; fi
        cat "$ST/fullnames" ;;
    esac ;;
  outdated)
    if [ "\$2" = "--cask" ]; then cat "$ST/outdated_c"; else cat "$ST/outdated_f"; fi ;;
  upgrade)
    [ -f "$ST/upgrade_fail" ] && exit 1
    if [ -f "$ST/upgrade_hang" ]; then echo "Warning: A newer Command Line Tools release is available"; sleep 60; fi
    if [ -f "$ST/upgrade_unpins" ]; then grep -vxF caddy "$ST/pinned" > "$ST/pinned.n"; mv "$ST/pinned.n" "$ST/pinned"; fi
    exit 0 ;;
  services) cat "$ST/services_json" ;;
esac
exit 0
EOF
cat > "$BIN/caddy" <<EOF
#!/bin/sh
cat "$ST/caddy_modules"
EOF
cat > "$BIN/sqlite3" <<EOF
#!/bin/sh
[ -f "$ST/sqlite_fail" ] && exit 1
cat "$ST/tcc_rows"
EOF
cat > "$BIN/launchctl" <<EOF
#!/bin/sh
cat "$ST/launchctl_print"
EOF
# PlistBuddy stub over key=value "plists": -c 'Print :Key[:0]' FILE
cat > "$BIN/PlistBuddy" <<'EOF'
#!/bin/sh
key=${2#Print :}
case "$key" in
  ProgramArguments:0) key=Program0 ;;
esac
v=$(sed -n "s/^$key=//p" "$3")
[ -n "$v" ] || exit 1
printf '%b\n' "$v"
EOF
cat > "$TS/tailscale" <<EOF
#!/bin/sh
cat "$ST/ts_version"
EOF
cat > "$BIN/op" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$BIN"/* "$TS/tailscale" "$SB/scripts/tcc-check.sh"

export PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin"
export HOME="$TMP/home"
export BREW_SERVICE_PLISTBUDDY="$BIN/PlistBuddy"
export BREW_UPGRADE_STAMP="$TMP/stamp/last-success"
export BREW_UPGRADE_IDLE_SECS=2 BREW_UPGRADE_POLL_SECS=1 HOMEBREW_LOGS="$TMP/hblogs"
LOCK="$HOME/.local/state/brew-upgrade/lock"

# reset: a quiet machine — nothing installed, nothing outdated, no tailscale, no
# colima plist, backend unset, op absent.
reset() {
  rm -rf "$ST" "$HOME" "$TMP/stamp" "$TS/sock" "$TS/opt-tailscale"
  [ -x "$BIN/op" ] || mv "$BIN/op.off" "$BIN/op" 2>/dev/null
  mkdir -p "$ST" "$HOME/.config/secrets" "$HOME/Library/LaunchAgents"
  : > "$ST/brew.log"
  for f in pinned installed outdated_f outdated_c fullnames services_json \
           caddy_modules tcc_rows launchctl_print ts_version; do : > "$ST/$f"; done
  : > "$HOME/.config/secrets/backend"
}
set_backend() { printf '%s\n' "$1" > "$HOME/.config/secrets/backend"; }
without_op()  { mv "$BIN/op" "$BIN/op.off"; }
put()         { local f=$1; shift; printf '%s\n' "$@" > "$ST/$f"; }

OUT=""; RC=0
run() { RC=0; OUT=$(/bin/bash "$SB/scripts/brew-upgrade.sh" "$@" 2>&1) || RC=$?; }
brewlog() { cat "$ST/brew.log"; }

echo "usage"
reset; run --bogus
assert_eq "unknown flag exits 1" "$RC" 1
assert_contains "unknown flag prints usage" "$OUT" "usage: brew-upgrade.sh"

echo "--pins-only"
reset; put installed caddy; put pinned foo
run --pins-only
assert_eq "pins-only exits 0" "$RC" 0
assert_contains "unpinned held formula gets pinned" "$OUT" "✓ pinned caddy"
assert_contains "uninstalled held formula is skipped" "$OUT" "tailscale not installed (skip)"
assert_contains "foreign pin is reported, not removed" "$OUT" "! foo is pinned but not in HELD"
assert_contains "brew pin caddy was called" "$(brewlog)" "pin caddy"
assert_not_contains "pins-only never runs brew update" "$(brewlog)" "update"
assert_not_contains "pins-only never lists outdated" "$(brewlog)" "outdated"
assert_eq "pins-only writes no stamp" "$([ -e "$BREW_UPGRADE_STAMP" ] && echo yes || echo no)" no

reset; put installed caddy tailscale; put pinned caddy tailscale
run --pins-only
assert_contains "already-pinned is idempotent" "$OUT" "· caddy pinned"
assert_not_contains "no redundant pin call" "$(brewlog)" "pin caddy"

echo "--dry-run"
reset; put installed caddy; put outdated_f jq
run --dry-run
assert_eq "dry-run exits 0" "$RC" 0
assert_contains "dry-run previews the pin" "$OUT" "caddy would be pinned (dry-run)"
assert_not_contains "dry-run does not pin" "$(brewlog)" "pin caddy"
assert_contains "dry-run lists what would upgrade" "$OUT" "would upgrade (dry-run): jq"
assert_not_contains "dry-run does not upgrade" "$(brewlog)" "upgrade"
assert_eq "dry-run writes no stamp" "$([ -e "$BREW_UPGRADE_STAMP" ] && echo yes || echo no)" no
reset; run --dry-run
assert_contains "dry-run with nothing outdated" "$OUT" "nothing to upgrade (dry-run)"

echo "partition by FULL name"
reset; put installed caddy tailscale; put pinned caddy tailscale
put outdated_f caddy tailscale oven-sh/bun/bun jq ripgrep
put outdated_c some-cask other-cask
put fullnames oven-sh/bun/bun jq ripgrep caddy
run
assert_eq "clean upgrade exits 0" "$RC" 0
assert_contains "held caddy gets the exact fixup line" "$OUT" "brew unpin caddy && brew upgrade caddy && make caddy-dns-build && brew pin caddy"
assert_contains "held tailscale points at make tailscale-upgrade" "$OUT" "make tailscale-upgrade HOST=mini"
assert_contains "third-party tap is reported by full name" "$OUT" "review manually (third-party tap): oven-sh/bun/bun"
assert_contains "casks are reported" "$OUT" "release-age cooldown applies: some-cask,other-cask"
assert_contains "only core, unheld formulae are upgraded" "$(brewlog)" "upgrade --formula jq ripgrep"
assert_not_contains "third-party never reaches brew upgrade" "$(brewlog)" "upgrade --formula jq ripgrep oven-sh"
assert_contains "summary counts every bucket" "$OUT" "upgraded 2, skipped: 2 held, 1 third-party, 2 cask(s)"
assert_eq "success stamp written" "$([ -e "$BREW_UPGRADE_STAMP" ] && echo yes || echo no)" yes

reset; put outdated_f caddy; put installed caddy; put pinned caddy
run
assert_contains "nothing upgradable says why" "$OUT" "nothing to upgrade — every outdated formula is held"
assert_not_contains "no brew upgrade call" "$(brewlog)" "upgrade --formula"

reset; put outdated_f jq; touch "$ST/upgrade_fail"
run
assert_eq "failed brew upgrade exits 1" "$RC" 1
assert_contains "failed brew upgrade says so" "$OUT" "✗ brew upgrade failed"
assert_eq "failed upgrade writes no stamp" "$([ -e "$BREW_UPGRADE_STAMP" ] && echo yes || echo no)" no

echo "post-upgrade: pin survives"
reset; put installed caddy; put pinned caddy; put outdated_f jq; touch "$ST/upgrade_unpins"
run
assert_eq "lost pin exits 1" "$RC" 1
assert_contains "lost pin names the fix" "$OUT" "✗ caddy is installed but no longer pinned (fix: brew pin caddy)"
assert_eq "stamp still written when an assertion fails" "$([ -e "$BREW_UPGRADE_STAMP" ] && echo yes || echo no)" yes
reset; put installed caddy; put pinned caddy
run
assert_contains "kept pin is confirmed" "$OUT" "✓ caddy still pinned"

echo "post-upgrade: caddy module (dev host only)"
reset; set_backend cache; put caddy_modules "http.handlers.file_server" "dns.providers.cloudflare"
run
assert_eq "module present exits 0" "$RC" 0
assert_contains "module present" "$OUT" "✓ caddy: dns.providers.cloudflare present"
reset; set_backend cache; put caddy_modules "http.handlers.file_server"
run
assert_eq "module missing exits 1" "$RC" 1
assert_contains "module missing names the fix" "$OUT" "✗ caddy: dns.providers.cloudflare missing (fix: make caddy-dns-build)"
reset; set_backend op
run
assert_contains "non-dev host skips the caddy assertion" "$OUT" "not the dev host (backend=op) — skipping caddy assertion"
reset
run
assert_contains "unset backend skips the caddy assertion" "$OUT" "backend=unset"
assert_eq "skips exit 0" "$RC" 0

echo "post-upgrade: tailscale daemon vs installed keg"
ts_setup() {  # $1 = keg version, $2 = daemon line
  : > "$TS/sock"; ln -s "../Cellar/tailscale/$1" "$TS/opt-tailscale"
  printf 'Client: 9.9.9\n%s\n' "$2" > "$ST/ts_version"
}
reset; run
assert_contains "no tailscaled here is a skip" "$OUT" "tailscale: no brew tailscaled here"
reset; ts_setup 1.102.3 "Daemon: 1.102.3-t53a0d659a"; run
assert_eq "matching daemon exits 0" "$RC" 0
assert_contains "build suffix is stripped before comparing" "$OUT" "✓ tailscale: daemon 1.102.3 matches the installed keg"
reset; ts_setup 1.102.3 "Daemon: 1.102.2-tdeadbeef"; run
assert_eq "stale daemon exits 1" "$RC" 1
assert_contains "stale daemon is named" "$OUT" "daemon still runs 1.102.2, 1.102.3 is installed"
reset; ts_setup 1.102.3 "no daemon line here"; run
assert_eq "unreadable daemon version exits 0" "$RC" 0
assert_contains "unreadable daemon version is a skip, not a pass" "$OUT" "version unreadable (installed='1.102.3' daemon='?')"

echo "post-upgrade: colima boot path"
colima_plist() {  # $1 = keepalive, $2 = program
  printf 'Label=sh.brew.colima\nKeepAlive=%s\nProgram0=%s\n' "$1" "$2" > "$HOME/Library/LaunchAgents/sh.brew.colima.plist"
}
reset; run
assert_contains "no colima service is a skip" "$OUT" "colima brew service not registered here"
reset; colima_plist true "$WRAPPER"; run
assert_eq "intact boot path exits 0" "$RC" 0
assert_contains "intact boot path (launchd unreadable tolerated)" "$OUT" "✓ colima: supervised boot path intact"
reset; colima_plist true "$WRAPPER"; put launchctl_print "	program = $WRAPPER"; run
assert_contains "launchd running the wrapper is intact" "$OUT" "✓ colima: supervised boot path intact"
reset; colima_plist true "$WRAPPER"; put launchctl_print "	program = /opt/homebrew/bin/colima"; run
assert_eq "file converged but launchd stale exits 1" "$RC" 1
assert_contains "stale launchd is named" "$OUT" "file converged but launchd still runs '/opt/homebrew/bin/colima'"
reset; colima_plist 'Dict {\n    SuccessfulExit = true\n}' /opt/homebrew/bin/colima; run
assert_eq "reverted boot path exits 1" "$RC" 1
assert_contains "reverted KeepAlive is flattened to one line" "$OUT" "KeepAlive='Dict {     SuccessfulExit = true }'"
assert_contains "reverted boot path names the fix" "$OUT" "(fix: make _colima-supervise)"
reset; colima_plist true /opt/homebrew/bin/colima; run
assert_contains "right KeepAlive, wrong program is still reverted" "$OUT" "boot path reverted by the upgrade"
reset; put services_json '  "loaded": true,'; run
assert_eq "loaded service with no plist exits 1" "$RC" 1
assert_contains "loaded without plist is the disarmed state" "$OUT" "brew service is loaded but has NO plist"
reset; printf 'Label=homebrew.mxcl.colima\nKeepAlive=true\nProgram0=%s\n' "$WRAPPER" > "$HOME/Library/LaunchAgents/homebrew.mxcl.colima.plist"; run
assert_contains "pre-Homebrew-6 plist name is resolved too" "$OUT" "✓ colima: supervised boot path intact"

echo "post-upgrade: tcc-check"
reset; run
assert_contains "tcc-check pass" "$OUT" "✓ tcc: tcc-check still classifies every LaunchAgent program"
reset; touch "$ST/tcc_fail"; run
assert_eq "tcc-check failure exits 1" "$RC" 1
assert_contains "tcc-check output is shown indented" "$OUT" "      program x unclassified"

echo "post-upgrade: op Full Disk Access (present-human machine only)"
OPREAL=$(readlink -f "$BIN/op")
reset; set_backend cache; run
assert_contains "wrong backend skips op assertion" "$OUT" "op: not the present-human machine (backend=cache)"
reset; set_backend op; without_op; run
assert_contains "op not installed is a skip" "$OUT" "op: 1password-cli not installed here"
assert_eq "op not installed exits 0" "$RC" 0
reset; set_backend op; put tcc_rows "2|$OPREAL" "2|/other"; run
assert_eq "FDA granted exits 0" "$RC" 0
assert_contains "FDA granted" "$OUT" "✓ op: Full Disk Access covers $OPREAL"
reset; set_backend op; put tcc_rows "0|$OPREAL" "2|/other"; run
assert_eq "denied row is not a grant: exits 1" "$RC" 1
assert_contains "FDA absent names the path" "$OUT" "✗ op: no Full Disk Access for $OPREAL"
reset; set_backend op; touch "$ST/sqlite_fail"; run
assert_eq "unreadable db is unassertable, not a failure" "$RC" 0
assert_contains "unreadable db message" "$OUT" "TCC db unreadable from here"

echo "concurrent runs"
reset; put outdated_f jq
# a live brew-upgrade holder: a process whose command line names brew-upgrade
printf '#!/bin/sh\nsleep 30\n' > "$TMP/brew-upgrade-fake.sh"
/bin/sh "$TMP/brew-upgrade-fake.sh" & holder=$!
mkdir -p "$(dirname "$LOCK")"; echo "$holder" > "$LOCK"
run
assert_eq "second run refuses: exits 1" "$RC" 1
assert_contains "second run names the holder" "$OUT" "another brew-upgrade is already running (pid $holder"
assert_not_contains "refused run never touches brew" "$(brewlog)" "update"
assert_eq "refused run leaves the holder's lock" "$(cat "$LOCK")" "$holder"
run --dry-run
assert_eq "dry-run ignores the lock" "$RC" 0
pkill -P "$holder" 2>/dev/null; kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
run
assert_eq "dead holder is stale: run proceeds" "$RC" 0
assert_eq "lock released on exit" "$([ -e "$LOCK" ] && echo yes || echo no)" no
sleep 30 & other=$!
echo "$other" > "$LOCK"
run
assert_eq "live pid that is not brew-upgrade is stale (pid reuse)" "$RC" 0
kill "$other" 2>/dev/null; wait "$other" 2>/dev/null
reset; put outdated_f jq; touch "$ST/upgrade_fail"; run
assert_eq "lock released after a failed upgrade" "$([ -e "$LOCK" ] && echo yes || echo no)" no

echo "stalled brew upgrade"
reset; put outdated_f jq; touch "$ST/upgrade_hang"
start=$(date +%s); run; took=$(( $(date +%s) - start ))
assert_eq "stalled upgrade exits 1" "$RC" 1
assert_contains "stall is reported" "$OUT" "brew upgrade stalled"
assert_contains "pending CLT update is named" "$OUT" "Command Line Tools update"
assert_contains "brew output is still shown" "$OUT" "newer Command Line Tools release"
[ "$took" -lt 30 ] && ok "watchdog fires well before the 60 s hang ($took s)" || bad "watchdog too slow ($took s)"
assert_eq "stalled run writes no stamp" "$([ -e "$BREW_UPGRADE_STAMP" ] && echo yes || echo no)" no
assert_eq "lock released after a stall" "$([ -e "$LOCK" ] && echo yes || echo no)" no
assert_eq "no hung brew child left behind" "$(pgrep -f "$BIN/brew upgrade" | wc -l | tr -d ' ')" 0
reset; put outdated_f jq; touch "$ST/upgrade_hang"
mkdir -p "$HOMEBREW_LOGS"; ( while :; do : > "$HOMEBREW_LOGS/jq.log"; sleep 0.3; done ) & feeder=$!
start=$(date +%s); RC=0; OUT=$(BREW_UPGRADE_IDLE_SECS=3 timeout 8 /bin/bash "$SB/scripts/brew-upgrade.sh" 2>&1) || RC=$?
kill "$feeder" 2>/dev/null; wait "$feeder" 2>/dev/null; pkill -P $$ -x sleep 2>/dev/null
assert_not_contains "fresh Homebrew build-log writes keep the run alive" "$OUT" "brew upgrade stalled"
rm -rf "$HOMEBREW_LOGS"

echo "unit: fixup_for / in_array / tcc_allows (extracted verbatim)"
for fn in fixup_for in_array tcc_allows; do
  eval "$(awk -v f="$fn() {" 'index($0, f) == 1 { p = 1 } p { print } p && /^}/ { exit }' "$SRC")"
done
assert_eq "fixup_for caddy" "$(fixup_for caddy)" "make caddy-dns-build"
assert_eq "fixup_for unknown is empty" "$(fixup_for tailscale)" ""
in_array b a b c && ok "in_array finds a member" || bad "in_array finds a member"
in_array z a b c && bad "in_array rejects a non-member" || ok "in_array rejects a non-member"
in_array a && bad "in_array on an empty haystack" || ok "in_array on an empty haystack is false"
in_array oven-sh/bun/bun bun && bad "in_array matches whole elements" || ok "in_array matches whole elements (no basename match)"
reset
put tcc_rows "2|/a/op" "5|/b/op"
tcc_allows db svc /a/op; assert_eq "tcc_allows granted -> 0" "$?" 0
tcc_allows db svc /b/op; assert_eq "tcc_allows auth_value 5 is not granted -> 1" "$?" 1
tcc_allows db svc /c/op; assert_eq "tcc_allows absent -> 1" "$?" 1
touch "$ST/sqlite_fail"
tcc_allows db svc /a/op; assert_eq "tcc_allows unreadable -> 2" "$?" 2

echo
if [ "$fails" -eq 0 ]; then echo "brew-upgrade: all passed"; else echo "brew-upgrade: $fails failed"; exit 1; fi
