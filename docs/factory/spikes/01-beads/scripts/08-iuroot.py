#!/usr/bin/env python3
"""Spike 1, step 5: IuRoot fit. Can a work repo get a task system without a single tracked change?

Question: routing a work repo's issues to a planning location outside that repo (`bd init
--contributor`), or keeping them in a pointer directory (`BEADS_DIR` + --stealth), or hiding
`.beads/` with --stealth: what exactly lands in the work repo (tracked files, untracked files,
.git/config, .git/info/exclude, hooks path, commits)?

Works on synthetic scratch repos only; no IuRoot repo is read or touched. The fake origin uses
a reserved .invalid host. Usage: python3 -I 08-iuroot.py. Writes results/iuroot.json.
"""
import hashlib
import json
import os
import pty
import re
import select
import shutil
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from spike import *  # noqa: E402,F401,F403
import spike  # noqa: E402

ROOT = f"{SPIKE}/data/iuroot"
shutil.rmtree(ROOT, ignore_errors=True)
shutil.rmtree(f"{ISO}/.beads-planning", ignore_errors=True)
os.makedirs(ROOT)
OUT = {"loadavg_at_start": loadavg()}


def mkrepo(name):
    d = f"{ROOT}/{name}"
    os.makedirs(f"{d}/src")
    git("init", "-q", ".", cwd=d)
    git("remote", "add", "origin", f"https://gitlab.spike.invalid/group/{name}.git", cwd=d)
    open(f"{d}/README.md", "w").write("work repo\n")
    open(f"{d}/AGENTS.md", "w").write("# agents\nowner-authored, tool-neutral\n")
    open(f"{d}/.gitignore", "w").write("node_modules/\n")
    open(f"{d}/src/app.py", "w").write("print('x')\n")
    git("add", "-A", cwd=d)
    git("commit", "-qm", "EP-1 initial", cwd=d)
    return d


def snap(d):
    tracked = git("ls-files", "-s", cwd=d).out
    return {"tracked_hash": hashlib.sha256(tracked.encode()).hexdigest()[:12],
            "commits": int(git("rev-list", "--count", "HEAD", cwd=d).out),
            "git_config": open(f"{d}/.git/config").read(),
            "exclude": open(f"{d}/.git/info/exclude").read(),
            "head": git("rev-parse", "HEAD", cwd=d).out.strip()}


def diff(d, before):
    after = snap(d)
    st = git("status", "--porcelain", cwd=d).out.splitlines()
    ign = git("status", "--porcelain", "--ignored", cwd=d).out.splitlines()
    return {"tracked_files_changed": after["tracked_hash"] != before["tracked_hash"],
            "commits_added_by_bd": after["commits"] - before["commits"],
            "head_moved": after["head"] != before["head"],
            "git_status_porcelain": st,
            "ignored_or_untracked_incl_ignored": [l for l in ign if l not in st],
            "git_config_added_lines": [l for l in after["git_config"].splitlines() if l not in before["git_config"].splitlines()],
            "info_exclude_added_lines": [l for l in after["exclude"].splitlines() if l not in before["exclude"].splitlines() and l.strip()]}


ANSWERS = {b"Continue with contributor setup": b"y"}  # the wizard defaults to N when no fork is detected


def pty_run(cmd, cwd, extra_env=None, timeout=240):
    """Run an interactive command in a pty, answering each prompt with the default (Enter) unless ANSWERS says otherwise."""
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(cwd)
        os.execvpe(cmd[0], cmd, spike.env({**(extra_env or {}), "BD_NON_INTERACTIVE": "0"}))
    out, t0, last = b"", time.time(), time.time()
    answered = 0
    while time.time() - t0 < timeout:
        r, _, _ = select.select([fd], [], [], 0.5)
        if r:
            try:
                data = os.read(fd, 4096)
            except OSError:
                break
            if not data:
                break
            out += data
            last = time.time()
        elif time.time() - last > 1.5 and re.search(rb"(\?|:|\]|\))\s*$", out[-120:]):
            ans = next((v for k, v in ANSWERS.items() if k in out[-400:]), b"")
            os.write(fd, ans + b"\n")
            answered += 1
            last = time.time()
    try:
        _, status = os.waitpid(pid, 0)
    except ChildProcessError:
        status = 0
    txt = re.sub(rb"\x1b\[[0-9;?]*[A-Za-z]", b"", out).decode("utf-8", "replace")
    return os.waitstatus_to_exitcode(status), txt, answered


# ---- A) bd init --contributor: planning repo outside the work repo
d = mkrepo("work-repo-a")
before = snap(d)
bd("metrics", "off", cwd=d)
t = time.time()
rc, txt, answered = pty_run(["bd", "init", "--contributor", "-p", "wra", "--skip-agents", "--skip-hooks"], d)
A = {"wizard_exit": rc, "wizard_seconds": round(time.time() - t, 1), "prompts_answered_with_default": answered,
     "transcript_tail": [l.strip() for l in txt.splitlines() if l.strip()][-14:]}
A["after_init"] = diff(d, before)
A["files_created_in_work_repo"] = sorted(os.path.relpath(os.path.join(p, f), d) for p, _, fs in os.walk(d)
                                          if ".git" not in p.split(os.sep) and "embeddeddolt" not in p for f in fs)
planning = f"{ISO}/.beads-planning"
A["planning_repo_exists_outside_work_repo"] = os.path.isdir(planning)
A["planning_repo_is_git_repo"] = os.path.isdir(f"{planning}/.git")
A["config_yaml_routing"] = [l for l in open(f"{d}/.beads/config.yaml").read().splitlines()
                            if re.match(r"\s*(routing|repos|beads)", l) or "contributor" in l or "planning" in l] if os.path.exists(f"{d}/.beads/config.yaml") else None
A["role"] = bd("config", "get", "beads.role", cwd=d).out.strip()
r = bd("create", "routed work item", "-t", "task", "--json", cwd=d)
A["create_exit"], A["create_secs"] = r.rc, round(r.secs, 2)
newid = ids_of(r)
A["created_id"] = newid
A["where_work_repo"] = bd("where", cwd=d).out.strip().replace(ISO, "<iso-home>").replace(SPIKE, "<spike>")[:300]
rl = bd("list", "--json", cwd=d)
A["list_in_work_repo_shows_it"] = newid in [x["id"] for x in (rl.json() or [])]
rp = bd("list", "--json", cwd=planning)
A["list_in_planning_repo_shows_it"] = newid in [x["id"] for x in (rp.json() or [])] if rp.rc == 0 else f"rc={rp.rc}"
rr = bd("ready", "--json", cwd=d)
A["ready_in_work_repo_shows_it"] = newid in [x["id"] for x in (rr.json() or [])]
A["after_create"] = diff(d, before)
OUT["A_init_contributor"] = A

# ---- B) BEADS_DIR pointer + --stealth: .beads lives entirely outside the work repo
d = mkrepo("work-repo-b")
before = snap(d)
pdir = f"{ROOT}/planning-b"
os.makedirs(pdir)
E = {"BEADS_DIR": f"{pdir}/.beads"}
r = bd("init", "--quiet", "--stealth", "-p", "wrb", "--non-interactive", "--skip-agents", "--skip-hooks", cwd=d, extra_env=E)
B = {"init_exit": r.rc, "init_secs": round(r.secs, 2), "init_err": r.err.strip()[:200]}
r = bd("create", "pointer item", "-t", "task", "--json", cwd=d, extra_env=E)
B["create_exit"] = r.rc
bid = ids_of(r)
B["ready_from_work_repo_with_pointer"] = bid in [x["id"] for x in (bd("ready", "--json", cwd=d, extra_env=E).json() or [])]
B["without_pointer_bd_finds_nothing"] = bd("ready", "--json", cwd=d).rc != 0
B["after"] = diff(d, before)
B["beads_dir_outside_work_repo"] = os.path.isdir(f"{pdir}/.beads") and not os.path.exists(f"{d}/.beads")
OUT["B_beads_dir_pointer_stealth"] = B

# ---- C) --stealth inside the work repo (.beads/ present but excluded locally)
d = mkrepo("work-repo-c")
before = snap(d)
r = bd("init", "--quiet", "--stealth", "-p", "wrc", "--non-interactive", "--skip-agents", "--skip-hooks", cwd=d)
C = {"init_exit": r.rc, "init_secs": round(r.secs, 2)}
bd("create", "stealth item", "-t", "task", "--json", cwd=d)
C["after"] = diff(d, before)
C["beads_dir_inside_work_repo"] = os.path.isdir(f"{d}/.beads")
OUT["C_stealth_in_repo"] = C

# ---- D) the default init, for contrast (what a careless `bd init` does to a work repo)
d = mkrepo("work-repo-d")
before = snap(d)
r = bd("init", "-p", "wrd", "--non-interactive", "--quiet", cwd=d)
D = {"init_exit": r.rc, "init_secs": round(r.secs, 2), "after": diff(d, before)}
D["tracked_files_added"] = sorted(git("diff", "--name-only", before["head"], "HEAD", cwd=d).out.split())
D["claude_md_created"] = os.path.exists(f"{d}/CLAUDE.md")
D["agents_md_modified"] = open(f"{d}/AGENTS.md").read() != "# agents\nowner-authored, tool-neutral\n"
D["core_hooksPath_set"] = git("config", "--local", "--get", "core.hooksPath", cwd=d).out.strip().replace(SPIKE, "<spike>")
OUT["D_default_init_for_contrast"] = D
OUT["loadavg_at_end"] = loadavg()
print(save("iuroot", OUT))
