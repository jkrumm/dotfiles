#!/usr/bin/env python3
"""Baseline gameday: a crashed, non-critical container against today's system.

Question: when a monitored, non-critical container goes down and stays down, does today's
system notice, page, heal and close it — and how long does each step take?

Fault: `docker stop glance` on the homelab (a dashboard; Kuma monitors "Glance - Docker" and
"Glance - HTTP"; nothing depends on it). `docker stop` marks the container manually stopped, so
Docker's restart policy will not bring it back: only the factory can.
Observation (every 15 s, read-only): container state over ssh; the live warden ledger
(~/.warden/warden.db, mode=ro) for events, items, transitions, dispatches and operations that
mention Glance after T0. If the container is not running at T0 + HEAL_WAIT_MIN, the script
restores it with `docker start glance` and keeps observing CLOSE_WAIT_MIN for closure.
Outputs: <run>.out.json (timeline + measures), <run>.out.md. Run: python3 -I baseline_gameday.py
"""
import json
import os
import sqlite3
import subprocess
import sys
import time
from datetime import datetime, timezone

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
from redact import redact  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
CONTAINER = "glance"
HOST = "homelab"
HEAL_WAIT_MIN = float(os.environ.get("HEAL_WAIT_MIN", 30))
CLOSE_WAIT_MIN = float(os.environ.get("CLOSE_WAIT_MIN", 15))
POLL_S = 15
RUN = "2026-10-22-glance"


def now():
    return datetime.now(timezone.utc)


def iso(d):
    return d.strftime("%Y-%m-%dT%H:%M:%SZ")


def container_state():
    r = subprocess.run(["ssh", HOST, f"docker inspect -f '{{{{.State.Status}}}} {{{{.State.StartedAt}}}}' {CONTAINER}"],
                       capture_output=True, text=True, timeout=30)
    return (r.stdout.strip().split(" ") + ["", ""])[:2] if r.returncode == 0 else ["ssh-error", ""]


def ledger(t0):
    db = sqlite3.connect("file:" + os.path.expanduser("~/.warden/warden.db") + "?mode=ro", uri=True, timeout=10)
    ev = db.execute("""select id, source, title, first_seen, resolved_at from events
                       where first_seen >= ? and (lower(title) like '%glance%' or lower(payload_json) like '%glance%')
                       order by first_seen""", (iso(t0),)).fetchall()
    ids = [e[0] for e in ev]
    items, trans, disp, ops = [], [], [], []
    if ids:
        q = ",".join("?" * len(ids))
        items = db.execute(f"select event_id, state, verb, close_reason, created_at, updated_at, duplicate_of, note from triage_items where event_id in ({q}) or duplicate_of in ({q})", ids + ids).fetchall()
        trans = db.execute(f"select event_id, from_state, to_state, at, note from item_transitions where event_id in ({q}) order by at", ids).fetchall()
        disp = db.execute(f"select id, tier, status, created_at, finished_at from dispatches where origin_event_id in ({q})", ids).fetchall()
        ops = db.execute(f"select op_id, kind, authorized_by, started_at, outcome, outcome_at from operations where event_id in ({q})", ids).fetchall()
    db.close()
    return {"events": ev, "items": items, "transitions": trans, "dispatches": disp, "operations": ops}


def main():
    start_state = container_state()
    if start_state[0] != "running":
        sys.exit(f"precondition failed: {CONTAINER} is {start_state}")
    t0 = now()
    r = subprocess.run(["ssh", HOST, f"docker stop {CONTAINER}"], capture_output=True, text=True, timeout=60)
    log = [{"t": iso(now()), "what": "fault injected: docker stop", "rc": r.returncode}]
    first = {}
    restored_at = None
    healed_by_factory_at = None
    deadline = HEAL_WAIT_MIN * 60
    snap = {}
    while True:
        el = (now() - t0).total_seconds()
        st = container_state()
        if st[0] == "running" and "running" not in first and restored_at is None:
            healed_by_factory_at = iso(now())
            first["running"] = el
            log.append({"t": iso(now()), "what": f"container running again (not by this script), StartedAt {st[1]}"})
        snap = ledger(t0)
        for key in ("events", "items", "transitions", "dispatches", "operations"):
            if snap[key] and key not in first:
                first[key] = el
                log.append({"t": iso(now()), "what": f"first {key[:-1]} seen", "n": len(snap[key])})
        if restored_at is None and healed_by_factory_at is None and el >= deadline:
            subprocess.run(["ssh", HOST, f"docker start {CONTAINER}"], capture_output=True, text=True, timeout=60)
            restored_at = iso(now())
            log.append({"t": restored_at, "what": "not healed: restored by the gameday script (docker start)"})
        end_ref = restored_at or healed_by_factory_at
        if end_ref:
            since_end = (now() - datetime.fromisoformat(end_ref.replace("Z", "+00:00"))).total_seconds()
            if since_end >= CLOSE_WAIT_MIN * 60:
                break
        time.sleep(POLL_S)

    def red(rows):
        return [[redact(str(c)) if isinstance(c, str) else c for c in row] for row in rows]

    final_state = container_state()
    out = {
        "run": RUN, "fault": f"docker stop {CONTAINER} on {HOST}", "t0": iso(t0),
        "heal_wait_min": HEAL_WAIT_MIN, "close_wait_min": CLOSE_WAIT_MIN,
        "healed_by_factory_at": healed_by_factory_at, "restored_by_script_at": restored_at,
        "seconds_to_first": first, "final_container_state": final_state[0],
        "ledger": {k: red(v) for k, v in snap.items()},
        "owner_facing": {
            "needs_decision_entries": sum(1 for t in snap["transitions"] if t[2] == "needs_decision"),
            "items_opened": len({i[0] for i in snap["items"]}),
        },
        "timeline": log,
    }
    json.dump(out, open(os.path.join(HERE, f"{RUN}.out.json"), "w"), indent=1)
    md = [f"# Baseline gameday {RUN}", "", f"Fault `{out['fault']}` at {out['t0']}. Healed by the factory: {healed_by_factory_at or 'no'}. Restored by the script: {restored_at or 'no'}.", "",
          f"Seconds to first: {json.dumps(first)}. Items opened: {out['owner_facing']['items_opened']}. needs_decision entries: {out['owner_facing']['needs_decision_entries']}. Final container state: {final_state[0]}.", "", "| t | what |", "|-|-|"]
    md += [f"| {e['t']} | {e['what']} |" for e in log]
    open(os.path.join(HERE, f"{RUN}.out.md"), "w").write("\n".join(md) + "\n")
    print("\n".join(md))


if __name__ == "__main__":
    main()
