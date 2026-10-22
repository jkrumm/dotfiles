#!/usr/bin/env python3
"""signals.py - which primary systems sit behind warden's Slack relays, what the relay loses,
and which direct intake path exists for each.

Question: 63 % of warden's signals (1,112 of 1,752) arrive through Slack relays (slack_update 713,
slack_alert 399). Which primary systems are behind them, what does the relay lose (structure,
fingerprints, recovery events, timing), and what direct path exists for each source?

Definition keys (DEFINITIONS.md): `item` (a triage_items row; rows with close_reason='duplicate' or
duplicate_of set are occurrences of their parent and are reported as `attached`), `escalated`
(>= 1 transition into needs_decision).

Inputs
  frozen   ~/.local/share/factory/snapshots/<AS_OF date>/warden.db   (events, triage_items,
           item_transitions; opened mode=ro, filtered < AS_OF)
  configs  checked-out repos, read at HEAD (heads recorded): warden (code paths, policy), homelab and
           homelab-private (Kuma monitors.yaml; private names are used for masking only), vps
           (HyperDX alerts-as-code), dotfiles docs/architecture.md (mini launchd table)
  probes   read-only, filtered < AS_OF where the store is append-only: ssh homelab (Kuma DB, Beszel DB,
           docker ps), ssh vps (docker ps, ClickStack deploy markers), gh API (Actions run counts).
           Nothing is changed, no alert is sent. --no-probe reuses the `probes` block of the previous
           signals.out.json so an offline re-run still yields complete outputs.

Outputs (this directory): signals.out.json, topology.out.json, signals.md. Stable key order. Every
free-text value passes lib/redact.py:redact(); homelab-private and IuRoot names are counted, never named.

Run:   python3 -I signals.py [--no-probe]        (AS_OF env override, default 2026-10-22T08:00:00Z)
Gate:  python3 -I ../lib/redact.py --check signals.out.json topology.out.json signals.md
"""

from __future__ import annotations

import argparse
import collections
import datetime as dt
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
EVIDENCE = HERE.parent
sys.dont_write_bytecode = True          # importing lib/redact.py must not drop a __pycache__ outside this directory
sys.path.insert(0, str(EVIDENCE / "lib"))
from redact import redact  # noqa: E402

UTC = dt.timezone.utc
AS_OF = os.environ.get("AS_OF", "2026-10-22T08:00:00Z")


def parse_ts(value: str) -> dt.datetime:
    d = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    return d if d.tzinfo else d.replace(tzinfo=UTC)


AS_OF_DT = parse_ts(AS_OF)
AS_OF_ISO = AS_OF_DT.isoformat()                        # 2026-10-22T08:00:00+00:00
AS_OF_SQL = AS_OF_DT.strftime("%Y-%m-%d %H:%M:%S")      # Kuma / Beszel / ClickHouse text format
SNAP_ROOT = Path(os.environ.get("FACTORY_SNAPSHOTS", Path.home() / ".local/share/factory/snapshots"))
WARDEN_DB = SNAP_ROOT / AS_OF[:10] / "warden.db"
ROOT = Path.home() / "SourceRoot"
OUT_JSON, OUT_TOPO, OUT_MD = HERE / "signals.out.json", HERE / "topology.out.json", HERE / "signals.md"
SLACK_SOURCES = ("slack_alert", "slack_update")

# --------------------------------------------------------------------------- small helpers


def pct(a: float, b: float, nd: int = 1):
    return round(100.0 * a / b, nd) if b else None


def quantile(xs, q):
    xs = sorted(xs)
    if not xs:
        return None
    k = (len(xs) - 1) * q
    f = int(k)
    c = min(f + 1, len(xs) - 1)
    return xs[f] + (xs[c] - xs[f]) * (k - f)


def dist(xs):
    if not xs:
        return {"n": 0, "median": None, "p90": None, "max": None}
    return {"n": len(xs), "median": round(quantile(xs, .5), 1), "p90": round(quantile(xs, .9), 1),
            "max": round(max(xs), 1)}


def month_of(d: dt.datetime) -> str:
    return d.strftime("%Y-%m")


def srt(counter) -> dict:
    return {k: counter[k] for k in sorted(counter, key=lambda x: str(x))}


def scrub(obj):
    """redact() every string value and key before anything is written."""
    if isinstance(obj, str):
        return redact(obj)
    if isinstance(obj, list):
        return [scrub(x) for x in obj]
    if isinstance(obj, dict):
        return {(redact(k) if isinstance(k, str) else k): scrub(v) for k, v in obj.items()}
    return obj


def git_head(repo: str) -> str | None:
    p = subprocess.run(["git", "-C", str(ROOT / repo), "rev-parse", "--short", "HEAD"],
                       capture_output=True, text=True)
    return p.stdout.strip() if p.returncode == 0 else None


def fingerprint_change_utc() -> dt.datetime:
    """When warden's fingerprint started stripping hex ids (commit 98d7798, warden repo)."""
    p = subprocess.run(["git", "-C", str(ROOT / "warden"), "log", "-1", "--format=%aI", "98d7798"],
                       capture_output=True, text=True)
    try:
        return parse_ts(p.stdout.strip()).astimezone(UTC)
    except ValueError:
        return parse_ts("2026-10-04T15:33:06Z")


# --------------------------------------------------------------------------- warden ledger


def load_events(db: sqlite3.Connection):
    escalated = {r[0] for r in db.execute(
        "SELECT DISTINCT event_id FROM item_transitions WHERE to_state='needs_decision' AND at < ?",
        (AS_OF_ISO,))}
    close_note = {}
    for ev, note in db.execute("SELECT event_id, note FROM item_transitions WHERE to_state='closed' AND at < ? ORDER BY id",
                               (AS_OF_ISO,)):
        close_note[ev] = note or ""
    q = """SELECT e.id, e.source, e.external_id, e.title, e.payload_json, e.first_seen, e.resolved_at,
                  t.event_id AS item_id, t.state, t.close_reason, t.duplicate_of,
                  t.created_at AS item_created, t.repo
           FROM events e LEFT JOIN triage_items t ON t.event_id = e.id AND t.created_at < ?
           WHERE e.first_seen < ? ORDER BY e.id"""
    rows = []
    for r in db.execute(q, (AS_OF_ISO, AS_OF_ISO)):
        try:
            payload = json.loads(r[4] or "{}")
        except json.JSONDecodeError:
            payload = {}
        if not isinstance(payload, dict):
            payload = {}

        def epoch(key):
            try:
                return dt.datetime.fromtimestamp(float(payload[key]), UTC)
            except (KeyError, TypeError, ValueError, OSError):
                return None

        rows.append({
            "id": r[0], "source": r[1], "external_id": r[2], "title": r[3], "payload": payload,
            "fs": parse_ts(r[5]), "resolved_at": r[6], "item": r[7] is not None, "state": r[8],
            "close_reason": r[9], "duplicate": (r[10] is not None) or (r[9] == "duplicate"),
            "item_created": parse_ts(r[11]) if r[11] else None, "repo": r[12],
            "escalated": r[0] in escalated, "ts_first": epoch("ts_first"), "ts_last": epoch("ts_last"),
            "close_note": close_note.get(r[0], ""),
        })
    return rows


def link_kind(r) -> str:
    if not r["item"]:
        return "no_item"
    if r["duplicate"]:
        return "duplicate"
    if r["close_reason"] == "ignored":
        return "ignored"
    return "worked"


def outcome(r) -> str:
    s = r["state"]
    if s in ("fixed", "quiet", "needs_decision", "failed"):
        return s
    if s == "closed":
        return "closed_" + (r["close_reason"] or "unknown")
    return "open"


def ignore_kind(r) -> str:
    n = r.get("close_note") or ""
    if n.startswith("matched the policy ignore list"):
        return "policy_ignore_list"
    if n.startswith("unstructured #alerts prose"):
        return "prose_filter"
    if n.startswith("closed by hand"):
        return "closed_by_hand"
    return "model_or_other"


def tally(rows, loop_start) -> dict:
    link, link_loop, worked = collections.Counter(), collections.Counter(), collections.Counter()
    ignored_by = collections.Counter()
    loop_events = esc = repo_null = items = 0
    for r in rows:
        k = link_kind(r)
        link[k] += 1
        if r["fs"] >= loop_start:
            loop_events += 1
            link_loop[k] += 1
        if k == "worked":
            worked[outcome(r)] += 1
        if k == "ignored":
            ignored_by[ignore_kind(r)] += 1
        if r["item"] and not r["duplicate"]:
            items += 1
            esc += 1 if r["escalated"] else 0
            repo_null += 1 if r["repo"] is None else 0
    return {"events": len(rows), "items": items, "link": srt(link), "loop_era_events": loop_events,
            "link_loop_era": srt(link_loop), "worked_outcomes": srt(worked), "ignored_by": srt(ignored_by),
            "escalated_items": esc, "items_without_repo": repo_null}


# --------------------------------------------------------------------------- Slack classification

KUMA_RE = re.compile(r"^\[(?P<mon>.+?)\] \[:(?:red_circle|white_check_mark): (?P<st>Down|Up)\]\s*(?P<msg>.*)$", re.S)
KUMA_GROUP_MSG_RE = re.compile(r"^(?:Child monitors down:|All children up and running)")
BETTER_RE = re.compile(r"^(?:New incident for |Automatically resolved .+ incident$)")
WATCHDOG_RE = re.compile(r"^HomeLab WatchDog")
HYPERDX_RE = re.compile(r"^(?:\U0001F6A8|✅) \S")
BESZEL_RE = re.compile(r"^(?:\S+ .*(?:above|below) threshold$|Connection to .+ is (?:up|down)\b)")
PRIVATE_APP_RE = re.compile(r"^\*(?P<title>[^*]+)\*: ")        # bold title, colon outside the bold: the notify helper's shape
RECOVERY_WORD_RE = re.compile(r"\b(?:success|restored|recovered|resolved)\b", re.I)
TEST_RE = re.compile(r"(?:identity test|webhook test|CANARY)")
ROLLHOOK_OK_RE = re.compile(r"^:white_check_mark: Deployed (?P<app>\S+) Image: ")
ROLLHOOK_FAIL_RE = re.compile(r"^:x: Deployment failed: (?P<app>\S+) Image: ")
WATCHTOWER_RE = re.compile(r"^Watchtower updates on ")

SYSTEM_LABEL = {
    "uptime_kuma": "Uptime Kuma (homelab)", "better_stack": "Better Stack (SaaS)",
    "beszel": "Beszel hub (homelab)", "homelab_watchdog": "HomeLab WatchDog (homelab cron)",
    "hyperdx": "HyperDX alerts (vps)", "homelab_private": "homelab-private apps and scripts",
    "rollhook": "RollHook (vps)", "watchtower": "Watchtower (homelab, vps)",
    "hermes_chat": "Hermes gateway chat (not a signal)", "test_canary": "test and canary posts",
}


def classify_slack(source: str, title: str):
    """(system, polarity, info). polarity: fault | recovery | info | chat | test. Text shape only:
    the ledger kept no poster id, so the primary system is inferred, never read."""
    if source == "slack_update":
        m = ROLLHOOK_OK_RE.match(title)
        if m:
            return "rollhook", "info", {"app": m["app"]}
        m = ROLLHOOK_FAIL_RE.match(title)
        if m:
            return "rollhook", "fault", {"app": m["app"]}
        if WATCHTOWER_RE.match(title):
            return "watchtower", "info", {}
        return "hermes_chat", "chat", {}
    if TEST_RE.search(title):
        return "test_canary", "test", {}
    m = KUMA_RE.match(title)
    if m:
        group = bool(KUMA_GROUP_MSG_RE.match(m["msg"].strip()))
        return "uptime_kuma", ("recovery" if m["st"] == "Up" else "fault"), {"mon": m["mon"], "group": group}
    if BETTER_RE.match(title):
        return "better_stack", ("recovery" if title.startswith("Automatically resolved") else "fault"), {}
    if WATCHDOG_RE.match(title):
        return "homelab_watchdog", ("recovery" if "\U0001F7E2" in title else "fault"), {}
    if HYPERDX_RE.match(title):
        return "hyperdx", ("recovery" if title.startswith("✅") else "fault"), {}
    if BESZEL_RE.match(title):
        return "beszel", ("recovery" if re.search(r"below threshold$|is up\b", title) else "fault"), {}
    m = PRIVATE_APP_RE.match(title)
    if m:
        return "homelab_private", ("recovery" if RECOVERY_WORD_RE.search(m["title"]) else "fault"), {}
    return "hermes_chat", "chat", {}


def hyperdx_project(title: str) -> str | None:
    t = re.sub(r"^\S+ ", "", title)
    for prefix, proj in (("research-gateway", "research-gateway"), ("email-gateway", "email-gateway"),
                         ("audio-gateway", "audio-gateway"), ("shutterflow", "shutterflow"),
                         ("VPS", "vps"), ("OTel ingest", "argo")):
        if t.startswith(prefix):
            return proj
    return None


def rollhook_project(app: str) -> str | None:
    for prefix, proj in (("argo-", "argo"), ("fpp-", "free-planning-poker"), ("weatherorb-", "weatherorb"),
                         ("shutterflow", "shutterflow"), ("research-gateway", "research-gateway"),
                         ("email-gateway", "email-gateway"), ("bun-email-api", "email-gateway"),
                         ("audio-gateway", "audio-gateway"), ("image-gen-gateway", "image-gateway"),
                         ("image-gateway", "image-gateway"), ("basalt-ui-marketing", "basalt-ui"),
                         ("rollhook-marketing", "rollhook"), ("jkrumm-com", "jkrumm.com")):
        if app.startswith(prefix):
            return proj
    return None


# --------------------------------------------------------------------------- configs on disk


def load_private_names():
    """Kuma monitor names declared by homelab-private (and the IuRoot 'Work' group): used to mask, never output."""
    private, work = set(), set()
    p = ROOT / "homelab-private/uptime-kuma/monitors.yaml"
    if not p.exists():
        return private, work
    top = None
    for line in p.read_text().splitlines():
        m = re.match(r"^(\s*)- name:\s*(.+?)\s*$", line)
        if not m:
            continue
        indent, name = len(m.group(1)), m.group(2)
        if indent <= 2:
            top = name
        if name == "HomeLab":
            continue
        (work if top == "Work" else private).add(name)
    return private, work


def load_public_kuma_yaml():
    """Names and declared types of the public homelab monitors.yaml (stdlib line parser, no YAML lib)."""
    p = ROOT / "homelab/uptime-kuma/monitors.yaml"
    names, cur = {}, None
    for line in p.read_text().splitlines():
        m = re.match(r"^(\s*)- name:\s*(.+?)\s*$", line)
        if m:
            cur = m.group(2)
            names[cur] = {"type": None}
            continue
        m = re.match(r"^\s+type:\s*(\w+)", line)
        if m and cur and names[cur]["type"] is None:
            names[cur]["type"] = m.group(1)
    names.pop("Warden - Ingest", None)    # a notification provider, not a monitor
    return names


def load_hyperdx_alerts():
    out = []
    d = ROOT / "vps/observability/alerts"
    project_of = {"research-gateway": "research-gateway", "email-gateway": "email-gateway",
                  "audio-gateway": "audio-gateway", "shutterflow": "shutterflow", "Argo API": "argo",
                  "VPS — Overview": "vps"}
    for f in sorted(d.glob("*.json")):
        a = json.loads(f.read_text())
        out.append({"name": a.get("name"), "dashboard": a.get("dashboard"),
                    "project": project_of.get(a.get("dashboard")), "interval": a.get("interval"),
                    "threshold": a.get("threshold"), "type": a.get("thresholdType"),
                    "channels": sorted(c.get("webhook", "") for c in a.get("channels", []))})
    return out


def load_policy():
    p = ROOT / "warden/config/triage-policy.json"
    pol = json.loads(p.read_text())
    rules = pol.get("rules") or []
    by_repo = collections.Counter(r.get("repo") for r in rules)
    ignore = [(x.get("match", "") if isinstance(x, dict) else str(x)) for x in (pol.get("ignore") or [])]
    return {"rules_total": len(rules), "rules_by_repo": srt(by_repo),
            "ignore_total": len(ignore),
            "ignores_kuma_up_lines": any("white-check-mark-up" in x for x in ignore),
            "ignores_better_stack_resolved_lines": any("automatically-resolved" in x for x in ignore),
            "ignore_unstructured_slack_prose": bool(pol.get("ignoreUnstructuredSlackProse"))}


def load_mini_launchagents():
    """Parse the '## LaunchAgents - mini' tables of docs/architecture.md: label -> owner repo, schedule."""
    text = (ROOT / "dotfiles/docs/architecture.md").read_text()
    rows, in_sec, owner = [], False, None
    for line in text.splitlines():
        if line.startswith("## LaunchAgents — mini"):
            in_sec = True
            continue
        if in_sec and line.startswith("## "):
            break
        if not in_sec:
            continue
        m = re.match(r"^### (.+)$", line)
        if m:
            owner = m.group(1).strip()
            continue
        m = re.match(r"^\| `([^`]+)` \| ([^|]+) \| ([^|]+) \|", line)
        if not m or owner is None:
            continue
        label, c2, c3 = m.group(1), m.group(2).strip(), m.group(3).strip()
        if owner == "others":
            rows.append({"label": label, "owner": c2.split(" (")[0], "schedule": c3})
        else:
            rows.append({"label": label, "owner": owner, "schedule": c2})
    return rows


def project_universe():
    skip = re.compile(r"(?:-w\d+|-trial(?:-v\d+)?|-compare)$")
    return sorted(p.name for p in ROOT.iterdir()
                  if p.is_dir() and (p / ".git").exists() and not skip.search(p.name) and p.name != "_ext")


# --------------------------------------------------------------------------- read-only probes

ALLOWED_REMOTE = ("sqlite3 -readonly ", "docker ps ", "docker events ",
                  "docker exec clickstack clickhouse-client --query ")
KUMA_METRICS_PROBE = "curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:3010/metrics"   # unauthenticated GET


def ssh_ro(host: str, remote_cmd: str, stdin: str | None = None, timeout: int = 120):
    assert remote_cmd.startswith(ALLOWED_REMOTE) or remote_cmd == KUMA_METRICS_PROBE, remote_cmd
    try:
        p = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", host, remote_cmd],
                           input=stdin, capture_output=True, text=True, timeout=timeout)
    except (subprocess.TimeoutExpired, OSError) as e:
        return None, type(e).__name__
    if p.returncode != 0:
        return None, (p.stderr.strip()[:160] or f"rc={p.returncode}")
    return p.stdout, None


def probe_kuma(private: set, work: set) -> dict:
    sql = f""".mode list
.separator |
SELECT 'mon', m.id, m.name, m.type, ifnull(p.name,''), m.interval, m.maxretries, ifnull(m.docker_container,''), m.active FROM monitor m LEFT JOIN monitor p ON p.id=m.parent ORDER BY m.id;
SELECT 'notif', n.name, count(*) FROM monitor_notification mn JOIN notification n ON n.id=mn.notification_id GROUP BY n.name;
SELECT 'nohook', m.id, m.name FROM monitor m WHERE m.type<>'group' AND m.id NOT IN (SELECT mn.monitor_id FROM monitor_notification mn JOIN notification n ON n.id=mn.notification_id WHERE n.name='Warden - Ingest');
SELECT 'imp', substr(h.time,1,7), CASE WHEN m.type='group' THEN 'group' ELSE 'leaf' END, h.status, count(*) FROM heartbeat h JOIN monitor m ON m.id=h.monitor_id WHERE h.important=1 AND h.time < '{AS_OF_SQL}' GROUP BY 2,3,4;
SELECT 'range', min(time), max(time), count(*) FROM heartbeat WHERE time < '{AS_OF_SQL}';
SELECT 'tags', (SELECT count(*) FROM tag), (SELECT count(*) FROM monitor_tag);
SELECT 'apikeys', count(*) FROM api_key;
SELECT 'win_all', max(c), sum(c>50), count(*) FROM (SELECT substr(h.time,1,13) || CASE WHEN substr(h.time,15,2) < '30' THEN ':00' ELSE ':30' END AS b, count(*) c FROM heartbeat h WHERE h.important=1 AND h.status IN (0,1) AND h.time < '{AS_OF_SQL}' GROUP BY b);
SELECT 'win_leaf', max(c), sum(c>50), count(*) FROM (SELECT substr(h.time,1,13) || CASE WHEN substr(h.time,15,2) < '30' THEN ':00' ELSE ':30' END AS b, count(*) c FROM heartbeat h JOIN monitor m ON m.id=h.monitor_id WHERE m.type<>'group' AND h.important=1 AND h.status IN (0,1) AND h.time < '{AS_OF_SQL}' GROUP BY b);
SELECT 'win_top', b, c FROM (SELECT substr(h.time,1,13) || CASE WHEN substr(h.time,15,2) < '30' THEN ':00' ELSE ':30' END AS b, count(*) c FROM heartbeat h WHERE h.important=1 AND h.status IN (0,1) AND h.time < '{AS_OF_SQL}' GROUP BY b ORDER BY c DESC LIMIT 3);
WITH h AS (SELECT monitor_id, status, time, LEAD(status) OVER (PARTITION BY monitor_id ORDER BY time) AS ns, LEAD(time) OVER (PARTITION BY monitor_id ORDER BY time) AS nt FROM heartbeat WHERE important=1 AND status IN (0,1) AND time < '{AS_OF_SQL}')
SELECT 'outage', bucket, count(*) FROM (SELECT CASE WHEN (julianday(nt)-julianday(time))*86400 < 300 THEN '1:<5m' WHEN (julianday(nt)-julianday(time))*86400 < 1800 THEN '2:5-30m' WHEN (julianday(nt)-julianday(time))*86400 < 7200 THEN '3:30m-2h' WHEN (julianday(nt)-julianday(time))*86400 < 86400 THEN '4:2-24h' ELSE '5:>=24h' END AS bucket FROM h JOIN monitor m ON m.id=h.monitor_id WHERE h.status=0 AND h.ns=1 AND m.type<>'group') GROUP BY bucket ORDER BY bucket;
WITH d AS (SELECT h.monitor_id, (cast(strftime('%s', h.time) AS integer) / 300) AS b5 FROM heartbeat h JOIN monitor m ON m.id=h.monitor_id WHERE m.type<>'group' AND h.important=1 AND h.status=0 AND h.time < '{AS_OF_SQL}')
SELECT 'cofire', sum(k), sum(CASE WHEN k>=3 THEN 1 ELSE 0 END), sum(CASE WHEN k>=3 THEN k ELSE 0 END) FROM (SELECT b5, count(DISTINCT monitor_id) AS k FROM d GROUP BY b5);
"""
    out, err = ssh_ro("homelab", "sqlite3 -readonly /home/jkrumm/ssd/uptime-kuma/kuma.db", stdin=sql)
    if out is None:
        return {"error": err}
    res = {"monitors": [], "notifications": {}, "leaf_without_warden_webhook": [], "important_heartbeats": {},
           "burst": {}, "outage_buckets": {}, "cofire_5m": {}}
    private_n = work_n = 0
    for line in out.splitlines():
        f = line.split("|")
        tag = f[0]
        if tag == "mon":
            mid, name, typ, parent = int(f[1]), f[2], f[3], f[4]
            if name in private or name in work:
                private_n += name in private
                work_n += name in work
                res["monitors"].append({"id": mid, "name": None, "type": typ, "parent": None,
                                        "class": "homelab-private" if name in private else "work"})
            else:
                res["monitors"].append({"id": mid, "name": name, "type": typ, "parent": parent or None,
                                        "interval": int(f[5]), "maxretries": int(f[6]),
                                        "docker_container": f[7] or None, "class": "public"})
        elif tag == "notif":
            res["notifications"][f[1]] = int(f[2])
        elif tag == "nohook":
            nm = f[2]
            res["leaf_without_warden_webhook"].append(
                {"id": int(f[1]), "name": nm if nm not in private and nm not in work else None})
        elif tag == "imp":
            key = f"{f[1]}|{f[2]}|{f[3]}"
            res["important_heartbeats"][key] = int(f[4])
        elif tag == "range":
            res["heartbeat_range"] = {"first": f[1], "last": f[2], "rows": int(f[3])}
        elif tag == "tags":
            res["tags"] = {"tag_definitions": int(f[1]), "monitor_tag_links": int(f[2])}
        elif tag == "apikeys":
            res["api_keys"] = int(f[1])
        elif tag in ("win_all", "win_leaf"):
            res["burst"][tag] = {"max_per_30min": int(f[1]), "windows_over_50": int(f[2] or 0), "windows": int(f[3])}
        elif tag == "win_top":
            res["burst"].setdefault("top_windows", []).append({"window_utc": f[1], "heartbeats": int(f[2])})
        elif tag == "outage":
            res["outage_buckets"][f[1]] = int(f[2])
        elif tag == "cofire":
            res["cofire_5m"] = {"leaf_down_transitions": int(f[1]), "buckets_with_3plus_monitors": int(f[2]),
                                "transitions_in_those_buckets": int(f[3])}
    code, _ = ssh_ro("homelab", KUMA_METRICS_PROBE, timeout=30)
    res["metrics_endpoint_http_status_without_credentials"] = int(code) if code and code.strip().isdigit() else None
    res["monitor_total"] = len(res["monitors"])
    res["by_type"] = srt(collections.Counter(m["type"] for m in res["monitors"]))
    res["private_monitors"], res["work_monitors"] = private_n, work_n
    return res


def probe_beszel() -> dict:
    sql = f""".mode list
.separator |
SELECT 'hist', substr(created,1,7), name, count(*), sum(resolved<>'') FROM alerts_history WHERE created < '{AS_OF_SQL}' GROUP BY 2,3;
SELECT 'range', min(created), max(created), count(*) FROM alerts_history WHERE created < '{AS_OF_SQL}';
SELECT 'defs', name, count(*) FROM alerts GROUP BY name;
"""
    out, err = ssh_ro("homelab", "sqlite3 -readonly /mnt/hdd/beszel/data.db", stdin=sql)
    if out is None:
        return {"error": err}
    res = {"history_by_month": {}, "alert_definitions": {}}
    for line in out.splitlines():
        f = line.split("|")
        if f[0] == "hist":
            m = res["history_by_month"].setdefault(f[1], {"episodes": 0, "resolved": 0, "by_alert": {}})
            m["episodes"] += int(f[3])
            m["resolved"] += int(f[4] or 0)
            m["by_alert"][f[2]] = int(f[3])
        elif f[0] == "range":
            res["history_range"] = {"first": f[1], "last": f[2], "rows": int(f[3])}
        elif f[0] == "defs":
            res["alert_definitions"][f[1]] = int(f[2])
    return res


FORMAT_PS = "'{{.Names}}|{{.Image}}|{{.Label \"com.docker.compose.project\"}}|{{.Label \"com.docker.compose.service\"}}|{{.Label \"com.centurylinklabs.watchtower.enable\"}}'"


def probe_docker(host: str) -> dict:
    out, err = ssh_ro(host, f"docker ps --format {FORMAT_PS}")
    if out is None:
        return {"error": err}
    units, private_n = [], 0
    for line in out.splitlines():
        f = line.split("|")
        if len(f) < 5:
            continue
        name, image, proj, svc, wt = f[:5]
        if proj == "homelab-private":        # counted, never named (isolation rule)
            private_n += 1
            continue
        internal = bool(re.match(r"^[a-z0-9.-]+\.[a-z]{2,}(?::\d+)?/", image)) and not re.match(
            r"^(?:ghcr\.io|docker\.io|lscr\.io|quay\.io|gcr\.io)/", image)
        repo = re.sub(r"^[a-z0-9.-]+\.[a-z]{2,}(?::\d+)?/", "", image) if internal else image
        repo = re.sub(r"[:@][^/]*$", "", repo)
        units.append({"name": name, "image": repo, "registry": "internal" if internal else "public",
                      "compose_project": proj or None, "compose_service": svc or None,
                      "watchtower_label": wt or None})
    ev, _ = ssh_ro(host, "docker events --since 720h --until 0s --format '{{.Time}}'")
    events = None
    if ev is not None:
        times = sorted(int(x) for x in ev.split() if x.isdigit())
        events = {"retained": len(times), "window_s": (times[-1] - times[0]) if times else 0}
    return {"containers": units, "containers_homelab_private_counted_not_named": private_n,
            "events_ring_buffer": events}


def probe_clickstack() -> dict:
    def q(sql):
        out, err = ssh_ro("vps", f'docker exec clickstack clickhouse-client --query "{sql} FORMAT TSV"')
        return out, err
    base = ("FROM default.otel_logs WHERE ServiceName = 'rollhook' "
            f"AND TimestampTime < toDateTime('{AS_OF_SQL}')")
    out, err = q(f"SELECT toStartOfMonth(TimestampTime) AS m, LogAttributes['deploy.status'] AS st, count() {base} GROUP BY m, st ORDER BY m, st")
    if out is None:
        return {"error": err}
    res = {"deploy_markers_by_month": {}, "by_service": {}}
    for line in out.splitlines():
        m, st, n = line.split("\t")
        res["deploy_markers_by_month"].setdefault(m[:7], {})[st] = int(n)
    out, _ = q(f"SELECT LogAttributes['deploy.service'] AS s, countIf(LogAttributes['deploy.status']='success'), countIf(LogAttributes['deploy.status']<>'success') {base} GROUP BY s ORDER BY 2 DESC")
    for line in (out or "").splitlines():
        s, ok, bad = line.split("\t")
        res["by_service"][s] = {"success": int(ok), "failed": int(bad)}
    out, _ = q(f"SELECT min(TimestampTime), max(TimestampTime) FROM default.otel_logs WHERE TimestampTime < toDateTime('{AS_OF_SQL}')")
    if out:
        lo, hi = out.strip().split("\t")
        res["table_range"] = {"first": lo, "last": hi}
    chg = fingerprint_change_utc().strftime("%Y-%m-%d %H:%M:%S")
    out, _ = q(f"SELECT min(TimestampTime), max(TimestampTime), "
               f"countIf(TimestampTime >= toDateTime('{chg}') AND LogAttributes['deploy.status']='success'), "
               f"countIf(TimestampTime >= toDateTime('{chg}') AND LogAttributes['deploy.status']<>'success') {base}")
    if out:
        lo, hi, ok, bad = out.strip().split("\t")
        res["marker_range"] = {"first": lo, "last": hi}
        res["since_fingerprint_change"] = {"change_utc": chg, "success": int(ok), "failed": int(bad)}
    res["ttl_days"] = 30    # from the table DDL, reported by the agw otel worker (TimestampTime + 30 days)
    return res


def probe_github() -> dict:
    gh = shutil.which("gh") or "/opt/homebrew/bin/gh"

    def api(path, jq):
        p = subprocess.run([gh, "api", "-H", "Accept: application/vnd.github+json", path, "--jq", jq],
                           capture_output=True, text=True, timeout=60)
        return p.stdout.strip() if p.returncode == 0 else None

    p = subprocess.run([gh, "repo", "list", "jkrumm", "--limit", "200", "--json",
                        "name,isPrivate,isArchived,isFork,pushedAt,defaultBranchRef"],
                       capture_output=True, text=True, timeout=90)
    if p.returncode != 0:
        return {"error": p.stderr.strip()[:160]}
    since = AS_OF_DT - dt.timedelta(days=90)
    rng = f"{since:%Y-%m-%dT%H:%M:%SZ}..{AS_OF_DT:%Y-%m-%dT%H:%M:%SZ}"
    repos = [r for r in json.loads(p.stdout) if not r["isArchived"] and not r["isFork"]
             and r["pushedAt"] and parse_ts(r["pushedAt"]) >= since]
    rows = []
    for r in repos:
        base = f"repos/jkrumm/{r['name']}/actions/runs?per_page=1&created={rng}"
        total = api(base, ".total_count")
        if not total or total == "0":
            continue
        failed = api(base + "&status=failure", ".total_count")
        branch = (r.get("defaultBranchRef") or {}).get("name") or "main"
        failed_push = api(base + f"&status=failure&event=push&branch={branch}", ".total_count")
        rows.append({"repo": r["name"], "private": r["isPrivate"], "runs": int(total),
                     "failed": int(failed or 0), "failed_on_default_branch_push": int(failed_push or 0)})
    rows.sort(key=lambda x: (-x["failed"], x["repo"]))
    return {"window_days": 90, "repos_pushed_in_window": len(repos), "repos_with_actions": len(rows),
            "runs": sum(r["runs"] for r in rows), "failed": sum(r["failed"] for r in rows),
            "failed_on_default_branch_push": sum(r["failed_on_default_branch_push"] for r in rows),
            "top_by_failures": rows[:10]}


def run_probes(private: set, work: set) -> dict:
    res = {"probed_at": dt.datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
           "kuma_homelab": probe_kuma(private, work), "beszel_homelab": probe_beszel(),
           "docker_homelab": probe_docker("homelab"), "docker_vps": probe_docker("vps"),
           "clickstack_vps": probe_clickstack()}
    try:
        res["github"] = probe_github()
    except (subprocess.TimeoutExpired, OSError, ValueError) as e:
        res["github"] = {"error": type(e).__name__}
    return res


# --------------------------------------------------------------------------- static knowledge (evidence named)

# Kuma http/keyword/mysql monitors -> (host the target runs on, service, project, how Kuma sees it).
# Evidence: homelab/uptime-kuma/monitors.yaml urls and comments; vps README stack table.
HTTP_TARGETS = {
    "Glance - HTTP": ("homelab", "glance", "homelab", "direct"),
    "Dozzle - HTTP": ("homelab", "dozzle", "homelab", "direct"),
    "S3 Gateway - HTTP": ("homelab", "versitygw", "homelab", "direct"),
    "Immich - HTTP": ("homelab", "immich_server", "homelab", "direct"),
    "Karakeep - HTTP": ("homelab", "karakeep", "homelab", "direct"),
    "Uptime Kuma - Uptime": ("homelab", "uptime-kuma", "homelab", "better-stack-api"),
    "Immich - Uptime": ("homelab", "immich_server", "homelab", "better-stack-api"),
    "Photos - Uptime": ("vps", "photo-gallery", "vps", "better-stack-api"),
    "Photos - HTTP": ("vps", "photo-gallery", "vps", "direct"),
    "WeatherOrb - HTTP": ("vps", "weatherorb-edge", "weatherorb", "direct"),
    "Traefik - HTTP": ("vps", "traefik", "vps", "direct"),
    "RollHook - HTTP": ("vps", "rollhook", "rollhook", "direct"),
    "RollHook - Ready - HTTP": ("vps", "rollhook", "rollhook", "direct"),
    "HyperDX - HTTP": ("vps", "clickstack", "vps", "direct"),
    "ClickStack OTel - HTTP": ("vps", "clickstack", "vps", "direct"),
    "Umami - HTTP": ("vps", "umami", "vps", "direct"),
    "ImageCDN - HTTP": ("vps", "imgproxy", "vps", "direct"),
    "ImageCDN Origin - HTTP": ("vps", "imgproxy", "vps", "direct"),
    "EmailGateway - HTTP": ("vps", "email-gateway", "email-gateway", "direct"),
    "Dashboard - HTTP": ("vps", "argo-dashboard", "argo", "direct"),
    "API - HTTP": ("vps", "argo-api", "argo", "direct"),
    "Hermes - HTTP": ("vps", "argo-api", "hermes-agent", "direct"),
    "Audio Gateway - HTTP": ("vps", "audio-gateway", "audio-gateway", "direct"),
    "Image Gen Gateway - HTTP": ("vps", "image-gateway", "image-gateway", "direct"),
    "FPP - Frontend - HTTP": ("external", "fpp-frontend", "free-planning-poker", "direct"),
    "FPP - Server - HTTP": ("vps", "fpp-server", "free-planning-poker", "direct"),
    "FPP - Analytics - HTTP": ("vps", "fpp-analytics", "free-planning-poker", "direct"),
    "FPP - DB - MySQL": ("vps", "mariadb", "free-planning-poker", "direct"),
}

# Kuma push monitors -> (host the pusher runs on, pusher, project). Evidence: monitors.yaml comments and
# dotfiles docs/architecture.md section Monitoring.
PUSH_OWNERS = {
    "HomeLab Watchdog - Push": ("homelab", "cron homelab_watchdog.sh", "homelab"),
    "Restic Backup - Push": ("homelab", "restic-backup", "homelab"),
    "Garmin Auto-Relogin - Push": ("homelab", "cron garmin-auto-relogin.sh", "homelab"),
    "Immich Backup - Push": ("homelab", "cron immich-backup-check.sh", "homelab"),
    "WeatherOrb Accounts Backup - Push": ("homelab", "cron weatherorb-accounts-pull.sh", "weatherorb"),
    "WeatherOrb Archive - Push": ("homelab", "cron weatherorb-archive-pull.sh", "weatherorb"),
    "Garmin Collector - Push": ("vps", "argo garmin-sync cron", "argo"),
    "1Password Backup - Push": ("macbook", "opbackup", "dotfiles"),
    "MacMini Secret Seed - Push": ("mini", "secrets-freshness check", "dotfiles"),
    "MacMini Dev Host - Push": ("mini", "com.jkrumm.devhost-health", "dotfiles"),
    "MacMini Collie - Push": ("mini", "collie behavioural check", "dotfiles"),
    "MacMini Drift - Push": ("mini", "com.jkrumm.drift-check", "dotfiles"),
    "Brain Sync - Push": ("mini", "com.jkrumm.brain-sync", "dotfiles"),
    "Brain Backup - Push": ("mini", "com.jkrumm.brain-backup", "dotfiles"),
    "Home Line - Push": ("mini", "com.jkrumm.linewatch-heartbeat", "linewatch"),
    "Home Line - Watchdog": ("mini", "com.jkrumm.linewatch-watchdog", "linewatch"),
    "WeatherOrb Watchdog - Push": ("mini", "com.jkrumm.weatherorb.watchdog", "weatherorb"),
    "WeatherOrb Watchdog - Degraded": ("mini", "com.jkrumm.weatherorb.watchdog", "weatherorb"),
    "Hermes Agent - Push": ("mini", "com.jkrumm.hermes-liveness", "hermes-agent"),
    "Hermes Serve - Push": ("mini", "com.jkrumm.hermes-serve-liveness", "hermes-agent"),
    "Hermes Backup - Push": ("mini", "com.jkrumm.hermes-backup", "hermes-agent"),
    "Warden Backup - Push": ("mini", "com.jkrumm.warden-backup", "warden"),
    "Warden Loop - Push": ("mini", "com.jkrumm.warden-loop", "warden"),
    "Agent Gateway - Push": ("mini", "com.jkrumm.agent-gateway", "agent-gateway"),
    "Postgres - Backup - Push": ("vps", "cron pg backup", "vps"),
    "Postgres - DB - Push": ("vps", "cron health-pg.sh", "vps"),
    "FPP - DB Backup - Push": ("vps", "cron fpp mariadb backup", "free-planning-poker"),
    "FPP - Analytics Readmodel - Push": ("vps", "fpp-analytics-updater", "free-planning-poker"),
}

# Push monitors whose subject is a container: link them to that unit (host, service).
PUSH_TARGET_UNIT = {"Postgres - DB - Push": ("vps", "postgres"), "Postgres - Backup - Push": ("vps", "postgres"),
                    "FPP - DB Backup - Push": ("vps", "mariadb"), "Restic Backup - Push": ("homelab", "restic-backup")}

# Compose project -> project (repo) on the vps. Service-level overrides below.
VPS_PROJECT = {"argo": "argo", "audio-gateway": "audio-gateway", "basalt-ui-marketing": "basalt-ui",
               "email-gateway": "email-gateway", "fpp": "free-planning-poker", "image-gateway": "image-gateway",
               "jkrumm-com": "jkrumm.com", "rollhook-marketing": "rollhook", "shutterflow": "shutterflow",
               "weatherorb": "weatherorb", "imgproxy": "vps", "photo-gallery": "vps", "vps": "vps"}
VPS_SERVICE_PROJECT = {"rollhook": "rollhook"}

# --------------------------------------------------------------------------- analysis


def analyse(rows, loop_start, probes, private, work, kuma_live_names):
    slack = [r for r in rows if r["source"] in SLACK_SOURCES]
    for r in slack:
        r["system"], r["polarity"], r["info"] = classify_slack(r["source"], r["title"])

    # ---- per warden source
    sources = {}
    for s in sorted({r["source"] for r in rows}):
        rs = [r for r in rows if r["source"] == s]
        t = tally(rs, loop_start)
        t["first_seen"] = min(r["fs"] for r in rs).strftime("%Y-%m-%d")
        t["last_seen"] = max(r["fs"] for r in rs).strftime("%Y-%m-%d")
        t["resolved_share_pct"] = pct(sum(1 for r in rs if r["resolved_at"]), len(rs))
        lag_s = [(r["item_created"] - r["fs"]).total_seconds() / 60 for r in rs
                 if r["item"] and not r["duplicate"] and r["item_created"] and r["fs"] >= loop_start]
        t["item_lag_min_after_row"] = dist([x for x in lag_s if 0 <= x <= 360])
        sources[s] = t

    # ---- per primary system (Slack only)
    systems = {}
    months_all = sorted({month_of(r["fs"]) for r in rows})
    for sysname in SYSTEM_LABEL:
        rs = [r for r in slack if r["system"] == sysname]
        if not rs:
            continue
        t = tally(rs, loop_start)
        t["label"] = SYSTEM_LABEL[sysname]
        t["by_source"] = srt(collections.Counter(r["source"] for r in rs))
        t["polarity"] = srt(collections.Counter(r["polarity"] for r in rs))
        t["months_first_seen"] = srt(collections.Counter(month_of(r["fs"]) for r in rs))
        t["months_ts_first"] = srt(collections.Counter(month_of(r["ts_first"]) for r in rs if r["ts_first"]))
        single = [(r["fs"] - r["ts_first"]).total_seconds() / 60 for r in rs
                  if r["ts_first"] and r["payload"].get("batch_count") == 1]
        t["poll_lag_min_single_message"] = dist([x for x in single if 0 <= x <= 360])
        t["rows_lag_over_6h_or_negative"] = sum(1 for x in single if x < 0 or x > 360)
        t["rows_text_cut_at_240"] = sum(1 for r in rs if len(r["payload"].get("first_text") or "") >= 240)
        spans = [(r["ts_last"] - r["ts_first"]).total_seconds() / 86400 for r in rs if r["ts_first"] and r["ts_last"]]
        t["rows_recurring_over_1h"] = sum(1 for x in spans if x > 1 / 24)
        t["max_span_days"] = round(max(spans), 1) if spans else None
        t["rows_batch_count_ge2"] = sum(1 for r in rs if (r["payload"].get("batch_count") or 1) >= 2)
        lag_i = [(r["item_created"] - r["fs"]).total_seconds() / 60 for r in rs
                 if r["item"] and not r["duplicate"] and r["item_created"] and r["fs"] >= loop_start]
        t["item_lag_min_after_row"] = dist([x for x in lag_i if 0 <= x <= 360])
        systems[sysname] = t

    # ---- Kuma specifics
    kuma = [r for r in slack if r["system"] == "uptime_kuma"]
    mons = collections.defaultdict(list)
    for r in kuma:
        mons[r["info"]["mon"]].append(r)
    down_fp = {m: {r["external_id"] for r in rs if r["polarity"] == "fault" and not r["info"]["group"]}
               for m, rs in mons.items()}
    group_rows = [r for r in kuma if r["info"]["group"]]
    stale = None
    if kuma_live_names is not None:
        live = kuma_live_names | private | work
        group_names = {m["name"] for m in probes["kuma_homelab"].get("monitors", []) if m["type"] == "group"}
        stale = sorted({n for n in mons if n not in live and n not in group_names})
    kuma_x = {
        "rows": len(kuma), "distinct_monitor_names": len(mons),
        "rows_per_monitor_mean": round(len(kuma) / len(mons), 2) if mons else None,
        "monitors_with_2plus_down_fingerprints": sum(1 for v in down_fp.values() if len(v) >= 2),
        "group_restatement_rows": len(group_rows),
        "group_restatement_months_ts_first": srt(collections.Counter(month_of(r["ts_first"]) for r in group_rows if r["ts_first"])),
        "rows_naming_monitors_not_live_today": None if stale is None else sum(len(mons[n]) for n in stale),
        "monitor_names_not_live_today": None if stale is None else len(stale),
    }
    # double intake after the webhook went live
    uk = [r for r in rows if r["source"] == "uk"]
    web = [r for r in uk if r["payload"].get("via") == "webhook"]
    era = min((r["fs"] for r in web), default=None)
    dbl = {"webhook_live_since_utc": era.strftime("%Y-%m-%dT%H:%M:%SZ") if era else None}
    if era:
        by_title = collections.defaultdict(list)
        for u in uk:
            by_title[u["title"]].append(u["fs"])
        down = [r for r in kuma if r["fs"] >= era and r["polarity"] == "fault" and not r["info"]["group"]]
        paired = sum(1 for r in down if any(abs((t - r["fs"]).total_seconds()) <= 3600
                                            for t in by_title.get(r["info"]["mon"], [])))
        esc_slack = sum(1 for r in kuma if r["fs"] >= era and r["item"] and not r["duplicate"] and r["escalated"])
        esc_uk = sum(1 for r in uk if r["fs"] >= era and r["item"] and not r["duplicate"] and r["escalated"])
        dbl.update({"slack_kuma_down_rows": len(down), "with_uk_event_same_monitor_within_60min": paired,
                    "slack_items_escalated": esc_slack, "uk_items_escalated": esc_uk,
                    "skip_rule_covers": "monitor names ending in 'Push' only (watchdog-poll.py:384)"})
    kuma_x["double_intake"] = dbl
    nohook = (probes.get("kuma_homelab") or {}).get("leaf_without_warden_webhook")
    kuma_x["leaf_monitors_without_warden_webhook"] = nohook
    bs = [r for r in slack if r["system"] == "better_stack"]

    def bs_subject(t):
        t = re.sub(r"^(?:New incident for |Automatically resolved )", "", t)
        t = re.sub(r"(?: incident)?(?: and \d+ similar incidents?)?$", "", t)
        return re.sub(r"[^a-z0-9]+", "", t.lower()).replace("ffp", "fpp")     # the monitor is named FFP once (typo)
    bs_x = {"rows": len(bs), "distinct_subjects": len({bs_subject(r["title"]) for r in bs}),
            "incident_rows_closed_by_prose_filter": sum(1 for r in bs if r["polarity"] == "fault" and ignore_kind(r) == "prose_filter"
                                                       and link_kind(r) == "ignored"),
            "incident_rows_in_loop_era": sum(1 for r in bs if r["polarity"] == "fault" and r["fs"] >= loop_start)}
    uk_x = {"rows": len(uk), "via_webhook": len(web), "via_snapshot_poll": len(uk) - len(web),
            "group_monitor_rows": sum(1 for r in uk if r["payload"].get("type") == "group")}

    # ---- deploy markers vs relay rows
    deploy = {}
    rh = [r for r in slack if r["system"] == "rollhook"]
    cs = probes.get("clickstack_vps", {})
    if cs and "deploy_markers_by_month" in cs:
        mr = cs.get("marker_range") or cs.get("table_range")
        lo = parse_ts(mr["first"].replace(" ", "T")) if mr else None
        chg = fingerprint_change_utc()
        info = [r for r in rh if r["polarity"] == "info"]
        fault = [r for r in rh if r["polarity"] == "fault"]
        prim_ok = sum(v.get("success", 0) for v in cs["deploy_markers_by_month"].values())
        prim_bad = sum(v.get("failed", 0) for v in cs["deploy_markers_by_month"].values())
        sc = cs.get("since_fingerprint_change") or {}
        pre_rows = sum(1 for r in info if r["ts_first"] and lo and lo <= r["ts_first"] < chg)
        deploy = {"window_start_utc": lo.strftime("%Y-%m-%dT%H:%M:%SZ") if lo else None,
                  "fingerprint_change_utc": chg.strftime("%Y-%m-%dT%H:%M:%SZ"),
                  "primary_markers_success": prim_ok, "primary_markers_failed": prim_bad,
                  "relay_rows_success_in_window": sum(1 for r in info if r["ts_first"] and lo and r["ts_first"] >= lo),
                  "relay_rows_failed_in_window": sum(1 for r in fault if r["ts_first"] and lo and r["ts_first"] >= lo),
                  "before_change": {"markers_success": prim_ok - sc.get("success", 0), "relay_rows": pre_rows},
                  "since_change": {"markers_success": sc.get("success"), "markers_failed": sc.get("failed"),
                                   "relay_rows_created": sum(1 for r in info if r["ts_first"] and r["ts_first"] >= chg),
                                   "relay_rows_touched": sum(1 for r in info if r["ts_last"] and r["ts_last"] >= chg)},
                  "relay_rows_ever": len(rh),
                  "relay_rows_with_sha_in_key": sum(1 for r in rh if re.search(r"[0-9a-f]{12,}", r["external_id"])),
                  "max_deploys_folded_into_one_row": max((r["payload"].get("batch_count") or 1) for r in rh) if rh else None,
                  "relay_months_ts_first": srt(collections.Counter(month_of(r["ts_first"]) for r in rh if r["ts_first"]))}
    # ---- beszel
    bz = probes.get("beszel_homelab", {})
    beszel = {}
    if bz and "history_by_month" in bz:
        lo_m = min((r["fs"] for r in slack if r["system"] == "beszel"), default=None)
        beszel = {"primary_episodes_since_relay_start": sum(v["episodes"] for m, v in bz["history_by_month"].items()
                                                            if lo_m and m >= "2026-05"),
                  "primary_episodes_total": bz["history_range"]["rows"],
                  "relay_rows": systems.get("beszel", {}).get("events"),
                  "history_resolved_share_pct": pct(sum(v["resolved"] for v in bz["history_by_month"].values()),
                                                    sum(v["episodes"] for v in bz["history_by_month"].values()))}
    # ---- kuma primary vs relay
    kp = probes.get("kuma_homelab", {})
    kuma_primary = {}
    if kp and "important_heartbeats" in kp:
        agg = collections.Counter()
        for key, n in kp["important_heartbeats"].items():
            _month, kind, status = key.split("|")
            agg[f"{kind}_{ {'0': 'down', '1': 'up', '2': 'pending'}.get(status, status)}"] += n
        kuma_primary = {"important_heartbeats": srt(agg), "important_total": sum(agg.values()),
                        "down_up_transitions_total": sum(v for k, v in agg.items() if not k.endswith("pending")),
                        "relay_rows_total": len(kuma),
                        "relay_rows_down": sum(1 for r in kuma if r["polarity"] == "fault"),
                        "relay_rows_up": sum(1 for r in kuma if r["polarity"] == "recovery")}
        o = kp.get("outage_buckets", {})
        tot = sum(o.values())
        kuma_primary["outage_duration_buckets"] = o
        kuma_primary["outages_under_5min_pct"] = pct(o.get("1:<5m", 0), tot)
        kuma_primary["outages_under_30min_pct"] = pct(o.get("1:<5m", 0) + o.get("2:5-30m", 0), tot)

    # ---- monthly volumes per source (ledger view)
    monthly_sources = {s: srt(collections.Counter(month_of(r["fs"]) for r in rows if r["source"] == s))
                       for s in sorted({r["source"] for r in rows})}
    # ---- recovery share over Slack rows
    pol = collections.Counter(r["polarity"] for r in slack)
    state_rows = pol["fault"] + pol["recovery"]
    recovery = {"slack_rows": len(slack), "by_polarity": srt(pol),
                "recovery_share_of_all_slack_rows_pct": pct(pol["recovery"], len(slack)),
                "recovery_share_of_fault_plus_recovery_pct": pct(pol["recovery"], state_rows),
                "non_signal_rows_chat_test_pct": pct(pol["chat"] + pol["test"], len(slack)),
                "success_notice_rows_pct": pct(pol["info"], len(slack)),
                "by_system_recovery_pct": {k: pct(v["polarity"].get("recovery", 0),
                                                  v["polarity"].get("recovery", 0) + v["polarity"].get("fault", 0))
                                           for k, v in systems.items()
                                           if v["polarity"].get("recovery", 0) + v["polarity"].get("fault", 0)},
                }
    # payload structure kept by the relay
    keys = collections.Counter(k for r in slack for k in r["payload"])
    lag_all = [(r["fs"] - r["ts_first"]).total_seconds() / 60 for r in slack
               if r["ts_first"] and r["payload"].get("batch_count") == 1]
    return {"sources": sources, "systems": systems, "kuma_relay": kuma_x, "uk_source": uk_x, "better_stack_relay": bs_x,
            "poll_lag_all_slack_rows": dist([x for x in lag_all if 0 <= x <= 360]),
            "deploy_relay_vs_primary": deploy,
            "beszel_relay_vs_primary": beszel, "kuma_relay_vs_primary": kuma_primary, "monthly_by_source": monthly_sources,
            "months": months_all, "recovery": recovery, "payload_keys_kept": srt(keys), "slack_rows": slack,
            "kuma_monitor_rows": {m: len(rs) for m, rs in mons.items()}}


# --------------------------------------------------------------------------- source map (static knowledge + numbers)


DIRECT_FLAG = {  # primary -> (direct_available: y | pull | n | n/a, status)
    "Uptime Kuma": ("y", "live"), "Better Stack": ("pull", "API poll only; the push cannot reach the tailnet door"),
    "Beszel hub": ("y", "config only"), "HomeLab WatchDog": ("n", "none today"), "HyperDX alerts": ("y", "live"),
    "homelab-private stack": ("n", "none today"), "RollHook": ("y", "config only; OTLP markers already live"),
    "Watchtower": ("y", "other form: Docker events and image digests"), "Hermes gateway chat": ("n/a", "not a signal"),
    "tests and canaries": ("n/a", "not a signal"), "Docker daemon": ("y", "event stream, unrecorded"),
    "GitHub": ("pull", "gh api; webhooks cannot reach the tailnet")}


def build_source_map(a, probes):
    """primary system -> relay -> warden source -> rows -> what is lost -> direct path -> recommended intake.
    Qualitative columns are static knowledge, each backed by the evidence named in `evidence`; numbers are computed."""
    sy = a["systems"]
    n = lambda k: sy.get(k, {}).get("events", 0)          # noqa: E731
    kp = probes.get("kuma_homelab", {})
    notif = kp.get("notifications", {})
    leaves = sum(1 for m in kp.get("monitors", []) if m["type"] != "group") if kp.get("monitors") else None
    gh = probes.get("github", {})
    dr = a["deploy_relay_vs_primary"]
    sc = dr.get("since_change", {})
    nohook = [x.get("name") for x in (kp.get("leaf_without_warden_webhook") or [])]
    src = a["sources"]
    rows = [
        {"primary": "Uptime Kuma", "host": "homelab (one instance; probes homelab and vps, receives pushes from mini, cron, MacBook)",
         "relay": "Slack - Alerts webhook, #alerts", "relay_short": "Slack webhook", "warden_source": "slack_alert", "rows": n("uptime_kuma"),
         "lost": "monitor id, type, tags (route_by_label reads a repo tag; Kuma holds 0 tags today), url, heartbeat time, retries, duration; group parents restate children; Down and Up are different fingerprints; identity breaks on a rename",
         "lost_short": "id, type, tags, url, times; groups echo children; Down/Up split",
         "direct": "yes, live", "direct_short": "y, live: webhook -> /ingest/kuma (uk)",
         "how": f"notification 'Warden - Ingest' -> POST /ingest/kuma -> source uk; attached to {notif.get('Warden - Ingest')} of {leaves} leaf monitors, Slack on {notif.get('Slack - Alerts')}; live since {a['kuma_relay']['double_intake'].get('webhook_live_since_utc')}",
         "gap": f"no redelivery while warden is down; the Slack copy of non-Push monitors is still ingested (double intake); leaf without the webhook: {', '.join(str(x) for x in nohook) or 'none'}",
         "recommended": "make uk the only Kuma intake: attach the webhook to the DB monitor, skip every Kuma-shaped #alerts line, and let the webhook only wake a level reconcile of Kuma state per monitor id (Prometheus /metrics with an API key, or the heartbeat table)",
         "recommended_short": "webhook wakes a state reconcile; drop Kuma lines from Slack intake",
         "evidence": "homelab/uptime-kuma/monitors.yaml settings; warden docs/api.md Ingest door; watchdog-poll.py:384"},
        {"primary": "Better Stack", "host": "SaaS (external vantage)",
         "relay": "Slack integration, #alerts", "relay_short": "Slack integration", "warden_source": "slack_alert", "rows": n("better_stack"),
         "lost": "incident id, cause, start and resolve times; incidents do not start with a bracket or glyph, so the prose filter can close them",
         "lost_short": "incident id, cause, times; prose filter closes them",
         "direct": "pull only", "direct_short": "pull: API (SaaS cannot reach the door)",
         "how": "outgoing webhooks (incident created, acknowledged, resolved, reopened) cannot reach the tailnet-only door; API poll possible; 3 Kuma monitors already poll it with a bearer key",
         "gap": "every subject is also probed by Kuma, so the same outage reaches warden through uk",
         "recommended": "drop from intake (Kuma carries the external verdict); keep Slack as the human mirror",
         "recommended_short": f"drop; Kuma probes all {a['better_stack_relay']['distinct_subjects']} subjects", "evidence": "monitors.yaml (- Uptime monitors); Better Stack docs (webhooks)"},
        {"primary": "Beszel hub", "host": "homelab (agents on homelab, vps, mini)",
         "relay": "Shoutrrr Slack URL, #alerts", "relay_short": "Shoutrrr Slack", "warden_source": "slack_alert", "rows": n("beszel"),
         "lost": "value, start and resolve time, system id; above and below are separate fingerprints; recurrences collapse",
         "lost_short": "value, times; recurrences collapse",
         "direct": "yes, config only", "direct_short": "y, config: generic webhook or alerts_history",
         "how": "Shoutrrr generic webhook (generic://host?template=json) to the ingest door, or read alerts_history (alert_id, created, resolved, system, value, name)",
         "gap": "no ingest route for it",
         "recommended": "reconcile on alerts_history (open = resolved empty); the webhook only wakes it",
         "recommended_short": "reconcile alerts_history", "evidence": "Beszel docs (notifications); live alerts_history schema"},
        {"primary": "HomeLab WatchDog", "host": "homelab (cron, every 10 min)",
         "relay": "Slack webhook, Block Kit", "relay_short": "Slack Block Kit", "warden_source": "slack_alert", "rows": n("homelab_watchdog"),
         "lost": "blocks flattened to one line, several notifications fused, cut at 240 characters; escalation level stays on the host",
         "lost_short": "blocks flattened, cut at 240",
         "direct": "no", "direct_short": "n: notify() could POST to the door",
         "how": "only liveness reaches warden (Kuma push); notify() could POST structured JSON to the ingest door (the homelab tag may reach it)",
         "gap": "escalation level and state files stay on the host",
         "recommended": "POST the structured event next to Slack; low volume",
         "recommended_short": "structured POST; low volume", "evidence": "homelab/scripts/homelab_watchdog.sh notify/flush; docs/watchdog-behaviors.md"},
        {"primary": "HyperDX alerts", "host": "vps (ClickStack; 21 alerts-as-code)",
         "relay": "Slack #alerts webhook", "relay_short": "Slack webhook", "warden_source": "slack_alert (before 2026-10-17)", "rows": n("hyperdx"),
         "lost": "value, time range, alert url, service; an ALERT and OK glyph flip inside one batch leaves no trace",
         "lost_short": "value, range, url, service",
         "direct": "yes, live", "direct_short": "y, live: webhook -> /ingest/hyperdx",
         "how": "webhook 'Warden ingest' on all 21 alerts -> POST /ingest/hyperdx -> source hyperdx; the poll skips glyph-prefixed lines",
         "gap": "alert state is not reconciled; weatherorb's own alerts use a separate path",
         "recommended": "keep the webhook; add a reconcile of alert state (REST v2 /alerts)",
         "recommended_short": "keep; reconcile alert state", "evidence": "vps observability/README.md; docs/observability.md"},
        {"primary": "homelab-private stack", "host": "homelab (apps and scripts; names withheld)",
         "relay": "Slack webhook via its notify helper", "relay_short": "Slack webhook", "warden_source": "slack_alert", "rows": n("homelab_private"),
         "lost": "structure, severity, which script or app; recoveries use a different sentence",
         "lost_short": "structure, severity, origin",
         "direct": "no", "direct_short": "n: POST to the door or push monitor",
         "how": "same POST-to-door option; some Kuma push monitors already carry its liveness",
         "gap": "no structured channel", "recommended": "POST structured events or push monitors with a DOWN reason; low volume",
         "recommended_short": "structured POST; low volume", "evidence": "homelab-private (names withheld)"},
        {"primary": "RollHook", "host": "vps (deployer)",
         "relay": "SLACK_WEBHOOK_URL, #updates", "relay_short": "Slack webhook", "warden_source": "slack_update (never ingested)", "rows": n("rollhook"),
         "lost": f"job id, duration, error; since the 2026-10-04 fingerprint change one row per app folds every deploy ({sc.get('relay_rows_touched')} rows for {sc.get('markers_success')} deploys)",
         "lost_short": "job id, duration, error; deploys folded per app",
         "direct": "yes, config only (+ markers live)", "direct_short": "y, config: job webhook; OTLP markers live",
         "how": "NOTIFICATION_WEBHOOK_URL posts the full job JSON; OTLP deploy markers already land in ClickStack (service rollhook, 30-day TTL); GET /jobs (bearer)",
         "gap": "no ingest route; nothing reads slack_update",
         "recommended": "webhook -> a deploy event (deployment frequency, change failure); stop polling #updates",
         "recommended_short": "webhook -> deploy event (DORA)", "evidence": "rollhook README Notifications; ClickStack probe"},
        {"primary": "Watchtower", "host": "homelab and vps (04:00 sweep)",
         "relay": "Shoutrrr Slack URL, #updates, level warn", "relay_short": "Shoutrrr Slack", "warden_source": "slack_update (never ingested)", "rows": n("watchtower"),
         "lost": "which image changed, which container",
         "lost_short": "image and container",
         "direct": "yes, other form", "direct_short": "y, other: Docker events and digests",
         "how": "Docker events (image pull, create, start, die, oom, health_status) or image digests; HTTP API is trigger-only, /v1/metrics needs API mode and a token",
         "gap": "daemon keeps only a 256-event ring: a stream consumer must record it",
         "recommended": "Docker state and events as the level source; ignore Watchtower text",
         "recommended_short": "ignore; use Docker state", "evidence": "Watchtower docs; docker events probe"},
        {"primary": "Hermes gateway chat", "host": "mini (replies in #alerts and #updates)",
         "relay": "Slack messages", "relay_short": "Slack messages", "warden_source": "slack_alert, slack_update", "rows": n("hermes_chat"),
         "lost": "not a signal", "lost_short": "not a signal",
         "direct": "n/a", "direct_short": "n/a", "how": "none needed", "gap": "polled as if it were a signal",
         "recommended": "stop reading prose; the policy already closes it as ignored", "recommended_short": "stop reading prose",
         "evidence": "loop/intake.py:878 classify"},
        {"primary": "tests and canaries", "host": "-", "relay": "Slack", "relay_short": "Slack", "warden_source": "slack_alert", "rows": n("test_canary"),
         "lost": "n/a", "lost_short": "-", "direct": "n/a", "direct_short": "n/a", "how": "n/a", "gap": "-",
         "recommended": "none", "recommended_short": "none", "evidence": "-"},
        {"primary": "Docker daemon", "host": "homelab, vps",
         "relay": "none (Argo /docker summary poll, 30 min)", "relay_short": "Argo summary poll", "warden_source": "docker_homelab, docker_vps",
         "rows": sum(src.get(x, {}).get("events", 0) for x in ("docker_homelab", "docker_vps")),
         "lost": "only unhealthy and restart-loop lists every 30 minutes; no history",
         "lost_short": "history; 30-min summary",
         "direct": "yes", "direct_short": "y: events stream (nothing records it)",
         "how": f"docker events stream; the daemon's ring (~256 events) covers {window_bucket((probes.get('docker_vps', {}).get('events_ring_buffer') or {}).get('window_s'))} on the vps and {window_bucket((probes.get('docker_homelab', {}).get('events_ring_buffer') or {}).get('window_s'))} on the homelab",
         "gap": "nothing records the stream", "recommended": "stream consumer with a recorder; container state as the level source",
         "recommended_short": "stream consumer + recorder", "evidence": "watchdog-poll.py:235; docker events probe"},
        {"primary": "GitHub", "host": "SaaS",
         "relay": "none (gh search in poll and loop)", "relay_short": "gh poll", "warden_source": "github_go, github_pr, github_issue",
         "rows": sum(src.get(x, {}).get("events", 0) for x in ("github_go", "github_pr", "github_issue")),
         "lost": "Actions results are not a source at all", "lost_short": "Actions are no source",
         "direct": "pull only", "direct_short": "pull: gh api",
         "how": f"gh api works non-interactively; webhooks cannot reach the tailnet; {gh.get('failed')} failed Actions runs in 90 days across {gh.get('repos_with_actions')} repos, {gh.get('failed_on_default_branch_push')} on a default-branch push",
         "gap": "CI failures reach nobody unless a PR gate sees them",
         "recommended": "poll runs per repo with conditional requests, or a failure step on the self-hosted runners posting to the door",
         "recommended_short": "poll runs (ETag) or runner step", "evidence": "gh probe; loop/intake.py:169"},
    ]
    for r in rows:
        r["direct_available"], r["direct_status"] = DIRECT_FLAG[r["primary"]]
    return rows


# --------------------------------------------------------------------------- topology


EDGES = [  # cross-host relations a correlation window needs; each names its evidence
    {"from": "homelab:uptime-kuma", "to": "vps:*", "kind": "probes over http (outside-in)",
     "evidence": "monitors.yaml VPS group; architecture.md Monitoring (ACL homelab -> vps)"},
    {"from": "mini:*", "to": "homelab:uptime-kuma", "kind": "push monitors (no inbound path to the mini)",
     "evidence": "architecture.md Monitoring"},
    {"from": "vps:cron and fpp-analytics-updater", "to": "homelab:uptime-kuma", "kind": "push monitors", "evidence": "monitors.yaml comments"},
    {"from": "homelab:cron", "to": "vps and mini", "kind": "pulls weatherorb dumps and archive, then pushes to Kuma",
     "evidence": "monitors.yaml WeatherOrb Accounts Backup and Archive comments"},
    {"from": "vps:clickstack", "to": "mini:research-gateway", "kind": "OTel alerts read the vps ClickStack while the service runs on the mini",
     "evidence": "architecture.md Repos (research-gateway mini-only); observability/alerts"},
    {"from": "vps:weatherorb-edge", "to": "mini:weatherorb", "kind": "edge proxies tiles from the mini", "evidence": "monitors.yaml WeatherOrb - HTTP comment"},
    {"from": "vps:argo-api", "to": "mini:hermes", "kind": "Hermes health route and chat", "evidence": "monitors.yaml Hermes - HTTP comment"},
    {"from": "mini:warden", "to": "vps:argo-api", "kind": "polls Slack and docker summaries through Argo", "evidence": "watchdog-poll.py API_BASE"},
    {"from": "vps:email-gateway", "to": "homelab:proton-bridge", "kind": "mail through the homelab Bridge", "evidence": "architecture.md Repos (email-gateway)"},
    {"from": "vps:rollhook", "to": "vps:apps", "kind": "deploys every RollHook-managed container; Watchtower updates the rest at 04:00 on both hosts",
     "evidence": "vps README stack table"},
    {"from": "homelab:beszel hub", "to": "vps and mini agents", "kind": "system metrics (push from the mini)", "evidence": "architecture.md Monitoring"},
]


def build_topology(a, probes, private, work, public_yaml, alerts, policy, launch, projects, rows):
    kp = probes.get("kuma_homelab", {})
    mons = kp.get("monitors", []) or []
    deploys = (probes.get("clickstack_vps", {}).get("by_service") or {})
    by_name = {m["name"]: m for m in mons if m.get("name")}

    def group_chain(m):
        chain, cur = [], m
        while cur and cur.get("parent"):
            chain.append(cur["parent"])
            cur = by_name.get(cur["parent"])
        return chain

    # ---- units (host -> container or launchd job -> service -> project)
    units = []
    hl_private = (probes.get("docker_homelab", {}) or {}).get("containers_homelab_private_counted_not_named", 0)
    for host, key in (("vps", "docker_vps"), ("homelab", "docker_homelab")):
        for c in (probes.get(key, {}) or {}).get("containers", []) or []:
            svc = c["compose_service"] or c["name"]
            proj = c["compose_project"]
            project = (VPS_SERVICE_PROJECT.get(svc) or VPS_PROJECT.get(proj, "vps")) if host == "vps" else "homelab"
            if host == "vps":
                if svc in deploys or c["registry"] == "internal":
                    deploy = "rollhook"
                elif c["watchtower_label"] == "false":
                    deploy = "compose or pinned (watchtower off)"
                else:
                    deploy = "watchtower (04:00)"
            else:
                deploy = "pinned (watchtower off)" if c["watchtower_label"] == "false" else "watchtower (04:00)"
            units.append({"host": host, "runtime": "container", "compose_project": proj, "service": svc,
                          "container": c["name"] if host == "homelab" else re.sub(r"-\d+$", "-*", c["name"]),
                          "image": c["image"], "project": project, "deploy": deploy, "kuma_monitors": [],
                          "deploy_markers_in_retained_window": (deploys.get(svc) or {}).get("success")})
    if hl_private:
        units.append({"host": "homelab", "runtime": "container-group", "compose_project": "homelab-private",
                      "service": f"{hl_private} containers (names withheld)", "container": None, "project": "homelab-private",
                      "deploy": "see homelab-private", "kuma_monitors": []})
    iu = 0
    for m in launch:
        if m["owner"].startswith("IuRoot") or m["label"].startswith("com.iu."):
            iu += 1
            continue
        units.append({"host": "mini", "runtime": "launchd", "label": m["label"], "service": m["label"], "container": None,
                      "project": m["owner"], "schedule": m["schedule"], "kuma_monitors": []})
    if iu:
        units.append({"host": "mini", "runtime": "launchd-group", "service": f"{iu} launchd jobs (names withheld)",
                      "container": None, "project": "IuRoot", "kuma_monitors": []})

    # ---- Kuma monitors -> targets
    idx = {}
    for u in units:
        if u["runtime"] == "container":
            idx.setdefault((u["host"], u["service"]), u)
            if u["host"] == "homelab":
                idx.setdefault(("homelab-container", u["container"]), u)
        elif u["runtime"] == "launchd":
            idx.setdefault(("mini", u["label"]), u)
    mon_rows, unmapped, orphans = [], [], []
    for m in mons:
        if m["class"] != "public":
            mon_rows.append({"id": m["id"], "name": None, "type": m["type"], "class": m["class"]})
            continue
        row = {"id": m["id"], "name": m["name"], "type": m["type"], "group_chain": group_chain(m), "class": "public",
               "interval_s": m.get("interval"), "maxretries": m.get("maxretries")}
        tgt = u = None
        if m["type"] == "group":
            row["role"] = "dashboard tree only; never notifies"
        elif m["type"] == "docker":
            u = idx.get(("homelab-container", m["docker_container"]))
            row["via"] = "docker socket"
            if u:
                tgt = ("homelab", u["service"], u["project"])
            else:
                orphans.append(m["name"])
                row["orphan"] = "no such container on the host"
        elif m["name"] in HTTP_TARGETS:
            h, svc, proj, via = HTTP_TARGETS[m["name"]]
            tgt, row["via"] = (h, svc, proj), via
            u = idx.get((h, svc))
        elif m["name"] in PUSH_OWNERS:
            h, pusher, proj = PUSH_OWNERS[m["name"]]
            tgt, row["via"], row["pusher"] = (h, pusher, proj), "push", pusher
            u = idx.get(PUSH_TARGET_UNIT.get(m["name"], (h, pusher))) or idx.get(("homelab", pusher))
        if tgt:
            row["host"], row["service"], row["project"] = tgt
        elif m["type"] != "group" and not row.get("orphan"):
            unmapped.append(m["name"])
        if u:
            u["kuma_monitors"].append(m["name"])
        mon_rows.append(row)

    # ---- per-project roll-up
    zero = {"kuma_leaf_monitors": 0, "hyperdx_alerts": 0, "containers": 0, "launchd_jobs": 0,
            "deploy_markers_in_retained_window": 0, "warden_items": 0, "slack_rows_attributed": 0}
    proj = {p: dict(zero) for p in projects}

    def bump(p, k, n=1):
        proj.setdefault(p, dict(zero))[k] += n
    for r in mon_rows:
        if r.get("project") and r.get("type") != "group":
            bump(r["project"], "kuma_leaf_monitors")
    bump("homelab-private", "kuma_leaf_monitors", sum(1 for m in mons if m["class"] == "homelab-private" and m["type"] != "group"))
    bump("homelab-private", "containers", hl_private)
    for al in alerts:
        if al["project"]:
            bump(al["project"], "hyperdx_alerts")
    for u in units:
        if u["runtime"] == "container":
            bump(u["project"], "containers")
            if u.get("deploy_markers_in_retained_window"):
                bump(u["project"], "deploy_markers_in_retained_window", u["deploy_markers_in_retained_window"])
        elif u["runtime"] == "launchd":
            bump(u["project"], "launchd_jobs")
    for p_, c in collections.Counter(r["repo"] for r in rows if r["item"] and not r["duplicate"] and r["repo"]).items():
        bump(p_, "warden_items", c)

    # ---- signal -> project attribution by topology alone (Slack rows)
    live = {m["name"]: m for m in mon_rows if m.get("name")}
    attrib = collections.defaultdict(collections.Counter)
    for r in a["slack_rows"]:
        sysn, key, pj = r["system"], None, None
        if sysn == "uptime_kuma":
            mon = r["info"]["mon"]
            if mon in private:
                pj = "homelab-private"
            elif mon in work:
                pj = "IuRoot"
            elif mon in live:
                pj = live[mon].get("project")
                key = "group_only" if live[mon]["type"] == "group" else None
            key = key or ("attributed" if pj else "unattributed")
        elif sysn == "hyperdx":
            pj = hyperdx_project(r["title"])
            key = "attributed" if pj else "unattributed"
        elif sysn == "rollhook":
            pj = rollhook_project(r["info"].get("app", ""))
            key = "attributed" if pj else "unattributed"
        elif sysn == "homelab_private":
            pj, key = "homelab-private", "attributed"
        elif sysn in ("beszel", "homelab_watchdog", "watchtower"):
            key = "host_only"
        elif sysn == "better_stack":
            key = "unattributed"
        else:
            key = "not_a_signal"
        attrib[sysn][key] += 1
        if key == "attributed" and pj:
            bump(pj, "slack_rows_attributed")

    # ---- coverage
    docker_targets = {m["docker_container"] for m in mons if m["type"] == "docker" and m["class"] == "public"}
    hl_units = [u for u in units if u["host"] == "homelab" and u["runtime"] == "container"]
    vps_units = [u for u in units if u["host"] == "vps" and u["runtime"] == "container"]
    leaves = [m for m in mon_rows if m.get("class") == "public" and m["type"] != "group"]
    mapped = [m for m in leaves if m.get("project")]
    by_host = collections.Counter(m.get("host", "unmapped") for m in leaves)
    items = [r for r in rows if r["item"] and not r["duplicate"]]
    known = set(projects) | {"homelab-private"}
    alert_rows = {k: v for k, v in attrib.items() if k in ("uptime_kuma", "better_stack", "beszel", "homelab_watchdog", "hyperdx", "homelab_private")}
    coverage = {
        "kuma_monitors_live_total": kp.get("monitor_total"),
        "kuma_public_leaf_monitors": len(leaves),
        "kuma_public_leaf_mapped_to_host_service_project": len(mapped),
        "kuma_public_leaf_unmapped": sorted(unmapped),
        "kuma_docker_monitors_without_a_running_container": sorted(orphans),
        "kuma_public_leaf_monitors_by_target_host": srt(by_host),
        "kuma_homelab_private_monitors_counted_not_named": kp.get("private_monitors"),
        "kuma_work_monitors_counted_not_named": kp.get("work_monitors"),
        "kuma_public_yaml_declared": len(public_yaml),
        "hyperdx_alerts": len(alerts), "hyperdx_alerts_mapped_to_project": sum(1 for x in alerts if x["project"]),
        "homelab_public_containers": len(hl_units), "homelab_private_containers_counted_not_named": hl_private,
        "homelab_public_containers_without_docker_monitor": sorted(u["container"] for u in hl_units if u["container"] not in docker_targets),
        "vps_containers": len(vps_units),
        "vps_containers_with_a_kuma_monitor_or_push": sum(1 for u in vps_units if u["kuma_monitors"]),
        "vps_container_services_without_kuma": sorted(u["service"] for u in vps_units if not u["kuma_monitors"]),
        "mini_launchd_jobs_mapped": sum(1 for u in units if u["runtime"] == "launchd"),
        "mini_launchd_jobs_with_kuma_push": sum(1 for u in units if u["runtime"] == "launchd" and u["kuma_monitors"]),
        "iuroot_launchd_jobs_counted_not_named": iu,
        "policy_rules": policy["rules_total"],
        "policy_rule_repos_not_in_sourceroot": sorted(r for r in policy["rules_by_repo"] if r and r not in known),
        "item_repos_not_in_sourceroot": sorted({r["repo"] for r in items if r["repo"]} - known),
        "items_total": len(items), "items_without_repo": sum(1 for r in items if r["repo"] is None),
        "slack_row_attribution_by_topology": {k: srt(v) for k, v in sorted(attrib.items())},
        "slack_alert_signal_rows": sum(sum(v.values()) for v in alert_rows.values()),
        "slack_alert_signal_rows_attributed_to_project": sum(v.get("attributed", 0) for v in alert_rows.values()),
        "slack_alert_signal_rows_host_only": sum(v.get("host_only", 0) + v.get("group_only", 0) for v in alert_rows.values()),
    }
    ncont = lambda h: sum(1 for u in units if u["host"] == h and u["runtime"] == "container")    # noqa: E731
    hosts = {
        "homelab": {"role": "own hardware, remote; docker compose (projects homelab, homelab-private)",
                    "units": ncont("homelab"), "units_withheld": hl_private,
                    "kuma": "the one Uptime Kuma instance (docker socket, outbound probes, inbound pushes)", "beszel": "hub",
                    "updates": "Watchtower 04:00", "reaches_ingest_door": True,
                    "evidence": "docker ps probe; homelab AGENTS.md; architecture.md Monitoring"},
        "vps": {"role": "cloud VPS; docker compose (networking, infra, monitoring, apps/*); RollHook deploys; ClickStack and HyperDX",
                "units": ncont("vps"), "kuma": "none (probed from the homelab; its crons push)", "beszel": "agent",
                "updates": "RollHook for apps, Watchtower 04:00 for the rest", "reaches_ingest_door": True,
                "evidence": "docker ps probe; vps README"},
        "mini": {"role": "always-on dev host; launchd (warden, agent-gateway, hermes, gateways, weatherorb, dotfiles jobs)",
                 "units": sum(1 for u in units if u["runtime"] == "launchd"), "units_withheld": iu,
                 "kuma": "none (push only; the ACL grants nothing inbound from the homelab)", "beszel": "agent (push)",
                 "updates": "own deploy paths (warden deploys itself; research-gateway deploy poller)",
                 "reaches_ingest_door": "hosts it: warden-api, /ingest/* only", "evidence": "architecture.md LaunchAgents and Doors"},
        "macbook": {"role": "client; a few launchd jobs (opbackup pushes to Kuma)", "kuma": "push only", "evidence": "architecture.md"},
        "external": {"role": "SaaS: Better Stack (external monitors), Vercel (FPP frontend), GitHub", "kuma": "probed or polled",
                     "evidence": "monitors.yaml"},
    }
    return {"hosts": hosts, "units": units, "kuma_monitors": mon_rows, "hyperdx_alerts": alerts, "edges": EDGES,
            "projects": {k: proj[k] for k in sorted(proj)}, "routing": {"policy": policy}, "coverage": coverage}


# --------------------------------------------------------------------------- markdown


def tbl(headers, rows):
    out = ["| " + " | ".join(headers) + " |", "|" + "-|" * len(headers)]
    out += ["| " + " | ".join(str(c) for c in r) + " |" for r in rows]
    return "\n".join(out)


def fmt(n):
    return f"{n:,}" if isinstance(n, int) else str(n)


def names(xs):
    return ", ".join(xs) if xs else "none"


def window_bucket(seconds) -> str:
    """Docker's event ring is live and volatile; reports use a coarse bucket so a re-run diffs cleanly."""
    if seconds is None:
        return "unknown"
    return "under 1 min" if seconds < 60 else ("1 to 3 min" if seconds < 180 else "over 3 min")


def render_md(out, a, probes, topo):
    sy, so = a["systems"], a["sources"]
    total, sl = out["slack_share"]["events_total"], out["slack_share"]["slack_events"]
    rec, kx, ku = a["recovery"], a["kuma_relay"], a["kuma_relay_vs_primary"]
    dbl, dr, bz, bs = kx["double_intake"], a["deploy_relay_vs_primary"], a["beszel_relay_vs_primary"], a["better_stack_relay"]
    kp, gh, cov = probes.get("kuma_homelab", {}), probes.get("github", {}), topo["coverage"]
    sc, burst, cof = dr.get("since_change", {}), kp.get("burst", {}), kp.get("cofire_5m", {})
    kl, lag = sy["uptime_kuma"], a["poll_lag_all_slack_rows"]
    L = []
    L.append("# Signals - what sits behind warden's Slack relays")
    L.append("")
    L.append(f"AS_OF {AS_OF}. Frozen `warden.db` plus read-only probes (ssh homelab/vps, gh); `signals.py` writes `signals.out.json` and `topology.out.json`. "
             "A row is a warden `events` row (one per text fingerprint), not a Slack message.")
    L.append("")
    L.append(f"**Headline.** {fmt(sl)} of {fmt(total)} events ({pct(sl, total)} %) came through Slack: slack_alert {so['slack_alert']['events']}, "
             f"slack_update {so['slack_update']['events']} (the brief's 1,112 of 1,752 predates nine rows).")
    L.append(f"- **Nothing consumes slack_update:** {so['slack_update']['events']} rows = {sy['rollhook']['events']} RollHook deploy notices, "
             f"{sy['watchtower']['events']} Watchtower, {sy['hermes_chat']['by_source'].get('slack_update', 0)} chat; `INGEST_SOURCES` excludes it, 0 became items.")
    L.append(f"- **slack_alert is mostly Kuma** ({kl['events']} of {so['slack_alert']['events']}; chat {sy['hermes_chat']['by_source'].get('slack_alert', 0)}, "
             f"Better Stack {sy['better_stack']['events']}, homelab-private {sy['homelab_private']['events']}, HyperDX {sy['hyperdx']['events']}, "
             f"Beszel {sy['beszel']['events']}, WatchDog {sy['homelab_watchdog']['events']}). {so['slack_alert']['items']} rows became items, "
             f"{so['slack_alert']['escalated_items']} of those reached the owner, none reached `fixed` ({so['slack_alert']['worked_outcomes'].get('quiet', 0)} went quiet).")
    L.append(f"- **Kuma and HyperDX already push to warden (webhooks live since {dbl.get('webhook_live_since_utc', '')[:10]}), but Kuma's Slack copy is still ingested:** "
             f"{dbl.get('with_uk_event_same_monitor_within_60min')} of {dbl.get('slack_kuma_down_rows')} Kuma Down rows since then duplicate a `uk` event; "
             f"escalations in that era: {dbl.get('slack_items_escalated')} via Slack, {dbl.get('uk_items_escalated')} via the webhook.")
    L.append("")
    L.append("## Source map")
    L.append("")
    r1 = []
    for r in out["source_map"]:
        if r["primary"] == "tests and canaries":
            continue
        r1.append([f"{r['primary']} ({r['host'].split(' (')[0]})", f"{r['relay_short']} -> {r['warden_source']}", fmt(r["rows"]),
                   r["lost_short"], r["direct_short"], r["recommended_short"]])
    L.append(tbl(["primary (host)", "relay -> warden source", "rows", "lost in the relay", "direct path", "recommended intake"], r1))
    L.append("")
    L.append("Rule for every row: the push is a wake-up, the level (current state per entity) is read from the source.")
    L.append("")
    L.append("## What happened to the rows (columns 3-7: events since the first loop item, 2026-09-08)")
    L.append("")
    r2 = []

    def fate(label, t, recov):
        lk = t["link_loop_era"]
        return [label, t["events"], t["loop_era_events"], lk.get("worked", 0) + lk.get("ignored", 0), lk.get("duplicate", 0),
                lk.get("ignored", 0), lk.get("no_item", 0), t["escalated_items"], recov]
    for k in ("uptime_kuma", "better_stack", "homelab_private", "hyperdx", "beszel", "homelab_watchdog", "rollhook"):
        t, pol = sy[k], sy[k]["polarity"]
        fr = pol.get("fault", 0) + pol.get("recovery", 0)
        rc = "n/a (update notices)" if k == "rollhook" else (f"{pol.get('recovery', 0)} ({pct(pol.get('recovery', 0), fr)} %)" if fr else "-")
        r2.append(fate(SYSTEM_LABEL[k].split(" (")[0], t, rc))
    for s_ in ("uk", "hyperdx"):
        r2.append(fate(f"{s_} (direct)", so[s_], f"{so[s_]['resolved_share_pct']} % resolved"))
    L.append(tbl(["class", "rows", "loop-era rows", "item", "attached", "ignored", "no item", "escalated (all time)", "recoveries (of fault+recovery)"], r2))
    L.append("")
    ib = so["slack_alert"]["ignored_by"]
    L.append(f"`item` = non-duplicate item rows (ignored included); `attached` = duplicate_of set. slack_alert ignores: policy list {ib.get('policy_ignore_list', 0)}, "
             f"prose filter {ib.get('prose_filter', 0)}, hand or model {ib.get('closed_by_hand', 0) + ib.get('model_or_other', 0)}. All {sy['hermes_chat']['events']} chat rows predate the loop; "
             f"{bs['incident_rows_closed_by_prose_filter']} of {bs['incident_rows_in_loop_era']} Better Stack incident rows died in the prose filter (no bracket, no glyph).")
    L.append("")
    L.append("## What the relay loses (measured)")
    L.append("")
    L.append(f"- **Structure.** Argo's mapper keeps ts, user-or-bot id, text, thread, reactions, files but drops username, app id, attachments and blocks (`argo/apps/api/src/clients/slack.ts:191`); warden keeps only `text` and `ts` "
             f"(`watchdog-poll.py:369-392`), discarding even the bot id, so the poster is a guess from text shape and {sum(v.get('rows_text_cut_at_240', 0) for v in sy.values())} rows are cut at 240 characters. "
             f"Routing suffers: items without a repo are {so['slack_alert']['items_without_repo']} of {so['slack_alert']['items']} for slack_alert and {so['uk']['items_without_repo']} of {so['uk']['items']} for `uk` (Kuma holds {(kp.get('tags') or {}).get('monitor_tag_links', '?')} tags, so the repo label that `route_by_label` reads does not exist; github_go, human, job: 0).")
    L.append(f"- **Fingerprints.** Identity is the text minus numbers and ids (`watchdog-poll.py:795`). Recurrence collapses: Beszel {bz.get('primary_episodes_since_relay_start')} episodes since May -> {bz.get('relay_rows')} rows; "
             f"Kuma {fmt(ku.get('down_up_transitions_total'))} transitions -> {ku.get('relay_rows_total')} rows ({kx['group_restatement_rows']} group echoes). Changing error text splits one outage "
             f"({kx['monitors_with_2plus_down_fingerprints']} of {kx['distinct_monitor_names']} Kuma names have 2+ Down fingerprints); a rename orphans rows ({kx['rows_naming_monitors_not_live_today']} name monitors that no longer exist). "
             f"RollHook since {dr.get('fingerprint_change_utc', '')[:10]}: {sc.get('relay_rows_touched')} per-app rows for {fmt(sc.get('markers_success'))} deploys (before: {dr['before_change']['relay_rows']} rows for {dr['before_change']['markers_success']}).")
    L.append(f"- **Recovery events.** {rec['by_polarity'].get('recovery', 0)} of {fmt(rec['slack_rows'])} rows ({rec['recovery_share_of_all_slack_rows_pct']} %) are recoveries, {rec['by_polarity'].get('info', 0)} ({rec['success_notice_rows_pct']} %) update notices, "
             f"{rec['by_polarity'].get('chat', 0) + rec['by_polarity'].get('test', 0)} ({rec['non_signal_rows_chat_test_pct']} %) chat or tests; of fault plus recovery rows {rec['recovery_share_of_fault_plus_recovery_pct']} % are recoveries (Kuma {rec['by_system_recovery_pct'].get('uptime_kuma')} %). "
             f"A recovery is its own row keyed by its own text, so a Kuma Up never closes its Down; only a glyph flip normalises to one key, and inside one batch it leaves no trace (`intake.py:735`). The policy ignores Kuma Up lines ({'yes' if rec.get('policy_ignores_kuma_up_lines') else 'no'}) and Better Stack resolved lines ({'yes' if rec.get('policy_ignores_better_stack_resolved_lines') else 'no'}).")
    L.append(f"- **Timing.** Only the Slack ts survives: poll lag median {lag['median']} min, p90 {lag['p90']} (single-message rows), the loop adds median {kl['item_lag_min_after_row']['median']} min; a webhook (`uk`) row becomes an item after median {so['uk']['item_lag_min_after_row']['median']} min (n {so['uk']['item_lag_min_after_row']['n']}). "
             f"{ku.get('outages_under_5min_pct')} % of Kuma outages end within 5 minutes and {ku.get('outages_under_30min_pct')} % within 30, shorter than one poll, so a relay sees Down and Up in one batch or misses the Down. "
             f"`first_seen` is the last re-arm ({sum(v.get('rows_lag_over_6h_or_negative', 0) for v in sy.values())} rows lag over 6 h).")
    L.append(f"- **Volume cap.** The poll takes the newest 50 messages and passes no `oldest` or cursor although Argo offers both plus `has_more` (`watchdog-poll.py:363`). Kuma's busiest half hour ({burst.get('top_windows', [{}])[0].get('window_utc')} UTC, the homelab reboot) held "
             f"{burst.get('win_all', {}).get('max_per_30min')} heartbeats ({burst.get('win_leaf', {}).get('max_per_30min')} leaf): the only window over 50 of {burst.get('win_all', {}).get('windows')}. "
             f"{cof.get('transitions_in_those_buckets')} of {cof.get('leaf_down_transitions')} leaf DOWNs sit in {cof.get('buckets_with_3plus_monitors')} five-minute buckets where 3+ monitors failed together: the correlation target.")
    L.append(f"- **Double intake.** The skip rule matches `[... Push]` names only (`watchdog-poll.py:384`), so Docker and HTTP monitor lines still open `slack_alert` items beside the webhook's `uk` events. "
             f"One leaf has no webhook, {names([x.get('name') for x in (kx.get('leaf_monitors_without_warden_webhook') or [])])} (sync.py skips existing DB monitors): for it Slack is the only path.")
    L.append("")
    L.append("## Monthly volumes (ledger first_seen month; recurring rows re-arm, so older months undercount; ts-based months are in the JSON)")
    L.append("")
    months = a["months"]
    r3 = []
    for k in ("uptime_kuma", "hermes_chat", "better_stack", "homelab_private", "hyperdx", "beszel", "homelab_watchdog", "rollhook"):
        r3.append([SYSTEM_LABEL[k].split(" (")[0]] + [sy[k]["months_first_seen"].get(m, 0) for m in months] + [sy[k]["events"]])
    for s_ in ("uk", "hyperdx"):
        r3.append([f"{s_} (direct)"] + [a["monthly_by_source"][s_].get(m, 0) for m in months] + [so[s_]["events"]])
    rest, rest_names = collections.Counter(), []
    for s_ in sorted(so, key=lambda x: -so[x]["events"]):
        if s_ not in SLACK_SOURCES and s_ not in ("uk", "hyperdx"):
            rest.update(a["monthly_by_source"][s_])
            rest_names.append(f"{s_} {so[s_]['events']}")
    r3.append(["other direct sources"] + [rest.get(m, 0) for m in months] + [sum(rest.values())])
    L.append(tbl(["class"] + [m[5:] for m in months] + ["total"], r3))
    L.append("")
    L.append(f"Not in the table: Watchtower {sy['watchtower']['events']}, tests {sy['test_canary']['events']}. Other direct sources: " + ", ".join(rest_names) + ".")
    L.append("")
    L.append("## Direct paths, probed read-only")
    L.append("")
    de_v, de_h = probes.get("docker_vps", {}).get("events_ring_buffer") or {}, probes.get("docker_homelab", {}).get("events_ring_buffer") or {}
    L.append(f"- **Kuma:** one instance, on the homelab (the vps runs none): {kp.get('monitor_total')} monitors ({', '.join(f'{k} {v}' for k, v in (kp.get('by_type') or {}).items())}), "
             f"Slack on {kp.get('notifications', {}).get('Slack - Alerts')} leaves, `Warden - Ingest` on {kp.get('notifications', {}).get('Warden - Ingest')}, groups notify nobody; the door answers the homelab and vps tags only. "
             f"`/metrics` answers {kp.get('metrics_endpoint_http_status_without_credentials')} without a key and {kp.get('api_keys')} API keys exist (`monitor_status` per monitor), so a level read is possible.")
    L.append(f"- **Deploys, metrics, events:** RollHook left {fmt(dr.get('primary_markers_success'))} OTLP deploy markers ok and {dr.get('primary_markers_failed')} failed in ClickStack since {dr.get('window_start_utc', '')[:10]} (30-day TTL) against {dr.get('relay_rows_success_in_window')} and {dr.get('relay_rows_failed_in_window')} Slack rows; "
             f"its job webhook is one env var away. Beszel `alerts_history`: {bz.get('primary_episodes_total')} rows, {bz.get('history_resolved_share_pct')} % resolved, value kept. "
             f"Docker's event ring (~256 events) is {window_bucket(de_v.get('window_s'))} of healthcheck noise on the vps and {window_bucket(de_h.get('window_s'))} on the homelab, so history needs a live consumer. Watchtower: HTTP API is trigger-only, `/v1/metrics` needs API mode and a token, level `warn`.")
    L.append(f"- **GitHub:** `gh api` works non-interactively; {gh.get('failed')} failed Actions runs in 90 days over {gh.get('repos_with_actions')} repos ({gh.get('failed_on_default_branch_push')} on a default-branch push); no warden source reads Actions. "
             "**Not probed:** Better Stack API, HyperDX alert history, RollHook `/jobs`, Slack itself.")
    L.append("")
    L.append("## Topology (draft; `topology.out.json` holds every unit, monitor, alert, edge and project roll-up)")
    L.append("")
    h = topo["hosts"]
    bh = cov["kuma_public_leaf_monitors_by_target_host"]
    L.append(tbl(["host", "units (host -> container or job -> service -> project)", "Kuma leaf monitors aimed at it", "updates", "alerts"],
                 [["homelab", f"{h['homelab']['units']} containers + {h['homelab']['units_withheld']} homelab-private (counted)", bh.get("homelab", 0), h["homelab"]["updates"], "Beszel hub"],
                  ["vps", f"{h['vps']['units']} containers", bh.get("vps", 0), h["vps"]["updates"], f"{cov['hyperdx_alerts']} HyperDX alerts (also for the mini's research-gateway)"],
                  ["mini", f"{h['mini']['units']} launchd jobs + {h['mini']['units_withheld']} IuRoot (counted)", bh.get("mini", 0), "own deploy paths", "push monitors only"],
                  ["macbook, external", "1 push; SaaS: Better Stack, Vercel, GitHub", f"{bh.get('macbook', 0)}, {bh.get('external', 0)}", "-", "-"]]))
    L.append("")
    L.append(f"- Mapped to host, service and project: {cov['kuma_public_leaf_mapped_to_host_service_project']} of {cov['kuma_public_leaf_monitors']} public Kuma leaf monitors, {cov['hyperdx_alerts_mapped_to_project']} of {cov['hyperdx_alerts']} alerts, all {cov['vps_containers']} vps and {cov['homelab_public_containers']} homelab containers; 11 cross-host edges are listed. "
             f"Blind spots: homelab containers without a Docker monitor ({names(cov['homelab_public_containers_without_docker_monitor'])}); {len(cov['vps_container_services_without_kuma'])} of {cov['vps_containers']} vps services have no Kuma monitor or push.")
    L.append(f"- Routing today: {cov['policy_rules']} policy rules; {cov['items_without_repo']} of {cov['items_total']} items carry no repo; repo names not in SourceRoot: {names(cov['item_repos_not_in_sourceroot'])}. "
             f"Topology alone attributes {cov['slack_alert_signal_rows_attributed_to_project']} of {cov['slack_alert_signal_rows']} slack_alert signal rows to a project and {cov['slack_alert_signal_rows_host_only']} to a host (Kuma groups, Beszel, WatchDog); the rest name stale monitors or Better Stack subjects.")
    L.append("")
    L.append("## Limits")
    L.append("")
    L.append("Rows are fingerprints, not messages: the Slack API was not called and the ledger cannot give true message counts. The system per row is inferred from text shape; chat is the residual class. "
             "Container lists are live at probe time; Kuma, Beszel and ClickStack aggregates are append-only reads below AS_OF. homelab-private and IuRoot items are counted, never named.")
    return "\n".join(L) + "\n"


# --------------------------------------------------------------------------- main


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--no-probe", action="store_true", help="reuse probes from the previous signals.out.json")
    args = ap.parse_args(argv)

    private, work = load_private_names()
    db = sqlite3.connect(f"file:{WARDEN_DB}?mode=ro", uri=True)
    rows = load_events(db)
    loop_start = min(r["item_created"] for r in rows if r["item_created"])

    if args.no_probe and OUT_JSON.exists():
        probes = json.loads(OUT_JSON.read_text()).get("probes", {})
    else:
        probes = run_probes(private, work)
    kuma_live = None
    if probes.get("kuma_homelab", {}).get("monitors"):
        kuma_live = {m["name"] for m in probes["kuma_homelab"]["monitors"] if m.get("name")}

    a = analyse(rows, loop_start, probes, private, work, kuma_live)
    public_yaml = load_public_kuma_yaml()
    alerts = load_hyperdx_alerts()
    policy = load_policy()
    a["recovery"]["policy_ignores_kuma_up_lines"] = policy["ignores_kuma_up_lines"]
    a["recovery"]["policy_ignores_better_stack_resolved_lines"] = policy["ignores_better_stack_resolved_lines"]
    launch = load_mini_launchagents()
    projects = project_universe()
    topo = build_topology(a, probes, private, work, public_yaml, alerts, policy, launch, projects, rows)

    total = len(rows)
    sl = sum(1 for r in rows if r["source"] in SLACK_SOURCES)
    intake_paths = {
        "slack_alert": "poll every 1800 s: Argo /slack/channels/<id>/messages?limit=50 (newest 50, text and ts only) -> fingerprint -> upsert_grouped; loop pass every 600 s opens items (watchdog-poll.py:352-392, 805-918; loop/intake.py:23)",
        "slack_update": "same poll on #updates; recorded, never ingested (loop/core.py:60 INGEST_SOURCES, :86)",
        "uk": "webhook POST /ingest/kuma (bearer, tailnet door) since 2026-10-16; before: 1800 s snapshot poll (lifecycle/ingest.py:75)",
        "hyperdx": "webhook POST /ingest/hyperdx since 2026-10-17 (lifecycle/ingest.py:118)",
        "docker_homelab": "poll every 1800 s: Argo /docker/<host>/summary alerts block (watchdog-poll.py:235)",
        "docker_vps": "same, vps",
        "github_go": "loop pass every 600 s: GitHub issue search per owner (loop/intake.py:169)",
        "github_pr": "poll every 1800 s: gh search prs, open and stale > 3 days (watchdog-poll.py:286)",
        "github_issue": "retired stale-issue digest (watchdog-poll.py:286 docstring)",
        "human": "warden run CLI and Argo owner actions, on demand",
        "hermes_log": "poll every 1800 s: tail of Hermes error logs with offsets (watchdog-poll.py:395)",
        "hermes_cron": "poll of the Hermes cron registry (reconcile retired)",
        "job": "loop pass every 600 s: local jobs-grade read (loop/intake.py:236)",
        "op_refs_homelab": "poll every 1800 s: ssh op run probe (watchdog-poll.py:472)",
        "op_refs_vps": "same, vps",
        "stray_skill": "poll every 1800 s: filesystem scan (watchdog-poll.py:576)",
        "warden_self": "internal escalation notes",
        "warden_canary": "internal canary items",
    }
    for s, t in a["sources"].items():
        t["intake_path"] = intake_paths.get(s)
    out = {
        "meta": {"script": "evidence/signals/signals.py", "as_of": AS_OF, "definition_keys": ["item", "escalated"],
                 "warden_snapshot": "~/.local/share/factory/snapshots/" + AS_OF[:10] + "/warden.db",
                 "loop_era_starts_utc": loop_start.strftime("%Y-%m-%dT%H:%M:%SZ"),
                 "repo_heads": {r: git_head(r) for r in ("warden", "homelab", "vps", "argo", "dotfiles", "rollhook")},
                 "limits": ["rows are distinct fingerprints, not Slack messages", "system per row inferred from text shape",
                            "first_seen is the last re-arm of a row", "container lists are live at probe time",
                            "homelab-private and IuRoot items are counted, never named"]},
        "slack_share": {"events_total": total, "slack_events": sl, "share_pct": pct(sl, total),
                        "brief_baseline": {"slack": 1112, "total": 1752, "share_pct": pct(1112, 1752)}},
        "sources": a["sources"], "systems": {k: v for k, v in a["systems"].items()},
        "kuma_relay": a["kuma_relay"], "uk_source": a["uk_source"], "better_stack_relay": a["better_stack_relay"],
        "poll_lag_all_slack_rows_min": a["poll_lag_all_slack_rows"],
        "kuma_relay_vs_primary": a["kuma_relay_vs_primary"], "beszel_relay_vs_primary": a["beszel_relay_vs_primary"],
        "deploy_relay_vs_primary": a["deploy_relay_vs_primary"], "recovery": a["recovery"],
        "monthly_by_source": a["monthly_by_source"], "payload_keys_kept": a["payload_keys_kept"],
        "relay_facts": {
            "slack_api_fields_forwarded_by_argo": ["ts", "user_or_bot_id", "text", "type", "thread_ts", "reply_count", "reactions", "files", "edited"],
            "slack_fields_not_forwarded": ["username", "app_id", "bot_profile", "attachments", "blocks", "subtype"],
            "warden_keeps": ["text (first 240 chars, newlines to spaces)", "ts"],
            "forwarded_by_argo_but_discarded_by_warden": ["user_or_bot_id", "thread_ts", "reactions", "files", "edited", "has_more", "next_cursor"],
            "argo_messages_route_offers": ["limit (max 100)", "oldest", "latest", "cursor"],
            "poll_interval_s": 1800, "loop_interval_s": 600, "fetch_limit": 50, "pagination": "none",
            "flap_threshold": 3, "grouped_ttl_days": 7,
            "fingerprint_change": "2026-10-04 (commit 98d7798): hex ids, numbers, paths stripped",
            "poll_skips": "names ending in Push, and glyph-prefixed HyperDX lines (watchdog-poll.py:384)"},
        "probes": probes,
    }
    out["source_map"] = build_source_map(a, probes)
    md = render_md(out, a, probes, topo)
    topo_out = {"meta": {"as_of": AS_OF, "script": "evidence/signals/signals.py",
                         "note": "units are live at probe time; Kuma, HyperDX and policy read from repos at the recorded heads; homelab-private and IuRoot are counted, never named",
                         "probed_at": probes.get("probed_at")}, **topo}
    OUT_JSON.write_text(json.dumps(scrub(out), indent=1, sort_keys=True, ensure_ascii=False) + "\n")
    OUT_TOPO.write_text(json.dumps(scrub(topo_out), indent=1, sort_keys=True, ensure_ascii=False) + "\n")
    OUT_MD.write_text(redact(md))
    print(f"wrote {OUT_JSON.name}, {OUT_TOPO.name}, {OUT_MD.name}; md lines: {md.count(chr(10))}")


if __name__ == "__main__":
    main()
