#!/usr/bin/env python3
"""hc-responsible — who macOS holds responsible for the herdr-core processes (docs/herdr-core.md §How the core runs now).

Terminal programs take the identity of their holder, the holder and the core their own: file-access prompts and Full
Disk Access are judged on the *responsible* process. It must be a process whose executable is inside `Herdr Core.app`
(upstream's signed bundle, the one the grant is on). A Homebrew Cellar herdr-core, sshd or a launcher as the
responsible process means the grant does not cover that holder's terminals.

Usage: hc-responsible.py [pid ...]   with pids: check those processes; without: the core (`herdr-core --hc-launchd`)
                                     and every `herdr-core hold`.
Prints one line per process; exit 0 all responsible processes are the bundle, 1 offenders (listed last), 0 with a note
when no core runs (core-up.sh owns that verdict). python3 stdlib only; read-only.
"""
import ctypes
import subprocess
import sys

BUNDLE = "Herdr Core.app/Contents/"


def process_table() -> list[tuple[int, str]]:
    """(pid, full command line) of every process of this user."""
    out = subprocess.run(["/bin/ps", "-axo", "pid=,command="], capture_output=True, text=True).stdout
    rows = []
    for line in out.splitlines():
        pid, _, cmd = line.strip().partition(" ")
        if pid.isdigit():
            rows.append((int(pid), cmd.strip()))
    return rows


def executable(pid: int) -> str:
    """Real path of the process's executable ('' when it is gone). `ps comm` prints argv[0], here the ~/.local/bin symlink."""
    buf = ctypes.create_string_buffer(4096)
    n = ctypes.CDLL("/usr/lib/libSystem.B.dylib").proc_pidpath(pid, buf, 4096)
    return buf.value.decode() if n > 0 else ""


def inherited_agent_env(pid: int) -> bool:
    """The process carries an agent's session marker: a core's environment becomes every terminal's (upstream #86), and
    a Claude started under this marker saves no transcript."""
    out = subprocess.run(["/bin/ps", "eww", "-o", "command=", "-p", str(pid)], capture_output=True, text=True).stdout
    return "CLAUDE_CODE_CHILD_SESSION=" in out


def responsible_pid(pid: int) -> int:
    lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    fn = lib.responsibility_get_pid_responsible_for_pid
    fn.argtypes = [ctypes.c_int]
    fn.restype = ctypes.c_int
    return fn(pid)


def targets(table: list[tuple[int, str]], pids: list[int]) -> list[tuple[int, str, str]]:
    """(pid, role, command): the explicit pids, else the core and every holder."""
    if pids:
        known = dict(table)
        return [(p, "pid", known.get(p, "?")) for p in pids]
    found = []
    for pid, cmd in table:
        if "herdr-core --hc-launchd" in cmd:
            found.append((pid, "core", cmd))
        elif "herdr-core hold" in cmd:
            found.append((pid, "holder", cmd))
    return found


def check(pids: list[int], table=process_table, exe=executable, resp=responsible_pid) -> tuple[list[str], list[str]]:
    """(report lines, offender lines)."""
    lines, bad = [], []
    for pid, role, cmd in targets(table(), pids):
        r = resp(pid)
        r_exe = exe(r) if r > 0 else ""
        ok = BUNDLE in r_exe
        line = f"{pid:>6} {role:<6} responsible={r} ({r_exe or 'unknown'}) {'ok' if ok else 'NOT Herdr Core.app'}"
        lines.append(line)
        if not ok:
            bad.append(line)
    return lines, bad


def main(argv: list[str]) -> int:
    try:
        pids = [int(a) for a in argv]
    except ValueError:
        print(__doc__, file=sys.stderr)
        return 2
    lines, bad = check(pids)
    if not lines:
        print("no herdr-core process found")
        return 0
    print("\n".join(lines))
    tainted = [str(pid) for pid, _, _ in targets(process_table(), pids) if inherited_agent_env(pid)]
    if tainted:
        print(f"agent environment inherited by {', '.join(tainted)}: every terminal gets it and Claude saves no transcript (fix: make herdr-core-clean-restart)")
    if bad:
        print(f"offenders: {len(bad)} of {len(lines)} not attributed to Herdr Core.app")
    return 1 if bad or tainted else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
