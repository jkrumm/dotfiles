#!/usr/bin/env python3
"""Census of every wave section across every plan and archive, with its Left-behind.

Question (postmortem): every "locked" model since the September estate round drifted
within days -- what did each round plan, what actually closed, what did it leave behind,
and where did the left-behind items go? This script is the raw count; judgment lives in
postmortem.md.

Definitions (this script's own; DEFINITIONS.md has no key for this question):
  wave         a heading `## Wave <n> - <title> <!-- status: <s> -->` in a plan file
  round        one plan: a `docs/waves/PLAN.md` / `docs/waves/archive/*.md` file at AS_OF,
               or a plan recovered from git history because its PLAN.md was overwritten
               or deleted without an archive (source = "history")
  closed       the first commit (committer date, UTC) whose version of any plan file in
               the repo carries the wave's title with status `done`; for a recovered
               round whose last close-out commit deleted the file while its final wave
               still read `active`, that wave is counted done and marked status_inferred
  open_item    a Left-behind item matching an explicit deferral cue (OPEN_CUES). A lower
               bound; hand-checked on 100 platform items: precision ~80 %, recall ~65 %
  owner_gated  an open_item that names the owner or a present human as the blocker
  sink         where an open_item says it goes (owner, improve_loop, next_wave,
               state_file, tracker) or `none`: it names no consumer
  flags        regexes on the full Left-behind text of a done wave: review_gate_failed,
               not_shipped, gate_red, not_run_live (closing-quality signals)
  carried      a backticked identifier that appears in the open items of 3-12 different
               platform waves (heuristic; conservative)
  duplicate    a wave whose (number, title) already exists in another round of the same
               repo (agent-gateway's PLAN.md stub repeats Wave 11; weatherorb's trimmed
               plan repeats carried waves); current files win over recovered history;
               excluded from every aggregate
  domain       platform (dotfiles, gateways, warden, hermes-agent), ui (basalt-ui family,
               argo), product (weatherorb); assigned by repo name in this file

Inputs: git objects of every ~/SourceRoot/<repo> that is not a linked worktree, read at
the last commit before AS_OF (never the working tree), plus warden's
docs/history/state-log.md section headings. No network, no private stores. Free text goes
through ../lib/redact.py:redact(), plus a scrub of 1Password refs and URLs.

Reproducible as long as no commit dated before AS_OF arrives late (a pull from another
machine); `repo_revs_at_as_of` records the commit read per repo so a diff shows which moved.

Run:  python3 -I extract.py          # writes waves.out.json next to this file
      AS_OF=2026-10-22T08:00:00Z python3 -I extract.py
"""

import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))
from redact import redact as _redact  # noqa: E402


def redact(text):
    """lib/redact.py plus two scrubs this public repo wants: 1Password refs and URLs."""
    text = re.sub(r"op://\S+", "op://<ref>", text or "")
    text = re.sub(r"https?://[^\s)`'\"]+", "<url>", text)
    return _redact(text)

AS_OF = os.environ.get("AS_OF", "2026-10-22T08:00:00Z")
ROOT = os.path.expanduser("~/SourceRoot")
OUT = os.path.join(HERE, "waves.out.json")

PLAN_PATHS = ["docs/waves/PLAN.md", "docs/waves/archive"]
CLOSEOUT_RX = re.compile(r"close[- ]?out|\bdone\b|\bcomplete|\bclosed\b|\barchive", re.I)
LB_CHARS = 600
ITEM_CHARS = 240
MAX_ITEMS_PER_WAVE = 12

# Repos whose plans are about the agent platform; the rest adopt basalt-ui or build a product.
PLATFORM = {
    "dotfiles", "agent-gateway", "warden", "hermes-agent", "research-gateway",
    "email-gateway", "audio-gateway", "image-gateway", "usage-tracker", "brain",
    "homelab", "vps",
}
UI = {
    "basalt-ui", "basalt-ui-obsidian", "argo", "rb", "rollhook", "linewatch",
    "basalt-expr-trial", "basalt-expr-trial-v1",
}


def domain_of(repo):
    if repo in PLATFORM:
        return "platform"
    if repo in UI:
        return "ui"
    return "product"


# ---------------------------------------------------------------------------- git


def git(repo, *args):
    p = subprocess.run(
        ["git", "-C", repo, "-c", "core.quotepath=off", *args],
        capture_output=True, text=True, encoding="utf-8", errors="replace",
    )
    return p.stdout if p.returncode == 0 else None


def cat_batch(repo, specs):
    """Read many `<rev>:<path>` blobs in one process. Missing objects come back None."""
    if not specs:
        return []
    p = subprocess.run(
        ["git", "-C", repo, "cat-file", "--batch"],
        input=("\n".join(specs) + "\n").encode(), capture_output=True,
    )
    data, pos, out = p.stdout, 0, []
    for _ in specs:
        nl = data.index(b"\n", pos)
        header = data[pos:nl].decode("utf-8", "replace")
        pos = nl + 1
        if header.endswith(" missing") or header.endswith(" ambiguous"):
            out.append(None)
            continue
        size = int(header.split()[2])
        out.append(data[pos:pos + size].decode("utf-8", "replace"))
        pos += size + 1
    return out


def utc(iso):
    return datetime.fromisoformat(iso).astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def hours_between(a, b):
    fa = datetime.strptime(a, "%Y-%m-%dT%H:%M:%SZ")
    fb = datetime.strptime(b, "%Y-%m-%dT%H:%M:%SZ")
    return round((fb - fa).total_seconds() / 3600, 1)


def list_repos():
    repos, skipped = [], []
    for name in sorted(os.listdir(ROOT)):
        path = os.path.join(ROOT, name)
        dotgit = os.path.join(path, ".git")
        if not os.path.isdir(path) or not os.path.exists(dotgit):
            continue
        if os.path.isfile(dotgit):  # linked worktree: same history as its parent repo
            skipped.append({"repo": name, "why": "linked worktree"})
            continue
        if git(path, "rev-list", "-1", f"--before={AS_OF}", "HEAD") is None:
            continue
        if not (git(path, "log", f"--before={AS_OF}", "-1", "--format=%H", "--", *PLAN_PATHS) or "").strip():
            continue
        repos.append(name)
    return repos, skipped


# ------------------------------------------------------------------------- parse

WAVE_RE = re.compile(
    r"^(#{2,4})\s+Wave\s+(\d+[a-z]?)\b\s*(?:[—–:-]+\s*)?(.*?)\s*(?:<!--\s*status:\s*(.*?)\s*-->)?\s*$",
    re.I,
)
H1_RE = re.compile(r"^#\s+(.+?)\s*$")
HEADING12_RE = re.compile(r"^#{1,2}\s")
LB_RE = re.compile(r"^\s*(?:[-*]\s+)?\*\*Left behind(?:\s*\([^)]*\))?\s*:?\*\*\s*:?\s*(.*)$", re.I)
STEP_RE = re.compile(r"^\s*[-*]\s+\[([ xX])\]")
REPO_LINE_RE = re.compile(r"^\s*\**Repos?\**\s*:\s*(.+)$", re.I)
PAREN_REPOS_RE = re.compile(r"\(repos?:\s*([^)]*)\)", re.I)
BULLET_RE = re.compile(r"^\s{0,3}(?:[-*]|\d+[.)])\s+")
ENUM_RE = re.compile(r"(?:(?<=\s)|^)\(\d+\)\s+")
SENT_RE = re.compile(r"(?<=[.!?;])\s+(?=[A-Z(\[`*])")

OPEN_CUES = re.compile(
    "|".join([
        r"\bnot (?:done|run|fixed|verified|exercised|touched|investigated|pushed|deployed|proven|landed|covered"
        r"|tested|re-?run|closed|fully closed|spawned|started|implemented|migrated|measured|wired|resolved"
        r"|addressed|reproduced|checked|re-?checked|committed|merged|released|live)\b",
        r"\bnever (?:ran|run|started|spawned|built|picked|got|did)\b",
        r"\b(?:deferred|defers|declined|parked|postponed|punted|descoped)\b",
        r"\bleft (?:for|to|open|undone|unfixed|as-is|alone|behind for)\b",
        r"\bstill (?:open|red|says|say|fails|failing|needs|owes|lacks|unfixed|unresolved|stale|broken|unmapped"
        r"|dirty|wrong|describes|references|mentions|calls|reads|uses|contains|names|claims|asserts|carries|has no)\b",
        r"\bopen(?:,|:| items?\b| by\b| question| for\b)|\*\*open\b",
        r"\bwatch(?::|\*\*)|\bskipped\b|\bwaits? on\b|\bstays? (?:failing|open|red|pending|inert)\b|\bpending on\b",
        r"\baccepted (?:straggler|gap|debt)\b|\bknown (?:stale|limitation)\b|\blimitation\b",
        r"\b(?:needs?|requires?) (?:a |an |the )?(?:restart|reload|reconnect|`?/mcp)",
        r"\bstill (?:`?investigate`?|pending|waiting)\b",
        r"\bnot reloaded\b|\bnothing pushed\b|\bno `?/review`? run\b|\bsynthesis (?:failed|died)\b",
        r"\bfollow-?ups?\b",
        r"\bcarried\b",
        r"\bunresolved\b",
        r"\bremains? (?:open|unresolved|red|undone|a gap|unfixed|unverified|to be|the owner)",
        r"\bno (?:verdict|review verdict)\b|\bReview: none\b",
        r"\b(?:not in|out of) scope\b",
        r"\bnext wave\b",
        r"\bunverified\b|\buntested\b|\bunexercised\b",
        r"\bTODO\b|\bFIXME\b",
        r"\bknown (?:gap|issue|defect|limitation)s?\b",
        r"\bpre-existing (?:debt|failure|red|bug|defect|failing)\b",
        r"\bblocked (?:on|by)\b",
        r"\bowner(?:'s)? (?:call|decision|action|to|must|needs|should|only|move|job|start)\b",
        r"\bby (?:the )?owner\b|\bowner:|\bOwner,|\bneeds? (?:a human|the owner|an owner|owner)\b",
        r"\bnobody built\b|\bnobody (?:has|did)\b",
        r"\bdebt\b",
    ]),
    re.I,
)
FLAG_RX = {
    # the /review tool failed or did not run (a manual or independent substitute may exist)
    "review_gate_failed": re.compile(r"review:\s*none|\bno (?:review )?verdict|/review[^.;\n]{0,80}(?:not run|never ran|failed|died|did not run)"
                            r"|review (?:was |is )?not run|not reviewed|review was not run", re.I),
    # the change was committed but not pushed, deployed, reloaded or live
    "not_shipped": re.compile(r"\bnot (?:pushed|deployed|reloaded|live|published)\b|\bnothing pushed\b|committed locally|"
                              r"\bserver not reloaded\b|make deploy[^.;\n]{0,40}not run|\bNOT (?:pushed|live)", re.I),
    # a validation gate was red or failing when the wave closed and was left
    "gate_red": re.compile(r"red on clean HEAD|\bstill fails\b|\bfails only on\b|check[^.;\n]{0,30}\bred\b|"
                           r"failing on (?:clean )?(?:HEAD|master)|pre-existing (?:failure|red|debt)", re.I),
    # acceptance was reading or unit tests, not running the path
    "not_run_live": re.compile(r"not (?:run|exercised|proven|verified)[^.;\n]{0,30}(?:live|end[- ]to[- ]end|e2e)|"
                               r"never (?:run|ran) against a live|only (?:dry|hermetic|unit)", re.I),
}
OWNER_CUES = re.compile(
    r"\bowner\b|\bask-human\b|\ba human\b|\bhuman typ|\bbiometric\b|\bthe human\b", re.I
)


SINKS = [
    ("owner", re.compile(r"\bowner\b|\bask-human\b|\bhuman (?:typ|must|queue)|\bbiometric\b|\bMacBook\b", re.I)),
    ("improve_loop", re.compile(r"improve[- ]loop|warden-improve|improve cycle", re.I)),
    ("next_wave", re.compile(r"\bnext wave\b|\bwave \d+\b|\bfor wave\b|follow-?up wave|\bW\d+\b", re.I)),
    ("state_file", re.compile(r"STATE\.md|state-log|\u00a7\s?\d+|handover|PLAN\.md|\bLeft behind\b", re.I)),
    ("tracker", re.compile(r"\bissue\b|\bGitHub\b|#\d{2,}|\bPR\b|\bticket\b", re.I)),
]


def sink_of(item):
    """Where an open item says it goes. First match wins; `none` means it names no owner."""
    for name, rx in SINKS:
        if rx.search(item):
            return name
    return "none"


def status_class(raw):
    if raw is None:
        return "none"
    s = raw.strip().lower()
    for k in ("done", "active", "pending", "blocked", "dropped", "parked", "superseded"):
        if s.startswith(k):
            return k
    return "other"


def norm_title(t):
    t = re.sub(r"\((?:repos?|repo)[^)]*\)", " ", t, flags=re.I)
    return re.sub(r"[^a-z0-9]+", " ", t.lower()).strip()


def clean(text):
    return re.sub(r"\s+", " ", text).strip()


def split_items(lines):
    """Left-behind lines -> candidate items (bullets, enumerations, sentences)."""
    blocks, cur = [], []
    for ln in lines:
        if not ln.strip():
            if cur:
                blocks.append(" ".join(cur))
                cur = []
            continue
        if BULLET_RE.match(ln) and cur:
            blocks.append(" ".join(cur))
            cur = []
        cur.append(ln.strip())
    if cur:
        blocks.append(" ".join(cur))
    items = []
    for b in blocks:
        parts = ENUM_RE.split(b)
        for part in parts:
            part = clean(part)
            if not part:
                continue
            if len(part) > 400:
                items.extend(clean(s) for s in SENT_RE.split(part) if clean(s))
            else:
                items.append(part)
    return items


def parse_plan(text):
    lines = text.splitlines()
    title, in_fence = None, False
    heads = []  # (line index, level, match)
    for i, ln in enumerate(lines):
        if ln.lstrip().startswith("```"):
            in_fence = not in_fence
        if in_fence:
            continue
        if title is None:
            m = H1_RE.match(ln)
            if m:
                title = m.group(1)
        if HEADING12_RE.match(ln):
            heads.append(i)
    waves = []
    for hi, i in enumerate(heads):
        m = WAVE_RE.match(lines[i])
        if not m:
            continue
        end = heads[hi + 1] if hi + 1 < len(heads) else len(lines)
        body = lines[i + 1:end]
        lb_at = next((k for k, ln in enumerate(body) if LB_RE.match(ln)), None)
        steps_part = body if lb_at is None else body[:lb_at]
        steps = [STEP_RE.match(ln) for ln in steps_part]
        steps = [s for s in steps if s]
        lb_lines, lb_present = [], lb_at is not None
        if lb_present:
            first = LB_RE.match(body[lb_at]).group(1)
            lb_lines = ([first] if first.strip() else []) + body[lb_at + 1:]
            while lb_lines and (not lb_lines[-1].strip() or lb_lines[-1].strip() == "---"):
                lb_lines.pop()
        touches = []
        pm = PAREN_REPOS_RE.search(m.group(3) or "")
        if pm:
            touches = re.findall(r"`?([A-Za-z0-9._-]+)`?", pm.group(1))
        else:
            for ln in body[:4]:
                rm = REPO_LINE_RE.match(ln)
                if rm:
                    touches = re.findall(r"`?([A-Za-z][A-Za-z0-9._-]+)`?", re.split(r"[(.;]", rm.group(1))[0])
                    break
        title_raw = re.sub(r"\((?:repos?|repo)[^)]*\)", "", m.group(3) or "", flags=re.I).strip(" -—–")
        waves.append({
            "num": m.group(2),
            "title": title_raw,
            "key": f"{m.group(2)}|{norm_title(m.group(3) or '')}",
            "status_raw": (m.group(4) or "").strip() or None,
            "status": status_class(m.group(4)),
            "steps_total": len(steps),
            "steps_checked": sum(1 for s in steps if s.group(1) in "xX"),
            "lb_present": lb_present,
            "lb_lines": lb_lines,
            "touches": [t for t in touches if t],
        })
    return {"title": title or "", "waves": waves}


# ---------------------------------------------------------------------- per repo


def versions_of(repo):
    """Every (commit, plan path) version before AS_OF, oldest first, parsed."""
    out = git(repo, "log", f"--before={AS_OF}", "--reverse", "--name-only", "--format=@@%H %cI %s", "--", *PLAN_PATHS)
    commits, cur = [], None
    for line in (out or "").splitlines():
        if line.startswith("@@"):
            sha, iso, subject = line[2:].split(" ", 2)
            cur = {"sha": sha, "date": utc(iso), "subject": subject, "paths": []}
            commits.append(cur)
        elif line.strip() and cur is not None:
            cur["paths"].append(line.strip())
    pairs = [(c, p) for c in commits for p in c["paths"] if p.endswith(".md")]
    blobs = cat_batch(repo, [f"{c['sha']}:{p}" for c, p in pairs])
    versions, touches = [], []
    for (c, p), text in zip(pairs, blobs):
        touches.append({"sha": c["sha"], "date": c["date"], "subject": c["subject"], "path": p, "exists": text is not None})
        if text is None:
            continue
        parsed = parse_plan(text)
        versions.append({"sha": c["sha"], "date": c["date"], "path": p, **parsed})
    return versions, touches


def final_files(repo, rev):
    names = (git(repo, "ls-tree", "-r", "--name-only", rev, "--", *PLAN_PATHS) or "").split("\n")
    names = [n for n in names if n.endswith(".md")]
    blobs = cat_batch(repo, [f"{rev}:{n}" for n in names])
    return [(n, parse_plan(t)) for n, t in zip(names, blobs) if t is not None]


def timelines(versions):
    tl = {}
    for v in versions:
        for w in v["waves"]:
            e = tl.setdefault(w["key"], {"first_seen": v["date"], "first_seen_sha": v["sha"],
                                         "done_at": None, "done_sha": None})
            if w["status"] == "done" and e["done_at"] is None:
                e["done_at"], e["done_sha"] = v["date"], v["sha"]
    return tl


def _count(values):
    out = {}
    for v in values:
        out[v] = out.get(v, 0) + 1
    return dict(sorted(out.items()))


def summarize_wave(w, repo, plan_file, round_id, tl):
    lb_text = clean(" ".join(w["lb_lines"]))
    items = split_items(w["lb_lines"]) if w["lb_present"] else []
    open_items = [it for it in items if OPEN_CUES.search(it)]
    owner_items = [it for it in open_items if OWNER_CUES.search(it)]
    t = tl.get(w["key"], {})
    first_seen, done_at = t.get("first_seen"), t.get("done_at")
    cycle = hours_between(first_seen, done_at) if first_seen and done_at else None
    lb_out = redact(lb_text[:LB_CHARS]) + ("…" if len(lb_text) > LB_CHARS else "")
    return {
        "id": f"{repo}:{plan_file}:W{w['num']}",
        "repo": repo,
        "plan_file": plan_file,
        "round": round_id,
        "wave": w["num"],
        "title": redact(w["title"]),
        "status": w["status"],
        "status_raw": redact(w["status_raw"] or ""),
        "steps_total": w["steps_total"],
        "steps_checked": w["steps_checked"],
        "touches": w["touches"],
        "first_seen": first_seen,
        "closed": done_at,
        "closed_sha": (t.get("done_sha") or "")[:7] or None,
        "cycle_hours": cycle,
        "left_behind_present": w["lb_present"],
        "left_behind_chars": len(lb_text),
        "left_behind": lb_out,
        "left_behind_items": len(items),
        "open_item_count": len(open_items),
        "owner_gated_count": len(owner_items),
        "open_items": [redact(it[:ITEM_CHARS]) + ("…" if len(it) > ITEM_CHARS else "")
                       for it in open_items[:MAX_ITEMS_PER_WAVE]],
        "owner_gated_items": [redact(it[:ITEM_CHARS]) + ("…" if len(it) > ITEM_CHARS else "")
                              for it in owner_items[:6]],
        "flags": {k: bool(rx.search(lb_text)) for k, rx in FLAG_RX.items()},
        "sinks": _count([sink_of(it) for it in open_items]),
        "duplicate_of": None,
        "_key": w["key"],
        "_open_full": open_items,
    }


def build_repo(repo):
    path = os.path.join(ROOT, repo)
    rev = (git(path, "rev-list", "-1", f"--before={AS_OF}", "HEAD") or "").strip()
    versions, touches = versions_of(path)
    tl = timelines(versions)
    finals = final_files(path, rev)
    final_titles = {p["title"] for _, p in finals if p["title"]}

    rounds, waves = [], []

    def ended_by(version):
        """The next commit that touched the same plan path after this version (a delete or a rewrite)."""
        later = [t for t in touches if t["path"] == version["path"] and t["date"] >= version["date"]
                 and t["sha"] != version["sha"]]
        return later[0] if later else None

    def add_round(plan_file, parsed, source, rev_label, end=None):
        round_id = f"{repo}:{plan_file}"
        same = [v for v in versions if v["title"] == parsed["title"] and parsed["title"]]
        opened = min((v["date"] for v in same), default=None)
        touched = max((v["date"] for v in same), default=None)
        archived = min((v["date"] for v in versions
                        if v["path"] == plan_file and plan_file.startswith("docs/waves/archive/")), default=None)
        ws = [summarize_wave(w, repo, plan_file, round_id, tl) for w in parsed["waves"]]
        if end is not None and CLOSEOUT_RX.search(end["subject"]):
            # the last close-out commit deleted or replaced the file in the same breath: the
            # last stored version still shows its final wave `active`; record the inference.
            for w in ws:
                if w["status"] == "active":
                    w["status"], w["status_inferred"] = "done", f"ended by {end['sha'][:7]}: {redact(end['subject'])[:80]}"
                    w["closed"], w["closed_sha"] = end["date"], end["sha"][:7]
        rounds.append({
            "id": round_id,
            "repo": repo,
            "domain": domain_of(repo),
            "plan_file": plan_file,
            "source": source,
            "version": rev_label,
            "title": redact(parsed["title"]),
            "stub": parsed["title"].endswith("archived"),
            "opened": opened,
            "last_touched": touched,
            "archived_at": archived,
            "ended_by": None if end is None else {"sha": end["sha"][:7], "date": end["date"],
                                                  "subject": redact(end["subject"])[:100]},
            "_waves": ws,
        })
        waves.extend(ws)

    for name, parsed in finals:
        add_round(name, parsed, "file", rev[:7])

    # Plans overwritten or deleted without an archive: last version per title.
    seen_hist = set()
    for v in reversed(versions):
        if not v["title"] or v["title"] in final_titles or v["title"] in seen_hist:
            continue
        if not v["waves"]:
            continue
        seen_hist.add(v["title"])
        add_round(f"{v['path']}@{v['sha'][:7]}", {"title": v["title"], "waves": v["waves"]}, "history",
                  v["sha"][:7], ended_by(v))

    # Same repo, same wave (number + title) in two rounds: the current file's copy wins over a recovered
    # one, then the earlier round's; the other copy is marked `duplicate_of` and left out of every aggregate.
    rounds.sort(key=lambda r: (r["source"] != "file", r["opened"] or "9999", r["plan_file"]))
    owner = {}
    for r in rounds:
        for w in r["_waves"]:
            if w["_key"] in owner:
                w["duplicate_of"] = owner[w["_key"]]
            else:
                owner[w["_key"]] = w["id"]

    # Title history of the PLAN.md path: which rounds shared it, oldest first.
    history, prev = [], None
    for v in versions:
        if v["path"] != "docs/waves/PLAN.md" or not v["title"]:
            continue
        if v["title"] != prev:
            history.append({"title": redact(v["title"]), "first_commit": v["sha"][:7], "first_date": v["date"],
                            "last_commit": v["sha"][:7], "last_date": v["date"], "commits": 1})
            prev = v["title"]
        else:
            history[-1].update(last_commit=v["sha"][:7], last_date=v["date"], commits=history[-1]["commits"] + 1)
    return rounds, history


# ---------------------------------------------------------------------- aggregate

COUNT_KEYS = ["waves", "done", "active", "pending", "blocked", "dropped", "other",
              "steps_total", "steps_checked", "waves_with_left_behind", "left_behind_items",
              "open_items", "owner_gated_items",
              "done_review_gate_failed", "done_not_shipped", "done_gate_red", "done_not_run_live", "done_owner_gated"]


SINK_KEYS = ["owner", "improve_loop", "next_wave", "state_file", "tracker", "none"]


def zero():
    acc = {k: 0 for k in COUNT_KEYS}
    acc["open_item_sinks"] = {k: 0 for k in SINK_KEYS}
    return acc


def tally(acc, w):
    if w["duplicate_of"]:
        return
    acc["waves"] += 1
    st = w["status"] if w["status"] in ("done", "active", "pending", "blocked", "dropped") else "other"
    acc[st] += 1
    acc["steps_total"] += w["steps_total"]
    acc["steps_checked"] += w["steps_checked"]
    acc["waves_with_left_behind"] += 1 if w["left_behind_chars"] else 0
    acc["left_behind_items"] += w["left_behind_items"]
    acc["open_items"] += w["open_item_count"]
    acc["owner_gated_items"] += w["owner_gated_count"]
    for k, n in w["sinks"].items():
        acc["open_item_sinks"][k] += n
    if w["status"] == "done":
        acc["done_review_gate_failed"] += 1 if w["flags"]["review_gate_failed"] else 0
        acc["done_not_shipped"] += 1 if w["flags"]["not_shipped"] else 0
        acc["done_gate_red"] += 1 if w["flags"]["gate_red"] else 0
        acc["done_not_run_live"] += 1 if w["flags"]["not_run_live"] else 0
        acc["done_owner_gated"] += 1 if w["owner_gated_count"] else 0


ANCHOR_RX = re.compile(r"`([^`\s]{5,70})`")
GENERIC_ANCHORS = {"make", "check", "master", "main", "deploy", "verify", "AGENTS.md", "STATE.md", "PLAN.md", "README.md",
                   "docs/waves/PLAN.md", "CLAUDE.md", "package.json", "Makefile", "needs_decision", "needs_human"}


def carried_items(rounds_waves):
    """Open Left-behind items that name the same identifier in three or more different waves.

    Heuristic: an anchor is a backticked token that looks like a path, identifier or flag
    (it holds one of ./_-: or an inner capital), is not generic, and appears in the open
    items of at least 3 waves while appearing in at most 12 waves' open items overall.
    """
    by_anchor = {}
    for w in rounds_waves:
        seen = set()
        for it in w["_open_full"]:
            for a in ANCHOR_RX.findall(it):
                if a in GENERIC_ANCHORS or a in seen:
                    continue
                if not re.search(r"[./_:-]|[a-z][A-Z]", a) or a.startswith(("-", "$", "http")):
                    continue
                seen.add(a)
                by_anchor.setdefault(a, []).append((w, it))
    out = []
    for a, hits in by_anchor.items():
        waves = {w["id"]: w for w, _ in hits}
        if not 3 <= len(waves) <= 12:
            continue
        dates = sorted((w["closed"] or w["first_seen"] or "") for w in waves.values() if (w["closed"] or w["first_seen"]))
        if len(dates) < 3:
            continue
        out.append({
            "anchor": redact(a),
            "open_in_waves": len(waves),
            "rounds": len({w["round"] for w in waves.values()}),
            "first": dates[0], "last": dates[-1], "span_days": round(hours_between(dates[0], dates[-1]) / 24, 1),
            "wave_ids": sorted(waves),
            "example": redact(hits[0][1][:ITEM_CHARS]),
        })
    out.sort(key=lambda x: (-x["span_days"], -x["open_in_waves"], x["anchor"]))
    return out[:40]


def state_log_summary():
    path = os.path.join(ROOT, "warden")
    rev = (git(path, "rev-list", "-1", f"--before={AS_OF}", "HEAD") or "").strip()
    blobs = cat_batch(path, [f"{rev}:docs/history/state-log.md"])
    if not blobs or blobs[0] is None:
        return None
    head = re.compile(r"^##\s+§?(\d+)[.\s—-]+(.*?)\s*\((\d{4}-\d{2}-\d{2})[^)]*\)\s*$")
    cue = re.compile(r"stale|contradict|wrong|dead|defect|regress|bug|broke|revert|false|silent|missing|never|drift|leak", re.I)
    sections, by_date = [], {}
    for ln in blobs[0].splitlines():
        m = head.match(ln)
        if not m:
            continue
        n, title, date = int(m.group(1)), m.group(2), m.group(3)
        by_date[date] = by_date.get(date, 0) + 1
        sections.append({"n": n, "date": date, "title": redact(title[:110]), "defect_cue": bool(cue.search(title))})
    return {
        "path": "warden:docs/history/state-log.md",
        "sections_dated": len(sections),
        "first_date": min(by_date) if by_date else None,
        "last_date": max(by_date) if by_date else None,
        "sections_with_defect_cue_in_title": sum(1 for s in sections if s["defect_cue"]),
        "by_date": dict(sorted(by_date.items())),
        "sections": sections,
    }


def run():
    repos, skipped = list_repos()
    all_rounds, history = [], {}
    for repo in repos:
        rounds, hist = build_repo(repo)
        all_rounds.extend(rounds)
        if hist:
            history[repo] = hist
    all_rounds.sort(key=lambda r: (r["opened"] or "9999", r["id"]))

    agg_all, agg_domain, agg_repo = zero(), {}, {}
    waves_out = []
    platform_waves = [w for r in all_rounds if r["domain"] == "platform" for w in r["_waves"] if not w["duplicate_of"]]
    carried = carried_items(platform_waves)
    for r in all_rounds:
        acc = zero()
        for w in r["_waves"]:
            tally(acc, w)
            tally(agg_all, w)
            tally(agg_domain.setdefault(r["domain"], zero()), w)
            tally(agg_repo.setdefault(r["repo"], zero()), w)
            waves_out.append({k: v for k, v in w.items() if not k.startswith("_")})
        r.update(acc)
        unfinished = [w["wave"] for w in r["_waves"]
                      if not w["duplicate_of"] and w["status"] not in ("done", "dropped")]
        r["unfinished_waves"] = unfinished
        dones = [w["closed"] for w in r["_waves"] if not w["duplicate_of"] and w["status"] == "done" and w["closed"]]
        r["closed_at"] = max(dones) if dones and not unfinished else None
        r["days_open"] = (round(hours_between(r["opened"], r["closed_at"]) / 24, 1)
                          if r["opened"] and r["closed_at"] else None)
        r["wave_ids"] = [w["id"] for w in r["_waves"]]
        del r["_waves"]

    result = {
        "as_of": AS_OF,
        "script": "extract.py",
        "definitions": {
            "wave": "heading '## Wave <n> - <title> <!-- status: <s> -->' in a plan file",
            "round": "one plan file at AS_OF, or a plan recovered from git history (source=history)",
            "closed": "first commit whose version of any plan file in the repo has the wave's title at status done",
            "open_item": "Left-behind item matching an explicit deferral cue; a lower bound",
            "owner_gated": "open_item naming the owner or a present human as the blocker",
            "duplicate": "wave (number+title) already in an earlier round of the same repo; excluded from aggregates",
            "flags": "regex flags on the full Left-behind text of a done wave: review_gate_failed (the /review tool "
                     "failed or did not run), not_shipped (committed but not pushed/deployed/live), gate_red (a validation gate "
                     "left red or failing), not_run_live (acceptance by unit tests or reading, not the live path)",
            "status_inferred": "history rounds only: the plan's last close-out commit deleted or replaced the file "
                               "while its final wave still read active; that wave is counted done and marked",
        },
        "flag_patterns": {k: rx.pattern for k, rx in FLAG_RX.items()},
        "open_cues": OPEN_CUES.pattern,
        "owner_cues": OWNER_CUES.pattern,
        "repos_scanned": repos,
        "repo_revs_at_as_of": {r: (git(os.path.join(ROOT, r), "rev-list", "-1", f"--before={AS_OF}", "HEAD") or "").strip()[:9]
                               for r in repos},
        "repos_skipped": skipped,
        "aggregate": {
            "all": agg_all,
            "by_domain": dict(sorted(agg_domain.items())),
            "by_repo": dict(sorted(agg_repo.items())),
        },
        "rounds": all_rounds,
        "waves": waves_out,
        "carried_open_items_platform": carried,
        "plan_title_history": dict(sorted(history.items())),
        "state_log": state_log_summary(),
    }
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(result, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(f"wrote {OUT}: {len(all_rounds)} rounds, {len(waves_out)} waves "
          f"({agg_all['waves']} excl. duplicates), {agg_all['open_items']} open items")


if __name__ == "__main__":
    run()
