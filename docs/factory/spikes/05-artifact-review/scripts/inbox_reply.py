#!/usr/bin/env python3
"""Play the human: send a words-only reply to the newest agent message of a thread (scratch Inbox window API, loopback).
usage: inbox_reply.py <inbox.json> <thread_id> "<words>"
"""
import json, sys, time, urllib.request

reg, tid, words = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3]
base = f"http://localhost:{reg['port']}"


def call(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(base + path, data=data, method=method, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


st, th = call("GET", f"/api/inbox/threads/{tid}")
mid = [m for m in th["thread"]["messages"] if m["author"]["kind"] == "agent"][-1]["id"]
st, r = call("POST", f"/api/inbox/messages/{mid}/reply", {"idempotency_key": f"human-{int(time.time() * 1000)}", "words": words,
             "questions": [], "serverSession": th["serverSession"]})
print("reply:", st)
