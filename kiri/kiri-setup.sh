#!/usr/bin/env bash
# kiri-setup — install, run, report on or remove the kiri trial (docs/kiri-trial.md).
#
#   kiri-setup.sh install    pinned release → sha256 → signature, team, notarization → ~/.local/share/kiri
#   kiri-setup.sh up         docker context `kiri`, render com.jkrumm.kiri, bootstrap it, wait for the socket
#   kiri-setup.sh down       boot the agent out (the daemon stops, its VM goes with it); files stay
#   kiri-setup.sh status     agent, daemon and VM processes, socket
#   kiri-setup.sh teardown   down, then remove the context, the install, ~/.kiri and the plist
#
# NEVER `kiri setup`: it appends to the shell profiles (here symlinks into this repo), edits
# ~/.docker/config.json, links /usr/local/bin/kiri and, with its default flags, asks for an
# administrator. We write the one docker context it would, and the LaunchAgent, ourselves. The Kiri
# UI is never started: it is the only code that checks for and installs updates.
#
# Env (set by the Makefile, the single pin): KIRI_VERSION KIRI_SHA256 KIRI_TEAM KIRI_MEMORY_MIB KIRI_IDLE_SECS
set -euo pipefail

DOTFILES_DIR="${DOTFILES_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LABEL="${KIRI_LABEL:-com.jkrumm.kiri}"
HOME_DIR="${KIRI_HOME:-$HOME/.local/share/kiri}"
STATE_DIR="$HOME/.kiri"
SOCKET="$STATE_DIR/run/docker.sock"
LOG="${KIRI_LOG:-$HOME/Library/Logs/kiri}"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
TEMPLATE="$DOTFILES_DIR/kiri/com.jkrumm.kiri.plist.template"
VERSION="${KIRI_VERSION:?KIRI_VERSION unset (run through make)}"
APP="$HOME_DIR/$VERSION/Kiri.app"

die() { echo "  ✗ $*" >&2; exit 1; }
note() { echo "    $*"; }

dev_host_gate() {
  [ "$(tr -d '[:space:]' < "$HOME/.config/secrets/backend" 2>/dev/null || true)" = "cache" ] \
    || { echo "    · not the dev host — kiri skipped"; exit 0; }
}

loaded() { launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; }

install() {
  dev_host_gate
  if [ -x "$APP/Contents/MacOS/kiri" ]; then note "v$VERSION already installed at $APP"; return 0; fi
  local sha="${KIRI_SHA256:?}" team="${KIRI_TEAM:?}" tmp
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/kiri-dl.XXXXXX")
  gh release download "v$VERSION" -R libracoder/kiri -p "Kiri-$VERSION-arm64.tar.gz" -D "$tmp" \
    || die "download failed"
  [ "$(shasum -a 256 "$tmp/Kiri-$VERSION-arm64.tar.gz" | cut -d' ' -f1)" = "$sha" ] || die "sha256 differs from the pin"
  mkdir "$tmp/x" && tar -xzf "$tmp/Kiri-$VERSION-arm64.tar.gz" -C "$tmp/x"
  local app="$tmp/x/Kiri.app"
  codesign --verify --deep --strict "$app" || die "signature does not verify"
  # Capture first: `grep -q` closing the pipe early fails the producer under pipefail.
  local out
  out=$(codesign -dv "$app" 2>&1 || true)
  [[ "$out" == *"TeamIdentifier=$team"* ]] || die "team id is not $team"
  out=$(spctl -a -vv -t exec "$app" 2>&1 || true)
  [[ "$out" == *"source=Notarized Developer ID"* ]] || die "Gatekeeper does not accept it: $out"
  xcrun stapler validate "$app" >/dev/null 2>&1 || die "no stapled notarization ticket"
  mkdir -p "$HOME_DIR/$VERSION"
  cp -R "$app" "$HOME_DIR/$VERSION/Kiri.app"
  rm -rf "$tmp"
  note "✓ installed v$VERSION (sha256, signature, team $team, notarized and stapled all checked)"
}

up() {
  dev_host_gate
  [ -x "$APP/Contents/MacOS/kiri" ] || die "not installed: make kiri-install"
  if ! docker context inspect kiri >/dev/null 2>&1; then
    docker context create kiri --description "kiri trial" --docker "host=unix://$SOCKET" >/dev/null
    note "✓ docker context kiri → $SOCKET"
  fi
  mkdir -p "$HOME/Library/LaunchAgents" "$(dirname "$LOG")"
  sed -e "s|__LABEL__|$LABEL|g" -e "s|__APP__|$APP|g" -e "s|__HOME__|$HOME|g" \
      -e "s|__MEMORY_MIB__|${KIRI_MEMORY_MIB:-2048}|g" -e "s|__IDLE_SECS__|${KIRI_IDLE_SECS:-60}|g" \
      -e "s|__LOG__|$LOG|g" "$TEMPLATE" > "$PLIST"
  plutil -lint "$PLIST" >/dev/null || die "rendered plist is invalid"
  down
  # bootout returns before launchd has let the old job go: retry the bootstrap until it takes.
  for _ in $(seq 1 15); do launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null && break; /bin/sleep 1; done
  loaded || die "bootstrap of $LABEL failed"
  for _ in $(seq 1 30); do docker --context kiri ps >/dev/null 2>&1 && break; /bin/sleep 1; done
  docker --context kiri ps >/dev/null 2>&1 || die "the daemon does not answer on $SOCKET after 30 s (log: $LOG.err.log)"
  note "✓ $LABEL up, answering on $SOCKET"
}

down() {
  if loaded; then
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null
    for _ in $(seq 1 30); do loaded || break; /bin/sleep 1; done
    note "✓ $LABEL booted out"
  else
    note "· $LABEL not loaded"
  fi
}

# The 48-hour reading: a second, interval agent that appends one footprint/health line every 15 min.
SAMPLE_LABEL="$LABEL-sample"
SAMPLE_PLIST="$HOME/Library/LaunchAgents/$SAMPLE_LABEL.plist"

sample_on() {
  dev_host_gate
  mkdir -p "$HOME_DIR" "$HOME/.local/state/kiri-trial"
  cp "$DOTFILES_DIR/kiri/kiri-trial.sh" "$HOME_DIR/kiri-trial.sh"
  sed -e "s|__LABEL__|$SAMPLE_LABEL|g" -e "s|__HOME_DIR__|$HOME_DIR|g" -e "s|__HOME__|$HOME|g" \
      "$DOTFILES_DIR/kiri/com.jkrumm.kiri-sample.plist.template" > "$SAMPLE_PLIST"
  plutil -lint "$SAMPLE_PLIST" >/dev/null || die "rendered sample plist is invalid"
  launchctl bootout "$DOMAIN/$SAMPLE_LABEL" 2>/dev/null || true
  for _ in $(seq 1 15); do launchctl bootstrap "$DOMAIN" "$SAMPLE_PLIST" 2>/dev/null && break; /bin/sleep 1; done
  launchctl print "$DOMAIN/$SAMPLE_LABEL" >/dev/null 2>&1 || die "bootstrap of $SAMPLE_LABEL failed"
  note "✓ $SAMPLE_LABEL every 900 s → ~/.local/state/kiri-trial/mariadb-sample.log"
}

sample_off() {
  launchctl bootout "$DOMAIN/$SAMPLE_LABEL" 2>/dev/null && note "✓ $SAMPLE_LABEL booted out" || note "· $SAMPLE_LABEL not loaded"
  rm -f "$SAMPLE_PLIST"
}

status() {
  if loaded; then note "agent: loaded"; else note "agent: not loaded"; fi
  note "daemon: $(pgrep -f "$HOME_DIR/.*/kiri daemon" | tr '\n' ' ')"
  note "socket: $([ -S "$SOCKET" ] && echo present || echo absent)"
  note "installed: $(ls "$HOME_DIR" 2>/dev/null | tr '\n' ' ')"
}

teardown() {
  sample_off
  down
  docker context rm -f kiri >/dev/null 2>&1 && note "✓ docker context kiri removed" || true
  rm -f "$PLIST"
  rm -rf "$HOME_DIR" "$STATE_DIR"
  note "✓ removed $PLIST, $HOME_DIR, $STATE_DIR (logs stay in $LOG.*)"
}

case "${1:-}" in
  install) install ;;
  up) up ;;
  down) down ;;
  sample-on) sample_on ;;
  sample-off) sample_off ;;
  status) status ;;
  teardown) teardown ;;
  *) die "usage: kiri-setup.sh install|up|down|status|teardown" ;;
esac
