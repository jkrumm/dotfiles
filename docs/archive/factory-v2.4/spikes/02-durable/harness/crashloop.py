#!/usr/bin/env python3
"""Crash-loop drill (extra to tests a..h): the loop process is killed N times in quick succession,
as launchd KeepAlive would after a bad deploy or a full disk, while a flow is mid-episode. DBOS
counts every recovery dispatch against `max_recovery_attempts` (default 100) and dead-letters the
workflow when it is exceeded; the ledger has no such counter. To show the mechanism in a minute the
limit is lowered to 3 in a modified copy of the option B source; fast-mode timings are used.
Then the operator rescue is tried: DBOSClient.resume_workflow.

Usage: crashloop.py   (writes results/crashloop.json)
"""
import json
import sqlite3
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from killtest import CODE, FIXED, FLOW, PY, HarnessTimeout, Run  # noqa: E402
from redact import redact  # noqa: E402

KILLS = 6
LIMIT = 3


def drill(opt: str) -> dict:
    r = Run(opt, "x_crashloop", 0, fast=True)
    f = r.flows[0]
    flow_file, env = FLOW[opt], {}
    if opt == "b":
        src = FLOW["b"].read_text()
        marker = '@DBOS.workflow(name="flow")'
        assert marker in src
        flow_file = r.root / "flow_b_limit.py"
        flow_file.write_text(src.replace(marker, f'@DBOS.workflow(name="flow", max_recovery_attempts={LIMIT})', 1))
        env = {"FLOW_COMMON": str(CODE / "common")}
    out: dict = {"option": opt, "kills": KILLS, "recovery_limit_b": LIMIT if opt == "b" else None}
    try:
        r.start_stub()
        r.start_loop(flow_file=flow_file, env=env)
        r.alert(f)
        r.auto_approve(f)
        r.wait_units(f, "investigate", 1)
        for _ in range(KILLS):
            r.kill_loop("crash loop")
            r.sleep(0.5)
            r.start_loop(flow_file=flow_file, env=env, label="restart")
            r.sleep(1.5)
        try:
            r.wait_done(timeout=60)
            out["completed_without_operator"] = True
        except HarnessTimeout:
            out["completed_without_operator"] = False
        if opt == "b":
            c = sqlite3.connect(f"file:{r.root / 'dbos.sqlite'}?mode=ro", uri=True)
            out["engine_status"], out["recovery_attempts"] = c.execute("SELECT status, recovery_attempts FROM workflow_status WHERE name='flow'").fetchone()
            if not out["completed_without_operator"]:
                from dbos import DBOSClient  # noqa: PLC0415
                t0 = time.time()
                DBOSClient(system_database_url=f"sqlite:///{r.root / 'dbos.sqlite'}").resume_workflow(f)
                try:
                    r.wait_done(timeout=120)
                    out["completed_after_resume_workflow"] = True
                    out["resume_to_done_s"] = round(time.time() - t0, 1)
                except HarnessTimeout:
                    out["completed_after_resume_workflow"] = False
        c = r.sql("SELECT (SELECT count(*) FROM prs WHERE flow_id=?), (SELECT count(*) FROM deployments WHERE flow_id=?)", f, f)[0]
        out["prs"], out["deploys"] = c
    finally:
        r.cleanup()
    return out


if __name__ == "__main__":
    res = {"expected_when_completed": FIXED, "drills": [drill("a"), drill("b")]}
    dest = CODE / "results" / "crashloop.json"
    dest.write_text(redact(json.dumps(res, indent=1)))
    print(json.dumps(res, indent=1))
