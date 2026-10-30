#!/usr/bin/env python3
"""Option B: DBOS Transact (Python 3.3.0) on SQLite, same flow as option A.

DBOS gives: workflow replay from checkpointed steps, `DBOS.sleep` (durable timer), `DBOS.recv`
with a timeout recorded as an absolute wake time (await-decision), partitioned queues
(per-repo merge slot) and workflow IDs as idempotency keys for intake. It does not give:
idempotency for calls to external APIs (the step may run again after a crash, so the call
carries a key), liveness for external agent episodes (observer step + heartbeat file here),
a lease with expiry (the queue slot has none), or a default value on timeout (recv returns None).

  flow:           investigate episode -> recv(decision, timeout) -> implement episode -> merge_section
  merge_section:  (child, partition key = repo, concurrency 1) open_pr -> deploy (+backoff) -> verify

Usage:
  flow_b.py run <sandbox>                      the loop process (kill -9 it freely)
  flow_b.py alert <sandbox> <flow_id>          intake: enqueue the flow with workflow id = flow id
  flow_b.py decide <sandbox> <flow_id> <approve|reject>   the owner's door: DBOSClient.send
  flow_b.py set-latest <sandbox> <version>     operator rescue (see test g in the harness)
"""
from __future__ import annotations

import os
import sqlite3
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, os.environ.get("FLOW_COMMON") or str(Path(__file__).resolve().parent.parent / "common"))
from world import Sandbox, api, audit, episode_state, evlog, first_live, kill_episode, launch_episode, write_final  # noqa: E402
from dbos import DBOS, DBOSClient, DBOSConfig, WorkflowSerializationFormat  # noqa: E402

SB = Sandbox(sys.argv[2])
CFG = SB.cfg
DB_URL = f"sqlite:///{SB.root / 'dbos.sqlite'}"
PORTABLE = WorkflowSerializationFormat.PORTABLE  # JSON events a non-Python dashboard can read


# ---- steps (at-least-once: a crash after the effect but before the checkpoint re-runs them) ----

@DBOS.step()
def start_episode(flow_id: str, kind: str, attempt: int) -> None:
    first_live(SB, flow_id, f"start_episode:{kind}")
    launch_episode(SB, flow_id, kind, attempt)


@DBOS.step()
def wait_episode(flow_id: str, kind: str) -> dict:
    """Observer step: poll the external episode until it is done or idle. Re-executing it after a
    crash only re-attaches to the same episode; the idle watchdog lives here."""
    first_live(SB, flow_id, f"wait_episode:{kind}")
    while True:
        st = episode_state(SB, flow_id, kind)
        if st["state"] == "done":
            return {"state": "done"}
        if st["state"] == "idle":
            evlog(SB, "episode.redrive", flow=flow_id, ep=kind, attempt=st["attempt"] + 1, idle_s=st["idle_s"])
            kill_episode(SB, flow_id, kind)
            return {"state": "idle"}
        time.sleep(CFG["tick_s"])


@DBOS.step()
def mark_decision_wait(flow_id: str) -> float:
    first_live(SB, flow_id, "decision")
    deadline = time.time() + CFG["decision_expiry_s"]
    evlog(SB, "decision.wait_start", flow=flow_id, deadline=deadline)
    return deadline


@DBOS.step()
def log_decision(flow_id: str, decision: str, by: str, deadline: float) -> None:
    evlog(SB, "decision.taken", flow=flow_id, decision=decision, by=by, late_s=round(time.time() - deadline, 2))


@DBOS.step()
def call_api(flow_id: str, kind: str, path: str, body: dict) -> dict:
    first_live(SB, flow_id, kind)
    status, resp = api(SB, "POST", path, body, key=f"{flow_id}:{kind}" if CFG["idempotency"] else None)
    if status == 200:
        evlog(SB, "step.done", flow=flow_id, step=kind)
    return {"status": status, "body": resp}


@DBOS.step()
def mark_timer(flow_id: str, why: str, delay: float) -> float:
    due = time.time() + delay
    evlog(SB, "timer.set", flow=flow_id, why=why, delay_s=delay, due=due)
    return due


@DBOS.step()
def mark_fired(flow_id: str, due: float) -> None:
    evlog(SB, "timer.fired", flow=flow_id, late_s=round(time.time() - due, 2))


@DBOS.step()
def verify(flow_id: str, service: str) -> dict:
    first_live(SB, flow_id, "verify")
    green, end = 0, time.time() + CFG["verify_window_s"]
    while time.time() < end:
        green = green + 1 if api(SB, "GET", f"/health?service={service}")[0] == 200 else 0
        if green >= CFG["verify_green"]:
            return {"ok": True}
        time.sleep(CFG["tick_s"])
    return {"ok": False}


@DBOS.step()
def audit_step(kind: str, repo: str, flow_id: str) -> None:
    audit(SB, kind, repo, flow_id)


@DBOS.step()
def finish(flow_id: str, state: str, decision: str, by: str) -> None:
    write_final(SB, flow_id, state, decision=decision, decided_by=by)


# ---- workflows ----

def run_episode(flow_id: str, kind: str) -> None:
    attempt = 1
    while True:
        start_episode(flow_id, kind, attempt)
        if wait_episode(flow_id, kind)["state"] == "done":
            return
        attempt += 1  # idle -> the watchdog killed it; re-drive resumes from the persisted session


def retrying(flow_id: str, kind: str, path: str, body: dict) -> dict:
    """Call an external API; on a transient failure sleep durably (backoff) and try again."""
    attempt = 0
    while True:
        out = call_api(flow_id, kind, path, body)
        if out["status"] == 200:
            return out["body"]
        delay = min(CFG["backoff_base_s"] * 2 ** attempt, CFG["backoff_cap_s"])
        attempt += 1
        due = mark_timer(flow_id, f"{kind} -> {out['status']}", delay)
        DBOS.sleep(delay)
        mark_fired(flow_id, due)


@DBOS.workflow(name="merge_section")
def merge_section(flow_id: str, repo: str, service: str) -> dict:
    first_live(SB, flow_id, "merge_section")
    DBOS.set_event("state", "opening_pr", serialization_type=PORTABLE)
    audit_step("slot.enter", repo, flow_id)
    pr = retrying(flow_id, "open_pr", "/pr", {"flow_id": flow_id, "repo": repo})
    DBOS.set_event("state", "deploying", serialization_type=PORTABLE)
    dep = retrying(flow_id, "deploy", "/deploy", {"flow_id": flow_id, "repo": repo, "service": service})
    DBOS.set_event("state", "verifying", serialization_type=PORTABLE)
    ok = verify(flow_id, service)["ok"]
    audit_step("slot.exit", repo, flow_id)
    return {"pr": pr["id"], "deploy": dep["id"], "verified": ok}


@DBOS.workflow(name="flow")
def flow(flow_id: str, repo: str, service: str) -> dict:
    first_live(SB, flow_id, "flow")
    DBOS.set_event("state", "investigating", serialization_type=PORTABLE)
    run_episode(flow_id, "investigate")
    DBOS.set_event("state", "awaiting_decision", serialization_type=PORTABLE)
    deadline = mark_decision_wait(flow_id)
    msg = DBOS.recv("decision", timeout_seconds=CFG["decision_expiry_s"])
    if msg is not None and CFG.get("strict_late") and msg["at"] > deadline:
        msg = None  # answered after the expiry: the default stands (same contract as option A)
    decision, by = (msg["decision"], "human") if msg is not None else (CFG["default_decision"], "default")  # recv gives None on timeout
    log_decision(flow_id, decision, by, deadline)
    if decision != "approve":
        DBOS.set_event("state", "rejected", serialization_type=PORTABLE)
        finish(flow_id, "rejected", decision, by)
        return {"state": "rejected"}
    DBOS.set_event("state", "implementing", serialization_type=PORTABLE)
    run_episode(flow_id, "implement")
    DBOS.set_event("state", "slot_wait", serialization_type=PORTABLE)
    child = DBOS.enqueue_workflow_with_options(
        {"workflow_name": "merge_section", "queue_name": "merge", "queue_partition_key": repo, "workflow_id": f"{flow_id}:merge"},
        flow_id, repo, service)
    result = child.get_result()
    state = "fixed" if result["verified"] else "failed"
    DBOS.set_event("state", state, serialization_type=PORTABLE)
    finish(flow_id, state, decision, by)
    return {"state": state, **result}


def main(argv: list[str]) -> None:
    cmd = argv[0]
    if cmd == "run":
        sqlite3.connect(SB.root / "dbos.sqlite").execute("PRAGMA journal_mode=WAL")  # DBOS sets no WAL itself
        config: DBOSConfig = {"name": "flowspike", "system_database_url": DB_URL, "log_level": "WARNING"}
        if CFG.get("pin_version"):
            config["application_version"] = "pinned-v1"  # else: hash of the workflow source
        DBOS(config=config)
        DBOS.launch()
        DBOS.register_queue("flows")
        DBOS.register_queue("merge", partition_concurrency=1)  # one running merge section per repo
        evlog(SB, "loop.ready")
        threading.Event().wait()
    elif cmd == "alert":
        fc = SB.flow_cfg(argv[2])
        DBOSClient(system_database_url=DB_URL).enqueue(
            {"workflow_name": "flow", "queue_name": "flows", "workflow_id": fc["id"]}, fc["id"], fc["repo"], fc["service"])
    elif cmd == "set-latest":  # operator rescue after a redeploy: make an older application version the dequeuing one again
        DBOSClient(system_database_url=DB_URL).set_latest_application_version(argv[2])
    elif cmd == "decide":
        DBOSClient(system_database_url=DB_URL).send(argv[2], {"decision": argv[3], "at": time.time()}, topic="decision", idempotency_key=f"{argv[2]}:decision")


if __name__ == "__main__":
    main(sys.argv[1:])
