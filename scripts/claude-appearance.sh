#!/bin/bash
# Make Claude Code (and OpenCode) in herdr panes follow the Mac's light/dark
# appearance when no Ghostty client is there to report it (Herdr GPUI sends
# nothing).
#
#   claude-appearance.sh light|dark   record the mode, re-theme every claude/opencode pane
#   claude-appearance.sh session      SessionStart hook / `oc` wrapper: re-theme THIS pane
#
# Claude Code on `theme: auto` enables DEC mode 2031 and, on a `CSI ?997;Nn`
# report, re-queries the background with OSC 11. OpenCode's opentui renderer
# handles the same report differently: `RendererThemeMode.handleSequence` only
# calls `requestThemeOscColors()` on it and then infers the mode from the pair of
# OSC 11 (background) and OSC 10 (foreground) answers — with either one missing it
# never commits, and without the report it never re-queries. So all three go out.
# herdr answers none of them for panes. Measured in a pty, 2026-09-30: the OSC 11
# answer alone leaves OpenCode dark (its old form), OSC 11 + OSC 10 flips it.
# Claude is unaffected by the extra OSC 10. Neither half works alone, and editing
# ~/.claude.json does nothing to a running session.
#
# herdr-core (hc) is no better (docs/herdr-core.md fact 6, re-verified on core 0.1.15):
# a terminal nobody is attached to answers OSC 10/11 with fixed dark colours, and a
# running program gets no `?997` on a switch. The same bytes therefore go in as raw
# input over `terminal.attach` (scripts/hc-raw-input.ts; `hc send` always adds Enter).
# The classic herdr path stays beside it until Wave 7.
#
# Applied by scripts/appearance-sync.sh both locally (this machine's own herdr
# panes, which run opencode too) and on the mini over `ssh mini`.

set -euo pipefail
export PATH="/opt/homebrew/bin:$HOME/.bun/bin:$PATH"

HC_INPUT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hc-raw-input.ts"

STATE="$HOME/.local/state/claude-appearance"

# The OSC 11 (background) and OSC 10 (foreground) colours are the One Zinc
# terminal pair (docs/theme.md). Both are required: opentui infers the mode from
# the two together, and Claude Code re-queries OSC 11 on the `?997` report.
# shellcheck disable=SC1003  # the trailing \\ is the ST terminator, not a quote escape
report() {
  if [ "$1" = light ]; then
    printf '\033[?997;2n\033]11;rgb:f2f2/f2f2/f5f5\033\\\033]10;rgb:2626/2626/2929\033\\'
  else
    printf '\033[?997;1n\033]11;rgb:1f1f/1f1f/2323\033\\\033]10;rgb:d4d4/d4d4/d8d8\033\\'
  fi
}

case "${1:-}" in
  light|dark)
    mkdir -p "$(dirname "$STATE")"
    echo "$1" > "$STATE"
    # Only agent terminals: a plain shell would take the bytes as typed input.
    # hc-raw-input --agents picks live terminals running claude or opencode and
    # refuses to start a core (no-op when launchd's herdr-core is not running).
    report "$1" | bun "$HC_INPUT" --agents >/dev/null 2>&1 || true
    # TODO(Wave 7): drop classic. opencode self-reports through herdr's opencode
    # integration, so both renderers are targetable by agent id.
    { herdr agent list 2>/dev/null \
      | jq -r '.result.agents[] | select(.agent == "claude" or .agent == "opencode") | .pane_id' \
      | while read -r pane; do
          herdr pane send-text "$pane" "$(report "$1")" >/dev/null 2>&1 || true
        done; } || true
    ;;
  session)
    # No-op outside a herdr pane / hc terminal, and on any host no push has ever reached.
    [ -n "${HERDR_PANE_ID:-}${HC_TERMINAL_ID:-}" ] && [ -f "$STATE" ] || exit 0
    # Detached, and the first send must beat OpenCode's first paint: it resolves
    # its mode before `waitForThemeMode` gives up (measured ~1.5 s to first paint,
    # >0.3 s of raw mode), so the old single 3 s send always arrived late and the
    # pane started dark. The later sends cover a slow start and Claude, whose
    # SessionStart hook runs this with its TUI already up. The hook itself must
    # return at once.
    if [ -n "${HC_TERMINAL_ID:-}" ]; then
      # shellcheck disable=SC2016  # $0/$1 expand in the child bash, by design
      nohup bash -c '
        for d in 0.4 0.8 1.8; do
          sleep "$d"; printf "%s" "$1" | bun "$0" --self >/dev/null 2>&1 || true
        done
      ' "$HC_INPUT" "$(report "$(cat "$STATE")")" >/dev/null 2>&1 &
    fi
    # TODO(Wave 7): drop classic.
    if [ -n "${HERDR_PANE_ID:-}" ]; then
      # shellcheck disable=SC2016  # $0/$1 expand in the child bash, by design
      nohup bash -c '
        sleep 0.4; herdr pane send-text "$0" "$1" >/dev/null 2>&1 || true
        sleep 0.8; herdr pane send-text "$0" "$1" >/dev/null 2>&1 || true
        sleep 1.8; herdr pane send-text "$0" "$1" >/dev/null 2>&1 || true
      ' "$HERDR_PANE_ID" "$(report "$(cat "$STATE")")" >/dev/null 2>&1 &
    fi
    ;;
  *)
    echo "usage: $(basename "$0") light|dark|session" >&2
    exit 2
    ;;
esac
