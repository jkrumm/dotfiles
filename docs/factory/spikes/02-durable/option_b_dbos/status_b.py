#!/usr/bin/env python3
"""Read-only dashboard derivation for option B, SQL only: no dbos import, no pickle. Opens the DBOS
system database mode=ro and works while the loop is dead. What it can and cannot derive:

  readable   workflow status/version/recovery attempts, the business state (set_event, portable
             JSON), the current step name, and durable timers: every DBOS.sleep row carries an
             absolute wake time (portable JSON)
  opaque     step outputs and workflow results (default serializer = pickle): PR number, deploy id
             ("opaque_outputs" counts them; a Python reader could unpickle, a TS dashboard cannot)
  invisible  a step that is in flight, and the decision wait itself: DBOS writes the `recv` row
             only when the wait ends, so while waiting the deadline is the newest pending
             DBOS.sleep row of the root workflow (the recv timeout), found by convention
  fragile    the child workflow is found by the id convention `<flow>:merge`; its steps and timers
             live in its own rows

Usage: status_b.py <sandbox-dir>   (prints JSON: one object per root workflow)
"""
import json
import sqlite3
import sys
import time
from pathlib import Path


def snapshot(db: Path) -> dict:
    c = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    c.row_factory = sqlite3.Row
    now, out = time.time(), {}
    for w in c.execute("SELECT * FROM workflow_status WHERE name='flow' ORDER BY created_at"):
        wid = w["workflow_uuid"]
        ev = lambda wf, key: next(iter(c.execute("SELECT value FROM workflow_events WHERE workflow_uuid=? AND key=?", (wf, key))), [None])[0]  # noqa: E731
        rows = lambda wf: c.execute("SELECT function_id, function_name, output, serialization FROM operation_outputs WHERE workflow_uuid=? ORDER BY function_id", (wf,)).fetchall()  # noqa: E731
        root, child = rows(wid), rows(f"{wid}:merge")
        state = json.loads(ev(wid, "state") or "null")
        if state == "slot_wait":  # inside the merge section the child's state is the interesting one
            state = json.loads(ev(f"{wid}:merge", "state") or "null") or state
        pending = lambda steps: [json.loads(s["output"]) - now for s in steps if s["function_name"] == "DBOS.sleep" and json.loads(s["output"]) > now]  # noqa: E731
        decision_wait = pending(root)[-1:] if state == "awaiting_decision" else []
        child_row = c.execute("SELECT status FROM workflow_status WHERE workflow_uuid=?", (f"{wid}:merge",)).fetchone()
        out[wid] = {
            "status": w["status"], "app_version": w["application_version"], "recovery_attempts": w["recovery_attempts"],
            "state": state, "current_step": (child or root)[-1]["function_name"] if (child or root) else None, "steps": len(root) + len(child),
            "decision_deadline_in_s": round(decision_wait[0], 1) if decision_wait else None,
            "timers_pending": [round(t, 1) for t in pending(child)],
            "merge_child": child_row["status"] if child_row else None,
            "opaque_outputs": sum(1 for s in root + child if s["serialization"] == "py_pickle"),
        }
    return out


if __name__ == "__main__":
    print(json.dumps(snapshot(Path(sys.argv[1]) / "dbos.sqlite")))
