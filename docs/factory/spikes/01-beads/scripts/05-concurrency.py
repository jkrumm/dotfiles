#!/usr/bin/env python3
"""Spike 1, step 5: concurrent writers, readers and claim races on one topology.

Question: what happens when two agents (or a mother plus a worker) use the same project
database at the same time: lost writes, lock errors, claim arbitration, and how it differs
between per-repo embedded (single-writer file lock) and the shared Dolt server.

Usage: python3 -I 05-concurrency.py embedded|shared   (after 03-topologies.py <same>)
Writes results/concurrency-<name>.json.
"""
import collections
import os
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from spike import *  # noqa: E402,F401,F403
import spike  # noqa: E402

TOPO = sys.argv[1] if len(sys.argv) > 1 else "embedded"
EXTRA = {"BEADS_DOLT_SERVER_PORT": "43308"} if TOPO == "shared" else {}
CWD = f"{SPIKE}/data/{TOPO}/dotfiles"
OUT = {"topology": TOPO, "loadavg_at_start": loadavg()}


def parallel(n, fn):
    barrier = threading.Barrier(n)
    res = [None] * n

    def w(k):
        barrier.wait()
        res[k] = fn(k)

    ts = [threading.Thread(target=w, args=(k,)) for k in range(n)]
    t0 = time.perf_counter()
    [t.start() for t in ts]
    [t.join() for t in ts]
    return res, time.perf_counter() - t0


def count_label(label):
    r = bd("list", "--label", label, "--json", "--limit", "0", "--status", "all", cwd=CWD, extra_env=EXTRA)
    return len(r.json() or [])


def errs(rows):
    c = collections.Counter()
    for rc, _, e in rows:
        if rc != 0:
            c[e.strip().splitlines()[0][:110] if e.strip() else f"rc={rc}"] += 1
    return dict(c)


# A) two concurrent writers, 25 creates each
def writer(k):
    rows = []
    for i in range(25):
        r = bd("create", f"conc w{k} {i}", "-t", "task", "-p", "4", "-l", "conc-a", "--json", cwd=CWD, extra_env=EXTRA)
        rows.append((r.rc, r.secs, r.err))
    return rows


rows, wall = parallel(2, writer)
flat = [x for r in rows for x in r]
ok = sum(1 for rc, _, _ in flat if rc == 0)
OUT["two_writers_25_creates_each"] = {"wall_s": round(wall, 1), "ok": ok, "failed": len(flat) - ok,
                                      "errors": errs(flat), "rows_found_in_db": count_label("conc-a"),
                                      "lost_acknowledged_writes": ok - count_label("conc-a"),
                                      "per_call": stats([s for _, s, _ in flat])}

# B) concurrent readers: 4 x 10 `bd ready`
def reader(k):
    rows = []
    for _ in range(10):
        r = bd("ready", "--json", "--limit", "0", cwd=CWD, extra_env=EXTRA)
        rows.append((r.rc, r.secs, r.err))
    return rows


rows, wall = parallel(4, reader)
flat = [x for r in rows for x in r]
OUT["four_readers_10_ready_each"] = {"wall_s": round(wall, 1), "failed": sum(1 for rc, _, _ in flat if rc),
                                     "errors": errs(flat), "per_call": stats([s for _, s, _ in flat])}

# C) a reader while a writer streams creates
def mixed(k):
    rows = []
    for i in range(15):
        if k == 0:
            r = bd("create", f"conc mixed {i}", "-t", "task", "-p", "4", "-l", "conc-c", "--json", cwd=CWD, extra_env=EXTRA)
        else:
            r = bd("ready", "--json", "--limit", "0", cwd=CWD, extra_env=EXTRA)
        rows.append((r.rc, r.secs, r.err))
    return rows


rows, wall = parallel(2, mixed)
OUT["one_writer_one_reader_15_each"] = {"wall_s": round(wall, 1),
                                        "writer": {"failed": sum(1 for rc, _, _ in rows[0] if rc), "stats": stats([s for _, s, _ in rows[0]])},
                                        "reader": {"failed": sum(1 for rc, _, _ in rows[1] if rc), "stats": stats([s for _, s, _ in rows[1]]),
                                                   "errors": errs(rows[1])}}

# D) claim race: two workers claim the same task at the same instant, 12 tasks
ids = [ids_of(bd("create", f"conc race {i}", "-t", "task", "-p", "4", "-l", "conc-d", "--json", cwd=CWD, extra_env=EXTRA))
       for i in range(12)]
outcomes, winners_consistent = collections.Counter(), 0
msgs = collections.Counter()
for tid in ids:
    procs = [subprocess.Popen(["bd", "update", tid, "--claim", "--actor", who, "--json"], cwd=CWD, env=spike.env(EXTRA),
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) for who in ("wA", "wB")]
    res = []
    for p, who in zip(procs, ("wA", "wB")):
        o, e = p.communicate()
        res.append((who, p.returncode, e.strip()))
    won = [w for w, rc, _ in res if rc == 0]
    outcomes[f"winners={len(won)}"] += 1
    for _, rc, e in res:
        if rc:
            msgs[(rc, e.splitlines()[0][:110] if e else "")] += 1
    holder = (bd("show", tid, "--json", cwd=CWD, extra_env=EXTRA).json() or [{}])
    holder = holder[0] if isinstance(holder, list) else holder
    if len(won) == 1 and holder.get("assignee") == won[0]:
        winners_consistent += 1
OUT["claim_race_12_tasks_2_workers"] = {"outcomes": dict(outcomes), "winner_matches_assignee": winners_consistent,
                                        "loser_exit_codes_and_messages": [{"exit": k[0], "message": k[1], "n": v} for k, v in msgs.items()]}
# E) fencing: can another actor close or steal a task someone else holds?
f = ids_of(bd("create", "conc fence", "-t", "task", "-l", "conc-e", "--json", cwd=CWD, extra_env=EXTRA))
bd("update", f, "--claim", "--actor", "owner", cwd=CWD, extra_env=EXTRA)
steal = bd("update", f, "--claim", "--actor", "intruder", cwd=CWD, extra_env=EXTRA)
close_other = bd("close", f, "-r", "x", "--actor", "intruder", cwd=CWD, extra_env=EXTRA)
holder = bd("show", f, "--json", cwd=CWD, extra_env=EXTRA).json()
holder = holder[0] if isinstance(holder, list) else (holder or {})
OUT["fencing_on_a_held_task"] = {"intruder_claim_exit": steal.rc, "intruder_close_exit": close_other.rc,
                                 "close_message": (close_other.err or close_other.out).strip().splitlines()[0][:150] if (close_other.err or close_other.out).strip() else "",
                                 "status_after": holder.get("status"), "assignee_after": holder.get("assignee")}
OUT["loadavg_at_end"] = loadavg()
print(save(f"concurrency-{TOPO}", OUT))
