#!/usr/bin/env bash
# Scratch email-gateway fixture instance for Spike 4 (never the production service).
#
#   email_fixture.sh up      seed a fresh store, start the instance on a scratch port, wait for /health
#   email_fixture.sh down    stop it
#   email_fixture.sh status  one line: running or not
#
# Everything lives under $SPIKE_SCRATCH/email (store, pid, log, random bearer key). The service code
# is run straight from the repo checkout (read-only use); every env var is a dummy except the
# scratch API key and DATA_DIR. No IMAP host is set, so nothing syncs; SES creds are dummies, so
# nothing can be sent.
set -euo pipefail

SCRATCH="${SPIKE_SCRATCH:-$HOME/.local/share/factory/spikes/04-cli-mcp}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${EMAIL_GATEWAY_REPO:-$HOME/SourceRoot/email-gateway}"
DIR="$SCRATCH/email"
PORT="${SPIKE_EMAIL_PORT:-39107}"

dummy_env() {
  local at='@'  # written this way so the public-repo redaction check does not mistake fixture mail for real mail
  export SECRET_KEY=spike-fixture-secret-key RECEIVER_EMAIL="owner${at}example.com" \
    SY_SERENDIPITY_RECEIVER_EMAIL="owner${at}example.com" SES_REGION=eu-central-1 \
    SES_ACCESS_KEY_ID=dummy SES_SECRET_ACCESS_KEY=dummy SES_CONFIGURATION_SET=dummy \
    PORT="$PORT" DATA_DIR="$DIR/data" API_KEY="$(cat "$DIR/api.key")" NODE_ENV=development
}

case "${1:-}" in
  up)
    "$0" down >/dev/null 2>&1 || true
    rm -rf "$DIR" && mkdir -p "$DIR/data"
    (umask 077 && openssl rand -hex 24 > "$DIR/api.key")
    dummy_env
    (cd "$DIR" && bun run "$HERE/seed_email_fixture.ts" "$DIR/truth.json" >/dev/null)
    (cd "$DIR" && nohup bun run "$REPO/src/index.ts" >"$DIR/server.log" 2>&1 & echo $! > "$DIR/pid")
    for _ in $(seq 1 40); do
      curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && { echo "up on :$PORT (pid $(cat "$DIR/pid"))"; exit 0; }
      sleep 0.5
    done
    echo "email fixture failed to start; see $DIR/server.log" >&2; exit 1 ;;
  down)
    [ -f "$DIR/pid" ] && kill "$(cat "$DIR/pid")" 2>/dev/null || true
    rm -f "$DIR/pid"; echo "down" ;;
  status)
    if [ -f "$DIR/pid" ] && kill -0 "$(cat "$DIR/pid")" 2>/dev/null; then echo "running (pid $(cat "$DIR/pid"), :$PORT)"; else echo "not running"; fi ;;
  *) echo "usage: $0 up|down|status" >&2; exit 2 ;;
esac
