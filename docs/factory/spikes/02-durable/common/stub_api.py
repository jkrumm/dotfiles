#!/usr/bin/env python3
"""Stub external API: a small SQLite-backed HTTP service that records every call, so duplicate
side effects are countable. It plays the git host (POST /pr), the deploy target (POST /deploy),
the health endpoint (GET /health) and an audit trail for the merge-slot critical section.

Fault injection (run.json "stub"): pr_delay_s / deploy_delay_s hold the RESPONSE of a call that
already committed its side effect (the window between "side effect happened" and "caller recorded
it"); deploy_fail_first makes the first N deploy calls per flow answer 503 with no side effect.

Usage: stub_api.py <sandbox-dir>   (writes <sandbox>/stub.port once listening)
"""
import json
import sqlite3
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

SCHEMA = """
CREATE TABLE IF NOT EXISTS calls(id INTEGER PRIMARY KEY, ts REAL, path TEXT, key TEXT, flow_id TEXT, outcome TEXT);
CREATE TABLE IF NOT EXISTS prs(number INTEGER PRIMARY KEY, flow_id TEXT, key TEXT, ts REAL);
CREATE TABLE IF NOT EXISTS deployments(id INTEGER PRIMARY KEY, flow_id TEXT, service TEXT, key TEXT, ts REAL);
CREATE TABLE IF NOT EXISTS idem(key TEXT PRIMARY KEY, response TEXT);
CREATE TABLE IF NOT EXISTS service(name TEXT PRIMARY KEY, healthy_from REAL);
CREATE TABLE IF NOT EXISTS audit(id INTEGER PRIMARY KEY, ts REAL, kind TEXT, repo TEXT, flow_id TEXT, key TEXT UNIQUE);
"""
LOCK = threading.Lock()


def main(sandbox: str) -> None:
    root = Path(sandbox)
    cfg = json.loads((root / "run.json").read_text())["stub"]
    db = sqlite3.connect(root / "stub.db", check_same_thread=False, isolation_level=None)
    db.execute("PRAGMA journal_mode=WAL")
    db.executescript(SCHEMA)

    def record(path, key, flow_id, outcome):
        db.execute("INSERT INTO calls(ts,path,key,flow_id,outcome) VALUES (?,?,?,?,?)", (time.time(), path, key, flow_id, outcome))

    def create(table, path, key, body, extra):
        """Idempotent create: a repeated Idempotency-Key replays the stored response."""
        with LOCK:
            hit = db.execute("SELECT response FROM idem WHERE key=?", (key,)).fetchone() if key else None
            if hit:
                record(path, key, body.get("flow_id"), "replayed")
                return 200, json.loads(hit[0]), 0.0
            cols = {"flow_id": body.get("flow_id"), "key": key, "ts": time.time(), **extra}
            cur = db.execute(f"INSERT INTO {table}({','.join(cols)}) VALUES ({','.join('?' * len(cols))})", list(cols.values()))
            resp = {"id": cur.lastrowid, "flow_id": body.get("flow_id")}
            if key:
                db.execute("INSERT INTO idem(key,response) VALUES (?,?)", (key, json.dumps(resp)))
            record(path, key, body.get("flow_id"), "created")
        return 200, resp, cfg["pr_delay_s"] if table == "prs" else cfg["deploy_delay_s"]

    def handle_post(path, body, key):
        if path == "/pr":
            return create("prs", path, key, body, {})
        if path == "/deploy":
            with LOCK:
                failed = db.execute("SELECT count(*) FROM calls WHERE path='/deploy' AND flow_id=? AND outcome='rejected_503'", (body.get("flow_id"),)).fetchone()[0]
                if failed < cfg["deploy_fail_first"]:
                    record(path, key, body.get("flow_id"), "rejected_503")
                    return 503, {"error": "deploy target busy"}, 0.0
            status, resp, delay = create("deployments", path, key, body, {"service": body["service"]})
            with LOCK:
                db.execute("INSERT OR IGNORE INTO service(name,healthy_from) VALUES (?,?)", (body["service"], time.time() + cfg["warmup_s"]))
            return status, resp, delay
        if path == "/audit":
            with LOCK:
                db.execute("INSERT OR IGNORE INTO audit(ts,kind,repo,flow_id,key) VALUES (?,?,?,?,?)", (time.time(), body["kind"], body["repo"], body["flow_id"], key))
            return 200, {"ok": True}, 0.0
        return 404, {"error": "no such path"}, 0.0

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def reply(self, status, obj):
            data = json.dumps(obj).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            u = urlparse(self.path)
            if u.path != "/health":
                return self.reply(404, {})
            name = parse_qs(u.query).get("service", [""])[0]
            with LOCK:
                row = db.execute("SELECT healthy_from FROM service WHERE name=?", (name,)).fetchone()
                ok = bool(row) and time.time() >= row[0]
                record("/health", None, name, "ok" if ok else "unhealthy")
            self.reply(200 if ok else 503, {"ok": ok})

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
            status, resp, delay = handle_post(urlparse(self.path).path, body, self.headers.get("Idempotency-Key"))
            if delay:
                time.sleep(delay)  # side effect is already committed; the caller is still waiting
            self.reply(status, resp)

    srv = ThreadingHTTPServer(("localhost", 0), Handler)
    srv.daemon_threads = True
    (root / "stub.port.tmp").write_text(str(srv.server_address[1]))
    (root / "stub.port.tmp").rename(root / "stub.port")
    srv.serve_forever()


if __name__ == "__main__":
    main(sys.argv[1])
