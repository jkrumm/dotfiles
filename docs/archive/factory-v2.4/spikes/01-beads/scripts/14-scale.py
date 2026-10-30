#!/usr/bin/env python3
"""Spike 1, step 3 (scale probe): does `bd ready` hold up as the backlog grows?

Synthetic backlog, same generator as the baseline's scale test (07-baseline-bench.py): N tasks, 60 % closed,
a parent for six in seven, three blocking edges on every tenth. Loaded with one `bd import`, then the five
requested operations are timed (median of 10) at that size. Usage: python3 -I 14-scale.py embedded|shared N
Writes results/scale-<topology>-<N>.json.
"""
import json
import os
import random
import shutil
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from spike import *  # noqa: E402,F401,F403

TOPO, N = sys.argv[1], int(sys.argv[2])
EXTRA = {"BEADS_DOLT_SERVER_PORT": "43308"} if TOPO == "shared" else {}
ROOT = f"{SPIKE}/data/{TOPO}/scale{N}"
shutil.rmtree(ROOT, ignore_errors=True)
os.makedirs(ROOT)
git("init", "-q", ".", cwd=ROOT)
open(f"{ROOT}/README.md", "w").write("scale\n")
git("add", "-A", cwd=ROOT)
git("commit", "-qm", "i", cwd=ROOT)
prefix = f"s{N}{os.urandom(1).hex()}"
flags = ["--skip-agents", "--skip-hooks"] + (["--shared-server"] if TOPO == "shared" else [])
assert bd("init", "-p", prefix, "--non-interactive", "--quiet", *flags, cwd=ROOT, extra_env=EXTRA).rc == 0
random.seed(N)
now = "2026-10-22T08:00:00Z"
lines, ids = [], [f"{prefix}-{i:05d}" for i in range(N)]
for i in range(N):
    deps = []
    if i and i % 7:
        deps.append({"issue_id": ids[i], "depends_on_id": ids[random.randrange(0, i)], "type": "parent-child"})
    if i > 10 and i % 10 == 0:
        deps += [{"issue_id": ids[i], "depends_on_id": ids[random.randrange(0, i)], "type": "blocks"} for _ in range(3)]
    closed = random.random() < 0.6
    rec = {"_type": "issue", "id": ids[i], "title": f"synthetic task {i}", "status": "closed" if closed else "open",
           "priority": 2, "issue_type": "task", "created_at": now, "updated_at": now}
    if closed:
        rec["closed_at"] = now
    if deps:
        rec["dependencies"] = deps
    lines.append(json.dumps(rec))
path = f"{SPIKE}/data/scale-{TOPO}-{N}.jsonl"
open(path, "w").write("\n".join(lines) + "\n")
OUT = {"topology": TOPO, "tasks": N, "loadavg_at_start": loadavg()}
r = bd("import", path, cwd=ROOT, extra_env=EXTRA)
OUT["import"] = {"exit": r.rc, "seconds": round(r.secs, 1), "error": r.err.strip()[:200] if r.rc else ""}
rows = bd("ready", "--json", "--limit", "0", cwd=ROOT, extra_env=EXTRA).json() or []
OUT["ready_rows"] = len(rows)
OUT["db_kb"] = int(run(["du", "-sk", f"{ROOT}/.beads" if TOPO == "embedded" else f"{ISO}/.beads/shared-server"]).out.split()[0])
ops = {}
ops["ready"], _ = series("ready", lambda i: bd("ready", "--json", "--limit", "0", cwd=ROOT, extra_env=EXTRA), 10)
ops["ready_limit_1"], _ = series("ready --limit 1", lambda i: bd("ready", "--json", "--limit", "1", cwd=ROOT, extra_env=EXTRA), 10)
ops["create"], rs = series("create", lambda i: bd("create", f"probe {i}", "-t", "task", "--json", cwd=ROOT, extra_env=EXTRA), 10)
new = [ids_of(x) for x in rs]
ops["claim"], _ = series("claim", lambda i: bd("update", new[i], "--claim", "--actor", "p", "--json", cwd=ROOT, extra_env=EXTRA), 10)
ops["heartbeat"], _ = series("heartbeat", lambda i: bd("heartbeat", new[i], "--actor", "p", cwd=ROOT, extra_env=EXTRA), 10)
ops["close"], _ = series("close", lambda i: bd("close", new[i], "-r", "x", "--actor", "p", cwd=ROOT, extra_env=EXTRA), 10)
OUT["ops"] = ops
OUT["loadavg_at_end"] = loadavg()
print(save(f"scale-{TOPO}-{N}", OUT))
print(json.dumps({"import": OUT["import"], "ready_rows": OUT["ready_rows"], "db_kb": OUT["db_kb"],
                  **{k: (v["median_ms"], v.get("median_cpu_ms")) for k, v in ops.items()}}))
