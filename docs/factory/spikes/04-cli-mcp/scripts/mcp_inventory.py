#!/usr/bin/env python3
"""Inventory one MCP server: tool names and the size of their definitions.

Speaks raw JSON-RPC (initialize, notifications/initialized, tools/list) over stdio or
streamable HTTP, so it measures what the server actually advertises, independent of any client.
Token counts come from the IU endpoint's count_tokens route (exact tokenizer, same models the
sessions use): tokens(messages + tools) - tokens(messages), i.e. what the API charges for the
definitions, including its fixed tool-use preamble (reported separately as `preamble_tokens`).

  mcp_inventory.py --name agw   --stdio "bun run <repo>/server/mcp.ts" --out raw/inventory-agw-mcp.json
  mcp_inventory.py --name email --http <url> --bearer-env SPIKE_EMAIL_KEY --out ...
  mcp_inventory.py --name research --claude-config research-gateway --out ...   # URL + headersHelper
                                                                                  # read from ~/.claude.json
"""

from __future__ import annotations

import argparse
import json
import os
import shlex
import subprocess
import sys
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from lib_iu import iu_base, iu_key  # noqa: E402

PROTOCOL = "2025-06-18"
MODEL_FOR_COUNT = os.environ.get("SPIKE_MODEL", "claude-sonnet-5")


class Stdio:
    def __init__(self, cmd: str, cwd: str | None):
        self.p = subprocess.Popen(
            shlex.split(cmd), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, cwd=cwd,
        )

    def rpc(self, method: str, params: dict | None, id_: int | None):
        msg = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            msg["params"] = params
        if id_ is not None:
            msg["id"] = id_
        assert self.p.stdin and self.p.stdout
        self.p.stdin.write(json.dumps(msg) + "\n")
        self.p.stdin.flush()
        if id_ is None:
            return None
        while True:
            line = self.p.stdout.readline()
            if not line:
                raise RuntimeError("server closed stdout")
            resp = json.loads(line)
            if resp.get("id") == id_:
                return resp

    def close(self):
        self.p.terminate()


class Http:
    def __init__(self, url: str, headers: dict[str, str]):
        self.url, self.headers, self.session = url, headers, None

    def rpc(self, method: str, params: dict | None, id_: int | None):
        body = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            body["params"] = params
        if id_ is not None:
            body["id"] = id_
        hdr = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream",
               "MCP-Protocol-Version": PROTOCOL, **self.headers}
        if self.session:
            hdr["Mcp-Session-Id"] = self.session
        req = urllib.request.Request(self.url, data=json.dumps(body).encode(), headers=hdr, method="POST")
        with urllib.request.urlopen(req) as r:  # noqa: S310 - fixed operator-supplied URL
            self.session = r.headers.get("Mcp-Session-Id") or self.session
            raw = r.read().decode()
            ctype = r.headers.get("Content-Type", "")
        if id_ is None or not raw.strip():
            return None
        if "text/event-stream" in ctype:
            for line in raw.splitlines():
                if line.startswith("data:"):
                    resp = json.loads(line[5:].strip())
                    if resp.get("id") == id_:
                        return resp
            raise RuntimeError("no matching SSE frame")
        return json.loads(raw)

    def close(self):
        pass


def list_tools(client) -> tuple[dict, list[dict]]:
    init = client.rpc("initialize", {"protocolVersion": PROTOCOL, "capabilities": {},
                                     "clientInfo": {"name": "spike4", "version": "0"}}, 1)["result"]
    client.rpc("notifications/initialized", None, None)
    tools, cursor, n = [], None, 2
    while True:
        resp = client.rpc("tools/list", {"cursor": cursor} if cursor else {}, n)
        n += 1
        tools += resp["result"]["tools"]
        cursor = resp["result"].get("nextCursor")
        if not cursor:
            return init, tools


def count_tokens(tools: list[dict] | None, probe: str = "ok") -> int | None:
    """Exact input-token count for a one-message request with the given tools (IU count_tokens)."""
    body: dict = {"model": MODEL_FOR_COUNT, "messages": [{"role": "user", "content": probe}]}
    if tools:
        body["tools"] = [{"name": t["name"], "description": t.get("description", ""),
                          "input_schema": t.get("inputSchema", {"type": "object"})} for t in tools]
    req = urllib.request.Request(
        iu_base() + "/v1/messages/count_tokens", data=json.dumps(body).encode(), method="POST",
        headers={"Content-Type": "application/json", "anthropic-version": "2023-06-01",
                 "Authorization": f"Bearer {iu_key()}"},
    )
    try:
        with urllib.request.urlopen(req) as r:  # noqa: S310
            return json.loads(r.read())["input_tokens"]
    except Exception as exc:  # the number is a cross-check; the session-derived one is primary
        print(f"count_tokens failed: {type(exc).__name__}", file=sys.stderr)
        return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", required=True)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--stdio")
    g.add_argument("--http")
    g.add_argument("--claude-config", help="server key in ~/.claude.json (read-only): url + headersHelper")
    ap.add_argument("--cwd")
    ap.add_argument("--bearer-env")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    if a.stdio:
        client = Stdio(a.stdio, a.cwd)
    else:
        headers: dict[str, str] = {}
        url = a.http
        if a.claude_config:
            cfg = json.loads(Path("~/.claude.json").expanduser().read_text())["mcpServers"][a.claude_config]
            url = cfg["url"]
            helper = cfg.get("headersHelper")
            if helper:
                headers = json.loads(subprocess.run([helper], capture_output=True, text=True).stdout or "{}")
        if a.bearer_env:
            headers["Authorization"] = f"Bearer {os.environ[a.bearer_env]}"
        client = Http(url, headers)

    try:
        init, tools = list_tools(client)
    finally:
        client.close()

    rows = []
    for t in tools:
        rows.append({
            "name": t["name"],
            "description_chars": len(t.get("description", "")),
            "input_schema_bytes": len(json.dumps(t.get("inputSchema", {}), separators=(",", ":"))),
            "output_schema_bytes": len(json.dumps(t.get("outputSchema", {}), separators=(",", ":"))),
            "annotations": t.get("annotations", {}),
            "total_bytes": len(json.dumps(t, separators=(",", ":"))),
        })
    with_tools, without, one = count_tokens(tools), count_tokens(None), count_tokens(tools[:1])
    result = {
        "server": a.name,
        "server_info": init.get("serverInfo"),
        "protocol": init.get("protocolVersion"),
        "instructions_chars": len(init.get("instructions", "") or ""),
        "tool_count": len(tools),
        "tool_names": [t["name"] for t in tools],
        "tools_list_bytes": len(json.dumps(tools, separators=(",", ":"))),
        "definition_tokens_count_tokens": (with_tools - without) if with_tools and without else None,
        "preamble_tokens": (one - without) - 0 if one and without else None,  # includes tool 1 itself
        "per_tool": rows,
    }
    Path(a.out).write_text(json.dumps(result, indent=1) + "\n")
    print(f"{a.name}: {len(tools)} tools, {result['tools_list_bytes']} bytes, "
          f"{result['definition_tokens_count_tokens']} tokens (count_tokens)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
