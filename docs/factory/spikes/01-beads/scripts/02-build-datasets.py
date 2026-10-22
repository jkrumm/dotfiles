#!/usr/bin/env python3
"""Spike 1, step 2: build the three real datasets as neutral task lists.

Question: what does a realistic task graph for the factory look like, so both candidates
(beads and a SQLite extension) are loaded with the *same* data?

Inputs (read-only):
  a) the frozen warden snapshot (~/.local/share/factory/snapshots/2026-10-22/warden.db):
     open items that are work (feature- or fix-shaped). Open = state not in
     {closed, quiet, fixed, failed}; work = origin != 'alert' (alerts are signals, they become
     Conditions/Incidents, not Tasks); kind = feature when the note carries the [product] tag,
     else fix.
  b) Round 5 (~/SourceRoot/dotfiles/docs/waves/PLAN.md): W1-W10 as an epic, the *Order* graph
     as `blocks` edges, every unchecked checklist line as a child task, the one owner decision
     as a decision task that blocks W4.
  c) the current wave plans of two fleet repos (weatherorb, basalt-ui): active/pending/held
     waves as epics with their unchecked checklist lines as children; waves chained in file
     order (one active wave per repo); explicit cross-repo `external:` edges.

Output:
  $SPIKE/data/datasets.json            full task lists (scratch; has titles, never published)
  results/datasets-summary.json        counts only (public)
Run: python3 -I 02-build-datasets.py
"""
import json
import os
import re
import sqlite3
import sys

HOME = os.path.expanduser("~")
SPIKE = os.environ.get("SPIKE", os.path.join(HOME, ".local/share/factory/spikes/01-beads"))
HERE = os.path.dirname(os.path.abspath(__file__))
SNAP = os.path.join(HOME, ".local/share/factory/snapshots/2026-10-22/warden.db")
R5 = os.path.join(HOME, "SourceRoot/dotfiles/docs/waves/PLAN.md")
WO = os.path.join(HOME, "SourceRoot/weatherorb/docs/waves/PLAN.md")
BU = os.path.join(HOME, "SourceRoot/basalt-ui/docs/waves/PLAN.md")

tasks = []  # dicts: repo, key, title, type, priority, labels, parent, deps, defer, desc


def add(repo, key, title, typ="task", prio=2, labels=(), parent=None, deps=(), defer=False, desc=""):
    title = re.sub(r"\s+", " ", title.replace("**", "")).strip()
    if len(title) > 110:
        title = title[:107].rsplit(" ", 1)[0] + "..."
    tasks.append(dict(repo=repo, key=key, title=title, type=typ, priority=prio, labels=list(labels),
                      parent=parent, deps=list(deps), defer=defer, desc=desc[:400]))


def parse_plan(path, wanted):
    """-> [(wave_no_or_slug, title, status, [checklist lines])] for sections whose status in wanted."""
    out, cur = [], None
    head = re.compile(r"^## (Wave (\d+)|Held)\s*[—-]\s*(.+?)\s*<!--\s*status:\s*([a-z]+)")
    for line in open(path, encoding="utf-8"):
        m = head.match(line)
        if m:
            if cur:
                out.append(cur)
            cur = None
            if m.group(4) in wanted:
                slug = m.group(2) or "held"
                cur = [slug, m.group(3), m.group(4), []]
            continue
        if line.startswith("## ") or line.startswith("# "):
            if cur:
                out.append(cur)
            cur = None
            continue
        if cur and line.startswith("- [ ] "):
            cur[3].append(line[6:])
    if cur:
        out.append(cur)
    return out


# ---------------------------------------------------------------- a) warden open work items
def warden_items():
    c = sqlite3.connect(f"file:{SNAP}?mode=ro", uri=True)
    c.row_factory = sqlite3.Row
    rows = c.execute(
        "select * from triage_items where state not in ('closed','quiet','fixed','failed') order by event_id"
    ).fetchall()
    n_open, kept = len(rows), []
    for r in rows:
        if r["origin"] == "alert":
            continue
        note = (r["note"] or "").strip()
        tag = re.match(r"\[([a-z_ ]+)\]", note)
        tag = tag.group(1) if tag else "untagged"
        kind = "feature" if tag == "product" else "fix"
        prio = 1 if tag in ("security", "data_loss", "blocker") else 2 if tag == "chronic" else 3
        repo = "wo" if r["repo"] == "weatherorb" else "df"
        slug = (r["root_cause"] or f"item-{r['event_id']}").replace("-", " ")
        kept.append(dict(id=r["event_id"], repo=repo, src_repo=r["repo"], origin=r["origin"], tier=r["max_tier"],
                         kind=kind, tag=tag, prio=prio, slug=slug, note=note))
    return n_open, kept


n_open, witems = warden_items()
for w in witems:
    labels = [f"src:warden", f"origin:{w['origin']}", f"tier:{w['tier']}", f"tag:{w['tag'].replace(' ', '_')}",
              f"repo:{w['src_repo']}"]
    deps = []
    if w["src_repo"] == "homelab" and "backup-target" in (w["slug"] or "").replace(" ", "-"):
        labels.append("export:hdd-back")  # a capability other repos wait for (see wo Held cutover)
    add(w["repo"], f"wd{w['id']}", w["slug"], "feature" if w["kind"] == "feature" else "bug", w["prio"], labels,
        deps=deps, desc=w["note"])

# ---------------------------------------------------------------- b) Round 5 epic
ORDER = {  # wave -> waves that block it (the *Order* graph in PLAN.md)
    2: [1], 3: [1], 5: [1], 6: [1], 4: [2, 3], 7: [5, 6], 9: [4], 8: [2], 10: [7, 8, 9],
}
r5 = parse_plan(R5, {"pending", "blocked", "active"})
add("df", "r5", "Round 5 - the dark factory", "epic", 1, ["plan:round5"])
for slug, title, status, items in r5:
    n = int(slug)
    add("df", f"w{n}", f"W{n} {title}", "epic", 2, [f"status:{status.split(':')[0]}", "plan:round5"], parent="r5",
        deps=[f"w{b}" for b in ORDER.get(n, [])])
    for i, it in enumerate(items, 1):
        add("df", f"w{n}.{i}", it, "task", 2, ["plan:round5"], parent=f"w{n}")
add("df", "d1", "Owner decision: engine inside herdr for warden's unattended implement work", "decision", 1,
    ["plan:round5", "owner-decision"], parent="r5")
for t in tasks:
    if t["repo"] == "df" and t["key"] == "w4":
        t["deps"].append("d1")

# ---------------------------------------------------------------- c) fleet repos' current plans
def fleet(repo, label, path, wanted, chain_start=None):
    prev = chain_start
    plan = parse_plan(path, wanted)
    for slug, title, status, items in plan:
        key = f"w{slug}"
        deps = [prev] if prev else []
        add(repo, key, f"W{slug} {title}", "epic", 2, [f"status:{status}", f"plan:{label}"], deps=deps)
        for i, it in enumerate(items, 1):
            add(repo, f"{key}.{i}", it, "task", 2, [f"plan:{label}"], parent=key)
        if slug != "held":
            prev = key
    return plan


wo_plan = fleet("wo", "weatherorb", WO, {"active", "pending", "held"})
bu_plan = fleet("bu", "basalt-ui", BU, {"active", "pending"})

# weatherorb extras from its Refactor backlog / Parked sections (R1 blocks W85; decisions are deferred)
add("wo", "r1", "R1 - a member's long-run tail and an honest fade", "epic", 2, ["plan:weatherorb"])
add("wo", "r1.1", "Q1 (#158): short runs shadow long runs for four members", "bug", 2, ["plan:weatherorb"], parent="r1")
add("wo", "r1.2", "Q2: weight falls to 0 in one hourly step at a run's actual end", "bug", 2, ["plan:weatherorb"], parent="r1")
add("wo", "r6", "R6 - coastal resolution where people are", "epic", 3, ["plan:weatherorb"])
for k, t in (("wind", "Wind: beaches ~12 km apart read one 0.125 deg cell"),
             ("waves", "Waves: a beach's height is its cell's open-sea value"),
             ("truth", "Truth: no wind obs near Sagres, the owner's reading cannot be scored")):
    add("wo", f"r6.{k}", t, "task", 3, ["plan:weatherorb"], parent="r6")
for k, t in (("magic", "Magic-link sign-in needs a Resend domain (spend, external account)"),
             ("offsite", "Archive offsite copy (ADR 0009) after the HDD outage"),
             ("lorenz", "Lorenz light-pollution atlas: no licence grant"),
             ("map", "Cold /map network bytes cap")):
    add("wo", f"park.{k}", t, "decision", 3, ["owner-decision", "parked"], defer=True)
for t in tasks:
    if t["repo"] == "wo" and t["key"] == "w85":
        t["deps"].append("r1")
    if t["repo"] == "wo" and t["key"] == "w87":
        t["defer"] = True  # postponed by the owner until surf work is on the table
    if t["repo"] == "wo" and t["key"] == "w86":
        t["deps"].append("external:bu:toolbelt")  # waits for basalt-ui's toolbelt minor
    if t["repo"] == "wo" and t["key"] == "wheld":
        t["deps"].append("external:df:hdd-back")  # waits for the homelab HDD (a warden item in df)
# basalt-ui: one issue provides the capability weatherorb waits for
add("bu", "toolbelt", "basalt-ui static-analysis toolbelt minor released", "task", 2,
    ["plan:basalt-ui", "export:toolbelt"])
# basalt-ui Part 2 (waves 20-28) is queued behind Part 3 in the plan, so file order already chains it after W48

# ---------------------------------------------------------------- write
by_repo = {}
for t in tasks:
    by_repo.setdefault(t["repo"], []).append(t)
keys = {(t["repo"], t["key"]) for t in tasks}
for t in tasks:
    for d in t["deps"]:
        if d.startswith("external:"):
            continue
        assert (t["repo"], d) in keys, (t["repo"], t["key"], d)
    if t["parent"]:
        assert (t["repo"], t["parent"]) in keys, (t["repo"], t["key"], t["parent"])
os.makedirs(f"{SPIKE}/data", exist_ok=True)
json.dump({"tasks": tasks}, open(f"{SPIKE}/data/datasets.json", "w"), indent=1)

summary = {
    "as_of": "2026-10-22",
    "warden_snapshot": {"open_items": n_open, "alert_origin_excluded": n_open - len(witems),
                        "work_items": len(witems),
                        "feature_shaped": sum(1 for w in witems if w["kind"] == "feature"),
                        "fix_shaped": sum(1 for w in witems if w["kind"] == "fix"),
                        "by_origin": {o: sum(1 for w in witems if w["origin"] == o) for o in sorted({w["origin"] for w in witems})}},
    "round5": {"waves": len(r5), "checklist_tasks": sum(len(i) for *_, i in r5),
               "order_edges": sum(len(v) for v in ORDER.values()), "decision_tasks": 1},
    "weatherorb_plan": {"waves": len(wo_plan), "checklist_tasks": sum(len(i) for *_, i in wo_plan)},
    "basalt_ui_plan": {"waves": len(bu_plan), "checklist_tasks": sum(len(i) for *_, i in bu_plan)},
    "per_repo_tasks": {r: len(v) for r, v in sorted(by_repo.items())},
    "total_tasks": len(tasks),
    "edges": {"blocks_local": sum(1 for t in tasks for d in t["deps"] if not d.startswith("external:")),
              "external": sum(1 for t in tasks for d in t["deps"] if d.startswith("external:")),
              "parent_child": sum(1 for t in tasks if t["parent"])},
    "repo_map": {"df": "dotfiles (Round 5 epic + every non-weatherorb warden item)",
                 "wo": "weatherorb (current plan + its warden items)",
                 "bu": "basalt-ui (current plan)"},
}
os.makedirs(os.path.join(HERE, "..", "results"), exist_ok=True)
json.dump(summary, open(os.path.join(HERE, "..", "results", "datasets-summary.json"), "w"), indent=1)
print(json.dumps(summary, indent=1))
