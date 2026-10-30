#!/usr/bin/env python3
"""Spike 1, step 3 (tail): `bd serve` reads and claims, what Argo (or a mother) would call.

Question: how fast is the HTTP surface compared with forking `bd` per call, and is it complete
enough for the mother's loop (ready, claim, heartbeat, reap, close)? `bd serve` needs a Dolt
SQL server (it refuses an embedded workspace permanently), so this runs on the shared topology.

Usage: python3 -I 04-serve.py   (after 03-topologies.py shared). Writes results/serve.json.
"""
import http.client as httpc
import json
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
PORT = 43400
LOOPBACK = ".".join(["127", "0", "0", "1"])  # bd serve wants a numeric IP literal for --addr
OUT = {"loadavg_at_start": loadavg()}


def call(method, path, body=None):
    c = httpc.HTTPConnection("localhost", PORT, timeout=30)
    t = time.perf_counter()
    c.request(method, path, body=json.dumps(body) if body is not None else None, headers={"Content-Type": "application/json"})
    r = c.getresponse()
    data = r.read()
    dt = time.perf_counter() - t
    c.close()
    try:
        j = json.loads(data)
    except ValueError:
        j = None
    return r.status, j, dt, len(data)


def timed(label, method, path, body=None, n=20):
    ts, status, size = [], None, 0
    for _ in range(n):
        s, j, dt, sz = call(method, path, body)
        ts.append(dt)
        status, size = s, sz
    return {**stats(ts), "op": label, "status": status, "response_bytes": size}


log = open(f"{SPIKE}/logs/bd-serve.log", "w")
t0 = time.time()
srv = subprocess.Popen(["bd", "serve", "--addr", f"{LOOPBACK}:{PORT}"], cwd=CWD, env=spike.env(EXTRA), stdout=log, stderr=log,
                       start_new_session=True)
up = False
while time.time() - t0 < 60:
    try:
        s, _, _, _ = call("GET", "/healthz")
        if s == 200:
            up = True
            break
    except OSError:
        time.sleep(0.2)
OUT["serve_start_to_healthz_s"] = round(time.time() - t0, 2)
assert up, "bd serve did not come up"
OUT["context"] = (call("GET", "/v0/beads/context")[1] or {})
OUT["context"] = {k: (str(v).replace(SPIKE, "<spike>")[:80]) for k, v in OUT["context"].items()}

reads = [timed("GET /healthz", "GET", "/healthz"),
         timed("GET /v0/beads/ready?limit=100", "GET", "/v0/beads/ready?limit=100"),
         timed("GET /v0/beads/ready?limit=1", "GET", "/v0/beads/ready?limit=1"),
         timed("GET /v0/beads/stats", "GET", "/v0/beads/stats"),
         timed("GET /v0/beads/issues?limit=50", "GET", "/v0/beads/issues?limit=50")]
rows = (call("GET", "/v0/beads/ready?limit=1")[1] or {})
rows = rows.get("issues") or rows.get("items") or rows.get("records") or (rows if isinstance(rows, list) else [])
OUT["ready_response_shape"] = sorted((call("GET", "/v0/beads/ready?limit=1")[1] or {}).keys())[:12]
if rows:
    reads.append(timed("GET /v0/beads/issues/{id}", "GET", f"/v0/beads/issues/{rows[0]['id']}"))
OUT["http_reads"] = reads
cli, _ = series("CLI: bd ready --json", lambda i: bd("ready", "--json", "--limit", "100", cwd=CWD, extra_env=EXTRA))
OUT["cli_ready_same_moment"] = cli

# writes through HTTP: claimNext (atomic poll+claim) and close; a claim race gets a typed 409
ids = []
ts = []
for i in range(20):
    s, j, dt, _ = call("POST", "/v0/beads/issues:claimNext?exclude_type=epic&exclude_type=decision", {"actor": "http-w"})
    ts.append(dt)
    c = (j or {}).get("claimed") or (j or {}).get("issue") or {}
    if c.get("id"):
        ids.append(c["id"])
OUT["http_claimNext_x20"] = {**stats(ts), "claimed": len(ids), "first_response_keys": sorted((j or {}).keys())}
if ids:
    s, j, _, _ = call("POST", f"/v0/beads/issues/{ids[0]}:claim", {"actor": "someone-else"})
    OUT["claim_on_held_task"] = {"http_status": s, "code": (j or {}).get("code"), "assignee_in_problem": (j or {}).get("assignee")}
    s, j, _, _ = call("GET", f"/v0/beads/issues/{ids[0]}")
    OUT["lease_fields_present_on_claimed_issue"] = sorted(k for k in (j or {}) if "lease" in k or "heartbeat" in k)
ts = []
for tid in ids:
    s, j, dt, _ = call("POST", f"/v0/beads/issues/{tid}:close", {"actor": "http-w", "reason": "x"})
    ts.append(dt)
OUT["http_close_x%d" % len(ids)] = stats(ts)
# the same loop's other two verbs over HTTP
spec = open(f"{SPIKE}/meta/openapi.v0.yaml").read()
OUT["spec_has_heartbeat_endpoint"] = "heartbeat" in "\n".join(l for l in spec.splitlines() if l.startswith("  /v0"))
OUT["spec_has_reclaim_endpoint"] = "reclaim" in "\n".join(l for l in spec.splitlines() if l.startswith("  /v0"))
OUT["spec_paths"] = sum(1 for l in spec.splitlines() if l.startswith("  /v0") or l.startswith("  /healthz"))
s, j, dt, _ = call("GET", "/v0/beads/events?since=0&limit=5")
OUT["events_endpoint"] = {"status": s, "keys": sorted((j or {}).keys())[:8], "secs": round(dt, 3)}
srv.send_signal(signal.SIGTERM)
try:
    srv.wait(timeout=20)
except subprocess.TimeoutExpired:
    srv.kill()
OUT["loadavg_at_end"] = loadavg()
print(save("serve", OUT))
