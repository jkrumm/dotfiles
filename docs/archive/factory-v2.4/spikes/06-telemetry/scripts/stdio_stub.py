#!/usr/bin/env python3
"""Minimal stdio MCP server (newline-delimited JSON-RPC) that records what Claude Code hands it.

Question it answers (Spike 6, step 5, agent-gateway row): agw's MCP is stdio-only. A stdio server
has no HTTP headers, so can a trace context reach it at all? This logs, per `tools/call`, the
TRACEPARENT-ish environment names the server process was spawned with and the `_meta` keys and
values of the call (the `claudecode/toolUseId` correlation key shows up there).

Started by Claude Code from --mcp-config; log path in SPIKE_STDIO_LOG. Stdlib only.
"""

import json
import os
import sys

LOG = os.environ.get("SPIKE_STDIO_LOG", "stdio-requests.jsonl")


def log(entry: dict) -> None:
    with open(LOG, "a", encoding="utf-8") as f:
        f.write(json.dumps(entry) + "\n")


def reply(rid: object, result: dict) -> None:
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": rid, "result": result}) + "\n")
    sys.stdout.flush()


log(
    {
        "event": "spawned",
        "env_names_of_interest": sorted(k for k in os.environ if k.startswith(("TRACE", "OTEL_", "CLAUDE_CODE_PROPAGATE")) or k == "TRACEPARENT"),
        "traceparent_in_env": os.environ.get("TRACEPARENT"),
    }
)
for raw in sys.stdin:
    try:
        msg = json.loads(raw)
    except json.JSONDecodeError:
        continue
    method, rid = msg.get("method"), msg.get("id")
    params = msg.get("params") or {}
    if rid is None:
        continue
    if method == "initialize":
        reply(rid, {"protocolVersion": params.get("protocolVersion", "2025-06-18"), "capabilities": {"tools": {"listChanged": False}}, "serverInfo": {"name": "stdio-stub-spike", "version": "0.0.1"}})
    elif method == "tools/list":
        reply(rid, {"tools": [{"name": "ping", "description": "Return pong.", "inputSchema": {"type": "object", "properties": {"note": {"type": "string"}}}}]})
    elif method == "tools/call":
        meta = params.get("_meta") or {}
        log({"event": "tools/call", "meta": {k: (v if k == "claudecode/toolUseId" else "<present>") for k, v in meta.items()}})
        reply(rid, {"content": [{"type": "text", "text": "pong"}], "isError": False})
    else:
        reply(rid, {})
