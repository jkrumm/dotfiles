#!/usr/bin/env python3
"""Simulated external agent episode (stands in for an agent-gateway job or a herdr pane).

Runs `units` x `unit_s` seconds, touches a heartbeat file every second, checkpoints each finished
unit in session.json (resume by persisted session id) and writes result.json atomically. It is
started detached (own session) so it survives the loop process dying. A kill loses the in-flight
unit only; a re-driven attempt resumes after the last finished unit.

Usage: episode.py <episode-dir> <kind> <units> <unit_s> <attempt>
"""
import json
import os
import sys
import time
from pathlib import Path


def main(d: str, kind: str, units: int, unit_s: float, attempt: int) -> None:
    ep = Path(d)
    (ep / "pid").write_text(str(os.getpid()))
    session = ep / "session.json"
    done = json.loads(session.read_text())["completed"] if session.exists() else 0
    for unit in range(done + 1, units + 1):
        end = time.time() + unit_s
        while time.time() < end:
            (ep / "heartbeat").write_text(str(time.time()))
            time.sleep(min(1.0, max(0.0, end - time.time())))
        with open(ep / "progress.jsonl", "a") as f:
            f.write(json.dumps({"unit": unit, "attempt": attempt, "ts": time.time()}) + "\n")
        tmp = ep / "session.json.tmp"
        tmp.write_text(json.dumps({"completed": unit}))
        os.replace(tmp, session)
    tmp = ep / "result.json.tmp"
    tmp.write_text(json.dumps({"ok": True, "kind": kind, "units": units, "finished_attempt": attempt, "finished_at": time.time()}))
    os.replace(tmp, ep / "result.json")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], int(sys.argv[3]), float(sys.argv[4]), int(sys.argv[5]))
