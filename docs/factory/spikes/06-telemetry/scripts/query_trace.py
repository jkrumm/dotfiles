#!/usr/bin/env python3
"""Which spans, logs and metrics joined one warden trace? (Spike 6, step 4.) Stdlib only.

  python3 -I query_trace.py --trace-id <32 hex> --item-id <warden item id> --label B --out <dir>

Reads the LOCAL ClickStack ClickHouse over HTTP (localhost:8123, loopback-only, dev default user;
see the /otel skill). Writes <out>/<label>.trace.md (waterfall + verdict tables, with the exact SQL
used) and <out>/<label>.trace.json (every row the report cites).

Joined = same TraceId. "Unjoined" = spans the run's other hops emitted under a DIFFERENT TraceId
(named exactly through --run-dir): that is where a broken hop shows up.
"""

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request

CH = os.environ.get("SPIKE_CH_URL", "http://localhost:8123/")

# The evidence this writes lands in a public repo: pass it through the shared redactor
# (docs/factory/evidence/lib/redact.py) before it touches disk.
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "evidence", "lib"))
try:
    from redact import redact  # type: ignore[import-not-found]
except ImportError:  # standalone copy of the scripts: fail closed rather than write unredacted output

    def redact(text: str) -> str:
        raise SystemExit("evidence/lib/redact.py not found; refusing to write unredacted output")
GATEWAYS = ("research-gateway", "gateway-stub-spike")


def ch(sql: str) -> list[dict]:
    body = f"{sql.strip().rstrip(';')} FORMAT JSONEachRow".encode()
    req = urllib.request.Request(CH, data=body, method="POST", headers={"content-type": "text/plain"})
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            text = resp.read().decode()
    except urllib.error.HTTPError as e:
        raise SystemExit(f"ClickHouse HTTP {e.code}: {e.read().decode(errors='replace')[:400]}") from e
    return [json.loads(line) for line in text.splitlines() if line.strip()]


def esc(value: str) -> str:
    if not re.fullmatch(r"[A-Za-z0-9_.:-]*", value):
        raise SystemExit(f"refusing to inline unexpected characters: {value!r}")
    return value


def short(span_id: str) -> str:
    return span_id[:8] if span_id else "-"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--trace-id", required=True)
    ap.add_argument("--item-id", required=True)
    ap.add_argument("--label", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--run-dir", help="run_spike.sh output dir: names the foreign traces exactly (stub log + gateway job id)")
    args = ap.parse_args()
    trace, item = esc(args.trace_id), esc(args.item_id)

    sql_trace = f"""SELECT toString(Timestamp) AS ts, ServiceName, SpanName, SpanKind, SpanId, ParentSpanId,
       Duration, StatusCode, SpanAttributes, ResourceAttributes
FROM default.otel_traces
WHERE TraceId = '{trace}'
ORDER BY Timestamp, SpanId"""
    spans = ch(sql_trace)
    if not spans:
        print("no spans for that trace id", file=sys.stderr)
        return 1

    by_id = {s["SpanId"]: s for s in spans}
    children: dict[str, list[dict]] = {}
    roots = []
    for s in spans:
        parent = s["ParentSpanId"]
        if parent and parent in by_id:
            children.setdefault(parent, []).append(s)
        else:
            roots.append(s)

    lines: list[str] = []

    def walk(node: dict, depth: int) -> None:
        ms = int(node["Duration"]) / 1e6
        lines.append(
            f'{"  " * depth}{node["ServiceName"]} / {node["SpanName"]}  [{node["SpanKind"]}] '
            f'{short(node["SpanId"])} <- {short(node["ParentSpanId"])}  {ms:.1f} ms  {node["StatusCode"]}'
        )
        for child in children.get(node["SpanId"], []):
            walk(child, depth + 1)

    for r in roots:
        walk(r, 0)

    # Which traces did the OTHER hops of this run emit? Named exactly, not guessed from a time window
    # (back-to-back runs overlap): the stub's own request log says which trace each request landed
    # in, and the real gateway derives its trace id from the job id the worker's `curl` got back.
    foreign: dict[str, str] = {}
    if args.run_dir:
        stub_log = os.path.join(args.run_dir, "stub-requests.jsonl")
        if os.path.exists(stub_log):
            for line in open(stub_log, encoding="utf-8"):
                tid = json.loads(line).get("span_trace_id")
                if tid and tid != trace:
                    foreign[tid] = "gateway-stub request without a joined traceparent"
        for name in ("claude.stream.jsonl", "pty-transcript.txt"):
            path = os.path.join(args.run_dir, name)
            if os.path.exists(path):
                text = open(path, encoding="utf-8", errors="replace").read()
                for job_id in dict.fromkeys(re.findall(r"jobId[\\\"': ]+([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})", text)):
                    foreign[job_id.replace("-", "")] = "research-gateway job (trace id = job id)"
    in_list = ", ".join(f"'{esc(t)}'" for t in foreign) or "''"
    sql_window = f"""SELECT toString(Timestamp) AS ts, ServiceName, SpanName, SpanKind, TraceId, substring(TraceId, 1, 8) AS trace8,
       SpanId, ParentSpanId, StatusCode
FROM default.otel_traces
WHERE TraceId IN ({in_list})
ORDER BY Timestamp"""
    unjoined = ch(sql_window)
    for u in unjoined:
        u["why"] = foreign.get(u["TraceId"], "")

    sql_logs = f"""SELECT ServiceName, LogAttributes['event.name'] AS event, count() AS n, countIf(SpanId != '') AS with_span_id
FROM default.otel_logs
WHERE TraceId = '{trace}'
GROUP BY ServiceName, event
ORDER BY ServiceName, event"""
    logs = ch(sql_logs)

    sql_resource = f"""SELECT * FROM (
  SELECT 'traces' AS signal, ServiceName, count() AS n FROM default.otel_traces
    WHERE ResourceAttributes['warden.item.id'] = '{item}' GROUP BY ServiceName
  UNION ALL SELECT 'logs', ServiceName, count() FROM default.otel_logs
    WHERE ResourceAttributes['warden.item.id'] = '{item}' GROUP BY ServiceName
  UNION ALL SELECT 'metrics_sum', ServiceName, count() FROM default.otel_metrics_sum
    WHERE ResourceAttributes['warden.item.id'] = '{item}' GROUP BY ServiceName
) ORDER BY signal, ServiceName"""
    resource_join = ch(sql_resource)

    by_name: dict[tuple[str, str], dict] = {}
    for s in spans:
        key = (s["ServiceName"], s["SpanName"])
        entry = by_name.setdefault(key, {"count": 0, "attr_keys": set()})
        entry["count"] += 1
        entry["attr_keys"].update(s["SpanAttributes"].keys())
    summary = [
        {"service": k[0], "span": k[1], "count": v["count"], "attribute_keys": sorted(v["attr_keys"])}
        for k, v in sorted(by_name.items())
    ]

    verdict = {
        "trace_id": trace,
        "item_id": item,
        "spans_in_trace": len(spans),
        "spans_by_service": {
            svc: sum(1 for s in spans if s["ServiceName"] == svc) for svc in sorted({s["ServiceName"] for s in spans})
        },
        "orphan_parents_inside_trace": [
            f'{s["ServiceName"]}/{s["SpanName"]}'
            for s in spans
            if s["ParentSpanId"] and s["ParentSpanId"] not in by_id
        ],
        "gateway_spans_in_other_traces": [
            {"service": u["ServiceName"], "span": u["SpanName"], "trace8": u["trace8"], "parent": short(u["ParentSpanId"]), "why": u["why"]}
            for u in unjoined
        ],
        "log_records_with_trace_id": sum(int(r["n"]) for r in logs),
        "resource_attribute_join": resource_join,
    }

    md = [f"# Trace {args.label}: {trace}", "", f"item id: `{item}`", "", "## Waterfall (joined = same TraceId)", "", "```text", *lines, "```", ""]
    md += ["## Spans of this run's other hops that are NOT in this trace", ""]
    if unjoined:
        md += ["|service|span|kind|trace8|parent|why it is elsewhere|", "|-|-|-|-|-|-|"]
        md += [f'|{u["ServiceName"]}|{u["SpanName"]}|{u["SpanKind"]}|{u["trace8"]}|{short(u["ParentSpanId"])}|{u["why"]}|' for u in unjoined]
    else:
        md += ["(none)"]
    md += ["", "## Log records with this TraceId", "", "|service|event|n|with SpanId|", "|-|-|-|-|"]
    md += [f'|{r["ServiceName"]}|{r["event"]}|{r["n"]}|{r["with_span_id"]}|' for r in logs]
    md += ["", "## Join by resource attribute `warden.item.id`", "", "|signal|service|rows|", "|-|-|-|"]
    md += [f'|{r["signal"]}|{r["ServiceName"]}|{r["n"]}|' for r in resource_join]
    md += ["", "## Span names and attribute keys", "", "|service|span|count|attribute keys|", "|-|-|-|-|"]
    md += [f'|{e["service"]}|{e["span"]}|{e["count"]}|{", ".join(e["attribute_keys"])}|' for e in summary]
    md += ["", "## SQL used", "", "```sql", sql_trace, "", sql_window, "", sql_logs, "", sql_resource, "```", ""]

    os.makedirs(args.out, exist_ok=True)
    with open(os.path.join(args.out, f"{args.label}.trace.md"), "w", encoding="utf-8") as f:
        f.write(redact("\n".join(md)))
    # Attribute VALUES stay out of the committed JSON: keys are the contract this spike reports.
    slim = [{k: v for k, v in s.items() if k not in ("SpanAttributes", "ResourceAttributes")} for s in spans]
    with open(os.path.join(args.out, f"{args.label}.trace.json"), "w", encoding="utf-8") as f:
        f.write(redact(json.dumps({"verdict": verdict, "span_summary": summary, "spans": slim, "unjoined": unjoined, "logs": logs}, indent=1, sort_keys=True)))
        f.write("\n")
    print("\n".join(lines))
    print(json.dumps(verdict, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
