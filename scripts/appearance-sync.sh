#!/bin/bash
# Follow the macOS light/dark appearance where it does not propagate by itself.
# Run by com.jkrumm.appearance-sync, which fires on every write to the global
# preferences plist — so most runs see no appearance change and must be no-ops.
#
# The Herdr app follows the system appearance itself (docs/theme.md), but Claude
# Code and OpenCode in its terminals do not: a Ghostty client would report the
# appearance, the core never does (docs/herdr-core.md fact 6). So re-theme every
# Claude and OpenCode terminal here, and push the mode to the mini, where the
# same terminals run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_STATE="$HOME/.local/state/claude-appearance"

# The mode the mini last acknowledged; a failed push leaves it stale, so the
# next preferences write retries.
PUSHED="$HOME/.local/state/appearance-sync.pushed"

# AppleInterfaceStyle exists only in dark mode; its absence means light.
if [ "$(defaults read -g AppleInterfaceStyle 2>/dev/null || true)" = "Dark" ]; then
  mode=dark
else
  mode=light
fi

sync_mini() {
  [ "$(cat "$PUSHED" 2>/dev/null || true)" = "$mode" ] && return 0
  # BatchMode: this rides the ControlMaster a connected Herdr app keeps open and
  # must never sit on an auth prompt when there is none.
  if ssh -o BatchMode=yes -o ConnectTimeout=5 mini \
       "\$HOME/SourceRoot/dotfiles/scripts/claude-appearance.sh $mode" </dev/null; then
    mkdir -p "$(dirname "$PUSHED")"
    echo "$mode" > "$PUSHED"
    echo "$(date '+%F %T') $mode → mini Claude terminals"
  fi
}

# The same mode, applied locally: this machine's own hc terminals run Claude and
# OpenCode too, and get no terminal answer for the same reason. This also writes
# ~/.local/state/claude-appearance, which the SessionStart hook and the `oc`
# wrapper replay into each new terminal. Without it the Mac's own terminals never
# hear a push (it was mini-only), so they started dark.
sync_local() {
  [ "$(cat "$LOCAL_STATE" 2>/dev/null || true)" = "$mode" ] && return 0
  "$SCRIPT_DIR/claude-appearance.sh" "$mode" || true
  echo "$(date '+%F %T') $mode → local Claude/OpenCode terminals"
}

sync_local || true
sync_mini || true
