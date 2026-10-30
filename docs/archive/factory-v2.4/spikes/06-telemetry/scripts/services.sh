#!/usr/bin/env bash
# Start/stop the two scratch servers the spike calls. Loopback only, nothing installed.
#
#   services.sh start|stop|status
#
# 1. gateway_stub.py  — positive control, reads `traceparent`          (localhost:17790)
# 2. research-gateway — the REAL gateway code from ~/SourceRoot/research-gateway, run as a
#    throwaway process: its own port, a scratch job db, dummy credentials (the LLM leg is
#    unreachable on purpose, so a job fails fast and costs nothing), OTLP pointed at the local
#    collector. Env is set on this child process only; the repo and the live service are not
#    touched.                                                              (localhost:17780)
#
# State and logs: $SPIKE_SCRATCH (default ~/.local/share/factory/spikes/06-telemetry).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCR="${SPIKE_SCRATCH:-$HOME/.local/share/factory/spikes/06-telemetry}"
RUN="$SCR/run"
GW_REPO="$HOME/SourceRoot/research-gateway"
OTLP="${SPIKE_OTLP_BASE:-http://localhost:4319}"
mkdir -p "$RUN/gw"

start_stub() {
  [[ -s "$RUN/stub.pid" ]] && kill -0 "$(cat "$RUN/stub.pid")" 2>/dev/null && { echo "stub already up"; return; }
  : > "$RUN/stub-requests.jsonl"
  SPIKE_STUB_LOG="$RUN/stub-requests.jsonl" nohup python3 -I "$HERE/gateway_stub.py" --port 17790 \
    > "$RUN/stub.out" 2>&1 &
  echo $! > "$RUN/stub.pid"
}

start_gateway() {
  [[ -s "$RUN/gw/gateway.pid" ]] && kill -0 "$(cat "$RUN/gw/gateway.pid")" 2>/dev/null && { echo "gateway already up"; return; }
  [[ -s "$RUN/gw/secret.txt" ]] || { openssl rand -hex 12 | tr -d '\n' > "$RUN/gw/secret.txt"; chmod 600 "$RUN/gw/secret.txt"; }
  rm -f "$RUN/gw/jobs.sqlite"*
  (
    cd "$GW_REPO"
    env PORT=17780 HOST=localhost \
      API_SECRET="$(cat "$RUN/gw/secret.txt")" \
      IU_BASE_URL=http://localhost:9/v1 IU_API_KEY=dummy-local TAVILY_API_KEY=dummy-local \
      JOB_DB_PATH="$RUN/gw/jobs.sqlite" USAGE_SINK=jsonl USAGE_JSONL_PATH="$RUN/gw/usage.jsonl" \
      OTEL_EXPORTER_OTLP_ENDPOINT="$OTLP" OTEL_RESOURCE_ATTRIBUTES=deployment.environment=local-spike \
      nohup bun run src/index.ts > "$RUN/gw/gateway.log" 2>&1 &
    echo $! > "$RUN/gw/gateway.pid"
  )
}

wait_up() {
  for _ in $(seq 1 40); do
    curl -fsS -m 2 "http://localhost:17790/health" >/dev/null 2>&1 \
      && curl -fsS -m 2 "http://localhost:17780/health" >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  return 1
}

stop_one() {
  local pidfile="$1"
  [[ -s "$pidfile" ]] && kill "$(cat "$pidfile")" 2>/dev/null || true
  rm -f "$pidfile"
}

case "${1:-status}" in
  start)
    curl -fsS -m 3 "$OTLP/v1/traces" -X POST -H 'content-type: application/json' -d '{}' >/dev/null \
      || { echo "collector not reachable at $OTLP — run: make -C ~/SourceRoot/vps clickstack-up" >&2; exit 1; }
    start_stub; start_gateway
    wait_up && echo "up: stub :17790, research-gateway :17780" || { echo "services did not come up" >&2; exit 1; }
    ;;
  stop)
    stop_one "$RUN/stub.pid"; stop_one "$RUN/gw/gateway.pid"; echo stopped
    ;;
  status)
    curl -fsS -m 2 "http://localhost:17790/health" >/dev/null 2>&1 && echo "stub: up" || echo "stub: down"
    curl -fsS -m 2 "http://localhost:17780/health" >/dev/null 2>&1 && echo "gateway: up" || echo "gateway: down"
    ;;
  *) echo "usage: $0 start|stop|status" >&2; exit 2 ;;
esac
