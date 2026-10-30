#!/usr/bin/env python3
"""Minimal MCP stdio client (newline-delimited JSON-RPC) for the scratch plannotator Inbox.

usage: mcp_call.py <cwd> list                 tool names
       mcp_call.py <cwd> size                 tool count and serialized size (context cost if registered as MCP)
       mcp_call.py <cwd> <tool> '<json-args>' one tool call; prints the structured result as JSON
Spawns `plannotator inbox mcp` through the isolated wrapper with <cwd> as the working folder (= the Inbox project).
"""
import json, os, subprocess, sys, time

D = os.path.dirname(os.path.abspath(__file__))
PN = os.path.join(D, "pn")


def run(cwd, method, params, timeout=70):
    p = subprocess.Popen([PN, "inbox", "mcp"], cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, text=True, bufsize=1)

    def send(msg):
        p.stdin.write(json.dumps(msg) + "\n"); p.stdin.flush()

    def recv(want):
        t0 = time.time()
        while time.time() - t0 < timeout:
            line = p.stdout.readline()
            if not line:
                break
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            if msg.get("id") == want:
                return msg
        return {"error": "no response"}

    send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "spike5", "version": "0"}}})
    recv(1)
    send({"jsonrpc": "2.0", "method": "notifications/initialized"})
    send({"jsonrpc": "2.0", "id": 2, "method": method, "params": params})
    res = recv(2)
    p.stdin.close()
    try:
        p.wait(timeout=5)
    except subprocess.TimeoutExpired:
        p.kill()
    return res


if __name__ == "__main__":
    cwd, what = sys.argv[1], sys.argv[2]
    if what in ("list", "size"):
        tools = run(cwd, "tools/list", {}).get("result", {}).get("tools", [])
        if what == "list":
            for t in tools:
                print(t["name"], "-", (t.get("description") or "")[:90].replace("\n", " "))
        else:
            raw = json.dumps(tools)
            print(json.dumps({"tools": len(tools), "bytes": len(raw), "approx_tokens": len(raw) // 4,
                              "per_tool": {t["name"]: len(json.dumps(t)) for t in tools}}))
    else:
        res = run(cwd, "tools/call", {"name": what, "arguments": json.loads(sys.argv[3]) if len(sys.argv) > 3 else {}})
        out = res.get("result", res)
        print(json.dumps(out.get("structuredContent", out), indent=1))
