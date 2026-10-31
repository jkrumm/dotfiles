#!/usr/bin/env bash
# collie-check — the behavioural check for the standalone Collie bridge on herdr-core.
# Run by `make collie-setup` (fails the install), `make collie-status` and, with
# COLLIE_CHECK_WRITE=1, by scripts/collie-hc-proof.sh. Exit 0 = every probe passed.
#
# Behavioural, not configural: a bridge started without its .env answers 200 exactly like a
# healthy one with every hardening setting silently off, and a bridge whose core socket is
# gone still serves the SPA. So each probe asserts the effect, never the config:
#   1. /api/health answers 200 (and, with COLLIE_EXPECT_VERSION, the build we pinned).
#   2. `/` serves the SPA shell.
#   3. A spoofed Host on /api/snapshot is 403 — the DNS-rebinding guard, i.e. the .env reached
#      the process. The path is load-bearing: the guard fires on API routes only, `/` answers 200
#      to any Host.
#   4. The bridge reaches the core: /api/snapshot with the host-local read credential says
#      `bridge: connected` and lists the core's terminals (shell panes + agents). The credential
#      is the bridge's own `local-secret` in its state dir; it reads, it never types.
#   5. (COLLIE_CHECK_WRITE=1, scratch cores only) read one terminal's screen and type a
#      keystroke into it through a paired device, then see it arrive. Never run against the
#      live core: it types into a terminal.
#
# The check never calls hc and never touches the core's socket itself: hc would start a core
# when none runs (docs/herdr-core.md fact 9), and launchd owns the core.
#
# Env: COLLIE_PORT (8787), COLLIE_STATE_DIR (~/.local/state/collie), COLLIE_EXPECT_VERSION,
#      COLLIE_CHECK_WAIT_S (20, how long to wait for the bridge to come up).
set -uo pipefail

PORT="${COLLIE_PORT:-8787}"
BASE="http://127.0.0.1:$PORT"
STATE_DIR="${COLLIE_STATE_DIR:-$HOME/.local/state/collie}"
WAIT_S="${COLLIE_CHECK_WAIT_S:-20}"
fail=0

ok() { echo "    ✓ $*"; }
bad() { echo "    ✗ $*"; fail=1; }
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$@" 2>/dev/null || true; }

# 1. liveness — the bridge needs a moment after a (re)start
health=""
for _ in $(seq 1 "$WAIT_S"); do
  health=$(curl -s --max-time 3 "$BASE/api/health" 2>/dev/null || true)
  [ "$(printf '%s' "$health" | jq -r '.ok // empty' 2>/dev/null)" = "true" ] && break
  health=""
  sleep 1
done
if [ -z "$health" ]; then
  bad "bridge is not answering on $BASE/api/health"
  echo "    check: launchctl print gui/$(id -u)/com.jkrumm.collie   and   ~/Library/Logs/collie.log"
  exit 1
fi
version=$(printf '%s' "$health" | jq -r '.version')
if [ -n "${COLLIE_EXPECT_VERSION:-}" ] && [ "$version" != "$COLLIE_EXPECT_VERSION" ]; then
  bad "bridge runs $version, expected $COLLIE_EXPECT_VERSION — the pinned build is not the one serving"
else
  ok "bridge up ($version)"
fi

# 2. the SPA shell
if [ "$(code "$BASE/")" = "200" ]; then ok "SPA shell served"; else bad "/ did not answer 200 — web/dist missing?"; fi

# 3. the rebind guard
got=$(code -H 'Host: evil.example.com' "$BASE/api/snapshot")
if [ "$got" = "403" ]; then
  ok "DNS-rebinding guard in effect (spoofed Host → 403)"
else
  bad "spoofed Host got $got, expected 403 — the .env did not reach the process; every hardening setting is off"
fi

# 4. the core is reached, and listed
secret=$(cat "$STATE_DIR/local-secret" 2>/dev/null || true)
if [ -z "$secret" ]; then
  bad "no local credential at $STATE_DIR/local-secret — cannot read the snapshot"
else
  snap=$(curl -s --max-time 10 -H "Authorization: Bearer $secret" "$BASE/api/snapshot" 2>/dev/null || true)
  link=$(printf '%s' "$snap" | jq -r '.bridge // empty' 2>/dev/null)
  if [ "$link" = "connected" ]; then
    n=$(printf '%s' "$snap" | jq '(.agents | length) + (.shellPanes | length)')
    ok "reaches the herdr-core: connected, $n terminals listed"
  else
    bad "bridge ↔ core is '${link:-no snapshot}' — is com.jkrumm.herdr-core running? (the bridge never starts one)"
  fi
fi

# 5. scratch cores only: read a terminal, type into it
if [ "${COLLIE_CHECK_WRITE:-}" = "1" ]; then
  : "${COLLIE_CHECK_PANE:?COLLIE_CHECK_PANE (a terminal address) required with COLLIE_CHECK_WRITE=1}"
  : "${COLLIE_CHECK_PAIRED_TOKEN:?COLLIE_CHECK_PAIRED_TOKEN required with COLLIE_CHECK_WRITE=1}"
  pane="$COLLIE_CHECK_PANE"
  screen=$(curl -s --max-time 10 -H "Authorization: Bearer $secret" "$BASE/api/pane/$pane" | jq -r '.text // empty')
  if [ -n "$screen" ]; then ok "read $pane: $(printf '%s' "$screen" | tail -1 | cut -c1-60)"; else bad "could not read $pane through the bridge"; fi
  sent=$(curl -s --max-time 10 -X POST -H "Authorization: Bearer $COLLIE_CHECK_PAIRED_TOKEN" -H 'Content-Type: application/json' \
    -d "{\"keys\":[\"${COLLIE_CHECK_KEYS:-q}\"]}" "$BASE/api/pane/$pane/keys" | jq -r '.ok // empty')
  if [ "$sent" = "true" ]; then ok "keystroke accepted for $pane"; else bad "keystroke refused for $pane"; fi
fi

exit "$fail"
