#!/usr/bin/env python3
"""Positive control: a gateway-shaped HTTP + MCP server that DOES read `traceparent`.

Question it answers (Spike 6, steps 3-4): when Claude Code sends a `traceparent` (Bash `curl`
header, outbound HTTP MCP request), what exactly arrives, and does the chain join once the
receiving side honours it? The real research-gateway is the negative control (it does not).

Doors (all on one loopback port):
  GET  /health      -> {"status":"ok","traceparent_seen":...}
  POST /research    -> {"jobId":...}                       (stands in for a gateway submit)
  POST /mcp         -> minimal MCP Streamable-HTTP server: initialize, tools/list, tools/call(ping)

Every request is appended to SPIKE_STUB_LOG (JSONL: method, path, rpc method, traceparent,
tracestate, user-agent) and exported as one SERVER span to the local collector, parented on the
incoming `traceparent` when it is valid, else a fresh root (an orphan trace: that is the bug the
spike is looking for). service.name = gateway-stub-spike.

  python3 -I gateway_stub.py --port 17790

No auth, loopback only, stdlib only.
"""

import argparse
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import otlp  # noqa: E402

LOG_PATH = os.environ.get("SPIKE_STUB_LOG", "gateway-stub-requests.jsonl")
SERVICE = "gateway-stub-spike"
PROTOCOL_FALLBACK = "2025-06-18"

PING_TOOL = {
    "name": "ping",
    "description": "Return 'pong' and the traceparent header this server received.",
    "inputSchema": {"type": "object", "properties": {"note": {"type": "string"}}},
}


class Handler(BaseHTTPRequestHandler):
    server_version = "gateway-stub/0"

    def log_message(self, fmt: str, *args: object) -> None:  # keep stdout clean
        return

    # -- plumbing ---------------------------------------------------------------------------
    def _read_json(self) -> dict | None:
        length = int(self.headers.get("content-length") or 0)
        if not length:
            return None
        try:
            return json.loads(self.rfile.read(length))
        except json.JSONDecodeError:
            return None

    def _send(self, code: int, body: object | None) -> None:
        raw = b"" if body is None else json.dumps(body).encode()
        self.send_response(code)
        if raw:
            self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _record_and_span(
        self, name: str, rpc_method: str, start_ns: int, status: int, meta_keys: list[str] | None = None
    ) -> str | None:
        tp = self.headers.get("traceparent")
        parsed = otlp.parse_traceparent(tp)
        trace_id, parent = parsed if parsed else (otlp.new_span_id() + otlp.new_span_id(), "")
        span_id = otlp.new_span_id()
        end_ns = otlp.now_ns()
        entry = {
            "ts_ns": start_ns,
            "http_method": self.command,
            "path": self.path,
            "rpc_method": rpc_method,
            "traceparent": tp,
            "tracestate": self.headers.get("tracestate"),
            "user_agent": self.headers.get("user-agent"),
            "span_trace_id": trace_id,
            "span_parent_id": parent,
            "joined": bool(parsed),
            "params_meta_keys": meta_keys or [],
        }
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(json.dumps(entry) + "\n")
        sp = otlp.span(
            trace_id=trace_id,
            span_id=span_id,
            parent_span_id=parent,
            name=name,
            kind=otlp.KIND_SERVER,
            start_ns=start_ns,
            end_ns=end_ns,
            status=otlp.STATUS_OK if status < 500 else otlp.STATUS_ERROR,
            attributes={
                "http.request.method": self.command,
                "url.path": self.path,
                "http.response.status_code": status,
                "rpc.method": rpc_method or None,
                "traceparent.present": bool(tp),
            },
        )
        otlp.export_spans(SERVICE, [sp], {"deployment.environment": "local"})
        return tp

    # -- doors ------------------------------------------------------------------------------
    def do_GET(self) -> None:  # noqa: N802
        start = otlp.now_ns()
        if self.path.split("?")[0] == "/health":
            tp = self.headers.get("traceparent")
            self._send(200, {"status": "ok", "traceparent_seen": tp})
            self._record_and_span("GET /health", "", start, 200)
            return
        self._send(405 if self.path.startswith("/mcp") else 404, None)

    def do_DELETE(self) -> None:  # noqa: N802
        self._send(200, None)

    def do_POST(self) -> None:  # noqa: N802
        start = otlp.now_ns()
        path = self.path.split("?")[0]
        body = self._read_json()
        if path == "/research":
            self._send(200, {"jobId": "00000000-0000-4000-8000-000000000001", "status": "queued"})
            self._record_and_span("POST /research", "", start, 200)
            return
        if path != "/mcp" or not isinstance(body, dict):
            self._send(404, None)
            return
        method = str(body.get("method", ""))
        rid = body.get("id")
        params = body.get("params") if isinstance(body.get("params"), dict) else {}
        meta = params.get("_meta") if isinstance(params.get("_meta"), dict) else {}
        meta_keys = sorted(meta.keys())
        if rid is None:  # notification
            self._send(202, None)
            self._record_and_span(f"mcp {method}", method, start, 202, meta_keys)
            return
        tp = self.headers.get("traceparent")
        if method == "initialize":
            proto = (body.get("params") or {}).get("protocolVersion") or PROTOCOL_FALLBACK
            result: dict = {
                "protocolVersion": proto,
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": {"name": "gateway-stub-spike", "version": "0.0.1"},
            }
        elif method == "tools/list":
            result = {"tools": [PING_TOOL]}
        elif method == "tools/call":
            result = {"content": [{"type": "text", "text": f"pong; traceparent_seen={tp}"}], "isError": False}
        elif method == "ping":
            result = {}
        else:
            self._send(200, {"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": "method not found"}})
            self._record_and_span(f"mcp {method}", method, start, 200, meta_keys)
            return
        self._send(200, {"jsonrpc": "2.0", "id": rid, "result": result})
        self._record_and_span(f"mcp {method}", method, start, 200, meta_keys)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int, default=17790)
    args = ap.parse_args()
    srv = ThreadingHTTPServer(("localhost", args.port), Handler)
    print(json.dumps({"listening": f"localhost:{args.port}", "log": LOG_PATH}), flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
