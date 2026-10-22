#!/usr/bin/env python3
"""Play the human against the scratch Inbox's window API (loopback, no browser).

usage: inbox_human.py <inbox.json> <thread_id> [words]
  picks the recommended choice of the first question, saves a comment on the first attachment, sends one reply.
The reply text a real UI would build from the comment (`feedback`) is not synthesised here: the attachment comment is stored
and linked (annotation_ids) but the agent-visible quote text only exists when the browser builds it (see REPORT, real-UI run).
"""
import json, sys, urllib.request

reg, tid = json.load(open(sys.argv[1])), sys.argv[2]
words = sys.argv[3] if len(sys.argv) > 3 else "Go with the recommended option."
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
sess, msg = th["serverSession"], th["thread"]["messages"][0]
q = msg["questions"][0]
answer = {"v": 1, "key": q["key"], "kind": q["kind"], "prompt": q["prompt"], "selected": [q["choices"][0]["label"]]}
st, r = call("POST", f"/api/inbox/messages/{msg['id']}/picks", {"questions": [{"key": q["key"], "revision": q["revision"], "answer": answer}], "serverSession": sess})
print("pick:", st)
att = msg["attachments"][0]
ann = {"id": "ann-spike-1", "blockId": "block-0", "startOffset": 0, "endOffset": 24, "type": "COMMENT",
       "text": "Say how a missed review is handled: timeout plus default.", "originalText": "Factory design", "createdA": 1}
st, r = call("POST", "/api/inbox/annotations", {"attachment_id": att["id"], "version": "current", "annotation": ann, "serverSession": sess})
print("annotation:", st)
st, th = call("GET", f"/api/inbox/threads/{tid}")          # the pick bumped the question revision: re-read before replying
q = th["thread"]["messages"][0]["questions"][0]
st, r = call("POST", f"/api/inbox/messages/{msg['id']}/reply", {"idempotency_key": "spike5-human-reply-1", "words": words,
             "questions": [{"key": q["key"], "revision": q["revision"]}], "annotation_ids": ["ann-spike-1"], "serverSession": sess})
print("reply:", st)
