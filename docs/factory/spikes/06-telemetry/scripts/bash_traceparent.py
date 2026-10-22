#!/usr/bin/env python3
"""What TRACEPARENT did the worker's Bash see, and which span does its span id belong to?

  python3 -I bash_traceparent.py <run-dir>...        (run_spike.sh output dirs)

Reads the probe's step-1 output (`TRACEPARENT_IN_BASH=...`) from claude.stream.jsonl (headless) or
pty-transcript.txt (interactive), then looks the span id up in the local ClickHouse. This is the
proof for two claims: without CLAUDE_CODE_PROPAGATE_TRACEPARENT the Bash subprocess just inherits
the spawner's value (the warden root span); with it, Bash gets the active tool.execution span.
Prints a markdown table; stdlib only.
"""

import json
import os
import re
import sys
import urllib.request

CH = os.environ.get("SPIKE_CH_URL", "http://localhost:8123/")
SEEN = re.compile(r"TRACEPARENT_IN_BASH=(00-[0-9a-f]{32}-[0-9a-f]{16}-[0-9a-f]{2}|unset)")


def ch(sql: str) -> list[dict]:
    req = urllib.request.Request(CH, data=f"{sql} FORMAT JSONEachRow".encode(), method="POST")
    with urllib.request.urlopen(req, timeout=30) as resp:
        return [json.loads(line) for line in resp.read().decode().splitlines() if line.strip()]


def main(dirs: list[str]) -> int:
    print("|run|worker|root span (warden)|span id Bash saw|that span is|same trace as warden root|")
    print("|-|-|-|-|-|-|")
    for d in dirs:
        warden = json.load(open(os.path.join(d, "warden.json")))
        label = os.path.basename(d.rstrip("/")).split("-")[0]
        text = ""
        for name in ("claude.stream.jsonl", "pty-transcript.txt"):
            p = os.path.join(d, name)
            if os.path.exists(p):
                text = open(p, encoding="utf-8", errors="replace").read()
                break
        # the echo appears in the tool result AND in the prompt echo; the value with a real id wins
        values = [m for m in SEEN.findall(text) if m != "unset"] or SEEN.findall(text)
        seen = values[0] if values else "(not captured)"
        kind = "interactive" if label == "I" else "headless -p"
        if seen.startswith("00-"):
            trace, span = seen.split("-")[1], seen.split("-")[2]
            rows = ch(f"SELECT SpanName FROM default.otel_traces WHERE TraceId = '{trace}' AND SpanId = '{span}' LIMIT 1")
            what = rows[0]["SpanName"] if rows else "no such span in that trace"
            if span == warden["span_id"]:
                what = "the warden root span itself (inherited, not injected)"
            print(f"|{label}|{kind}|{warden['span_id'][:8]}|{span[:8]}|{what}|{trace == warden['trace_id']}|")
        else:
            print(f"|{label}|{kind}|{warden['span_id'][:8]}|{seen}|-|-|")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
