#!/usr/bin/env bash
# brew-service.test — proves scripts/lib/brew-service.sh against a SCRATCH dir.
#
# Runs on either Mac and touches nothing real: BREW_SERVICE_GUI_DIR /
# BREW_SERVICE_SYSTEM_DIR exist so the resolver can be driven over fabricated
# plists instead of a live boot path. That matters more than usual here — the
# thing under test decides which file `_colima-supervise` rewrites, so a test
# that used the real LaunchAgents dir could disarm the machine it is checking.
#
# The three facts worth asserting are the three that broke: NEW name wins when
# both exist (a stale old file must not shadow what launchd actually loaded),
# the OLD name still resolves (the mini has not restarted anything since the
# Homebrew 6 rename), and "neither" is a distinguishable FAILURE rather than an
# empty string a caller can mistake for "not installed here, fine".
set -u

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/brew-service.sh"
[ -f "$LIB" ] || { echo "✗ $LIB not found"; exit 1; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/brew-service-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/agents" "$TMP/daemons"

export BREW_SERVICE_GUI_DIR="$TMP/agents"
export BREW_SERVICE_SYSTEM_DIR="$TMP/daemons"

fails=0
ok()   { echo "  ✓ $1"; }
bad()  { echo "  ✗ $1"; fails=$((fails + 1)); }
is()   { [ "$2" = "$3" ] && ok "$1" || bad "$1 — got '$2', want '$3'"; }

plist_with_label() {
  printf '%s\n' \
    '<?xml version="1.0" encoding="UTF-8"?>' \
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
    '<plist version="1.0"><dict><key>Label</key><string>'"$2"'</string></dict></plist>' > "$1"
}

plist_with_label "$TMP/agents/sh.brew.both.plist"        sh.brew.both
plist_with_label "$TMP/agents/homebrew.mxcl.both.plist"  homebrew.mxcl.both
plist_with_label "$TMP/agents/homebrew.mxcl.old.plist"   homebrew.mxcl.old
plist_with_label "$TMP/daemons/homebrew.mxcl.caddy.plist" homebrew.mxcl.caddy
# No :Label key at all — the basename fallback must still name something usable.
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
  '<plist version="1.0"><dict></dict></plist>' > "$TMP/agents/sh.brew.nolabel.plist"

echo "brew-service resolver"

is "both names present → prefers sh.brew" \
  "$(bash "$LIB" plist both)" "$TMP/agents/sh.brew.both.plist"
is "old name only → still resolves" \
  "$(bash "$LIB" plist old)" "$TMP/agents/homebrew.mxcl.old.plist"

out=$(bash "$LIB" plist absent 2>/dev/null); rc=$?
[ "$rc" = "1" ] && [ -z "$out" ] \
  && ok "neither name → exit 1, no output" \
  || bad "neither name → got rc=$rc out='$out', want rc=1 and empty"

is "label read from the file"        "$(bash "$LIB" label both)" "sh.brew.both"
is "label of an old-name service"    "$(bash "$LIB" label old)"  "homebrew.mxcl.old"
is "label falls back to basename"    "$(bash "$LIB" label nolabel)" "sh.brew.nolabel"

bash "$LIB" label absent >/dev/null 2>&1
is "label of an unresolvable service exits 1" "$?" "1"

is "launchctl target (gui)" \
  "$(bash "$LIB" target both)" "gui/$(/usr/bin/id -u)/sh.brew.both"
is "launchctl target (system)" \
  "$(bash "$LIB" target caddy system)" "system/homebrew.mxcl.caddy"
is "system domain resolves in LaunchDaemons" \
  "$(bash "$LIB" plist caddy system)" "$TMP/daemons/homebrew.mxcl.caddy.plist"

# expected-plist is what brew would write NEXT — never a lookup, so it answers
# for a service with no file at all and always names the new form.
is "expected is always the new name" \
  "$(bash "$LIB" expected old)" "$TMP/agents/sh.brew.old.plist"
is "expected answers for an absent service" \
  "$(bash "$LIB" expected absent)" "$TMP/agents/sh.brew.absent.plist"

bash "$LIB" plist both bogus >/dev/null 2>&1
is "unknown domain is a usage error (rc 2)" "$?" "2"
bash "$LIB" >/dev/null 2>&1
is "no verb is a usage error (rc 2)" "$?" "2"

# Sourcing must not mutate the caller: no `set -e`, no cd, no stray output.
sourced=$(bash -c 'set -u; source "$1"; echo "$(brew_service_plist both)"' _ "$LIB")
is "sourceable with no side effects" "$sourced" "$TMP/agents/sh.brew.both.plist"

echo ""
[ "$fails" = "0" ] && { echo "✓ brew-service: all assertions passed"; exit 0; }
echo "✗ brew-service: $fails assertion(s) failed"; exit 1
