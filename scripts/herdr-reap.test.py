#!/usr/bin/env python3
"""Hermetic tests for herdr-reap.py: fake `herdr` and `claude` on PATH, real throwaway git repos,
HOME pointed at a tmpdir (transcripts, state, log). Run: python3 scripts/herdr-reap.test.py"""
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest

REAP = os.path.join(os.path.dirname(os.path.abspath(__file__)), "herdr-reap.py")

FAKE_HERDR = r'''#!/usr/bin/env python3
import json, os, sys
a = sys.argv[1:]
d = json.load(open(os.environ["FAKE_WORLD"]))
open(os.environ["FAKE_CALLS"], "a").write(" ".join(a) + "\n")
if a[:2] == ["pane", "list"]:
    print(json.dumps({"result": {"panes": d["panes"]}}))
elif a[:2] == ["agent", "list"]:
    print(json.dumps({"result": {"agents": d["agents"]}}))
elif a[:2] == ["tab", "list"]:
    print(json.dumps({"result": {"tabs": d["tabs"]}}))
else:
    print(json.dumps({"result": {"type": "ok"}}))
'''
FAKE_CLAUDE = r'''#!/usr/bin/env python3
import json, os, sys
d = json.load(open(os.environ["FAKE_WORLD"]))
open(os.environ["FAKE_CALLS"], "a").write("claude " + " ".join(sys.argv[1:]) + "\n")
if sys.argv[1:3] == ["agents", "--json"]:
    print(json.dumps(d.get("bg", [])))
'''


def git(cwd, *a):
    subprocess.run(["git", "-C", cwd, *a], check=True, capture_output=True)


class Reap(unittest.TestCase):
    def setUp(self):
        self.t = tempfile.mkdtemp()
        self.home = os.path.join(self.t, "home")
        self.bin = os.path.join(self.t, "bin")
        os.makedirs(self.bin)
        os.makedirs(os.path.join(self.home, ".claude/projects/p"))
        for n, body in (("herdr", FAKE_HERDR), ("claude", FAKE_CLAUDE)):
            with open(os.path.join(self.bin, n), "w") as f:
                f.write(body)
            os.chmod(os.path.join(self.bin, n), 0o755)
        self.world = os.path.join(self.t, "world.json")
        self.calls = os.path.join(self.t, "calls.txt")
        open(self.calls, "w").close()

    def repo(self, name, dirty=False, plan_active=False):
        r = os.path.join(self.t, name)
        remote = os.path.join(self.t, f"{name}.git")
        subprocess.run(["git", "init", "-q", "--bare", remote], check=True)
        subprocess.run(["git", "clone", "-q", remote, r], check=True, capture_output=True)
        git(r, "config", "user.email", "t@t"); git(r, "config", "user.name", "t")
        os.makedirs(os.path.join(r, "docs/waves"))
        with open(os.path.join(r, "docs/waves/PLAN.md"), "w") as f:
            f.write(f"## Wave 1 — x   <!-- status: {'active' if plan_active else 'done'} -->\n")
        git(r, "add", "."); git(r, "commit", "-qm", "init"); git(r, "push", "-qu", "origin", "HEAD")
        os.makedirs(os.path.join(r, "sub"))
        if dirty:
            open(os.path.join(r, "x"), "w").write("x")
        return r

    def agent(self, pane, tab, status, cwd, idle_h=30):
        sid = f"sid-{pane}"
        ts = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(time.time() - idle_h * 3600))
        with open(os.path.join(self.home, ".claude/projects/p", f"{sid}.jsonl"), "w") as f:
            f.write(json.dumps({"timestamp": ts}, separators=(",", ":")) + "\n")
        return ({"pane_id": pane, "tab_id": tab}, {"pane_id": pane, "tab_id": tab, "agent": "claude", "agent_status": status,
                "cwd": cwd, "agent_session": {"value": sid}}, {"tab_id": tab, "label": tab})

    def run_reap(self, agents, bg=(), *flags):
        panes, ags, tabs = zip(*agents) if agents else ((), (), ())
        json.dump({"panes": list(panes), "agents": list(ags), "tabs": list(tabs), "bg": list(bg)}, open(self.world, "w"))
        env = dict(os.environ, HOME=self.home, PATH=f"{self.bin}:{os.environ['PATH']}", FAKE_WORLD=self.world,
                   FAKE_CALLS=self.calls, HERDR_PANE_ID="own", REAP_IDLE_H="12")
        r = subprocess.run([sys.executable, REAP, *flags], env=env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        return open(self.calls).read()

    def log(self):
        p = os.path.join(self.home, "Library/Logs/herdr-reap.log")
        return open(p).read() if os.path.exists(p) else ""

    def test_closes_idle_clean_pushed(self):
        r = self.repo("a")
        calls = self.run_reap([self.agent("p1", "t1", "idle", r)])
        self.assertIn("tab close t1", calls)
        self.assertIn("close tab=t1", self.log())

    def test_dry_run_changes_nothing(self):
        r = self.repo("a")
        calls = self.run_reap([self.agent("p1", "t1", "idle", r)], (), "--dry-run")
        self.assertNotIn("tab close", calls)
        self.assertEqual(self.log(), "")

    def test_recent_idle_is_kept(self):
        r = self.repo("a")
        self.assertNotIn("tab close", self.run_reap([self.agent("p1", "t1", "idle", r, idle_h=1)]))

    def test_never_working_or_blocked(self):
        r1, r2 = self.repo("a"), self.repo("b")
        calls = self.run_reap([self.agent("p1", "t1", "working", r1), self.agent("p2", "t2", "blocked", r2)])
        self.assertNotIn("tab close", calls)

    def test_working_agent_in_subdir_shields_the_checkout(self):
        r = self.repo("a")
        calls = self.run_reap([self.agent("p1", "t1", "idle", r), self.agent("p2", "t2", "working", os.path.join(r, "sub"))])
        self.assertNotIn("tab close", calls)
        self.assertNotIn("agent prompt", calls)

    def test_dirty_is_messaged_not_closed(self):
        r = self.repo("a", dirty=True)
        calls = self.run_reap([self.agent("p1", "t1", "done", r)])
        self.assertNotIn("tab close", calls)
        self.assertIn("agent prompt p1", calls)
        # and only once per 24 h
        calls = self.run_reap([self.agent("p1", "t1", "done", r)])
        self.assertEqual(calls.count("agent prompt p1"), 1)

    def test_unpushed_is_not_closed(self):
        r = self.repo("a")
        git(r, "commit", "--allow-empty", "-qm", "local")
        self.assertNotIn("tab close", self.run_reap([self.agent("p1", "t1", "idle", r)]))

    def test_active_wave_plan_shields_the_repo(self):
        r = self.repo("a", plan_active=True)
        self.assertNotIn("tab close", self.run_reap([self.agent("p1", "t1", "idle", r)]))

    def test_non_git_cwd_and_non_agent_pane_and_own_tab(self):
        r = self.repo("a")
        plain = os.path.join(self.t, "plain"); os.makedirs(plain)
        a1 = self.agent("p1", "t1", "idle", plain)
        a2 = self.agent("p2", "t2", "idle", r)
        a3 = self.agent("own", "t3", "idle", self.repo("c"))
        shell = ({"pane_id": "sh", "tab_id": "t2"}, None, None)
        panes = [a1, a2, a3]
        json.dump({"panes": [x[0] for x in panes] + [shell[0]], "agents": [x[1] for x in panes],
                   "tabs": [x[2] for x in panes], "bg": []}, open(self.world, "w"))
        env = dict(os.environ, HOME=self.home, PATH=f"{self.bin}:{os.environ['PATH']}", FAKE_WORLD=self.world,
                   FAKE_CALLS=self.calls, HERDR_PANE_ID="own", REAP_IDLE_H="12")
        subprocess.run([sys.executable, REAP], env=env, check=True, capture_output=True)
        self.assertNotIn("tab close", open(self.calls).read())

    def test_bg_filter(self):
        old = int((time.time() - 48 * 3600) * 1000)
        bg = [{"id": "aaa", "kind": "background", "state": "blocked", "startedAt": old, "name": "n", "cwd": "/x"},
              {"id": "bbb", "kind": "background", "state": "working", "startedAt": old, "name": "n", "cwd": "/x"},
              {"id": "ccc", "kind": "background", "startedAt": old, "name": "n", "cwd": "/x"},
              {"id": "ddd", "kind": "background", "state": "blocked", "startedAt": int(time.time() * 1000), "name": "n", "cwd": "/x"}]
        calls = self.run_reap([], bg)
        self.assertIn("claude stop aaa", calls)
        for x in ("bbb", "ccc", "ddd"):
            self.assertNotIn(f"claude stop {x}", calls)


if __name__ == "__main__":
    unittest.main()
