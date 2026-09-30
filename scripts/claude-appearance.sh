#!/bin/bash
# Make Claude Code (and OpenCode) in herdr panes follow the MacBook's light/dark
# appearance when no Ghostty client is there to report it (Herdr GPUI sends
# nothing).
#
#   claude-appearance.sh light|dark   record the mode, re-theme every claude/opencode pane
#   claude-appearance.sh session      SessionStart hook / `oc` wrapper: re-theme THIS pane
#
# Claude Code on `theme: auto` enables DEC mode 2031 and, on a `CSI ?997;Nn`
# report, re-queries the background with OSC 11. OpenCode's opentui renderer
# reads the same `CSI ?997;Nn` report (packages/tui/src/context/theme.tsx) and
# flips its mode from it. herdr answers neither for panes, so this sends the
# report AND the OSC 11 answer, as a terminal would. Measured 2026-09-27: a
# running Claude flips live, no redraw, nothing lands in the prompt. Neither
# half works alone, and editing ~/.claude.json does nothing to a running
# session.
#
# Pushed from the MacBook by scripts/appearance-sync.sh over `ssh mini`.

set -euo pipefail
export PATH="/opt/homebrew/bin:$PATH"

STATE="$HOME/.local/state/claude-appearance"

# The OSC 11 colours are the One Zinc terminal backgrounds (docs/theme.md).
# shellcheck disable=SC1003  # the trailing \\ is the ST terminator, not a quote escape
report() {
  if [ "$1" = light ]; then
    printf '\033[?997;2n\033]11;rgb:f2f2/f2f2/f5f5\033\\'
  else
    printf '\033[?997;1n\033]11;rgb:1f1f/1f1f/2323\033\\'
  fi
}

case "${1:-}" in
  light|dark)
    mkdir -p "$(dirname "$STATE")"
    echo "$1" > "$STATE"
    # Only agent panes: a plain shell would take the bytes as typed input.
    # opencode self-reports through herdr's opencode integration, so both
    # renderers are targetable by agent id.
    herdr agent list 2>/dev/null \
      | jq -r '.result.agents[] | select(.agent == "claude" or .agent == "opencode") | .pane_id' \
      | while read -r pane; do
          herdr pane send-text "$pane" "$(report "$1")" >/dev/null 2>&1 || true
        done
    ;;
  session)
    # No-op outside a herdr pane, and on any host no push has ever reached.
    [ -n "${HERDR_PANE_ID:-}" ] && [ -f "$STATE" ] || exit 0
    # Detached, and late enough for the TUI to have enabled mode 2031 — the
    # hook itself must return at once.
    # shellcheck disable=SC2016  # $0/$1 expand in the child bash, by design
    nohup bash -c 'sleep 3; herdr pane send-text "$0" "$1"' \
      "$HERDR_PANE_ID" "$(report "$(cat "$STATE")")" >/dev/null 2>&1 &
    ;;
  *)
    echo "usage: $(basename "$0") light|dark|session" >&2
    exit 2
    ;;
esac
