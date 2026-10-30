#!/usr/bin/env python3
"""Read-only dashboard derivation for option A. Opens the ledger mode=ro, imports nothing from the
flow, works while the loop is dead. Everything a dashboard needs is a column or one join.

Usage: status_a.py <sandbox-dir>   (prints JSON: one object per flow)
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
    for f in c.execute("SELECT * FROM flows ORDER BY created_at"):
        one = lambda sql, *a: c.execute(sql, a).fetchone()[0]  # noqa: E731
        out[f["id"]] = {
            "state": f["state"],
            "since_s": round(now - f["updated_at"], 1),
            "decision_expires_in_s": round(f["state_deadline"] - now, 1) if f["state"] == "awaiting_decision" else None,
            "timer_due_in_s": round(f["retry_at"] - now, 1) if f["retry_at"] else None,
            "backoff_attempts": f["attempts"],
            "decision": f["decision"], "decided_by": f["decided_by"], "pr": f["pr_number"],
            "holds_slot": bool(one("SELECT count(*) FROM slots WHERE repo=? AND holder=?", f["repo"], f["id"])),
            "ops_in_doubt": one("SELECT count(*) FROM operations WHERE flow_id=? AND outcome IS NULL", f["id"]),
            "transitions": one("SELECT count(*) FROM transitions WHERE flow_id=?", f["id"]),
        }
    return out


if __name__ == "__main__":
    print(json.dumps(snapshot(Path(sys.argv[1]) / "ledger.db")))
