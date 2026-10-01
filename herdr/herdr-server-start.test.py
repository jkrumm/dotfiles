#!/usr/bin/python3
"""Regression suite for herdr/herdr-server-start.py — the launchd supervision wrapper.

Run: make herdr-server-start-test
 (or: /usr/bin/python3 herdr/herdr-server-start.test.py)

Hermetic by construction: the wrapper is driven as a REAL subprocess, but HERDR is
a fake over a scratch dir, so no herdr server, socket, plist or LaunchAgent is
touched. Every case below is a reviewed finding rather than a nicety — four of
them were blocking findings on a step-7 review of this wrapper:

1. An unreadable status (`herdr status --json` body unparseable) at STARTUP must
   still fork. Waiting in supervise() for an affirmative `false` is a job that
   stays alive with no server ever started and no KeepAlive respawn to fix it.
   A speculative fork is safe because a held socket makes the child exit
   AddrInUse and the adoption path supervises the running server.
2. An unreadable status AFTER our own child exited adopts and supervises — it is
   neither "gone" (that is an affirmed false, which exits for KeepAlive) nor
   "another server confirmed up".
3. A momentarily non-executable binary (brew upgrade, path race) is the same
   UNKNOWN and must not `exit 127` — under unconditional KeepAlive that is a
   respawn loop for the length of the upgrade.
4. The forked child resets the relayed stop signals to SIG_DFL before exec: in
   the fork-to-exec window the inherited handler runs inside the child's own copy
   of `state` (where child = None), no-ops, and lets a server start while the
   parent reports a clean stop.
5. The wrapper's whole reason to exist: a child that cannot start exits non-zero
   so KeepAlive restarts it, and a stop signal is relayed to a child that WAS
   started (that child is in its own session, so launchd cannot reach it).
"""

import importlib.util
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
WRAPPER = os.path.join(HERE, "herdr-server-start.py")

# A stand-in for `herdr`. `status --json` answers per FAKE_MODE; `server` claims a
# lock file and then blocks in the foreground exactly like the real server does,
# writing its pid so a test can prove the stop relay reached it.
FAKE_HERDR = r'''#!/usr/bin/python3
import json, os, sys, time

mode = os.environ.get("FAKE_MODE", "unreadable")
if sys.argv[1:2] == ["status"]:
    if mode == "running":
        print(json.dumps({"server": {"running": True}}))
    elif mode == "absent":
        print(json.dumps({"server": {"running": False}}))
    else:
        # What an unreachable socket or a timing-out probe looks like: exit 0,
        # with no parseable body. The exit code is NOT the signal.
        sys.stdout.write("herdr: cannot talk to the server\n")
        sys.stdout.flush()
    sys.exit(0)

if os.path.exists(os.environ["FAKE_LOCK"]):
    sys.stderr.write("error: herdr server is already running\n")
    sys.exit(1)
open(os.environ["FAKE_LOCK"], "w").close()
with open(os.environ["FAKE_STARTED"], "w") as fh:
    fh.write(str(os.getpid()))
while True:
    time.sleep(0.05)
'''


def wait_for(predicate, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.05)
    return False


def pid_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:  # pragma: no cover - not our own pid
        return True
    return True


class WrapperCase(unittest.TestCase):
    """Drives the wrapper as launchd would: one process, hermetic fake herdr."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="herdr-wrapper-test.")
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.fake = os.path.join(self.tmp, "herdr")
        with open(self.fake, "w") as fh:
            fh.write(FAKE_HERDR)
        os.chmod(self.fake, 0o755)
        self.lock = os.path.join(self.tmp, "server.lock")
        self.started = os.path.join(self.tmp, "server.pid")
        self.procs = []
        self.addCleanup(self._reap)

    def _reap(self):
        for proc in self.procs:
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:  # pragma: no cover
                    proc.kill()
            for stream in (proc.stdout, proc.stderr):
                if stream and not stream.closed:
                    stream.close()

    def start(self, mode, herdr=None, **env_extra):
        env = dict(os.environ)
        env.update(
            {
                "HERDR_SERVER_BIN": herdr or self.fake,
                "FAKE_MODE": mode,
                "FAKE_LOCK": self.lock,
                "FAKE_STARTED": self.started,
                "HERDR_SUPERVISOR_POLL_SECONDS": "0.2",
                "HERDR_SUPERVISOR_SLEEP_STEP_SECONDS": "0.05",
                "HERDR_SUPERVISOR_STATUS_TIMEOUT_SECONDS": "2",
                "HERDR_SUPERVISOR_STOP_GRACE_SECONDS": "2",
            }
        )
        env.update(env_extra)
        proc = subprocess.Popen(
            [WRAPPER],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
        )
        self.procs.append(proc)
        return proc

    def stopped(self, proc, timeout=10):
        """Stop like launchd does, assert a clean stop, return (rc, stderr)."""
        proc.terminate()
        rc = proc.wait(timeout=timeout)
        return rc, proc.stderr.read()

    def test_unreadable_status_at_startup_still_starts_a_server(self):
        proc = self.start("unreadable")
        self.assertTrue(
            wait_for(lambda: os.path.exists(self.started), 10),
            "no server was ever started: the wrapper supervised an unreadable "
            "status for a socket nobody held",
        )
        self.assertIsNone(proc.poll(), "the wrapper exited while supervising")
        rc, err = self.stopped(proc)
        self.assertEqual(rc, 0)
        self.assertIn("status unreadable — forking speculatively", err)

    def test_the_started_server_dies_with_the_wrapper(self):
        proc = self.start("unreadable")
        self.assertTrue(wait_for(lambda: os.path.exists(self.started), 10))
        with open(self.started) as fh:
            child = int(fh.read())
        self.assertTrue(pid_alive(child))
        rc, _err = self.stopped(proc)
        self.assertEqual(rc, 0)
        self.assertTrue(
            wait_for(lambda: not pid_alive(child), 5),
            "the relayed stop did not reach the forked server — it would be "
            "orphaned and unsupervised",
        )

    def test_unreadable_after_child_exit_supervises_defensively(self):
        open(self.lock, "w").close()  # a server already holds the socket
        proc = self.start("unreadable")
        time.sleep(1.5)
        self.assertIsNone(proc.poll(), "an unreadable status must not exit")
        rc, err = self.stopped(proc)
        self.assertEqual(rc, 0)
        self.assertIn("supervising defensively", err)
        self.assertFalse(
            os.path.exists(self.started),
            "the wrapper forked onto a socket another server holds",
        )

    def test_non_executable_binary_supervises_instead_of_exiting_127(self):
        broken = os.path.join(self.tmp, "herdr-mid-upgrade")
        with open(broken, "w") as fh:
            fh.write("#!/bin/sh\nexit 0\n")
        os.chmod(broken, 0o644)
        proc = self.start("absent", herdr=broken)
        time.sleep(1.5)
        self.assertIsNone(
            proc.poll(),
            "a non-executable binary exited the wrapper (127) — under KeepAlive "
            "that is a respawn loop for the whole upgrade window",
        )
        rc, err = self.stopped(proc)
        self.assertEqual(rc, 0)
        self.assertIn("is not executable", err)

    def test_confirmed_running_server_is_adopted_without_forking(self):
        proc = self.start("running")
        time.sleep(1.5)
        self.assertIsNone(proc.poll())
        self.assertFalse(os.path.exists(self.started))
        rc, err = self.stopped(proc)
        self.assertEqual(rc, 0)
        self.assertIn("server already running — supervising it", err)

    def test_a_child_that_cannot_start_exits_nonzero_for_keepalive(self):
        open(self.lock, "w").close()  # the child will hit AddrInUse and exit 1
        proc = self.start("absent")
        rc = proc.wait(timeout=10)
        self.assertEqual(rc, 1, "the wrapper must not report a clean stop here")
        err = proc.stderr.read()
        self.assertIn("no server — forking one", err)


class ChildDisposition(unittest.TestCase):
    """Unit level: what the forked child sees in the fork-to-exec window."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="herdr-wrapper-unit.")
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.probe = os.path.join(self.tmp, "dispositions.json")
        os.environ["HERDR_SERVER_BIN"] = os.path.join(self.tmp, "herdr")
        spec = importlib.util.spec_from_file_location("herdr_server_start", WRAPPER)
        self.wrapper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.wrapper)

    def test_the_forked_child_resets_the_stop_signals_before_exec(self):
        def relay(_signum, _frame):  # pragma: no cover - never invoked
            pass

        for sig in self.wrapper.STOP_SIGNALS:
            signal.signal(sig, relay)

        probe = self.probe
        signals = self.wrapper.STOP_SIGNALS

        def fake_execv(_path, _argv):  # runs in the child
            with open(probe, "w") as fh:
                json.dump([signal.getsignal(s) is signal.SIG_DFL for s in signals], fh)
            os._exit(0)

        original = os.execv
        os.execv = fake_execv
        try:
            pid = self.wrapper.start_server()
        finally:
            os.execv = original
        os.waitpid(pid, 0)

        with open(self.probe) as fh:
            inherited_defaults = json.load(fh)
        self.assertEqual(
            inherited_defaults,
            [True] * len(signals),
            "the child still held the parent's relay handler: a stop in the "
            "fork-to-exec window would no-op there and exec the server anyway",
        )
        for sig in signals:
            self.assertIs(
                signal.getsignal(sig), relay, "the parent's own handler was reset"
            )


if __name__ == "__main__":
    unittest.main(verbosity=2)
