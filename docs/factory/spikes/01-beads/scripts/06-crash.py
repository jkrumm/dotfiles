#!/usr/bin/env python3
"""Spike 1, steps 4 and 6: crash semantics of the mother loop, on beads and on the SQLite baseline.

Question: when a loop dies (kill -9) or freezes (SIGSTOP) mid-task, how long does the task stay
stranded, how does it come back, does a frozen-then-resumed worker learn it lost the task, and
do two loops racing on one queue ever double-claim?

Usage: python3 -I 06-crash.py beads embedded|shared
       python3 -I 06-crash.py sqlite
Uses mother.sh (the same 25-line loop for both backends). Writes results/crash-<name>.json.
Beads' lease TTL is fixed at 5 min (no flag, config key or API member), so a beads run takes
about 6 minutes; the baseline's TTL is the LEASE_TTL env (30 s here).
"""
import json
import os
import shutil
import signal
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from spike import *  # noqa: E402,F401,F403
import spike  # noqa: E402

KIND = sys.argv[1]
TOPO = sys.argv[2] if KIND == "beads" else "sqlite"
NAME = f"crash-{KIND}-{TOPO}" if KIND == "beads" else "crash-sqlite"
HERE = os.path.dirname(os.path.abspath(__file__))
MOTHER = os.path.join(HERE, "mother.sh")
LOG = f"{SPIKE}/logs/{NAME}.mother.log"
TTL_SQL = 30
OUT = {"backend": KIND, "topology": TOPO, "loadavg_at_start": loadavg()}
EXTRA = {"BEADS_DOLT_SERVER_PORT": "43308"} if TOPO == "shared" else {}

if KIND == "beads":
    ROOT = f"{SPIKE}/data/{TOPO}/crash"
    shutil.rmtree(ROOT, ignore_errors=True)
    os.makedirs(ROOT)
    git("init", "-q", ".", cwd=ROOT)
    open(f"{ROOT}/README.md", "w").write("crash\n")
    git("add", "-A", cwd=ROOT)
    git("commit", "-qm", "i", cwd=ROOT)
    flags = ["--skip-agents", "--skip-hooks"] + (["--shared-server"] if TOPO == "shared" else [])
    r = bd("init", "-p", "cr", "--non-interactive", "--quiet", *flags, cwd=ROOT, extra_env=EXTRA)
    assert r.rc == 0, r
    CLI, MENV = "bd", dict(EXTRA)
    CWD = ROOT

    def create(t):
        return ids_of(bd("create", t, "-t", "task", "--json", cwd=CWD, extra_env=EXTRA))

    def status_of(i):
        j = bd("show", i, "--json", cwd=CWD, extra_env=EXTRA).json()
        j = j[0] if isinstance(j, list) else j
        return (j or {}).get("status"), (j or {}).get("assignee")

    def reclaim():
        r = bd("reclaim", "--older-than", "1s", "--json", cwd=CWD, extra_env=EXTRA)
        return r

    def ready_ids():
        return {x["id"] for x in (bd("ready", "--json", "--limit", "0", cwd=CWD, extra_env=EXTRA).json() or [])}

    POLL = 10
else:
    ROOT = f"{SPIKE}/data/sqlite"
    shutil.rmtree(ROOT, ignore_errors=True)
    os.makedirs(ROOT)
    CLI = f"python3 {HERE}/sqlite_tasks.py"
    MENV = {"TASKS_DB": f"{ROOT}/tasks.db", "LEASE_TTL": str(TTL_SQL)}
    CWD = ROOT

    def sq(*a):
        return run(["python3", f"{HERE}/sqlite_tasks.py", *a], cwd=CWD, extra_env=MENV)

    def create(t):
        return sq("create", t, "--project", "cr").json()["id"]

    def status_of(i):
        j = sq("show", i).json()[0]
        return j["status"], j["assignee"]

    def reclaim():
        return sq("reclaim", "--older-than", "0")

    def ready_ids():
        return {x["id"] for x in sq("ready", "--json", "--limit", "0").json()}

    POLL = 1


def loop(name, work, hb, once, exit_on_lost=False):
    e = spike.env({**MENV, "TASKCLI": CLI, "WORK": str(work), "HB": str(hb), "LOG": LOG, **({"ONCE": "1"} if once else {}),
                   **({"EXIT_ON_LOST": "1"} if exit_on_lost else {})})
    return subprocess.Popen(["bash", MOTHER, name], cwd=CWD, env=e, start_new_session=True,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def log_lines():
    return [l.split() for l in open(LOG)] if os.path.exists(LOG) else []


def wait_for(cond, timeout, step=0.5):
    t = time.time()
    while time.time() - t < timeout:
        if cond():
            return True
        time.sleep(step)
    return False


open(LOG, "w").close()
tasks = [create(f"crash task {i}") for i in range(8)]
OUT["tasks_created"] = len(tasks)

# ---- K/Z: two long-running workers; alpha is killed, zed is frozen
alpha, zed = loop("alpha", 3600, 5, False), loop("zed", 3600, 5, False, exit_on_lost=True)
claimed = lambda who: [l[3] for l in log_lines() if l[1] == who and l[2] == "claimed"]
hbs = lambda who: [int(l[0]) for l in log_lines() if l[1] == who and l[2] == "hb"]
ok = wait_for(lambda: claimed("alpha") and claimed("zed") and len(hbs("alpha")) >= 2 and len(hbs("zed")) >= 2, 120)
OUT["two_workers_claimed_and_heartbeating"] = ok
X, Z = claimed("alpha")[0], claimed("zed")[0]
last_hb = max(hbs("alpha"))
t_kill = time.time()
os.killpg(alpha.pid, signal.SIGKILL)
os.killpg(zed.pid, signal.SIGSTOP)
OUT["seconds_between_last_alpha_heartbeat_and_kill"] = round(t_kill - last_hb, 1)
st = status_of(X)
OUT["right_after_kill"] = {"killed_worker_task": {"status": st[0], "assignee": st[1]},
                           "frozen_worker_task": dict(zip(("status", "assignee"), status_of(Z))),
                           "stranded_tasks_visible_in_ready": bool({X, Z} & ready_ids())}

# the reaper runs on its own timer from the moment of the kill, like a supervisor would
import threading
reclaimed_at, reaper_polls, stop_reaper = {}, [], threading.Event()


def reaper():
    while not stop_reaper.is_set() and time.time() - t_kill < 900:  # hang guard, not an agent budget
        r = reclaim()
        reaper_polls.append({"t": round(time.time() - t_kill, 1), "output": r.out.strip()[:60].replace("\n", " ")})
        for tid in (X, Z):
            if tid not in reclaimed_at and status_of(tid)[0] == "open":
                reclaimed_at[tid] = round(time.time() - t_kill, 1)
        if len(reclaimed_at) == 2:
            return
        stop_reaper.wait(POLL)


rt = threading.Thread(target=reaper)
rt.start()

# beta drains whatever is free while the two stranded tasks stay stranded
t0 = time.time()
beta = loop("beta", 2, 1, True)
beta.wait()
OUT["beta_drain_of_free_tasks_s"] = round(time.time() - t0, 1)
OUT["beta_closed_while_two_were_stranded"] = sum(1 for l in log_lines() if l[1] == "beta" and l[2] == "closed")
OUT["stranded_when_beta_went_idle"] = {"killed": status_of(X)[0], "frozen": status_of(Z)[0],
                                       "at_s_after_kill": round(time.time() - t_kill, 1)}
rt.join()
OUT["reclaim_seconds_after_kill"] = {"killed_worker_task": reclaimed_at.get(X), "frozen_worker_task": reclaimed_at.get(Z)}
OUT["reaper_poll_interval_s"] = POLL
OUT["reaper_polls_before_first_reclaim"] = [p for p in reaper_polls if "0" in p["output"] or "No " in p["output"] or p["output"] in ("", "[]")][:3]
OUT["reaper_polls_total"] = len(reaper_polls)

# frozen worker wakes up after its task was reclaimed: does it learn it lost the lease?
os.killpg(zed.pid, signal.SIGCONT)
lost = wait_for(lambda: any(l[1] == "zed" and l[2] == "lost-lease" for l in log_lines()), 40, 0.2)
OUT["resumed_zombie_learns_lease_is_gone"] = lost
try:
    os.killpg(zed.pid, signal.SIGKILL)
except (ProcessLookupError, PermissionError):
    pass

# a second pass closes the reclaimed tasks
t1 = time.time()
beta2 = loop("beta", 2, 1, True)
beta2.wait()
OUT["recovery_second_pass_s"] = round(time.time() - t1, 1)
OUT["both_recovered_tasks_closed"] = status_of(X)[0] == "closed" and status_of(Z)[0] == "closed"
OUT["total_s_kill_to_all_closed"] = round(time.time() - t_kill, 1)
OUT["all_8_closed"] = all(status_of(t)[0] == "closed" for t in tasks)

# ---- R: two loops racing on one queue
race_tasks = [create(f"race task {i}") for i in range(12)]
open(LOG, "w").close()
t0 = time.time()
a, b = loop("alpha", 2, 1, True), loop("beta", 2, 1, True)
a.wait()
b.wait()
L = log_lines()
claims = [l[3] for l in L if l[2] == "claimed"]
OUT["race_two_loops_12_tasks"] = {
    "drain_s": round(time.time() - t0, 1),
    "claims_total": len(claims), "distinct_tasks_claimed": len(set(claims)), "double_claims": len(claims) - len(set(claims)),
    "lost_claims_seen_by_loops": sum(1 for l in L if l[2] == "lost-claim"),
    "closed": sum(1 for l in L if l[2] == "closed"), "close_failed": sum(1 for l in L if l[2] == "close-failed"),
    "claims_by_worker": {w: sum(1 for l in L if l[1] == w and l[2] == "claimed") for w in ("alpha", "beta")},
    "all_12_closed": all(status_of(t)[0] == "closed" for t in race_tasks)}
OUT["loadavg_at_end"] = loadavg()
print(save(NAME, OUT))
print(json.dumps(OUT, indent=1)[:1500])
