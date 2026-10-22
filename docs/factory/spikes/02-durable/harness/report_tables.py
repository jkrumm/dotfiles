#!/usr/bin/env python3
"""Render the report tables from results/<full|fast>/results.json (so no number is typed by hand).

Usage: report_tables.py [full|fast]
"""
import json
import statistics
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
mode = sys.argv[1] if len(sys.argv) > 1 else "full"
D = json.loads((ROOT / "results" / mode / "results.json").read_text())
RUNS = D["runs"]


def sel(opt, test):
    return [r for r in RUNS if r["option"] == opt and r["test"] == test]


def stat(xs, nd=1):
    xs = [x for x in xs if x is not None]
    if not xs:
        return "-"
    return f"{statistics.median(xs):.{nd}f} / {max(xs):.{nd}f}"


def flows(rs):
    return [fm for r in rs for fm in r["flows"].values()]


def row(opt, test, note_fn=None):
    rs = sel(opt, test)
    if not rs:
        return None
    ctl = test.endswith("nokey")
    dup = sum(fm["duplicates"] for fm in flows(rs))
    miss = sum(fm["missing"] for fm in flows(rs))
    rec = [x for fm in flows(rs) for x in fm["recovery_s"]]
    rdy = [lp["ready_s"] for r in rs for lp in r["loops"][1:]]
    ok = "control" if ctl else f"{sum(bool(r['pass']) for r in rs)}/{len(rs)}"
    note = note_fn(rs) if note_fn else ""
    return f"| {test} | {opt.upper()} | {len(rs)} | {ok} | {dup} | {miss} | {stat(rec, 2)} | {stat(rdy, 2)} | {note} |"


def n_a(rs):
    return f"implement episode kept running and re-attached: {sum(fm['episodes']['implement']['attempts'] == 1 for fm in flows(rs))}/{len(rs)}; extra episode launches {sum(fm['episodes']['implement']['attempts'] - 1 for fm in flows(rs))}"


def n_b(rs):
    return f"calls replayed by the key: {sum(fm['replayed_calls'] for fm in flows(rs))}; runs with a duplicate: {sum(fm['duplicates'] > 0 for fm in flows(rs))}/{len(rs)}"


def n_c(rs):
    src = {}
    for fm in flows(rs):
        k = (fm["decided_by"], fm["decision"])
        src[k] = src.get(k, 0) + 1
    late = [d["late_s"] for fm in flows(rs) for d in fm["decision_taken"] if d["by"] == "default"]
    after = [fm.get("decision_after_restart_s") for fm in flows(rs)]
    s = ", ".join(f"{k[0]}:{k[1]} x{v}" for k, v in sorted(src.items(), key=str))
    if late:
        s += f"; default taken late_s med/max {stat(late, 2)}"
    if any(a is not None for a in after):
        s += f"; decision taken {stat(after, 1)} s after restart"
    return s


def n_d(rs):
    det = [r.get("redrive_detect_s") for r in rs]
    lost = [r["marks"].get("lost_partial_unit_s") for r in rs]
    kinds = ",".join(sorted({r.get("kill_kind", "?") for r in rs}))
    resumed = sum(all(v for k, v in r["checks"].items() if k.endswith("resumed_not_restarted")) for r in rs)
    return f"killed episodes: {kinds}; re-drive detected {stat(det, 1)} s after the kill; in-flight unit wasted {stat(lost, 1)} s; resumed from session, no finished unit redone: {resumed}/{len(rs)}"


def n_e(rs):
    by = {}
    for r in rs:
        by.setdefault(r["phase"], []).append(bool(r["pass"]))
    redr = [fm.get("redrive_after_kill_s") for fm in flows(rs)]
    return "phases " + ", ".join(f"{k}:{'ok' if all(v) else 'FAIL'}" for k, v in by.items()) + f"; episode re-drive {stat(redr, 1)} s after kill"


def n_f(rs):
    late = [x for fm in flows(rs) for x in fm["timers"]["late_s"]]
    return f"overlapping slot intervals: {sum(r['mutex_violations'] for r in rs)}; early timer calls: {sum(fm['timers']['early_calls'] for fm in flows(rs))}; timer lateness {stat(late, 2)} s"


def n_g(rs):
    rec = sum(bool(r.get("recovered_without_rescue")) for r in rs)
    resc = sorted({r.get("rescue") for r in rs if r.get("rescue")})
    s = f"recovered with no operator action: {rec}/{len(rs)}"
    if resc:
        s += "; rescue needed: " + ", ".join(resc)
    st = sorted({r.get("dbos_status") for r in rs if r.get("dbos_status")})
    if st:
        s += f"; engine status {','.join(st)}"
    return s


def n_h(rs):
    k = [x for r in rs for x in r.get("kills", [])]
    redr = sum(fm["episodes"][e]["redrive_events"] for fm in flows(rs) for e in ("investigate", "implement"))
    return f"{len(k)} kills ({sum(x['scope'] == 'machine' for x in k)} whole-machine, {sum(x['scope'] == 'loop' for x in k)} loop-only); episode re-drives {redr}"


NOTES = {"a": n_a, "b": n_b, "b_nokey": n_b, "b_deploy": n_b, "c1": n_c, "c2": n_c, "c3": n_c, "c4": n_c, "c5": n_c, "c5s": n_c, "d": n_d, "e": n_e, "f": n_f, "g": n_g, "g_pinned": n_g, "g_break": n_g, "h": n_h}
print("| Test | Opt | Runs | Pass | Dup. | Missing | Recovery to first live action med/max (s) | Process ready med/max (s) | Measured |")
print("|-|-|-|-|-|-|-|-|-|")
for t in ["happy", "a", "b", "b_nokey", "b_deploy", "c1", "c2", "c3", "c4", "c5", "c5s", "d", "e", "f", "h", "g", "g_pinned", "g_break"]:
    for o in ("a", "b"):
        line = row(o, t, NOTES.get(t))
        if line:
            print(line)

print()
print("Footprint at the first kill (loop process) and ledger/engine DB at the end of the run:")
print("| Opt | loop RSS MB med/max | threads med/max | DB tables | DB bytes incl. WAL med/max | rows per flow (all tables) med/max |")
print("|-|-|-|-|-|-|")
for o in ("a", "b"):
    rs = [r for r in RUNS if r["option"] == o and r.get("db") and r["marks"].get("footprint_loop") and len(r["flows"]) == 1]
    rss = [r["marks"]["footprint_loop"]["rss_mb"] for r in rs]
    thr = [r["marks"]["footprint_loop"]["threads"] for r in rs]
    rows = [sum(r["db"]["rows"].values()) for r in rs]
    size = [r["db"]["bytes_incl_wal"] for r in rs]
    print(f"| {o.upper()} | {stat(rss)} | {stat(thr, 0)} | {rs[0]['db']['tables'] if rs else '-'} | {stat(size, 0)} | {stat(rows, 0)} |")

print()
print("Dashboard derivation while the loop is dead (status script, read-only):")
print("| Opt | runs with a snapshot at kill | status script latency ms med/max |")
print("|-|-|-|")
for o in ("a", "b"):
    sn = [r["snapshots"]["at_kill"] for r in RUNS if r["option"] == o and r["snapshots"].get("at_kill")]
    print(f"| {o.upper()} | {sum(s['ok'] for s in sn)}/{len(sn)} | {stat([s['ms'] for s in sn], 0)} |")
