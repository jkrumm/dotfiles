#!/usr/bin/env python3
"""Spike 1, step 3 (tail): projections, git footprint, backup and restore on one topology.

Question: how does Argo/Obsidian/TickTick read what beads holds (JSONL export, `bd list --json`,
the events journal), what lands in git (.beads/ files, refs/dolt/data on a git remote), and can
the data be backed up and restored (Dolt-native backup, git-remote clone via `bd bootstrap`)?

Usage: python3 -I 09-export-backup.py embedded|shared  (after 03-topologies.py <same>)
Writes results/export-backup-<name>.json. A bare git repo in the scratch prefix stands in for
the git remote.
"""
import json
import os
import shutil
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from spike import *  # noqa: E402,F401,F403

TOPO = sys.argv[1] if len(sys.argv) > 1 else "embedded"
EXTRA = {"BEADS_DOLT_SERVER_PORT": "43308"} if TOPO == "shared" else {}
CWD = f"{SPIKE}/data/{TOPO}/dotfiles"
X = f"{SPIKE}/data/{TOPO}-extra"
shutil.rmtree(X, ignore_errors=True)
os.makedirs(X)
OUT = {"topology": TOPO, "loadavg_at_start": loadavg()}


def step(r, keep_out=False):
    d = {"exit": r.rc, "secs": round(r.secs, 2)}
    if r.rc != 0:
        d["error"] = (r.err or r.out).strip().replace(SPIKE, "<spike>").replace(HOME, "~")[:300]
    elif keep_out:
        d["out"] = r.out.strip()[:300]
    return d


def count(cwd):
    j = bd("list", "--json", "--limit", "0", "--status", "all", cwd=cwd, extra_env=EXTRA).json()
    return len(j) if isinstance(j, list) else None


OUT["tasks_in_db"] = count(CWD)

# 1) projections: JSONL export vs `bd list --json`
p = f"{X}/export.jsonl"
r = bd("export", "-o", p, cwd=CWD, extra_env=EXTRA)
OUT["jsonl_export"] = {**step(r), "bytes": os.path.getsize(p) if os.path.exists(p) else None}
if os.path.exists(p):
    lines = open(p).read().splitlines()
    first = json.loads(lines[0]) if lines else {}
    OUT["jsonl_export"].update({"lines": len(lines), "keys_of_first_record": sorted(first.keys())[:30],
                                "has_dependencies_field": any("dependencies" in json.loads(l) for l in lines[:50]),
                                "has_labels_field": any("labels" in json.loads(l) for l in lines[:50])})
r = bd("list", "--json", "--limit", "0", "--status", "all", cwd=CWD, extra_env=EXTRA)
OUT["list_json_all"] = {**step(r), "bytes": len(r.out), "rows": len(r.json() or [])}
r = bd("list", "--json", "--limit", "0", "--status", "all", "--brief", cwd=CWD, extra_env=EXTRA)
OUT["list_json_all_brief"] = {**step(r), "bytes": len(r.out)}
r = bd("ready", "--json", "--limit", "0", cwd=CWD, extra_env=EXTRA)
OUT["ready_json_default_vs_brief_bytes"] = {"default": len(r.out), "brief": len(bd("ready", "--json", "--brief", "--limit", "0", cwd=CWD, extra_env=EXTRA).out)}

# 2) events journal (change feed for projections)
r = bd("config", "set", "events-journal", "true", cwd=CWD, extra_env=EXTRA)
OUT["events_journal_enable"] = step(r)
tid = ids_of(bd("create", "journal probe", "-t", "task", "--json", cwd=CWD, extra_env=EXTRA))
bd("update", tid, "--claim", "--actor", "probe", cwd=CWD, extra_env=EXTRA)
bd("close", tid, "-r", "x", cwd=CWD, extra_env=EXTRA)
r = bd("events", "tail", "--since", "0", cwd=CWD, extra_env=EXTRA)
ev = [json.loads(l) for l in r.out.splitlines() if l.strip().startswith("{")]
OUT["events_tail"] = {**step(r), "records": len(ev), "operations": sorted({e.get("operation", e.get("op", "?")) for e in ev})[:10],
                      "keys": sorted(ev[0].keys())[:20] if ev else []}

# 3) git footprint and the git remote (refs/dolt/data)
st = git("status", "--short", cwd=CWD).out.splitlines()
OUT["git_footprint"] = {"tracked_beads_files": [f for f in git("ls-files", cwd=CWD).out.split() if f.startswith(".beads")],
                        "git_status_short": st[:8], "commits": int(git("rev-list", "--count", "HEAD", cwd=CWD).out),
                        "bd_made_commits": git("log", "--format=%s", cwd=CWD).out.splitlines()[:4]}
bare = f"{X}/remote.git"
git("init", "-q", "--bare", bare, cwd=X)
git("remote", "add", "origin", bare, cwd=CWD)
git("push", "-q", "origin", "main", cwd=CWD)
r = bd("dolt", "remote", "add", "origin", f"git+file://{bare}", cwd=CWD, extra_env=EXTRA)
OUT["dolt_remote_add"] = step(r)
r = bd("dolt", "push", cwd=CWD, extra_env=EXTRA)
OUT["dolt_push"] = step(r)
refs = git("ls-remote", "origin", cwd=CWD).out.replace(SPIKE, "<spike>")
OUT["git_remote_refs_after_push"] = [l.split("\t")[1] for l in refs.splitlines()]
OUT["git_remote_size_kb"] = int(run(["du", "-sk", bare]).out.split()[0])
r = git("log", "--oneline", "origin/main", cwd=CWD)
OUT["code_branch_history_untouched_commits"] = len(r.out.splitlines())
# fresh clone of the code repo, then `bd bootstrap` pulls the issue data from refs/dolt/data
clone = f"{X}/clone"
git("clone", "-q", bare, clone, cwd=X)
t = time.time()
r = bd("bootstrap", cwd=clone, extra_env=EXTRA)
OUT["clone_bootstrap"] = {**step(r), "tasks_after_bootstrap": count(clone), "expected": OUT["tasks_in_db"] + 1,
                          "files_present_in_fresh_clone": sorted(f for f in os.listdir(f"{clone}/.beads") if not f.startswith("."))[:8]}

# 4) Dolt-native backup and restore into a fresh workspace
bk = f"{X}/backup"
r = bd("backup", "init", bk, cwd=CWD, extra_env=EXTRA)
OUT["backup_init"] = step(r)
r = bd("backup", "sync", cwd=CWD, extra_env=EXTRA)
OUT["backup_sync"] = {**step(r), "backup_kb": int(run(["du", "-sk", bk]).out.split()[0]) if os.path.isdir(bk) else None}
fresh = f"{X}/restored"
os.makedirs(fresh)
git("init", "-q", ".", cwd=fresh)
open(f"{fresh}/README.md", "w").write("r\n")
git("add", "-A", cwd=fresh)
git("commit", "-qm", "i", cwd=fresh)
flags = ["--skip-agents", "--skip-hooks"] + (["--shared-server"] if TOPO == "shared" else [])
r0 = bd("init", "-p", "rst", "--non-interactive", "--quiet", *flags, cwd=fresh, extra_env=EXTRA)
r = bd("backup", "restore", "--force", bk, cwd=fresh, extra_env=EXTRA)
OUT["backup_restore_into_fresh_workspace"] = {**step(r), "init_secs": round(r0.secs, 2), "tasks_after_restore": count(fresh),
                                              "expected": OUT["tasks_in_db"] + 1}
OUT["loadavg_at_end"] = loadavg()
print(save(f"export-backup-{TOPO}", OUT))
