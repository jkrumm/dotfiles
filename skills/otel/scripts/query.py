#!/usr/bin/env python3
"""
ClickHouse OTEL query tool for HyperDX/ClickStack.

Stdlib only — no dependencies. Runs against local Docker or prod VPS via SSH.
SQL is piped via stdin to avoid any quoting issues.

Usage:
  python3 query.py [--env local|prod] "SELECT count() FROM default.otel_logs"
  python3 query.py [--env prod] --preset errors --since 2h
  python3 query.py [--env prod] --preset trace --trace-id abc123def456
  python3 query.py [--env prod] --preset log-search --pattern "NullPointerException"
  python3 query.py --list-presets
"""
import sys
import subprocess
import argparse
import urllib.request
import urllib.error
import urllib.parse
import socket

PRESETS = {
    "health": {
        "desc": "Data freshness + row counts per table",
        "sql": """SELECT 'traces' AS tbl, toString(max(Timestamp)) AS latest, formatReadableQuantity(count()) AS rows_in_range
FROM default.otel_traces WHERE Timestamp >= now() - INTERVAL {since}
UNION ALL
SELECT 'logs', toString(max(Timestamp)), formatReadableQuantity(count())
FROM default.otel_logs WHERE TimestampTime >= now() - INTERVAL {since}""",
    },
    "tables": {
        "desc": "OTEL tables with total row counts and disk size",
        "sql": """SELECT name, formatReadableQuantity(total_rows) AS total_rows, formatReadableSize(total_bytes) AS size
FROM system.tables
WHERE database = 'default' AND name LIKE 'otel%'
ORDER BY name""",
    },
    "services": {
        "desc": "Active services: span count, error rate, avg/p95 latency",
        "sql": """SELECT
  ServiceName,
  count() AS spans,
  countIf(StatusCode = 'STATUS_CODE_ERROR') AS errors,
  round(100.0 * countIf(StatusCode = 'STATUS_CODE_ERROR') / count(), 1) AS error_pct,
  round(avg(Duration) / 1e6, 1) AS avg_ms,
  round(quantile(0.95)(Duration) / 1e6, 1) AS p95_ms
FROM default.otel_traces
WHERE Timestamp >= now() - INTERVAL {since}
GROUP BY ServiceName
ORDER BY spans DESC""",
    },
    "errors": {
        "desc": "Top errors grouped by service + span + message",
        "sql": """SELECT ServiceName, SpanName, StatusMessage, count() AS cnt
FROM default.otel_traces
WHERE StatusCode = 'STATUS_CODE_ERROR'
  AND Timestamp >= now() - INTERVAL {since}
GROUP BY ServiceName, SpanName, StatusMessage
ORDER BY cnt DESC
LIMIT 25""",
    },
    "slow": {
        "desc": "Slowest spans by p95 duration",
        "sql": """SELECT
  ServiceName,
  SpanName,
  round(avg(Duration) / 1e6, 1) AS avg_ms,
  round(quantile(0.95)(Duration) / 1e6, 1) AS p95_ms,
  round(max(Duration) / 1e6, 1) AS max_ms,
  count() AS cnt
FROM default.otel_traces
WHERE Timestamp >= now() - INTERVAL {since}
GROUP BY ServiceName, SpanName
ORDER BY p95_ms DESC
LIMIT 20""",
    },
    "trace": {
        "desc": "Full trace waterfall by trace ID (requires --trace-id)",
        "sql": """SELECT
  SpanId,
  ParentSpanId,
  ServiceName,
  SpanName,
  round(Duration / 1e6, 2) AS ms,
  StatusCode,
  StatusMessage,
  toString(SpanAttributes) AS attrs
FROM default.otel_traces
WHERE TraceId = '{trace_id}'
ORDER BY Timestamp""",
    },
    "log-errors": {
        "desc": "Recent ERROR/FATAL logs with attributes",
        "sql": """SELECT
  toString(Timestamp) AS ts,
  ServiceName,
  SeverityText,
  Body,
  toString(LogAttributes) AS attrs
FROM default.otel_logs
WHERE SeverityNumber >= 17
  AND TimestampTime >= now() - INTERVAL {since}
ORDER BY Timestamp DESC
LIMIT 50""",
    },
    "log-count": {
        "desc": "Log volume breakdown by service + severity",
        "sql": """SELECT ServiceName, SeverityText, count() AS cnt
FROM default.otel_logs
WHERE TimestampTime >= now() - INTERVAL {since}
GROUP BY ServiceName, SeverityText
ORDER BY cnt DESC
LIMIT 30""",
    },
    "log-search": {
        "desc": "Full-text search across log body (requires --pattern)",
        "sql": """SELECT
  toString(Timestamp) AS ts,
  ServiceName,
  SeverityText,
  Body,
  toString(LogAttributes) AS attrs
FROM default.otel_logs
WHERE Body ILIKE '%{pattern}%'
  AND TimestampTime >= now() - INTERVAL {since}
ORDER BY Timestamp DESC
LIMIT 50""",
    },
    "trace-logs": {
        "desc": "All logs correlated to a trace (requires --trace-id)",
        "sql": """SELECT
  toString(Timestamp) AS ts,
  ServiceName,
  SeverityText,
  Body,
  toString(LogAttributes) AS attrs
FROM default.otel_logs
WHERE TraceId = '{trace_id}'
ORDER BY Timestamp""",
    },
    "metrics": {
        "desc": "Available metric names per service",
        "sql": """SELECT DISTINCT ServiceName, MetricName, MetricUnit
FROM (
  SELECT ServiceName, MetricName, MetricUnit FROM default.otel_metrics_sum
  UNION ALL SELECT ServiceName, MetricName, MetricUnit FROM default.otel_metrics_gauge
)
ORDER BY ServiceName, MetricName
LIMIT 60""",
    },
    "volume": {
        "desc": "Span + log ingestion rate per 5-minute bucket (last hour)",
        "sql": """SELECT
  toStartOfFiveMinutes(Timestamp) AS bucket,
  ServiceName,
  count() AS spans
FROM default.otel_traces
WHERE Timestamp >= now() - INTERVAL 1 HOUR
GROUP BY bucket, ServiceName
ORDER BY bucket DESC, spans DESC
LIMIT 60""",
    },
}


def parse_since(since: str) -> str:
    """Convert shorthand (1h, 6h, 7d, 30m) to ClickHouse INTERVAL format."""
    s = since.strip().lower()
    if s.endswith('d'):
        return f"{s[:-1]} DAY"
    if s.endswith('h'):
        return f"{s[:-1]} HOUR"
    if s.endswith('m'):
        return f"{s[:-1]} MINUTE"
    return s  # Already valid or unknown — pass through


def build_sql(preset_name: str, args) -> str:
    sql = PRESETS[preset_name]["sql"]
    sql = sql.replace("{since}", parse_since(args.since))
    if args.trace_id:
        sql = sql.replace("{trace_id}", args.trace_id.replace("'", "\\'"))
    if args.pattern:
        sql = sql.replace("{pattern}", args.pattern.replace("'", "\\'"))
    return sql


def _http_port_open(host: str, port: int, timeout: float = 0.3) -> bool:
    """Quick TCP probe — does ClickHouse HTTP appear to be reachable?"""
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def _run_http(sql: str, fmt: str) -> tuple:
    """Query ClickHouse via HTTP on localhost:8123. Works without docker exec —
    used when the sandbox blocks raw docker commands, or when the container's
    8123 port is bound to the host (see vps/compose.dev.yml). FORMAT is
    appended to the SQL itself rather than passed as a header so it survives
    statements that already declare their own format."""
    url = "http://127.0.0.1:8123/"
    body = f"{sql.rstrip(';').rstrip()} FORMAT {fmt}".encode("utf-8")
    req = urllib.request.Request(url, data=body, method="POST",
                                 headers={"Content-Type": "text/plain"})
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return resp.read().decode("utf-8", errors="replace"), ""
    except urllib.error.HTTPError as e:
        return "", e.read().decode("utf-8", errors="replace").strip() or f"HTTP {e.code}"
    except urllib.error.URLError as e:
        return "", f"HTTP transport failed: {e.reason}. Is ClickHouse :8123 exposed? (see vps/compose.dev.yml)"
    except socket.timeout:
        return "", "HTTP query timed out after 60s"


def run_query(sql: str, env: str, fmt: str = "TabSeparatedWithNamesAndTypes",
              transport: str = "auto") -> tuple:
    """Execute SQL against ClickStack. Returns (stdout, stderr).

    transport:
      - 'auto'  (default): HTTP if :8123 reachable, else fall back to docker exec
      - 'http'  : force HTTP (localhost:8123). Local-only; prod still needs ssh+docker.
      - 'exec'  : force docker exec (legacy path). Required if HTTP port isn't exposed.
    """
    if env == "local" and transport in ("http", "auto") and _http_port_open("127.0.0.1", 8123):
        return _run_http(sql, fmt)

    if env == "local":
        cmd = ["docker", "exec", "-i", "clickstack", "clickhouse-client", f"--format={fmt}"]
    else:
        # SSH with stdin forwarding — no quoting issues
        cmd = ["ssh", "vps", f"docker exec -i clickstack clickhouse-client --format={fmt}"]

    try:
        r = subprocess.run(cmd, input=sql, capture_output=True, text=True, timeout=60)
        if r.returncode != 0:
            return "", r.stderr.strip() or f"Exit {r.returncode}"
        return r.stdout, ""
    except subprocess.TimeoutExpired:
        return "", "Query timed out after 60s"
    except FileNotFoundError as e:
        return "", f"Command not found: {e}\n  Local: ensure Docker is running with 'clickstack' container\n  Prod: ensure 'ssh vps' is configured in ~/.ssh/config"


def tsv_to_markdown(raw: str, max_col: int = 70) -> str:
    """Convert TabSeparatedWithNamesAndTypes output to markdown table."""
    lines = raw.strip().splitlines()
    if not lines:
        return "(no results)"

    headers = lines[0].split('\t')
    # Line 0 = column names, line 1 = types, line 2+ = data rows
    data_rows = [l.split('\t') for l in lines[2:]] if len(lines) > 2 else []

    if not data_rows:
        return f"(no rows) — columns: {', '.join(headers)}"

    def trunc(s: str, w: int) -> str:
        return s[:w - 3] + '...' if len(s) > w else s

    widths = [max(3, len(h)) for h in headers]
    for row in data_rows:
        for i, cell in enumerate(row[:len(headers)]):
            widths[i] = max(widths[i], min(len(cell), max_col))

    sep = '|' + '|'.join('-' * (w + 2) for w in widths) + '|'
    hdr = '| ' + ' | '.join(headers[i].ljust(widths[i]) for i in range(len(headers))) + ' |'
    result = [hdr, sep]
    for row in data_rows:
        cells = []
        for i in range(len(headers)):
            cell = row[i] if i < len(row) else ''
            cells.append(trunc(cell, widths[i]).ljust(widths[i]))
        result.append('| ' + ' | '.join(cells) + ' |')
    return '\n'.join(result)


def main():
    p = argparse.ArgumentParser(
        description="ClickHouse OTEL query tool for HyperDX/ClickStack",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--env", choices=["local", "prod"], default="local",
                   help="Target environment (default: local)")
    p.add_argument("--preset", choices=list(PRESETS.keys()),
                   help="Named query preset")
    p.add_argument("--list-presets", action="store_true",
                   help="Print all presets and exit")
    p.add_argument("--since", default="1h",
                   help="Time range: 15m, 1h, 6h, 24h, 7d (default: 1h)")
    p.add_argument("--trace-id", metavar="ID",
                   help="Trace ID for 'trace' and 'trace-logs' presets")
    p.add_argument("--pattern", metavar="TEXT",
                   help="Search pattern for 'log-search' preset")
    p.add_argument("--json", action="store_true",
                   help="Output raw ClickHouse JSON instead of markdown table")
    p.add_argument("--transport", choices=["auto", "http", "exec"], default="auto",
                   help="Local transport: 'auto' (HTTP if :8123 reachable, else docker exec), "
                        "'http' (force localhost:8123), 'exec' (force docker exec). "
                        "Prod always uses ssh+docker exec.")
    p.add_argument("sql", nargs="?",
                   help="Raw SQL query (alternative to --preset)")
    args = p.parse_args()

    if args.list_presets:
        print("Available presets:")
        for name, info in PRESETS.items():
            print(f"  {name:<14}  {info['desc']}")
        return

    if args.preset:
        sql = build_sql(args.preset, args)
    elif args.sql:
        sql = args.sql
    else:
        sql = sys.stdin.read().strip()

    if not sql:
        p.print_help(sys.stderr)
        sys.exit(1)

    fmt = "JSON" if args.json else "TabSeparatedWithNamesAndTypes"
    stdout, stderr = run_query(sql, args.env, fmt, args.transport)

    if stderr:
        print(f"ERROR: {stderr}", file=sys.stderr)
        sys.exit(1)

    if args.json:
        print(stdout)
    else:
        print(tsv_to_markdown(stdout))


if __name__ == "__main__":
    main()
