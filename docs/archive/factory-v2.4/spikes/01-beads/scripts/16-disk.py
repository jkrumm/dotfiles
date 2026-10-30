#!/usr/bin/env python3
"""Spike 1, step 3 (footprint): disk and history growth after the whole spike, per topology.
Usage: python3 -I 16-disk.py (last, once the other runs are done) -> results/disk.json"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from spike import *  # noqa: E402,F401,F403


def kb(p):
    return int(run(["du", "-sk", p]).out.split()[0]) if os.path.exists(p) else None


out = {"embedded": {}, "shared": {}, "sqlite_baseline": {}}
for name, prefix in (("dotfiles", "df"), ("weatherorb", "wo"), ("basalt-ui", "bu")):
    db = f"{SPIKE}/data/embedded/{name}/.beads/embeddeddolt/{prefix}"
    log = run(["dolt", "log", "--oneline"], cwd=db).out.splitlines() if os.path.isdir(db) else []
    n = len(log)
    out["embedded"][name] = {"dolt_commits": n, "db_kb": kb(db), "kb_per_commit": round(kb(db) / n, 1) if n else None}
base = f"{SPIKE}/home/.beads/shared-server/dolt"
for prefix in ("df", "wo", "bu"):
    db = f"{base}/{prefix}"
    log = run(["dolt", "log", "--oneline"], cwd=db).out.splitlines() if os.path.isdir(db) else []
    out["shared"][prefix] = {"dolt_commits": len(log), "db_kb": kb(db)}
out["shared"]["server_dir_kb_total"] = kb(f"{SPIKE}/home/.beads/shared-server")
out["sqlite_baseline"] = {"tasks_db_kb_210_tasks": kb(f"{SPIKE}/data/sqlite-bench/tasks.db"), "tasks_loaded": 210}
out["binaries_mb"] = {"bd": round(os.path.getsize(f"{SPIKE}/bin/bd") / 1048576), "dolt": round(os.path.getsize(f"{SPIKE}/bin/dolt") / 1048576)}
print(save("disk", out))
print(out)
