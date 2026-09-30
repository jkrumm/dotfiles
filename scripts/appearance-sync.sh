#!/bin/bash
# Follow the macOS light/dark appearance where it does not propagate by itself.
# Run by com.jkrumm.appearance-sync, which fires on every write to the global
# preferences plist — so most runs see no appearance change and must be no-ops.
#
# 1. Herdr GPUI takes a single `theme` name and has no system-appearance
#    handling (checked against its source, 2026-09-26). It reloads
#    config-gpui.local.toml on save, so rewriting the one line is enough.
# 2. Claude Code and OpenCode in herdr panes on the mini only follow the Mac
#    when a Ghostty client reports the appearance; Herdr GPUI never does. So push
#    the mode to the mini, where scripts/claude-appearance.sh re-themes every
#    Claude and OpenCode pane.

set -euo pipefail

GPUI_CONFIG="$HOME/.config/herdr/config-gpui.local.toml"
GPUI_LIGHT="basalt-ui-light"
GPUI_DARK="basalt-ui-dark"
# The mode the mini last acknowledged; a failed push leaves it stale, so the
# next preferences write retries.
PUSHED="$HOME/.local/state/appearance-sync.pushed"

# AppleInterfaceStyle exists only in dark mode; its absence means light.
if [ "$(defaults read -g AppleInterfaceStyle 2>/dev/null || true)" = "Dark" ]; then
  mode=dark theme="$GPUI_DARK"
else
  mode=light theme="$GPUI_LIGHT"
fi

sync_gpui() {
  [ -f "$GPUI_CONFIG" ] || return 0
  local want="theme = \"$theme\"" tmp
  grep -qxF "$want" "$GPUI_CONFIG" && return 0
  tmp="$(mktemp)"
  if grep -qE '^theme = ' "$GPUI_CONFIG"; then
    sed -E "s|^theme = .*|$want|" "$GPUI_CONFIG" > "$tmp"
  else
    # A top-level key must precede every table header, so it goes first.
    { echo "$want"; cat "$GPUI_CONFIG"; } > "$tmp"
  fi
  # Rewrite in place rather than mv: the GUI watches this path, and theme-picker
  # saves from the app itself go to the same inode.
  cat "$tmp" > "$GPUI_CONFIG"
  rm -f "$tmp"
  echo "$(date '+%F %T') $mode → herdr-gpui theme $theme"
}

sync_mini() {
  [ "$(cat "$PUSHED" 2>/dev/null || true)" = "$mode" ] && return 0
  # BatchMode: this rides the ControlMaster a connected GUI/desk keeps open and
  # must never sit on an auth prompt when there is none.
  if ssh -o BatchMode=yes -o ConnectTimeout=5 mini \
       "\$HOME/SourceRoot/dotfiles/scripts/claude-appearance.sh $mode" </dev/null; then
    mkdir -p "$(dirname "$PUSHED")"
    echo "$mode" > "$PUSHED"
    echo "$(date '+%F %T') $mode → mini Claude panes"
  fi
}

sync_gpui
sync_mini || true
