#!/usr/bin/python3
"""Start and supervise the herdr server, under launchd.

THE BUG THIS EXISTS FOR (part 1). Every `desk` (`herdr --remote mini`) launch
asked:

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

WHY A WRAPPER AND WHY IT FORKS. `herdr server` runs in the FOREGROUND: it binds
its sockets and blocks in `server.run()` (src/server/headless/bootstrap.rs). It
does NOT daemonise itself. The detached-server daemon is produced by the CLIENT
auto-spawn path, which sets `setsid()` and a Mach user-context before exec'ing
`herdr server` (src/platform/mod.rs `detach_server_daemon_command`) — a launchd
job is not that client, so it still needs the fork here. `setsid(2)` fails with
EPERM when the caller is already a process-group leader, which is exactly what
launchd hands us (pgid == pid), so the session leader has to be a *child*:
fork, `setsid()` in the child, exec herdr there. macOS ships no `setsid(1)`,
hence python rather than a shell one-liner.

THE BUG THIS EXISTS FOR (part 2) — THE RESPAWN LOOP. `herdr server` exits
NON-ZERO (`error: herdr server is already running`) when another server already
holds the socket (bootstrap.rs). This plist carries an unconditional
`KeepAlive true`, so a wrapper that simply forwarded its child's exit status
turned that into a hot loop: whenever a server was already running — a `desk`
attach auto-spawns one, or a previous incarnation survived a job reload — every
launchd respawn re-forked, the child hit AddrInUse, exited 1, the parent
returned 1, and launchd respawned roughly every 10s forever.

A server that is already up is the state this job exists to maintain, not a
failure. So this wrapper stays alive as long as *some* server answers the
socket and exits (non-zero, for KeepAlive) only when none does. If its own child
loses an AddrInUse race, it adopts the running server instead of dying with it.
That keeps the launchd job up, which is what stops KeepAlive respawning.

UNREADABLE IS NOT "DOWN". `herdr status --json` prints `"running": false` and
still exits 0 against a missing socket, so only the parsed body tells the truth
(scripts/lib/herdr-ready.sh makes the same point). When the body cannot be read
at all the answer is UNKNOWN, and every branch treats it as "assume a server is
up": a probe failure must never fork a second server onto a held socket or exit
into the respawn loop this wrapper exists to stop.

Signals: the child is in its own session, so launchd's SIGTERM does not reach
it; the wrapper relays SIGTERM/SIGINT/SIGHUP to a child it started, then exits,
so `brew services stop` still stops a wrapper-owned server. A stop that lands
before the child exists (during the status probe or the fork) is remembered and
delivered once it does, and a child that ignores the relay is SIGKILLed after a
grace period with a log line — otherwise a stop during startup orphans the
freshly forked server. A server the wrapper adopted (it did not start) is left
running — it may be a `desk` auto-spawn the user expects to persist, and
bootout deliberately does not stop a detached daemon.

Installed into herdr's brew-service plist by `make herdr-setup`
(_herdr-supervise) — `sh.brew.herdr.plist` since Homebrew 6, renamed from
`homebrew.mxcl.herdr.plist` on the next start/restart rather than at upgrade
time, so every caller resolves it via scripts/lib/brew-service.sh instead of
spelling a label. BREW REGENERATES THAT PLIST on every `brew services
start/restart` and every `brew upgrade herdr`, silently — same trap as colima's
inverted KeepAlive and caddy's DNS module. `make _herdr-supervise` re-converges it and
`scripts/brew-upgrade.sh` asserts it after every upgrade.
"""

import json
import os
import signal
import subprocess
import sys
import time

HERDR = os.environ.get("HERDR_SERVER_BIN", "/opt/homebrew/opt/herdr/bin/herdr")
ARGV = [HERDR, "server"]

# How long between socket liveness probes while supervising.
POLL_SECONDS = float(os.environ.get("HERDR_SUPERVISOR_POLL_SECONDS", "10"))
# A `herdr status` that hangs must not hang the supervisor.
STATUS_TIMEOUT_SECONDS = float(
    os.environ.get("HERDR_SUPERVISOR_STATUS_TIMEOUT_SECONDS", "15")
)
# How long to let a relayed stop reach our child before SIGKILLing it.
STOP_GRACE_SECONDS = float(
    os.environ.get("HERDR_SUPERVISOR_STOP_GRACE_SECONDS", "10")
)
# Sleep granularity, so a stop is acted on promptly rather than after a full poll.
SLEEP_STEP_SECONDS = float(
    os.environ.get("HERDR_SUPERVISOR_SLEEP_STEP_SECONDS", "0.2")
)


def server_running():
    """True/False when `herdr status` can tell, None when it cannot.

    THE EXIT CODE IS NOT THE SIGNAL: against a socket that does not exist
    `herdr status` prints `"running": false` and still exits 0, so only the
    parsed body says anything true. None means UNREADABLE — never "no server".
    """
    try:
        proc = subprocess.run(
            [HERDR, "status", "--json"],
            capture_output=True,
            text=True,
            timeout=STATUS_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    try:
        server = json.loads(proc.stdout).get("server")
    except (ValueError, AttributeError):
        return None
    if not isinstance(server, dict) or "running" not in server:
        return None
    return bool(server["running"])


def start_server():
    """Fork a session-leader child running `herdr server`; return its pid.

    The child never returns: `os.execv` replaces it with the server, which runs
    in the foreground for as long as the socket is up.
    """
    pid = os.fork()
    if pid == 0:
        os.setsid()
        try:
            os.execv(HERDR, ARGV)
        except OSError as err:  # pragma: no cover - exec failure is terminal
            print(f"herdr-server-start: exec failed: {err}", file=sys.stderr)
            os._exit(126)
    return pid


def exit_status(status):
    if status is None:
        return 1
    if os.WIFEXITED(status):
        return os.WEXITSTATUS(status)
    if os.WIFSIGNALED(status):
        return 128 + os.WTERMSIG(status)
    return 1


def signal_child(state, signum):
    """Forward a stop signal to the child we started, if any."""
    child = state["child"]
    if child is None:
        return
    try:
        os.kill(child, signum)
    except ProcessLookupError:
        pass


def sleep_interruptibly(seconds, state):
    """Sleep in small steps so a stop is acted on within SLEEP_STEP_SECONDS."""
    deadline = time.monotonic() + seconds
    while not state["stopping"] and time.monotonic() < deadline:
        time.sleep(SLEEP_STEP_SECONDS)


def wait_for_child(state):
    """Block until our child exits or a stop is requested.

    Returns the child's wait status, or None when it was reaped on the stop path
    (or had already been reaped).
    """
    while not state["stopping"]:
        try:
            done, status = os.waitpid(state["child"], os.WNOHANG)
        except ChildProcessError:
            return None
        if done:
            return status
        sleep_interruptibly(POLL_SECONDS, state)
    reap_child(state)
    return None


def reap_child(state):
    """Give a signalled child STOP_GRACE_SECONDS to exit, then SIGKILL it."""
    child = state["child"]
    if child is None:
        return
    deadline = time.monotonic() + STOP_GRACE_SECONDS
    while time.monotonic() < deadline:
        try:
            done, _ = os.waitpid(child, os.WNOHANG)
        except ChildProcessError:
            return
        if done:
            return
        time.sleep(SLEEP_STEP_SECONDS)
    print(
        f"herdr-server-start: child did not exit within {STOP_GRACE_SECONDS}s"
        " — sending SIGKILL",
        file=sys.stderr,
    )
    try:
        os.kill(child, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        os.waitpid(child, 0)
    except ChildProcessError:
        pass


def supervise(state):
    """Stay alive while a server answers the socket.

    This is the whole job in the adopted case: the plist carries an
    unconditional `KeepAlive`, so exiting is what triggers a respawn. Exit
    non-zero only when `herdr status` can AFFIRM there is no server left
    (`is False`); an unreadable status keeps us alive rather than reopening the
    hot-respawn loop.
    """
    while not state["stopping"]:
        if server_running() is False:
            print(
                "herdr-server-start: server is gone — exiting for KeepAlive",
                file=sys.stderr,
            )
            return 1
        sleep_interruptibly(POLL_SECONDS, state)
    return 0


def main():
    if not os.access(HERDR, os.X_OK):
        print(f"herdr-server-start: {HERDR} is not executable", file=sys.stderr)
        return 127

    state = {"stopping": False, "stop_signal": None, "child": None}

    def relay(signum, _frame):
        state["stopping"] = True
        state["stop_signal"] = signum
        signal_child(state, signum)

    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, relay)

    initial = server_running()
    if initial is False:
        # Affirmatively no server: fork ours. A stop that arrived during the
        # status probe or the fork had no child to signal yet, so deliver it now
        # that one exists.
        state["child"] = start_server()
        if state["stopping"]:
            signal_child(state, state["stop_signal"] or signal.SIGTERM)
        status = wait_for_child(state)
        if state["stopping"]:
            return 0
        # The child exited on its own. If no server answers, it is genuinely gone
        # and its status goes to KeepAlive so the server is restarted. If one
        # does answer, the child lost a start race (AddrInUse) and we adopt the
        # running server instead of dying with it. An unreadable status is
        # neither — adopt, so a probe failure cannot reopen the respawn loop.
        if server_running() is False:
            return exit_status(status)
        state["child"] = None  # never signal a reaped, possibly recycled pid
        print(
            "herdr-server-start: another server holds the socket — supervising it",
            file=sys.stderr,
        )
    elif initial is True:
        print(
            "herdr-server-start: server already running — supervising it",
            file=sys.stderr,
        )
    else:
        print(
            "herdr-server-start: status unreadable — supervising without forking",
            file=sys.stderr,
        )

    return supervise(state)


if __name__ == "__main__":
    sys.exit(main())
