#!/usr/bin/env python3
"""herdr-reap — the janitor behind `rd reap` and com.jkrumm.herdr-reap.

Closes herdr tabs whose agents are finished, and nothing else:

  close    every agent in the tab is done/idle for longer than REAP_IDLE_H hours (default 12),
           the checkout is clean and pushed, and no `active` wave in the repo's plan could own it
  message  the same tab, but dirty or unpushed — the agent is told (once per 24 h), the tab stays
  never    working/blocked/unknown agents, a checkout a working agent also uses, tabs holding a non-agent pane (a shell or server would
           die with it), tabs whose cwd is not inside a git repo (the ~/SourceRoot design tabs),
           any tab in a repo whose docs/waves/PLAN.md has an `active` wave (mother/lead/wave tabs),
           the caller's own tab

Also stops `claude --bg` sessions older than 24 h that are not working (`claude stop` keeps the
conversation). --dry-run prints the plan and writes nothing. Every live action is one line in
~/Library/Logs/herdr-reap.log.

Idle age comes from the last timestamped record of the agent's Claude session transcript. An agent whose
transcript cannot be found has an unknown age and is never closed.
"""

import argparse
import calendar
import fcntl
import glob
import json
import os
import re
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
LOG = os.path.join(HOME, "Library/Logs/herdr-reap.log")
STATE = os.path.join(HOME, ".local/state/herdr-reap/messaged.json")
MESSAGE_EVERY_S = 24 * 3600
BG_MAX_AGE_S = 24 * 3600
ACTIVE_RE = re.compile(r"<!--\s*status:\s*active\b")
FINISHED = {"done", "idle"}
BG_STOPPABLE = {"blocked", "idle", "done"}


def sh(*cmd: str, cwd: str | None = None) -> tuple[int, str]:
    r = subprocess.run(cmd, capture_output=True, text=True, cwd=cwd)
    return r.returncode, r.stdout


def herdr_json(*args: str) -> dict:
    rc, out = sh("herdr", *args)
    if rc != 0:
        sys.exit(f"herdr {' '.join(args)} failed")
    return json.loads(out)["result"]


def git(cwd: str, *args: str) -> tuple[int, str]:
    return sh("git", "-C", cwd, *args)


def repo_roots(cwd: str) -> tuple[str, str] | None:
    """(this checkout's toplevel, the main repo's root) or None outside a git repo."""
    if not os.path.isdir(cwd):
        return None
    rc, top = git(cwd, "rev-parse", "--show-toplevel")
    if rc != 0:
        return None
    rc, common = git(cwd, "rev-parse", "--path-format=absolute", "--git-common-dir")
    main = os.path.dirname(common.strip()) if rc == 0 and common.strip().endswith(".git") else top.strip()
    return top.strip(), main


def active_wave(root: str) -> bool:
    try:
        with open(os.path.join(root, "docs/waves/PLAN.md")) as f:
            return any(ACTIVE_RE.search(line) for line in f)
    except OSError:
        return False


TS_RE = re.compile(rb'"timestamp":"(\d{4}-\d\d-\d\dT[\d:.]+Z)"')


def idle_hours(session_id: str | None) -> float | None:
    """Hours since the last timestamped record of the agent's transcript. Not the file mtime:
    Claude rewrites trailing metadata on resume, which makes a week-old session look fresh."""
    if not session_id:
        return None
    hits = glob.glob(os.path.join(HOME, ".claude/projects/*", f"{session_id}.jsonl"))
    if not hits:
        return None
    with open(hits[0], "rb") as f:
        f.seek(0, os.SEEK_END)
        f.seek(max(0, f.tell() - 262144))
        stamps = TS_RE.findall(f.read())
    if not stamps:
        return None
    last = calendar.timegm(time.strptime(stamps[-1].decode()[:19], "%Y-%m-%dT%H:%M:%S"))
    return (time.time() - last) / 3600


def checkout_problem(cwd: str) -> str | None:
    rc, out = git(cwd, "status", "--porcelain")
    if rc != 0:
        return "git status failed"
    if out.strip():
        return f"{len(out.strip().splitlines())} uncommitted path(s)"
    rc, out = git(cwd, "rev-list", "--count", "@{u}..HEAD")
    if rc != 0:
        return "no upstream branch"
    if out.strip() != "0":
        return f"{out.strip()} unpushed commit(s)"
    return None


class Journal:
    def __init__(self, dry: bool):
        self.dry = dry

    def line(self, action: str, **kv: str) -> None:
        text = " ".join([action] + [f"{k}={v}" for k, v in kv.items()])
        if self.dry:
            print(f"  would {text}")
            return
        print(f"  {text}")
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        with open(LOG, "a") as f:
            f.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S%z')} {text}\n")


def load_messaged() -> dict:
    try:
        with open(STATE) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_messaged(m: dict) -> None:
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    tmp = f"{STATE}.{os.getpid()}"
    with open(tmp, "w") as f:
        json.dump(m, f)
    os.replace(tmp, STATE)


def reap_tabs(idle_h: float, j: Journal) -> None:
    panes = herdr_json("pane", "list")["panes"]
    agents = {a["pane_id"]: a for a in herdr_json("agent", "list")["agents"]}
    labels = {t["tab_id"]: t.get("label", "") for t in herdr_json("tab", "list")["tabs"]}
    own = os.environ.get("HERDR_PANE_ID", "")
    # A checkout another live agent is working in is not this tab's to clean up: its dirty files are
    # that agent's, and nudging an idle sibling to commit them would be wrong.
    busy_checkouts = set()
    for a in agents.values():
        if a["agent_status"] in ("working", "blocked") and (r := repo_roots(a.get("cwd") or "")):
            busy_checkouts.add(r[0])
    messaged = load_messaged()
    now = time.time()

    by_tab: dict[str, list[dict]] = {}
    for p in panes:
        by_tab.setdefault(p["tab_id"], []).append(p)

    kept: list[str] = []
    for tab, tpanes in by_tab.items():
        members = [agents[p["pane_id"]] for p in tpanes if p["pane_id"] in agents]
        if not members:
            continue  # shell-only tab: not an agent's
        name = f"{tab} '{labels.get(tab, '')}'"
        why = None
        if any(p["pane_id"] not in agents for p in tpanes):
            why = "also holds a non-agent pane"
        elif any(p["pane_id"] == own for p in tpanes):
            why = "caller's own tab"
        elif any(a["agent_status"] not in FINISHED for a in members):
            why = "agent " + "/".join(sorted({a["agent_status"] for a in members}))
        if why:
            kept.append(f"{name}: {why}")
            continue

        ages = [idle_hours((a.get("agent_session") or {}).get("value")) for a in members]
        if any(a is None for a in ages):
            kept.append(f"{name}: idle age unknown (no session transcript)")
            continue
        age = min(ages)  # type: ignore[type-var]
        if age <= idle_h:
            kept.append(f"{name}: {'/'.join(a['agent_status'] for a in members)} {age:.1f}h <= {idle_h:g}h")
            continue

        cwds = {a.get("cwd") or "" for a in members}
        if any((r := repo_roots(c)) and r[0] in busy_checkouts for c in cwds):
            kept.append(f"{name}: checkout shared with a working agent")
            continue
        roots = [repo_roots(c) for c in cwds]
        if any(r is None for r in roots):
            kept.append(f"{name}: cwd is not a git repo")
            continue
        if any(active_wave(r) for pair in roots for r in set(pair)):  # type: ignore[union-attr]
            kept.append(f"{name}: repo plan has an active wave")
            continue
        problems = [(c, checkout_problem(c)) for c in sorted(cwds)]
        problems = [(c, p) for c, p in problems if p]
        repo = os.path.basename(next(iter(cwds)))
        if problems:
            detail = "; ".join(f"{os.path.basename(c)}: {p}" for c, p in problems)
            kept.append(f"{name}: {detail}")
            for a in members:
                key = a["pane_id"]
                if now - messaged.get(key, 0) < MESSAGE_EVERY_S:
                    continue
                if j.dry:
                    j.line("message", tab=tab, pane=key, repo=repo, reason=f'"{detail}"')
                    continue
                rc, out = sh("herdr", "agent", "prompt", key,
                             f"herdr-reap: this tab has been {a['agent_status']} for {age:.0f}h but its checkout has "
                             f"{detail}. Commit and push, or leave a note why not; the tab stays open until it is clean and pushed.")
                if rc != 0 or '"error"' in out:  # herdr reports a rejected prompt in the body with exit 0
                    j.line("message-failed", tab=tab, pane=key, repo=repo, out=json.dumps(out.strip()[:160]))
                    continue
                j.line("message", tab=tab, pane=key, repo=repo, reason=f'"{detail}"')
                messaged[key] = now
            continue

        j.line("close", tab=tab, panes=",".join(p["pane_id"] for p in tpanes), repo=repo,
               idle=f"{age:.0f}h", label=f'"{labels.get(tab, "")}"')
        if not j.dry:
            rc, out = sh("herdr", "tab", "close", tab)
            if rc != 0 or '"error"' in out:
                j.line("close-failed", tab=tab, out=out.strip()[:200])

    if not j.dry:
        save_messaged({k: v for k, v in messaged.items() if k.startswith('bg:') or now - v < 7 * 86400})
    print(f"kept {len(kept)} tab(s):")
    for k in kept:
        print(f"  keep {k}")


def reap_bg(j: Journal) -> None:
    rc, out = sh("claude", "agents", "--json")
    if rc != 0:
        print("claude agents --json failed; skipping bg leftovers")
        return
    now = time.time() * 1000
    seen = load_messaged()
    for a in json.loads(out):
        # Only a state known to be finished is stopped; an unknown or missing one is left alone.
        if a.get("kind") != "background" or (a.get("state") or a.get("status")) not in BG_STOPPABLE:
            continue
        if now - a["startedAt"] < BG_MAX_AGE_S * 1000:
            continue
        key = f"bg:{a['id']}"
        if key in seen:
            continue  # stop already failed once (daemon gone): the record stays, logging it every run is noise
        desc = dict(id=a["id"], name=f'"{a.get("name", "")}"', state=str(a.get("state")),
                    cwd=a.get("cwd", ""), age=f"{(now - a['startedAt']) / 3.6e6:.0f}h")
        if j.dry:
            j.line("bg-stop", **desc)
            continue
        rc, _ = sh("claude", "stop", a["id"])
        if rc == 0:
            j.line("bg-stop", **desc)
        else:
            j.line("bg-stop-failed", **desc, why='"claude stop could not reach the background daemon; record left in place"')
            seen[key] = now
            save_messaged(seen)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dry-run", action="store_true", help="print the plan, change nothing")
    args = ap.parse_args()
    idle_h = float(os.environ.get("REAP_IDLE_H", "12"))
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    lock = open(STATE + ".lock", "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("another herdr-reap run holds the lock; exiting")
        return
    j = Journal(args.dry_run)
    print(f"herdr-reap {'DRY RUN ' if args.dry_run else ''}idle>{idle_h:g}h")
    reap_tabs(idle_h, j)
    reap_bg(j)
    if not args.dry_run:
        j.line("run-complete", idle_h=f"{idle_h:g}")


if __name__ == "__main__":
    main()
