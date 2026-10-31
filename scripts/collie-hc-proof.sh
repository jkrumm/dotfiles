#!/usr/bin/env bash
# collie-hc-proof — proves the standalone Collie bridge works against herdr-core, in a scratch
# core. Re-run it after a collie-upgrade or a core bump, before trusting the live install.
#
# Everything is scratch and torn down on exit: its own core session (HC_SESSION=chp) under its own
# throwaway LaunchAgent (a core is only ever started through launchd), scratch XDG_* /
# HERDR_APP_HOME, its own bridge LaunchAgent on a scratch port, state dir and config dir. It runs
# the REAL scripts/collie-setup.sh with the scratch overrides, so the build, the plist and the
# behavioural check are the production ones. The owner's core, the live collie and the classic
# herdr.collie plugin are never touched (COLLIE_LEGACY_MIGRATE=0).
#
#   1. collie-setup.sh setup  → build the pinned commit, render + bootstrap the agent, run the
#      behavioural check (health, SPA, spoofed-Host 403, bridge ↔ core connected)
#   2. list: the bridge's snapshot shows the scratch terminal
#   3. read: the bridge returns that terminal's screen (a nonce the terminal printed)
#   4. type: a paired device sends a keystroke through the bridge; the terminal receives it
#   5. launchd-first: with the core and its holder gone, the bridge stays up, reports
#      `disconnected`, and nothing starts a core or recreates the socket; when launchd brings
#      the core back, the bridge reconnects on its own
#
# Needs: the dev host (secrets backend `cache`), bun, network for the first build (~1 min).
set -uo pipefail

DOTFILES_DIR="${DOTFILES_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
MAKEFILE="$DOTFILES_DIR/Makefile"
# shellcheck source=lib/github-tags.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/github-tags.sh"
COLLIE_SOURCE=$(makefile_var COLLIE_SOURCE)
COLLIE_REF=$(makefile_var COLLIE_REF)
COLLIE_VERSION=$(makefile_var COLLIE_VERSION)
[ -n "$COLLIE_REF" ] || { echo "✗ cannot read COLLIE_REF from $MAKEFILE"; exit 1; }

UID_=$(id -u)
DOMAIN="gui/$UID_"
T=$(mktemp -d /tmp/chp.XXXXXX)
SESSION=chp
PORT="${COLLIE_PROOF_PORT:-18789}"
CORE_LABEL="com.jkrumm.scratch-chp-core"
BRIDGE_LABEL="com.jkrumm.scratch-chp-collie"
SOCK="$T/state/herdr-core/$SESSION/$SESSION.sock"
NONCE="w4-$RANDOM$RANDOM"
fail=0

step() { printf '\n== %s\n' "$*"; }
ok() { echo "   ✓ $*"; }
bad() { echo "   ✗ $*"; fail=1; }

# shellcheck disable=SC2009  # pgrep -f cannot print the command line the failure report needs
scratch_procs() { ps -axo pid=,command= | grep -F "$T/state" | grep -v grep || true; }

# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() {
  launchctl bootout "$DOMAIN/$BRIDGE_LABEL" 2>/dev/null || true
  launchctl bootout "$DOMAIN/$CORE_LABEL" 2>/dev/null || true
  scratch_procs | awk '{print $1}' | xargs kill 2>/dev/null || true
  sleep 1
  scratch_procs | awk '{print $1}' | xargs kill -9 2>/dev/null || true
  rm -rf "$T"
  echo; echo "scratch torn down ($T)"
}
trap cleanup EXIT

# The owner's core must be up under launchd before any hc call: an hc call with no core
# auto-starts one. (Our calls carry HC_SESSION and a scratch core, but the rule is cheap.)
step "preflight"
launchctl print "$DOMAIN/com.jkrumm.herdr-core" 2>/dev/null | grep -E '^[[:space:]]+state = ' | head -1 | sed 's/^[[:space:]]*/   live core: /'
echo "   pin: collie $COLLIE_VERSION ($COLLIE_REF)  scratch: $T  port: $PORT"

step "scratch core (own session '$SESSION', own LaunchAgent)"
mkdir -p "$T"/{agents,state,xdgcfg,xdgdata,app,cfg}
HC_BIN=$(command -v hc || true)
CORE_BIN=/opt/homebrew/opt/herdr-core/bin/herdr-core
[ -n "$HC_BIN" ] && [ -x "$CORE_BIN" ] || { echo "✗ hc or herdr-core missing"; exit 1; }
cat > "$T/agents/$CORE_LABEL.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$CORE_LABEL</string>
<key>ProgramArguments</key><array><string>$CORE_BIN</string><string>serve</string></array>
<key>RunAtLoad</key><true/>
<key>EnvironmentVariables</key><dict>
<key>PATH</key><string>$HOME/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
<key>HC_SESSION</key><string>$SESSION</string>
<key>XDG_STATE_HOME</key><string>$T/state</string>
<key>XDG_CONFIG_HOME</key><string>$T/xdgcfg</string>
<key>XDG_DATA_HOME</key><string>$T/xdgdata</string>
<key>HERDR_APP_HOME</key><string>$T/app</string>
</dict>
<key>StandardOutPath</key><string>$T/core.log</string>
<key>StandardErrorPath</key><string>$T/core.log</string>
</dict></plist>
EOF
launchctl bootstrap "$DOMAIN" "$T/agents/$CORE_LABEL.plist" || { echo "✗ could not bootstrap the scratch core"; exit 1; }
for _ in $(seq 1 20); do [ -S "$SOCK" ] && break; sleep 1; done
[ -S "$SOCK" ] || { echo "✗ scratch core socket never appeared ($SOCK)"; exit 1; }
hcs() { HC_SESSION=$SESSION XDG_STATE_HOME="$T/state" XDG_CONFIG_HOME="$T/xdgcfg" XDG_DATA_HOME="$T/xdgdata" HERDR_APP_HOME="$T/app" hc "$@"; }
hcs run --bg --keep --name proof-a sh -c "echo ready-$NONCE; exec cat" >/dev/null
ok "core $(hcs server status 2>/dev/null | jq -r '.version // empty') up, terminal t1 running"

step "1. collie-setup.sh setup (the production script, scratch overrides)"
cat > "$T/cfg/.env" <<EOF
COLLIE_PORT=$PORT
COLLIE_HOST=127.0.0.1
COLLIE_SKIP_SERVE=1
COLLIE_MULTI_SESSION=off
COLLIE_PUBLIC_HOSTS=proof.example.test:8788,proof.example.test
COLLIE_MUX=herdr-core
EOF
chmod 600 "$T/cfg/.env"
csetup() {
  COLLIE_SOURCE="$COLLIE_SOURCE" COLLIE_REF="$COLLIE_REF" COLLIE_VERSION="$COLLIE_VERSION" \
  COLLIE_LABEL="$BRIDGE_LABEL" COLLIE_HOME="$T/home" COLLIE_CONFIG_DIR="$T/cfg" COLLIE_LOG="$T/collie.log" \
  COLLIE_AGENT_DIR="$T/agents" COLLIE_PORT="$PORT" COLLIE_STATE_DIR="$T/cstate" \
  COLLIE_HC_SESSION="$SESSION" COLLIE_HC_SOCKET="$SOCK" COLLIE_LEGACY_MIGRATE=0 \
    bash "$DOTFILES_DIR/scripts/collie-setup.sh" "$@"
}
csetup setup || { bad "collie-setup.sh setup failed"; tail -20 "$T/collie.log" 2>/dev/null; exit 1; }

BASE="http://127.0.0.1:$PORT"
SECRET=$(cat "$T/cstate/local-secret")
ROOT="$T/home/${COLLIE_REF:0:12}"

step "2. list — the bridge shows the scratch terminal"
snap=$(curl -s -H "Authorization: Bearer $SECRET" "$BASE/api/snapshot")
echo "$snap" | jq -c '{bridge, panes: [(.shellPanes + .agents)[] | {paneId, label: .paneLabel, agent}]}' | sed 's/^/   /'
if [ "$(echo "$snap" | jq -r '[(.shellPanes + .agents)[].paneId] | index("t1") != null')" = "true" ]; then ok "t1 listed"; else bad "t1 not listed"; fi

step "3. read — the bridge returns its screen"
screen=$(curl -s -H "Authorization: Bearer $SECRET" "$BASE/api/pane/t1" | jq -r '.text // empty')
printf '%s\n' "$screen" | sed 's/^/   | /'
if [[ "$screen" == *"ready-$NONCE"* ]]; then ok "screen carries the terminal's nonce ready-$NONCE"; else bad "nonce not on the bridge's screen"; fi

step "4. type — a paired device sends a keystroke through the bridge"
pair_json=$(COLLIE_PLUGIN_ROOT="$ROOT" HERDR_PLUGIN_CONFIG_DIR="$T/cfg" COLLIE_STATE_DIR="$T/cstate" "$ROOT/bin/collie" pair --json 2>/dev/null | tail -1)
code=$(echo "$pair_json" | jq -r '.code // empty')
token=$(curl -s -X POST -H 'Content-Type: application/json' -d "{\"code\":\"$code\",\"label\":\"proof\"}" "$BASE/api/pair" | jq -r '.token // empty')
if [ -z "$token" ]; then bad "pairing failed"; else ok "device paired (token ${#token} chars, never printed)"; fi
echo "   local credential must not type:"
got=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $SECRET" -H 'Content-Type: application/json' -d '{"keys":["x"]}' "$BASE/api/pane/t1/keys")
if [ "$got" = "403" ]; then ok "local credential refused (403)"; else bad "local credential got $got on keys, expected 403"; fi
COLLIE_PORT="$PORT" COLLIE_STATE_DIR="$T/cstate" COLLIE_CHECK_WRITE=1 COLLIE_CHECK_PANE=t1 COLLIE_CHECK_KEYS=q \
COLLIE_CHECK_PAIRED_TOKEN="$token" COLLIE_EXPECT_VERSION="$COLLIE_VERSION+${COLLIE_REF:0:10}" \
  bash "$DOTFILES_DIR/scripts/collie-check.sh" || fail=1
arrived=""
for _ in $(seq 1 20); do
  arrived=$(hcs read t1 2>/dev/null | tail -1)
  [ "$arrived" = "q" ] && break
  sleep 1
done
echo "   hc read t1 (last line): '$arrived'"
if [ "$arrived" = "q" ]; then ok "the keystroke arrived in the terminal"; else bad "keystroke did not arrive"; fi

step "4b. setup is idempotent; status and pair work"
again=$(csetup setup 2>&1)
if grep -q "up to date" <<<"$again" && grep -q "built at" <<<"$again" && ! grep -q "bootstrapped" <<<"$again"; then
  ok "second setup: same build, same plist, agent left running"
else
  bad "second setup was not a no-op:"; echo "$again" | sed 's/^/     /'
fi
csetup status 2>&1 | grep -E "✓|✗|!" | sed 's/^ */   /'
if [ "$(csetup pair 2>/dev/null | head -1 | tr -d '[:space:]' | wc -c | tr -d ' ')" = "8" ]; then ok "pair mints an 8-character code"; else bad "pair did not print a code"; fi

step "5. launchd-first — core gone: the bridge stays up and starts nothing"
launchctl bootout "$DOMAIN/$CORE_LABEL" 2>/dev/null || true
scratch_procs | awk '{print $1}' | xargs kill 2>/dev/null || true
sleep 1
scratch_procs | awk '{print $1}' | xargs kill -9 2>/dev/null || true
rm -rf "$T/state/herdr-core/$SESSION"
sleep 15
left=$(scratch_procs)
if [ -z "$left" ]; then ok "no process under the scratch session after 15 s (no core started)"; else bad "something is running:"; echo "$left" | cut -c1-150 | sed 's/^/     /'; fi
if [ ! -e "$T/state/herdr-core/$SESSION" ]; then ok "the session dir was not recreated (no socket)"; else bad "session dir reappeared"; fi
health=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/health")
link=$(curl -s -H "Authorization: Bearer $SECRET" "$BASE/api/snapshot" | jq -r '.bridge')
echo "   /api/health → $health   snapshot.bridge → $link"
if [ "$health" = "200" ] && [ "$link" = "disconnected" ]; then ok "bridge up, reports disconnected"; else bad "unexpected bridge state"; fi
if COLLIE_PORT="$PORT" COLLIE_STATE_DIR="$T/cstate" COLLIE_CHECK_WAIT_S=3 bash "$DOTFILES_DIR/scripts/collie-check.sh" >/dev/null 2>&1; then
  bad "collie-check passed with the core down — it must fail"
else
  ok "collie-check fails with the core down"
fi

step "   core back (launchd) — the bridge reconnects by itself"
launchctl bootstrap "$DOMAIN" "$T/agents/$CORE_LABEL.plist" 2>/dev/null || true
link=""
for _ in $(seq 1 30); do
  link=$(curl -s -H "Authorization: Bearer $SECRET" "$BASE/api/snapshot" | jq -r '.bridge')
  [ "$link" = "connected" ] && break
  sleep 1
done
if [ "$link" = "connected" ]; then ok "snapshot.bridge → connected"; else bad "bridge did not reconnect (last: $link)"; fi

step "6. teardown removes the agent"
csetup teardown >/dev/null 2>&1
if launchctl print "$DOMAIN/$BRIDGE_LABEL" >/dev/null 2>&1; then bad "agent still loaded after teardown"; else ok "agent gone"; fi
if [ -e "$T/home" ]; then bad "checkouts still there"; else ok "checkouts removed, .env kept: $([ -f "$T/cfg/.env" ] && echo yes || echo no)"; fi

echo
if [ "$fail" = "0" ]; then echo "PROOF PASSED — collie $COLLIE_VERSION drives herdr-core"; else echo "PROOF FAILED"; fi
exit "$fail"
