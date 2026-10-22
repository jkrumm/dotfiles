#!/usr/bin/env python3
"""Spike 1, step 6: the same datasets and the same measurements on the SQLite baseline.

Question: what does the baseline (sqlite_tasks.py, 65 lines: tasks + deps tables, recursive-CTE
ready query, claim lease by conditional UPDATE, heartbeat, reclaim) cost per operation, does its
ready set equal the independent oracle on the same data, and how does the ready query scale?
One database holds every project, so a cross-project edge is an ordinary edge.

Usage: python3 -I 07-baseline-bench.py   Writes results/baseline.json.
"""
import json
import os
import random
import shutil
import sqlite3
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from spike import *  # noqa: E402,F401,F403

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import sqlite_tasks as st  # noqa: E402

ROOT = f"{SPIKE}/data/sqlite-bench"
shutil.rmtree(ROOT, ignore_errors=True)
os.makedirs(ROOT)
MENV = {"TASKS_DB": f"{ROOT}/tasks.db", "LEASE_TTL": "300"}
OUT = {"loadavg_at_start": loadavg(), "lines_of_code": sum(1 for _ in open(f"{HERE}/sqlite_tasks.py"))}


def sq(*a):
    return run(["python3", f"{HERE}/sqlite_tasks.py", *a], cwd=ROOT, extra_env=MENV)


tasks = load_dataset()
ids, creates = {}, []
t0 = time.perf_counter()
for t in tasks:
    args = ["create", t["title"], "--project", t["repo"], "--type", t["type"], "--priority", str(t["priority"])]
    if t["labels"]:
        args += ["--labels", ",".join(t["labels"])]
    if t["parent"]:
        args += ["--parent", ids[(t["repo"], t["parent"])]]
    r = sq(*args)
    creates.append(r.secs)
    ids[(t["repo"], t["key"])] = r.json()["id"]
t_create = time.perf_counter() - t0
t1, edges = time.perf_counter(), 0
for t in tasks:
    for d in t["deps"]:
        if d.startswith("external:"):
            _, proj, cap = d.split(":")
            target = next((x for x in tasks if x["repo"] == proj and f"export:{cap}" in x["labels"]), None)
            if target is None:
                continue
            dep_id = ids[(proj, target["key"])]
        else:
            dep_id = ids[(t["repo"], d)]
        sq("dep", "add", ids[(t["repo"], t["key"])], dep_id)
        edges += 1
for t in tasks:
    if t["defer"]:
        sqlite3.connect(MENV["TASKS_DB"]).execute("UPDATE tasks SET status='deferred' WHERE id=?", (ids[(t["repo"], t["key"])],)).connection.commit()
OUT["load"] = {"tasks": len(tasks), "create_cli_calls": stats(creates), "create_total_s": round(t_create, 2),
               "edges": edges, "dep_cli_calls_total_s": round(time.perf_counter() - t1, 2),
               "load_total_s": round(time.perf_counter() - t0, 2)}

# ready set vs the oracle, per project (one DB, cross-project edges are ordinary edges)
rows = sq("ready", "--json", "--limit", "0").json()
id2key = {v: k for k, v in ids.items()}
per = {}
for repo in ("df", "wo", "bu"):
    got = {id2key[r["id"]][1] for r in rows if r["project"] == repo}
    exp = oracle_ready(tasks, repo, parent_propagation=True, exclude_types=())
    per[repo] = {"ready_rows": len(got), "oracle_rows": len(exp), "match": got == exp,
                 "extra": sorted(got - exp)[:6], "missing": sorted(exp - got)[:6]}
OUT["ready_vs_oracle"] = per

# per-op latency through the CLI, median of 20 (wall and CPU), same shape as the beads series
new = [sq("create", f"bench {i}", "--project", "df", "--priority", "3").json()["id"] for i in range(20)]
ops = {}
ops["create"], _ = series("create", lambda i: sq("create", f"bench2 {i}", "--project", "df", "--priority", "3"))
ops["update_cas"], _ = series("update (CAS)", lambda i: sq("update", new[i], "--if-status", "open", "--status", "open", "-a", "x"))
ops["ready"], _ = series("ready", lambda i: sq("ready", "--json", "--limit", "0"))
ops["list"], _ = series("list", lambda i: sq("list"))
ops["show"], _ = series("show", lambda i: sq("show", new[i]))
ops["claim"], _ = series("claim", lambda i: sq("update", new[i], "--claim", "--actor", "bench"))
ops["heartbeat"], _ = series("heartbeat", lambda i: sq("heartbeat", new[i], "--actor", "bench"))
ops["close"], _ = series("close", lambda i: sq("close", new[i], "--actor", "bench"))
ops["floor_python_startup"], _ = series("floor: python3 -c pass", lambda i: run(["python3", "-c", "pass"]))
OUT["ops"] = ops

# in-process: the same SQL without a process per call (what warden would do as a library)
db = sqlite3.connect(MENV["TASKS_DB"])
db.row_factory = sqlite3.Row
t = time.perf_counter()
for _ in range(200):
    db.execute(st.READY.format(extra=""), (100,)).fetchall()
OUT["in_process_ready_query_ms"] = round((time.perf_counter() - t) / 200 * 1000, 2)

# scale: synthetic backlogs, ready query time (parent chains, 3 deps per ~10th task)
scale = {}
for n in (1000, 5000, 20000):
    p = f"{ROOT}/scale{n}.db"
    c = sqlite3.connect(p)
    c.executescript(st.SCHEMA)
    random.seed(n)
    rows_, deps_ = [], []
    for i in range(n):
        parent = f"t{random.randrange(0, i)}" if i and i % 7 else None
        rows_.append((f"t{i}", "s", f"task {i}", "task", 2, "closed" if random.random() < 0.6 else "open", parent, time.time() + i))
        if i > 10 and i % 10 == 0:
            deps_ += [(f"t{i}", f"t{random.randrange(0, i)}") for _ in range(3)]
    c.executemany("INSERT INTO tasks(id,project,title,type,priority,status,parent,created_at) VALUES(?,?,?,?,?,?,?,?)", rows_)
    c.executemany("INSERT OR IGNORE INTO task_deps VALUES(?,?)", deps_)
    c.commit()
    c.row_factory = sqlite3.Row
    t = time.perf_counter()
    for _ in range(20):
        res = c.execute(st.READY.format(extra=""), (100,)).fetchall()
    scale[str(n)] = {"ready_query_ms": round((time.perf_counter() - t) / 20 * 1000, 2), "rows": len(res),
                     "db_kb": os.path.getsize(p) // 1024}
OUT["scale_ready_query"] = scale
OUT["loadavg_at_end"] = loadavg()
print(save("baseline", OUT))
print(json.dumps({k: OUT[k] for k in ("load", "ready_vs_oracle", "in_process_ready_query_ms", "scale_ready_query")}, indent=1)[:2500])
