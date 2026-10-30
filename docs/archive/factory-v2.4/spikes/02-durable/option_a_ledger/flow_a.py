#!/usr/bin/env python3
"""Option A: SQLite ledger + explicit statechart + hand-rolled timers, leases and idempotency keys.
Stdlib only. The loop is a level-triggered reconciler: every tick re-derives each flow's next move
from the ledger row plus what it observes outside (episode heartbeat, stub API), so recovery after
a crash is simply "tick again".

  new -> investigating -> awaiting_decision -> implementing -> slot_wait
      -> opening_pr -> deploying -> verifying -> fixed          (rejected / failed are terminal)

Mechanisms (each one is a few lines below):
  statechart + CAS   every transition is `UPDATE .. WHERE id=? AND rev=?` in one transaction
  idempotency        `operations` row written BEFORE the external call; outcome NULL = in doubt;
                     the call carries the op key as Idempotency-Key, so retrying an in-doubt op is safe
  durable timer      `retry_at` on the flow row (backoff); the tick skips the flow until it passes
  decision expiry    absolute `state_deadline` stored at the transition, never "now + 180 s at restart"
  lease              `slots` row (holder, lease_until); renewed on every tick while inside the section
  agent episodes     external; observed via heartbeat file; idle watchdog re-drives (resume by session)

Usage:
  flow_a.py run <sandbox> [--exit-when-idle]     the loop (kill -9 it freely)
  flow_a.py alert <sandbox> <flow_id>            intake: a new flow row (state=new)
  flow_a.py decide <sandbox> <flow_id> <approve|reject>   the owner's door: a decisions row
"""
from __future__ import annotations

import json
import os
import sqlite3
import sys
import time
import traceback
from pathlib import Path

sys.path.insert(0, os.environ.get("FLOW_COMMON") or str(Path(__file__).resolve().parent.parent / "common"))
from world import TERMINAL, Sandbox, api, audit, episode_state, evlog, first_live, kill_episode, launch_episode, write_final  # noqa: E402

SCHEMA = """
CREATE TABLE IF NOT EXISTS flows(
  id TEXT PRIMARY KEY, repo TEXT NOT NULL, service TEXT NOT NULL,
  state TEXT NOT NULL, rev INTEGER NOT NULL DEFAULT 0,
  retry_at REAL, attempts INTEGER NOT NULL DEFAULT 0,
  state_deadline REAL,
  decision TEXT, decided_by TEXT, pr_number INTEGER, green INTEGER NOT NULL DEFAULT 0,
  created_at REAL NOT NULL, updated_at REAL NOT NULL);
CREATE TABLE IF NOT EXISTS operations(
  op_key TEXT PRIMARY KEY, flow_id TEXT NOT NULL, kind TEXT NOT NULL,
  started_at REAL NOT NULL, outcome TEXT, receipt TEXT);
CREATE TABLE IF NOT EXISTS decisions(flow_id TEXT PRIMARY KEY, decision TEXT NOT NULL, decided_at REAL NOT NULL);
CREATE TABLE IF NOT EXISTS slots(repo TEXT PRIMARY KEY, holder TEXT NOT NULL, lease_until REAL NOT NULL);
CREATE TABLE IF NOT EXISTS transitions(
  id INTEGER PRIMARY KEY, flow_id TEXT NOT NULL, from_state TEXT, to_state TEXT NOT NULL, at REAL NOT NULL, note TEXT);
"""
SECTION = ("opening_pr", "deploying", "verifying")  # states that run inside the per-repo merge slot


def connect(sb: Sandbox, readonly: bool = False) -> sqlite3.Connection:
    if readonly:
        c = sqlite3.connect(f"file:{sb.root / 'ledger.db'}?mode=ro", uri=True)
    else:
        c = sqlite3.connect(sb.root / "ledger.db", timeout=5, isolation_level=None)
        c.execute("PRAGMA journal_mode=WAL")
        c.execute("PRAGMA synchronous=FULL")
        c.execute("PRAGMA busy_timeout=5000")
        c.executescript(SCHEMA)
    c.row_factory = sqlite3.Row
    return c


def move(c, f, to: str, note: str = "", also=(), **cols) -> bool:
    """Compare-and-set transition. Applies only if the row is still at the revision this pass read;
    `also` statements (e.g. an operation's outcome, a lease release) commit atomically with it."""
    sets = "".join(f", {k}=?" for k in cols)
    c.execute("BEGIN IMMEDIATE")
    try:
        cur = c.execute(f"UPDATE flows SET state=?, rev=rev+1, updated_at=?, retry_at=NULL, attempts=0{sets} WHERE id=? AND rev=?",
                        (to, time.time(), *cols.values(), f["id"], f["rev"]))
        if not cur.rowcount:
            c.execute("ROLLBACK")
            return False
        for sql, args in also:
            c.execute(sql, args)
        c.execute("INSERT INTO transitions(flow_id,from_state,to_state,at,note) VALUES (?,?,?,?,?)", (f["id"], f["state"], to, time.time(), note))
        c.execute("COMMIT")
        return True
    except Exception:
        c.execute("ROLLBACK")
        raise


def backoff(c, sb, f, why: str) -> None:
    """Durable timer: persist when this flow may act again; the tick skips it until then."""
    delay = min(sb.cfg["backoff_base_s"] * 2 ** f["attempts"], sb.cfg["backoff_cap_s"])
    c.execute("UPDATE flows SET attempts=attempts+1, retry_at=? WHERE id=? AND rev=?", (time.time() + delay, f["id"], f["rev"]))
    evlog(sb, "timer.set", flow=f["id"], why=why, delay_s=delay, due=time.time() + delay)


def hold_slot(c, sb, repo: str, holder: str) -> bool:
    """Acquire or renew the per-repo merge-slot lease: free, mine, or expired."""
    now = time.time()
    c.execute("BEGIN IMMEDIATE")
    row = c.execute("SELECT holder, lease_until FROM slots WHERE repo=?", (repo,)).fetchone()
    ok = row is None or row["holder"] == holder or row["lease_until"] < now
    if ok:
        c.execute("INSERT INTO slots(repo,holder,lease_until) VALUES (?,?,?) ON CONFLICT(repo) DO UPDATE SET holder=excluded.holder, lease_until=excluded.lease_until",
                  (repo, holder, now + sb.cfg["lease_ttl_s"]))
    c.execute("COMMIT")
    return ok


def drive_episode(c, sb, f, kind: str, to: str, **on_done) -> None:
    """Observe the external episode; launch, re-drive on idle, or collect the result."""
    st = episode_state(sb, f["id"], kind)
    if st["state"] == "absent":
        launch_episode(sb, f["id"], kind, 1)
    elif st["state"] == "idle":
        evlog(sb, "episode.redrive", flow=f["id"], ep=kind, attempt=st["attempt"] + 1, idle_s=st["idle_s"])
        kill_episode(sb, f["id"], kind)
        launch_episode(sb, f["id"], kind, st["attempt"] + 1)
    elif st["state"] == "done" and move(c, f, to, note=f"{kind} done", **on_done):
        evlog(sb, "step.done", flow=f["id"], step=kind)
        if to == "awaiting_decision":
            evlog(sb, "decision.wait_start", flow=f["id"], deadline=on_done["state_deadline"])


def h_new(c, sb, f):
    move(c, f, "investigating", note="alert intake")


def h_investigating(c, sb, f):
    drive_episode(c, sb, f, "investigate", "awaiting_decision", state_deadline=time.time() + sb.cfg["decision_expiry_s"])


def h_awaiting_decision(c, sb, f):
    d = c.execute("SELECT * FROM decisions WHERE flow_id=?", (f["id"],)).fetchone()
    now = time.time()
    if d and d["decided_at"] <= f["state_deadline"]:
        decision, by = d["decision"], "human"
    elif now >= f["state_deadline"]:
        decision, by = sb.cfg["default_decision"], "default"  # reversible default; a late human answer is ignored
    else:
        return
    if move(c, f, "implementing" if decision == "approve" else "rejected", note=f"{decision} by {by}", decision=decision, decided_by=by):
        evlog(sb, "decision.taken", flow=f["id"], decision=decision, by=by, late_s=round(now - f["state_deadline"], 2), human_late=bool(d and d["decided_at"] > f["state_deadline"]))


def h_implementing(c, sb, f):
    drive_episode(c, sb, f, "implement", "slot_wait")


def h_slot_wait(c, sb, f):
    if hold_slot(c, sb, f["repo"], f["id"]):
        move(c, f, "opening_pr", note="slot acquired")


def external_op(c, sb, f, kind: str, path: str, body: dict, to: str, **cols) -> None:
    """Intent first, call second, outcome + transition in one transaction. If the process dies
    anywhere in between, the row is still in this state with the op in doubt, and the retry
    reuses the same Idempotency-Key."""
    key = f"{f['id']}:{kind}"
    c.execute("INSERT OR IGNORE INTO operations(op_key,flow_id,kind,started_at) VALUES (?,?,?,?)", (key, f["id"], kind, time.time()))
    status, resp = api(sb, "POST", path, body, key=key if sb.cfg["idempotency"] else None)
    if status != 200:
        return backoff(c, sb, f, f"{kind} -> {status}")
    extra = {"pr_number": resp["id"]} if kind == "open_pr" else {}
    if move(c, f, to, note=f"{kind} ok", also=[("UPDATE operations SET outcome='ok', receipt=? WHERE op_key=?", (json.dumps(resp), key))], **extra, **cols):
        evlog(sb, "step.done", flow=f["id"], step=kind)


def h_opening_pr(c, sb, f):
    external_op(c, sb, f, "open_pr", "/pr", {"flow_id": f["id"], "repo": f["repo"]}, "deploying")


def h_deploying(c, sb, f):
    external_op(c, sb, f, "deploy", "/deploy", {"flow_id": f["id"], "repo": f["repo"], "service": f["service"]}, "verifying",
                state_deadline=time.time() + sb.cfg["verify_window_s"], green=0)


def h_verifying(c, sb, f):
    status, _ = api(sb, "GET", f"/health?service={f['service']}")
    green = f["green"] + 1 if status == 200 else 0
    release = [("DELETE FROM slots WHERE repo=? AND holder=?", (f["repo"], f["id"]))]
    if green >= sb.cfg["verify_green"]:
        audit(sb, "slot.exit", f["repo"], f["id"])  # audit before release: observed intervals never exceed lease intervals
        move(c, f, "fixed", note="verified", also=release)
    elif time.time() > f["state_deadline"]:
        audit(sb, "slot.exit", f["repo"], f["id"])
        move(c, f, "failed", note="verify window expired", also=release)
    else:
        c.execute("UPDATE flows SET green=? WHERE id=? AND rev=?", (green, f["id"], f["rev"]))


HANDLERS = {n[2:]: fn for n, fn in globals().items() if n.startswith("h_")}


def tick(c, sb) -> bool:
    """One reconcile pass. Returns True while any flow is non-terminal."""
    open_flows = c.execute(f"SELECT * FROM flows WHERE state NOT IN ({','.join('?' * len(TERMINAL))}) ORDER BY created_at", TERMINAL).fetchall()
    for f in open_flows:
        try:
            first_live(sb, f["id"], f["state"])
            if f["retry_at"]:
                if f["retry_at"] > time.time():
                    continue
                evlog(sb, "timer.fired", flow=f["id"], state=f["state"], late_s=round(time.time() - f["retry_at"], 2))
                c.execute("UPDATE flows SET retry_at=NULL WHERE id=? AND rev=?", (f["id"], f["rev"]))
            if f["state"] in SECTION:
                if not hold_slot(c, sb, f["repo"], f["id"]):  # lease lost while down: re-queue for the slot
                    move(c, f, "slot_wait", note="lease lost")
                    continue
                audit(sb, "slot.enter", f["repo"], f["id"])
            HANDLERS[f["state"]](c, sb, f)
        except Exception:
            evlog(sb, "error", flow=f["id"], tb=traceback.format_exc()[-600:])
    for f in c.execute(f"SELECT * FROM flows WHERE state IN ({','.join('?' * len(TERMINAL))})", TERMINAL).fetchall():
        write_final(sb, f["id"], f["state"], decision=f["decision"], decided_by=f["decided_by"])
    return bool(open_flows)


def main(argv: list[str]) -> None:
    cmd, sb = argv[0], Sandbox(argv[1])
    c = connect(sb)
    if cmd == "alert":
        fc = sb.flow_cfg(argv[2])
        c.execute("INSERT OR IGNORE INTO flows(id,repo,service,state,created_at,updated_at) VALUES (?,?,?,?,?,?)",
                  (fc["id"], fc["repo"], fc["service"], "new", time.time(), time.time()))
    elif cmd == "decide":
        c.execute("INSERT OR IGNORE INTO decisions(flow_id,decision,decided_at) VALUES (?,?,?)", (argv[2], argv[3], time.time()))
    elif cmd == "run":
        evlog(sb, "loop.start")
        while tick(c, sb) or "--exit-when-idle" not in argv:
            time.sleep(sb.cfg["tick_s"])


if __name__ == "__main__":
    main(sys.argv[1:])
