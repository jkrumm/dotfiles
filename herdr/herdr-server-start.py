#!/usr/bin/python3
"""Start the herdr server as a SESSION LEADER, under launchd supervision.

THE BUG THIS EXISTS FOR. Every `desk` (`herdr --remote mini`) launch asked:

    the remote server was started by a herdr build that may not survive SSH
    connection loss. restart it so network drops disconnect only this client.
    restart the remote server now? [y/N]

Answering `y` restarts the server outside brew services and kills every process
in every pane, so the only correct answer was `N` — forever, on every launch.

It is not about the build. herdr reports `detached_server_daemon` from
`getsid(0) == getpid()` (src/platform/mod.rs), i.e. "am I a session leader?",
and the remote client refuses to stay quiet when the answer is no
(`remote_server_restart_reason`, src/remote/unix.rs). A launchd-spawned job is
NOT a session leader — measured on the mini: the brew-service server ran with
pid 671, pgid 671, **sid 1**. So the warning was true as asked and false as
meant: launchd owns the job, an ssh disconnect cannot touch it, and herdr has
no way to see that.

WHY A WRAPPER AND WHY IT FORKS. `setsid(2)` fails with EPERM when the caller is
already a process-group leader, which is exactly what launchd hands us
(pgid == pid). So the session leader has to be a *child*: fork, `setsid()` in
the child, exec herdr there. macOS ships no `setsid(1)`, hence python rather
than a shell one-liner.

The parent stays alive on purpose. It is the process launchd tracks, so exiting
early would trip `KeepAlive` and spawn a SECOND server against the same socket.
It waits, forwards SIGTERM/SIGINT/SIGHUP to the child so `brew services stop`
still stops the server, and exits with the child's status so KeepAlive restarts
a server that genuinely died.

Installed into homebrew.mxcl.herdr.plist by `make herdr-setup` (_herdr-supervise).
BREW REGENERATES THAT PLIST on every `brew services start/restart` and every
`brew upgrade herdr`, silently — same trap as colima's inverted KeepAlive and
caddy's DNS module. `make _herdr-supervise` re-converges it and
`scripts/brew-upgrade.sh` asserts it after every upgrade.
"""

import os
import signal
import sys

HERDR = os.environ.get("HERDR_SERVER_BIN", "/opt/homebrew/opt/herdr/bin/herdr")
ARGV = [HERDR, "server"]


def main() -> int:
    if not os.access(HERDR, os.X_OK):
        print(f"herdr-server-start: {HERDR} is not executable", file=sys.stderr)
        return 127

    pid = os.fork()
    if pid == 0:
        # Child: become a session leader before exec, so the server herdr sees
        # answers `getsid(0) == getpid()` with itself.
        os.setsid()
        try:
            os.execv(HERDR, ARGV)
        except OSError as err:  # pragma: no cover - exec failure is terminal
            print(f"herdr-server-start: exec failed: {err}", file=sys.stderr)
            os._exit(126)

    # Parent: launchd's tracked process. Relay the signals that mean "stop" —
    # the child is in its own session now, so launchd's own SIGTERM does not
    # reach it and `brew services stop herdr` would otherwise leave it running.
    def relay(signum, _frame):
        try:
            os.kill(pid, signum)
        except ProcessLookupError:
            pass

    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, relay)

    while True:
        try:
            _, status = os.waitpid(pid, 0)
        except InterruptedError:
            continue
        except ChildProcessError:
            return 0
        if os.WIFEXITED(status):
            return os.WEXITSTATUS(status)
        if os.WIFSIGNALED(status):
            return 128 + os.WTERMSIG(status)


if __name__ == "__main__":
    sys.exit(main())
