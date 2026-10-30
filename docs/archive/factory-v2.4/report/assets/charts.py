#!/usr/bin/env python3
"""Render the factory design report charts as self-contained SVGs.

Run:  python3 -I charts.py

Every number is read from ../../evidence/**/*.out.json (and, for the ideal-path
page counts, the closing table of evidence/incidents/incidents.md, which has no
JSON twin). Output is deterministic: no timestamps, no randomness, sorted inputs.
Light/dark come from prefers-color-scheme CSS inside each SVG.
"""
import json
import re
import sys
from datetime import datetime
from html import escape
from pathlib import Path

HERE = Path(__file__).resolve().parent
EVID = HERE.parent.parent / "evidence"
NOTES = []  # data inconsistencies, printed to stderr


def load(rel):
    return json.loads((EVID / rel).read_text())


def note(msg):
    NOTES.append(msg)


def ts(s):
    return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ")


# ---------------------------------------------------------------- svg kit

STYLE = """
:root{--bg:#f2f2f5;--t1:#18181b;--t2:#4c4c55;--tm:#62626b;--grid:#dcdce2;--axis:#b0b0ba;
--s1:#2a78d6;--s2:#eb6834;--s3:#1baf7a;--s4:#eda100}
@media (prefers-color-scheme:dark){:root{--bg:#1f1f23;--t1:#f4f4f5;--t2:#c4c4cc;--tm:#8e8e98;
--grid:#34343a;--axis:#4c4c54;--s1:#3987e5;--s2:#d95926;--s3:#199e70;--s4:#c98500}}
text{font-family:system-ui,-apple-system,"Segoe UI",sans-serif;fill:var(--t1)}
.bg{fill:var(--bg)}.ttl{font-size:19px;font-weight:600}.sub{font-size:12.5px;fill:var(--t2)}
.lbl{font-size:12px;fill:var(--t2)}.val{font-size:12px;font-weight:600}.tick{font-size:11px;fill:var(--tm)}
.src{font-size:11px;fill:var(--tm)}.ax{font-size:12px;fill:var(--t2)}.hd{font-size:12.5px;font-weight:600}
.grid{stroke:var(--grid);stroke-width:1;fill:none}.axis{stroke:var(--axis);stroke-width:1;fill:none}
.tgt{stroke:var(--t1);stroke-width:1.5;stroke-dasharray:6 4;fill:none}
.tgt2{stroke:var(--t1);stroke-width:1.5;stroke-dasharray:2 3;fill:none}
.gap{stroke:var(--bg);stroke-width:2}
.f1{fill:var(--s1)}.f2{fill:var(--s2)}.f3{fill:var(--s3)}.f4{fill:var(--s4)}
.ghost{fill:var(--s1);fill-opacity:.2;stroke:var(--s1);stroke-width:1.5;stroke-dasharray:4 3}
.hollow{fill:none;stroke:var(--t2);stroke-width:1.5;stroke-dasharray:3 3}
"""


def fmt(v, d=1):
    return f"{v:,.{d}f}"


class Svg:
    def __init__(self, w, h, title, desc):
        self.w, self.h = w, h
        self.title, self.desc = title, desc
        self.parts = []

    def add(self, s):
        self.parts.append(s)

    def text(self, x, y, s, cls="lbl", anchor="start", extra=""):
        self.add(f'<text x="{x:.1f}" y="{y:.1f}" class="{cls}" text-anchor="{anchor}" {extra}>{escape(str(s))}</text>')

    def line(self, x1, y1, x2, y2, cls="grid"):
        self.add(f'<line x1="{x1:.1f}" y1="{y1:.1f}" x2="{x2:.1f}" y2="{y2:.1f}" class="{cls}"/>')

    def hbar(self, x, y, w, h, cls, tip, rounded=True, gap=False):
        """Horizontal bar anchored left at x; right (data) end rounded."""
        if w <= 0:
            return
        r = min(4, w / 2, h / 2) if rounded else 0
        d = (f"M{x:.1f} {y:.1f}H{x + w - r:.1f}a{r:.1f} {r:.1f} 0 0 1 {r:.1f} {r:.1f}V{y + h - r:.1f}"
             f"a{r:.1f} {r:.1f} 0 0 1 -{r:.1f} {r:.1f}H{x:.1f}Z")
        g = " gap" if gap else ""
        self.add(f'<g><title>{escape(tip)}</title><path d="{d}" class="{cls}{g}"/></g>')

    def vbar(self, x, y, w, h, cls, tip, rounded=True, gap=False):
        """Vertical bar anchored to the baseline at y+h; top (data) end rounded."""
        if h <= 0:
            return
        r = min(4, w / 2, h / 2) if rounded else 0
        d = (f"M{x:.1f} {y + h:.1f}V{y + r:.1f}a{r:.1f} {r:.1f} 0 0 1 {r:.1f} -{r:.1f}H{x + w - r:.1f}"
             f"a{r:.1f} {r:.1f} 0 0 1 {r:.1f} {r:.1f}V{y + h:.1f}Z")
        g = " gap" if gap else ""
        self.add(f'<g><title>{escape(tip)}</title><path d="{d}" class="{cls}{g}"/></g>')

    def header(self, title, subtitle):
        self.text(24, 34, title, "ttl")
        for i, s in enumerate(subtitle if isinstance(subtitle, list) else [subtitle]):
            self.text(24, 56 + 17 * i, s, "sub")

    def legend(self, x, y, items):
        for cls, label in items:
            self.add(f'<rect x="{x:.1f}" y="{y - 10:.1f}" width="12" height="12" rx="3" class="{cls}"/>')
            self.text(x + 18, y, label, "lbl")
            x += 18 + 7 * len(label) + 22

    def source(self, lines):
        for i, s in enumerate(lines):
            self.text(24, self.h - 14 - 15 * (len(lines) - 1 - i), s, "src")

    def render(self):
        ident = re.sub(r"\W+", "-", self.title.lower())[:40]
        return (
            f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {self.w} {self.h}" width="{self.w}" '
            f'height="{self.h}" role="img" aria-labelledby="{ident}-t {ident}-d">\n'
            f'<title id="{ident}-t">{escape(self.title)}</title>\n<desc id="{ident}-d">{escape(self.desc)}</desc>\n'
            f"<style>{STYLE}</style>\n"
            f'<rect class="bg" width="{self.w}" height="{self.h}"/>\n' + "\n".join(self.parts) + "\n</svg>\n"
        )


def write(name, svg):
    (HERE / name).write_text(svg.render())


def ticks_v(s, x0, x1, ybase, ytop, vmax, step, unit=""):
    """Horizontal gridlines + left tick labels for a vertical-bar chart."""
    v = 0
    while v <= vmax + 1e-9:
        y = ybase - (ybase - ytop) * v / vmax
        s.line(x0, y, x1, y, "axis" if v == 0 else "grid")
        s.text(x0 - 8, y + 4, f"{v:g}{unit}", "tick", "end")
        v += step


def ticks_h(s, x0, x1, ytop, ybase, vmax, step, unit=""):
    """Vertical gridlines + bottom tick labels for a horizontal-bar chart."""
    v = 0
    while v <= vmax + 1e-9:
        x = x0 + (x1 - x0) * v / vmax
        s.line(x, ytop, x, ybase, "axis" if v == 0 else "grid")
        s.text(x, ybase + 16, f"{v:g}{unit}", "tick", "middle")
        v += step


# ---------------------------------------------------------------- 1 quota

def chart_quota():
    q = load("kpi/quota.out.json")
    ep = load("kpi/engine_policy.out.json")
    add = ep["weekly_window_pct_if_on_max"]
    cycles = [c for c in q["weekly_cycles"] if not c["partial"]]
    skipped = len(q["weekly_cycles"]) - len(cycles)
    w, h = 940, 520
    s = Svg(w, h, "Max 7-day utilisation: weekly peaks vs the 90 % line, and with agent-gateway's OpenCode load added",
            f"Bar chart of {len(cycles)} complete weekly quota cycles. Peaks: "
            + ", ".join(f"{ts(c['start']).strftime('%b %d')} {c['peak_7d']} %" for c in cycles)
            + f". A dashed ghost segment adds {add} percentage points to each peak (the OpenCode workload moved onto Max); "
            f"{sum(1 for c in cycles if c['peak_7d'] + add >= 90)} of {len(cycles)} cycles would reach 90 % or more "
            f"(observed: {sum(1 for c in cycles if c['peak_7d'] >= 90)}).")
    s.header("Max 7-day utilisation: weekly peaks, today and with OpenCode on Max",
             [f"Solid = observed peak. Dashed ghost = peak + {add} pp (agent-gateway's OpenCode workload, weekly window share).",
              f"{len(cycles)} complete cycles; {skipped} partial cycle(s) skipped. Line = 90 %."])
    x0, x1, ytop, ybase, vmax = 70, 910, 112, 400, 130
    ticks_v(s, x0, x1, ybase, ytop, vmax, 25, " %")
    s.text(18, (ytop + ybase) / 2, "7-day utilisation, peak of cycle (%)", "ax", "middle",
           f'transform="rotate(-90 18 {(ytop + ybase) / 2})"')
    slot = (x1 - x0) / len(cycles)
    bw = 56

    def y_of(v):
        return ybase - (ybase - ytop) * v / vmax

    for i, c in enumerate(cycles):
        cx = x0 + slot * i + (slot - bw) / 2
        p = c["peak_7d"]
        days = (ts(c["end"]) - ts(c["start"])).total_seconds() / 86400
        # ghost on top of the observed bar
        top = y_of(p + add)
        s.add(f'<g><title>{escape(f"{p} % + {add} pp projected = {p + add:.1f} %")}</title>'
              f'<rect x="{cx:.1f}" y="{top:.1f}" width="{bw}" height="{y_of(p) - top:.1f}" rx="4" class="ghost"/></g>')
        s.vbar(cx, y_of(p), bw, ybase - y_of(p), "f1",
               f"{ts(c['start']).strftime('%Y-%m-%d')}: peak {p} %, {c['hours_ge_90']} h at or above 90 %", gap=True)
        s.text(cx + bw / 2, top - 7, f"{p} → {p + add:.0f}", "val", "middle")
        s.text(cx + bw / 2, ybase + 17, ts(c["start"]).strftime("%b %d"), "lbl", "middle")
        s.text(cx + bw / 2, ybase + 31, f"{days:.1f} d", "tick", "middle")
    ytgt = y_of(90)
    s.line(x0, ytgt, x1, ytgt, "tgt")
    s.text(x1, ytgt - 6, "90 %", "hd", "end")
    s.text((x0 + x1) / 2, ybase + 52, "Cycle start (weekly reset or early reset), cycle length in days below", "ax", "middle")
    s.legend(x0, 92, [("f1", "Observed peak"), ("ghost", f"+ OpenCode load ({add} pp)")])
    short = sum(1 for c in cycles if (ts(c["end"]) - ts(c["start"])).total_seconds() < 6.5 * 86400)
    if short:
        note(f"quota: {short} of {len(cycles)} complete cycles are shorter than 7 days (early resets), "
             f"yet the full weekly {add} pp is added to each ghost bar (overstates those)")
    s.source(["Source: evidence/kpi/quota.out.json (weekly_cycles), evidence/kpi/engine_policy.out.json (weekly_window_pct_if_on_max).",
              f"{add} pp is a {ep['days']} d measurement, added in full to every cycle (incl. {short} shorter than 7 days)."])
    write("chart-quota.svg", s)


# ---------------------------------------------------------------- 2 attention

def ideal_pages():
    """Parse (id-suffix -> (label, today, ideal_upper_bound)) from the closing table."""
    md = (EVID / "incidents/incidents.md").read_text()
    sect = md.split("## Closing table", 1)[1]
    out = {}
    for line in sect.splitlines():
        if not re.match(r"\|\s*\d+ e\d+", line):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        m = re.search(r"(\d+)\s*→\s*(?:≤\s*)?(\d+)", cells[-2])
        e = re.search(r"\be(\d+)\b", cells[0]).group(1)
        out[e] = (re.sub(r"^\d+\s+", "", cells[0]), int(m.group(1)), int(m.group(2)))
    return out


def chart_attention():
    c = load("incidents/costliest.out.json")
    kinds = c["meta"]["page_totals"]
    total = sum(kinds.values())
    ideal = ideal_pages()
    rows = []
    for iid in c["ranking"]["top10"]:
        inc = c["incidents"][iid]
        e = iid.rsplit("-e", 1)[1]
        label, md_today, ideal_n = ideal[e]
        if md_today != inc["pages"]:
            note(f"attention: {iid} pages {inc['pages']} in costliest.out.json vs {md_today} in incidents.md closing table")
        rows.append((label, inc["pages"], ideal_n))
    rows.sort(key=lambda r: -r[1])
    sum_today, sum_ideal = sum(r[1] for r in rows), sum(r[2] for r in rows)
    w, h = 1040, 600
    s = Svg(w, h, "Owner-facing notifications by kind, and the ten costliest incidents' pages today vs the ideal path",
            f"Left: {total} owner-facing notifications split into decision entries {kinds['decision_entries']}, "
            f"legacy notifications {kinds['legacy_notifications']}, reminders {kinds['reminders']}; "
            f"{(kinds['legacy_notifications'] + kinds['reminders']) / total * 100:.0f} % never went through needs_decision. "
            f"Right: the ten costliest incidents page {sum_today} times today and at most {sum_ideal} times on the ideal path.")
    s.header("Owner attention: notifications by kind, and the ten costliest incidents",
             [f"Left: {total} owner-facing notifications in the ledger, by kind. Right: pages per incident, today vs ideal path "
              f"({sum_today} → at most {sum_ideal}).",
              "Ideal-path pages are the upper bounds of the incident review's own estimates, not measurements."])
    # left: kinds
    lx0, lx1, ly = 150, 400, 130
    names = [("decision_entries", "Decision entries"), ("legacy_notifications", "Legacy notifications"), ("reminders", "Reminders")]
    s.text(24, ly - 14, "Notifications by kind", "hd")
    vmax = 300
    bh, pitch = 26, 52
    ybase = ly + pitch * len(names) - 8
    ticks_h(s, lx0, lx1, ly - 4, ybase, vmax, 100)
    for i, (k, lab) in enumerate(names):
        y = ly + i * pitch
        v = kinds[k]
        s.text(lx0 - 10, y + bh / 2 + 4, lab, "lbl", "end")
        s.hbar(lx0, y, (lx1 - lx0) * v / vmax, bh, "f1", f"{lab}: {v} ({v / total * 100:.0f} % of {total})")
        s.text(lx0 + (lx1 - lx0) * v / vmax + 8, y + bh / 2 + 4, f"{v} ({v / total * 100:.0f} %)", "val")
    s.text((lx0 + lx1) / 2, ybase + 36, "Notifications (count)", "ax", "middle")
    s.text(24, ybase + 70, f"{(kinds['legacy_notifications'] + kinds['reminders']) / total * 100:.0f} % of {total} never went", "lbl")
    s.text(24, ybase + 87, "through needs_decision (legacy + reminders).", "lbl")
    # right: incidents
    rx0, rx1, ry = 640, 1000, 112
    s.text(450, ry - 14, "Pages per incident (ten costliest)", "hd")
    rbh, rpitch = 15, 40
    rbase = ry + rpitch * len(rows) - 6
    vmax2 = 35
    ticks_h(s, rx0, rx1, ry - 6, rbase, vmax2, 5)
    for i, (label, today, ideal_n) in enumerate(rows):
        y = ry + i * rpitch
        s.text(rx0 - 10, y + 17, label, "lbl", "end")
        s.hbar(rx0, y, (rx1 - rx0) * today / vmax2, rbh, "f2", f"{label}: {today} pages today", gap=True)
        s.text(rx0 + (rx1 - rx0) * today / vmax2 + 6, y + 12, str(today), "val")
        s.hbar(rx0, y + rbh + 2, (rx1 - rx0) * ideal_n / vmax2, rbh, "f1",
               f"{label}: at most {ideal_n} page(s) on the ideal path", gap=True)
        s.text(rx0 + (rx1 - rx0) * ideal_n / vmax2 + 6, y + rbh + 14, f"≤ {ideal_n}" if ideal_n else "0", "val")
    s.text((rx0 + rx1) / 2, rbase + 36, "Pages to the owner (count)", "ax", "middle")
    s.legend(450, rbase + 62, [("f2", "Today"), ("f1", "Ideal path (upper bound)")])
    s.source(["Source: evidence/incidents/costliest.out.json (meta.page_totals, ranking.top10, incidents[].pages).",
              "Ideal-path bounds: closing table in evidence/incidents/incidents.md."])
    write("chart-attention.svg", s)


# ---------------------------------------------------------------- 3 signals

def chart_signals():
    sg = load("signals/signals.out.json")
    by = sg["monthly_by_source"]
    excluded = {"human", "warden_canary", "warden_self"}  # owner actions and internal items, not signals
    relay_src = sorted(k for k in by if k.startswith("slack_"))
    direct_src = sorted(k for k in by if k not in excluded and k not in relay_src)
    months = sorted({m for k in by for m in by[k]})
    relay = {m: sum(by[k].get(m, 0) for k in relay_src) for m in months}
    direct = {m: sum(by[k].get(m, 0) for k in direct_src) for m in months}
    asof = sg["meta"]["as_of"]
    share = sum(relay.values()) / (sum(relay.values()) + sum(direct.values())) * 100
    w, h = 920, 500
    s = Svg(w, h, "Signals per month: via Slack relays vs direct to the ledger",
            "Stacked bars per month. " + "; ".join(f"{m}: {relay[m]} relayed, {direct[m]} direct" for m in months)
            + f". Over all months {share:.0f} % of signals arrive via Slack relays.")
    s.header("Signals per month: via Slack relays vs direct",
             [f"Relay = Slack alert and update posts ({', '.join(relay_src)}). Direct = every other intake source "
              f"({len(direct_src)} sources).",
              f"{share:.0f} % of {sum(relay.values()) + sum(direct.values())} signals came through Slack. "
              f"Last month is partial (to {asof[8:10]}th)."])
    x0, x1, ytop, ybase = 70, 880, 112, 400
    vmax = max(relay[m] + direct[m] for m in months)
    vmax = ((vmax // 100) + 1) * 100
    ticks_v(s, x0, x1, ybase, ytop, vmax, 100)
    s.text(18, (ytop + ybase) / 2, "Signals (count, by first timestamp)", "ax", "middle",
           f'transform="rotate(-90 18 {(ytop + ybase) / 2})"')
    slot = (x1 - x0) / len(months)
    bw = 54
    for i, m in enumerate(months):
        cx = x0 + slot * i + (slot - bw) / 2
        hd = (ybase - ytop) * direct[m] / vmax
        hr = (ybase - ytop) * relay[m] / vmax
        if direct[m]:
            s.vbar(cx, ybase - hd, bw, hd, "f2", f"{m}: {direct[m]} direct", rounded=not relay[m], gap=True)
        if relay[m]:
            s.vbar(cx, ybase - hd - hr, bw, hr, "f1", f"{m}: {relay[m]} via Slack relays", gap=True)
        s.text(cx + bw / 2, ybase - hd - hr - 7, f"{relay[m] + direct[m]}", "val", "middle")
        s.text(cx + bw / 2, ybase + 17, datetime.strptime(m, "%Y-%m").strftime("%b %Y") + ("*" if m == months[-1] else ""),
               "lbl", "middle")
    s.text((x0 + x1) / 2, ybase + 42, "Month of first signal timestamp (* partial month)", "ax", "middle")
    s.legend(x0, 92, [("f1", "Via Slack relays"), ("f2", "Direct")])
    s.source([f"Source: evidence/signals/signals.out.json (monthly_by_source); excluded as non-signals: {', '.join(sorted(excluded))}.",
              "Slack-relay share per the ledger: slack_share.share_pct = " + fmt(sg["slack_share"]["share_pct"]) + " % of all events."])
    write("chart-signals.svg", s)


# ---------------------------------------------------------------- 4 questions

def chart_questions():
    qd = load("questions/questions.out.json")
    top = sorted(qd["questions"], key=lambda x: (-x["count"], x["id"]))[:15]
    for x in top:
        if x["count_last_14d"] + x["count_prior_31d"] != x["count"]:
            note(f"questions: {x['id']} count {x['count']} != last_14d + prior_31d "
                 f"({x['count_last_14d'] + x['count_prior_31d']})")
    w, h = 960, 640
    s = Svg(w, h, "Top 15 owner questions by count, last 14 days vs earlier",
            "Horizontal stacked bars. " + "; ".join(
                f"{x['id'].replace('_', ' ')}: {x['count_last_14d']} in the last 14 days, {x['count_prior_31d']} earlier" for x in top))
    s.header("Top 15 owner questions: last 14 days vs earlier",
             [f"{sum(x['count'] for x in top)} asks across {qd['totals']['classified_messages']} classified owner messages "
              f"({qd['totals']['owner_messages']} total).",
              "Earlier = the 31 days before the last 14. * = implied question (the owner typed a statement, not a question)."])
    lx, x1, ytop = 215, 880, 112
    vmax = 50
    pitch, bh = 30, 20
    ybase = ytop + pitch * len(top)
    ticks_h(s, lx, x1, ytop - 6, ybase, vmax, 10)
    for i, x in enumerate(top):
        y = ytop + i * pitch
        name = x["id"].replace("_", " ") + ("*" if x["kind"] == "statement" else "")
        s.text(lx - 10, y + bh / 2 + 4, name, "lbl", "end")
        sc = (x1 - lx) / vmax
        a, b = x["count_last_14d"], x["count_prior_31d"]
        s.hbar(lx, y, sc * a, bh, "f1", f"{name}: {a} in the last 14 days", rounded=not b, gap=True)
        s.hbar(lx + sc * a, y, sc * b, bh, "f2", f"{name}: {b} in the 31 days before", gap=True)
        s.text(lx + sc * x["count"] + 8, y + bh / 2 + 4, f"{x['count']}  ({a} | {b})", "val")
    s.text((lx + x1) / 2, ybase + 36, "Owner asks (count)", "ax", "middle")
    s.legend(lx, ybase + 64, [("f1", "Last 14 days"), ("f2", "Earlier (31 days before)")])
    s.source(["Source: evidence/questions/questions.out.json (questions[].count, count_last_14d, count_prior_31d)."])
    write("chart-questions.svg", s)


# ---------------------------------------------------------------- 5 drift

def chart_drift():
    d = load("postmortem/drift.out.json")
    claims = [c for m in d["models"] for c in m["claims"]]
    order = [("prose", "f1", "Prose (a doc or prompt asserts it)"), ("changed_on_purpose", "f2", "Changed on purpose"),
             ("enforced", "f3", "Enforced (code or a tool runs it)"), ("cross_repo", "f4", "Cross-repo")]
    classes = {c["cause_class"] for c in claims}
    if classes - {o[0] for o in order}:
        note(f"drift: unplotted cause classes {sorted(classes - {o[0] for o in order})}")
    for c in claims:
        if c.get("holds_at_lock") is None and c.get("days_from_lock") is not None:
            note(f"drift: {c['id']} has holds_at_lock=null but days_from_lock={c['days_from_lock']} "
                 f"(days_to_drift={c.get('days_to_drift')})")
        if c.get("born_false") and c.get("holds_at_as_of"):
            note(f"drift: {c['id']} is born_false yet holds_at_as_of=true")
    summ = d["summary"]
    if summ["claims"] != len(claims):
        note(f"drift: summary.claims={summ['claims']} but {len(claims)} claims listed")
    contradicted = sum(1 for c in claims if c.get("days_from_lock") is not None)
    if contradicted != summ["born_false"] + summ["contradicted_after_lock"]:
        note(f"drift: {contradicted} claims carry days_from_lock; summary says born_false {summ['born_false']} + "
             f"contradicted_after_lock {summ['contradicted_after_lock']}")
    pitch, bh, gh = 20, 13, 30
    nblocks = len(order)
    ytop = 116
    h = ytop + pitch * len(claims) + gh * nblocks + 96
    w = 980
    s = Svg(w, h, "Days from lock to first contradiction, per claim, by cause class",
            f"{len(claims)} locked claims in four cause classes. "
            + "; ".join(f"{cl}: {sum(1 for c in claims if c['cause_class'] == cl)} claims" for cl, _, _ in order)
            + f". Median {summ['median_days_from_lock_to_first_contradiction']} days from lock to first contradiction; "
            f"{summ['held_at_as_of']} claims still hold.")
    s.header("Days from lock to first contradiction, per claim",
             [f"{len(claims)} claims, grouped by cause class. Median {summ['median_days_from_lock_to_first_contradiction']} d; "
              f"{summ['born_false']} born false (0 d); {summ['held_at_as_of']} still hold.",
              "Rows without a bar held through the as-of date."])
    lx, x1 = 330, 920
    vmax = 45
    sc = (x1 - lx) / vmax
    # body height
    y = ytop
    body_top = y - 6
    total_h = pitch * len(claims) + gh * nblocks
    ticks_h(s, lx, x1, body_top, body_top + total_h, vmax, 5)
    s.text((lx + x1) / 2, body_top + total_h + 36, "Days from lock to first contradiction", "ax", "middle")
    for cl, fcls, lab in order:
        grp = sorted((c for c in claims if c["cause_class"] == cl),
                     key=lambda c: (c.get("days_from_lock") is None, c.get("days_from_lock") or 0, c["id"]))
        n_c = sum(1 for c in grp if c.get("days_from_lock") is not None)
        s.add(f'<rect x="24" y="{y + 2:.1f}" width="12" height="12" rx="3" class="{fcls}"/>')
        s.text(42, y + 13, f"{lab}: {len(grp)} claims, {n_c} contradicted", "hd")
        y += gh
        for c in grp:
            dl = c.get("days_from_lock")
            s.text(lx - 10, y + bh / 2 + 4, c["id"], "lbl", "end")
            if dl is None:
                s.text(lx + 6, y + bh / 2 + 4, "held, no contradiction", "tick")
            else:
                bw = max(sc * dl, 0)
                tip = f"{c['id']}: {dl} d from lock to first contradiction" + (" (born false)" if c.get("born_false") else "")
                if dl == 0:
                    s.add(f'<g><title>{escape(tip)}</title><rect x="{lx:.1f}" y="{y:.1f}" width="4" height="{bh}" rx="2" class="{fcls}"/></g>')
                else:
                    s.hbar(lx, y, bw, bh, fcls, tip)
                s.text(lx + bw + 8, y + bh / 2 + 4, f"{dl:g} d" + (" · born false" if c.get("born_false") else ""), "val")
            y += pitch
    s.source(["Source: evidence/postmortem/drift.out.json (models[].claims[].days_from_lock, cause_class, born_false; summary)."])
    write("chart-drift.svg", s)


# ---------------------------------------------------------------- 6 baseline

def chart_baseline():
    b = load("kpi/baseline.out.json")["headline"]
    wins = [("14d", "14 d"), ("30d", "30 d"), ("all", "all")]
    # (title, direction, key, scale, unit, decimals, vmax, step, [(target, cls, label)], target text)
    panels = [
        ("Autonomy", "higher is better", "autonomy_rate", 100, " %", 1, 100, 25,
         [(99, "tgt", "SLO 99 %"), (99.9, "tgt2", "stretch 99.9 %")], "SLO 99 %, stretch 99.9 %"),
        ("Escalated share", "lower is better", "escalated_rate", 100, " %", 1, 40, 10,
         [(1, "tgt", "SLO < 1 %")], "SLO < 1 %"),
        ("Reopen rate", "lower is better", "reopen_rate", 100, " %", 1, 20, 5,
         [(5, "tgt", "≤ 5 %")], "target ≤ 5 %"),
        ("Regression rate", "lower is better", "regression_rate", 100, " %", 1, 20, 5,
         [(5, "tgt", "≤ 5 %")], "target ≤ 5 %"),
        ("Time to resolve, median", "lower is better", "time_to_resolve_median_h", 1, " h", 2, 2, 0.5,
         [(0.5, "tgt", "≤ 0.5 h")], "target ≤ 0.5 h"),
    ]
    n = {k: b[k]["items"] for k, _ in wins}
    w, h = 1120, 520
    s = Svg(w, h, "Baseline KPIs vs targets: autonomy, escalated share, reopen, regression, time to resolve",
            "Five panels, each with three bars for the last 14 days, last 30 days and all time, and the target as a dashed line. "
            + " ".join(
                f"{p[0]}: " + ", ".join(
                    f"{lab} {b[k][p[2]] * p[3]:.{p[5]}f}{p[4]}" if b[k][p[2]] is not None else f"{lab} n/a"
                    for k, lab in wins) + f" (target {p[9]})."
                for p in panels))
    s.header("Baseline vs target: five headline KPIs over 14 d, 30 d and all time",
             [f"Items in window: {n['14d']} (14 d), {n['30d']} (30 d), {n['all']} (all). Dashed line = target. "
              "Regression is only evaluable on all time.", ""])
    gap = 22
    pw = (w - 48 - gap * (len(panels) - 1)) / len(panels)
    ytop, ybase = 150, 380
    for i, (title, direction, key, mult, unit, dec, vmax, step, targets, ttxt) in enumerate(panels):
        px = 24 + i * (pw + gap)
        ax0, ax1 = px + 36, px + pw
        s.text(px, 106, title, "hd")
        s.text(px, 122, direction, "tick")
        s.text(px, 138, f"target: {ttxt}", "tick")
        v = 0
        while v <= vmax + 1e-9:
            y = ybase - (ybase - ytop) * v / vmax
            s.line(ax0, y, ax1, y, "axis" if v == 0 else "grid")
            s.text(ax0 - 6, y + 4, f"{v:g}", "tick", "end")
            v += step
        slot = (ax1 - ax0) / len(wins)
        bw = 30
        for j, (k, lab) in enumerate(wins):
            cx = ax0 + slot * j + (slot - bw) / 2
            val = b[k][key]
            if val is None:
                s.text(cx + bw / 2, ybase - 8, "n/a", "val", "middle")
                if key == "regression_rate":
                    s.text(cx + bw / 2, ybase - 22, f"{b[k]['regression_evaluable_fixes']} fixes", "tick", "middle")
            else:
                v2 = val * mult
                hh = (ybase - ytop) * v2 / vmax
                s.vbar(cx, ybase - hh, bw, hh, "f1", f"{title}, {lab}: {v2:.{dec}f}{unit}")
                s.text(cx + bw / 2, ybase - hh - 6, f"{v2:.{dec}f}", "val", "middle")
            s.text(cx + bw / 2, ybase + 17, lab, "lbl", "middle")
        for tv, tcls, _ in targets:
            y = ybase - (ybase - ytop) * tv / vmax
            s.line(ax0, y, ax1, y, tcls)
        s.text(ax0 + (ax1 - ax0) / 2, ybase + 40, f"unit: {unit.strip()}", "ax", "middle")
    s.text(24, ybase + 66, "x-axis: window; y-axis: value in the panel's unit. Autonomy shows both targets (99 % dashed, 99.9 % dotted),", "ax")
    s.text(24, ybase + 83, "about 2 px apart at this scale.", "ax")
    s.source(["Source: evidence/kpi/baseline.out.json (headline: autonomy_rate, escalated_rate, reopen_rate,",
              "regression_rate, time_to_resolve_median_h). Targets are design targets, not data."])
    for k, _ in wins:
        a, e = b[k]["autonomy_rate"], b[k]["escalated_rate"]
        if abs(a + e - 1) > 0.005:
            note(f"baseline: {k} autonomy_rate {a} + escalated_rate {e} != 1 (autonomy = 1 - owner_touch_rate {b[k]['owner_touch_rate']}; "
                 f"escalated is a different cut)")
            break
    write("chart-baseline.svg", s)


# ---------------------------------------------------------------- 7 rework

def chart_rework():
    g = load("kpi/git_delivery.out.json")
    min_c = g["rankings"]["min_commits"]
    rows = [(r["repo"], r["commits"], r["rework"]["share"], r["root"]) for r in g["repos"] if r["commits"] >= min_c]
    rows.sort(key=lambda r: (-r[2], r[0]))
    top = rows[:12]
    ranked = g["rankings"]["top_rework_share"]
    if len(ranked) < 12:
        note(f"rework: rankings.top_rework_share lists only {len(ranked)} repos; "
             f"top 12 of the {len(rows)} repos with >= {min_c} commits computed from repos[].rework.share")
    for r in ranked:
        mine = next((t for t in rows if t[0] == r["repo"]), None)
        if mine and abs(mine[2] - r["rework_share"]) > 5e-4:
            note(f"rework: {r['repo']} share {r['rework_share']} in rankings vs {mine[2]} in repos[]")
    pooled = sum(r["rework"]["count"] for r in g["repos"]) / max(1, sum(r["commits"] for r in g["repos"]))
    w = 900
    pitch, bh = 30, 20
    ytop = 108
    h = ytop + pitch * len(top) + 100
    s = Svg(w, h, f"Rework share for the top 12 repos with at least {min_c} commits",
            "Horizontal bars of rework share (commits that rework recent work, within " + f"{g['rework_lookback_days']} days) over a {g['window_days']}-day window: "
            + "; ".join(f"{r[0]} {r[2] * 100:.1f} % of {r[1]} commits" for r in top) + ".")
    s.header(f"Rework share: top 12 repos with at least {min_c} commits",
             [f"Share of commits that rework files touched in the prior {g['rework_lookback_days']} days; "
              f"{g['window_days']}-day window.",
              f"{len(rows)} repos qualify; the 12 highest shown. Repo-pooled share: {pooled * 100:.1f} %."])
    lx, x1 = 220, 790
    vmax = 60
    ybase = ytop + pitch * len(top)
    ticks_h(s, lx, x1, ytop - 6, ybase, vmax, 10, " %")
    sc = (x1 - lx) / vmax
    for i, (repo, commits, share, root) in enumerate(top):
        y = ytop + i * pitch
        s.text(lx - 10, y + bh / 2 + 4, repo, "lbl", "end")
        s.hbar(lx, y, sc * share * 100, bh, "f1", f"{repo}: rework share {share * 100:.1f} % of {commits} commits")
        s.text(lx + sc * share * 100 + 8, y + bh / 2 + 4, f"{share * 100:.1f} %  ·  {commits:,} commits", "val")
    s.text((lx + x1) / 2, ybase + 36, "Rework share of commits (%)", "ax", "middle")
    s.source(["Source: evidence/kpi/git_delivery.out.json (repos[].commits, repos[].rework.share;",
              "cross-checked against rankings.top_rework_share)."])
    write("chart-rework.svg", s)


def main():
    chart_quota()
    chart_attention()
    chart_signals()
    chart_questions()
    chart_drift()
    chart_baseline()
    chart_rework()
    for n in NOTES:
        print("DATA NOTE:", n, file=sys.stderr)


if __name__ == "__main__":
    main()
