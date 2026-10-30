#!/usr/bin/env python3
"""Fleet or session, per repo — from evidence, not taste.

Question: which projects carry enough sustained, planned, multi-wave work that a persistent
coordinator (mother → lead → workers) pays for itself, and which are served by plain sessions?

Rule (fixed before reading the output): fleet  <=>  planned work units closed in the 90 days before
AS_OF >= 10 AND commits per week over those 90 days >= 25. A planned work unit is a `done` wave in
docs/waves (any plan file or archive) or, for repos on the `fleet/` handoff convention (shutterflow),
a `chore(fleet): … merged` phase commit on the default branch — added after the first run counted
shutterflow's 424 fleet commits as zero because it keeps no docs/waves. Everything else is session. Incident load is
reported beside the class but does not decide it: incidents flow through warden for every class.

Inputs (all evidence outputs, read-only): ../kpi/git_delivery.out.json (commits),
../postmortem/waves.out.json (wave sections with close dates), ../kpi/baseline.out.json
(`by_repo`, items and escalations), ../signals/topology.out.json (runtime units per project).
Run: python3 -I classify.py  → classify.out.json, classify.out.md
"""
import json
import os
import subprocess
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
AS_OF = os.environ.get("AS_OF", "2026-10-22T08:00:00Z")
asof = datetime.fromisoformat(AS_OF.replace("Z", "+00:00"))
since = asof - timedelta(days=90)


def load(rel):
    with open(os.path.join(HERE, rel)) as fh:
        return json.load(fh)


git = {r["repo"]: r for r in load("../kpi/git_delivery.out.json")["repos"]}
IU = {r["repo"] for r in load("../kpi/git_delivery.out.json")["repos"] if "IuRoot" in r.get("root", "")}
waves = load("../postmortem/waves.out.json")["waves"]
by_repo = load("../kpi/baseline.out.json")["by_repo"]
topo = load("../signals/topology.out.json")


def parse(ts):
    if not ts:
        return None
    try:
        return datetime.fromisoformat(str(ts).replace("Z", "+00:00"))
    except ValueError:
        return None


closed, active = {}, {}
for w in waves:
    repo = w.get("repo")
    if w.get("status") == "active":
        active[repo] = active.get(repo, 0) + 1
    c = parse(w.get("closed"))
    if c and c.tzinfo is None:
        c = c.replace(tzinfo=timezone.utc)
    if c and since <= c < asof and w.get("status") == "done":
        closed[repo] = closed.get(repo, 0) + 1



def fleet_units(repo):
    """Phase commits of the fleet/ handoff convention, on the default branch, inside the window."""
    root = os.path.expanduser(f"~/SourceRoot/{repo}")
    ref = subprocess.run(["git", "-C", root, "symbolic-ref", "--short", "refs/remotes/origin/HEAD"],
                         capture_output=True, text=True).stdout.strip() or "HEAD"
    has = subprocess.run(["git", "-C", root, "ls-tree", "--name-only", ref, "fleet"], capture_output=True, text=True).stdout.strip()
    if not has:
        return 0
    log = subprocess.run(["git", "-C", root, "log", ref, f"--since={since.isoformat()}", f"--until={asof.isoformat()}",
                          "--format=%s", "-E", "--grep=^chore\\(fleet\\): .* merged"], capture_output=True, text=True).stdout
    return len([l for l in log.splitlines() if l.strip()])




def iu_waves(repo):
    """IuRoot repos are outside the postmortem scan: count `done` wave sections in docs/waves files
    last committed inside the window (approximate; names and counts only, never content)."""
    root = os.path.expanduser(f"~/IuRoot/{repo}")
    files = subprocess.run(["git", "-C", root, "ls-files", "docs/waves"], capture_output=True, text=True).stdout.split()
    n = 0
    for f in files:
        if not f.endswith(".md"):
            continue
        last = subprocess.run(["git", "-C", root, "log", "-1", "--format=%cI", f"--until={asof.isoformat()}", "--", f],
                              capture_output=True, text=True).stdout.strip()
        if not last or parse(last) < since:
            continue
        try:
            text = open(os.path.join(root, f), encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        n += sum(1 for line in text.splitlines() if line.startswith("## Wave") and "status: done" in line)
    return n


units = {}
for u in topo.get("units", topo if isinstance(topo, list) else []):
    if isinstance(u, dict) and u.get("project"):
        units[u["project"]] = units.get(u["project"], 0) + 1

rows = []
for repo, g in sorted(git.items()):
    commits = g.get("commits") or 0
    per_week = round(commits / (90 / 7), 1)
    wc = (iu_waves(repo) if repo in IU else closed.get(repo, 0) + fleet_units(repo))
    inc = by_repo.get("30d", {}).get(repo, {})
    cls = "fleet" if wc >= 10 and per_week >= 25 else "session"
    rows.append({
        "repo": repo, "class": cls, "commits_90d": commits, "commits_per_week": per_week,
        "waves_closed_90d": wc, "waves_active": active.get(repo, 0),
        "items_30d": inc.get("items", 0), "escalated_30d": inc.get("escalated", 0),
        "runtime_units": units.get(repo, 0), "workspace": "IuRoot" if repo in IU else "SourceRoot",
    })
rows.sort(key=lambda r: (r["class"] != "fleet", -r["commits_90d"]))
out = {"as_of": AS_OF, "rule": "fleet <=> planned units closed 90d (done waves + fleet phase merges) >= 10 and commits_per_week >= 25", "rows": rows,
       "fleet": [r["repo"] for r in rows if r["class"] == "fleet"]}
with open(os.path.join(HERE, "classify.out.json"), "w") as fh:
    json.dump(out, fh, indent=1)
    fh.write("\n")
lines = ["# Fleet or session, per repo", "", f"AS_OF {AS_OF}. Rule: `{out['rule']}`. Incident load is shown, not decisive.", "",
         "| Repo | Root | Class | Commits 90 d | /week | Waves closed 90 d | Active waves | Items 30 d | Escalated 30 d | Runtime units |", "|-|-|-|-|-|-|-|-|-|-|"]
for r in rows:
    lines.append(f"| {r['repo']} | {r['workspace']} | {r['class']} | {r['commits_90d']} | {r['commits_per_week']} | {r['waves_closed_90d']} | {r['waves_active']} | {r['items_30d']} | {r['escalated_30d']} | {r['runtime_units']} |")
with open(os.path.join(HERE, "classify.out.md"), "w") as fh:
    fh.write("\n".join(lines) + "\n")
print("fleet:", out["fleet"])
