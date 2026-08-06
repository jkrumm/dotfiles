#!/usr/bin/env bash
# tailscale-cli — resolve THIS machine's Tailscale CLI, once, for every caller.
#
# WHY THIS EXISTS. The two Macs run different Tailscale variants and there is no
# single path that works on both:
#
#   mini      open-source tailscaled (brew), root LaunchDaemon, CLI at
#             /opt/homebrew/bin/tailscale, socket /var/run/tailscaled.socket
#   MacBook   App Store build, CLI only inside the app bundle
#
# Before the 2026-08-06 migration every script hardcoded the app-bundle path.
# On the mini that path STILL EXISTS and STILL ANSWERS — the macsys system
# extension is left installed so rollback stays cheap — but it answers from the
# DORMANT daemon, reporting a stopped tunnel and the pre-migration IP. That is
# the worst possible failure shape: not an error, a confident wrong answer.
# caddy-tailnet.sh regenerated its config with the dead IP that way, and
# devhost-health would have paged "tailnet down" on a perfectly healthy host.
#
# THE SOCKET IS ALWAYS EXPLICIT, never left to auto-detection. The brew CLI
# picks the macsys socket over its own when both are present — the same wrong
# daemon, reached a different way. `--socket` is what makes the answer
# deterministic, so ts_run() always passes it.
#
# Read-only commands work as a normal user (the socket is srw-rw-rw-), which is
# what lets devhost-health keep running as a LaunchAgent. Mutating commands
# (serve, funnel, up) still need root — callers add their own sudo.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/tailscale-cli.sh"
#   ts_run status --json
#   [[ -n "$TAILSCALE_BIN" ]] || die "no tailscale CLI"

# Honour a caller-supplied override first — the tests drive both variants from
# one machine, and a hardcoded probe order would make that impossible.
if [ -z "${TAILSCALE_BIN:-}" ]; then
  if [ -S /var/run/tailscaled.socket ] && [ -x /opt/homebrew/bin/tailscale ]; then
    TAILSCALE_BIN=/opt/homebrew/bin/tailscale
    TAILSCALE_SOCKET=/var/run/tailscaled.socket
  elif [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]; then
    TAILSCALE_BIN=/Applications/Tailscale.app/Contents/MacOS/Tailscale
    TAILSCALE_SOCKET=""
  else
    TAILSCALE_BIN=""
    TAILSCALE_SOCKET=""
  fi
fi
: "${TAILSCALE_SOCKET:=}"

# Which variant answered, for messages that need to say so. Not derived from the
# path at each call site — one place decides, everywhere else asks.
# shellcheck disable=SC2034  # consumed by sourcing scripts (drift-check.sh)
if [ "$TAILSCALE_BIN" = "/opt/homebrew/bin/tailscale" ]; then
  TAILSCALE_VARIANT="tailscaled (brew, open source)"
elif [ -n "$TAILSCALE_BIN" ]; then
  TAILSCALE_VARIANT="app bundle (App Store or standalone)"
else
  TAILSCALE_VARIANT="none"
fi

# The one call path. Unquoted ${TAILSCALE_SOCKET:+...} is deliberate: it must
# expand to nothing at all when empty, and the value is a fixed literal path
# with no whitespace or glob characters.
# shellcheck disable=SC2086
ts_run() {
  [ -n "$TAILSCALE_BIN" ] || return 1
  "$TAILSCALE_BIN" ${TAILSCALE_SOCKET:+--socket=$TAILSCALE_SOCKET} "$@"
}
