#!/usr/bin/env python3
"""Toil accounting: what the owner and the agents repeat by hand, how often, and which of it
should become a reconciler, a recurring job, a CLI verb, a policy line or a Renovate-style tool.

Question (factory design, Phase 1, SRE toil accounting):
  what do the owner and the agents repeat by hand, how often, and what should be automated?

Definition keys from ../DEFINITIONS.md implemented here: `item` (duplicates are occurrences, not
items), `escalated`, `owner_touch`, `resolved` (warden section). The other sections have no
baseline key; their own definitions are in toil.out.json -> meta.definitions.

Inputs (all read-only; no raw command line, prompt or ask text is ever written):
  1. owner shell history: this host (~/.zsh_history) and the IU MacBook (`ssh iumac cat
     ~/.zsh_history`, held in memory only). Each entry is normalised by cmdnorm.normalize() to
     `command + subcommand` patterns; only aggregates (counts, 2-4-grams) are kept.
  2. agent Bash calls: Claude Code transcripts ~/.claude/projects/**/*.jsonl, last 30 days by
     entry timestamp (< AS_OF), streamed by scan_transcripts.py.
  3. warden items: frozen snapshot warden.db (items, transitions, dispatches, operations).
  4. human-queue asks: frozen snapshot human-queue/ (*.req / *.res).

How to run (from this directory; ~15 s for the 30-day transcript scan on 12 cores):
  python3 -I toil.py
Environment: AS_OF (default 2026-10-22T08:00:00Z), FACTORY_SNAPSHOTS, TOIL_WORKERS (default 8),
  TOIL_IUMAC_WAIT_S (retry the ssh read for this many seconds when the laptop is asleep, default 0),
  TOIL_REFRESH_HISTORY=1|mini|iumac (re-read the shell histories instead of the frozen aggregates),
  TOIL_IUMAC_HISTORY_FILE / TOIL_OUT_DIR / TOIL_MAX_FILES (tests and smoke runs only).
The two history aggregates (history-<src>.agg.json: normalised patterns and counts, no raw lines) are
frozen on the first successful read, like the SQLite snapshots, because zsh history is a rolling file
without timestamps; the IU MacBook is read over ssh and may be offline.
Outputs: toil.out.json (every number the report cites) and toil.md (the human tables).
Free text goes through ../lib/redact.py:redact(); IuRoot repos appear by name only.
"""

import collections
import datetime as dt
import glob
import json
import os
import re
import sqlite3
import statistics
import subprocess
import sys
import time

sys.dont_write_bytecode = True   # keep the evidence directory free of __pycache__
HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.environ.get("TOIL_OUT_DIR", HERE)   # tests only; real runs write next to the script
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "lib"))
from redact import redact  # noqa: E402
import cmdnorm  # noqa: E402
import scan_transcripts as scan  # noqa: E402

AS_OF = os.environ.get("AS_OF", "2026-10-22T08:00:00Z")
AS_OF_DT = dt.datetime.fromisoformat(AS_OF.replace("Z", "+00:00"))
WINDOW_DAYS = 30
SNAP_ROOT = os.environ.get("FACTORY_SNAPSHOTS", os.path.expanduser("~/.local/share/factory/snapshots"))
SNAP = os.path.join(SNAP_ROOT, AS_OF[:10])
WORKERS = int(os.environ.get("TOIL_WORKERS", "8"))

# --- assumptions (every one is repeated in toil.out.json -> meta.assumptions) -----------------
ASSUMPTIONS = {
    "month_days": 30,
    "owner_history_window_days": 30,
    "owner_history_window_basis": (
        "zsh history here carries no per-line timestamps; the window is assumed to be ~30 days. "
        "Cross-check: injected agent launches in the retained history are of the same order as the "
        "agent sessions the transcripts show for 30 days (see owner_history.<src>.window_check)."
    ),
    "owner_typing_seconds": "4 + len(raw command) / 5  (typing at ~5 chars/s plus 4 s of context switch)",
    "owner_min_per_human_queue_ask": 3.0,
    "owner_min_per_warden_escalation": 6.0,
    "agent_blocked_turn_s": "measured: seconds from a blocked call to the agent's next call (capped 600 s)",
    "agent_retry_cycle_s": "measured: seconds from a failed call to its re-run (capped 900 s)",
    "owner_ask_minutes_basis": (
        "~1 min to read the macOS dialog, click Run and give Touch ID, plus ~2 min of lost focus; "
        "a failed ask is paid again as a retry ask. ran_at is stamped when the dialog is shown, so "
        "the real click latency is not recorded"
    ),
    "escalation_minutes_basis": "read the card or Argo item, decide, answer",
}
OWNER_ASK_MIN = ASSUMPTIONS["owner_min_per_human_queue_ask"]
OWNER_ESC_MIN = ASSUMPTIONS["owner_min_per_warden_escalation"]

IU_NAMES = scan.IU_NAMES


def r1(x):
    return None if x is None else round(x, 1)


def r2(x):
    return None if x is None else round(x, 2)


def scrub(obj):
    """Run every free-text string through redact() (keys are code-controlled and left alone)."""
    if isinstance(obj, str):
        return redact(obj)
    if isinstance(obj, list):
        return [scrub(x) for x in obj]
    if isinstance(obj, dict):
        return {k: scrub(v) for k, v in obj.items()}
    return obj


def log(msg):
    print(f"[toil] {msg}", file=sys.stderr)


# =========================================================================== 1. owner history


def _unmeta(b):
    out = bytearray()
    i = 0
    while i < len(b):
        if b[i] == 0x83 and i + 1 < len(b):
            out.append(b[i + 1] ^ 0x20)
            i += 2
        else:
            out.append(b[i])
            i += 1
    return bytes(out)


def history_entries(raw):
    txt = _unmeta(raw).decode("utf-8", "replace")
    out, cur = [], []
    for ln in txt.split("\n"):
        m = re.match(r"^: \d+:\d+;(.*)$", ln)
        if m and not cur:
            ln = m.group(1)
        if ln.endswith("\\") and (len(ln) - len(ln.rstrip("\\"))) % 2 == 1:
            cur.append(ln[:-1])
            continue
        cur.append(ln)
        out.append("\n".join(cur))
        cur = []
    if cur:
        out.append("\n".join(cur))
    return [re.sub(r"\x1b?\[20[01]~", "", e) for e in out if e.strip()]


def read_history(source):
    if source == "mini":
        try:
            with open(os.path.expanduser("~/.zsh_history"), "rb") as fh:
                return fh.read(), None
        except OSError as e:
            return None, f"unreadable: {e.__class__.__name__}"
    override = os.environ.get("TOIL_IUMAC_HISTORY_FILE")
    if override:
        with open(override, "rb") as fh:
            return fh.read(), None
    wait = int(os.environ.get("TOIL_IUMAC_WAIT_S", "0"))
    deadline = time.time() + wait
    err = "ssh not attempted"
    while True:
        try:
            p = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "iumac", "cat ~/.zsh_history"],
                               capture_output=True, timeout=90)
            if p.returncode == 0 and p.stdout:
                return p.stdout, None
            err = f"ssh exit {p.returncode}"
        except (OSError, subprocess.TimeoutExpired) as e:
            err = f"ssh failed: {e.__class__.__name__}"
        if time.time() >= deadline:
            return None, err + (f" (retried for {wait} s)" if wait else "")
        time.sleep(15)


def iumac_transcript_count():
    try:
        p = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "iumac",
                            "cd ~/.claude/projects 2>/dev/null && find . -maxdepth 2 -name '*.jsonl' -mtime -30 | wc -l"],
                           capture_output=True, timeout=90)
        return int(p.stdout.strip() or 0) if p.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired, ValueError):
        return None


def ngram_counts(seq, ns=(2, 3, 4), min_count=3):
    c = collections.Counter()
    for n in ns:
        for i in range(len(seq) - n + 1):
            g = tuple(seq[i:i + n])
            if len(set(g)) == 1 or all(cmdnorm.head_of(p) in cmdnorm.NAV for p in g) or "<other-cmd>" in g:
                continue
            c[g] += 1
    return {g: n for g, n in c.items() if n >= min_count}


def maximal_counts(c):
    kept = {}
    for g, n in sorted(c.items(), key=lambda kv: (-len(kv[0]), -kv[1], kv[0])):
        if any(len(h) > len(g) and n2 >= 0.8 * n and any(h[i:i + len(g)] == g for i in range(len(h) - len(g) + 1))
               for h, n2 in kept.items()):
            continue
        kept[g] = n
    return kept


LAUNCHERS = ("c", "cs", "cf", "ca", "cdf", "cdp", "cap", "cx", "cxa", "oc", "claude --resume", "claude")
INJECTED = (
    (lambda e: e.startswith("export USAGE_LANE="), "rd lane export (injected by rd/herdr)"),
    (lambda e: "--dangerously-skip-permissions" in e and "claude" in e and "--bg" not in e,
     "claude launch (typed into the pane by herdr agent start)"),
    (lambda e: re.search(r"\bclaude\b.*--bg\b", e) is not None, "claude --bg launch (spawned by an agent)"),
)
CACHE_FMT = "history-{src}.agg.json"


def analyse_history(entries, mask):
    """Aggregates only: pattern counts, typing-time estimate, 2-4-gram counts, launcher/reset adjacency."""
    occ, ent, secs = collections.Counter(), collections.Counter(), collections.defaultdict(float)
    injected = collections.Counter()
    glue = collections.Counter()
    seq = []
    manual = 0
    for e in entries:
        hit = next((label for fn, label in INJECTED if fn(e)), None)
        if hit:
            injected[hit] += 1
            continue
        ps = [p for p, _ in cmdnorm.normalize(e, mask=mask)]
        work = [p for p in ps if not cmdnorm.is_glue(p)]
        for p in ps:
            if cmdnorm.is_glue(p):
                glue[p] += 1
        if not work:
            continue
        manual += 1
        share = (4.0 + len(e) / 5.0) / len(work)
        for p in work:
            occ[p] += 1
            secs[p] += share
        for p in set(work):
            ent[p] += 1
        for p in work:
            if not seq or seq[-1] != p:
                seq.append(p)
    pairs = collections.Counter()
    for i in range(len(seq) - 1):
        if seq[i] in LAUNCHERS and seq[i + 1] == "reset":
            pairs["launcher_then_reset"] += 1
        if seq[i] == "reset" and seq[i + 1] in LAUNCHERS:
            pairs["reset_then_launcher"] += 1
    ng = {" > ".join(g): n for g, n in ngram_counts(seq, min_count=2).items()}
    return {"entries": len(entries), "manual_entries": manual, "injected": dict(sorted(injected.items())),
            "glue": dict(glue.most_common(12)),
            "occ": dict(sorted(occ.items())), "ent": dict(sorted(ent.items())),
            "secs": {k: round(v, 1) for k, v in sorted(secs.items())},
            "ngrams": dict(sorted(ng.items())), "pairs": dict(sorted(pairs.items()))}


def load_history_agg(src, mask):
    """Frozen aggregate (like the SQLite snapshots): first successful read writes it, later runs reuse it."""
    cache = os.path.join(OUT_DIR, CACHE_FMT.format(src=src))
    refresh = os.environ.get("TOIL_REFRESH_HISTORY", "") in ("1", src)
    override = src == "iumac" and os.environ.get("TOIL_IUMAC_HISTORY_FILE")
    if os.path.exists(cache) and not refresh and not override:
        with open(cache, encoding="utf-8") as fh:
            a = json.load(fh)
        a["_status"] = f"frozen aggregate read {a.get('read_at', '?')[:16]}Z"
        return a
    raw, err = read_history(src)
    if raw is None:
        return {"_status": err}
    entries = history_entries(raw)
    a = analyse_history(entries, mask)
    a = {"source": src, "read_at": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
         "history_bytes": len(raw), "note": "aggregates of normalised patterns only; no raw command line is stored",
         "transcript_files_30d": iumac_transcript_count() if src == "iumac" and not override else None, **a}
    if override:
        a["_status"] = "read from TOIL_IUMAC_HISTORY_FILE (test override, not frozen)"
        return a
    with open(cache, "w", encoding="utf-8") as fh:
        json.dump(scrub(a), fh, indent=1, ensure_ascii=False)
        fh.write("\n")
    a["_status"] = "read live and frozen now"
    return a


def owner_history_section(agent_sessions_30d):
    parsed, out_sources = {}, {}
    wd = ASSUMPTIONS["owner_history_window_days"]
    for src, mask in (("mini", False), ("iumac", True)):
        a = load_history_agg(src, mask)
        if "occ" not in a:
            out_sources[src] = {"status": a["_status"]}
            continue
        parsed[src] = a
        log(f"history {src}: {a['entries']} entries ({a['_status']})")
    for src, a in parsed.items():
        occ, ent, secs = a["occ"], a["ent"], a["secs"]
        total_occ = sum(occ.values())
        launches = sum(a["injected"].get(l, 0) for l in a["injected"] if l.startswith("claude launch"))
        launchers_typed = sum(occ.get(x, 0) for x in LAUNCHERS)
        sess30 = agent_sessions_30d if src == "mini" else a.get("transcript_files_30d")
        check = {"injected_claude_launch_lines": launches, "typed_launcher_commands": launchers_typed,
                 "agent_sessions_in_transcripts_30d": sess30,
                 "implied_window_days_upper_bound": r1(wd * (launches + launchers_typed) / sess30) if sess30 else None}
        top = []
        for p, n in sorted(occ.items(), key=lambda kv: (-kv[1], kv[0]))[:40]:
            top.append({"pattern": p, "kind": cmdnorm.classify(p), "count": n, "entries": ent.get(p, 0),
                        "share_of_manual_commands": r2(n / total_occ) if total_occ else None,
                        "est_typing_s_total": int(round(secs.get(p, 0)))})
        ng = {tuple(k.split(" > ")): n for k, n in a["ngrams"].items() if n >= 3}
        ng = maximal_counts(ng)
        out_sources[src] = {
            "status": "ok (" + a["_status"] + ")", "entries": a["entries"], "manual_entries": a["manual_entries"],
            "injected_entries": a["injected"], "glue_segments": dict(list(a["glue"].items())[:8]),
            "distinct_manual_patterns": len(occ), "window_days_assumed": wd, "window_check": check,
            "top_patterns": top,
            "ngrams": [{"sequence": list(g), "count": n} for g, n in
                       sorted(ng.items(), key=lambda kv: (-kv[1], -len(kv[0]), kv[0]))[:15]],
            "launcher_reset_pairs": a["pairs"],
        }
    comb, comb_secs, per_src = collections.Counter(), collections.defaultdict(float), collections.defaultdict(dict)
    for src, a in parsed.items():
        for p, n in a["occ"].items():
            comb[p] += n
            comb_secs[p] += a["secs"].get(p, 0)
            per_src[p][src] = n
    total = sum(comb.values())
    top = []
    for p, n in sorted(comb.items(), key=lambda kv: (-kv[1], kv[0]))[:40]:
        top.append({"pattern": p, "kind": cmdnorm.classify(p), "mini": per_src[p].get("mini", 0),
                    "iumac": per_src[p].get("iumac", 0), "count": n,
                    "share_of_manual_commands": r2(n / total) if total else None,
                    "per_month_est": r1(n * ASSUMPTIONS["month_days"] / wd),
                    "est_typing_min_per_month": r1(comb_secs[p] / 60.0 * ASSUMPTIONS["month_days"] / wd)})
    ngc = collections.Counter()
    for a in parsed.values():
        for k, n in a["ngrams"].items():
            ngc[tuple(k.split(" > "))] += n
    ng = maximal_counts({g: n for g, n in ngc.items() if n >= 3})
    pairs = collections.Counter()
    for a in parsed.values():
        pairs.update(a["pairs"])
    return {
        "sources": out_sources, "manual_commands_total": total,
        "injected_total": sum(sum(a["injected"].values()) for a in parsed.values()),
        "combined_top_patterns": top,
        "combined_ngrams": [{"sequence": list(g), "count": n} for g, n in
                            sorted(ng.items(), key=lambda kv: (-kv[1], -len(kv[0]), kv[0]))[:20]],
        "launcher_reset_pairs": dict(sorted(pairs.items())),
    }


# =========================================================================== 2. agent Bash calls


def pat_record(p, e):
    walls = e["walls"]
    long_ms = [w for w in walls if w >= scan.LONG_CALL_MS]
    lanes = e["lanes"]
    top_lane, top_n = (lanes.most_common(1)[0] if lanes else (None, 0))
    return {
        "pattern": p, "kind": cmdnorm.classify(p), "calls": e["calls"], "sessions": len(e["sessions"]),
        "top_lane": top_lane, "top_lane_share": r2(top_n / e["calls"]) if e["calls"] else None,
        "primary_calls": e["primary"], "failed": e["fail"], "benign_nonzero": e["benign"], "blocked": e["blocked"],
        "fail_pct": r1(100.0 * e["fail"] / e["primary"]) if e["primary"] else None,
        "wall_h": r1(sum(walls) / 3.6e6),
        "p50_s": r1(scan.pct(walls, 0.5) / 1000.0) if walls else None,
        "p90_s": r1(scan.pct(walls, 0.9) / 1000.0) if walls else None,
        "calls_over_120s": len(long_ms), "wall_h_over_120s": r1(sum(long_ms) / 3.6e6),
        "top_repos": [r for r, _ in e["repos"].most_common(3)],
    }


def agent_section(agg):
    pats = agg["pat"]
    recs = {p: pat_record(p, e) for p, e in pats.items()}
    by_calls = sorted(recs.values(), key=lambda r: (-r["calls"], r["pattern"]))
    action = [r for r in by_calls if not cmdnorm.is_noise(r["pattern"])]
    by_sessions = sorted([r for r in by_calls if not cmdnorm.is_noise(r["pattern"])], key=lambda r: (-r["sessions"], -r["calls"], r["pattern"]))
    by_wall = sorted(by_calls, key=lambda r: (-(r["wall_h"] or 0), r["pattern"]))
    recurring = [r for r in by_calls if r["sessions"] >= scan.MIN_SESSIONS]
    total_calls = agg["calls"]
    rec_calls_cover = sum(1 for _ in recurring)

    # recipes
    rc, runs = scan.recipes(agg["streams"])
    mx = scan.drop_rotations(scan.maximal(rc))
    spans = scan.recipe_spans(list(mx), runs)

    def recipe_rec(g, s, o):
        sp = spans.get(g, [])
        secs = [x for x, _ in sp]
        calls = [c for _, c in sp]
        return {"sequence": list(g), "length": len(g), "sessions": s, "occurrences": o,
                "median_calls_spanned": scan.pct(calls, 0.5) if calls else None,
                "occurrences_over_several_calls": sum(1 for c in calls if c >= 2),
                "median_span_s": r1(scan.pct(secs, 0.5)) if secs else None,
                "total_span_h": r1(sum(secs) / 3600.0) if secs else None}

    ranked = sorted(mx.items(), key=lambda kv: (-kv[1][0] * (len(kv[0]) - 1), -kv[1][0], kv[0]))
    recipes = [recipe_rec(g, s, o) for g, (s, o) in ranked[:20]]
    multi = [recipe_rec(g, s, o) for g, (s, o) in ranked
             if (scan.pct([c for _, c in spans.get(g, [])], 0.5) or 1) >= 2][:12]
    n_frequent = len(rc)

    # per repo
    repos = []
    for repo, r in sorted(agg["repo"].items(), key=lambda kv: (-kv[1]["calls"], kv[0]))[:14]:
        rec = {"repo": repo, "calls": r["calls"], "sessions": len(r["sessions"]), "iu_repo": bool(r["iu"])}
        if r["iu"]:
            rec["top_tools"] = [{"tool": h, "calls": n} for h, n in r["heads"].most_common(6)]
        else:
            rec["top_patterns"] = [{"pattern": p, "calls": n} for p, n in
                                   sorted(((p, n) for p, n in r["pat"].items() if not cmdnorm.is_noise(p)),
                                          key=lambda kv: (-kv[1], kv[0]))[:6]]
        repos.append(rec)

    # failures, retries, blocks
    R = agg["retry"]
    retried = sum(r["retried"] for r in R.values())
    retry_top = []
    for k, r in sorted(R.items(), key=lambda kv: (-kv[1]["retried"], kv[0]))[:12]:
        retry_top.append({"pattern": k, "retried": r["retried"], "exact_command": r["exact"], "blind": r["blind"],
                          "after_edit": r["fix"], "next_attempt_ok": r["ok_next"], "sessions": len(r["sessions"]),
                          "cycle_h": r2(r["cycle_ms"] / 3.6e6)})
    blocks = []
    for k, n in sorted(agg["blocks"].items(), key=lambda kv: (-kv[1], kv[0])):
        blocks.append({"reason": k, "calls": n, "sessions": len(agg["block_sessions"][k]),
                       "agent_gap_h": r2(agg["block_gap_ms"][k] / 3.6e6),
                       "top_repos": [r for r, _ in agg["block_repos"][k].most_common(3)]})
    failing = [r for r in by_calls if r["failed"]]
    fail_top = sorted(failing, key=lambda r: (-r["failed"], r["pattern"]))[:12]
    fail_rate_top = sorted([r for r in failing if (r["primary_calls"] or 0) >= 80],
                           key=lambda r: (-(r["fail_pct"] or 0), r["pattern"]))[:10]

    skills = [{"skill": k, "model_invoked": v["model"], "expanded_without_tool_call": v["typed"],
               "sessions": len(v["sessions"]), "lanes": dict(v["lanes"].most_common(3))}
              for k, v in sorted(agg["skills"].items(), key=lambda kv: (-(kv[1]["model"] + kv[1]["typed"]), kv[0]))[:15]]
    slash = [{"command": "/" + k, "total": v["total"], "owner_typed": v["owner"], "scheduled": v["scheduled"],
              "other": v["other"], "sessions": len(v["sessions"])}
             for k, v in sorted(agg["slash"].items(), key=lambda kv: (-kv[1]["total"], kv[0]))[:20]]

    lanes = [{"lane": k, "calls": v, "sessions": len(agg["lane_sessions"][k]), "share": r2(v / total_calls)}
             for k, v in sorted(agg["lane_calls"].items(), key=lambda kv: (-kv[1], kv[0]))]
    gaps = agg["gaps"]
    groups = {}
    for k, g in sorted(agg["groups"].items()):
        groups[k] = {"calls": g["calls"], "sessions": len(g["sessions"]), "agent_step_h": r2(g["gap_ms"] / 3.6e6),
                     "tool_wall_h": r2(g["wall_ms"] / 3.6e6), "failed": g["fail"],
                     "top_repos": [r for r, _ in g["repos"].most_common(3)],
                     "lanes": dict(g["lanes"].most_common(3))}
    fail_classes = [{"class": k, "calls": v, "sessions": len(agg["fail_class_sessions"][k])}
                    for k, v in sorted(agg["fail_class_total"].items(), key=lambda kv: (-kv[1], kv[0]))[:10]]
    return {
        "turn_time": {"median_s": r1(statistics.median(gaps) / 1000.0) if gaps else None,
                      "mean_s_capped_600": r1(sum(gaps) / len(gaps) / 1000.0) if gaps else None,
                      "total_agent_step_h": r1(sum(gaps) / 3.6e6),
                      "definition": "seconds from one Bash call to the next call in the same transcript file, capped at 600 s"},
        "call_groups": groups,
        "waiting_and_delegation_tools": dict(sorted(agg["tool_counts"].items())),
        "failure_classes": fail_classes,
        "typed_prompts": {
            "total": agg["typed_prompts"],
            "share_10_words_or_more": r2(agg["typed_words"].get(10, 0) / agg["typed_prompts"]) if agg["typed_prompts"] else None,
            "words_histogram_capped_at_10": {str(k): v for k, v in sorted(agg["typed_words"].items())},
            "repeated_short_prompts_min_5": [{"prompt": k, "count": v} for k, v in
                                             sorted(agg["typed_short"].items(), key=lambda kv: (-kv[1], kv[0])) if v >= 5][:10],
            "note": "typed = promptSource typed; rd/herdr inject their briefs the same way, so owner and tooling are not separable",
        },
        "scan": {
            "window": agg["window"], "transcript_files_with_window_entries": agg["files_with_entries"],
            "bash_calls": total_calls, "duplicate_tool_ids_dropped": agg["dup_ids"], "sessions": len(agg["sessions"]),
            "calls_in_iu_repos": agg["iu_calls"], "background_calls": agg["bg_calls"],
            "segments": agg["segments"], "glue_segments": agg["glue_segments"],
            "unmapped_command_segments": agg["other_cmd_calls"],
            "distinct_patterns": len(recs), "tool_wall_hours": r1(agg["wall_ms"] / 3.6e6),
            "status": dict(sorted(agg["status"].items())),
            "nonzero_exits": sum(agg["exit_codes"].values()), "benign_nonzero_exits": agg["benign_nonzero"],
            "exit_codes_top": [{"code": k, "calls": v} for k, v in agg["exit_codes"].most_common(6)],
        },
        "lanes": lanes,
        "top_patterns_overall": by_calls[:30],
        "top_action_patterns": action[:30],
        "top_by_sessions": by_sessions[:20],
        "top_by_wall_hours": by_wall[:15],
        "recurring_patterns": {"min_sessions": scan.MIN_SESSIONS, "patterns": len(recurring),
                               "of_distinct": len(recs),
                               "calls_covered": sum(r["calls"] for r in recurring),
                               "share_of_pattern_occurrences": r2(sum(r["calls"] for r in recurring) / max(1, sum(r["calls"] for r in by_calls)))},
        "recipes": {"min_sessions": scan.MIN_SESSIONS, "frequent_ngrams_3_to_5": n_frequent,
                    "maximal_kept": len(mx), "top": recipes, "top_over_several_calls": multi,
                    "gap_barrier_s": scan.RECIPE_GAP_S,
                    "extra_calls_on_consecutive_steps": dict(sorted(agg["chain_extra"].items()))},
        "per_repo": repos,
        "failures": {
            "failing_calls_non_benign": sum(r["failed"] for r in recs.values()),
            "retry_links": retried,
            "retry_exact_command": sum(r["exact"] for r in R.values()),
            "retry_without_edit_between": sum(r["blind"] for r in R.values()),
            "retry_after_edit": sum(r["fix"] for r in R.values()),
            "retry_next_attempt_ok": sum(r["ok_next"] for r in R.values()),
            "retry_cycle_h": r1(sum(r["cycle_ms"] for r in R.values()) / 3.6e6),
            "blind_retry_cycle_h": r1(sum(r["blind_cycle_ms"] for r in R.values()) / 3.6e6),
            "chain_lengths": {str(k): {"chains": v, "ended_ok": agg["chain_ok"][k]} for k, v in sorted(agg["chains"].items())},
            "top_retried": retry_top, "top_failing_patterns": fail_top, "top_failure_rate_patterns": fail_rate_top,
        },
        "blocked_calls": blocks,
        "skills": skills,
        "slash_commands": slash,
        "_recs": recs,
    }


# =========================================================================== 3. warden families


def _dtparse(s):
    try:
        return dt.datetime.fromisoformat(s.replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        return None


def _n(text):
    t = re.sub(r"https?://\S+", "<url>", text)
    t = re.sub(r"\b\d{1,3}(?:\.\d{1,3}){3}(?::\d+)?\b", "<ip>", t)
    t = re.sub(r"\b[0-9a-f]{7,40}\b", "<sha>", t)
    t = re.sub(r"\d+", "<n>", t)
    return re.sub(r"\s+", " ", t).strip()


def family_of(source, title, signature):
    t = re.sub(r"<[^>]*>", "", redact(title or ""))
    t = re.sub(r"[^\x00-\x7f]+", " ", t)   # emoji and typographic marks carry no signal
    t = re.sub(r"[*`]|(?<!\w)_|_(?!\w)", "", t)
    t = re.sub(r"\s+", " ", t).strip()
    low = t.lower()
    if source == "uk":
        m = re.search(r" - (docker|http|push|db|mysql|postgres|tcp|ping|dns)\b", low)
        return f"uk monitor ({m.group(1)})" if m else "uk monitor (group)"
    m = re.match(r"^\[(.+?)\]\s*\[:(\w+):\s*(\w+)\]\s*(.*)$", t)
    if m:
        name, _emoji, state, msg = m.groups()
        km = re.search(r" - ([A-Za-z]+)$", name)
        kind = km.group(1).lower() if km else "group"
        msg = _n(msg.lower())[:60]
        return f"kuma {kind} {state.lower()}: {msg}"
    if low.startswith("homelab watchdog"):
        rest = re.sub(r"[^\w\s-]", " ", t.split("•", 1)[-1])
        first = re.split(r"\s{2,}|:", rest.strip())[0]
        return "homelab watchdog: " + _n(first.lower())[:40]
    m = re.match(r"^homelab (.+?) (above|below) threshold", low)
    if m:
        return f"homelab metric {m.group(2)} threshold: {_n(m.group(1))}"
    if re.match(r"^(new incident for|automatically resolved)", low):
        return "statuspage incident: " + ("opened" if low.startswith("new") else "auto-resolved")
    if source == "hermes_log":
        m = re.search(r"(?:WARNING|ERROR|INFO|CRITICAL)\s+(?:\[[^\]]*\]\s+)?([\w.]+):\s*(.*)$", t) or re.match(r"^([\w.]+):\s*(.*)$", t)
        if m:
            return f"hermes log {m.group(1)}: " + " ".join(_n(m.group(2).lower()).split()[:5])
        return "hermes log: other"
    if source == "github_go":
        m = re.match(r"\[alert\]\s*([\w-]+)", t)
        return f"github_go alert: {m.group(1)}" if m else "github_go: issue (free text)"
    if source == "human":
        return "human: owner/agent brief (free text)"
    if source == "warden_self":
        return "warden self: " + " ".join(_n(low).split()[:5])
    if source == "job":
        label = signature.split(":", 2)[-1] if signature else ""
        return "job failure: " + label
    if source in ("docker_homelab", "docker_vps"):
        return "docker unhealthy"
    return f"{source}: " + " ".join(_n(low).split()[:6])


def warden_section():
    path = os.path.join(SNAP, "warden.db")
    con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    lo = AS_OF_DT - dt.timedelta(days=WINDOW_DAYS)
    items = {}
    for (eid, sig, state, reason, dup, origin, created, dj, ij, vj, tj, sj, trj, source, title) in con.execute(
            """select t.event_id, t.signature, t.state, t.close_reason, t.duplicate_of, t.origin, t.created_at,
                      t.dispatch_job, t.implement_job, t.validation_job, t.triage_job, t.sweep_job, t.train_job,
                      e.source, e.title
               from triage_items t join events e on e.id = t.event_id"""):
        c = _dtparse(created)
        if c is None or c >= AS_OF_DT:
            continue
        items[eid] = {"sig": sig, "state": state, "reason": reason or "", "dup": dup is not None or reason == "duplicate",
                      "created": c, "source": source, "family": family_of(source, title, sig),
                      "jobs": {j for j in (dj, ij, vj, tj, sj, trj) if j}, "esc": False, "touch": False}
    dur, tiers = {}, {}
    for (jid, tier, status, cr, fin, oid) in con.execute(
            "select job_id, tier, status, created_at, finished_at, origin_event_id from dispatches"):
        c, f = _dtparse(cr), _dtparse(fin)
        if c is None or c >= AS_OF_DT:
            continue
        dur[jid] = (f - c).total_seconds() / 60.0 if f else None
        tiers[jid] = tier
        if oid in items:
            items[oid]["jobs"].add(jid)
    for (eid, to_state, at, note) in con.execute("select event_id, to_state, at, note from item_transitions"):
        a = _dtparse(at)
        if eid not in items or a is None or a >= AS_OF_DT:
            continue
        if to_state == "needs_decision":
            items[eid]["esc"] = True
            items[eid]["touch"] = True
        if note and (note.startswith("closed by hand") or note.startswith("re-investigation requested")):
            items[eid]["touch"] = True
    for (eid, auth, started) in con.execute("select event_id, authorized_by, started_at from operations"):
        s = _dtparse(started)
        if eid in items and s is not None and s < AS_OF_DT and (auth.startswith("owner:") or auth.startswith("cli:")):
            items[eid]["touch"] = True
    ev_by_source = dict(con.execute("select source, count(*) from events where first_seen < ? group by 1",
                                    (AS_OF_DT.strftime("%Y-%m-%dT%H:%M:%S"),)).fetchall())
    con.close()

    def outcome(it):
        if it["dup"]:
            return "duplicate"
        if it["state"] == "fixed" or (it["state"] == "closed" and it["reason"] in ("resolved", "fixed_by")):
            return "resolved"
        if it["state"] == "quiet":
            return "quiet_recovered"
        if it["state"] == "closed" and it["reason"] == "ignored":
            return "ignored"
        if it["state"] == "closed":
            return "closed_no_reason"
        if it["state"] == "failed":
            return "failed"
        return "open_" + it["state"]

    fam = {}
    for eid, it in sorted(items.items()):
        f = fam.setdefault(it["family"], {"sources": collections.Counter(), "items": 0, "duplicates": 0, "n30": 0,
                                          "outcomes": collections.Counter(), "with_job": 0, "jobs": set(),
                                          "esc": 0, "touch": 0, "first": None, "last": None, "jobs30": set(),
                                          "touch30": 0, "esc30": 0, "with_job30": 0})
        o = outcome(it)
        f["sources"][it["source"]] += 1
        in30 = it["created"] >= lo
        if it["dup"]:
            f["duplicates"] += 1
            f["outcomes"]["duplicate"] += 1
            continue
        f["items"] += 1
        f["n30"] += 1 if in30 else 0
        f["outcomes"][o] += 1
        f["with_job"] += 1 if it["jobs"] else 0
        f["with_job30"] += 1 if (it["jobs"] and in30) else 0
        f["jobs"] |= it["jobs"]
        if in30:
            f["jobs30"] |= it["jobs"]
        f["esc"] += 1 if it["esc"] else 0
        f["touch"] += 1 if it["touch"] else 0
        f["esc30"] += 1 if (it["esc"] and in30) else 0
        f["touch30"] += 1 if (it["touch"] and in30) else 0
        c = it["created"]
        f["first"] = c if f["first"] is None or c < f["first"] else f["first"]
        f["last"] = c if f["last"] is None or c > f["last"] else f["last"]

    def fam_rec(name, f):
        jt = collections.Counter(tiers.get(j, "unknown") for j in f["jobs"])
        minutes = sum(dur[j] for j in f["jobs"] if dur.get(j) is not None)
        minutes30 = sum(dur[j] for j in f["jobs30"] if dur.get(j) is not None)
        n = f["items"]
        return {
            "family": name, "source": f["sources"].most_common(1)[0][0], "items": n, "duplicates": f["duplicates"],
            "items_30d": f["n30"], "first": f["first"].strftime("%Y-%m-%d") if f["first"] else None,
            "last": f["last"].strftime("%Y-%m-%d") if f["last"] else None,
            "outcomes": dict(sorted(f["outcomes"].items())),
            "items_needing_agent_job": f["with_job"], "share_needing_agent_job": r2(f["with_job"] / n) if n else None,
            "agent_jobs": len(f["jobs"]), "agent_jobs_by_tier": dict(sorted(jt.items())),
            "jobs_per_item": r2(len(f["jobs"]) / n) if n else None,
            "agent_minutes": r1(minutes), "agent_minutes_30d": r1(minutes30),
            "escalated_items": f["esc"], "owner_touch_items": f["touch"],
            "escalated_30d": f["esc30"], "owner_touch_30d": f["touch30"], "agent_jobs_30d": len(f["jobs30"]),
        }

    all_recs = [fam_rec(k, v) for k, v in fam.items()]
    recurring = sorted([r for r in all_recs if r["items"] >= 3 or r["items_30d"] >= 2],
                       key=lambda r: (-r["items"], r["family"]))
    singles = [r for r in all_recs if r not in recurring]
    n_items = sum(r["items"] for r in all_recs)
    n_dup = sum(r["duplicates"] for r in all_recs)
    with_job = sum(r["items_needing_agent_job"] for r in all_recs)
    all_jobs = set()
    for f in fam.values():
        all_jobs |= f["jobs"]
    minutes_all = sum(dur[j] for j in all_jobs if dur.get(j) is not None)
    return {
        "snapshot": "warden.db", "as_of": AS_OF, "window_days": WINDOW_DAYS,
        "funnel": {
            "events_by_source": dict(sorted(ev_by_source.items(), key=lambda kv: (-kv[1], kv[0]))),
            "items": n_items, "duplicate_rows": n_dup, "items_needing_agent_job": with_job,
            "agent_jobs": len(all_jobs), "agent_minutes": r1(minutes_all),
            "escalated_items": sum(r["escalated_items"] for r in all_recs),
            "owner_touch_items": sum(r["owner_touch_items"] for r in all_recs),
            "items_30d": sum(r["items_30d"] for r in all_recs),
            "escalated_30d": sum(r["escalated_30d"] for r in all_recs),
            "owner_touch_30d": sum(r["owner_touch_30d"] for r in all_recs),
            "agent_jobs_30d": len(set().union(*[f["jobs30"] for f in fam.values()])) if fam else 0,
            "agent_minutes_30d": r1(sum(r["agent_minutes_30d"] or 0 for r in all_recs)),
        },
        "_all_families": all_recs,
        "recurring_families": recurring[:30],
        "recurring_family_count": len(recurring),
        "recurring_items_share": r2(sum(r["items"] for r in recurring) / n_items) if n_items else None,
        "one_off_families": {"families": len(singles), "items": sum(r["items"] for r in singles),
                             "agent_jobs": sum(r["agent_jobs"] for r in singles)},
    }


# =========================================================================== 4. human-queue

HQ_RULES = [
    ("aws-sso-login", lambda t, c: "aws sso login" in c),
    ("tcc-fda-grant-or-protected-read", lambda t, c: "x-apple.systempreferences" in c or re.search(r"Screen Recording|\bTCC\b|Full Disk Access|Accessibility|Privacy & Security|TCC-protected|Network Volumes", t)),
    ("mini-host-cleanup", lambda t, c: re.search(r"Trash|NIC cleanup|system ?extension|macsys|macOS-Drift|Estate review|Tailscale ssh block", t)),
    ("tailnet-acl-push", lambda t, c: re.search(r"tailnet ACL|tailscale-acl|ACL (?:push|from|addition)|Push the tailnet|grant tag:", t, re.I) or "tailscale-acl" in c),
    ("secrets-cache-reseal", lambda t, c: re.search(r"reseal|re-?seed|reseed|Seed the (?:new |mini )|headless\.refs|secrets cache", t, re.I)),
    ("1password-write", lambda t, c: re.search(r"op item (?:create|edit|delete|move)", c) or re.search(r"(?:Create|Rename|Store|Archive|Add|Delete|Move|Copy|Set) .{0,90}(?:1Password|in 1P|1P )|1Password item|1Password vps|1P vps", t) or (re.search(r"op://", t) and re.search(r"create|add|store|reuse", t, re.I))),
    ("1password-lookup", lambda t, c: re.search(r"op item (?:list|get)|op read|op run|titles only|List (?:item|KEY)|Verify .* refs", c + " " + t)),
    ("sudo-root-action", lambda t, c: "ROOT_PW" in c or re.search(r"root-owned|needs sudo|sudo via 1Password|root cleanup|Remove Microsoft Teams", t)),
    ("github-credential-setting", lambda t, c: re.search(r"fine-grained PAT|Settings \u2192 Develop|deploy secrets on GitHub|GitHub UI", t)),
    ("third-party-account-or-token", lambda t, c: re.search(r"CDS token|ECMWF|Copernicus|MAM session|MyAnonamouse|account to download|Uptime Kuma push monitor", t)),
    ("macbook-host-action", lambda t, c: ("macbook-sync" in c) or (re.search(r"MacBook", t) and re.search(r"install|launchd|rollout|sync|port forward|test", t, re.I))),
    ("homelab-host-ops", lambda t, c: re.search(r"homelab|/mnt/hdd|systemd drop-in|chattr", t, re.I)),
    ("service-restart", lambda t, c: re.search(r"needs a restart|gateway restart", t, re.I)),
    ("warden-cli-action", lambda t, c: c.startswith("warden ")),
    ("owner-decision-question", lambda t, c: not c and re.search(r"Which |owner decision|decide|need.*(?:decision|call)", t)),
]
HQ_RETRY = re.compile(r"^\s*(?:Retry|retry)|\((?:retry|re-?try)|second try|third try|retry of|try again|, second retry", re.I)


def hq_kind(text, cmd):
    for name, fn in HQ_RULES:
        try:
            if fn(text, cmd):
                return name
        except re.error:
            continue
    return "other"


def hq_failure_tag(tail):
    t = tail or ""
    if re.search(r"invalid JSON", t):
        return "op-stdin-read-as-json-template"
    if re.search(r"locked or unavailable|timed out|no accounts|1Password.*lock", t, re.I):
        return "1password-locked-or-unreachable"
    if re.search(r"@@|tailscale-acl|Fast-forward|guard", t):
        return "acl-push-guard-or-diff"
    if re.search(r"validateVaultItem|Validation", t):
        return "op-item-validation"
    return "other"


def human_queue_section():
    hq = os.path.join(SNAP, "human-queue")
    lo = AS_OF_DT - dt.timedelta(days=WINDOW_DAYS)
    rows = []
    for f in sorted(glob.glob(os.path.join(hq, "*.req"))):
        try:
            q = json.load(open(f))
        except (OSError, ValueError):
            continue
        created = _dtparse(q.get("created", ""))
        if created is None or created >= AS_OF_DT:
            continue
        try:
            r = json.load(open(f[:-4] + ".res"))
        except (OSError, ValueError):
            r = {}
        ran = _dtparse(r.get("ran_at", ""))
        if ran is not None and ran >= AS_OF_DT:
            r = {}
            ran = None
        text, cmd = q.get("text", "") or "", (q.get("cmd") or "").strip()
        cwd = re.sub(r"^/Users/[^/]+", "~", q.get("cwd", ""))
        m = re.match(r"~/(SourceRoot|IuRoot)/([^/]+)", cwd)
        repo = m.group(2) if m else "~"
        rows.append({
            "kind": hq_kind(text, cmd), "status": r.get("status") or "no-result", "created": created,
            "latency_min": (ran - created).total_seconds() / 60.0 if ran else None,
            "dialog_at_once": bool(ran) and (ran - created).total_seconds() <= 60,
            "retry": bool(HQ_RETRY.search(text)), "repo": repo, "iu": m is not None and m.group(1) == "IuRoot",
            "tag": hq_failure_tag(r.get("output_tail")) if r.get("status") == "failed" else None,
        })
    kinds = {}
    for r in rows:
        k = kinds.setdefault(r["kind"], {"asks": 0, "n30": 0, "status": collections.Counter(), "retry": 0, "lat": [],
                                         "tags": collections.Counter(), "repos": collections.Counter(), "first": None, "last": None,
                                         "retry30": 0, "failed30": 0})
        k["asks"] += 1
        in30 = r["created"] >= lo
        k["n30"] += 1 if in30 else 0
        k["status"][r["status"]] += 1
        k["pushed"] = k.get("pushed", 0) + (1 if r["dialog_at_once"] else 0)
        k["retry"] += 1 if r["retry"] else 0
        k["retry30"] += 1 if (r["retry"] and in30) else 0
        k["failed30"] += 1 if (r["status"] == "failed" and in30) else 0
        if r["latency_min"] is not None and r["status"] in ("done", "failed"):
            k["lat"].append(r["latency_min"])
        if r["tag"]:
            k["tags"][r["tag"]] += 1
        k["repos"][r["repo"]] += 1
        k["first"] = r["created"] if k["first"] is None or r["created"] < k["first"] else k["first"]
        k["last"] = r["created"] if k["last"] is None or r["created"] > k["last"] else k["last"]
    out = []
    for name, k in sorted(kinds.items(), key=lambda kv: (-kv[1]["asks"], kv[0])):
        lat = k["lat"]
        out.append({
            "kind": name, "asks": k["asks"], "asks_30d": k["n30"], "status": dict(sorted(k["status"].items())),
            "retry_asks": k["retry"], "retry_asks_30d": k["retry30"], "failed_30d": k["failed30"],
            "failure_causes": dict(sorted(k["tags"].items())),
            "dialog_shown_within_60s": k.get("pushed", 0),
            "queued_over_60s_then_run": sum(1 for x in lat if x > 1.0),
            "first": k["first"].strftime("%Y-%m-%d"), "last": k["last"].strftime("%Y-%m-%d"),
            "top_repos": [r for r, _ in k["repos"].most_common(3)],
        })
    total = len(rows)
    req_ids = {os.path.basename(f)[:-4] for f in glob.glob(os.path.join(hq, "*.req"))}
    orphans = sum(1 for f in glob.glob(os.path.join(hq, "*.res")) if os.path.basename(f)[:-4] not in req_ids)
    status = collections.Counter(r["status"] for r in rows)
    span_days = (max(r["created"] for r in rows) - min(r["created"] for r in rows)).days + 1 if rows else 0
    return {
        "snapshot": "human-queue/", "asks": total, "orphan_results_without_request": orphans, "asks_30d": sum(1 for r in rows if r["created"] >= lo),
        "span_days": span_days, "status": dict(sorted(status.items())),
        "retry_asks": sum(1 for r in rows if r["retry"]), "failed": status.get("failed", 0),
        "failure_causes": dict(sorted(collections.Counter(r["tag"] for r in rows if r["tag"]).items())),
        "kinds": out,
        "by_repo": [{"repo": k, "asks": v} for k, v in collections.Counter(r["repo"] for r in rows).most_common(10)],
    }


# =========================================================================== 5. candidate automation

AGENT_HOUR_WEIGHT = 0.2   # value_h = owner_h + AGENT_HOUR_WEIGHT * agent_h  (ranking only)
ASSUMPTIONS["agent_hour_weight"] = AGENT_HOUR_WEIGHT
ASSUMPTIONS["agent_hour_weight_basis"] = (
    "an agent hour is worth a fifth of an owner hour for ranking: agents run in parallel and cost quota, "
    "the owner's attention is the scarce resource; both columns are always shown"
)
ASSUMPTIONS["owner_seconds_per_resume"] = 45
ASSUMPTIONS["owner_seconds_per_reset"] = 3


def _fam_sum(fams, pred):
    out = {"families": 0, "items_30d": 0, "agent_jobs_30d": 0, "agent_minutes_30d": 0.0, "escalated_30d": 0,
           "owner_touch_30d": 0, "items": 0}
    for f in fams:
        if pred(f["family"]):
            out["families"] += 1
            for k in ("items_30d", "agent_jobs_30d", "escalated_30d", "owner_touch_30d", "items"):
                out[k] += f[k]
            out["agent_minutes_30d"] += f["agent_minutes_30d"] or 0.0
    return out


def build_candidates(oh, ag, wd, hq):
    C = []
    turn_s = ag["turn_time"]["median_s"] or 5.9
    G = ag["call_groups"]
    K = {k["kind"]: k for k in hq["kinds"]}
    fams = wd["_all_families"]
    wdays = ASSUMPTIONS["owner_history_window_days"]
    md = ASSUMPTIONS["month_days"]

    def add(cid, pattern, freq, who, mechanism, owner_h, agent_h, arithmetic, evidence, note=""):
        C.append({"id": cid, "pattern": pattern, "frequency_30d": freq, "who_repeats": who, "mechanism": mechanism,
                  "owner_h_per_month": r1(owner_h), "agent_h_per_month": r1(agent_h),
                  "value_h": r2(owner_h + AGENT_HOUR_WEIGHT * agent_h), "arithmetic": arithmetic,
                  "evidence": evidence, "note": note})

    # ---- owner: human-queue asks
    k = K.get("1password-write", {})
    f30 = k.get("failed_30d", 0)
    add("T01", "1Password item writes via the human-queue (op item create/edit/rename); stdin read as a JSON template",
        f"{k.get('asks_30d', 0)} asks, {f30} failed", "owner (dialog) + agent (retry ask)",
        "CLI verb (`secrets put|rename`, JSON-safe, idempotent) + policy line (never pipe JSON into `op item create`)",
        f30 * 2 * OWNER_ASK_MIN / 60, 0,
        f"{f30} failed asks x 2 asks (the failed one and its retry) x {OWNER_ASK_MIN:g} min / 60",
        "human_queue.kinds[1password-write].failure_causes")
    k = K.get("secrets-cache-reseal", {})
    n = k.get("asks_30d", 0)
    add("T02", "Reseal the mini secrets cache after `headless.refs` changed", f"{n} asks", "owner (dialog)",
        "reconciler (refs file = desired, sealed cache = observed; one batched approval instead of one per change)",
        n * OWNER_ASK_MIN * 0.7 / 60, 0, f"{n} asks x {OWNER_ASK_MIN:g} min x 70 % batched away / 60",
        "human_queue.kinds[secrets-cache-reseal]", "70 % is an assumption")
    k = K.get("tailnet-acl-push", {})
    n = k.get("asks_30d", 0)
    add("T03", "Push the tailnet ACL from the private repo (diff, confirm, apply); guard aborts and retries", f"{n} asks, {k.get('failed_30d', 0)} failed",
        "owner (dialog + typed confirm)", "Renovate-style tool (GitOps: verify on PR, apply on merge, drift check)",
        n * OWNER_ASK_MIN / 60, 0, f"{n} asks x {OWNER_ASK_MIN:g} min x 100 % / 60", "human_queue.kinds[tailnet-acl-push]")
    k = K.get("1password-lookup", {})
    n = k.get("asks_30d", 0)
    add("T04", "1Password lookups (item titles / field names, no values)", f"{n} asks", "owner (dialog)",
        "CLI verb (`secrets ls` answering from the sealed cache, no dialog)",
        n * OWNER_ASK_MIN / 60, 0, f"{n} asks x {OWNER_ASK_MIN:g} min x 100 % / 60", "human_queue.kinds[1password-lookup]")
    chores = ("mini-host-cleanup", "macbook-host-action", "sudo-root-action", "tcc-fda-grant-or-protected-read",
              "homelab-host-ops", "service-restart", "aws-sso-login", "github-credential-setting",
              "third-party-account-or-token", "warden-cli-action")
    n = sum(K.get(c, {}).get("asks_30d", 0) for c in chores)
    add("T05", "Estate chores that need a present human (sudo cleanups, TCC / Full Disk Access grants, host installs, token pages)",
        f"{n} asks", "owner (dialog)", "recurring job (monthly estate sweep, one batched approval) + policy line (grant TCC once per machine)",
        n * OWNER_ASK_MIN * 0.5 / 60, 0, f"{n} asks x {OWNER_ASK_MIN:g} min x 50 % batched or granted once / 60",
        "human_queue.kinds[*]", "50 % is an assumption")

    # ---- owner: shell
    top = {r["pattern"]: r for r in oh["combined_top_patterns"]}
    r = top.get("claude --resume")
    if r:
        sec = ASSUMPTIONS["owner_seconds_per_resume"]
        add("T06", "`claude --resume <session id>` typed by hand (find the id, paste)",
            f"{r['per_month_est']:g} / month", "owner (shell)",
            "reconciler (herdr restores the agents that were running after a crash or reboot) + CLI verb (`rd resume <repo>`)",
            r["per_month_est"] * sec / 3600, 0, f"{r['per_month_est']:g} resumes x {sec} s / 3600",
            "owner_history.combined_top_patterns[claude --resume]", "45 s per resume is an assumption")
    pairs = oh["launcher_reset_pairs"].get("launcher_then_reset", 0)
    rs = top.get("reset")
    if rs:
        per_month = pairs * md / wdays
        sec = ASSUMPTIONS["owner_seconds_per_reset"]
        add("T07", "`reset` typed after a Claude launcher exits (terminal left in a bad state)",
            f"{rs['per_month_est']:g} resets / month, {per_month:g} directly after a launcher", "owner (shell)",
            "policy line in the launcher (`c` restores the TTY on exit)",
            rs["per_month_est"] * sec / 3600, 0, f"{rs['per_month_est']:g} resets x {sec} s / 3600",
            "owner_history.launcher_reset_pairs", "3 s per reset is an assumption")

    # ---- warden loop
    casc = _fam_sum(fams, lambda f: (f.startswith("kuma ") and " down" in f) or f.startswith("uk monitor") or f.startswith("docker unhealthy")
                    or f.startswith("homelab watchdog") or f.startswith("homelab metric") or f.startswith("job failure"))
    add("T08", "Monitor and container outage items (Kuma down, uk monitor, unhealthy container, watchdog, job failure): one item and one investigation per page",
        f"{casc['items_30d']} items, {casc['agent_jobs_30d']} agent jobs, {casc['escalated_30d']} escalations", "warden loop + owner (escalations)",
        "reconciler (level-triggered conditions) + correlation (topology / 15-min window fold: one outage = one incident)",
        casc["escalated_30d"] * OWNER_ESC_MIN * 0.7 / 60, casc["agent_minutes_30d"] * 0.7 / 60,
        f"owner: {casc['escalated_30d']} escalations x {OWNER_ESC_MIN:g} min x 70 % / 60; agent: {casc['agent_minutes_30d']:.0f} job-min x 70 % / 60",
        "warden.recurring_families[kuma/uk/docker/homelab/job]", "70 % folded is an assumption (the 10-17 outage folds 16 pages into 1)")
    rec = _fam_sum(fams, lambda f: (f.startswith("kuma ") and " up" in f) or f.startswith("statuspage incident"))
    add("T09", "Recovery notifications opened as items (Kuma up, status-page opened / auto-resolved) and closed `ignored`",
        f"{rec['items_30d']} items, {rec['agent_jobs_30d']} agent jobs", "warden loop",
        "reconciler (an `up` event closes the matching condition and never creates an item)",
        0.0, rec["agent_minutes_30d"] / 60, f"{rec['items_30d']} items, no agent job, no owner touch: noise removed, hours measured = {rec['agent_minutes_30d']:.0f} job-min / 60",
        "warden.recurring_families[kuma ... up]", "pure ledger and card churn; hours are ~0 by measurement")
    her = _fam_sum(fams, lambda f: f.startswith("hermes log"))
    add("T10", "Hermes log lines opened as items (tool errors, checkpoint-manager git skips, streaming failures, second gateway instance)",
        f"{her['items_30d']} items, {her['agent_jobs_30d']} agent jobs, {her['owner_touch_30d']} owner touches", "warden loop (+ owner touches)",
        "known-error store (fix once, recognise the fingerprint) + policy line (expected skips are logged below ERROR)",
        her["owner_touch_30d"] * OWNER_ESC_MIN * 0.8 / 60, her["agent_minutes_30d"] * 0.8 / 60,
        f"owner: {her['owner_touch_30d']} touches x {OWNER_ESC_MIN:g} min x 80 % / 60; agent: {her['agent_minutes_30d']:.0f} job-min x 80 % / 60",
        "warden.recurring_families[hermes log]", "80 % is an assumption")
    gh = _fam_sum(fams, lambda f: f.startswith("github_go alert"))
    add("T11", "Scheduled-job alerts as GitHub issues (store_stale, workflow_failed, job_down, disk_low): an item and an investigation each time",
        f"{gh['items_30d']} items, {gh['agent_jobs_30d']} agent jobs", "warden loop",
        "recurring job (per-signal self-heal with the fix recipe in the known-error store)",
        gh["owner_touch_30d"] * OWNER_ESC_MIN * 0.6 / 60, gh["agent_minutes_30d"] * 0.6 / 60,
        f"owner: {gh['owner_touch_30d']} touches x {OWNER_ESC_MIN:g} min x 60 % / 60; agent: {gh['agent_minutes_30d']:.0f} job-min x 60 % / 60",
        "warden.recurring_families[github_go alert]", "60 % is an assumption")

    intake = _fam_sum(fams, lambda f: f.startswith("human:") or f.startswith("github_go: issue"))
    add("T11b", "Escalations (`needs_decision`) raised on intake items, the owner's and agents' own briefs and issues",
        f"{intake['escalated_30d']} escalations on {intake['items_30d']} items, {intake['agent_jobs_30d']} agent jobs", "owner (decisions) + warden loop",
        "policy line (the fixed owner-decision rule: product direction, spend, irreversible data loss, other people) + verification ladder (everything else is decided on evidence)",
        intake["escalated_30d"] * OWNER_ESC_MIN * 0.5 / 60, 0,
        f"{intake['escalated_30d']} escalations x {OWNER_ESC_MIN:g} min x 50 % not a genuine owner decision / 60",
        "warden.funnel, warden.recurring_families[human / github_go: issue]",
        "50 % is a placeholder until the golden set labels `genuine_owner_decision`; replace it with the measured share")

    # ---- agents (call groups are disjoint, so the rows add up)
    g = G.get("blocked:sleep-then-command", {})
    add("T12", "`sleep N && <command>` polling that the harness blocks, then re-issued differently",
        f"{g.get('calls', 0)} blocked calls in {g.get('sessions', 0)} sessions", "agents (interactive)",
        "policy line (wait with `rd wait` / `agw wait` / Monitor, never `sleep N &&`)",
        0, g.get("calls", 0) * turn_s / 3600,
        f"{g.get('calls', 0)} blocked calls x 100 % x {turn_s:g} s median turn / 3600 (measured time to the next call, an upper bound: {g.get('agent_step_h', 0)} h)",
        "agent_bash.call_groups[blocked:sleep-then-command]")
    g = G.get("poll:sleep", {})
    n = g.get("calls", 0)
    add("T13", "`sleep <n>` polls for a job, CI run or service (one model turn per poll)",
        f"{n} calls in {g.get('sessions', 0)} sessions", "agents (interactive)",
        "reconciler (event-driven wake: herdr events and job completion push to the waiting agent)",
        0, n * 0.8 * turn_s / 3600, f"{n} polls x 80 % x {turn_s:g} s median turn / 3600 (the waiting itself is not claimed)",
        "agent_bash.call_groups[poll:sleep]", "80 % is an assumption; some sleeps are legitimate pacing")
    g = G.get("poll:orchestrator-status", {})
    n = g.get("calls", 0)
    add("T14", "Orchestrators polling agent and PR state (`rd agents`, `rd read`, wave-watch, `herdr agent wait|list|get`, `gh pr checks`)",
        f"{n} calls in {g.get('sessions', 0)} sessions", "agents (orchestrator tabs)",
        "reconciler (event log + push: a finished wave or red check wakes the orchestrator)",
        0, n * 0.8 * turn_s / 3600, f"{n} calls x 80 % x {turn_s:g} s / 3600", "agent_bash.call_groups[poll:orchestrator-status]",
        "80 % is an assumption")
    g = G.get("poll:shell-loop", {})
    add("T15", "Shell polling loops (`until|while|for ... sleep`) that park a session in one long call",
        f"{g.get('calls', 0)} loops in {g.get('sessions', 0)} sessions, {g.get('tool_wall_h', 0)} h of wall time", "agents",
        "reconciler (event-driven wake frees the session; no turns removed, so no hours claimed)",
        0, 0, f"each loop is one call: turns removed = 0; wall time parked = {g.get('tool_wall_h', 0)} h (not claimed)",
        "agent_bash.call_groups[poll:shell-loop]", "listed so the omission is visible; latency and parallelism gain, not toil hours")
    g = G.get("kill-sleep-kill-rm", {})
    add("T16", "Process cleanup recipe `kill -> sleep -> kill -> rm` (stale dev / test servers and lockfiles)",
        f"{g.get('calls', 0)} calls in {g.get('sessions', 0)} sessions", "agents (incl. agw / sideclaw jobs)",
        "recurring job (reaper for stale agent-owned processes and locks) + CLI verb (`rd kill-tree`)",
        0, g.get("calls", 0) * 0.8 * turn_s / 3600,
        f"{g.get('calls', 0)} calls x 80 % x {turn_s:g} s / 3600 (upper bound, whole step time: {g.get('agent_step_h', 0)} h)",
        "agent_bash.call_groups[kill-sleep-kill-rm]", "80 % is an assumption; each recipe is one chained call, so a verb alone saves tokens, the reaper saves the call")
    g = G.get("fail:bsd-vs-gnu-and-glob", {})
    add("T17", "GNU-isms on macOS: `sed -i` / `sed` syntax errors, unquoted zsh globs, `head -n -N`, GNU-only flags",
        f"{g.get('calls', 0)} failing calls in {g.get('sessions', 0)} sessions", "agents (interactive)",
        "policy line (BSD userland: `sed -i ''`, quote globs; prefer the Edit tool) + PreToolUse rewrite",
        0, g.get("calls", 0) * 0.9 * turn_s / 3600,
        f"{g.get('calls', 0)} failing calls x 90 % x {turn_s:g} s / 3600 (upper bound, measured step time: {g.get('agent_step_h', 0)} h)",
        "agent_bash.failure_classes, call_groups[fail:bsd-vs-gnu-and-glob]", "90 % is an assumption")
    g1, g2 = G.get("blocked:worktree-isolation-guard", {}), G.get("blocked:git-and-docker-hooks", {})
    n = g1.get("calls", 0) + g2.get("calls", 0)
    h = (g1.get("agent_step_h", 0) or 0) + (g2.get("agent_step_h", 0) or 0)
    add("T18", "Commands refused by the worktree-isolation guard and by the git / docker hooks (force push, protected branch, raw docker)",
        f"{n} blocked calls", "agents (worktree and interactive sessions)",
        "policy line (AGENTS.md: what stays inside a worktree; merge only via `rd merge` / PR)",
        0, n * 0.8 * turn_s / 3600, f"{n} blocked calls x 80 % x {turn_s:g} s / 3600 (upper bound, measured: {h:.2f} h)",
        "agent_bash.blocked_calls", "80 % is an assumption")
    g = G.get("vps-homelab-container-inspect", {})
    n = g.get("calls", 0)
    add("T19", "Container inspection on the VPS and homelab by hand (`ssh <host>: docker ps|logs|exec|inspect`)",
        f"{n} calls in {g.get('sessions', 0)} sessions", "agents", "CLI verb (`vps|hl ps|logs`) or an Argo read model",
        0, n * 0.5 * turn_s / 3600, f"{n} calls x 50 % x {turn_s:g} s / 3600", "agent_bash.call_groups[vps-homelab-container-inspect]",
        "50 % is an assumption")
    g = G.get("local-health-curl", {})
    n = g.get("calls", 0)
    add("T20", "Local health probes by hand (`curl localhost:<port>/health`)", f"{n} calls in {g.get('sessions', 0)} sessions", "agents",
        "reconciler (health probes declared in the project manifest, state read from the event log)",
        0, n * 0.6 * turn_s / 3600, f"{n} calls x 60 % x {turn_s:g} s / 3600", "agent_bash.call_groups[local-health-curl]", "60 % is an assumption")
    g = G.get("launchd-by-hand", {})
    n = g.get("calls", 0)
    add("T21", "launchd inspection and restarts by hand (`launchctl print|list|kickstart`)", f"{n} calls in {g.get('sessions', 0)} sessions", "agents",
        "reconciler (desired launchd jobs from the manifest, kickstart when unhealthy)",
        0, n * 0.7 * turn_s / 3600, f"{n} calls x 70 % x {turn_s:g} s / 3600", "agent_bash.call_groups[launchd-by-hand]", "70 % is an assumption")
    g = G.get("dependency-updates", {})
    n = g.get("calls", 0)
    add("T22", "Dependency checks and bumps by agents (`bun outdated|update`, `npm outdated`, `ncu`, `uv lock`, `brew outdated|upgrade`)",
        f"{n} calls in {g.get('sessions', 0)} sessions", "agents", "Renovate-style tool (mechanical bumps as PRs; agents only for breaking changes)",
        0, n * 0.9 * turn_s / 3600, f"{n} calls x 90 % x {turn_s:g} s / 3600", "agent_bash.call_groups[dependency-updates]", "90 % is an assumption")
    ex = ag["recipes"]["extra_calls_on_consecutive_steps"]
    ver_n, com_n = ex.get("verify", 0), ex.get("commit", 0)
    add("T23", "Verification run as separate calls in a row (`bun test`, `bunx oxfmt`, typecheck, lint, build)",
        f"{ver_n} extra calls", "agents", "CLI verb + policy line (one `make check` per repo, the same entrypoint everywhere)",
        0, ver_n * 0.7 * turn_s / 3600, f"{ver_n} extra calls x 70 % x {turn_s:g} s / 3600", "agent_bash.recipes.extra_calls_on_consecutive_steps",
        "70 % is an assumption")
    add("T24", "git add / commit / push / `gh pr create` issued as separate calls in a row",
        f"{com_n} extra calls", "agents", "CLI verb (`git ship`; the `/commit` skill as the only way)",
        0, com_n * 0.9 * turn_s / 3600, f"{com_n} extra calls x 90 % x {turn_s:g} s / 3600", "agent_bash.recipes.extra_calls_on_consecutive_steps",
        "90 % is an assumption; most commit recipes are already one chained call (median 1), only the separate ones count")
    C.sort(key=lambda c: (-c["value_h"], -c["owner_h_per_month"], c["id"]))
    for i, c in enumerate(C, 1):
        c["id"] = f"C{i:02d}"
    return C


# =========================================================================== output


DEFINITIONS = {
    "month": "30 days; transcript, warden and human-queue figures use the window [AS_OF - 30 d, AS_OF)",
    "pattern": "command + subcommand with every argument elided or replaced by a placeholder (cmdnorm.normalize); "
               "env assignments, paths, URLs, quoted strings and heredoc bodies never reach an output",
    "owner_manual": "shell-history entries not typed by rd/herdr; injected lines (`export USAGE_LANE=`, `claude --dangerously-skip-permissions ...`, `claude --bg`) are counted apart",
    "glue": "cd, export, echo, set, test and other shell builtins; counted in totals, excluded from rankings",
    "inspect": "read-only inspection (ls, cat, grep, sed without -i, head, ...); ranked, but excluded from recipes and the action table",
    "session": "one Claude Code session id; subagent transcripts count with their parent",
    "recurring_pattern": "a pattern present in >= 5 sessions",
    "recipe": "the same 3-5 consecutive non-noise patterns in >= 5 sessions (gaps over 20 min break a sequence; consecutive duplicates collapse); maximal sequences only",
    "failing_call": "tool_result with is_error and `Exit code N`, minus normal non-zero exits (grep/rg no match, test, diff, git rev-parse ...)",
    "blocked_call": "a call refused by the harness or a PreToolUse hook (sleep-then-command, worktree isolation, force push, raw docker)",
    "retry": "a failing call re-run within the next 8 calls / 15 min, as the same command (exact) or the same action-level pattern; `without edit` = no Edit/Write tool call in between",
    "agent_step_time": "seconds from a Bash call to the next Bash call in the same file (includes waiting inside the call), capped at 600 s",
    "lane": "interactive = Claude Code CLI sessions; headless = sdk-cli sessions elsewhere; agw-job / sideclaw-job = dispatched review and check workers; scratch / bench = temporary directories",
    "warden_item": "DEFINITIONS.md `item`: duplicates are occurrences, counted apart; outcomes follow `resolved`; escalated / owner_touch as defined there",
    "warden_family": "rule-based normalisation of source + title (service names, numbers, addresses and ids removed); `family_of` in toil.py",
    "agent_job": "a dispatches row linked by origin_event_id, or a job id stored on the item (dispatch, implement, validation, triage, sweep, train)",
    "human_queue_kind": "keyword classification of the ask text and proposed command (HQ_RULES in toil.py); only counts are stored",
}


def build_glance(oh, ag, wd, hq, cands):
    owner = []
    for r in oh["combined_top_patterns"]:
        if cmdnorm.head_of(r["pattern"]) in cmdnorm.NAV or r["pattern"] == "<other-cmd>":
            continue
        owner.append({"pattern": r["pattern"], "per_month_est": r["per_month_est"], "mini": r["mini"], "iumac": r["iumac"],
                      "typing_min_per_month": r["est_typing_min_per_month"]})
        if len(owner) == 5:
            break
    asks = [{"kind": k["kind"], "asks_30d": k["asks_30d"], "failed_30d": k["failed_30d"]} for k in
            sorted(hq["kinds"], key=lambda k: (-k["asks_30d"], k["kind"]))[:5]]
    agent = [{"pattern": r["pattern"], "calls": r["calls"], "sessions": r["sessions"], "wall_h": r["wall_h"]}
             for r in ag["top_action_patterns"][:5]]
    by_wall = [{"pattern": r["pattern"], "wall_h": r["wall_h"], "calls": r["calls"]} for r in ag["top_by_wall_hours"][:5]]
    fams = [{"family": r["family"], "items": r["items"], "items_30d": r["items_30d"],
             "share_needing_agent_job": r["share_needing_agent_job"], "agent_jobs": r["agent_jobs"],
             "escalated": r["escalated_items"]}
            for r in wd["recurring_families"] if not r["family"].startswith(("human:", "github_go: issue"))][:5]
    cand = [{"id": c["id"], "pattern": c["pattern"], "mechanism": c["mechanism"], "owner_h_per_month": c["owner_h_per_month"],
             "agent_h_per_month": c["agent_h_per_month"], "value_h": c["value_h"]} for c in cands[:5]]
    return {"owner_shell_top5": owner, "owner_human_queue_top5": asks, "agent_action_patterns_top5": agent,
            "agent_wall_hours_top5": by_wall, "warden_families_top5": fams, "candidates_top5": cand}


def build_output(oh, ag, wd, hq, cands, agg):
    ag = dict(ag)
    ag.pop("_recs", None)
    wd = dict(wd)
    wd.pop("_all_families", None)
    return {
        "meta": {
            "script": "toil.py", "helpers": ["cmdnorm.py", "scan_transcripts.py"],
            "question": "what do the owner and the agents repeat by hand, how often, and which of it should become a reconciler, "
                        "a recurring job, a CLI verb, a policy line or a Renovate-style tool",
            "as_of": AS_OF, "window_days": WINDOW_DAYS,
            "definition_keys": ["item", "escalated", "owner_touch", "resolved"],
            "sources": {
                "owner_history": "mini ~/.zsh_history and IU MacBook ~/.zsh_history (frozen aggregates, see owner_history.sources.*.status)",
                "agent_bash": f"~/.claude/projects/**/*.jsonl, {agg['files_with_entries']} files with entries in the window {agg['window'][0]} .. {agg['window'][1]}",
                "warden": "snapshots/<as_of date>/warden.db", "human_queue": "snapshots/<as_of date>/human-queue/",
            },
            "definitions": DEFINITIONS, "assumptions": ASSUMPTIONS,
            "redaction": "free text passes lib/redact.py:redact(); patterns carry no arguments; IuRoot repos by name only, "
                         "their calls appear as tool-level aggregates",
        },
        "owner_history": oh,
        "agent_bash": ag,
        "warden": wd,
        "human_queue": hq,
        "candidates": cands,
        "glance": build_glance(oh, ag, wd, hq, cands),
    }


def md_table(headers, rows):
    out = ["| " + " | ".join(headers) + " |", "|" + "-|" * len(headers)]
    for r in rows:
        out.append("| " + " | ".join(str(c) for c in r) + " |")
    return "\n".join(out)


def esc(s):
    return str(s).replace("|", "\\|")


def fmt_outcomes(o):
    short = {"resolved": "res", "quiet_recovered": "quiet", "ignored": "ign", "failed": "fail", "duplicate": "dup",
             "closed_no_reason": "closed", "open_needs_decision": "open"}
    return ", ".join(f"{n} {short.get(k, k)}" for k, n in sorted(o.items(), key=lambda kv: (-kv[1], kv[0])))


def render_md(out):
    oh, ag, wd, hq, cands = out["owner_history"], out["agent_bash"], out["warden"], out["human_queue"], out["candidates"]
    sc = ag["scan"]
    L = []
    w = L.append
    w("# Toil accounting: what the owner and the agents repeat by hand")
    w("")
    w(f"As of `{out['meta']['as_of']}`, windows of {WINDOW_DAYS} days. Produced by `toil.py` (helpers `cmdnorm.py`, "
      "`scan_transcripts.py`) into `toil.out.json`, which holds every number below. Patterns are command + subcommand with "
      "all arguments elided; no raw command, prompt or ask text is stored. Hours are estimates with the arithmetic shown in "
      "section 6; every assumption is listed in `toil.out.json` under `meta.assumptions`.")
    w("")

    # ------------------------------------------------------------------ summary
    top_owner = [r for r in oh["combined_top_patterns"] if r["kind"] not in ("navigation",)][:5]
    w("## Summary")
    w("")
    n_manual = oh.get("manual_commands_total", 0)
    w(f"- **Owner:** {n_manual:,} hand-typed commands in the retained shell histories (plus {oh.get('injected_total', 0):,} lines typed "
      "into panes by rd/herdr, which are not owner toil). The most repeated pattern is the Claude launcher followed by `reset`; "
      f"{hq['asks_30d']} human-queue asks reached the owner in 30 days ({hq['asks']} since August), {hq['failed']} of them failed and "
      f"{hq['retry_asks']} were retries of an earlier ask.")
    w(f"- **Agents:** {sc['bash_calls']:,} Bash calls in {sc['sessions']:,} sessions over 30 days, {sc['tool_wall_hours']:,.0f} h of tool wall time. "
      f"{sc['nonzero_exits'] - sc['benign_nonzero_exits']:,} calls failed ({100.0 * (sc['nonzero_exits'] - sc['benign_nonzero_exits']) / sc['bash_calls']:.1f} %), "
      f"{sum(b['calls'] for b in ag['blocked_calls']):,} were refused by the harness or a hook; the same command re-run after a failure is rare "
      f"({ag['failures']['retry_exact_command']} exact re-runs).")
    fn = wd["funnel"]
    w(f"- **Warden loop:** {fn['items']} items from {sum(fn['events_by_source'].values()):,} events; {fn['items_needing_agent_job']} items needed at least one agent job "
      f"({fn['agent_jobs']:,} jobs, {fn['agent_minutes'] / 60:,.0f} agent hours); {wd['recurring_family_count']} recurring families cover "
      f"{round(100 * (wd['recurring_items_share'] or 0))} % of the items. In the last 30 days {fn['escalated_30d']} of {fn['items_30d']} items reached the owner "
      f"(`needs_decision`) and {fn['owner_touch_30d']} were touched from outside the loop (`owner_touch`).")
    w("")

    gl = out["glance"]
    w("### At a glance")
    w("")
    w("- **Owner, shell (per month, est.):** " + "; ".join(f"`{r['pattern']}` {r['per_month_est']:g}" for r in gl["owner_shell_top5"]) + ".")
    w("- **Owner, human-queue (30 days):** " + "; ".join(f"{r['kind']} {r['asks_30d']} ({r['failed_30d']} failed)" for r in gl["owner_human_queue_top5"]) + ".")
    w("- **Agents, action patterns by calls:** " + "; ".join(f"`{r['pattern']}` {r['calls']:,} in {r['sessions']:,} sessions" for r in gl["agent_action_patterns_top5"]) + ".")
    w("- **Agents, tool wall hours:** " + "; ".join(f"`{r['pattern']}` {r['wall_h']:g} h" for r in gl["agent_wall_hours_top5"]) + ".")
    w("- **Warden families (excluding intake):** " + "; ".join(f"`{r['family']}` {r['items']} items" for r in gl["warden_families_top5"]) + ".")
    w("- **Best candidates (value hours):** " + "; ".join(f"{r['id']} {r['owner_h_per_month']:g} owner + {r['agent_h_per_month']:g} agent h" for r in gl["candidates_top5"]) + " (see section 6).")
    w("")

    # ------------------------------------------------------------------ sources
    w("## Sources and coverage")
    w("")
    rows = []
    for src, v in oh["sources"].items():
        if v.get("status", "").startswith("ok"):
            rows.append([f"owner shell history ({src})", f"{v['entries']:,} entries, {v['manual_entries']:,} hand-typed", v["status"], "no timestamps; window assumed 30 d"])
        else:
            rows.append([f"owner shell history ({src})", "unavailable", v.get("status", "?"), "see caveats"])
    rows.append(["agent Bash calls", f"{sc['bash_calls']:,} calls, {sc['sessions']:,} sessions, {sc['transcript_files_with_window_entries']:,} files with entries in the window", "transcripts, streamed", "timestamps exact; entry-filtered to the window"])
    rows.append(["warden items", f"{fn['items']} items, {fn['duplicate_rows']} duplicate rows, {fn['agent_jobs']:,} agent jobs", "snapshot warden.db", "2026-09-08 .. as-of"])
    rows.append(["human-queue asks", f"{hq['asks']} asks over {hq['span_days']} days", "snapshot human-queue/", "ran_at is the dialog time, not the click"])
    w(md_table(["source", "volume", "origin", "notes"], rows))
    w("")

    # ------------------------------------------------------------------ 1 owner
    w("## 1. What the owner repeats by hand")
    w("")
    w("### Top 20 manual shell patterns")
    w("")
    rows = []
    n = 0
    nav = {}
    for r in oh["combined_top_patterns"]:
        if cmdnorm.head_of(r["pattern"]) in cmdnorm.NAV:
            nav[r["pattern"]] = r["count"]
            continue
        if r["pattern"] == "<other-cmd>":
            continue
        n += 1
        rows.append([n, f"`{esc(r['pattern'])}`", r["kind"], r["mini"], r["iumac"] if oh["sources"].get("iumac", {}).get("status", "").startswith("ok") else "n/a",
                     r["count"], r["per_month_est"], r["est_typing_min_per_month"]])
        if n == 20:
            break
    w(md_table(["#", "pattern", "kind", "mini", "iumac", "total", "per month (est.)", "typing min / month (est.)"], rows))
    w("")
    inj = {}
    for v in oh["sources"].values():
        for k2, n2 in (v.get("injected_entries") or {}).items():
            inj[k2] = inj.get(k2, 0) + n2
    cd_n = sum(v for src in oh["sources"].values() for k2, v in (src.get("glue_segments") or {}).items() if k2 == "cd <path>")
    w("Excluded as not owner-typed: " + "; ".join(f"{n2:,} x {k2}" for k2, n2 in sorted(inj.items(), key=lambda kv: -kv[1])) +
      ". Navigation is left out of the ranking: " + ", ".join(f"`{k2}` {v}" for k2, v in sorted(nav.items(), key=lambda kv: -kv[1])) + f", `cd <path>` {cd_n}. "
      "Frequencies assume each history spans about 30 days (no per-line timestamps; the implied-window check in section 7 makes the monthly figures an upper bound).")
    w("")
    pr = oh["launcher_reset_pairs"]
    w(f"The sharpest repeat: `reset` is typed {next((r['count'] for r in oh['combined_top_patterns'] if r['pattern'] == 'reset'), 0)} times, {pr.get('launcher_then_reset', 0)} of them directly after a Claude launcher exits.")
    w("")
    w("### Top repeated sequences (2-4 consecutive commands)")
    w("")
    rows = [[f"`{esc(' > '.join(g['sequence']))}`", g["count"]] for g in oh["combined_ngrams"][:12]]
    w(md_table(["sequence", "times"], rows))
    w("")
    w("### Typed slash commands (`<command-name>` entries in user messages)")
    w("")
    rows = [[f"`{s['command']}`", s["total"], s["owner_typed"], s["scheduled"], s["other"], s["sessions"]] for s in ag["slash_commands"][:12]]
    w(md_table(["command", "entries", "owner-typed", "scheduled", "other", "sessions"], rows))
    w("")
    tp = ag["typed_prompts"]
    short = tp["repeated_short_prompts_min_5"]
    w(f"Typed prompts: {tp['total']:,} in 30 days, {round(100 * (tp['share_10_words_or_more'] or 0))} % with ten words or more (rd/herdr type their briefs into panes the same way, so owner and tooling "
      "are not separable). Short prompts repeated at least five times: " + (", ".join(f"\"{p['prompt']}\" {p['count']}" for p in short) if short else "none") + ". The owner does not repeat steering nudges by hand.")
    w("")
    sk = ag["skills"][:8]
    w("Skills launched in the same window (model-invoked `Skill` calls; skill launches the owner types are recorded as skill expansions without a tool call): " +
      ", ".join(f"`{s['skill']}` {s['model_invoked']}" + (f" (+{s['expanded_without_tool_call']})" if s["expanded_without_tool_call"] else "") for s in sk) + ".")
    w("")

    # ------------------------------------------------------------------ 2 agents
    w("## 2. What the agents repeat by hand")
    w("")
    w(f"{sc['bash_calls']:,} Bash calls, {sc['sessions']:,} sessions, {sc['distinct_patterns']:,} distinct patterns; "
      f"{sc['glue_segments']:,} of {sc['segments']:,} command segments are shell glue and left out of the rankings. "
      "Lanes: " + ", ".join(f"{l['lane']} {l['calls']:,} calls / {l['sessions']:,} sessions" for l in ag["lanes"]) + ".")
    w("")
    w("### Top 20 patterns by calls")
    w("")
    rows = []
    for i, r in enumerate(ag["top_patterns_overall"][:20], 1):
        fp = f"{r['fail_pct']}" if (r["primary_calls"] or 0) >= 100 and r["fail_pct"] is not None else "-"
        rows.append([i, f"`{esc(r['pattern'])}`", r["kind"], f"{r['calls']:,}", f"{r['sessions']:,}", f"{r['top_lane']} {round(100 * (r['top_lane_share'] or 0))} %", fp, r["wall_h"], r["p50_s"], r["p90_s"]])
    w(md_table(["#", "pattern", "kind", "calls", "sessions", "top lane", "fail % (as last command)", "wall h", "p50 s", "p90 s"], rows))
    w("")
    w("### Top 20 action patterns (inspection and glue removed)")
    w("")
    rows = []
    for i, r in enumerate(ag["top_action_patterns"][:20], 1):
        fp = f"{r['fail_pct']}" if (r["primary_calls"] or 0) >= 100 and r["fail_pct"] is not None else "-"
        rows.append([i, f"`{esc(r['pattern'])}`", r["kind"], f"{r['calls']:,}", f"{r['sessions']:,}", fp, r["wall_h"], r["p90_s"], r["calls_over_120s"]])
    w(md_table(["#", "pattern", "kind", "calls", "sessions", "fail % (as last command)", "wall h", "p90 s", "calls > 120 s"], rows))
    w("")
    rp = ag["recurring_patterns"]
    w(f"Recurring patterns (present in at least {rp['min_sessions']} sessions): {rp['patterns']:,} of {rp['of_distinct']:,} distinct patterns, covering "
      f"{round(100 * (rp['share_of_pattern_occurrences'] or 0))} % of all pattern occurrences. The ten with the widest spread (action patterns):")
    w("")
    rows = [[f"`{esc(r['pattern'])}`", r["kind"], f"{r['sessions']:,}", f"{r['calls']:,}"] for r in ag["top_by_sessions"][:10]]
    w(md_table(["pattern", "kind", "sessions", "calls"], rows))
    w("")
    w("### Where the time goes (tool wall hours, top 8)")
    w("")
    rows = [[f"`{esc(r['pattern'])}`", f"{r['wall_h']}", f"{r['calls']:,}", r["p50_s"], r["p90_s"], r["wall_h_over_120s"]] for r in ag["top_by_wall_hours"][:8]]
    w(md_table(["pattern", "wall h", "calls", "p50 s", "p90 s", "h in calls > 120 s"], rows))
    w("")
    w("### Per repo (top 10 by calls; IuRoot repos by name, tool-level only)")
    w("")
    rows = []
    for r in ag["per_repo"][:10]:
        if r["iu_repo"]:
            desc = "tools: " + ", ".join(f"{t['tool']} {t['calls']:,}" for t in r["top_tools"][:5])
        else:
            desc = ", ".join(f"`{esc(p['pattern'])}` {p['calls']:,}" for p in r["top_patterns"][:5])
        rows.append([f"`{r['repo']}`" + (" (IU)" if r["iu_repo"] else ""), f"{r['calls']:,}", f"{r['sessions']:,}", desc])
    w(md_table(["repo", "calls", "sessions", "top patterns"], rows))
    w("")
    fl = ag["failures"]
    w("### Failures, retries and refusals")
    w("")
    w(f"- {fl['failing_calls_non_benign']:,} calls failed (non-zero exit, excluding grep no-match and similar); {sc['benign_nonzero_exits']:,} further non-zero exits are normal. "
      "Most common failure classes: " + ", ".join(f"{c['class']} {c['calls']} ({c['sessions']} sessions)" for c in ag["failure_classes"][:6]) + ".")
    ch = fl["chain_lengths"]
    w(f"- Retries: {fl['retry_links']} failing calls were followed by a re-run of the same action ({fl['retry_exact_command']} the exact same command, "
      f"{fl['retry_without_edit_between']} with no edit in between, {fl['retry_after_edit']} after an edit); {fl['retry_next_attempt_ok']} succeeded on the next attempt. "
      "Loops: " + ", ".join(f"{v['chains']} chains of {k} attempts ({v['ended_ok']} ended ok)" for k, v in ch.items()) +
      f". The blind retries cost {fl['blind_retry_cycle_h']} agent hours in total.")
    rows = [[f"`{esc(r['pattern'])}`", r["retried"], r["exact_command"], r["blind"], r["after_edit"], r["sessions"]] for r in fl["top_retried"][:8]]
    w("")
    w(md_table(["pattern re-run after failing", "retries", "exact command", "no edit between", "after an edit", "sessions"], rows))
    w("")
    rows = [[esc(b["reason"]), b["calls"], b["sessions"], b["agent_gap_h"], ", ".join(b["top_repos"])] for b in ag["blocked_calls"][:10]]
    w(md_table(["refused by", "calls", "sessions", "agent h to next call", "top repos"], rows))
    w("")

    w("### Call groups behind the candidates (disjoint: a call joins the first matching group)")
    w("")
    rows = [[f"`{k}`", f"{v['calls']:,}", f"{v['sessions']:,}", v["agent_step_h"], v["tool_wall_h"], v["failed"], ", ".join(v["top_repos"])]
            for k, v in sorted(ag["call_groups"].items(), key=lambda kv: (-kv[1]["agent_step_h"], kv[0]))]
    w(md_table(["group", "calls", "sessions", "agent step h", "tool wall h", "failed", "top repos"], rows))
    w("")
    wt = ag["waiting_and_delegation_tools"]
    w(f"Agent step time is the time from one Bash call to the next ({ag['turn_time']['total_agent_step_h']:,} h in total, median turn {ag['turn_time']['median_s']} s); "
      "it includes waiting inside the call, which is why polling groups look large. Only removable turns are claimed in section 6. "
      f"For comparison, the proper waiting tools were called {wt.get('Monitor', 0):,} times (`Monitor`), {wt.get('job_wait (mcp)', 0):,} times (gateway `job_wait`) and "
      f"{wt.get('ScheduleWakeup', 0):,} times (`ScheduleWakeup`), against {ag['call_groups'].get('poll:sleep', {}).get('calls', 0) + ag['call_groups'].get('blocked:sleep-then-command', {}).get('calls', 0):,} "
      f"`sleep` calls and {ag['call_groups'].get('poll:shell-loop', {}).get('calls', 0):,} shell polling loops.")
    w("")

    # ------------------------------------------------------------------ 3 recipes
    w("## 3. Recurring recipes (same 3-5 patterns in at least 5 sessions)")
    w("")
    rc = ag["recipes"]
    w(f"{rc['frequent_ngrams_3_to_5']:,} frequent 3-5-grams, {rc['maximal_kept']:,} maximal after dropping sub-sequences. Top by sessions x (length - 1):")
    w("")
    rows = []
    for r in rc["top"][:15]:
        rows.append([f"`{esc(' > '.join(r['sequence']))}`", r["sessions"], r["occurrences"], r["median_calls_spanned"], r["median_span_s"]])
    w(md_table(["sequence", "sessions", "occurrences", "median calls spanned", "median span s"], rows))
    w("")
    w("A median of 1 call means the agent already chains the steps in one Bash call: a verb would save tokens, not turns. "
      "Sequences that really span several calls:")
    w("")
    rows = [[f"`{esc(' > '.join(r['sequence']))}`", r["sessions"], r["occurrences"], r["occurrences_over_several_calls"], r["median_calls_spanned"], r["median_span_s"]]
            for r in rc["top_over_several_calls"][:10]]
    w(md_table(["sequence", "sessions", "occurrences", "over several calls", "median calls spanned", "median span s"], rows))
    w("")
    ex = rc["extra_calls_on_consecutive_steps"]
    w(f"Extra calls spent on consecutive steps of one kind (distinct calls in a run minus one): {ex.get('verify', 0):,} on verification (`bun test`, `bunx oxfmt`, typecheck, lint, build) "
      f"and {ex.get('commit', 0):,} on git add / commit / push / `gh pr create`.")
    w("")

    # ------------------------------------------------------------------ 4 warden
    w("## 4. Recurring warden item families (the toil the loop repeats)")
    w("")
    w(f"{fn['items']} items ({fn['items_30d']} in 30 days), {fn['duplicate_rows']} duplicate rows; {fn['items_needing_agent_job']} items needed an agent job "
      f"({fn['agent_jobs']:,} jobs, {fn['agent_minutes'] / 60:,.0f} agent hours); {fn['escalated_items']} escalated, {fn['owner_touch_items']} owner-touched. "
      f"Families with at least 3 items (or 2 in 30 days): {wd['recurring_family_count']}, covering {round(100 * (wd['recurring_items_share'] or 0))} % of items. "
      f"One-off families: {wd['one_off_families']['families']} ({wd['one_off_families']['items']} items). "
      "`human:` and `github_go: issue` rows are intake (owner or agent briefs), listed for scale, not toil.")
    w("")
    rows = []
    for r in wd["recurring_families"][:20]:
        rows.append([f"`{esc(r['family'])}`", r["items"], r["items_30d"], r["duplicates"], esc(fmt_outcomes(r["outcomes"])),
                     f"{r['items_needing_agent_job']} ({round(100 * (r['share_needing_agent_job'] or 0))} %)", r["agent_jobs"], r["agent_minutes"], r["escalated_items"], r["owner_touch_items"]])
    w(md_table(["family", "items", "30 d", "dup rows", "outcomes", "needed an agent job", "jobs", "agent min", "escalated", "owner touch"], rows))
    w("")

    # ------------------------------------------------------------------ 5 human queue
    w("## 5. Human-queue asks by kind")
    w("")
    w(f"{hq['asks']} asks since 2026-08-07 ({hq['asks_30d']} in the last 30 days): " + ", ".join(f"{n} {k}" for k, n in hq["status"].items()) +
      f". {hq['retry_asks']} asks are retries of an earlier failed ask. Failure causes: " + ", ".join(f"{k} {n}" for k, n in hq["failure_causes"].items()) + ".")
    w("")
    rows = []
    for k in hq["kinds"]:
        st = k["status"]
        rows.append([f"`{k['kind']}`", k["asks"], k["asks_30d"], st.get("done", 0), st.get("failed", 0), st.get("denied", 0) + st.get("superseded", 0), k["retry_asks"],
                     esc(", ".join(f"{a} {b}" for a, b in k["failure_causes"].items()) or "-")])
    w(md_table(["kind", "asks", "30 d", "done", "failed", "denied / superseded", "retry asks", "failure causes"], rows))
    w("")

    # ------------------------------------------------------------------ 6 candidates
    w("## 6. Candidate automation")
    w("")
    w("Ranked by value hours = owner hours + 0.2 x agent hours (an agent hour is worth a fifth of an owner hour: agents run in parallel and cost "
      "quota, the owner's attention is the scarce resource). Both hour columns are always shown. Owner minutes per ask (3), per escalation (6), "
      "per resume (45 s) and per reset (3 s) are assumptions. Agent hours are removed calls x the measured median turn of "
      f"{ag['turn_time']['median_s']} s (waiting time that would remain is not claimed; the measured step time is quoted as an upper bound where it differs), "
      "or warden job minutes where a loop investigation disappears. Shares removed are stated per row.")
    w("")
    rows = []
    for c in cands:
        rows.append([c["id"], esc(c["pattern"]), esc(c["frequency_30d"]), esc(c["who_repeats"]), esc(c["mechanism"]),
                     c["owner_h_per_month"], c["agent_h_per_month"], esc(c["arithmetic"])])
    w(md_table(["id", "pattern", "frequency (30 d)", "who repeats it", "mechanism", "owner h / month", "agent h / month", "arithmetic"], rows))
    w("")
    notes = [f"- {c['id']}: {esc(c['note'])}" for c in cands if c["note"] and not re.fullmatch(r"\d+ % is an assumption", c["note"])]
    w("Every share removed (50 to 100 %) is an assumption stated in the row's arithmetic; the rows are disjoint (owner asks by kind, warden families by "
      "name predicate, agent calls by first matching group), so the hours add up.")
    w("")
    if notes:
        L.extend(notes)
        w("")
    tot_o = sum(c["owner_h_per_month"] for c in cands)
    tot_a = sum(c["agent_h_per_month"] for c in cands)
    w(f"Sum over all rows: {tot_o:.1f} owner hours and {tot_a:.1f} agent hours per month.")
    w("")

    # ------------------------------------------------------------------ caveats
    w("## 7. Caveats")
    w("")
    iw = ", ".join(f"{src} {v['window_check']['implied_window_days_upper_bound']:g} days" for src, v in oh["sources"].items()
                   if v.get("window_check", {}).get("implied_window_days_upper_bound"))
    w("- Shell histories carry no timestamps; per-month figures assume a 30-day window. Launches in the history against sessions in the transcripts give an upper bound "
      f"for the real window ({iw or 'not available'}), so the monthly owner figures are upper bounds too (divide by 1.3 to 1.5 for the longer window).")
    w("- `ran_at` in the human-queue is stamped when the dialog is shown, so owner response time is not measurable; owner minutes per ask are an assumption.")
    w("- The mini history mixes hand-typed commands with lines that rd/herdr type into panes; the latter are separated by prefix and counted apart.")
    w("- A failing call is attributed to its last non-glue command; `fail %` is shown only for patterns that are the last command in at least 100 calls.")
    w("- Warden families come from rule-based title normalisation; a title the rules do not know falls into `<source>: <first words>` and is a one-off.")
    w("- Skill launches and typed slash commands are distinct records: this Claude Code version stores owner-typed skill commands as a skill expansion, so the `<command-name>` table holds mostly built-ins and `/loop`.")
    if not all(v.get("status", "").startswith("ok") for v in oh["sources"].values()):
        w("- At least one history source was unavailable at run time; its rows are missing from sections 1 and 6.")
    w("")
    w("## Reproduce")
    w("")
    w("`cd` to this directory and run `python3 -I toil.py` (about 20 s; transcripts, `warden.db` and `human-queue/` are read from the frozen snapshots and the 30-day transcript window). "
      "The two shell-history aggregates `history-mini.agg.json` and `history-iumac.agg.json` are frozen on the first successful read, because zsh history is a rolling file without timestamps and the "
      "IU MacBook is only reachable when it is awake; delete one (or set `TOIL_REFRESH_HISTORY`) to re-read it. They hold normalised patterns and counts only.")
    w("")
    return "\n".join(L)


def main():
    t0 = time.time()
    mf = os.environ.get("TOIL_MAX_FILES")
    log("scanning transcripts")
    agg = scan.scan(AS_OF, days=WINDOW_DAYS, workers=WORKERS, max_files=int(mf) if mf else None)
    ag = agent_section(agg)
    oh = owner_history_section(len(agg["lane_sessions"]["interactive"]))
    wd = warden_section()
    hq = human_queue_section()
    cands = build_candidates(oh, ag, wd, hq)
    out = scrub(build_output(oh, ag, wd, hq, cands, agg))
    with open(os.path.join(OUT_DIR, "toil.out.json"), "w", encoding="utf-8") as fh:
        json.dump(out, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    md = redact(render_md(out))
    with open(os.path.join(OUT_DIR, "toil.md"), "w", encoding="utf-8") as fh:
        fh.write(md + "\n")
    log(f"wrote toil.out.json and toil.md in {time.time() - t0:.0f}s")


if __name__ == "__main__":
    main()
