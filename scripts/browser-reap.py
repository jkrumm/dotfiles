#!/usr/bin/env python3
"""browser-reap — ends test-browser Chrome trees that outlived their launcher (com.jkrumm.browser-reap, every 30 min).

A Playwright or puppeteer Chrome keeps running when the process that launched it dies (a killed
chrome-devtools-mcp, a crashed test run): its parent becomes launchd and it holds ~hundreds of MiB until reboot.
A tree is ended only when ALL hold:

  1. its --user-data-dir is a temp directory named playwright_chromiumdev_profile-* or puppeteer_dev_chrome_profile-*
  2. every root of the tree (a member whose parent is not in the tree) has ppid 1: the launcher is gone
  3. every root is older than MIN_AGE_S (30 min)

Never: the owner's Chrome (no --user-data-dir), a persistent profile such as ~/.local/share/research-chrome, a tree
whose launcher is alive, a young tree. Kills by pid (SIGTERM, then SIGKILL after a grace), one log line per
action on stdout (the plist sends it to ~/Library/Logs/browser-reap.log). --dry-run prints the plan, kills nothing.

Test hooks: BROWSER_REAP_TMPDIR (the temp root), BROWSER_REAP_MIN_AGE_S, BROWSER_REAP_GRACE_S.
"""

import argparse
import os
import re
import signal
import subprocess
import sys
import time

MIN_AGE_S = int(os.environ.get("BROWSER_REAP_MIN_AGE_S", 30 * 60))
GRACE_S = float(os.environ.get("BROWSER_REAP_GRACE_S", 5))
PROFILE = re.compile(r"^(playwright_chromiumdev_profile|puppeteer_dev_chrome_profile)-[A-Za-z0-9_.-]+$")
USER_DATA_DIR = re.compile(r"--user-data-dir=(\S+)")


def temp_roots() -> list[str]:
    if os.environ.get("BROWSER_REAP_TMPDIR"):  # tests: the only root, so a real tree on the host is never in scope
        return [os.path.realpath(os.environ["BROWSER_REAP_TMPDIR"])]
    return [os.path.realpath(r) for r in (os.environ.get("TMPDIR") or "/tmp", "/tmp", "/var/folders")]


def is_test_profile(path: str) -> bool:
    """A temp directory named like a throwaway test profile — never a persistent profile elsewhere."""
    path = os.path.realpath(path)
    if not PROFILE.match(os.path.basename(path)):
        return False
    return any(path.startswith(r.rstrip("/") + "/") for r in temp_roots())


def parse_etime(s: str) -> int:
    """ps etime: [[dd-]hh:]mm:ss"""
    days = 0
    if "-" in s:
        d, s = s.split("-", 1)
        days = int(d)
    parts = [int(x) for x in s.split(":")]
    while len(parts) < 3:
        parts.insert(0, 0)
    h, m, sec = parts
    return days * 86400 + h * 3600 + m * 60 + sec


def snapshot() -> dict[int, dict]:
    out = subprocess.run(["ps", "-axww", "-o", "pid=,ppid=,etime=,command="], capture_output=True, text=True, check=True).stdout
    procs: dict[int, dict] = {}
    for line in out.splitlines():
        f = line.split(None, 3)
        if len(f) < 4:
            continue
        try:
            procs[int(f[0])] = {"pid": int(f[0]), "ppid": int(f[1]), "age": parse_etime(f[2]), "cmd": f[3]}
        except ValueError:
            continue
    return procs


def trees(procs: dict[int, dict]) -> dict[str, set[int]]:
    """user-data-dir -> pids of every process carrying it, plus their descendants."""
    by_dir: dict[str, set[int]] = {}
    for p in procs.values():
        m = USER_DATA_DIR.search(p["cmd"])
        if m and is_test_profile(m.group(1)):
            by_dir.setdefault(m.group(1), set()).add(p["pid"])
    for members in by_dir.values():
        grew = True
        while grew:
            grew = False
            for p in procs.values():
                if p["ppid"] in members and p["pid"] not in members:
                    members.add(p["pid"])
                    grew = True
    return by_dir


def reapable(procs: dict[int, dict], members: set[int]) -> str | None:
    """None when the tree is to be ended, else why it is kept."""
    roots = [procs[p] for p in members if procs[p]["ppid"] not in members]
    if not roots:
        return "no root"
    if any(r["ppid"] != 1 for r in roots):
        return "launcher alive"
    if any(r["age"] < MIN_AGE_S for r in roots):
        return "younger than %d min" % (MIN_AGE_S // 60)
    return None


def alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def end_tree(pids: set[int]) -> int:
    """SIGTERM every pid, SIGKILL the survivors after the grace. Returns how many needed SIGKILL."""
    me = {os.getpid(), os.getppid(), 0, 1}
    pids = pids - me
    for pid in pids:
        try:
            os.kill(pid, signal.SIGTERM)
        except (ProcessLookupError, PermissionError):
            pass
    deadline = time.time() + GRACE_S
    while time.time() < deadline and any(alive(p) for p in pids):
        time.sleep(0.2)
    killed = 0
    for pid in pids:
        if alive(pid):
            try:
                os.kill(pid, signal.SIGKILL)
                killed += 1
            except (ProcessLookupError, PermissionError):
                pass
    return killed


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dry-run", action="store_true", help="print the plan, kill nothing")
    args = ap.parse_args()
    procs = snapshot()
    stamp = time.strftime("%Y-%m-%dT%H:%M:%S")
    ended = 0
    for udd, members in sorted(trees(procs).items()):
        why = reapable(procs, members)
        label = f"{stamp} browser-reap tree={os.path.basename(udd)} pids={len(members)}"
        if why:
            if args.dry_run:
                print(f"{label} keep ({why})")
            continue
        root = min((procs[p] for p in members if procs[p]["ppid"] not in members), key=lambda r: r["pid"])
        detail = f"root={root['pid']} age={root['age'] // 60}min"
        if args.dry_run:
            print(f"{label} would-end {detail}")
            continue
        killed = end_tree(members)
        print(f"{label} ended {detail}" + (f" sigkill={killed}" if killed else ""))
        ended += 1
    print(f"{stamp} browser-reap {'dry-run ' if args.dry_run else ''}done ended={ended}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
