#!/usr/bin/env python3
"""
HyperDX/ClickStack MCP + REST client for scripted / no-MCP callers.

Stdlib only — no dependencies. Talks to the built-in ClickStack MCP server
(POST <base>/api/mcp, stateless Streamable HTTP, JSON-RPC over SSE) and the
external REST v2 API (<base>/api/api/v2/...) with the same bearer token.
Complements the interactive `mcp__hyperdx-{local,prod}__clickstack_*` tools
registered in Claude Code — use this when there's no MCP client (a script,
a subagent, a cron job) or when a deterministic, scriptable call is easier.

Usage:
  python3 hdx.py local tools
  python3 hdx.py local schema clickstack_timeseries
  python3 hdx.py local instructions
  python3 hdx.py local call clickstack_list_sources '{}'
  python3 hdx.py local call clickstack_describe_source '{"sourceId": "..."}' --raw
  python3 hdx.py local prompt query_guide
  python3 hdx.py local rest GET /sources
  python3 hdx.py local rest POST /dashboards '{"name": "..."}'
  python3 hdx.py local link 66f1... --last 24h

  python3 hdx.py prod tools   # fails soft with a setup hint until the
                               # hyperdx-agent key exists (op://vps/clickstack/*)
"""
import sys
import os
import json
import argparse
import subprocess
import time
import urllib.request
import urllib.error

LOCAL_ENV_FILE = os.path.expanduser("~/.config/hyperdx/local.env")
LOCAL_BASE = "http://localhost:7707"
PROD_BASE = "https://hyperdx.jkrumm.com"
PROD_KEY_REF = "op://vps/clickstack/AGENT_ACCESS_KEY"

PROD_HINT = (
    "could not resolve prod HyperDX access key ({}).\n"
    "  Run `make hyperdx-agent-setup` in vps, then add the ref to headless.refs."
)
LOCAL_HINT = (
    "no local HyperDX credentials at {}.\n"
    "  Run `make hyperdx-dev-bootstrap` in vps."
)


def _read_local_env() -> dict:
    if not os.path.isfile(LOCAL_ENV_FILE):
        return {}
    env = {}
    with open(LOCAL_ENV_FILE, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            env[key.strip()] = value.strip()
    return env


def _resolve_prod_key() -> str:
    override = os.environ.get("HYPERDX_PROD_ACCESS_KEY")
    if override:
        return override
    runner = "secrets-run" if _which("secrets-run") else None
    try:
        if runner:
            r = subprocess.run(["secrets-run", "read", PROD_KEY_REF],
                                capture_output=True, text=True, timeout=15)
        else:
            r = subprocess.run(["op", "read", "--account", "tkrumm", PROD_KEY_REF],
                                capture_output=True, text=True, timeout=15)
        if r.returncode == 0:
            return r.stdout.strip()
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass
    return ""


def _which(cmd: str) -> bool:
    for d in os.environ.get("PATH", "").split(os.pathsep):
        if os.path.isfile(os.path.join(d, cmd)):
            return True
    return False


def resolve_env(env: str) -> tuple:
    """Returns (base_url, bearer_key) or raises SystemExit with a one-line hint."""
    if env == "local":
        key = _read_local_env().get("HYPERDX_LOCAL_ACCESS_KEY", "")
        if not key:
            sys.exit(f"ERROR: {LOCAL_HINT.format(LOCAL_ENV_FILE)}")
        return LOCAL_BASE, key
    if env == "prod":
        key = _resolve_prod_key()
        if not key:
            sys.exit(f"ERROR: {PROD_HINT.format(PROD_KEY_REF)}")
        return PROD_BASE, key
    sys.exit(f"ERROR: unknown env '{env}' — expected local or prod")


def _http_post(url: str, key: str, body: dict, accept: str, _retried: bool = False) -> bytes:
    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode("utf-8"),
        method="POST",
        headers={
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
            "Accept": accept,
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return resp.read()
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", errors="replace").strip()
        # The dev ClickStack MCP intermittently 400s an empty body when hit with
        # back-to-back requests (connection race, not a request-shape problem) —
        # one silent retry absorbs it instead of surfacing a flaky false error.
        if e.code == 400 and not detail and not _retried:
            time.sleep(0.3)
            return _http_post(url, key, body, accept, _retried=True)
        sys.exit(f"ERROR: HTTP {e.code} from {url}\n{detail}")
    except urllib.error.URLError as e:
        sys.exit(f"ERROR: transport failed reaching {url}: {e.reason}")
    except TimeoutError:
        sys.exit(f"ERROR: request to {url} timed out after 60s")


def _http_request(method: str, url: str, key: str, body=None) -> tuple:
    """REST v2 call. Returns (status, text)."""
    data = json.dumps(body).encode("utf-8") if body is not None else None
    headers = {"Authorization": f"Bearer {key}"}
    if data is not None:
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return resp.status, resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", errors="replace")
    except urllib.error.URLError as e:
        sys.exit(f"ERROR: transport failed reaching {url}: {e.reason}")


def _parse_sse_jsonrpc(raw: bytes, want_id) -> dict:
    """Parse `event: message\\ndata: {...}\\n\\n` framing (also accepts a bare
    JSON body, since a non-SSE JSON response is a valid fallback)."""
    text = raw.decode("utf-8", errors="replace")
    stripped = text.strip()
    if stripped.startswith("{"):
        return json.loads(stripped)
    for block in stripped.split("\n\n"):
        data_line = None
        for line in block.splitlines():
            if line.startswith("data:"):
                data_line = line[len("data:"):].strip()
        if data_line is None:
            continue
        try:
            msg = json.loads(data_line)
        except json.JSONDecodeError:
            continue
        if want_id is None or msg.get("id") == want_id:
            return msg
    sys.exit(f"ERROR: no JSON-RPC message with id={want_id} found in SSE response:\n{text[:500]}")


def rpc_call(base: str, key: str, method: str, params: dict) -> dict:
    req_id = int(time.time() * 1000) % 1_000_000
    body = {"jsonrpc": "2.0", "id": req_id, "method": method, "params": params}
    raw = _http_post(f"{base}/api/mcp", key, body, "application/json, text/event-stream")
    msg = _parse_sse_jsonrpc(raw, req_id)
    if "error" in msg:
        sys.exit(f"ERROR: {method} failed: {json.dumps(msg['error'])}")
    return msg.get("result", {})


def _print_tool_list(tools: list) -> None:
    for tool in tools:
        desc = (tool.get("description") or "").split(".")[0].strip()
        print(f"{tool['name']:<40} {desc}")


def cmd_tools(base: str, key: str, args) -> None:
    result = rpc_call(base, key, "tools/list", {})
    _print_tool_list(result.get("tools", []))
    print(f"\n(schema: hdx.py {args.env} schema <name>)")


def cmd_schema(base: str, key: str, args) -> None:
    result = rpc_call(base, key, "tools/list", {})
    tools = result.get("tools", [])
    if not args.tool:
        _print_tool_list(tools)
        return
    for tool in tools:
        if tool["name"] == args.tool:
            print(json.dumps(tool.get("inputSchema", {}), indent=2))
            desc = (tool.get("description") or "").strip()
            if desc:
                print()
                print(desc)
            return
    sys.exit(f"ERROR: no tool named '{args.tool}'")


def cmd_instructions(base: str, key: str, _args) -> None:
    result = rpc_call(base, key, "initialize", {
        "protocolVersion": "2024-11-05",
        "capabilities": {},
        "clientInfo": {"name": "hdx.py", "version": "1.0"},
    })
    print(result.get("instructions", ""))


def cmd_call(base: str, key: str, args) -> None:
    try:
        tool_args = json.loads(args.json_args) if args.json_args else {}
    except json.JSONDecodeError as e:
        sys.exit(f"ERROR: invalid JSON args: {e}")
    result = rpc_call(base, key, "tools/call", {"name": args.tool, "arguments": tool_args})
    if args.raw:
        print(json.dumps(result, indent=2))
        return
    for item in result.get("content", []):
        if item.get("type") != "text":
            print(json.dumps(item, indent=2))
            continue
        text = item["text"]
        try:
            print(json.dumps(json.loads(text), indent=2))
        except json.JSONDecodeError:
            print(text)


def cmd_prompt(base: str, key: str, args) -> None:
    result = rpc_call(base, key, "prompts/get", {"name": args.name})
    for message in result.get("messages", []):
        content = message.get("content", {})
        if content.get("type") == "text":
            print(content["text"])
        else:
            print(json.dumps(content, indent=2))


def cmd_rest(base: str, key: str, args) -> None:
    path = args.path if args.path.startswith("/") else f"/{args.path}"
    url = f"{base}/api/api/v2{path}"
    body = None
    if args.json_body:
        try:
            body = json.loads(args.json_body)
        except json.JSONDecodeError as e:
            sys.exit(f"ERROR: invalid JSON body: {e}")
    status, text = _http_request(args.method.upper(), url, key, body)
    try:
        print(json.dumps(json.loads(text), indent=2))
    except json.JSONDecodeError:
        print(text)
    if status >= 400:
        sys.exit(1)


LAST_TO_MS = {
    "1h": 3_600_000,
    "6h": 6 * 3_600_000,
    "24h": 24 * 3_600_000,
    "7d": 7 * 24 * 3_600_000,
    "30d": 30 * 24 * 3_600_000,
}


def cmd_link(base: str, _key: str, args) -> None:
    span_ms = LAST_TO_MS.get(args.last)
    if span_ms is None:
        sys.exit(f"ERROR: unsupported --last '{args.last}' — choose from {', '.join(LAST_TO_MS)}")
    now_ms = int(time.time() * 1000)
    from_ms = now_ms - span_ms
    print(f"{base}/dashboards/{args.dashboard_id}?from={from_ms}&to={now_ms}&kiosk=true")


def main() -> None:
    p = argparse.ArgumentParser(description="HyperDX/ClickStack MCP + REST client")
    p.add_argument("env", choices=["local", "prod"], help="Target environment")
    sub = p.add_subparsers(dest="command", required=True)

    sub.add_parser("tools", help="List MCP tool names + first sentence of description")

    schema_p = sub.add_parser("schema", help="Print a tool's inputSchema + full description (omit tool to list all)")
    schema_p.add_argument("tool", nargs="?", default=None, help="Tool name, e.g. clickstack_timeseries")

    sub.add_parser("instructions", help="Print the server's tool-selection instructions (from initialize)")

    call_p = sub.add_parser("call", help="Call an MCP tool (tools/call)")
    call_p.add_argument("tool", help="Tool name, e.g. clickstack_list_sources")
    call_p.add_argument("json_args", nargs="?", default="{}", help="JSON arguments object")
    call_p.add_argument("--raw", action="store_true", help="Print the full JSON-RPC result")

    prompt_p = sub.add_parser("prompt", help="Fetch an MCP prompt (prompts/get)")
    prompt_p.add_argument("name", help="Prompt name, e.g. query_guide")

    rest_p = sub.add_parser("rest", help="Call the REST v2 API")
    rest_p.add_argument("method", help="HTTP method, e.g. GET, POST, PATCH, DELETE")
    rest_p.add_argument("path", help="Path under /api/api/v2, e.g. /dashboards")
    rest_p.add_argument("json_body", nargs="?", default=None, help="JSON request body")

    link_p = sub.add_parser("link", help="Print a kiosk dashboard deep link")
    link_p.add_argument("dashboard_id")
    link_p.add_argument("--last", default="24h", choices=list(LAST_TO_MS))

    args = p.parse_args()
    base, key = resolve_env(args.env)

    handlers = {
        "tools": cmd_tools,
        "schema": cmd_schema,
        "instructions": cmd_instructions,
        "call": cmd_call,
        "prompt": cmd_prompt,
        "rest": cmd_rest,
        "link": cmd_link,
    }
    handlers[args.command](base, key, args)


if __name__ == "__main__":
    main()
