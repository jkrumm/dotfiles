#!/usr/bin/env python3
"""Baseline to beat: the task layer as a warden-ledger extension on SQLite, bd-compatible verbs.
Tasks + deps tables, a recursive-CTE ready query, claim lease by conditional UPDATE, heartbeat, reclaim."""
import json, os, sqlite3, sys, time, uuid
DB, TTL = os.environ.get("TASKS_DB", "tasks.db"), float(os.environ.get("LEASE_TTL", "300"))
SCHEMA = """
CREATE TABLE IF NOT EXISTS tasks(id TEXT PRIMARY KEY, project TEXT, title TEXT NOT NULL, type TEXT DEFAULT 'task',
  priority INT DEFAULT 2, status TEXT DEFAULT 'open', parent TEXT, assignee TEXT, lease_until REAL, heartbeat_at REAL,
  labels TEXT DEFAULT '', created_at REAL, closed_at REAL);
CREATE TABLE IF NOT EXISTS task_deps(task TEXT, depends_on TEXT, PRIMARY KEY(task, depends_on));
CREATE INDEX IF NOT EXISTS task_deps_on ON task_deps(depends_on);"""
READY = """WITH RECURSIVE blocked(id) AS (
  SELECT d.task FROM task_deps d LEFT JOIN tasks b ON b.id = d.depends_on WHERE b.id IS NULL OR b.status != 'closed'
  UNION SELECT c.id FROM tasks c JOIN blocked p ON c.parent = p.id)
SELECT * FROM tasks WHERE status = 'open' AND id NOT IN (SELECT id FROM blocked) {extra}
ORDER BY priority, created_at LIMIT ?"""
BOOL, ALIAS = {"claim", "json"}, {"t": "type", "p": "priority", "l": "labels", "r": "reason", "a": "actor", "s": "status", "n": "limit"}

def parse(args):
    pos, fl, i = [], {}, 0
    while i < len(args):
        if args[i].startswith("-"):
            k = ALIAS.get(args[i].lstrip("-"), args[i].lstrip("-"))
            if k in BOOL: fl[k] = True
            else: i += 1; fl[k] = args[i]
        else: pos.append(args[i])
        i += 1
    return pos, fl

def main(argv):
    db = sqlite3.connect(DB, timeout=30, isolation_level=None); db.row_factory = sqlite3.Row
    db.execute("PRAGMA journal_mode=WAL"); db.executescript(SCHEMA)
    now, (cmd, *rest) = time.time(), argv
    pos, fl = parse(rest)
    def upd(sql, *a): return db.execute(sql, a).rowcount          # one atomic statement = the compare-and-set
    def out(rows): print(json.dumps([dict(r) for r in rows], indent=1))
    if cmd == "create":
        tid = f"{fl.get('project', 'wd')}-{uuid.uuid4().hex[:6]}"
        db.execute("INSERT INTO tasks(id,project,title,type,priority,parent,labels,created_at) VALUES(?,?,?,?,?,?,?,?)",
                   (tid, fl.get("project", "wd"), pos[0], fl.get("type", "task"), int(fl.get("priority", 2)), fl.get("parent"), fl.get("labels", ""), now))
        print(json.dumps({"id": tid}))
    elif cmd == "dep":                                              # dep add <task> <depends-on>; cross-project = same table
        db.execute("INSERT OR IGNORE INTO task_deps VALUES(?,?)", (pos[1], pos[2]))
    elif cmd == "ready":
        ex = "".join(f" AND type != '{t}'" for t in fl.get("exclude-type", "").split(",") if t)
        out(db.execute(READY.format(extra=ex), (int(fl.get("limit", 100)) or -1,)).fetchall())
    elif cmd == "update" and fl.get("claim"):                       # claim = lease; lost race -> exit 1
        won = upd("UPDATE tasks SET status='in_progress', assignee=?, heartbeat_at=?, lease_until=? WHERE id=? AND (status='open' OR (status='in_progress' AND assignee=?))",
                  fl["actor"], now, now + TTL, pos[0], fl["actor"])
        sys.exit(0 if won else 1)
    elif cmd == "update":                                           # --if-status S --status T: stale guard -> exit 13
        ok = upd("UPDATE tasks SET status=?, assignee=COALESCE(?,assignee) WHERE id=? AND status=?", fl["status"], fl.get("actor"), pos[0], fl["if-status"])
        sys.exit(0 if ok else 13)
    elif cmd == "heartbeat":                                        # only the owner of a live claim may extend it
        sys.exit(0 if upd("UPDATE tasks SET heartbeat_at=?, lease_until=? WHERE id=? AND assignee=? AND status='in_progress'", now, now + TTL, pos[0], fl["actor"]) else 1)
    elif cmd == "close":                                            # fenced like bd: only the holder (or anyone, if unheld) closes
        sys.exit(0 if upd("UPDATE tasks SET status='closed', closed_at=?, assignee=NULL, lease_until=NULL WHERE id=? AND status!='closed' AND (assignee IS NULL OR assignee=?)", now, pos[0], fl.get("actor")) else 1)
    elif cmd == "reclaim":                                          # reaper: expired lease (+ grace) -> open again
        n = upd("UPDATE tasks SET status='open', assignee=NULL, lease_until=NULL WHERE status='in_progress' AND lease_until < ?", now - float(fl.get("older-than", 0)))
        print(json.dumps({"reclaimed": n}))
    elif cmd in ("list", "show"):
        out(db.execute("SELECT * FROM tasks WHERE (? IS NULL OR id=?) LIMIT 200", (pos[0] if pos else None,) * 2).fetchall())

if __name__ == "__main__":
    main(sys.argv[1:])
