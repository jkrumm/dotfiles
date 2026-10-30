"""Shared fixtures used unchanged by both options: sandbox layout, structured event log, the
stub-API client and the agent-episode launcher/observer. No durability logic lives here: how a
flow survives a crash is exactly what the two options differ on."""
from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
TERMINAL = ("fixed", "rejected", "failed")


class Sandbox:
    """One run's directory: everything a flow, the stub API and the episodes touch."""

    def __init__(self, root: str | Path):
        self.root = Path(root)
        self.cfg = json.loads((self.root / "run.json").read_text())
        self.episodes = self.root / "episodes"
        self.finals = self.root / "finals"
        self.events = self.root / "events.jsonl"
        self.stub_db = self.root / "stub.db"
        for d in (self.episodes, self.finals):
            d.mkdir(parents=True, exist_ok=True)

    def flow_cfg(self, flow_id: str) -> dict:
        return next(f for f in self.cfg["flows"] if f["id"] == flow_id)

    @property
    def base_url(self) -> str:
        return f"http://localhost:{(self.root / 'stub.port').read_text().strip()}"


def evlog(sb: Sandbox, ev: str, /, **kw) -> None:
    """Append one JSON line (single O_APPEND write, atomic across processes)."""
    line = json.dumps({"ts": time.time(), "pid": os.getpid(), "kind": ev, **kw}) + "\n"
    fd = os.open(sb.events, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    try:
        os.write(fd, line.encode())
    finally:
        os.close(fd)


_live_seen: set[str] = set()


def first_live(sb: Sandbox, flow_id: str, where: str) -> None:
    """Mark the first time THIS process does real (non-replayed) work for a flow: recovery time."""
    if flow_id not in _live_seen:
        _live_seen.add(flow_id)
        evlog(sb, "live", flow=flow_id, where=where)


def api(sb: Sandbox, method: str, path: str, body: dict | None = None, key: str | None = None, timeout: float = 20) -> tuple[int, dict]:
    """Call the stub API. Non-LLM HTTP, so a plain request timeout is allowed (agent-limits rule)."""
    headers = {"Content-Type": "application/json"}
    if key:
        headers["Idempotency-Key"] = key
    req = urllib.request.Request(sb.base_url + path, method=method, headers=headers, data=json.dumps(body).encode() if body is not None else None)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")
    except (urllib.error.URLError, OSError, TimeoutError) as e:
        return 0, {"error": str(e)}


def launch_episode(sb: Sandbox, flow_id: str, kind: str, attempt: int) -> bool:
    """Start attempt N of a flow's episode, detached. Idempotent: an O_EXCL marker makes attempt N
    launch at most once, so a loop that crashes and re-decides does not start a second copy."""
    d = sb.episodes / f"{flow_id}-{kind}"
    d.mkdir(parents=True, exist_ok=True)
    try:
        os.close(os.open(d / f"launch-{attempt}", os.O_CREAT | os.O_EXCL | os.O_WRONLY))
    except FileExistsError:
        return False
    c = sb.flow_cfg(flow_id)["episode"][kind]
    with open(d / f"attempt-{attempt}.log", "ab") as log:
        subprocess.Popen([sys.executable, str(HERE / "episode.py"), str(d), kind, str(c["units"]), str(c["unit_s"]), str(attempt)],
                         stdout=log, stderr=log, stdin=subprocess.DEVNULL, start_new_session=True)
    evlog(sb, "episode.launch", flow=flow_id, ep=kind, attempt=attempt)
    return True


def episode_state(sb: Sandbox, flow_id: str, kind: str) -> dict:
    """Observe an episode from outside: absent | running | idle (no heartbeat for idle_limit_s) | done.
    Liveness is heartbeat staleness only (the idle watchdog), never a deadline on the work itself."""
    d = sb.episodes / f"{flow_id}-{kind}"
    attempts = sorted(int(p.name.split("-")[1]) for p in d.glob("launch-*")) if d.exists() else []
    if not attempts:
        return {"state": "absent", "attempt": 0}
    if (d / "result.json").exists():
        return {"state": "done", "attempt": attempts[-1], "result": json.loads((d / "result.json").read_text())}
    last = (d / f"launch-{attempts[-1]}").stat().st_mtime
    if (d / "heartbeat").exists():
        last = max(last, (d / "heartbeat").stat().st_mtime)
    idle = time.time() - last
    return {"state": "idle" if idle > sb.cfg["idle_limit_s"] else "running", "attempt": attempts[-1], "idle_s": round(idle, 1)}


def kill_episode(sb: Sandbox, flow_id: str, kind: str) -> None:
    """Kill a wedged worker before re-driving (only after the idle watchdog fired). The pid is
    checked against the process command line so a recycled pid is never killed."""
    pidf = sb.episodes / f"{flow_id}-{kind}" / "pid"
    if not pidf.exists():
        return
    pid = int(pidf.read_text() or 0)
    cmd = subprocess.run(["ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True).stdout
    if "episode.py" in cmd:
        os.kill(pid, signal.SIGKILL)


def write_final(sb: Sandbox, flow_id: str, state: str, **extra) -> None:
    """Uniform completion marker for the harness (each option also keeps its own terminal state)."""
    p = sb.finals / f"{flow_id}.json"
    if not p.exists():
        tmp = p.with_suffix(".tmp")
        tmp.write_text(json.dumps({"flow": flow_id, "state": state, "ts": time.time(), **extra}))
        os.replace(tmp, p)


_audited: set[str] = set()


def audit(sb: Sandbox, kind: str, repo: str, flow_id: str) -> None:
    """Tell the stub a flow entered/left the merge-slot critical section. The stub's timestamps are
    the harness's ground truth for mutual exclusion; the key makes the report idempotent."""
    key = f"{flow_id}:{kind}"
    if key not in _audited and api(sb, "POST", "/audit", {"kind": kind, "repo": repo, "flow_id": flow_id}, key=key)[0] == 200:
        _audited.add(key)
