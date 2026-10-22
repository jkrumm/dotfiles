#!/usr/bin/env python3
"""How many Claude Code spans would the last 7 days of sessions have produced? (Spike 6, step 6.)

Question: what volume does full Claude Code tracing add? The span count per session comes from the
measured trace shape (see REPORT.md): per user prompt one `claude_code.interaction`, per model
request one `claude_code.llm_request`, per tool call three spans (`tool`, `tool.blocked_on_user`,
`tool.execution`). This script counts those three things in the real transcripts and applies it.

  python3 -I session_volume.py [--days 7] [--out <dir>]

Reads ~/.claude/projects/**/*.jsonl (this machine only; the MacBook copy is not included), streams
each file once, never holds a transcript in memory, and writes session-volume.out.json/.md. Files
whose directory slug contains `spikes-06-telemetry` (this spike's own probes) are skipped.

Counting rules (transcript line = one content block of an API message):
  llm_requests = distinct assistant `message.id`
  tool_calls   = distinct `tool_use` ids
  interactions = `user` lines that carry a human prompt (no `tool_result`, not meta/sidechain)
"""

import argparse
import collections
import datetime as dt
import glob
import json
import os
import re
import statistics
import sys
import time

ROOT = os.path.expanduser("~/.claude/projects")
TS = re.compile(rb'"timestamp":"(\d{4}-\d\d-\d\d)T')
MSG_ID = re.compile(rb'"message":\{[^{}]*?"id":"(msg_[A-Za-z0-9_]+)"')
MSG_ID_FALLBACK = re.compile(rb'"id":"(msg_[A-Za-z0-9_]+)"')
TOOL_ID = re.compile(rb'"type":"tool_use","id":"(toolu_[A-Za-z0-9_]+)"')
TOOL_ID_ALT = re.compile(rb'"id":"(toolu_[A-Za-z0-9_]+)","name"')


def scan(path: str, cutoff: str) -> dict:
    llm: set[bytes] = set()
    tools: set[bytes] = set()
    interactions = 0
    per_day: dict[str, list[int]] = collections.defaultdict(lambda: [0, 0, 0])  # llm, tools, interactions
    with open(path, "rb") as f:
        for line in f:
            is_asst = b'"type":"assistant"' in line
            is_user = b'"type":"user"' in line
            if not (is_asst or is_user):
                continue
            m = TS.search(line)
            if not m:
                continue
            day = m.group(1).decode()
            if day < cutoff:
                continue
            if is_asst:
                mid = MSG_ID.search(line) or MSG_ID_FALLBACK.search(line)
                if mid and mid.group(1) not in llm:
                    llm.add(mid.group(1))
                    per_day[day][0] += 1
                for t in TOOL_ID.findall(line) + TOOL_ID_ALT.findall(line):
                    if t not in tools:
                        tools.add(t)
                        per_day[day][1] += 1
            elif b'"tool_use_id"' not in line and b'"isMeta":true' not in line and b'"isSidechain":true' not in line:
                interactions += 1
                per_day[day][2] += 1
    return {"llm": len(llm), "tools": len(tools), "interactions": interactions, "per_day": dict(per_day)}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--days", type=int, default=7)
    ap.add_argument("--out", default=os.path.dirname(os.path.abspath(__file__)))
    args = ap.parse_args()

    now = dt.datetime.now(dt.timezone.utc)
    cutoff = (now - dt.timedelta(days=args.days)).strftime("%Y-%m-%d")
    horizon = time.time() - args.days * 86400
    started = time.time()

    files = [
        p
        for p in glob.glob(os.path.join(ROOT, "*", "**", "*.jsonl"), recursive=True)
        if "spikes-06-telemetry" not in p and os.path.getmtime(p) >= horizon
    ]
    sessions: dict[str, dict] = {}
    daily: dict[str, dict] = collections.defaultdict(lambda: {"llm": 0, "tools": 0, "interactions": 0, "sessions": set()})
    for path in files:
        is_sub = "/subagents/" in path
        # a subagent's spans nest under its parent session's trace: group by the parent session dir
        sid = path.split("/subagents/")[0].removesuffix(".jsonl") if is_sub else path.removesuffix(".jsonl")
        r = scan(path, cutoff)
        s = sessions.setdefault(sid, {"llm": 0, "tools": 0, "interactions": 0, "subagent_files": 0})
        s["llm"] += r["llm"]
        s["tools"] += r["tools"]
        s["interactions"] += r["interactions"]
        s["subagent_files"] += 1 if is_sub else 0
        for day, (l, t, i) in r["per_day"].items():
            d = daily[day]
            d["llm"] += l
            d["tools"] += t
            d["interactions"] += i
            if not is_sub:
                d["sessions"].add(sid)

    def spans(llm: int, tools: int, inter: int) -> int:
        return inter + llm + 3 * tools

    per_session = sorted(spans(v["llm"], v["tools"], v["interactions"]) for v in sessions.values() if v["llm"])
    day_rows = []
    for day in sorted(daily):
        d = daily[day]
        day_rows.append(
            {
                "day": day,
                "sessions_active": len(d["sessions"]),
                "interactions": d["interactions"],
                "llm_requests": d["llm"],
                "tool_calls": d["tools"],
                "spans": spans(d["llm"], d["tools"], d["interactions"]),
            }
        )
    full_days = [r for r in day_rows if r["day"] != cutoff and r["day"] != now.strftime("%Y-%m-%d")]
    out = {
        "as_of_utc": now.strftime("%Y-%m-%dT%H:%MZ"),
        "window_days": args.days,
        "files_scanned": len(files),
        "sessions_with_model_calls": len(per_session),
        "spans_total": sum(per_session),
        "spans_per_session": {
            "median": statistics.median(per_session) if per_session else 0,
            "mean": round(statistics.fmean(per_session), 1) if per_session else 0,
            "p90": per_session[int(len(per_session) * 0.9)] if per_session else 0,
            "p99": per_session[int(len(per_session) * 0.99)] if per_session else 0,
            "max": per_session[-1] if per_session else 0,
        },
        "per_day": day_rows,
        "mean_spans_per_full_day": round(statistics.fmean(r["spans"] for r in full_days), 0) if full_days else None,
        "mean_sessions_per_full_day": round(statistics.fmean(r["sessions_active"] for r in full_days), 1) if full_days else None,
        "elapsed_s": round(time.time() - started, 1),
    }
    os.makedirs(args.out, exist_ok=True)
    with open(os.path.join(args.out, "session-volume.out.json"), "w", encoding="utf-8") as f:
        json.dump(out, f, indent=1, sort_keys=True)
        f.write("\n")
    lines = ["|day (UTC)|sessions active|interactions|llm requests|tool calls|spans|", "|-|-|-|-|-|-|"]
    lines += [
        f'|{r["day"]}|{r["sessions_active"]}|{r["interactions"]}|{r["llm_requests"]}|{r["tool_calls"]}|{r["spans"]}|'
        for r in day_rows
    ]
    with open(os.path.join(args.out, "session-volume.out.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    print(json.dumps({k: v for k, v in out.items() if k != "per_day"}, indent=1))
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
