#!/usr/bin/env python3
"""Spike 1, step 4 (detail): exit codes of the compare-and-set paths, on both topologies.
Question: when is it exit 13 (stale guard) and when exit 1 (refusal), and does a CAS claim take a lease?
Usage: python3 -I 15-cas-probe.py   (after 03-topologies.py embedded and shared) -> results/cas-probe.json"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from spike import *  # noqa: E402,F401,F403

out = {}
for topo in ("embedded", "shared"):
    extra = {"BEADS_DOLT_SERVER_PORT": "43308"} if topo == "shared" else {}
    cwd = f"{SPIKE}/data/{topo}/dotfiles"
    t = ids_of(bd("create", "cas probe", "-t", "task", "--json", cwd=cwd, extra_env=extra))
    code = lambda *a: bd("update", t, *a, cwd=cwd, extra_env=extra).rc
    r = {"guard_mismatch_if_status_closed_on_open_task": code("--if-status", "closed", "-p", "1"),
         "guard_mismatch_if_assignee_nobody": code("--if-assignee", "nobody", "-p", "2"),
         "guard_matches": code("--if-status", "open", "-p", "1"),
         "cas_claim_status_and_assignee": code("--if-status", "open", "-s", "in_progress", "-a", "w1")}
    second = bd("update", t, "--if-status", "open", "-s", "in_progress", "-a", "w2", cwd=cwd, extra_env=extra)
    r["second_cas_claimer_exit"] = second.rc
    r["second_cas_claimer_message"] = (second.err or second.out).strip().splitlines()[1][:150] if len((second.err or second.out).strip().splitlines()) > 1 else (second.err or second.out).strip()[:150]
    j = bd("show", t, "--json", cwd=cwd, extra_env=extra).json()
    j = j[0] if isinstance(j, list) else j
    r["cas_claimed_task_has_lease"] = bool(j.get("lease_expires_at"))
    r["heartbeat_on_cas_claimed_task_exit"] = bd("heartbeat", t, "--actor", "w1", cwd=cwd, extra_env=extra).rc
    out[topo] = r
print(save("cas-probe", out))
print(out)
