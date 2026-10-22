"""Run one headless `claude -p` session under the Spike 4 lab config and reduce it to metrics.

Lab config (every flag verified against `claude --help` of the installed build):
  --setting-sources project      no user settings: no hooks, plugins, env block, output style
  --disable-slash-commands       no skills
  --strict-mcp-config + --mcp-config <file>   exactly one MCP server, or none
  --tools <set>                  "" (MCP only) | Bash (CLI) | ToolSearch (deferred MCP)
  --dangerously-skip-permissions the owner's own sessions run this way
  --no-session-persistence       no transcript under ~/.claude/projects (the measured runs lacked this flag: see the
                                 spike notes on usage-tracker ingesting them; stream-json is the record)
  --output-format stream-json --verbose   per-message usage, every tool call and result
  env CLAUDE_CODE_DISABLE_CLAUDE_MDS / _AUTO_MEMORY   no CLAUDE.md, no auto-memory
`--bare` is deliberately NOT used: it shortens MCP tool descriptions to their first paragraph, which
halves the measured definition cost of agent-gateway (9.4k vs 17.9k tokens) and would flatter MCP.

No turn limit and no wall-clock ceiling (rules/agent-limits.md): the only liveness rule is an idle
watchdog, no stdout line for IDLE_SECONDS means wedged, then the session is killed.
"""

from __future__ import annotations

import json
import os
import queue
import re
import signal
import subprocess
import sys
import threading
import time
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "evidence" / "lib"))
from lib_iu import CLAUDE, iu_env  # noqa: E402
from redact import redact  # noqa: E402

IDLE_SECONDS = 300
ANSWER_RE = re.compile(r"ANSWER:\s*(\{.*)", re.S)


@dataclass
class Session:
    cwd: Path
    prompt: str
    model: str
    tools: str                      # value for --tools ("" disables all built-ins)
    mcp_config: Path
    effort: str = "medium"
    append_system: str | None = None
    env: dict[str, str] = field(default_factory=dict)


@dataclass
class Raw:
    events: list[dict]
    wall_s: float
    returncode: int | None
    stderr: str
    idle_killed: bool


def build_command(s: Session) -> list[str]:
    cmd = [
        CLAUDE, "-p", "--output-format", "stream-json", "--verbose",
        "--dangerously-skip-permissions", "--no-session-persistence", "--setting-sources", "project", "--disable-slash-commands",
        "--strict-mcp-config", "--mcp-config", str(s.mcp_config),
        "--tools", s.tools, "--model", s.model, "--effort", s.effort,
    ]
    if s.append_system:
        cmd += ["--append-system-prompt", s.append_system]
    return cmd


def run_session(s: Session, raw_path: Path, secrets: list[str]) -> Raw:
    env = iu_env({"CLAUDE_CODE_DISABLE_CLAUDE_MDS": "1", "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1", **s.env})
    s.cwd.mkdir(parents=True, exist_ok=True)
    errfile = raw_path.with_suffix(".err")
    t0 = time.monotonic()
    with open(errfile, "w") as err:
        p = subprocess.Popen(build_command(s), stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=err,
                             text=True, env=env, cwd=s.cwd, start_new_session=True)
        assert p.stdin and p.stdout
        p.stdin.write(s.prompt)
        p.stdin.close()
        lines: queue.Queue[str | None] = queue.Queue()
        threading.Thread(target=lambda: ([lines.put(l) for l in p.stdout], lines.put(None)), daemon=True).start()
        events: list[dict] = []
        last, idle_killed = time.monotonic(), False
        while True:
            try:
                line = lines.get(timeout=5)
            except queue.Empty:
                if time.monotonic() - last > IDLE_SECONDS:
                    idle_killed = True
                    os.killpg(p.pid, signal.SIGTERM)
                    time.sleep(3)
                    if p.poll() is None:
                        os.killpg(p.pid, signal.SIGKILL)
                    break
                continue
            if line is None:
                break
            last = time.monotonic()
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                events.append({"type": "unparsed", "raw": line[:500]})
        rc = p.wait()
    wall = time.monotonic() - t0
    stderr = errfile.read_text(errors="replace")
    errfile.unlink(missing_ok=True)
    # Persist the raw stream redacted: exact secret values first, then the public-repo patterns.
    text = "\n".join(json.dumps(e, ensure_ascii=False) for e in events)
    for sec in secrets:
        if sec:
            text = text.replace(sec, "<scrubbed>")
    raw_path.write_text(redact(text) + "\n")
    return Raw(events, wall, rc, stderr, idle_killed)


def _flatten(content) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(c.get("text", "") for c in content if isinstance(c, dict) and c.get("type") == "text")
    return json.dumps(content)


def analyze(raw: Raw) -> dict:
    """Reduce a stream-json transcript to the per-run record."""
    usage_by_msg: dict[str, dict] = {}
    order: list[str] = []
    calls: list[dict] = []
    results: dict[str, dict] = {}
    init, final = {}, {}
    for e in raw.events:
        t = e.get("type")
        if t == "system" and e.get("subtype") == "init":
            init = e
        elif t == "assistant":
            m = e.get("message", {})
            mid = m.get("id") or f"anon-{len(order)}"
            if mid not in usage_by_msg:
                order.append(mid)
            usage_by_msg[mid] = m.get("usage", {})
            for b in m.get("content", []):
                if b.get("type") == "tool_use":
                    calls.append({"id": b["id"], "name": b["name"], "input": b.get("input", {})})
        elif t == "user":
            content = e.get("message", {}).get("content")
            for b in content if isinstance(content, list) else []:
                if isinstance(b, dict) and b.get("type") == "tool_result":
                    results[b["tool_use_id"]] = {"text": _flatten(b.get("content")), "is_error": bool(b.get("is_error"))}
        elif t == "result":
            final = e

    def tok(u: dict) -> tuple[int, int, int, int]:
        return (u.get("input_tokens", 0), u.get("cache_creation_input_tokens", 0),
                u.get("cache_read_input_tokens", 0), u.get("output_tokens", 0))

    per_msg = [tok(usage_by_msg[m]) for m in order]
    first = per_msg[0] if per_msg else (0, 0, 0, 0)
    for c in calls:
        r = results.get(c["id"], {})
        c["is_error"], c["result_chars"], c["result_head"] = r.get("is_error", False), len(r.get("text", "")), r.get("text", "")[:400]
        c["result_text"] = r.get("text", "")
    names = Counter(c["name"] for c in calls)
    bash_cmds = [c["input"].get("command", "") for c in calls if c["name"] == "Bash"]
    return {
        "init_tools": init.get("tools", []),
        "init_mcp": init.get("mcp_servers", []),
        "api_calls": len(order),
        "turn1_input_tokens": first[0] + first[1] + first[2],
        "input_tokens_fresh": sum(m[0] + m[1] for m in per_msg),
        "input_tokens_cache_read": sum(m[2] for m in per_msg),
        "input_tokens_total": sum(m[0] + m[1] + m[2] for m in per_msg),
        "output_tokens": sum(m[3] for m in per_msg),
        "tool_calls": len(calls),
        "tool_calls_by_name": dict(names),
        "tool_errors": sum(1 for c in calls if c["is_error"]),
        "discovery_calls": names.get("ToolSearch", 0) + sum(1 for b in bash_cmds if re.search(r"(^|\s)(--help|-h|help)(\s|$)", b)),
        "tool_result_chars": sum(c["result_chars"] for c in calls),
        "cost_usd": final.get("total_cost_usd"),
        "cc_duration_ms": final.get("duration_ms"),
        "cc_api_ms": final.get("duration_api_ms"),
        "result_subtype": final.get("subtype"),
        "is_error": final.get("is_error"),
        "final_text": final.get("result", "") if isinstance(final.get("result"), str) else "",
        "calls": calls,
        "wall_s": round(raw.wall_s, 2),
        "returncode": raw.returncode,
        "idle_killed": raw.idle_killed,
        "stderr_head": raw.stderr[:300],
    }


def extract_answer(text: str) -> dict | None:
    """The last `ANSWER: {json}` in the final text, or None."""
    hits = list(ANSWER_RE.finditer(text or ""))
    for m in reversed(hits):
        try:
            obj, _ = json.JSONDecoder().raw_decode(m.group(1))
            if isinstance(obj, dict):
                return obj
        except json.JSONDecodeError:
            continue
    return None
