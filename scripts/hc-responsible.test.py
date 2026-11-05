#!/usr/bin/env python3
"""Hermetic tests for hc-responsible.py: the ps and ctypes layers are faked. Run: python3 scripts/hc-responsible.test.py"""
import contextlib
import importlib.util
import io
import os
import unittest

spec = importlib.util.spec_from_file_location("hcr", os.path.join(os.path.dirname(os.path.abspath(__file__)), "hc-responsible.py"))
hcr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hcr)

APP = "/Users/x/.local/share/herdr-core/active/Herdr Core.app/Contents/MacOS/herdr-core"
CELLAR = "/opt/homebrew/Cellar/herdr-core/0.1.17/bin/herdr-core"
TABLE = [
    (1, "/sbin/launchd"),
    (100, f"{APP} --hc-launchd /tmp/hc-launchd-1-2-x/ready"),
    (200, f"{APP} hold --socket /s"),
    (300, f"{CELLAR} hold --socket /s"),
    (400, "/bin/zsh -l"),
]
RESP = {100: 100, 200: 200, 300: 300, 400: 200}
EXE = {100: APP, 200: APP, 300: CELLAR}


def run(pids):
    return hcr.check(pids, table=lambda: TABLE, exe=lambda p: EXE.get(p, "/usr/sbin/sshd"), resp=lambda p: RESP.get(p, -1))


class Responsible(unittest.TestCase):
    def test_core_and_holders_are_selected_not_terminal_programs(self):
        self.assertEqual([(p, r) for p, r, _ in hcr.targets(TABLE, [])], [(100, "core"), (200, "holder"), (300, "holder")])

    def test_cellar_holder_is_the_offender(self):
        lines, bad = run([])
        self.assertEqual(len(lines), 3)
        self.assertEqual(len(bad), 1)
        self.assertIn("300", bad[0])
        self.assertIn("NOT Herdr Core.app", bad[0])

    def test_explicit_pid_whose_responsible_is_the_bundle_is_ok(self):
        _, bad = run([400])
        self.assertEqual(bad, [])

    def test_unknown_responsible_is_an_offender(self):
        lines, bad = hcr.check([500], table=lambda: TABLE, exe=lambda p: "", resp=lambda p: -1)
        self.assertEqual(len(bad), 1)
        self.assertIn("unknown", lines[0])

    def test_main_exit_codes(self):
        orig = hcr.check
        out = contextlib.redirect_stdout(io.StringIO())
        out.__enter__()
        try:
            hcr.check = lambda pids: ([], [])
            self.assertEqual(hcr.main([]), 0)
            hcr.check = lambda pids: (["a"], ["a"])
            self.assertEqual(hcr.main([]), 1)
            hcr.check = lambda pids: (["a"], [])
            self.assertEqual(hcr.main([]), 0)
        finally:
            hcr.check = orig
            out.__exit__(None, None, None)
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(hcr.main(["x"]), 2)


if __name__ == "__main__":
    unittest.main()
