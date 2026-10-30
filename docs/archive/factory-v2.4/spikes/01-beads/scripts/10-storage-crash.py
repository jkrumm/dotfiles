#!/usr/bin/env python3
"""Spike 1, step 4 (storage layer): kill -9 during writes.

Question: does an abrupt kill leave the store corrupt, leave a stale lock, or lose an
acknowledged write? Embedded: SIGKILL the `bd create` process mid-write. Shared: SIGKILL the
always-on `dolt sql-server` under a stream of creates and time the recovery. SQLite baseline:
SIGKILL the CLI mid-transaction.

Usage: python3 -I 10-storage-crash.py embedded|shared|sqlite   Writes results/storage-crash-<kind>.json
"""
import json
import os
import random
import shutil
import signal
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from spike import *  # noqa: E402,F401,F403
import spike  # noqa: E402
from spike import Res  # noqa: E402

KIND = sys.argv[1]
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = {"kind": KIND, "loadavg_at_start": loadavg()}
random.seed(7)
EXTRA = {"BEADS_DOLT_SERVER_PORT": "43308"} if KIND == "shared" else {}


def dolt_pids():
    return [int(x) for x in run(["pgrep", "-f", f"{SPIKE}/bin/dolt sql-server"]).out.split()]


if KIND in ("embedded", "shared"):
    ROOT = f"{SPIKE}/data/{KIND}/kill"
    shutil.rmtree(ROOT, ignore_errors=True)
    os.makedirs(ROOT)
    git("init", "-q", ".", cwd=ROOT)
    open(f"{ROOT}/README.md", "w").write("k\n")
    git("add", "-A", cwd=ROOT)
    git("commit", "-qm", "i", cwd=ROOT)
    flags = ["--skip-agents", "--skip-hooks"] + (["--shared-server"] if KIND == "shared" else [])
    PREFIX = "kl" + os.urandom(2).hex()  # a re-init with a used prefix on the shared server is refused (project identity guard)
    assert bd("init", "-p", PREFIX, "--non-interactive", "--quiet", *flags, cwd=ROOT, extra_env=EXTRA).rc == 0

    def found():
        r = bd("list", "--label", "kill-test", "--json", "--limit", "0", "--status", "all", cwd=ROOT, extra_env=EXTRA)
        return r, {x["title"] for x in (r.json() or [])} if r.rc == 0 else None
else:
    ROOT = f"{SPIKE}/data/sqlite-kill"
    shutil.rmtree(ROOT, ignore_errors=True)
    os.makedirs(ROOT)
    MENV = {"TASKS_DB": f"{ROOT}/tasks.db"}
    run(["python3", f"{HERE}/sqlite_tasks.py", "ready"], cwd=ROOT, extra_env=MENV)  # create schema

    def found():
        t = time.perf_counter()
        c = __import__("sqlite3").connect(f"{ROOT}/tasks.db", timeout=30)
        titles = {x[0] for x in c.execute("SELECT title FROM tasks")}
        c.close()
        return Res(0, "", "", time.perf_counter() - t), titles

ack, killed_mid = set(), 0
recov = []
if KIND in ("embedded", "sqlite"):
    n = 10
    for i in range(n):
        title = f"kill-test {i}"
        if KIND == "embedded":
            cmd = ["bd", "create", title, "-t", "task", "-l", "kill-test", "--json"]
            lo, hi = 0.05, 1.3
            p = subprocess.Popen(cmd, cwd=ROOT, env=spike.env(EXTRA), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        else:
            # a writer looping committed inserts (the baseline CLI finishes in ~40 ms, too short to hit); each
            # commit is acknowledged on stdout before the next one starts
            lo, hi = 0.25, 0.6
            p = subprocess.Popen(["python3", f"{HERE}/sqlite_writer.py", str(i)], cwd=ROOT, env=spike.env(MENV),
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        time.sleep(random.uniform(lo, hi))
        if p.poll() is None:
            p.send_signal(signal.SIGKILL)
            killed_mid += 1
        o, e = p.communicate()
        if KIND == "sqlite":
            ack.update(l.strip() for l in o.splitlines() if l.strip())
        elif p.returncode == 0:
            ack.add(title)
        t = time.perf_counter()
        r, f = found()
        recov.append({"next_command_ok": r.rc == 0, "seconds": round(time.perf_counter() - t, 2),
                      "error": (r.err.strip()[:140] if r.rc else "")})
    r, f = found()
    OUT["rounds"] = n
    OUT["killed_before_exit"] = killed_mid
    OUT["acknowledged_creates"] = len(ack)
    OUT["found_after"] = len(f) if f is not None else None
    missing = sorted(ack - (f or set()))
    OUT["acknowledged_but_missing"] = {"count": len(missing), "first": missing[:5]}
    OUT["found_but_not_acknowledged"] = len((f or set()) - ack)
    OUT["next_command_after_kill"] = {"all_ok": all(x["next_command_ok"] for x in recov),
                                      "failures": [x for x in recov if not x["next_command_ok"]][:3],
                                      "median_s": sorted(x["seconds"] for x in recov)[len(recov) // 2]}
    if KIND == "embedded":
        d = bd("doctor", cwd=ROOT)
        OUT["bd_doctor"] = {"exit": d.rc, "tail": [l.strip() for l in (d.out + d.err).splitlines() if l.strip()][-6:]}
    else:
        c = __import__("sqlite3").connect(f"{ROOT}/tasks.db")
        OUT["sqlite_integrity_check"] = c.execute("PRAGMA integrity_check").fetchone()[0]
else:  # shared: kill the server under a write stream
    rounds = []
    for k in range(3):
        stop, acked, errs = threading.Event(), [], []
        n = [0]

        def writer():
            while not stop.is_set():
                n[0] += 1
                title = f"kill-test s{k}-{n[0]}"
                r = bd("create", title, "-t", "task", "-l", "kill-test", "--json", cwd=ROOT, extra_env=EXTRA)
                if r.rc == 0:
                    acked.append(title)
                else:
                    errs.append((time.time(), r.err.strip()[:160]))

        th = threading.Thread(target=writer)
        th.start()
        time.sleep(4)
        pids = dolt_pids()
        t_kill = time.time()
        for pid in pids:
            os.kill(pid, signal.SIGKILL)
        time.sleep(6)
        stop.set()
        th.join()
        # nothing restarts the server by itself: record what a plain command does, then restart it the way a
        # supervisor would (`bd dolt start`) and check that no acknowledged write was lost
        time.sleep(6)  # past the circuit breaker's 5 s cooldown
        r = bd("ready", "--json", cwd=ROOT, extra_env=EXTRA)
        plain = {"exit": r.rc, "error": r.err.strip().splitlines()[-1][:140] if r.err.strip() else ""}
        server_back = bool(dolt_pids())
        t0 = time.perf_counter()
        rs = bd("dolt", "start", cwd=ROOT, extra_env=EXTRA)
        restart_s = time.perf_counter() - t0
        t0, ready_after = time.perf_counter(), None
        while time.perf_counter() - t0 < 60:  # hang guard
            if bd("ready", "--json", cwd=ROOT, extra_env=EXTRA).rc == 0:
                ready_after = time.perf_counter() - t0
                break
            time.sleep(0.5)
        w = bd("create", f"kill-test s{k}-post", "-t", "task", "-l", "kill-test", "--json", cwd=ROOT, extra_env=EXTRA)
        r2, f = found()
        rec = {"round": k, "server_pids_killed": len(pids), "acknowledged_before_kill": len(acked),
               "writer_errors_after_kill": len(errs), "first_error": errs[0][1].splitlines()[0][:140] if errs else "",
               "plain_command_after_cooldown": plain, "server_restarted_by_bd_on_its_own": server_back,
               "bd_dolt_start": {"exit": rs.rc, "seconds": round(restart_s, 2)},
               "first_successful_read_after_start_s": round(ready_after, 2) if ready_after is not None else None,
               "first_write_after_restart_exit": w.rc}
        rec["acknowledged_but_missing"] = sorted(set(acked) - (f or set()))
        rec["found_total"] = len(f) if f is not None else None
        rounds.append(rec)
    OUT["rounds"] = rounds
OUT["loadavg_at_end"] = loadavg()
print(save(f"storage-crash-{KIND}", OUT))
print(json.dumps(OUT, indent=1)[:1800])
