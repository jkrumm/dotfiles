#!/usr/bin/env python3
"""Hermetic tests for factory-spaces.py: temp HOME, a fixture groups.json, fake repo dirs.
Run: python3 scripts/factory-spaces.test.py"""
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "factory-spaces.py")


class Spaces(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp()
        self.groups = os.path.join(self.home, "groups.json")
        self.out = os.path.join(self.home, ".config", "factory", "spaces.json")
        with open(self.groups, "w") as f:
            json.dump({"noFactorySpace": ["skipped"],
                       "groups": [{"label": "A", "members": ["IuRoot", "beta", "alpha", "work", "ghost", "skipped"]},
                                  {"label": "B", "members": ["gamma", "beta"]}]}, f)
        for root, name in (("SourceRoot", "alpha"), ("SourceRoot", "beta"), ("SourceRoot", "gamma"),
                           ("SourceRoot", "skipped"), ("IuRoot", "work"), ("IuRoot", "alpha")):
            os.makedirs(os.path.join(self.home, root, name))

    def run_script(self):
        r = subprocess.run([sys.executable, SCRIPT, "--groups", self.groups, "--out", self.out],
                           env=dict(os.environ, HOME=self.home), capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout

    def spaces(self):
        with open(self.out) as f:
            return json.load(f)["spaces"]

    def test_order_kept_both_roots_missing_and_listed_skipped_duplicates_once(self):
        self.run_script()
        p = lambda n: os.path.join(self.home, "SourceRoot", n)
        work = os.path.join(self.home, "IuRoot")
        self.assertEqual(self.spaces(), [
            {"name": "IuRoot", "path": work},  # the work root itself, for the cross-repo planner
            {"name": "beta", "path": p("beta")},
            {"name": "alpha", "path": p("alpha")},  # in both roots: SourceRoot wins
            {"name": "work", "path": os.path.join(work, "work")},  # "ghost" missing, "skipped" listed
            {"name": "gamma", "path": p("gamma")},  # second "beta" dropped
        ])

    def test_mode_and_idempotent(self):
        self.assertIn("wrote", self.run_script())
        self.assertEqual(stat.S_IMODE(os.stat(self.out).st_mode), 0o644)
        ino, mtime = os.stat(self.out).st_ino, os.stat(self.out).st_mtime_ns
        self.assertIn("unchanged", self.run_script())
        st = os.stat(self.out)
        self.assertEqual((st.st_ino, st.st_mtime_ns), (ino, mtime))
        self.assertEqual(os.listdir(os.path.dirname(self.out)), ["spaces.json"])  # no temp left behind

    def test_changed_groups_rewrite(self):
        self.run_script()
        os.makedirs(os.path.join(self.home, "SourceRoot", "ghost"))
        self.assertIn("wrote", self.run_script())
        self.assertIn("ghost", [s["name"] for s in self.spaces()])

    def test_unreadable_groups_fails_without_writing(self):
        os.unlink(self.groups)
        r = subprocess.run([sys.executable, SCRIPT, "--groups", self.groups, "--out", self.out],
                           env=dict(os.environ, HOME=self.home), capture_output=True, text=True)
        self.assertEqual(r.returncode, 1)
        self.assertFalse(os.path.exists(self.out))


if __name__ == "__main__":
    unittest.main()
