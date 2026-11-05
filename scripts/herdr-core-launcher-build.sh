#!/usr/bin/env bash
set -u -o pipefail
# herdr-core-launcher-build — build + sign the launcher: the Full Disk Access umbrella for LaunchAgent programs that
# call `op` (opbackup; docs/tcc.md pattern "Launcher"). It is not the herdr-core's program any more (the core is Herdr
# Core.app); the name and path are kept because the grant is keyed on them. Never rebuilt casually: `make opbackup-setup` runs it.
# Signature: ad-hoc, with the fixed identifier AND an explicit designated requirement
#   designated => identifier "com.jkrumm.herdr-core-launcher"
# so the code requirement TCC stores no longer carries the cdhash and survives a rebuild. A self-signed
# certificate would add a certificate leaf to it, but macOS refuses to sign with an untrusted identity
# (CSSMERR_TP_NOT_TRUSTED) and trusting one needs a GUI authorization: not available headless.
#
# Rebuilds when the source hash OR the signing mode changes (both sit in the .src-sha marker). The swap
# into place never happens silently when the requirement changes: the Full Disk Access re-grant is queued
# with ask-human first (an unchanged requirement keeps the grant, no ask).
# Env: LAUNCHER_BIN (required), DOTFILES_DIR, ASK_HUMAN (default: ask-human on PATH).
# BASH 3.2.

DOTFILES_DIR="${DOTFILES_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BIN="${LAUNCHER_BIN:?LAUNCHER_BIN required}"
ASK="${ASK_HUMAN:-ask-human}"
SRC="$DOTFILES_DIR/scripts/herdr-core-launcher.c"
IDENT="com.jkrumm.herdr-core-launcher"
SIGN_MODE="adhoc-dr1"
DR="designated => identifier \"$IDENT\""

dr_of() { codesign -dr- "$1" 2>/dev/null | sed -n 's/^# designated => //p; s/^designated => //p' | head -1; }

marker="$(shasum -a 256 "$SRC" | cut -d' ' -f1) $SIGN_MODE"
if [ -x "$BIN" ] && [ "$(cat "$BIN.src-sha" 2>/dev/null)" = "$marker" ]; then
  echo "    · herdr-core-launcher (up to date)"; exit 0
fi

mkdir -p "$(dirname "$BIN")"
NEW="$BIN.new.$$"   # unique per invocation; removed on every exit path (a successful mv leaves nothing)
trap 'rm -f "$NEW"' EXIT
{ cc -O2 -Wall -o "$NEW" "$SRC" && codesign -f -s - --identifier "$IDENT" -r="$DR" "$NEW" 2>/dev/null; } \
  || { echo "    ✗ launcher build failed"; exit 1; }

install_new() {
  mv "$NEW" "$BIN" && echo "$marker" > "$BIN.src-sha" \
    || { echo "    ✗ could not install the launcher at $BIN (mv or marker write failed)"; exit 1; }
}

new_dr=$(dr_of "$NEW")
if [ -x "$BIN" ] && [ -n "$new_dr" ] && [ "$(dr_of "$BIN")" = "$new_dr" ]; then
  install_new
  echo "    ✓ herdr-core-launcher rebuilt — same code requirement ($new_dr): the Full Disk Access grant holds; run make tcc-probe"
  exit 0
fi

# New code requirement (first build, or the cdhash-bound ad-hoc launcher being migrated): a re-grant is due.
msg="herdr-core launcher was rebuilt/re-signed and needs a one-time Full Disk Access grant on THIS machine: System Settings > Privacy & Security > Full Disk Access > add $BIN. Afterwards, in a fresh terminal: make tcc-probe (docs/tcc.md)."
if ! "$ASK" ask "$msg" >/dev/null 2>&1 && ! "$ASK" ask "$msg" --no-push >/dev/null 2>&1; then
  echo "    ✗ launcher needs a new Full Disk Access grant and the re-grant could not be queued ($ASK ask failed): not swapped in. Fix ask-human, re-run"
  exit 1
fi
install_new
echo "    ✓ herdr-core-launcher built (${new_dr:-no requirement}) — NEW code requirement: Full Disk Access re-grant queued with ask-human for $BIN; then make tcc-probe (docs/tcc.md)"
