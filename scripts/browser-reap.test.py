#!/usr/bin/env python3
"""Hermetic tests for browser-reap.py. Real throwaway processes whose argv carries a --user-data-dir (a python
sleeper), orphaned to launchd by a double fork. BROWSER_REAP_TMPDIR points the "temp root" at a tmpdir and
MIN_AGE_S is 0 (reapable) or huge (young). Run: python3 scripts/browser-reap.test.py"""
import os
import subprocess
import sys
import tempfile
import time
import unittest

REAP = os.path.join(os.path.dirname(os.path.abspath(__file__)), "browser-reap.py")
SLEEPER = "import time; time.sleep(120)"


def spawn(udd: str | None, orphan: bool, extra: tuple[str, ...] = ()) -> subprocess.Popen | int:
    """A sleeper carrying --user-data-dir. orphan=True: double-forked so its parent is launchd; returns its pid."""
    argv = ["python3", "-c", SLEEPER] + ([f"--user-data-dir={udd}"] if udd else []) + list(extra)
    if not orphan:
        return subprocess.Popen(argv)
    out = subprocess.run(["sh", "-c", '"$@" >/dev/null 2>&1 & echo $!', "sh"] + argv, capture_output=True, text=True)
    return int(out.stdout.strip())


def alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    # a zombie child of this test is dead for our purposes
    st = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    return bool(st) and not st.startswith("Z")


def ppid(pid: int) -> int:
    return int(subprocess.run(["ps", "-o", "ppid=", "-p", str(pid)], capture_output=True, text=True).stdout.strip())


class BrowserReap(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(dir=os.path.realpath(tempfile.gettempdir()))
        self.pids: list[int] = []
        self.procs: list[subprocess.Popen] = []

    def tearDown(self):
        for pid in self.pids:
            try:
                os.kill(pid, 9)
            except ProcessLookupError:
                pass
        for p in self.procs:
            p.kill()
            p.wait()
        subprocess.run(["rm", "-rf", self.tmp])

    def orphan(self, udd, **kw):
        pid = spawn(udd, True, **kw)
        self.pids.append(pid)
        deadline = time.time() + 5
        while time.time() < deadline and ppid(pid) != 1:
            time.sleep(0.05)
        self.assertEqual(ppid(pid), 1, "fixture did not orphan to launchd")
        return pid

    def child(self, udd):
        p = spawn(udd, False)
        self.procs.append(p)
        return p

    def reap(self, min_age="0", dry=False):
        env = dict(os.environ, BROWSER_REAP_TMPDIR=self.tmp, BROWSER_REAP_MIN_AGE_S=min_age, BROWSER_REAP_GRACE_S="1")
        r = subprocess.run([sys.executable, REAP] + (["--dry-run"] if dry else []), env=env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout

    def wait_dead(self, pid):
        deadline = time.time() + 5
        while time.time() < deadline and alive(pid):
            time.sleep(0.05)
        return not alive(pid)

    # ---- ends
    def test_ends_an_orphaned_old_playwright_tree(self):
        udd = os.path.join(self.tmp, "playwright_chromiumdev_profile-AbC123")
        a, b = self.orphan(udd), self.orphan(udd)
        out = self.reap()
        self.assertTrue(self.wait_dead(a) and self.wait_dead(b), out)
        self.assertIn("ended", out)
        self.assertIn("playwright_chromiumdev_profile-AbC123", out)

    def test_ends_a_puppeteer_tree(self):
        pid = self.orphan(os.path.join(self.tmp, "puppeteer_dev_chrome_profile-xYz"))
        self.reap()
        self.assertTrue(self.wait_dead(pid))

    def test_dry_run_kills_nothing(self):
        pid = self.orphan(os.path.join(self.tmp, "playwright_chromiumdev_profile-dry"))
        out = self.reap(dry=True)
        self.assertIn("would-end", out)
        self.assertTrue(alive(pid))

    # ---- the never cases
    def test_never_the_owners_chrome_without_user_data_dir(self):
        pid = self.orphan(None)
        self.reap()
        self.assertTrue(alive(pid))

    def test_never_a_persistent_profile_like_research_chrome(self):
        persistent = os.path.join(self.tmp, "home", ".local", "share", "research-chrome")
        named_like_a_test_profile_outside_temp = os.path.join("/nonexistent-root", "playwright_chromiumdev_profile-keep")
        a = self.orphan(persistent)
        b = self.orphan(named_like_a_test_profile_outside_temp)
        self.reap()
        self.assertTrue(alive(a) and alive(b))

    def test_never_a_tree_whose_launcher_is_alive(self):
        udd = os.path.join(self.tmp, "playwright_chromiumdev_profile-live")
        p = self.child(udd)  # parent is this test process
        out = self.reap()
        self.assertTrue(alive(p.pid), out)

    def test_never_a_young_tree(self):
        pid = self.orphan(os.path.join(self.tmp, "playwright_chromiumdev_profile-young"))
        self.reap(min_age="3600")
        self.assertTrue(alive(pid))

    def test_ends_only_the_orphaned_tree_among_mixed(self):
        dead = self.orphan(os.path.join(self.tmp, "playwright_chromiumdev_profile-dead"))
        keep = self.child(os.path.join(self.tmp, "playwright_chromiumdev_profile-keep"))
        self.reap()
        self.assertTrue(self.wait_dead(dead))
        self.assertTrue(alive(keep.pid))


if __name__ == "__main__":
    unittest.main()
