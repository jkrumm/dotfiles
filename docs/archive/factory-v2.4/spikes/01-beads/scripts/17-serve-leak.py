#!/usr/bin/env python3
"""Spike 1, step 7 (process hygiene): does stopping `bd serve` leave a helper process behind?
Counts `bd db-proxy-child` processes before `bd serve`, while it runs, and after a graceful SIGTERM.
Usage: python3 -I 17-serve-leak.py (needs the shared server from 03-topologies.py shared) -> results/serve-leak.json"""
import os
import signal
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from spike import *  # noqa: E402,F401,F403
import spike  # noqa: E402

EXTRA = {"BEADS_DOLT_SERVER_PORT": "43308"}
CWD = f"{SPIKE}/data/shared/dotfiles"


def proxies():
    r = run(["pgrep", "-f", f"{SPIKE}/bin/bd db-proxy-child"])
    return [int(x) for x in r.out.split()]


for pid in proxies():
    os.kill(pid, signal.SIGKILL)
bd("dolt", "start", cwd=CWD, extra_env=EXTRA)
time.sleep(2)
out = {"proxy_children_before_serve": len(proxies())}
srv = subprocess.Popen(["bd", "serve", "--addr", f"{LOOPBACK}:43401"], cwd=CWD, env=spike.env(EXTRA),
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
time.sleep(5)
out["proxy_children_while_serve_runs"] = len(proxies())
srv.send_signal(signal.SIGTERM)
try:
    srv.wait(timeout=20)
    out["serve_exited_after_sigterm"] = True
except subprocess.TimeoutExpired:
    out["serve_exited_after_sigterm"] = False
time.sleep(3)
left = proxies()
out["proxy_children_after_serve_exit"] = len(left)
if left:
    r = run(["ps", "-o", "ppid=,rss=,command=", "-p", str(left[0])])
    ppid, rss, *cmd = r.out.split(None, 2)
    out["leftover"] = {"parent_pid": int(ppid), "rss_mb": round(int(rss) / 1024), "idle_timeout_flag": "--idle-timeout -1ns" in r.out}
for pid in left:
    os.kill(pid, signal.SIGKILL)
print(save("serve-leak", out))
print(out)
