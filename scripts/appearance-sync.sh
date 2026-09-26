#!/bin/bash
# Follow the macOS light/dark appearance in apps that cannot do it themselves.
# Run by com.jkrumm.appearance-sync, which fires on every write to the global
# preferences plist — so most runs see no appearance change and must be no-ops.
#
# Herdr GPUI (the herdr desktop client) takes a single `theme` name and has no
# system-appearance handling (checked against its source, 2026-09-26). It does
# reload config-gpui.local.toml on save, so rewriting the one line is enough.
# Delete this job the day upstream grows a light/dark pair.

set -euo pipefail

GPUI_CONFIG="$HOME/.config/herdr/config-gpui.local.toml"
GPUI_LIGHT="basalt-ui-light"
GPUI_DARK="basalt-ui-dark"

# AppleInterfaceStyle exists only in dark mode; its absence means light.
if [ "$(defaults read -g AppleInterfaceStyle 2>/dev/null || true)" = "Dark" ]; then
  mode=dark theme="$GPUI_DARK"
else
  mode=light theme="$GPUI_LIGHT"
fi

[ -f "$GPUI_CONFIG" ] || exit 0
want="theme = \"$theme\""
grep -qxF "$want" "$GPUI_CONFIG" && exit 0

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
