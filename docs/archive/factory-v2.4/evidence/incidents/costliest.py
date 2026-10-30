#!/usr/bin/env python3
"""Which incidents cost the most, and what happened to each from raw signal to closure?

Question (Phase 1, factory design): rank warden's incidents by owner pages, duration and
agent spend, and reconstruct the ten costliest (plus the 2026-10-17 outage) as timelines
that the design can later be replayed against.

DEFINITIONS.md keys implemented: `item` (duplicates are occurrences, reported apart),
`escalated`, `owner_touch`, `resolved` (terminal = closed/fixed/quiet), `time_to_resolve`
(first signal -> last closure, open items censored at AS_OF) and the attribution half of
`cost_per_resolved_item` (dispatches -> agw job id -> usage rows). Nothing here edits an input.

Inputs (all read-only, `file:...?mode=ro`, everything filtered `< AS_OF`):
  frozen snapshot  ~/.local/share/factory/snapshots/<AS_OF date>/{warden.db, usage.db}
                   (agw-jobs.db is read for job status where a row survives)
  live, append-only OpenCode session stores (aggregate columns of `session`/`session_v2`
                   only, never message bodies): ~/.local/share/opencode/opencode.db (to
                   2026-10-15) and ~/.local/share/agent-gateway/opencode/opencode.db (agw's
                   own store from 2026-10-14, which usage-tracker does not collect)
  git              ~/SourceRoot/<repo> `git log` / `git show -s` (read-only)
  host boot history  `ssh vps|homelab 'last -x reboot shutdown -F'` (wtmp is append-only; a read
                   command per evidence/README.md; skipped with status "unavailable" when ssh fails).
                   An incident whose first signal falls in a recorded shutdown..boot window is tagged
                   `host_reboot`: the root cause the ledger itself never recorded.

Run:  python3 -I costliest.py            ->  costliest.out.json, costliest.out.md
      AS_OF=2026-10-22T08:00:00Z python3 -I costliest.py   (env override)

NODES. An event row is reused for every recurrence of the same alert (UNIQUE(source,
external_id); first_seen is reset), so an item with several lifecycles is several nodes:
a node is one lifecycle segment of an item (a segment starts at the item's creation and at
every transition back into `new`) or one event that never got an item. A segment's signal
time is, for the lifecycle the event row currently describes, the earlier of events.first_seen
and the Slack message time (`ts_first`, else `ts_last`, if it lies within 6 h before
first_seen: Slack relays reach warden late); for older lifecycles it is the creation/reopen
transition (the raw signal time of past recurrences is not recorded).

GROUPING RULE (a baseline, NOT the design). Union-find over nodes; an incident is a component.
Time-proximity rules run first, identity rules after, so a weak link never bridges two incidents:
  R3 co-firing         alert-class nodes (Kuma/Slack alerts, Kuma push, HyperDX, docker,
                       job, op-refs, hermes_log, GitHub issues labelled alert) whose signal
                       times are <= 30 min (+ 2 min poll jitter: poll-batched sources arrive
                       29-31 min apart, and a bare 30 min cut one 6.5 h overnight outage into
                       five incidents) apart (single linkage over the time-sorted list)
                       AND share a source family (kuma = slack_alert + uk, docker, job, ...)
                       or the same non-empty repo. "Same host/monitor" is approximated by
                       the source family; this tool has no topology data (that is the point).
  R4 repo window       triage items with the same non-empty repo and the same class (alert vs
                       filed work) whose signal times are <= 32 min apart (batches of human- or
                       issue-filed work; an alert cluster and two filings in one repo are not one
                       incident just because they share a half hour).
                       R3 and R4 never produce a component whose node start times span more
                       than 8 h, and skip chronic items (>= 4 lifecycles): without both guards
                       one 5-hourly flapping push monitor chained a week of unrelated outages
                       into one 136-hour "incident". Known weakness: a busy repo (weatherorb)
                       fuses same-day filings.
  R1 duplicate_of      a duplicate lifecycle and the parent lifecycle nearest in time.
  R0 same item         consecutive lifecycles of one item <= 24 h apart (a flap, not a recurrence).
                       7 days chained two unrelated outages of one monitor two days apart;
                       chronic items (>= 4 lifecycles) are listed in meta.chronic_items instead.
  R2 root_cause        items whose normalised `root_cause` text is identical, spans
                       [signal, last_seen] <= 7 days apart (single linkage).
  R5 same fix          items citing the same commit (>= 7 hex chars, in the first 100 characters
                       of a closing note, or merged_sha/fixed_by_pr/pr_url) or the same PR,
                       spans <= 7 days apart; a ref cited by more than 8 items is a batch label
                       and ignored (a sha deeper in a note is prose, not a fix: it fused a
                       weatherorb watchdog fix with two Hermes log items).

PAGES (owner-facing notifications, the ranking's first key):
  pages = decision_entries + legacy_notifications + reminders
    decision_entries      transitions into `needs_decision` (each is a Slack line + an Argo
                          inbox entry; DEFINITIONS `escalated` counts the item once)
    legacy_notifications  events.notified_at not null (the pre-rebuild notifier, still used
                          for uk/hermes_log/job sources)
    reminders             events.reminder_count
  Reported, never added: slack_posts (distinct card_ts, a lower bound on lines posted),
  fixed_notices (entries into `fixed`), answers (card_hash `answered`).
  Incidents made only of notice-type events (deploy updates, stray skills, PR notices, cron
  status) are not incidents: excluded from the ranking, summarised in meta.

DURATION: first signal -> last closure of any non-noise node (an item with no recorded transitions: its
  last_seen when quiet, else its creation). For slack_alert/hermes_log/slack_update
  events without an item `resolved_at` is a retention sweep, not a recovery (>= 7 days on every row), so
  their closure is the last page, else first_seen. A node whose item is not in
  {closed, fixed, quiet} at AS_OF is open: the incident is censored and the duration runs to
  AS_OF (`open_items` says how many). Noise nodes (closed `ignored` by the policy ignore list:
  recovery notices, status-page chatter) never extend an incident. `duration_closed_h`
  ignores open nodes; `service_window_h` spans the alert nodes carrying a recovery timestamp
  (Kuma push / docker / HyperDX / job `resolved_at`).

COST: dispatches (origin_event_id) -> job id = the worktree directory name of the OpenCode
  session -> tokens and cost. Tracker rows (usage.db source `opencode`, to 2026-10-13) are
  priced by usage-tracker; later sessions only exist in the OpenCode stores, whose reported
  cost is a different (lower, model-dependent) price book, so it is scaled by the per-model
  median tracker/OpenCode ratio measured on the overlap (meta.cost_calibration; a model
  without overlap is counted unscaled and flagged in sessions_uncalibrated).
  Not attributed: the owner's Claude Code sessions, Hermes loops, agw triage/decide calls (no
  job id on the usage rows), in-place episodes (no worktree id), jobs before 2026-09-22.

RANKING (stated, not canonical): lexicographic key (pages desc, duration_h desc, cost_usd
  desc, first signal asc) over incidents that are not notice-only and have a page or an agent
  job. The same pool is also listed top-10 by each single dimension and, because the notifier
  that predates triage items dominates the page count, top-10 among loop-era incidents (>= 1
  item). Window: all history before AS_OF (DEFINITIONS windows 14d/30d/90d are not applied).
  The 2026-10-17 outage is always given a `detail` record.
"""

from __future__ import annotations

import collections
import datetime as dt
import json
import os
import re
import sqlite3
import statistics
import subprocess
import sys
from pathlib import Path

sys.dont_write_bytecode = True  # this script writes only into its own directory, never a __pycache__ in lib/
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "lib"))
from redact import redact  # noqa: E402

AS_OF = os.environ.get("AS_OF", "2026-10-22T08:00:00Z")
HOME = Path.home()
SNAP = Path(os.environ.get("FACTORY_SNAPSHOTS", HOME / ".local/share/factory/snapshots")) / AS_OF[:10]
OPENCODE_OLD = HOME / ".local/share/opencode/opencode.db"
OPENCODE_AGW = HOME / ".local/share/agent-gateway/opencode/opencode.db"
SOURCE_ROOT = HOME / "SourceRoot"
REPO_ALIAS = {"sideclaw": "agent-gateway", "dispatch-scratch": "agent-gateway"}

COFIRE_WINDOW = dt.timedelta(minutes=32)  # 30 min + 2 min of poll jitter: poll-batched sources arrive 29-31 min apart
COFIRE_SPAN = dt.timedelta(hours=8)
FLAP_WINDOW = dt.timedelta(hours=24)
ROOT_CAUSE_WINDOW = dt.timedelta(days=7)
FIX_REF_WINDOW = dt.timedelta(days=7)
SLACK_LAG_MAX = dt.timedelta(hours=6)
REF_MAX_ITEMS = 8
REF_NOTE_HEAD = 100  # a fix is cited in the first words of a closing note; later shas are prose
CHRONIC_LIFECYCLES = 4
TERMINAL = ("closed", "fixed", "quiet")
OUTAGE_DAY = "2026-10-17"  # always reconstructed (PLAN.md "Established facts")

ALERT_SOURCES = {"slack_alert", "uk", "hyperdx", "docker_homelab", "docker_vps", "job",
                 "op_refs_homelab", "hermes_log"}
NOTICE_SOURCES = {"slack_update", "stray_skill", "github_pr", "hermes_cron", "github_issue"}
# For these sources `resolved_at` is a retention sweep (every row is >= 7 days after first_seen, in
# batches such as 2026-06-08T08:00), not a recovery: it is never read as a closure.
SWEPT_SOURCES = {"slack_alert", "hermes_log", "slack_update"}
FAMILY = {"slack_alert": "kuma", "uk": "kuma", "hyperdx": "hyperdx", "docker_homelab": "docker",
          "docker_vps": "docker", "job": "job", "op_refs_homelab": "ops", "hermes_log": "hermes_log",
          "github_go": "github", "github_issue": "github", "github_pr": "github", "human": "human",
          "slack_update": "update", "stray_skill": "skill", "hermes_cron": "cron",
          "warden_self": "self", "warden_canary": "self"}

UUID_RE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
HEX_RE = re.compile(r"\b(?=[0-9a-f]*\d)(?=[0-9a-f]*[a-f])[0-9a-f]{7,40}\b")
PR_URL_RE = re.compile(r"github\.com/([\w.-]+/[\w.-]+)/pull/(\d+)")
# Beyond redact(): bare hostnames (public repo rule) and the homelab-private service names
# (CLAUDE.md: that repo is self-contained, its services are never named elsewhere).
HOST_RE = re.compile(r"\b(?!github\.com\b)(?:[a-z0-9-]+\.)+(?:com|org|net|io|dev|app|de|eu|cloud|test|ai)\b(?:/[^\s'\"`)\]]*)?", re.I)
PRIVATE_RE = re.compile(r"\b(?:qbittorrent|prowlarr|flaresolverr|gluetun|torrent[\w-]*|jellyfin|audiobookshelf|"
                        r"shelfmark|koinsight|myanonamouse|seedbox|vpn[- ]watchdog[\w-]*|cwa|mam)\b", re.I)


def clean(text, limit: int | None = None) -> str | None:
    """redact() first (the mandated gate), then hostnames and private service names, then trim."""
    if text is None:
        return None
    t = redact(str(text))
    t = re.sub(r"/Users/\w*", "~", t)  # warden truncates titles mid-path ("/Users/j"): redact() needs the full name
    t = HOST_RE.sub("<host>", t)
    t = PRIVATE_RE.sub("<private-service>", t)
    t = re.sub(r"\s+", " ", t).strip()
    return t if not limit or len(t) <= limit else t[: limit - 1] + "…"


def parse_ts(value) -> dt.datetime | None:
    if not value:
        return None
    d = dt.datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    return d if d.tzinfo else d.replace(tzinfo=dt.timezone.utc)


def iso(d: dt.datetime | None) -> str | None:
    return d.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ") if d else None


def hours(a: dt.datetime, b: dt.datetime) -> float:
    return round((b - a).total_seconds() / 3600, 2)


AS_OF_DT = parse_ts(AS_OF)
AS_OF_MS = int(AS_OF_DT.timestamp() * 1000)


def ro(path: Path) -> sqlite3.Connection:
    conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA query_only=ON")
    return conn


# --------------------------------------------------------------------------- load


def load_warden():
    w = ro(SNAP / "warden.db")
    ev = {r["id"]: dict(r) for r in w.execute("SELECT * FROM events WHERE first_seen < ?", (AS_OF,))}
    items = {r["event_id"]: dict(r) for r in w.execute("SELECT * FROM triage_items WHERE created_at < ?", (AS_OF,))}
    trans = collections.defaultdict(list)
    for r in w.execute("SELECT * FROM item_transitions WHERE at < ? ORDER BY id", (AS_OF,)):
        trans[r["event_id"]].append(dict(r))
    disp = collections.defaultdict(list)
    for r in w.execute("SELECT * FROM dispatches WHERE created_at < ? ORDER BY id", (AS_OF,)):
        disp[r["origin_event_id"]].append(dict(r))
    ops = collections.defaultdict(list)
    for r in w.execute("SELECT * FROM operations WHERE started_at < ? ORDER BY started_at", (AS_OF,)):
        ops[r["event_id"]].append(dict(r))
    return ev, items, trans, disp, ops


def payload(e: dict) -> dict:
    try:
        d = json.loads(e["payload_json"] or "{}")
        return d if isinstance(d, dict) else {}
    except (TypeError, ValueError):
        return {}


def signal_time(e: dict) -> dt.datetime:
    first = parse_ts(e["first_seen"])
    p = payload(e)
    best = first
    for key in ("ts_first", "ts_last"):
        try:
            ts = dt.datetime.fromtimestamp(float(p[key]), dt.timezone.utc)
        except (KeyError, TypeError, ValueError):
            continue
        if first - SLACK_LAG_MAX <= ts <= first and ts < best:
            best = ts
    return best


def is_alert(e: dict) -> bool:
    if e["source"] in ALERT_SOURCES:
        return True
    return e["source"] == "github_go" and "alert" in (payload(e).get("labels") or [])


# --------------------------------------------------------------------------- nodes


def split_segments(trans: list[dict]) -> list[list[dict]]:
    segs, cur = [], []
    for t in trans:
        if cur and t["to_state"] == "new" and t["from_state"] is not None:
            segs.append(cur)
            cur = []
        cur.append(t)
    if cur:
        segs.append(cur)
    return segs


def build_nodes(ev, items, trans):
    """node key (event_id, segment) -> node dict. See NODES in the docstring."""
    nodes = {}
    for i, e in ev.items():
        it = items.get(i)
        first_seen = parse_ts(e["first_seen"])
        if it is None:
            nodes[(i, 0)] = {"key": (i, 0), "event_id": i, "seg": 0, "n_seg": 1, "item": None, "trans": [], "t0": first_seen,
                             "start": signal_time(e), "end": None, "closure": None, "closure_basis": None, "noise": False,
                             "cur": True, "start_basis": "event_signal"}
            if e["resolved_at"] and e["source"] not in SWEPT_SOURCES:
                nodes[(i, 0)].update(closure=parse_ts(e["resolved_at"]), closure_basis="resolved_at")
            else:
                last = max(filter(None, [parse_ts(e["last_reminder_at"]), parse_ts(e["notified_at"]), first_seen]))
                nodes[(i, 0)].update(closure=last, closure_basis="last_page" if e["notified_at"] else "first_seen")
            nodes[(i, 0)]["end"] = nodes[(i, 0)]["closure"]
            continue
        segs = split_segments(trans.get(i, [])) or [[]]
        t0s = [parse_ts(s[0]["at"]) if s else parse_ts(it["created_at"]) for s in segs]
        cands = [k for k, t0 in enumerate(t0s) if t0 >= first_seen - dt.timedelta(minutes=1)]
        cur = cands[0] if cands else len(segs) - 1
        for k, seg in enumerate(segs):
            t0 = t0s[k]
            if k == cur:
                start, basis = min(signal_time(e), t0, parse_ts(it["first_seen"]) or t0 if k == 0 else t0), "event_signal"
            elif k == 0:
                start, basis = min(parse_ts(it["first_seen"]) or t0, t0), "item_first_seen"
            else:
                start, basis = t0, "reopen_transition"
            last_t = parse_ts(seg[-1]["at"]) if seg else t0
            final = seg[-1]["to_state"] if seg else "new"
            is_last = k == len(segs) - 1
            if final in TERMINAL:
                closure, cb = last_t, "terminal_transition"
            elif is_last and it["state"] in TERMINAL and not seg:
                # 33 items from the first triage days carry no transitions; updated_at is a later sweep, so the
                # last occurrence of the signal is the best closure estimate
                closure, cb = (parse_ts(it["last_seen"]) if it["state"] == "quiet" and it["last_seen"] else t0), "no_transitions"
            elif is_last and it["state"] in TERMINAL:
                closure, cb = parse_ts(it["updated_at"]), "terminal_state_updated_at"
            elif is_last:
                closure, cb = None, "open:" + it["state"]
            else:
                closure, cb = last_t, "superseded_by_reopen"
            note = (seg[-1]["note"] or "") if seg else ""
            noise = final == "closed" and not note.startswith("closed by hand") and (
                note.startswith(("matched the policy ignore list", "unstructured #alerts prose")) or (is_last and it["close_reason"] == "ignored"))
            nodes[(i, k)] = {"key": (i, k), "event_id": i, "seg": k, "n_seg": len(segs), "item": it, "trans": seg, "t0": t0,
                             "start": start, "end": last_t, "closure": closure, "closure_basis": cb, "noise": noise,
                             "cur": k == cur, "start_basis": basis}
    return nodes


def node_for(nodes, event_id: int, when: dt.datetime) -> tuple:
    """Lifecycle segment of an item that `when` belongs to: the last one that began at or before it."""
    n_seg = nodes[(event_id, 0)]["n_seg"]
    best = (event_id, 0)
    for k in range(n_seg):
        if nodes[(event_id, k)]["t0"] <= when + dt.timedelta(minutes=5):
            best = (event_id, k)
    return best


# --------------------------------------------------------------------------- grouping


class UnionFind:
    """Union-find that also tracks each component's spread of node start times."""

    def __init__(self, nodes):
        self.p = {k: k for k in nodes}
        self.lo = {k: n["start"] for k, n in nodes.items()}
        self.hi = dict(self.lo)

    def find(self, x):
        while self.p[x] != x:
            self.p[x] = self.p[self.p[x]]
            x = self.p[x]
        return x

    def union(self, a, b, max_spread: dt.timedelta | None = None) -> bool:
        ra, rb = self.find(a), self.find(b)
        if ra == rb:
            return False
        lo, hi = min(self.lo[ra], self.lo[rb]), max(self.hi[ra], self.hi[rb])
        if max_spread is not None and hi - lo > max_spread:
            return False
        keep, drop = min(ra, rb), max(ra, rb)
        self.p[drop] = keep
        self.lo[keep], self.hi[keep] = lo, hi
        return True


def fix_refs(text_sources: list[str]) -> set:
    refs = set()
    for text in text_sources:
        refs.update(("sha", m[:7]) for m in HEX_RE.findall(text))
        refs.update(("pr", repo, num) for repo, num in PR_URL_RE.findall(text))
    return refs


def node_fix_refs(n) -> set:
    it = n["item"]
    texts = [t["note"][:REF_NOTE_HEAD] for t in n["trans"] if t["to_state"] in TERMINAL and t["note"]
             and re.match(r"(closed by hand|merged|backfill|fixed|adopted by owner)", t["note"])]
    if n["seg"] == n["n_seg"] - 1:
        texts += [it.get(c) for c in ("merged_sha", "fixed_by_pr", "pr_url") if it.get(c)]
    return fix_refs(texts)


def chains(keys, nodes, end, window):
    """Runs of nodes: a node joins the current run when its start is within `window` of the latest end in the run."""
    keys = sorted(keys, key=lambda k: (nodes[k]["start"], k))
    run, run_end = [], None
    for k in keys:
        if run and nodes[k]["start"] - run_end <= window:
            run.append(k)
            run_end = max(run_end, end[k])
        else:
            if run:
                yield run
            run, run_end = [k], end[k]
    if run:
        yield run


def group(nodes, ev, items):
    """Time-proximity rules first (capped spread, chronic items excluded), identity rules after."""
    uf = UnionFind(nodes)
    edges = collections.Counter()
    end = {}
    for k, n in nodes.items():
        it = n["item"]
        e = n["end"] or n["start"]
        if it and n["seg"] == n["n_seg"] - 1 and it["last_seen"]:
            e = max(e, parse_ts(it["last_seen"]))
        end[k] = max(e, n["start"])
    chronic = {i for i in items if nodes[(i, 0)]["n_seg"] >= CHRONIC_LIFECYCLES}

    def union_run(run, rule):
        for b in run[1:]:
            if uf.union(run[0], b):
                edges[rule] += 1

    alerts = sorted((k for k, n in nodes.items() if is_alert(ev[n["event_id"]]) and k[0] not in chronic), key=lambda k: (nodes[k]["start"], k))
    fam = lambda k: FAMILY.get(ev[k[0]]["source"], ev[k[0]]["source"])
    repo = lambda k: (nodes[k]["item"] or {}).get("repo")
    for a_idx, a in enumerate(alerts):  # R3
        for b in alerts[a_idx + 1:]:
            if nodes[b]["start"] - nodes[a]["start"] > COFIRE_WINDOW:
                break
            if (fam(a) == fam(b) or (repo(a) and repo(a) == repo(b))) and uf.union(a, b, COFIRE_SPAN):
                edges["R3_cofire"] += 1
    by_repo = collections.defaultdict(list)
    for k, n in nodes.items():
        if n["item"] and n["item"]["repo"] and k[0] not in chronic:
            by_repo[(n["item"]["repo"], is_alert(ev[k[0]]))].append(k)  # filed work never fuses with an alert cluster by repo alone
    for ks in by_repo.values():  # R4
        ks.sort(key=lambda k: (nodes[k]["start"], k))
        for a, b in zip(ks, ks[1:]):
            if nodes[b]["start"] - nodes[a]["start"] <= COFIRE_WINDOW and uf.union(a, b, COFIRE_SPAN):
                edges["R4_repo_window"] += 1
    for i, it in items.items():  # R1
        p = it["duplicate_of"]
        if p not in items:
            continue
        for k in range(nodes[(i, 0)]["n_seg"]):
            me = nodes[(i, k)]
            near = min((nodes[(p, j)] for j in range(nodes[(p, 0)]["n_seg"])), key=lambda c: abs((c["start"] - me["start"]).total_seconds()))
            if uf.union(me["key"], near["key"]):
                edges["R1_duplicate_of"] += 1
    for i in items:  # R0
        for k in range(nodes[(i, 0)]["n_seg"] - 1):
            a, b = nodes[(i, k)], nodes[(i, k + 1)]
            if b["start"] - (a["end"] or a["start"]) <= FLAP_WINDOW and uf.union(a["key"], b["key"]):
                edges["R0_same_item"] += 1
    by_rc = collections.defaultdict(list)
    for i, it in items.items():
        if it["root_cause"]:
            by_rc[re.sub(r"\s+", " ", it["root_cause"].strip().lower())].append((i, nodes[(i, 0)]["n_seg"] - 1))
    for ks in by_rc.values():  # R2
        for run in chains(ks, nodes, end, ROOT_CAUSE_WINDOW):
            union_run(run, "R2_root_cause")
    by_ref = collections.defaultdict(set)
    for k, n in nodes.items():
        if n["item"]:
            for ref in node_fix_refs(n):
                by_ref[ref].add(k)
    for members in by_ref.values():  # R5
        if 1 < len({k[0] for k in members}) <= REF_MAX_ITEMS:
            for run in chains(members, nodes, end, FIX_REF_WINDOW):
                union_run(run, "R5_same_fix")
    comps = collections.defaultdict(list)
    for k in nodes:
        comps[uf.find(k)].append(k)
    return comps, dict(edges), sorted(chronic)


# --------------------------------------------------------------------------- usage


def load_usage(job_ids: set[str]):
    """job id -> tokens, io_tokens, cost_tracker, cost_calibrated, sessions. See COST above."""
    u = ro(SNAP / "usage.db")
    tracker = collections.defaultdict(lambda: {"tokens": 0, "io": 0, "cost": 0.0, "job": None})
    for r in u.execute("SELECT project, raw, cost_usd, input_tokens, output_tokens, cache_read_tokens, "
                       "cache_write_tokens, reasoning_tokens FROM usage_record WHERE source='opencode' AND ts < ?", (AS_OF,)):
        m = UUID_RE.search(r["project"] or "")
        job = m.group(0) if m and m.group(0) in job_ids else None
        try:
            sid = json.loads(r["raw"])["sessionId"]
        except (TypeError, ValueError, KeyError):
            continue
        t = tracker[sid]
        t["tokens"] += r["input_tokens"] + r["output_tokens"] + r["cache_read_tokens"] + r["cache_write_tokens"] + r["reasoning_tokens"]
        t["io"] += r["input_tokens"] + r["output_tokens"] + r["reasoning_tokens"]
        t["cost"] += r["cost_usd"] or 0.0
        t["job"] = t["job"] or job
    sessions = {}
    for store, tables in ((OPENCODE_OLD, ("session", "session_v2")), (OPENCODE_AGW, ("session_v2",))):
        if not store.exists():
            continue
        conn = ro(store)
        for table in tables:
            for r in conn.execute(f"SELECT id, directory, cost, tokens_input, tokens_output, tokens_reasoning, "
                                  f"tokens_cache_read, tokens_cache_write, model FROM {table} WHERE time_created < ?", (AS_OF_MS,)):
                m = UUID_RE.search(r["directory"] or "")
                if not m or m.group(0) not in job_ids:
                    continue
                try:
                    mj = json.loads(r["model"] or "{}")
                    model = f"{mj.get('providerID', '?')}/{mj.get('id', '?')}"
                except (TypeError, ValueError):
                    model = "?"
                io = r["tokens_input"] + r["tokens_output"] + r["tokens_reasoning"]
                sessions[r["id"]] = {"job": m.group(0), "model": model, "oc_cost": r["cost"] or 0.0,
                                     "tokens": io + r["tokens_cache_read"] + r["tokens_cache_write"], "io": io}
    ratios = collections.defaultdict(list)
    for sid, s in sessions.items():
        t = tracker.get(sid)
        if t and t["cost"] > 0 and s["oc_cost"] > 0:
            ratios[s["model"]].append(t["cost"] / s["oc_cost"])
    calib = {m: round(statistics.median(v), 3) for m, v in sorted(ratios.items()) if len(v) >= 3}
    per_job = collections.defaultdict(lambda: {"tokens": 0, "io_tokens": 0, "cost_tracker": 0.0, "cost_calibrated": 0.0,
                                               "sessions": 0, "sessions_uncalibrated": 0})
    for sid, s in sessions.items():
        agg = per_job[s["job"]]
        agg["sessions"] += 1
        t = tracker.get(sid)
        if t:
            agg["tokens"] += t["tokens"]; agg["io_tokens"] += t["io"]; agg["cost_tracker"] += t["cost"]
        else:
            agg["tokens"] += s["tokens"]; agg["io_tokens"] += s["io"]
            ratio = calib.get(s["model"])
            if ratio is None:
                ratio = 1.0
                agg["sessions_uncalibrated"] += 1
            agg["cost_calibrated"] += s["oc_cost"] * ratio
    for sid, t in tracker.items():  # tracker rows whose session left the stores
        if sid not in sessions and t["job"]:
            agg = per_job[t["job"]]
            agg["tokens"] += t["tokens"]; agg["io_tokens"] += t["io"]; agg["cost_tracker"] += t["cost"]; agg["sessions"] += 1
    return per_job, calib


def load_job_stats():
    path = SNAP / "agw-jobs.db"
    if not path.exists():
        return {}
    return {r["id"]: dict(r) for r in ro(path).execute("SELECT id, tool, status, created_at, started_at, finished_at, attempts, error_head FROM job_stats")}


# --------------------------------------------------------------------------- host boots

LAST_BOOT_RE = re.compile(r"^reboot\s+system\s+(?:boot\s+)?(\S+)\s+(\w{3} \w{3}\s+\d+ [\d:]{8} \d{4})")
LAST_DOWN_RE = re.compile(r"^shutdown\s+system\s+(?:down\s+)?(\S+)\s+(\w{3} \w{3}\s+\d+ [\d:]{8} \d{4})\s+-\s+(?:\w{3} \w{3}\s+\d+ ([\d:]{8}) (\d{4})|\S+)")


def last_ts(text: str) -> dt.datetime:
    return dt.datetime.strptime(" ".join(text.split()), "%a %b %d %H:%M:%S %Y").replace(tzinfo=dt.timezone.utc)


def host_boots(host: str) -> dict:
    """Boot records of a host from wtmp: [{down, up, kernel_from, kernel_to}] with down None when no clean shutdown was recorded."""
    cmd = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", host, "TZ=UTC last -x reboot shutdown -F"]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    except (subprocess.TimeoutExpired, OSError):
        return {"status": "unavailable", "boots": []}
    if r.returncode != 0:
        return {"status": "unavailable", "boots": []}
    boots, downs = [], []
    for line in r.stdout.splitlines():
        m = LAST_BOOT_RE.match(line)
        if m:
            boots.append({"kernel": m.group(1), "up": last_ts(m.group(2))})
            continue
        m = LAST_DOWN_RE.match(line)
        if m:
            downs.append({"kernel": m.group(1), "down": last_ts(m.group(2))})
    boots.sort(key=lambda b: b["up"])
    downs.sort(key=lambda d: d["down"])
    out = []
    for n, b in enumerate(boots):
        if b["up"] >= AS_OF_DT:
            continue
        prev = boots[n - 1] if n else None
        down = next((d for d in downs if prev and prev["up"] < d["down"] <= b["up"] and (b["up"] - d["down"]) < dt.timedelta(hours=1)), None)
        if b["up"] < parse_ts("2026-03-01T00:00:00Z"):
            continue
        out.append({"up": iso(b["up"]), "down": iso(down["down"]) if down else None,
                    "kernel_from": prev["kernel"] if prev else None, "kernel_to": b["kernel"],
                    "kernel_changed": bool(prev and prev["kernel"] != b["kernel"]),
                    "downtime_min": round((b["up"] - down["down"]).total_seconds() / 60, 1) if down else None})
    return {"status": "ok", "boots": out}


def tag_host_reboots(incs, boots_by_host):
    for inc in incs:
        first = parse_ts(inc["first_signal"])
        for host, rec in boots_by_host.items():
            for b in rec["boots"]:
                up = parse_ts(b["up"])
                down = parse_ts(b["down"]) if b["down"] else up - dt.timedelta(minutes=5)
                if down - dt.timedelta(minutes=10) <= first <= up + dt.timedelta(minutes=20):
                    inc["host_reboot"] = {"host": host, "down": b["down"], "up": b["up"], "downtime_min": b["downtime_min"],
                                          "kernel_from": b["kernel_from"], "kernel_to": b["kernel_to"], "clean_shutdown_recorded": bool(b["down"])}
                    break


# --------------------------------------------------------------------------- incidents


def node_counts(n, ev, ops):
    """Pages and owner touches of one node."""
    e = ev[n["event_id"]]
    out = collections.Counter()
    for t in n["trans"]:
        note = t["note"] or ""
        out["decision_entries"] += t["to_state"] == "needs_decision"
        out["fixed_notices"] += t["to_state"] == "fixed"
        out["closed_by_hand"] += note.startswith("closed by hand")
        out["reinvestigation_requests"] += note.startswith("re-investigation requested")
        out["by_owner_notes"] += bool(re.match(r"(adopted|retried|dismissed|merged|implemented) by owner", note))
    out["owner_ops"] = sum(o["authorized_by"].startswith(("owner:", "cli:")) for o in n.get("ops", []))
    if n["cur"]:
        out["legacy_notifications"] = 1 if e["notified_at"] else 0
        out["reminders"] = e["reminder_count"] or 0
    return out


def build_incident(keys, nodes, ev, items):
    keys = sorted(keys, key=lambda k: (nodes[k]["start"], k))
    ns = [nodes[k] for k in keys]
    anchor = ns[0]
    first_signal = anchor["start"]
    ids = sorted({n["event_id"] for n in ns})
    real_items = sorted({n["event_id"] for n in ns if n["item"] and not (n["item"]["duplicate_of"] or n["item"]["close_reason"] == "duplicate")})
    dup_items = sorted({n["event_id"] for n in ns if n["item"]} - set(real_items))
    event_only = sorted({n["event_id"] for n in ns if not n["item"]})
    tot = collections.Counter()
    touch_items = set()
    for n in ns:
        c = node_counts(n, ev, None)
        tot.update(c)
        if n["event_id"] in real_items and any(c[k] for k in ("decision_entries", "closed_by_hand", "reinvestigation_requests", "owner_ops")):
            touch_items.add(n["event_id"])
    pages = tot["decision_entries"] + tot["legacy_notifications"] + tot["reminders"]
    page_times = [parse_ts(t["at"]) for n in ns for t in n["trans"] if t["to_state"] == "needs_decision"]
    page_times += [parse_ts(ev[n["event_id"]]["notified_at"]) for n in ns if n["cur"] and ev[n["event_id"]]["notified_at"]]
    cards = {(n["item"]["card_channel"], n["item"]["card_ts"]) for n in ns if n["item"] and n["item"]["card_ts"] and n["trans"]
             and any(t["to_state"] in ("needs_decision", "fixed") for t in n["trans"]) and n["seg"] == n["n_seg"] - 1}
    answers = sum(1 for n in ns if n["item"] and n["seg"] == n["n_seg"] - 1 and n["item"]["card_hash"] == "answered")
    live = [n for n in ns if not n["noise"]] or ns
    open_states = collections.Counter(n["closure_basis"].split(":")[1] for n in live if n["closure"] is None)
    open_items = sum(open_states.values())
    closures = [n["closure"] for n in live if n["closure"] is not None]
    last_closure = max(closures) if closures else None
    end = AS_OF_DT if open_items else (last_closure or first_signal)
    recov = [parse_ts(ev[n["event_id"]]["resolved_at"]) for n in ns if n["cur"] and ev[n["event_id"]]["resolved_at"]
             and ev[n["event_id"]]["source"] in ("uk", "docker_homelab", "docker_vps", "hyperdx", "job")]
    kinds = set()
    for n in ns:
        e = ev[n["event_id"]]
        kinds.add("alert" if is_alert(e) else "notice" if e["source"] in NOTICE_SOURCES else "work")
    kind = "alert" if "alert" in kinds else "work" if "work" in kinds else "notice"
    jobs = [d for n in ns for d in n.get("disp", [])]
    by_tier = collections.Counter(d["tier"] for d in jobs)
    by_status = collections.Counter(d["status"] for d in jobs)
    wall = sum((parse_ts(d["finished_at"]) - parse_ts(d["created_at"])).total_seconds()
               for d in jobs if d["finished_at"] and parse_ts(d["finished_at"]) >= parse_ts(d["created_at"]))
    sources = collections.Counter(ev[i]["source"] for i in ids)
    lags = [(parse_ts(ev[n["event_id"]]["first_seen"]) - n["start"]).total_seconds() for n in ns if n["cur"] and n["start_basis"] == "event_signal"]
    repos = sorted({n["item"]["repo"] for n in ns if n["item"] and n["item"]["repo"]})
    return {
        "id": f"inc-{first_signal:%Y%m%dT%H%M}-e{anchor['event_id']}",
        "kind": kind,
        "era": "loop" if any(n["item"] for n in ns) else "pre_loop",
        "anchor_event": anchor["event_id"],
        "first_signal": iso(first_signal),
        "first_page_at": iso(min(page_times)) if page_times else None,
        "signal_to_first_page_min": round((min(page_times) - first_signal).total_seconds() / 60, 1) if page_times else None,
        "last_closure": iso(last_closure),
        "duration_h": hours(first_signal, end),
        "duration_closed_h": hours(first_signal, last_closure) if last_closure else None,
        "censored_at_as_of": bool(open_items),
        "open_items": open_items,
        "open_states": dict(sorted(open_states.items())),
        "service_window_h": hours(first_signal, max(recov)) if recov else None,
        "nodes": len(ns),
        "events": len(ids),
        "items": len(real_items),
        "duplicates": len(dup_items),
        "event_only": len(event_only),
        "event_ids": ids,
        "item_ids": real_items,
        "node_keys": [f"{k[0]}.{k[1]}" for k in keys],
        "repos": repos,
        "sources": dict(sorted(sources.items())),
        "pages": pages,
        "decision_entries": tot["decision_entries"],
        "legacy_notifications": tot["legacy_notifications"],
        "reminders": tot["reminders"],
        "slack_posts": len(cards),
        "fixed_notices": tot["fixed_notices"],
        "answers": answers,
        "escalated_items": len({n["event_id"] for n in ns if n["event_id"] in real_items and any(t["to_state"] == "needs_decision" for t in n["trans"])}),
        "owner_touch_items": len(touch_items),
        "owner_touch_actions": {k: tot[k] for k in ("decision_entries", "closed_by_hand", "reinvestigation_requests", "owner_ops", "by_owner_notes")},
        "agent_jobs": len(jobs),
        "agent_jobs_by_tier": dict(sorted(by_tier.items())),
        "agent_jobs_by_status": dict(sorted(by_status.items())),
        "agent_wall_h": round(wall / 3600, 2),
        "intake_lag_max_s": int(max(lags)) if lags else 0,
        "closure_basis": dict(sorted(collections.Counter(n["closure_basis"].split(":")[0] for n in ns).items())),
        "noise_nodes": sum(1 for n in ns if n["noise"]),
        "job_ids": sorted(d["job_id"] for d in jobs),
    }


def attach_cost(inc, usage):
    tok = io = covered = uncal = 0
    ct = cc = 0.0
    for j in inc["job_ids"]:
        u = usage.get(j)
        if u and u["tokens"]:
            covered += 1
            tok += u["tokens"]; io += u["io_tokens"]; ct += u["cost_tracker"]; cc += u["cost_calibrated"]; uncal += u["sessions_uncalibrated"]
    inc.update(jobs_with_tokens=covered, tokens_total=tok, tokens_io=io, cost_usd=round(ct + cc, 3),
               cost_usd_tracker=round(ct, 3), cost_usd_calibrated=round(cc, 3), sessions_uncalibrated=uncal)


# --------------------------------------------------------------------------- detail


def stage_of(t: dict) -> str:
    note = t["note"] or ""
    to, frm = t["to_state"], t["from_state"]
    if frm is None:
        return "created"
    if to == "needs_decision":
        return "page"
    for prefix, stage in (("pr_opened", "pr_opened"), ("pr_updated", "pr_updated"), ("verified", "verified"), ("merged and deployed", "merged_deployed")):
        if note.startswith(prefix):
            return stage
    if to in ("closed", "quiet"):
        return "closed_by_hand" if note.startswith("closed by hand") else to
    return {"merging": "merging", "verifying": "verifying", "fixed": "fixed", "triaged": "triaged", "working": "working",
            "failed": "failed", "new": "reopened"}.get(to, to)


def detail(inc, nodes, ev, jstats):
    ns = [nodes[tuple(int(x) for x in k.split("."))] for k in inc["node_keys"]]
    out_nodes, stages, ms = [], collections.defaultdict(lambda: {"n": 0, "first": None, "last": None}), []

    def mark(stage, when, text, ident, extra=None):
        s = stages[stage]
        s["n"] += 1
        s["first"] = when if s["first"] is None or when < s["first"] else s["first"]
        s["last"] = when if s["last"] is None or when > s["last"] else s["last"]
        m = {"t": iso(when), "stage": stage, "id": ident, "text": clean(text, 200)}
        m.update(extra or {})
        ms.append(m)

    for n in ns:
        e, it, i = ev[n["event_id"]], n["item"], n["event_id"]
        ident = f"{i}.{n['seg']}" if n["n_seg"] > 1 else str(i)
        c = node_counts(n, ev, None)
        out_nodes.append({
            "node": ident, "event_id": i, "source": e["source"], "start": iso(n["start"]), "start_basis": n["start_basis"],
            "title": clean(e["title"], 120), "repo": it["repo"] if it else None,
            "final_state": (n["trans"][-1]["to_state"] if n["trans"] else None), "close_reason": it["close_reason"] if it and n["seg"] == n["n_seg"] - 1 else None,
            "noise": n["noise"], "duplicate_of": it["duplicate_of"] if it else None,
            "root_cause": clean(it["root_cause"], 140) if it and it["root_cause"] and n["seg"] == n["n_seg"] - 1 else None,
            "decision_entries": c["decision_entries"], "legacy_notified": bool(c["legacy_notifications"]), "reminders": c["reminders"],
            "closure": iso(n["closure"]), "closure_basis": n["closure_basis"]})
        mark("signal", n["start"], e["title"], ident, {"source": e["source"]})
        if n["cur"] and n["start_basis"] == "event_signal" and parse_ts(e["first_seen"]) - n["start"] > dt.timedelta(minutes=5):
            mark("intake_lag", parse_ts(e["first_seen"]), f"warden saw it {int((parse_ts(e['first_seen']) - n['start']).total_seconds() // 60)} min after the raw signal", ident)
        if n["cur"] and e["notified_at"]:
            mark("legacy_notification", parse_ts(e["notified_at"]), "notified_at", ident)
        if n["cur"] and e["last_reminder_at"]:
            mark("reminder", parse_ts(e["last_reminder_at"]), f"last of {e['reminder_count']} reminders", ident)
        for t in n["trans"]:
            mark(stage_of(t), parse_ts(t["at"]), f"{t['from_state'] or '∅'}→{t['to_state']}: {t['note'] or ''}", ident)
        for d in n.get("disp", []):
            js = jstats.get(d["job_id"]) or {}
            mark(f"dispatch_{d['tier']}", parse_ts(d["created_at"]), f"{d['tier']} {d['status']} job {d['job_id'][:8]}", ident,
                 {"job": d["job_id"][:8], "finished": iso(parse_ts(d["finished_at"])), "status": d["status"], "error": clean(d["error"], 120),
                  "agw_status": js.get("status"), "agw_attempts": js.get("attempts")})
        for o in n.get("ops", []):
            mark(f"op_{o['kind']}", parse_ts(o["started_at"]), f"{o['kind']} by {o['authorized_by']} -> {o['outcome']}", ident,
                 {"authorized_by": o["authorized_by"], "outcome": o["outcome"]})
    ms.sort(key=lambda m: (m["t"], m["id"], m["stage"]))
    compact, seen = [], collections.Counter()
    for m in ms:  # first 6 and last 2 per stage keep a 60-node incident readable; owner-facing stages are kept whole
        n_stage = stages[m["stage"]]["n"]
        seen[m["stage"]] += 1
        if seen[m["stage"]] <= 6 or seen[m["stage"]] > n_stage - 2 or m["stage"].startswith(("closed_by_hand", "page", "fixed", "reopened", "op_")):
            compact.append(m)
    return {"stages": {k: {"n": v["n"], "first": iso(v["first"]), "last": iso(v["last"])} for k, v in sorted(stages.items())},
            "nodes": out_nodes, "milestones": compact[:400]}


def git_facts(inc, nodes, items):
    """Commits cited in closing notes/columns, plus fix/revert commits in each involved repo's window."""
    out = {"cited": [], "window": {}}
    refs = collections.defaultdict(set)
    for k in inc["node_keys"]:
        n = nodes[tuple(int(x) for x in k.split("."))]
        if n["item"]:
            for ref in node_fix_refs(n):
                if ref[0] == "sha":
                    refs[REPO_ALIAS.get(n["item"]["repo"], n["item"]["repo"])].add(ref[1])
    for repo, shas in sorted(refs.items(), key=lambda kv: str(kv[0])):
        path = SOURCE_ROOT / str(repo)
        if not (path / ".git").exists():
            continue
        for sha in sorted(shas):
            r = subprocess.run(["git", "-C", str(path), "show", "-s", "--format=%H%x1f%cI%x1f%s", sha], capture_output=True, text=True, timeout=60)
            if r.returncode == 0 and r.stdout.strip():
                h, when, subj = r.stdout.strip().split("\x1f", 2)
                out["cited"].append({"repo": repo, "sha": h[:10], "committed": when, "subject": clean(subj, 140)})
    first = parse_ts(inc["first_signal"]) - dt.timedelta(hours=1)
    last = min((parse_ts(inc["last_closure"]) if inc["last_closure"] else AS_OF_DT) + dt.timedelta(hours=12), first + dt.timedelta(days=14), AS_OF_DT)
    for repo in sorted({REPO_ALIAS.get(r, r) for r in inc["repos"]}):
        path = SOURCE_ROOT / repo
        if not (path / ".git").exists():
            continue
        r = subprocess.run(["git", "-C", str(path), "log", "--no-merges", f"--since={iso(first)}", f"--until={iso(last)}", "--format=%H%x1f%cI%x1f%s"],
                           capture_output=True, text=True, timeout=60)
        rows = []
        for line in r.stdout.splitlines():
            h, when, subj = line.split("\x1f", 2)
            if re.match(r"(fix|revert|hotfix)", subj, re.I):
                rows.append({"sha": h[:10], "committed": when, "subject": clean(subj, 140)})
        if rows:
            out["window"][repo] = rows[:20]
    return out


# --------------------------------------------------------------------------- facts


def facts(ev, items, trans, nodes, disp, boots_by_host):
    """Numbers quoted in incidents.md that are not an incident's own metrics."""
    out = {}
    lag = []
    for e in ev.values():
        if e["source"] in ("slack_alert", "slack_update"):
            try:
                raw = dt.datetime.fromtimestamp(float(payload(e)["ts_first"]), dt.timezone.utc)
            except (KeyError, TypeError, ValueError):
                continue
            d = (parse_ts(e["first_seen"]) - raw).total_seconds() / 60
            if 0 <= d <= SLACK_LAG_MAX.total_seconds() / 60:
                lag.append(d)
    lag.sort()
    if lag:
        out["slack_relay_intake_lag_min"] = {"n": len(lag), "median": round(statistics.median(lag), 1), "p90": round(lag[int(len(lag) * 0.9)], 1), "max": round(lag[-1], 1)}
    rec = boots_by_host.get("vps", {"boots": []})
    fp = []
    for b in rec["boots"]:
        if not b["down"]:
            continue
        down, up = parse_ts(b["down"]), parse_ts(b["up"])
        ns = [n for n in nodes.values() if down - dt.timedelta(minutes=10) <= n["start"] <= up + dt.timedelta(minutes=20) and is_alert(ev[n["event_id"]])]
        tot = collections.Counter()
        for n in ns:
            tot.update(node_counts(n, ev, None))
        fp.append({"down": b["down"], "up": b["up"], "kernel_to": b["kernel_to"], "downtime_min": b["downtime_min"], "alert_nodes": len(ns),
                   "pages": tot["decision_entries"] + tot["legacy_notifications"] + tot["reminders"]})
    out["vps_reboot_footprint"] = fp
    ids = [i for i, e in ev.items() if "checkpoint_manager" in (e["title"] or "") or "checkpoint" in (e["title"] or "") and "working directory not found" in (e["title"] or "")]
    cp = collections.Counter()
    for i in ids:
        cp["events"] += 1
        cp["pages"] += (1 if ev[i]["notified_at"] else 0) + (ev[i]["reminder_count"] or 0) + sum(1 for t in trans.get(i, []) if t["to_state"] == "needs_decision")
        cp["dispatches"] += len(disp.get(i, []))
    out["checkpoint_manager_family"] = {"events": cp["events"], "pages": cp["pages"], "dispatches": cp["dispatches"],
                                        "first": iso(min(parse_ts(ev[i]["first_seen"]) for i in ids)) if ids else None,
                                        "last": iso(max(parse_ts(ev[i]["first_seen"]) for i in ids)) if ids else None}
    quoted = collections.Counter()
    for rows in disp.values():
        for d in rows:
            if d["tier"] != "investigate" or d["created_at"][:10] != OUTAGE_DAY or not 1155 <= d["id"] <= 1171:
                continue
            e = ev.get(d["origin_event_id"])
            if e and e["source"] == "slack_alert":
                quoted["slack_path_briefs"] += 1
                quoted["quote_warden_poll_time"] += "2026-10-17 21:22 UTC" in (d["brief"] or "")
    out["outage_2026_10_17_briefs"] = dict(quoted)
    return out


# --------------------------------------------------------------------------- main


def main() -> None:
    ev, items, trans, disp, ops = load_warden()
    nodes = build_nodes(ev, items, trans)
    for d_list, field in ((disp, "disp"), (ops, "ops")):
        for i, rows in d_list.items():
            if i not in items:
                continue
            for r in rows:
                n = nodes[node_for(nodes, i, parse_ts(r["created_at"] if field == "disp" else r["started_at"]))]
                n.setdefault(field, []).append(r)
    comps, edges, chronic = group(nodes, ev, items)
    job_ids = {d["job_id"] for rows in disp.values() for d in rows}
    usage, calib = load_usage(job_ids)
    jstats = load_job_stats()
    for n in nodes.values():
        if "ops" in n:
            n["ops"].sort(key=lambda o: o["started_at"])
    rows = [build_incident(keys, nodes, ev, items) for keys in comps.values()]
    for r in rows:
        attach_cost(r, usage)
    rows.sort(key=lambda r: (r["first_signal"], r["anchor_event"]))
    boots_by_host = {h: host_boots(h) for h in ("vps", "homelab")}
    tag_host_reboots(rows, {h: v for h, v in boots_by_host.items() if v["status"] == "ok"})
    pool = [r for r in rows if r["kind"] != "notice" and (r["pages"] > 0 or r["agent_jobs"] > 0)]
    notice = [r for r in rows if r["kind"] == "notice" and r["pages"] > 0]
    key = lambda r: (-r["pages"], -r["duration_h"], -r["cost_usd"], r["first_signal"])
    ordered = sorted(pool, key=key)
    for rank, r in enumerate(ordered, 1):
        r["rank"] = rank
    top = ordered[:10]
    by_id = {r["id"]: r for r in rows}
    dims = {
        "pages": lambda r: (-r["pages"], -r["duration_h"], r["first_signal"]),
        "duration_h": lambda r: (-r["duration_h"], -r["pages"], r["first_signal"]),
        "cost_usd": lambda r: (-r["cost_usd"], -r["pages"], r["first_signal"]),
        "tokens_total": lambda r: (-r["tokens_total"], -r["pages"], r["first_signal"]),
        "agent_jobs": lambda r: (-r["agent_jobs"], -r["pages"], r["first_signal"]),
        "owner_touch_items": lambda r: (-r["owner_touch_items"], -r["pages"], r["first_signal"]),
    }
    top_by = {k: [r["id"] for r in sorted(pool, key=fn)[:10]] for k, fn in dims.items()}
    loop_top = [r["id"] for r in ordered if r["era"] == "loop"][:10]
    outage = sorted((r for r in pool if r["first_signal"].startswith(OUTAGE_DAY) and r["pages"] >= 10), key=lambda r: -r["pages"])[:1]
    detail_ids = list(dict.fromkeys([r["id"] for r in top] + [r["id"] for r in outage] + loop_top[:10]))
    details = {}
    for iid in detail_ids:
        r = by_id[iid]
        d = detail(r, nodes, ev, jstats)
        d["git"] = git_facts(r, nodes, items)
        details[iid] = d
    cover = collections.Counter()
    for rows_ in disp.values():
        for d in rows_:
            cover[(d["created_at"][:7], bool(usage.get(d["job_id"], {}).get("tokens")))] += 1
    chronic_rows = []
    for i in chronic:
        ns_ = [nodes[(i, k)] for k in range(nodes[(i, 0)]["n_seg"])]
        jobs_ = [d for n in ns_ for d in n.get("disp", [])]
        chronic_rows.append({
            "event_id": i, "title": clean(ev[i]["title"], 100), "repo": items[i]["repo"], "lifecycles": len(ns_),
            "first_start": iso(ns_[0]["start"]), "last_start": iso(ns_[-1]["start"]),
            "decision_entries": sum(1 for n in ns_ for t in n["trans"] if t["to_state"] == "needs_decision"),
            "closed_by_hand": sum(1 for n in ns_ for t in n["trans"] if (t["note"] or "").startswith("closed by hand")),
            "agent_jobs": len(jobs_), "tokens_total": sum((usage.get(d["job_id"]) or {}).get("tokens", 0) for d in jobs_),
            "cost_usd": round(sum((usage.get(d["job_id"]) or {}).get("cost_tracker", 0) + (usage.get(d["job_id"]) or {}).get("cost_calibrated", 0) for d in jobs_), 3)})
    chronic_rows.sort(key=lambda r: (-r["lifecycles"], r["event_id"]))
    meta = {
        "question": "Which incidents cost the most (pages, duration, agent spend) and what happened to each?",
        "as_of": AS_OF,
        "definition_keys": ["item", "escalated", "owner_touch", "resolved", "time_to_resolve", "cost_per_resolved_item"],
        "grouping_rule": {
            "node": "lifecycle segment of an item (split at every transition back into new) or an event without an item",
            "order": "R3, R4 (time proximity, spread <= 8 h, chronic items skipped) then R1, R0, R2, R5 (identity)",
            "R0": f"consecutive lifecycles of one item <= {int(FLAP_WINDOW.total_seconds() // 3600)} h apart",
            "R1": "duplicate_of: duplicate lifecycle to the parent lifecycle nearest in time",
            "R2": f"identical normalised root_cause, spans within {ROOT_CAUSE_WINDOW.days} days",
            "R3": f"alert-class nodes within {int(COFIRE_WINDOW.total_seconds() // 60)} min (30 + 2 poll jitter) sharing source family or repo",
            "R4": f"items with the same repo within {int(COFIRE_WINDOW.total_seconds() // 60)} min",
            "R5": f"same fix commit/PR (first {REF_NOTE_HEAD} chars of a closing note, or merge columns) cited by <= {REF_MAX_ITEMS} items, spans within {FIX_REF_WINDOW.days} days",
            "chronic": f"items with >= {CHRONIC_LIFECYCLES} lifecycles",
            "signal_time": "events.first_seen or the Slack message time when it lies within 6 h before first_seen; older lifecycles: creation/reopen transition"},
        "pages_definition": "decision_entries + legacy_notifications (notified_at) + reminders (reminder_count)",
        "ranking": "lexicographic: pages desc, duration_h desc, cost_usd desc, first_signal asc; pool = not notice-only and (pages > 0 or agent job)",
        "edges": edges,
        "counts": {"events": len(ev), "items": len(items), "nodes": len(nodes), "multi_lifecycle_items": sum(1 for i in items if nodes[(i, 0)]["n_seg"] > 1),
                   "incidents_all": len(rows), "incidents_ranked_pool": len(pool), "notice_only_incidents_excluded": len(notice),
                   "notice_only_pages_excluded": sum(r["pages"] for r in notice), "multi_node_incidents": sum(1 for r in rows if r["nodes"] > 1),
                   "dispatches": len(job_ids)},
        "coverage": {"dispatches_by_month_with_tokens": {f"{m}:{'tokens' if t else 'none'}": n for (m, t), n in sorted(cover.items())},
                     "jobs_with_tokens": sum(1 for j in job_ids if usage.get(j, {}).get("tokens")),
                     "agw_job_stats_rows_for_dispatches": sum(1 for j in job_ids if j in jstats),
                     "note": "tokens exist only from 2026-09-22 (OpenCode store start); in-place episodes and non-worktree sessions carry no job id"},
        "facts": facts(ev, items, trans, nodes, disp, {h: v for h, v in boots_by_host.items() if v["status"] == "ok"}),
        "cost_calibration": calib,
        "host_boots": {h: v for h, v in boots_by_host.items()},
        "chronic_items": chronic_rows,
        "reconcile": {"items_total": len(items), "items_ever_needs_decision": sum(1 for i in items if any(t["to_state"] == "needs_decision" for t in trans.get(i, []))),
                      "needs_decision_transitions": sum(1 for i in items for t in trans.get(i, []) if t["to_state"] == "needs_decision"),
                      "items_closed_by_hand": sum(1 for i in items if any((t["note"] or "").startswith("closed by hand") for t in trans.get(i, []))),
                      "note": "findings-2026-10-22.md: 114 / 597 items ever reached needs_decision"},
        "page_totals": {"decision_entries": sum(r["decision_entries"] for r in rows), "legacy_notifications": sum(r["legacy_notifications"] for r in rows),
                        "reminders": sum(r["reminders"] for r in rows)},
        "pages_in_ranked_pool": {"loop_era": sum(r["pages"] for r in pool if r["era"] == "loop"), "pre_loop": sum(r["pages"] for r in pool if r["era"] == "pre_loop")},
        "excluded_notice_incidents_top": [{"id": r["id"], "pages": r["pages"], "sources": r["sources"]} for r in sorted(notice, key=lambda r: -r["pages"])[:5]],
    }
    for r in rows:
        r.pop("job_ids", None)
    out = {
        "meta": meta,
        "ranking": {"top10": [r["id"] for r in top], "top10_loop_era": loop_top, "top10_by": top_by, "outage_2026_10_17": [r["id"] for r in outage]},
        "incidents": {r["id"]: r for r in ordered},
        "detail": details,
    }
    (HERE / "costliest.out.json").write_text(json.dumps(out, indent=2, sort_keys=True, ensure_ascii=False) + "\n", encoding="utf-8")
    (HERE / "costliest.out.md").write_text(render_md(out), encoding="utf-8")
    print(f"incidents: {len(rows)} (ranked pool {len(pool)}); top: {[r['id'] for r in top]}")


def render_md(out) -> str:
    inc = out["incidents"]
    cols = [("rank", "#"), ("id", "id"), ("kind", "kind"), ("era", "era"), ("first_signal", "first signal"), ("items", "items"), ("events", "events"),
            ("pages", "pages"), ("duration_h", "dur h"), ("open_items", "open"), ("agent_jobs", "jobs"), ("tokens_total", "tokens"),
            ("cost_usd", "cost $"), ("owner_touch_items", "touch items")]

    def table(ids):
        lines = ["| " + " | ".join(c[1] for c in cols) + " |", "|" + "-|" * len(cols)]
        for i in ids:
            lines.append("| " + " | ".join(str(inc[i][c[0]]) for c in cols) + " |")
        return "\n".join(lines)

    parts = ["# costliest incidents — generated by costliest.py\n",
             f"AS_OF `{out['meta']['as_of']}`. Grouping rule, page, duration and cost definitions: script docstring and `costliest.out.json` meta.\n",
             "## Top 10 (pages, then duration, then cost)\n", table(out["ranking"]["top10"]), "",
             "## Top 10 among loop-era incidents (at least one triage item)\n", table(out["ranking"]["top10_loop_era"]), ""]
    for dim, ids in out["ranking"]["top10_by"].items():
        parts += [f"## Top 10 by {dim}\n", table(ids), ""]
    parts += ["## Counts\n", "```json", json.dumps(out["meta"]["counts"], indent=2, sort_keys=True), "```", ""]
    return "\n".join(parts)


if __name__ == "__main__":
    main()
