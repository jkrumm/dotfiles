#!/usr/bin/env bash
# drift-check.test — hermetic regression suite for scripts/drift-check.sh.
#
# Runs the real script from a SANDBOX COPY (scripts/ + lib/) whose host-absolute
# paths (the brew tailscaled, the app bundle, /usr/bin/ssh and /usr/bin/curl) are
# rewritten to scratch stubs; the script under test is not modified. git, brew,
# defaults, pmset, sysadminctl and date are injected through the script's own
# *_BIN variables; HOME, state dir and Makefile are scratch. Time is a stub
# (NOW is fixed), so the age-grace maths is exact and nothing reads the clock.
#
# Asserted: the drift / skipped / info classification per check, the 14-day
# grace boundary (>= is stale, keyed on the component, resolved entries
# dropped), and the Kuma push the run ends in: status up|down, the exact
# summary msg, and the exit code (a failed push fails the run too).
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/drift-check.sh"
[ -f "$SRC" ] || { echo "✗ $SRC not found"; exit 1; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/drift-check-test.XXXXXX") || exit 1
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

ST="$TMP/st"; BIN="$TMP/bin"; SB="$TMP/sandbox"; TS="$TMP/ts"
export ST
mkdir -p "$BIN" "$SB/scripts/lib" "$TS"
NOW=1800000000
DAY=86400

# Sandbox copy of the script and its libs, host paths -> scratch.
rewrite() {
  sed -e "s|-S /var/run/tailscaled.socket|-f $TS/sock|g" \
      -e "s|/var/run/tailscaled.socket|$TS/sock|g" \
      -e "s|/opt/homebrew/bin/tailscale|$TS/tailscale|g" \
      -e "s|/Applications/Tailscale.app/Contents/MacOS/Tailscale|$TS/app|g" \
      -e "s|/usr/bin/ssh|$BIN/ssh|g" \
      -e "s|/usr/bin/curl|$BIN/curl|g" \
      "$1" > "$2"
}
rewrite "$SRC" "$SB/scripts/drift-check.sh"
for l in kuma-push github-tags tailscale-cli; do rewrite "$HERE/lib/$l.sh" "$SB/scripts/lib/$l.sh"; done

cat > "$BIN/date" <<EOF
#!/bin/sh
if [ "\$1" = "-u" ]; then echo $NOW; else echo "2027-01-15 08:00"; fi
EOF
cat > "$BIN/git" <<'EOF'
#!/bin/sh
# git ls-remote --tags https://github.com/<owner>/<repo>
f="$ST/tags/$(echo "${3#https://github.com/}" | tr / _)"
[ -f "$ST/git_fail" ] && exit 128
[ -f "$f" ] || exit 128
cat "$f"
EOF
cat > "$BIN/brew" <<'EOF'
#!/bin/sh
[ -f "$ST/brew_fail" ] && exit 1
if [ "$2" = "--cask" ]; then cat "$ST/brew_casks"; else cat "$ST/brew_outdated"; fi
EOF
cat > "$BIN/defaults" <<'EOF'
#!/bin/sh
[ -f "$ST/defaults_none" ] && exit 1
cat "$ST/defaults_out"
EOF
cat > "$BIN/pmset" <<'EOF'
#!/bin/sh
[ -f "$ST/pmset_fail" ] && exit 1
cat "$ST/pmset_out"
EOF
cat > "$BIN/sysadminctl" <<'EOF'
#!/bin/sh
cat "$ST/autologin_out"
EOF
cat > "$TS/tailscale" <<'EOF'
#!/bin/sh
case "$*" in
  *--daemon*) if [ -f "$ST/ts_daemon" ]; then cat "$ST/ts_daemon"; fi ;;
  *) cat "$ST/ts_plain" ;;
esac
EOF
# curl: the release-feed lookup, or the Kuma push (recorded one arg per line).
cat > "$BIN/curl" <<'EOF'
#!/bin/sh
case "$*" in
  *mode=json*)
    [ -f "$ST/ts_feed_fail" ] && exit 22
    cat "$ST/ts_feed" ;;
  *)
    [ -f "$ST/push_fail" ] && exit 22
    for a in "$@"; do printf '%s\n' "$a"; done > "$ST/push.log" ;;
esac
EOF
cat > "$BIN/ssh" <<'EOF'
#!/bin/sh
# ssh -o .. -o .. <host> '<cmd>'
cat "$ST/ssh_$5"
EOF
chmod +x "$BIN"/* "$TS/tailscale"

export HOME="$TMP/home"
export PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin"
unset TAILSCALE_BIN TAILSCALE_SOCKET DRIFT_PUSH_URL
export DOTFILES_DIR="$TMP/dotfiles"
export DRIFT_MAKEFILE="$TMP/Makefile"
export GIT_BIN="$BIN/git" BREW_BIN="$BIN/brew" DATE_BIN="$BIN/date"
export DEFAULTS_BIN="$BIN/defaults" PMSET_BIN="$BIN/pmset" SYSADMINCTL_BIN="$BIN/sysadminctl"
PYTHON_BIN=$(command -v python3); export PYTHON_BIN
export DRIFT_STATE_DIR="$TMP/state" BREW_UPGRADE_STAMP="$TMP/brew-stamp"
export DRIFT_PUSH_URL_FILE="$TMP/push-url" BACKEND_FILE="$TMP/backend"

COLLIE_SHA=aaaaaaa1111111111111111111111111111111aa
touch_age() {  # $1 file, $2 age in days relative to NOW
  python3 -c 'import os,sys; t=int(sys.argv[2]); os.utime(sys.argv[1], (t, t))' "$1" $((NOW - $2 * DAY))
}
tags() {  # $1 owner_repo, then lines
  local f=$1; shift; printf '%s\n' "$@" > "$ST/tags/$f"
}

# reset (ts_current is defined below, called at run time): everything current, push configured, not the dev host.
reset() {
  rm -rf "$ST" "$HOME" "$DRIFT_STATE_DIR" "$BREW_UPGRADE_STAMP" "$TS/sock" "$TS/app" "$BACKEND_FILE"
  mkdir -p "$ST/tags" "$HOME" "$DRIFT_STATE_DIR"
  printf 'COLLIE_REF := %s\nXCADDY_VERSION ?= v0.4.2 # c\nCADDY_DNS_MODULE_VERSION = v0.0.3\n' "$COLLIE_SHA" > "$DRIFT_MAKEFILE"
  tags AltanS_collie "1111111111111111111111111111111111111111	refs/tags/v0.21.0" \
    "2222222222222222222222222222222222222222	refs/tags/v0.22.0" \
    "$COLLIE_SHA	refs/tags/v0.22.0^{}" \
    "3333333333333333333333333333333333333333	refs/tags/v0.23.0-rc1"
  tags caddyserver_xcaddy "4444444444444444444444444444444444444444	refs/tags/v0.4.1" \
    "5555555555555555555555555555555555555555	refs/tags/v0.4.2"
  tags caddy-dns_cloudflare "6666666666666666666666666666666666666666	refs/tags/v0.0.3"
  printf 'a\nb\n' > "$ST/brew_outdated"; printf 'c\n' > "$ST/brew_casks"
  : > "$BREW_UPGRADE_STAMP"; touch_age "$BREW_UPGRADE_STAMP" 1
  touch "$ST/defaults_none"
  : > "$ST/pmset_out"; : > "$ST/autologin_out"; : > "$ST/ts_plain"; : > "$ST/ts_feed"
  echo "https://kuma.example.com/api/push/abc" > "$DRIFT_PUSH_URL_FILE"
  ts_current
}
# Dev-host tailscale in the brew variant, all three nodes current.
ts_current() {
  : > "$TS/sock"
  printf 'Client: 1.102.3\nDaemon: 1.102.3-t53a0d659a\n' > "$ST/ts_daemon"
  printf '{"TarballsVersion":"1.102.3"}\n' > "$ST/ts_feed"
  printf 'Client: 1.102.3\nDaemon: 1.102.3\n' > "$ST/ssh_homelab"
  printf 'Client: 1.102.3\nDaemon: 1.102.3\n' > "$ST/ssh_vps"
}
first_seen() {  # lines "key<TAB>days-ago"
  local line
  : > "$DRIFT_STATE_DIR/first-seen"
  for line in "$@"; do
    printf '%s\t%s\n' "${line%%:*}" $((NOW - ${line##*:} * DAY)) >> "$DRIFT_STATE_DIR/first-seen"
  done
}

OUT=""; RC=0
run() { RC=0; OUT=$(/bin/bash "$SB/scripts/drift-check.sh" "$@" 2>&1) || RC=$?; }
push_status() { sed -n 's/^status=//p' "$ST/push.log" 2>/dev/null; }
push_msg()    { sed -n 's/^msg=//p' "$ST/push.log" 2>/dev/null; }
pushed()      { [ -f "$ST/push.log" ] && echo yes || echo no; }

echo "usage"
reset; run --bogus
assert_eq "unknown flag exits 1" "$RC" 1
assert_contains "usage printed" "$OUT" "usage: drift-check.sh [--no-push]"

echo "everything current"
reset; run
assert_eq "exit 0" "$RC" 0
assert_eq "push status up" "$(push_status)" up
assert_eq "summary" "$(push_msg)" "everything current"
assert_contains "pinned commit peeled from the annotated tag" "$OUT" "· collie current (v0.22.0)"
assert_contains "version pins compared by tag" "$OUT" "· xcaddy current (v0.4.2)"
assert_contains "prerelease tags are ignored" "$OUT" "· caddy-dns current (v0.0.3)"
assert_contains "brew counts ride along" "$OUT" "· brew: 2 outdated (1 cask)"
assert_contains "brew-upgrade age is info" "$OUT" "· brew-upgrade 1d ago"
assert_contains "no pending macOS update" "$OUT" "· macOS: no pending updates"

echo "pinned commit / version drift and the grace clock"
reset; printf 'COLLIE_REF := bbbbbbb2222222222222222222222222222222bb\nXCADDY_VERSION = v0.4.1\nCADDY_DNS_MODULE_VERSION = v0.0.3\n' > "$DRIFT_MAKEFILE"
run
assert_eq "fresh drift does not page: exit 0" "$RC" 0
assert_eq "fresh drift pushes up" "$(push_status)" up
assert_contains "commit drift names latest tag, short pin and fix" "$(push_msg)" "drifting: collie → v0.22.0 (pin bbbbbbb, fix: bump COLLIE_REF + COLLIE_VERSION, then make collie-setup) [0d]"
assert_contains "version drift names pin -> latest" "$(push_msg)" "xcaddy v0.4.1 → v0.4.2 (fix: bump XCADDY_VERSION, then make caddy-dns-build) [0d]"
assert_not_contains "no STALE section yet" "$(push_msg)" "STALE"
assert_contains "first-seen records the component at NOW" "$(cat "$DRIFT_STATE_DIR/first-seen")" "collie	$NOW"

first_seen collie:13 xcaddy:14 gone:99
run
assert_eq "13d is still inside the grace" "$(printf '%s' "$(push_msg)" | grep -c 'drifting: collie')" 1
assert_contains "14d is stale (>=)" "$(push_msg)" "STALE: xcaddy v0.4.1 → v0.4.2 (fix: bump XCADDY_VERSION, then make caddy-dns-build) [14d]"
assert_eq "one stale entry pages: status down" "$(push_status)" down
assert_eq "one stale entry: exit 1" "$RC" 1
assert_contains "stale and fresh are joined with ' | '" "$(push_msg)" "[14d] | drifting: collie"
assert_contains "terminal report marks stale with ✗" "$OUT" "✗ xcaddy v0.4.1"
assert_contains "clock survives across runs, keyed on component" "$(cat "$DRIFT_STATE_DIR/first-seen")" "collie	$((NOW - 13 * DAY))"
assert_not_contains "resolved/unknown keys are dropped from first-seen" "$(cat "$DRIFT_STATE_DIR/first-seen")" "gone"

first_seen collie:20 xcaddy:15
run
assert_contains "several stale entries are joined with '; '" "$(push_msg)" "[20d]; xcaddy"

echo "skips never page"
reset; touch "$ST/git_fail"; run
assert_eq "github down: exit 0" "$RC" 0
assert_eq "github down: push up" "$(push_status)" up
assert_eq "github down: every pin skipped" "$(push_msg)" "skipped: collie (github unreachable); xcaddy (github unreachable); caddy-dns (github unreachable)"
reset; printf 'XCADDY_VERSION = v0.4.2\n' > "$DRIFT_MAKEFILE"; run
assert_contains "unreadable pin is skipped, not drifted" "$(push_msg)" "collie (pin unreadable in Makefile)"
reset; tags caddy-dns_cloudflare "6666666666666666666666666666666666666666	refs/tags/v0.1.0-rc1"; run
assert_contains "only-prerelease tags: skipped, never drift" "$(push_msg)" "skipped: caddy-dns ("

echo "brew"
reset; BREW_BIN="$TMP/nope" run; BREW_BIN="$BIN/brew"
assert_contains "brew missing is skipped" "$(push_msg)" "brew (not installed)"
reset; touch "$ST/brew_fail"; run
assert_contains "brew outdated failure is skipped" "$(push_msg)" "brew (outdated query failed)"
reset; rm -f "$BREW_UPGRADE_STAMP"; run
assert_contains "never-run upgrader is drift" "$(push_msg)" "drifting: brew-upgrade has never run (fix: make brew-upgrade)"
assert_eq "never-run is fresh at first sight: up" "$(push_status)" up
reset; touch_age "$BREW_UPGRADE_STAMP" 30; run
assert_contains "age == max is still fine" "$OUT" "· brew-upgrade 30d ago"
assert_eq "age == max is current" "$(push_msg)" "everything current"
reset; touch_age "$BREW_UPGRADE_STAMP" 31; run
assert_contains "age > max is drift" "$(push_msg)" "brew-upgrade 31d ago (max 30d, fix: make brew-upgrade)"
reset; touch_age "$BREW_UPGRADE_STAMP" 31; BREW_UPGRADE_MAX_AGE_DAYS=60 run
assert_eq "max age is overridable" "$(push_msg)" "everything current"
reset; touch_age "$BREW_UPGRADE_STAMP" 31; first_seen brew-upgrade:16; run
assert_eq "stale brew-upgrade pages" "$(push_status)" down

echo "macOS"
reset; rm "$ST/defaults_none"
cat > "$ST/defaults_out" <<'EOF'
(
        {
        "Display Name" = "macOS Tahoe 26.6.1";
        Identifier = "MSU_UPDATE_26.6.1_patch";
    },
        {
        "Display Name" = "macOS Tahoe 27";
        Identifier = "MSU_UPDATE_27_major";
    }
)
EOF
run
assert_eq "pending patch is drift, up while fresh" "$(push_status)" up
assert_eq "major is held by policy, patch is flagged" "$(push_msg)" "drifting: macOS update pending: macOS Tahoe 26.6.1 (needs a restart window) [0d]"
assert_contains "major is reported as info only" "$OUT" "macOS major available, held by policy: macOS Tahoe 27"
reset; rm "$ST/defaults_none"
printf '(\n  {\n  "Display Name" = "macOS Tahoe 27";\n  Identifier = "MSU_UPDATE_27_major";\n },\n)\n' > "$ST/defaults_out"; run
assert_eq "a major alone never drifts" "$(push_msg)" "everything current"

echo "tailscale"
reset; rm "$TS/sock"; run
assert_contains "no CLI is skipped" "$(push_msg)" "tailscale (no CLI found)"
reset; run
assert_eq "all nodes current" "$(push_msg)" "everything current"
assert_contains "build suffix stripped, brew variant named" "$OUT" "tailscale current (daemon 1.102.3, tailscaled (brew, open source))"
reset; ts_current; printf 'Client: 1.102.3\nDaemon: 1.100.0-tdead\n' > "$ST/ts_daemon"; run
assert_contains "stale daemon is drift, measured on the DAEMON not the CLI" "$(push_msg)" "tailscale daemon 1.100.0 → 1.102.3 (fix, from the MacBook: make tailscale-upgrade HOST=mini)"
reset; ts_current; rm "$ST/ts_daemon"; printf '1.102.3 \n  other\n' > "$ST/ts_plain"; run
assert_contains "old CLI without --daemon falls back to line 1" "$OUT" "tailscale current (daemon 1.102.3"
reset; ts_current; rm "$ST/ts_daemon"; : > "$ST/ts_plain"; run
assert_contains "unreadable version is skipped" "$(push_msg)" "tailscale (running version unreadable)"
reset; ts_current; touch "$ST/ts_feed_fail"; run
assert_contains "feed unreachable is skipped" "$(push_msg)" "tailscale (pkgs.tailscale.com unreachable)"
reset; ts_current; printf 'Daemon: 1.099.0\n' > "$ST/ssh_homelab"; printf "no daemon line\n" > "$ST/ssh_vps"; run
assert_contains "server behind is its own drift key" "$(push_msg)" "tailscale on homelab 1.099.0 → 1.102.3 (fix, from the MacBook: make tailscale-upgrade HOST=homelab)"
assert_contains "server answering without a Daemon line is skipped, not drift" "$(push_msg)" "tailscale on vps (unreachable)"
reset; rm "$TS/sock"; printf 'Client: 1.50.0\nDaemon: 1.50.0\n' > "$ST/ts_daemon"; cp "$TS/tailscale" "$TS/app"; run
assert_contains "app bundle is reported and left alone" "$OUT" "tailscale 1.50.0 (app bundle (App Store or standalone) — updates via the App Store)"
assert_eq "app bundle never drifts or consults the feed" "$(push_msg)" "everything current"

echo "power posture (dev host only)"
reset; printf 'cache\n' > "$BACKEND_FILE"
printf 'AC Power:\n autorestart 1\n sleep 0\n' > "$ST/pmset_out"
printf 'Automatic login user: dev\n' > "$ST/autologin_out"; run
assert_eq "both on" "$(push_msg)" "everything current"
assert_contains "autorestart on is info" "$OUT" "· autorestart on"
assert_contains "autologin on is info" "$OUT" "· autologin on"
reset; printf 'cache\n' > "$BACKEND_FILE"
printf 'AC Power:\n autorestart 0\n' > "$ST/pmset_out"
printf 'Automatic login is off\n' > "$ST/autologin_out"; run
assert_contains "autorestart off is drift" "$(push_msg)" "pmset autorestart is 0, the mini will not power itself on after a power cut (fix: sudo pmset -a autorestart 1)"
assert_contains "autologin off is drift" "$(push_msg)" "automatic login is off, a reboot leaves the mini at the login window (fix: make lock-at-boot-setup)"
reset; printf 'cache\n' > "$BACKEND_FILE"; touch "$ST/pmset_fail"; run
assert_contains "pmset unreadable is skipped" "$(push_msg)" "autorestart (pmset unreadable)"
assert_contains "sysadminctl unreadable is skipped" "$(push_msg)" "autologin (sysadminctl unreadable)"
reset; printf 'op\n' > "$BACKEND_FILE"; printf 'autorestart 0\n' > "$ST/pmset_out"; run
assert_eq "non-dev backend ignores power posture entirely" "$(push_msg)" "everything current"
reset; printf 'autorestart 0\n' > "$ST/pmset_out"; run
assert_eq "no backend file ignores power posture" "$(push_msg)" "everything current"

echo "push contract"
reset; run --no-push
assert_eq "--no-push does not push" "$(pushed)" no
assert_eq "--no-push still exits 0 when clean" "$RC" 0
assert_contains "--no-push still reports" "$OUT" "drift-check (2027-01-15 08:00)"
reset; touch "$ST/git_fail"; first_seen collie:30; run --no-push
assert_eq "--no-push with only skips exits 0" "$RC" 0
reset; printf 'COLLIE_REF = bbbbbbb\nXCADDY_VERSION = v0.4.2\nCADDY_DNS_MODULE_VERSION = v0.0.3\n' > "$DRIFT_MAKEFILE"; first_seen collie:30; run --no-push
assert_eq "--no-push with stale drift exits 1" "$RC" 1
reset; rm "$DRIFT_PUSH_URL_FILE"; run
assert_eq "no push URL file: no push" "$(pushed)" no
assert_eq "no push URL file: exit 0 (unwired machine)" "$RC" 0
reset; rm "$DRIFT_PUSH_URL_FILE"; DRIFT_PUSH_URL="https://kuma.example.com/api/push/env" run
assert_eq "URL from env without a file: no push (file gates it)" "$(pushed)" no
reset; DRIFT_PUSH_URL="https://kuma.example.com/api/push/env" run
assert_contains "env URL wins over the file" "$(cat "$ST/push.log")" "https://kuma.example.com/api/push/env"
reset; touch "$ST/push_fail"; run
assert_eq "failed push fails the run even when clean" "$RC" 1

echo
if [ "$fails" -eq 0 ]; then echo "drift-check: all passed"; else echo "drift-check: $fails failed"; exit 1; fi
