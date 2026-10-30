#!/usr/bin/env python3
"""Helper for 10-storage-crash.py: commit one task per transaction in a loop, acknowledging each commit on stdout."""
import os, sqlite3, sys, time, uuid
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sqlite_tasks as st
db = sqlite3.connect(os.environ["TASKS_DB"], timeout=30, isolation_level=None)
db.execute("PRAGMA journal_mode=WAL")
n = 0
while True:
    n += 1
    title = f"kill-test {sys.argv[1]}-{n}"
    db.execute("BEGIN IMMEDIATE")
    db.execute("INSERT INTO tasks(id,project,title,created_at) VALUES(?,?,?,?)", (uuid.uuid4().hex[:8], "kl", title, time.time()))
    db.execute("COMMIT")
    print(title, flush=True)
