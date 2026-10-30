#!/usr/bin/env python3
"""Spike 1: merge every results/*.json into one raw measurements file.

Usage: python3 -I 12-merge.py   -> ../measurements.json
The file keeps each experiment's JSON verbatim under its name, plus the environment (versions,
machine class, load) so the numbers can be read in context. Home paths are rewritten to ~.
"""
import glob
import json
import os
import platform
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from spike import sanitize  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
RES = os.path.normpath(os.path.join(HERE, "..", "results"))
HOME = os.path.expanduser("~")
out = {"spike": "01-beads", "as_of": "2026-10-22",
       "environment": {"os": platform.platform(), "arch": platform.machine(),
                       "cpus": os.cpu_count(),
                       "note": "Measured on the always-on dev host while other agent sessions were running: the 1-minute load average ranged about 10-35 on 12 cores. Wall-clock figures are inflated by that contention; CPU-seconds per operation (median_cpu_ms) are the load-independent number."},
       "experiments": {}}
for p in sorted(glob.glob(os.path.join(RES, "*.json"))):
    name = os.path.basename(p)[:-5]
    raw = open(p).read()
    clean = sanitize(raw)  # results written before a fix still get the same treatment
    if clean != raw:
        open(p, "w").write(clean)
    out["experiments"][name] = json.loads(clean)
out["experiments"]["topology-embedded"]["_note"] = ("ops_df.close (20 refused closes: the bench did not pass the claiming actor) and the single-case "
                                                    "external check in this first run are superseded by topology-embedded-rerun")
txt = sanitize(json.dumps(out, indent=1))
open(os.path.normpath(os.path.join(HERE, "..", "measurements.json")), "w").write(txt)
print(f"merged {len(out['experiments'])} experiments: {', '.join(out['experiments'])}")
