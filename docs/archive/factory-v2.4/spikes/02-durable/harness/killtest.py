#!/usr/bin/env python3
"""Kill-test harness for spike 2 (durable execution): option A (SQLite ledger) vs option B (DBOS).

One run = a fresh sandbox, a stub external API (survives every kill, like GitHub does), a loop
process (the thing we kill -9), detached agent episodes, and a scripted scenario. Metrics come from
independent ground truth: the stub's call log (duplicates are counted there, not in the flow's own
bookkeeping), the episode directories, and the flows' structured event log.

Tests (each >= 5 runs per option; seeds are shared across options so runs pair up):
  happy      no kill: nominal timeline
  a          kill -9 the loop during the external implement episode
  b          kill -9 between open_pr committing at the stub and the flow recording it
  b_nokey    control for b: same kill, no Idempotency-Key (proves the zero in b is the key's doing)
  b_deploy   like b, on the deploy call
  c1..c5     kill -9 the loop during the decision wait:
             c1 owner decides while down, restart before expiry   c2 no decision, restart before expiry
             c3 down across the expiry, no decision               c4 decided before expiry, down across it
             c5 decision arrives AFTER expiry while still down    c5s = c5 with option B's strict rule
  d          kill the external episode itself (as an OpenCode restart would); loop stays up
  e          "machine reboot": kill the loop AND every episode at a different phase per run, restart the loop only
  f          two flows on one repo; kill the loop inside a deploy backoff timer while holding the merge slot
  h          chaos: three kill -9s at random instants (loop alone or whole machine), random outages
  g          redeploy: kill, restart the loop from a source file that differs by one comment line
  g_pinned   g with DBOS application_version pinned (option B only)
  g_break    pinned version + an incompatible change (a new step ahead of recorded ones) (option B only)

Usage:
  killtest.py run-one <a|b> <test> <idx> [--fast]
  killtest.py batch --options a,b --tests a,b,... --runs 5 [--parallel N] [--fast]
  killtest.py collect [--fast]
"""
from __future__ import annotations

import argparse
import json
import os
import random
import shutil
import signal
import sqlite3
import statistics
import subprocess
import sys
import threading
import time
from pathlib import Path

CODE = Path(__file__).resolve().parent.parent
SCRATCH = Path(os.environ.get("SPIKE_SCRATCH") or Path.home() / ".local/share/factory/spikes/02-durable")
PY = os.environ.get("SPIKE_PY") or str(SCRATCH / "venv/bin/python")
FLOW = {"a": CODE / "option_a_ledger/flow_a.py", "b": CODE / "option_b_dbos/flow_b.py"}
STATUS = {"a": CODE / "option_a_ledger/status_a.py", "b": CODE / "option_b_dbos/status_b.py"}
DBFILE = {"a": "ledger.db", "b": "dbos.sqlite"}
sys.path.insert(0, str(CODE.parent.parent / "evidence" / "lib"))
from redact import redact  # noqa: E402

FIXED = {"state": "fixed", "prs": 1, "deploys": 1}
REJECTED = {"state": "rejected", "prs": 0, "deploys": 0}
PHASES = ["investigate", "decision", "implement", "deploy_backoff", "verify"]  # test e, by run index


class HarnessTimeout(Exception):
    pass


def build_cfg(test: str, idx: int, fast: bool) -> dict:
    drng = random.Random(f"dur-{idx}-{fast}")  # episode durations depend on idx only: runs pair across tests/options
    units = 5 if fast else 12
    ep = lambda: {"units": units, "unit_s": drng.choice([1.0, 1.5]) if fast else float(drng.randint(5, 10))}  # noqa: E731  60..120 s
    flows = [{"id": f"{test}-{idx}", "repo": f"repo-{test}-{idx}", "service": f"svc-{test}-{idx}", "episode": {"investigate": ep(), "implement": ep()}}]
    if test == "f":  # two flows contend for one repo's merge slot; Y reaches it a few seconds after X
        base = {"investigate": {"units": units, "unit_s": 1.0 if fast else 5.0}, "implement": {"units": units, "unit_s": 1.0 if fast else 5.0}}
        slow = {"investigate": base["investigate"], "implement": {"units": units, "unit_s": 1.4 if fast else 5.5}}
        flows = [{"id": f"f-{idx}-x", "repo": f"repo-f-{idx}", "service": f"svc-f-{idx}-x", "episode": base},
                 {"id": f"f-{idx}-y", "repo": f"repo-f-{idx}", "service": f"svc-f-{idx}-y", "episode": slow}]
    delay = 2 if fast else 4
    return {
        "idle_limit_s": 4 if fast else 15, "tick_s": 0.5 if fast else 1.0, "decision_expiry_s": 15 if fast else 180,
        "default_decision": "approve", "backoff_base_s": 1 if fast else 5, "backoff_cap_s": 4 if fast else 30,
        "lease_ttl_s": 10 if fast else 30, "verify_green": 3, "verify_window_s": 30 if fast else 60,
        "idempotency": test != "b_nokey", "strict_late": test == "c5s", "pin_version": test in ("g_pinned", "g_break"),
        "stub": {"pr_delay_s": delay if test in ("b", "b_nokey") else 0, "deploy_delay_s": delay if test == "b_deploy" else 0,
                 "deploy_fail_first": 2, "warmup_s": 1 if fast else 2},
        "flows": flows,
    }


class Run:
    def __init__(self, opt: str, test: str, idx: int, fast: bool):
        self.opt, self.test, self.idx, self.fast = opt, test, idx, fast
        self.root = SCRATCH / ("runs-fast" if fast else "runs") / opt / test / str(idx)
        shutil.rmtree(self.root, ignore_errors=True)
        self.root.mkdir(parents=True)
        self.rng = random.Random(f"{test}-{idx}-{fast}")  # scenario randomness: identical for both options
        self.cfg = build_cfg(test, idx, fast)
        (self.root / "run.json").write_text(json.dumps(self.cfg))
        self.flows = [f["id"] for f in self.cfg["flows"]]
        self.units = self.cfg["flows"][0]["episode"]["implement"]["units"]
        self.cap = 240 if fast else 1500  # harness safety net only; flows have no such cap
        self.marks: dict = {}
        self.loops: list[dict] = []
        self.snaps: dict = {}
        self.proc: subprocess.Popen | None = None
        self.stub: subprocess.Popen | None = None
        self.notes: list[str] = []
        self.marks["load1_start"] = round(os.getloadavg()[0], 1)

    # ---- observation ----
    def events(self) -> list[dict]:
        out = []
        try:
            for line in (self.root / "events.jsonl").read_text().splitlines():
                try:
                    out.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
        except FileNotFoundError:
            pass
        return out

    def find(self, kind: str, flow: str | None = None, after: float = 0.0) -> dict | None:
        return next((e for e in self.events() if e["kind"] == kind and (flow is None or e.get("flow") == flow) and e["ts"] > after), None)

    def sql(self, query: str, *args):
        c = sqlite3.connect(f"file:{self.root / 'stub.db'}?mode=ro", uri=True)
        try:
            return c.execute(query, args).fetchall()
        finally:
            c.close()

    def wait_for(self, fn, what: str, timeout: float | None = None, poll: float = 0.1):
        end = time.time() + (timeout or self.cap)
        while time.time() < end:
            got = fn()
            if got:
                return got
            time.sleep(poll)
        raise HarnessTimeout(what)

    def wait_event(self, kind: str, flow: str, after: float = 0.0, timeout: float | None = None) -> dict:
        return self.wait_for(lambda: self.find(kind, flow, after), f"event {kind} {flow}", timeout)

    def units_done(self, flow: str, kind: str) -> int:
        p = self.root / "episodes" / f"{flow}-{kind}" / "progress.jsonl"
        return len(p.read_text().splitlines()) if p.exists() else 0

    def wait_units(self, flow: str, kind: str, n: int) -> None:
        self.wait_for(lambda: self.units_done(flow, kind) >= n, f"{flow} {kind} units>={n}")

    def into_unit(self, flow: str, kind: str) -> None:
        """Land the next kill at a random point inside the in-flight unit, not on a unit boundary."""
        self.sleep(self.rng.uniform(0.2, 0.9) * next(f for f in self.cfg["flows"] if f["id"] == flow)["episode"][kind]["unit_s"])

    def wait_stub(self, query: str, flow: str, n: int = 1) -> None:
        self.wait_for(lambda: self.sql(query, flow)[0][0] >= n, f"stub {query} >= {n}")

    def is_done(self) -> bool:
        return all((self.root / "finals" / f"{f}.json").exists() for f in self.flows)

    def wait_done(self, timeout: float | None = None) -> None:
        self.wait_for(self.is_done, "all flows terminal", timeout)

    def sleep(self, s: float) -> None:
        time.sleep(s)

    def sleep_until(self, t: float) -> None:
        time.sleep(max(0.0, t - time.time()))

    def outage(self) -> float:
        return self.rng.uniform(1, 2) if self.fast else self.rng.uniform(3, 8)

    def kmid(self) -> int:
        lo = max(1, self.units // 4)
        return self.rng.randint(lo, max(lo, self.units - 4 if self.units >= 8 else self.units - 2))

    # ---- processes ----
    def start_stub(self) -> None:
        self.stub = subprocess.Popen([PY, str(CODE / "common/stub_api.py"), str(self.root)], stdin=subprocess.DEVNULL,
                                     stdout=open(self.root / "stub.log", "ab"), stderr=subprocess.STDOUT, start_new_session=True)
        self.wait_for(lambda: (self.root / "stub.port").exists(), "stub port", 30)

    def start_loop(self, flow_file: Path | None = None, env: dict | None = None, label: str = "start") -> None:
        t0 = time.time()
        p = subprocess.Popen([PY, str(flow_file or FLOW[self.opt]), "run", str(self.root)], stdin=subprocess.DEVNULL,
                             stdout=open(self.root / "loop.log", "ab"), stderr=subprocess.STDOUT, start_new_session=True,
                             env={**os.environ, **(env or {})})
        self.proc = p
        ready = "loop.ready" if self.opt == "b" else "loop.start"
        e = self.wait_for(lambda: next((x for x in self.events() if x["kind"] == ready and x["pid"] == p.pid), None), f"loop ready ({label})", 120)
        self.loops.append({"pid": p.pid, "t_spawn": t0, "ready_s": round(e["ts"] - t0, 2), "label": label})

    def restart_loop(self, **kw) -> None:
        self.start_loop(label="restart", **kw)
        self.marks["t_restart"] = self.loops[-1]["t_spawn"]

    def footprint(self) -> dict:
        pid = self.proc.pid
        rss = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
        thr = subprocess.run(["ps", "-M", "-p", str(pid)], capture_output=True, text=True).stdout.strip().splitlines()
        return {"rss_mb": round(int(rss) / 1024, 1) if rss else None, "threads": max(0, len(thr) - 1)}

    def kill_loop(self, why: str) -> None:
        self.marks["footprint_loop"] = self.marks.get("footprint_loop") or self.footprint()
        self.marks["t_kill"], self.marks["kill_why"] = time.time(), why
        self.proc.kill()
        self.proc.wait()
        self.snapshot("at_kill")  # the dashboard must work while the loop is dead

    def episode_pids(self) -> list[int]:
        pids = []
        for pidf in (self.root / "episodes").glob("*/pid"):
            pid = int(pidf.read_text() or 0)
            cmd = subprocess.run(["ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True).stdout
            if "episode.py" in cmd:
                pids.append(pid)
        return pids

    def partial_unit_s(self, d: Path) -> float:
        """Seconds of the in-flight unit of episode dir `d`: time since its last finished unit or latest launch."""
        launches = [p.stat().st_mtime for p in d.glob("launch-*")]
        lines = (d / "progress.jsonl").read_text().splitlines() if (d / "progress.jsonl").exists() else []
        last = max([json.loads(lines[-1])["ts"]] + launches) if lines else max(launches)
        return round(time.time() - last, 1)

    def kill_episode(self, flow: str, kind: str) -> None:
        d = self.root / "episodes" / f"{flow}-{kind}"
        self.marks["lost_partial_unit_s"] = self.partial_unit_s(d)
        os.kill(int((d / "pid").read_text()), signal.SIGKILL)
        self.marks["t_kill_episode"] = time.time()
        self.marks["units_at_episode_kill"] = self.units_done(flow, kind)

    def kill_everything(self, why: str) -> None:
        live = [d for d in (self.root / "episodes").iterdir() if not (d / "result.json").exists() and (d / "pid").exists()]
        self.marks["lost_partial_unit_s"] = [self.partial_unit_s(d) for d in live]
        for pid in self.episode_pids():
            os.kill(pid, signal.SIGKILL)
        self.kill_loop(why)

    def cli(self, *args: str) -> None:
        r = subprocess.run([PY, str(FLOW[self.opt]), *args], capture_output=True, text=True, stdin=subprocess.DEVNULL)
        if r.returncode:
            raise RuntimeError(f"cli {args} failed: {r.stderr[-400:]}")

    def alert(self, flow: str) -> None:
        self.marks[f"t_alert_{flow}"] = time.time()
        self.cli("alert", str(self.root), flow)

    def decide(self, flow: str, decision: str) -> None:
        self.marks[f"t_decide_{flow}"] = time.time()
        self.cli("decide", str(self.root), flow, decision)

    def auto_approve(self, flow: str, after: float = 1.0) -> None:
        def run():
            try:
                self.wait_event("decision.wait_start", flow)
                time.sleep(after)
                self.decide(flow, "approve")
            except Exception as e:  # noqa: BLE001
                self.notes.append(f"auto_approve {flow}: {e!r}")
        threading.Thread(target=run, daemon=True).start()

    def boot(self, auto_approve: bool = True) -> None:
        self.start_stub()
        self.start_loop()
        for f in self.flows:
            self.alert(f)
            if auto_approve:
                self.auto_approve(f)

    def snapshot(self, label: str) -> None:
        t0 = time.time()
        r = subprocess.run([PY, str(STATUS[self.opt]), str(self.root)], capture_output=True, text=True)
        try:
            self.snaps[label] = {"ok": r.returncode == 0, "ms": round((time.time() - t0) * 1000), "flows": json.loads(r.stdout) if r.returncode == 0 else r.stderr[-300:]}
        except json.JSONDecodeError:
            self.snaps[label] = {"ok": False, "err": r.stdout[-200:] + r.stderr[-200:]}

    def cleanup(self) -> None:
        for p in (self.proc, self.stub):
            if p and p.poll() is None:
                p.kill()
                p.wait()
        for pid in self.episode_pids():
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

    # ---- analysis ----
    def db_footprint(self) -> dict:
        db = self.root / DBFILE[self.opt]
        c = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        tables = [t[0] for t in c.execute("SELECT name FROM sqlite_master WHERE type='table'")]
        rows = {t: c.execute(f'SELECT count(*) FROM "{t}"').fetchone()[0] for t in tables}
        size = sum(p.stat().st_size for p in self.root.glob(DBFILE[self.opt] + "*"))
        return {"tables": len(tables), "rows": {t: n for t, n in rows.items() if n}, "bytes_incl_wal": size}

    def final(self, flow: str) -> dict | None:
        p = self.root / "finals" / f"{flow}.json"
        return json.loads(p.read_text()) if p.exists() else None

    def analyze(self, expect: dict, extra: dict | None = None) -> dict:
        ev = self.events()
        out = {"option": self.opt, "test": self.test, "idx": self.idx, "fast": self.fast, "marks": self.marks, "loops": self.loops,
               "snapshots": self.snaps, "notes": self.notes, "flows": {}, **(extra or {})}
        mutex_flows = [f for f in self.flows]
        for fid in self.flows:
            exp, fin = expect[fid], self.final(fid)
            q1 = lambda sql: self.sql(sql, fid)[0][0]  # noqa: E731
            fm = {"expect": exp, "final_state": fin["state"] if fin else None, "decision": fin and fin.get("decision"), "decided_by": fin and fin.get("decided_by")}
            fm["prs"] = q1("SELECT count(*) FROM prs WHERE flow_id=?")
            fm["deploys"] = q1("SELECT count(*) FROM deployments WHERE flow_id=?")
            fm["replayed_calls"] = q1("SELECT count(*) FROM calls WHERE flow_id=? AND outcome='replayed'")
            fm["deploy_503"] = q1("SELECT count(*) FROM calls WHERE flow_id=? AND outcome='rejected_503'")
            fm["duplicates"] = max(0, fm["prs"] - exp["prs"]) + max(0, fm["deploys"] - exp["deploys"])
            fm["missing"] = max(0, exp["prs"] - fm["prs"]) + max(0, exp["deploys"] - fm["deploys"])
            fm["episodes"] = {}
            for kind in ("investigate", "implement"):
                d = self.root / "episodes" / f"{fid}-{kind}"
                units = [json.loads(line)["unit"] for line in (d / "progress.jsonl").read_text().splitlines()] if (d / "progress.jsonl").exists() else []
                fm["episodes"][kind] = {"attempts": len(list(d.glob("launch-*"))) if d.exists() else 0, "units_finished": len(units), "units_unique": len(set(units)),
                                        "redrive_events": sum(1 for e in ev if e["kind"] == "episode.redrive" and e.get("flow") == fid and e.get("ep") == kind)}
            fm["recovery_s"] = []
            for lp in self.loops[1:]:
                live = [e["ts"] for e in ev if e["kind"] == "live" and e.get("flow") == fid and e["pid"] == lp["pid"]]
                fm["recovery_s"].append(round(min(live) - lp["t_spawn"], 2) if live else None)
            fm["decision_taken"] = [{"decision": e["decision"], "by": e["by"], "late_s": e["late_s"]} for e in ev if e["kind"] == "decision.taken" and e.get("flow") == fid]
            if len(self.loops) > 1 and fm["decision_taken"]:
                dts = [e["ts"] for e in ev if e["kind"] == "decision.taken" and e.get("flow") == fid and e["ts"] > self.loops[1]["t_spawn"]]
                fm["decision_after_restart_s"] = round(min(dts) - self.loops[1]["t_spawn"], 2) if dts else None
            rds = [e["ts"] for e in ev if e["kind"] == "episode.redrive" and e.get("flow") == fid and "t_kill" in self.marks and e["ts"] > self.marks["t_kill"]]
            fm["redrive_after_kill_s"] = round(min(rds) - self.marks["t_kill"], 2) if rds else None
            ws = next((e for e in ev if e["kind"] == "decision.wait_start" and e.get("flow") == fid), None)
            fm["decision_deadline"] = ws["deadline"] if ws else None
            sets = [e for e in ev if e["kind"] == "timer.set" and e.get("flow") == fid]
            fired = [e for e in ev if e["kind"] == "timer.fired" and e.get("flow") == fid]
            dep_ts = [r[0] for r in self.sql("SELECT ts FROM calls WHERE flow_id=? AND path='/deploy' ORDER BY ts", fid)]
            fm["timers"] = {"set": len(sets), "fired": len(fired), "late_s": [e["late_s"] for e in fired],
                            "early_calls": sum(1 for s, t in zip([e for e in sets if "deploy" in e["why"]], dep_ts[1:]) if t < s["due"] - 0.05)}
            fm["wall_s"] = round(fin["ts"] - min(v for k, v in self.marks.items() if k.startswith("t_alert_")), 1) if fin else None
            out["flows"][fid] = fm
        if self.test == "f":
            rows = self.sql("SELECT flow_id, kind, ts FROM audit ORDER BY ts")
            span = {}
            for fid, kind, ts in rows:
                span.setdefault(fid, {})[kind] = ts
            iv = sorted((s.get("slot.enter", 0), s.get("slot.exit", float("inf")), fid) for fid, s in span.items())
            out["mutex_violations"] = sum(1 for a, b in zip(iv, iv[1:]) if b[0] < a[1])
            out["slot_intervals"] = [{"flow": f, "enter": round(a, 2), "exit": round(b, 2) if b != float("inf") else None} for a, b, f in iv]
        out["completed"] = self.is_done()
        out["marks"]["load1_end"] = round(os.getloadavg()[0], 1)
        out["db"] = self.db_footprint() if (self.root / DBFILE[self.opt]).exists() else None
        out["checks"] = self.checks(out, expect)
        out["pass"] = all(out["checks"].values()) if not self.test.endswith("nokey") else None
        out["control"] = self.test.endswith("nokey")
        return out

    def checks(self, out: dict, expect: dict) -> dict:
        c: dict[str, bool] = {"completed": out["completed"]}
        tick = self.cfg["tick_s"]
        for fid, fm in out["flows"].items():
            exp = expect[fid]
            p = f"{fid}:" if len(out["flows"]) > 1 else ""
            c[p + "final_state"] = fm["final_state"] == exp["state"]
            c[p + "no_duplicate_side_effects"] = fm["duplicates"] == 0
            c[p + "no_missing_side_effects"] = fm["missing"] == 0
            dt = fm["decision_taken"]
            c[p + "decision_consistent"] = len({(d["decision"], d["by"]) for d in dt}) == 1
            if "decided_by" in exp:
                c[p + "decision_source"] = bool(dt) and dt[0]["by"] == exp["decided_by"] and dt[0]["decision"] == exp["decision"]
            if self.test == "a":
                c[p + "episode_survived_no_redrive"] = fm["episodes"]["implement"]["attempts"] == 1
            if self.test in ("b", "b_deploy"):
                c[p + "key_replayed_the_in_doubt_call"] = fm["replayed_calls"] >= 1
            if self.test == "c2":
                c[p + "default_on_time"] = bool(dt) and 0 <= dt[0]["late_s"] <= 3 * tick + 2
            if self.test in ("c3", "c4", "c5", "c5s") and dt and fm["decision_deadline"]:
                c[p + "decided_at_recovery"] = (dt[0]["late_s"] - max(0.0, self.marks["t_restart"] - fm["decision_deadline"])) < 20
            if self.test == "d":
                kind = out["kill_kind"]
                e = fm["episodes"][kind]
                c[p + "redriven_once"] = e["attempts"] == 2 and e["redrive_events"] == 1
                c[p + "resumed_not_restarted"] = e["units_finished"] == self.units and e["units_unique"] == self.units
            if self.test == "h":
                c[p + "episodes_resumed_not_restarted"] = all(e["units_finished"] == self.units and e["units_unique"] == self.units for e in fm["episodes"].values())
            if self.test == "f":
                c[p + "timer_not_early"] = fm["timers"]["early_calls"] == 0
        if self.test == "f":
            c["merge_slot_mutual_exclusion"] = out["mutex_violations"] == 0
        if self.test in ("g", "g_pinned", "g_break"):
            c["recovered_after_redeploy"] = out["completed"] and out.get("recovered_without_rescue", False)
        return c


# ---- scenarios: each returns (expectations per flow, extra result fields) ----

def sc_happy(r: Run):
    r.boot()
    r.wait_done()
    return {f: FIXED for f in r.flows}, {}


def sc_a(r: Run):
    r.boot()
    f = r.flows[0]
    k = r.kmid()
    r.wait_units(f, "implement", k)
    r.kill_loop(f"implement episode at unit {k}")
    r.sleep(r.outage())
    r.restart_loop()
    r.wait_done()
    return {f: FIXED}, {}


def sc_b(r: Run, table: str = "prs"):
    r.boot()
    f = r.flows[0]
    r.wait_stub(f"SELECT count(*) FROM {table} WHERE flow_id=?", f)  # committed at the stub; response still held
    r.kill_loop(f"after {table} committed at the stub, before the flow recorded it")
    r.sleep(r.outage())
    r.restart_loop()
    r.wait_done()
    return {f: FIXED}, {}


def sc_c(r: Run, variant: str):
    f = r.flows[0]
    r.boot(auto_approve=False)
    ws = r.wait_event("decision.wait_start", f)
    dl, x = ws["deadline"], r.cfg["decision_expiry_s"] / 18  # x = 10 s of the 180 s expiry
    r.sleep_until(ws["ts"] + x + r.rng.uniform(0, x))
    r.kill_loop(f"decision wait ({variant})")
    if variant == "c1":
        r.sleep(r.outage())
        r.decide(f, "reject")
        r.sleep(r.outage())
        r.restart_loop()
        exp = {**REJECTED, "decided_by": "human", "decision": "reject"}
    elif variant == "c2":
        r.sleep(r.outage())
        r.restart_loop()
        exp = {**FIXED, "decided_by": "default", "decision": "approve"}
    elif variant == "c3":
        r.sleep_until(dl + x)
        r.restart_loop()
        exp = {**FIXED, "decided_by": "default", "decision": "approve"}
    elif variant == "c4":
        r.sleep(r.outage())
        r.decide(f, "reject")
        r.sleep_until(dl + x)
        r.restart_loop()
        exp = {**REJECTED, "decided_by": "human", "decision": "reject"}
    else:  # c5 / c5s: the owner answers after the expiry, while the loop is still down. Contract: too late, the default stands.
        r.sleep_until(dl + x / 2)
        r.decide(f, "reject")
        r.sleep_until(dl + x)
        r.restart_loop()
        exp = {**FIXED, "decided_by": "default", "decision": "approve"}
    r.wait_done()
    return {f: exp}, {}


def sc_d(r: Run):
    f = r.flows[0]
    kind = "investigate" if r.idx % 2 == 0 else "implement"
    r.boot()
    r.wait_units(f, kind, r.kmid())
    r.into_unit(f, kind)
    r.kill_episode(f, kind)
    r.wait_done()
    t = r.marks["t_kill_episode"]
    rd = r.find("episode.redrive", f, after=t)
    return {f: FIXED}, {"kill_kind": kind, "redrive_detect_s": round(rd["ts"] - t, 2) if rd else None}


def sc_e(r: Run):
    f = r.flows[0]
    phase = PHASES[r.idx % 5]
    r.start_stub()
    r.start_loop()
    r.alert(f)
    if phase != "decision":
        r.auto_approve(f)
    if phase == "investigate":
        r.wait_units(f, "investigate", r.kmid())
        r.into_unit(f, "investigate")
    elif phase == "decision":
        ws = r.wait_event("decision.wait_start", f)
        r.sleep_until(ws["ts"] + r.cfg["decision_expiry_s"] / 18)
    elif phase == "implement":
        r.wait_units(f, "implement", r.kmid())
        r.into_unit(f, "implement")
    elif phase == "deploy_backoff":
        r.wait_stub("SELECT count(*) FROM calls WHERE flow_id=? AND outcome='rejected_503'", f)
    else:
        r.wait_stub("SELECT count(*) FROM deployments WHERE flow_id=?", f)
    r.kill_everything(f"machine reboot during {phase}")
    r.sleep(r.rng.uniform(5, 10) if not r.fast else r.rng.uniform(1, 2))
    r.restart_loop()  # the loop only: episodes stay dead until the loop re-drives them
    if phase == "decision":
        r.sleep(5)
        r.decide(f, "approve")
    r.wait_done()
    return {f: FIXED}, {"phase": phase}


def sc_h(r: Run):
    """Chaos: three kills at uniformly random instants through the flow, each either the loop alone or the
    whole machine (loop + every episode), with a random outage. Nothing is aimed at a known window."""
    f = r.flows[0]
    r.boot()
    kills = []
    for _ in range(3):
        r.sleep(r.rng.uniform(3, 9) if r.fast else r.rng.uniform(15, 70))
        if r.is_done():
            break
        everything = r.rng.random() < 0.5
        (r.kill_everything if everything else r.kill_loop)("chaos")
        kills.append({"t": round(time.time() - r.marks[f"t_alert_{f}"], 1), "scope": "machine" if everything else "loop"})
        r.sleep(r.outage())
        r.restart_loop()
    r.wait_done()
    return {f: FIXED}, {"kills": kills}


def sc_f(r: Run):
    x, y = r.flows
    r.boot()
    r.wait_stub("SELECT count(*) FROM calls WHERE flow_id=? AND outcome='rejected_503'", x)
    r.kill_loop("X inside a deploy backoff timer, holding the merge slot")
    r.sleep(3 if not r.fast else 1)
    r.restart_loop()
    r.wait_done()
    return {x: FIXED, y: FIXED}, {}


def redeploy(r: Run, edit: str) -> None:
    """Restart the loop from a source file that differs from the one that crashed by `edit`."""
    src = FLOW[r.opt].read_text()
    marker = "def flow(flow_id: str, repo: str, service: str) -> dict:\n" if r.opt == "b" else "def tick(c, sb) -> bool:\n"
    assert marker in src
    mod = r.root / FLOW[r.opt].name.replace(".py", "_v2.py")
    mod.write_text(src.replace(marker, marker + edit, 1))
    r.sleep(r.outage())
    r.restart_loop(flow_file=mod, env={"FLOW_COMMON": str(CODE / "common")})


def pending_flow_version(r: Run) -> str:
    c = sqlite3.connect(f"file:{r.root / 'dbos.sqlite'}?mode=ro", uri=True)
    return c.execute("SELECT application_version FROM workflow_status WHERE name='flow' LIMIT 1").fetchone()[0]


def sc_g(r: Run):
    f = r.flows[0]
    r.boot()
    r.wait_units(f, "implement", r.kmid())
    r.kill_loop("implement episode, before redeploy")
    redeploy(r, "    # redeploy marker: one comment line, behaviour unchanged\n")
    extra: dict = {"recovered_without_rescue": True}
    try:
        r.wait_done(timeout=25 if r.fast else 150)  # the rest of the flow takes far less than this
    except HarnessTimeout:
        extra["recovered_without_rescue"] = False
        r.snapshot("orphaned")
        r.marks["t_rescue"] = time.time()
        r.proc.kill()
        r.proc.wait()
        r.start_loop(label="rescue_original_code")  # operator rescue 1: run the old code again
        try:
            r.wait_done(timeout=20 if r.fast else 60)
            extra["rescue"] = "original code alone"
        except HarnessTimeout:
            r.snapshot("orphaned_after_rescue_1")
            r.cli("set-latest", str(r.root), pending_flow_version(r))  # operator rescue 2: make the old version the dequeuing one
            extra["rescue"] = "original code + set_latest_application_version"
            r.wait_done()
        extra["rescue_completion_s"] = round(time.time() - r.marks["t_rescue"], 1)
    return {f: FIXED}, extra


def sc_g_break(r: Run):
    f = r.flows[0]
    r.boot()
    r.wait_units(f, "implement", r.kmid())
    r.kill_loop("implement episode, before an incompatible redeploy")
    redeploy(r, '    audit_step("compat-probe", repo, flow_id)  # incompatible change: a new step ahead of the recorded ones\n')
    extra: dict = {}
    try:
        r.wait_done(timeout=25 if r.fast else 90)
    except HarnessTimeout:
        c = sqlite3.connect(f"file:{r.root / 'dbos.sqlite'}?mode=ro", uri=True)
        extra["dbos_status"] = c.execute("SELECT status FROM workflow_status WHERE name='flow'").fetchone()[0]
        errs = [ln for ln in (r.root / "loop.log").read_text().splitlines() if "DBOSUnexpectedStepError" in ln]
        extra["dbos_error"] = errs[-1][:300] if errs else None
        r.snapshot("after_incompatible_redeploy")
    return {f: FIXED}, extra


SCENARIOS = {"happy": sc_happy, "a": sc_a, "b": sc_b, "b_nokey": sc_b, "b_deploy": lambda r: sc_b(r, "deployments"),
             "c1": lambda r: sc_c(r, "c1"), "c2": lambda r: sc_c(r, "c2"), "c3": lambda r: sc_c(r, "c3"), "c4": lambda r: sc_c(r, "c4"),
             "c5": lambda r: sc_c(r, "c5"), "c5s": lambda r: sc_c(r, "c5"), "d": sc_d, "e": sc_e, "f": sc_f, "h": sc_h, "g": sc_g, "g_pinned": sc_g, "g_break": sc_g_break}
LONG = ("c1", "c2", "c3", "c4", "c5", "c5s")  # scheduled first: they wait out a 180 s expiry


def run_one(opt: str, test: str, idx: int, fast: bool) -> dict:
    r = Run(opt, test, idx, fast)
    t0 = time.time()
    try:
        expect, extra = SCENARIOS[test](r)
        r.snapshot("final")
        res = r.analyze(expect, extra)
        res["harness_s"] = round(time.time() - t0, 1)
    except Exception as e:  # noqa: BLE001
        r.snapshot("error")
        res = {"option": opt, "test": test, "idx": idx, "fast": fast, "completed": False, "pass": False, "error": f"{type(e).__name__}: {e}",
               "marks": r.marks, "loops": r.loops, "snapshots": r.snaps, "notes": r.notes, "flows": {}, "checks": {"completed": False}, "harness_s": round(time.time() - t0, 1)}
    finally:
        r.cleanup()
    (r.root / "result.json").write_text(json.dumps(res, indent=1))
    return res


def batch(options: list[str], tests: list[str], runs: int, parallel: int, fast: bool) -> None:
    jobs = [(o, t, i) for t in sorted(tests, key=lambda t: t not in LONG) for i in range(runs) for o in options
            if not (t in ("c5s", "g_pinned", "g_break") and o == "a")]
    running: list[tuple[subprocess.Popen, tuple]] = []
    logdir = SCRATCH / "batch-logs"
    logdir.mkdir(exist_ok=True)
    print(f"{len(jobs)} runs, parallel={parallel}", flush=True)
    while jobs or running:
        running = [(p, j) for p, j in running if p.poll() is None]
        while jobs and len(running) < parallel:
            o, t, i = jobs.pop(0)
            p = subprocess.Popen([PY, str(Path(__file__)), "run-one", o, t, str(i)] + (["--fast"] if fast else []), stdin=subprocess.DEVNULL,
                                 stdout=open(logdir / f"{o}-{t}-{i}.log", "wb"), stderr=subprocess.STDOUT)
            running.append((p, (o, t, i)))
        time.sleep(2)
    print("batch done", flush=True)


def med(xs):
    xs = [x for x in xs if x is not None]
    return round(statistics.median(xs), 2) if xs else None


def trimmed(root: Path) -> dict:
    """Per-run evidence for the raw file: the flow's key events and the stub's call log, times relative to the first event."""
    keep = ("loop.", "live", "decision.", "timer.", "episode.", "step.done", "error")
    evs = []
    for line in (root / "events.jsonl").read_text().splitlines() if (root / "events.jsonl").exists() else []:
        try:
            e = json.loads(line)
        except json.JSONDecodeError:
            continue
        if e["kind"].startswith(keep):
            evs.append(e)
    t0 = evs[0]["ts"] if evs else 0.0
    calls = []
    if (root / "stub.db").exists():
        c = sqlite3.connect(f"file:{root / 'stub.db'}?mode=ro", uri=True)
        calls = [[round(ts - t0, 2), path, flow, key, outcome] for ts, path, flow, key, outcome in c.execute("SELECT ts,path,flow_id,key,outcome FROM calls WHERE path!='/health' ORDER BY id")]
    for e in evs:
        e["ts"] = round(e["ts"] - t0, 2)
    return {"t0_epoch": t0, "events": evs, "stub_calls_ts_path_flow_key_outcome": calls}


def collect(fast: bool) -> None:
    base = SCRATCH / ("runs-fast" if fast else "runs")
    outdir = CODE / "results" / ("fast" if fast else "full")
    (outdir / "raw").mkdir(parents=True, exist_ok=True)
    runs = []
    for p in sorted(base.glob("*/*/*/result.json")):
        res = json.loads(p.read_text())
        (outdir / "raw" / f"{res['option']}-{res['test']}-{res['idx']}.json").write_text(redact(json.dumps({**res, **trimmed(p.parent)}, indent=1)))
        runs.append(res)
    happy = {(r["option"], r["idx"]): next(iter(r["flows"].values()))["wall_s"] for r in runs if r["test"] == "happy" and r["flows"]}
    summary: dict = {}
    for r in runs:
        s = summary.setdefault(f"{r['option']}/{r['test']}", {"runs": 0, "passed": 0, "completed": 0, "duplicates": 0, "missing": 0, "recovery_s": [], "restart_ready_s": [],
                                                              "default_late_s": [], "redrive_detect_s": [], "overhead_s": [], "failed_checks": {}, "errors": []})
        s["runs"] += 1
        s["completed"] += bool(r.get("completed"))
        s["passed"] += bool(r.get("pass"))
        s["restart_ready_s"] += [lp["ready_s"] for lp in r.get("loops", [])[1:]]
        if r.get("error"):
            s["errors"].append(r["error"])
        for k, v in r.get("checks", {}).items():
            if not v:
                s["failed_checks"][k.split(":")[-1]] = s["failed_checks"].get(k.split(":")[-1], 0) + 1
        for fm in r.get("flows", {}).values():
            s["duplicates"] += fm["duplicates"]
            s["missing"] += fm["missing"]
            s["recovery_s"] += [x for x in fm["recovery_s"] if x is not None]
            s["default_late_s"] += [d["late_s"] for d in fm["decision_taken"] if d["by"] == "default"]
            if (r["option"], r["idx"]) in happy and fm["wall_s"] and happy[(r["option"], r["idx"])]:
                s["overhead_s"].append(round(fm["wall_s"] - happy[(r["option"], r["idx"])], 1))
        if r.get("redrive_detect_s") is not None:
            s["redrive_detect_s"].append(r["redrive_detect_s"])
    for s in summary.values():
        for k in ("recovery_s", "restart_ready_s", "default_late_s", "redrive_detect_s", "overhead_s"):
            vals = s.pop(k)
            s[k] = {"n": len(vals), "median": med(vals), "max": max(vals) if vals else None, "min": min(vals) if vals else None}
    meta = {"dbos": "3.3.0", "python": sys.version.split()[0], "load_avg_at_collect": os.getloadavg(), "fast": fast, "generated": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            "notes": ["Option B status snapshots were taken with the first status_b.py: it missed the decision deadline while a flow waits in recv (the recv row is written when the wait ends) "
                      "and ignored timers inside the child merge_section workflow. Fixed afterwards and verified on fast-mode runs; the stored snapshots are unchanged.",
                      "Timings are scaled as listed in the report: idle limit 15 s, tick 1 s, lease TTL 30 s, backoff 5/10/30 s; decision expiry 180 s and episodes 60-120 s as specified.",
                      "Host load average was 12-24 on 12 cores during the runs (other agents), so absolute recovery times are inflated; both options ran under the same load."]}
    (outdir / "results.json").write_text(redact(json.dumps({"meta": meta, "summary": dict(sorted(summary.items())), "runs": runs}, indent=1)))
    print(f"collected {len(runs)} runs -> {outdir / 'results.json'}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    p1 = sub.add_parser("run-one")
    p1.add_argument("option", choices=["a", "b"])
    p1.add_argument("test")
    p1.add_argument("idx", type=int)
    p1.add_argument("--fast", action="store_true")
    p2 = sub.add_parser("batch")
    p2.add_argument("--options", default="a,b")
    p2.add_argument("--tests", required=True)
    p2.add_argument("--runs", type=int, default=5)
    p2.add_argument("--parallel", type=int, default=20)
    p2.add_argument("--fast", action="store_true")
    p3 = sub.add_parser("collect")
    p3.add_argument("--fast", action="store_true")
    a = ap.parse_args()
    if a.cmd == "run-one":
        res = run_one(a.option, a.test, a.idx, a.fast)
        print(json.dumps({k: res.get(k) for k in ("option", "test", "idx", "completed", "pass", "checks", "error", "harness_s")}))
    elif a.cmd == "batch":
        batch(a.options.split(","), a.tests.split(","), a.runs, a.parallel, a.fast)
    else:
        collect(a.fast)
