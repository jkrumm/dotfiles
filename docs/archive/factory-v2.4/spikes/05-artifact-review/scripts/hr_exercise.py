#!/usr/bin/env python3
"""Option C (human-review) scenarios, playing the browser against the local server API (no real browser).

  B   comment + Send  -> what the blocking `poll` prints; --ack then a bounded poll must not replay
  C1  an unsent comment survives a SIGKILL of the server; `status` works with the server dead; re-open reports `leftover`
  C2  a Sent batch survives a SIGKILL before the agent polls and is delivered by a fresh poll
  E   is there any list/inbox route across targets?
Stdlib only. Run through human-review-exercise.sh (needs HOME_SPIKE and the scratch install).
"""
import json, os, signal, subprocess, sys, threading, time, urllib.request

S = os.environ.get("HOME_SPIKE", os.path.expanduser("~/.local/share/factory/spikes/05-review"))
HR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "hr")
STATE = os.path.join(S, "home", ".human-review")
BRIEF = os.path.join(S, "artifacts", "BRIEF.md")
passed = failed = 0


def check(name, got, want):
    global passed, failed
    ok = got == want
    passed += ok; failed += (not ok)
    print(f"{'PASS' if ok else 'FAIL'}  {name} ({got})" if ok else f"FAIL  {name}: want [{want}] got [{got}]")


def server():
    return json.load(open(os.path.join(STATE, "server.json")))


def api(method, path, body=None):
    srv = server()
    req = urllib.request.Request(f"http://localhost:{srv['port']}{path}", method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"x-human-review-token": srv["token"], "content-type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        return e.code, {"error": e.read().decode()[:200]}


def cli(*args, timeout=60):
    p = subprocess.run([HR, *args], capture_output=True, text=True, timeout=timeout)
    return p.stdout.strip()


def hold_browser(sid):
    """Simulate the tab: keep the SSE stream open so the session counts as live."""
    srv = server()
    r = urllib.request.urlopen(urllib.request.Request(f"http://localhost:{srv['port']}/events/{sid}",
                                                     headers={"x-human-review-token": srv["token"]}), timeout=300)
    stop = threading.Event()

    def pump():
        try:
            while not stop.is_set() and r.readline():
                pass
        except Exception:
            pass
    threading.Thread(target=pump, daemon=True).start()
    return r, stop


def kill_server():
    pid = server()["pid"]
    os.kill(pid, signal.SIGKILL); time.sleep(1.0)
    try:
        os.kill(pid, 0); alive = True
    except OSError:
        alive = False
    return pid, alive


cli(BRIEF)                                           # spawns the detached server like an agent's first call
print("== B: comment + Send -> poll")
st, sess = api("POST", "/api/session", {"target": BRIEF})
sid, key = sess["sessionId"], sess["key"]
conn, stop = hold_browser(sid)
poll = subprocess.Popen([HR, "poll", BRIEF], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
time.sleep(2)
quote = "Never break the lane used to fix things"
api("POST", f"/api/page/{key}/comment", {"kind": "selection", "quote": quote,
    "anchor": {"prefix": "- ", "quote": quote, "suffix": ": the manual Claude Code"}, "feedback": "Name the lane explicitly."})
api("POST", f"/api/page/{key}/comment", {"kind": "element", "quote": "Fixed - do not debate", "feedback": "Add a one-line rationale per fixed item."})
t0 = time.time()
api("POST", f"/api/page/{key}/send", {"sessionId": sid, "note": "Overall: tighten the Fixed list."})
out, _ = poll.communicate(timeout=20)
latency = time.time() - t0
batch = json.loads(out)
print(out)
check("poll returns feedback", batch["status"], "feedback")
check("selection comment keeps quote + prefix/suffix anchor", batch["pages"][0]["comments"][0]["anchor"]["quote"], quote)
check("overall note delivered", batch["overall_note"], "Overall: tighten the Fixed list.")
print(f"   poll released {latency:.2f}s after Send")
out = cli("poll", BRIEF, "--ack", "--timeout", "4", timeout=30)
check("after --ack the next poll times out (no replay)", json.loads(out)["status"], "timeout")

print("== C1: unsent comment, then SIGKILL the server")
api("POST", f"/api/page/{key}/comment", {"kind": "selection", "quote": "Phase 4",
    "anchor": {"prefix": "", "quote": "Phase 4", "suffix": " - spikes"}, "feedback": "unsent draft comment"})
stop.set(); conn.close()
pid, alive = kill_server()
check("server really died", alive, False)
st = json.loads(cli("status", BRIEF))
check("status with the server dead reads state.json: unsent comments", (st["server_running"], st["unsent"]["comments"]), (False, 1))
cli(BRIEF); st, sess2 = api("POST", "/api/session", {"target": BRIEF})
check("re-open after restart reports leftover", sess2["leftover"]["comments"], 1)
check("a new server process owns the port", server()["pid"] != pid, True)
conn, stop = hold_browser(sess2["sessionId"])

print("== C2: Send, SIGKILL before the agent polls, poll afterwards")
api("POST", f"/api/page/{key}/comment", {"kind": "selection", "quote": "Phase 6",
    "anchor": {"prefix": "", "quote": "Phase 6", "suffix": " - proof"}, "feedback": "sent just before a crash"})
api("POST", f"/api/page/{key}/send", {"sessionId": sess2["sessionId"], "note": ""})
stop.set(); conn.close()
pid, alive = kill_server()
st = json.loads(cli("status", BRIEF))
check("status with the server dead: feedback waiting on disk", st["feedback_waiting"], True)
b = json.loads(cli("poll", BRIEF, "--timeout", "15", timeout=40))
check("fresh poll after the crash delivers the batch", b["status"], "feedback")
check("batch holds the carried-over draft and the new comment", [c["feedback"] for p in b["pages"] for c in p["comments"]],
      ["unsent draft comment", "sent just before a crash"])

print("== E: any list / inbox route across targets?")
codes = {p: api("GET", p)[0] for p in ("/", "/api/sessions", "/api/pages", "/api/inbox", "/api/reviews")}
print("   ", codes)
check("no inbox route exists", set(codes.values()), {404})
cli("poll", BRIEF, "--ack", "--timeout", "3", timeout=20)
print(f"RESULT: {passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
