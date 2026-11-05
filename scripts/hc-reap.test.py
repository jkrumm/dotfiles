#!/usr/bin/env python3
"""Hermetic tests for hc-reap.py: fake `hc` and `claude` on PATH, a fake lib/core-up.sh (CORE_UP_SH), real throwaway git repos,
HOME pointed at a tmpdir (transcripts, state, log). Run: python3 scripts/hc-reap.test.py"""
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest

REAP = os.path.join(os.path.dirname(os.path.abspath(__file__)), "hc-reap.py")

FAKE_HC = r'''#!/usr/bin/env python3
# A fake core: `hc connect` answers JSON-RPC from FAKE_WORLD and records every call (list/kill/rm/send) in FAKE_CALLS.
import json, os, subprocess, sys
if sys.argv[1:2] != ["connect"]:
    sys.exit(2)
req = json.loads(sys.stdin.readline())
m, p = req["method"], req.get("params") or {}
with open(os.environ["FAKE_WORLD"]) as f:
    d = json.load(f)
calls = os.environ["FAKE_CALLS"]
with open(calls, "a") as f:
    f.write(m.split(".")[1] + (" " + p["terminal"] if "terminal" in p else "") + (" " + p["text"] if "text" in p else "") + "\n")
with open(calls) as f:
    n = len([l for l in f if l.startswith("list")])
def reply(r):
    print(json.dumps({"jsonrpc": "2.0", "id": req["id"], "result": r}))
def fail(kind):
    print(json.dumps({"jsonrpc": "2.0", "id": req["id"], "error": {"code": -32000, "message": kind, "data": {"kind": kind}}}))
if m == "terminal.list":
    if d.get("list_error"):
        fail("boom")
        sys.exit(0)
    flip = d.get("flip_after")
    only = d.get("flip_terminals")
    ts = [dict(t, status={"app": "claude-code", "state": "working"}) if flip is not None and n > flip and t.get("status") and (only is None or t["address"] in only) else t
          for t in d["terminals"]]
    if d.get("child_after") is not None and n > d["child_after"]:
        ts.append({"address": "newc", "state": "live", "parent": d["child_of"], "status": None, "labels": {}, "cwd": "/"})
    if d.get("replace_after") is not None and n > d["replace_after"]:  # same address, a different terminal
        ts = [dict(t, created_ms=999) if t["address"] == d["replace_addr"] else t for t in ts]
    reply({"terminals": ts, "hidden_finished": 0})
elif m in ("terminal.kill", "terminal.rm", "terminal.send"):
    if d.get("fail_" + m.split(".")[1]):
        fail("live")
    else:
        reply({})
else:
    fail("unknown")
'''
FAKE_CORE_UP = '''#!/bin/sh
echo "core-up" >> "$FAKE_CALLS"
[ -f "$FAKE_CORE_DOWN" ] && exit 1
exit 0
'''
FAKE_CLAUDE = r'''#!/usr/bin/env python3
import json, os, sys
with open(os.environ["FAKE_WORLD"]) as f:
    d = json.load(f)
with open(os.environ["FAKE_CALLS"], "a") as f:
    f.write("claude " + " ".join(sys.argv[1:]) + "\n")
if sys.argv[1:3] == ["agents", "--json"]:
    print(json.dumps(d.get("bg", [])))
'''


def write(path, text):
    with open(path, "w") as f:
        f.write(text)


def git(cwd, *a):
    subprocess.run(["git", "-C", cwd, *a], check=True, capture_output=True)


class Reap(unittest.TestCase):
    def setUp(self):
        self.t = tempfile.mkdtemp()
        self.home = os.path.join(self.t, "home")
        self.bin = os.path.join(self.t, "bin")
        os.makedirs(self.bin)
        os.makedirs(os.path.join(self.home, ".claude/projects/p"))
        for n, body in (("hc", FAKE_HC), ("claude", FAKE_CLAUDE), ("core-up.sh", FAKE_CORE_UP)):
            with open(os.path.join(self.bin, n), "w") as f:
                f.write(body)
            os.chmod(os.path.join(self.bin, n), 0o755)
        self.world = os.path.join(self.t, "world.json")
        self.calls = os.path.join(self.t, "calls.txt")
        with open(self.calls, "w"):
            pass

    def repo(self, name, dirty=False):
        r = os.path.join(self.t, name)
        remote = os.path.join(self.t, f"{name}.git")
        subprocess.run(["git", "init", "-q", "--bare", remote], check=True)
        subprocess.run(["git", "clone", "-q", remote, r], check=True, capture_output=True)
        git(r, "config", "user.email", "t@t"); git(r, "config", "user.name", "t")
        write(os.path.join(r, "README"), "x")
        git(r, "add", "."); git(r, "commit", "-qm", "init"); git(r, "push", "-qu", "origin", "HEAD")
        os.makedirs(os.path.join(r, "sub"))
        if dirty:
            write(os.path.join(r, "x"), "x")
        return r

    def agent(self, pane, addr, status, cwd, idle_h=30, key="fan:test"):
        """A live Claude terminal record as `terminal.list` returns it; `pane` only makes the session id unique.
        `key` is the `factory.key` label (None = a keyless terminal, the owner's own session)."""
        tab, sid = addr, f"sid-{pane}"
        ts = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(time.time() - idle_h * 3600))
        with open(os.path.join(self.home, ".claude/projects/p", f"{sid}.jsonl"), "w") as f:
            f.write(json.dumps({"timestamp": ts}, separators=(",", ":")) + "\n")
        return {"address": addr, "state": "live", "created_ms": 1000, "pid": 1, "name": None, "parent": None, "keep": True,
                "cwd": cwd, "foreground": {"argv": ["claude"], "cwd": cwd, "name": "claude", "pid": 1},
                "status": {"app": "claude-code", "state": status},
                "labels": {"jk.claude.session": sid, "where": f"proj / {tab}", **({"factory.key": key} if key else {})}}

    def run_reap(self, terminals, bg=(), *flags, flip_after=None, flip_terminals=None, child_after=None,
                 child_of="t1", replace_after=None, replace_addr="t1", core_down=False,
                 own="own", extra_env=None, **world):
        with open(self.world, "w") as f:
            json.dump({"terminals": list(terminals), "bg": list(bg), "flip_after": flip_after,
                       "flip_terminals": flip_terminals, "child_after": child_after, "child_of": child_of,
                       "replace_after": replace_after, "replace_addr": replace_addr, **world}, f)
        down = os.path.join(self.t, "core_down")
        if core_down:
            write(down, "")
        env = dict(os.environ, HOME=self.home, PATH=f"{self.bin}:{os.environ['PATH']}", FAKE_WORLD=self.world,
                   FAKE_CALLS=self.calls, FAKE_CORE_DOWN=down, CORE_UP_SH=os.path.join(self.bin, "core-up.sh"), HC_TERMINAL_ID=own, REAP_IDLE_H="12")
        env.pop("HC_SESSION", None)
        env.update(extra_env or {})
        r = subprocess.run([sys.executable, REAP, *flags], env=env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.last_out = r.stdout
        return self.calls_text()

    def calls_text(self):
        with open(self.calls) as f:
            return f.read()

    def log(self):
        p = os.path.join(self.home, "Library/Logs/hc-reap.log")
        if not os.path.exists(p):
            return ""
        with open(p) as f:
            return f.read()

    def test_closes_idle_clean_pushed(self):
        r = self.repo("a")
        calls = self.run_reap([self.agent("p1", "t1", "idle", r)])
        self.assertIn("kill t1", calls)
        self.assertIn("close terminal=t1", self.log())

    def test_plan_tab_idle_for_days_is_kept(self):
        r = self.repo("a")
        calls = self.run_reap([self.agent("p1", "t1", "idle", r, idle_h=96, key="plan:a")])
        self.assertNotIn("kill", calls)
        self.assertIn("plan tab (plan:a)", self.last_out)

    def test_keyless_terminal_idle_is_kept(self):
        r = self.repo("a")
        calls = self.run_reap([self.agent("p1", "t1", "idle", r, idle_h=96, key=None)])
        self.assertNotIn("kill", calls)
        self.assertIn("no factory.key label", self.last_out)

    def test_keyless_dirty_terminal_is_not_messaged(self):
        r = self.repo("a", dirty=True)
        calls = self.run_reap([self.agent("p1", "t1", "idle", r, idle_h=96, key=None)])
        self.assertNotIn("send", calls)

    def test_keyed_idle_terminal_beside_a_plan_tab_is_still_reaped(self):
        r = self.repo("a")
        calls = self.run_reap([self.agent("p1", "t1", "idle", r, key="plan:a"),
                               self.agent("p2", "t2", "idle", r, key="fan:x")])
        self.assertNotIn("kill t1", calls)
        self.assertIn("kill t2", calls)

    def shell(self, addr, **kw):
        """A live login shell as `terminal.list` returns it: no status, no name, no labels, `turn` 3."""
        rec = {"address": addr, "state": "live", "created_ms": 5000, "pid": 1, "turn": 3,
               "name": None, "parent": None, "keep": True, "cwd": "/", "argv": ["/bin/zsh", "-l"],
               "foreground": {"argv": ["zsh"], "cwd": "/", "name": "zsh", "pid": 1}, "status": None, "labels": {"where": "proj / 1"}}
        rec.update(kw)
        return rec

    def seed_shell(self, addr, turn=3, days_ago=8):
        """hc-reap's state file as an earlier run left it: this terminal's `turn` last changed `days_ago` ago."""
        path = os.path.join(self.home, ".local/state/hc-reap/messaged.json")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        try:
            with open(path) as f:
                st = json.load(f)
        except OSError:
            st = {}
        st[f"shell:{addr}:5000"] = {"turn": turn, "at": time.time() - days_ago * 86400}
        with open(path, "w") as f:
            json.dump(st, f)

    def test_shell_with_turn_unchanged_for_seven_days_is_closed(self):
        self.seed_shell("s1")
        calls = self.run_reap([self.shell("s1")])
        self.assertIn("kill s1", calls)
        self.assertIn("rm s1", calls)
        self.assertIn("close terminal=s1", self.log())

    def test_dry_run_lists_the_shell_and_changes_nothing(self):
        self.seed_shell("s1")
        calls = self.run_reap([self.shell("s1")], (), "--dry-run")
        self.assertNotIn("kill", calls)
        self.assertIn("close terminal=s1", self.last_out)
        self.assertEqual(self.log(), "")

    def test_shell_whose_turn_moved_a_day_ago_is_kept(self):
        self.seed_shell("s1", turn=2, days_ago=1)
        self.assertNotIn("kill", self.run_reap([self.shell("s1", turn=3)]))
        self.seed_shell("s2", turn=3, days_ago=1)
        self.assertNotIn("kill", self.run_reap([self.shell("s2", turn=3)]))

    def test_turn_that_moved_restarts_the_clock_even_after_eight_days(self):
        self.seed_shell("s1", turn=2, days_ago=8)
        self.assertNotIn("kill", self.run_reap([self.shell("s1", turn=3)]))

    def test_first_sighting_of_an_old_terminal_is_kept_and_remembered(self):
        self.assertNotIn("kill", self.run_reap([self.shell("s1", created_ms=1000)]))
        with open(os.path.join(self.home, ".local/state/hc-reap/messaged.json")) as f:
            self.assertIn("shell:s1:1000", json.load(f))

    def test_shell_without_a_turn_is_kept_and_gets_no_clock(self):
        rec = self.shell("s1")
        del rec["turn"]
        self.assertNotIn("kill", self.run_reap([rec]))
        with open(os.path.join(self.home, ".local/state/hc-reap/messaged.json")) as f:
            self.assertNotIn("shell:s1:5000", json.load(f))

    def test_plan_tab_shell_is_kept(self):
        self.seed_shell("s1")
        self.assertNotIn("kill", self.run_reap([self.shell("s1", labels={"factory.key": "plan:a"})]))

    def test_named_shell_is_kept(self):
        self.seed_shell("s1")
        self.assertNotIn("kill", self.run_reap([self.shell("s1", name="relogin-me")]))

    def test_shell_with_a_claude_label_is_kept(self):
        self.seed_shell("s1")
        self.assertNotIn("kill", self.run_reap([self.shell("s1", labels={"jk.claude.session": "abc"})]))

    def test_shell_running_a_program_is_kept(self):
        self.seed_shell("s1")
        fg = {"argv": ["vim"], "cwd": "/", "name": "vim", "pid": 2}
        self.assertNotIn("kill", self.run_reap([self.shell("s1", foreground=fg)]))

    def test_shell_with_a_child_and_the_callers_own_are_kept(self):
        for a in ("s1", "s2", "own"):
            self.seed_shell(a)
        calls = self.run_reap([self.shell("s1"), self.shell("s2", parent="s1"), self.shell("own")])
        self.assertNotIn("kill s1", calls)
        self.assertNotIn("kill own", calls)

    def test_shell_changing_before_the_close_is_kept(self):
        self.seed_shell("s1")
        calls = self.run_reap([self.shell("s1")], replace_after=2, replace_addr="s1")
        self.assertNotIn("kill", calls)

    def test_dry_run_changes_nothing(self):
        r = self.repo("a")
        calls = self.run_reap([self.agent("p1", "t1", "idle", r)], (), "--dry-run")
        self.assertNotIn("kill", calls)
        self.assertEqual(self.log(), "")

    def test_recent_idle_is_kept(self):
        r = self.repo("a")
        self.assertNotIn("kill", self.run_reap([self.agent("p1", "t1", "idle", r, idle_h=1)]))

    def test_never_working_or_blocked(self):
        r1, r2 = self.repo("a"), self.repo("b")
        calls = self.run_reap([self.agent("p1", "t1", "working", r1), self.agent("p2", "t2", "blocked", r2)])
        self.assertNotIn("kill", calls)

    def test_working_agent_in_subdir_shields_the_checkout(self):
        r = self.repo("a")
        calls = self.run_reap([self.agent("p1", "t1", "idle", r), self.agent("p2", "t2", "working", os.path.join(r, "sub"))])
        self.assertNotIn("kill", calls)
        self.assertNotIn("send", calls)

    def test_dirty_is_messaged_not_closed(self):
        r = self.repo("a", dirty=True)
        calls = self.run_reap([self.agent("p1", "t1", "done", r)])
        self.assertNotIn("kill", calls)
        self.assertIn("send t1", calls)
        # and only once per 24 h
        calls = self.run_reap([self.agent("p1", "t1", "done", r)])
        self.assertEqual(calls.count("send t1"), 1)

    def test_unpushed_is_not_closed(self):
        r = self.repo("a")
        git(r, "commit", "--allow-empty", "-qm", "local")
        self.assertNotIn("kill", self.run_reap([self.agent("p1", "t1", "idle", r)]))

    def test_non_git_cwd_shell_finished_linked_and_own_terminal_are_left_alone(self):
        r = self.repo("a")
        plain = os.path.join(self.t, "plain"); os.makedirs(plain)
        shell = dict(self.agent("s", "t4", "idle", r), status=None)  # a login shell: no status, not an agent's
        finished = dict(self.agent("f", "t5", "idle", r), state="finished")
        linked = self.agent("l", "mini/t1", "idle", r)  # the linked machine's terminal: not ours to kill
        calls = self.run_reap([self.agent("p1", "t1", "idle", plain), shell, finished, linked,
                               self.agent("own", "own", "idle", self.repo("c"))])
        self.assertNotIn("kill", calls)
        self.assertNotIn("send", calls)
        self.assertIn("cwd is not a git repo", self.last_out)
        self.assertIn("caller's own terminal", self.last_out)

    def test_orchestrator_with_a_live_child_is_kept(self):
        r = self.repo("a")
        child = dict(self.agent("c", "t2", "working", self.repo("b")), parent="t1")
        calls = self.run_reap([self.agent("p1", "t1", "idle", r), child])
        self.assertNotIn("kill", calls)
        self.assertIn("has live child terminals", self.last_out)

    def test_unlabelled_agent_has_unknown_age_and_is_kept(self):
        r = self.repo("a")
        t = self.agent("p1", "t1", "idle", r)
        t["labels"] = {"factory.key": "fan:x"}  # keyed, but no session label
        self.assertNotIn("kill", self.run_reap([t]))
        self.assertIn("idle age unknown", self.last_out)

    def test_kill_then_rm_and_a_failed_rm_is_reported(self):
        r = self.repo("a")
        calls = self.run_reap([self.agent("p1", "t1", "idle", r)])
        self.assertEqual([l for l in calls.splitlines() if l.split()[0] in ("kill", "rm")], ["kill t1", "rm t1"])
        self.run_reap([self.agent("p1", "t1", "idle", r)], fail_rm=True)
        self.assertIn("close-failed terminal=t1", self.log())

    def test_stopped_core_is_never_connected_to(self):
        r = self.repo("a")
        calls = self.run_reap([self.agent("p1", "t1", "idle", r)], core_down=True)
        self.assertNotIn("connect", calls)
        self.assertNotIn("list", calls)
        self.assertIn("terminal pass skipped", self.last_out)
        self.assertIn("core-up", calls)  # core-up.sh was asked, hc was not

    def test_scratch_core_skips_the_launchd_guard(self):
        r = self.repo("a")
        calls = self.run_reap([self.agent("p1", "t1", "idle", r)], core_down=True, extra_env={"HC_SESSION": "scratch"})
        self.assertIn("kill t1", calls)

    def test_unreadable_roster_does_not_fail_the_job(self):
        self.run_reap([], list_error=True)
        self.assertIn("terminal pass skipped", self.last_out)

    def test_new_child_under_the_terminal_before_the_close_keeps_it(self):
        r = self.repo("a")
        calls = self.run_reap([self.agent("p1", "t1", "idle", r)], child_after=1)  # a worker appears under it after the plan
        self.assertNotIn("kill", calls)
        self.assertIn("child terminal appeared", self.log())

    def test_address_reused_by_another_terminal_before_the_close_keeps_it(self):
        r = self.repo("a")
        calls = self.run_reap([self.agent("p1", "t1", "idle", r)], replace_after=1)
        self.assertNotIn("kill", calls)
        self.assertIn("the terminal changed", self.log())

    def test_status_flip_before_the_close_keeps_the_tab(self):
        r = self.repo("a")
        calls = self.run_reap([self.agent("p1", "t1", "idle", r)], flip_after=1)  # first roster read: idle; the re-query: working
        self.assertNotIn("kill", calls)
        self.assertIn("agent status changed", self.log())

    def test_another_agent_joining_the_checkout_before_the_close_keeps_it(self):
        r = self.repo("a")
        other = self.agent("p2", "t2", "idle", r)  # idle at plan time, working at the re-query
        calls = self.run_reap([self.agent("p1", "t1", "idle", r), other], flip_after=1, flip_terminals=["t2"])
        self.assertNotIn("kill", calls)

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
