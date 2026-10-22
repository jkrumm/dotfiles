#!/usr/bin/env python3
"""Real run-time distribution of agent-gateway jobs from the frozen snapshot (read-only).

How long do the jobs agents actually wait for? A shell tool that blocks in the foreground for at most
two minutes (Claude Code's default) only fits the tools whose run time stays under that.

  job_durations.py [snapshot.db]    # default: ~/.local/share/factory/snapshots/2026-10-22/agw-jobs.db
"""
import json
import sqlite3
import statistics
import sys
from pathlib import Path

db = Path(sys.argv[1] if len(sys.argv) > 1 else "~/.local/share/factory/snapshots/2026-10-22/agw-jobs.db").expanduser()
con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
rows = con.execute("SELECT tool, (finished_at - started_at) / 1000.0 FROM job_stats WHERE status = 'done' AND started_at IS NOT NULL AND finished_at IS NOT NULL").fetchall()
by: dict[str, list[float]] = {}
for tool, secs in rows:
    by.setdefault(tool, []).append(secs)
out = {}
print(f"{'tool':<12}{'n':>6}{'median s':>10}{'p90 s':>8}{'share >120 s':>14}")
for tool, v in sorted(by.items(), key=lambda kv: -len(kv[1])):
    v.sort()
    p90 = v[min(len(v) - 1, int(0.9 * len(v)))]
    over = sum(1 for x in v if x > 120) / len(v)
    out[tool] = {"n": len(v), "median_s": round(statistics.median(v), 1), "p90_s": round(p90, 1), "share_over_120s": round(over, 3)}
    print(f"{tool:<12}{len(v):>6}{statistics.median(v):>10.0f}{p90:>8.0f}{over:>14.0%}")
print(json.dumps({"source": "agw job_stats snapshot, status=done", "by_tool": out}), file=open(Path(__file__).resolve().parents[1] / "raw" / "agw-job-durations.json", "w"))
