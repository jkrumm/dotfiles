"""Minimal OTLP/HTTP JSON span emitter. Stdlib only.

Shared by warden_item.py (the `warden.item` root span) and mcp_stub.py (a gateway-shaped
server that DOES read `traceparent`). Mirrors what research-gateway/src/lib/otel.ts does on the
wire: one POST per batch to <base>/v1/traces, JSON body, no SDK.

The base URL comes from SPIKE_OTLP_BASE (default: the unauthenticated local ClickStack receiver).
"""

import hashlib
import json
import os
import re
import secrets
import time
import urllib.error
import urllib.request

OTLP_BASE = os.environ.get("SPIKE_OTLP_BASE", "http://localhost:4319")

KIND_INTERNAL, KIND_SERVER, KIND_CLIENT = 1, 2, 3
STATUS_UNSET, STATUS_OK, STATUS_ERROR = 0, 1, 2

_TRACEPARENT_RE = re.compile(r"^00-([0-9a-f]{32})-([0-9a-f]{16})-([0-9a-f]{2})$")


def new_span_id() -> str:
    return secrets.token_hex(8)


def trace_id_from_item(item_id: str) -> str:
    """Deterministic 32-hex trace id from a warden item id (Round 5 W9: 'trace id from item id').

    Anyone who knows the item id can recompute it, so a component that cannot take a header
    (a cron, a log line) can still be joined at query time.
    """
    return hashlib.sha256(f"warden-item:{item_id}".encode()).hexdigest()[:32]


def make_traceparent(trace_id: str, span_id: str, sampled: bool = True) -> str:
    return f"00-{trace_id}-{span_id}-{'01' if sampled else '00'}"


def parse_traceparent(value: str | None) -> tuple[str, str] | None:
    """Return (trace_id, parent_span_id) for a valid W3C traceparent, else None."""
    if not value:
        return None
    m = _TRACEPARENT_RE.match(value.strip().lower())
    if not m or set(m.group(1)) == {"0"} or set(m.group(2)) == {"0"}:
        return None
    return m.group(1), m.group(2)


def _any_value(v: object) -> dict:
    if isinstance(v, bool):
        return {"boolValue": v}
    if isinstance(v, int):
        return {"intValue": str(v)}
    if isinstance(v, float):
        return {"doubleValue": v}
    return {"stringValue": str(v)}


def attrs(d: dict) -> list[dict]:
    return [{"key": k, "value": _any_value(v)} for k, v in d.items() if v is not None]


def span(
    *,
    trace_id: str,
    span_id: str,
    parent_span_id: str = "",
    name: str,
    kind: int = KIND_INTERNAL,
    start_ns: int,
    end_ns: int,
    attributes: dict | None = None,
    status: int = STATUS_OK,
    status_message: str = "",
) -> dict:
    out = {
        "traceId": trace_id,
        "spanId": span_id,
        "parentSpanId": parent_span_id,
        "name": name,
        "kind": kind,
        "startTimeUnixNano": str(start_ns),
        "endTimeUnixNano": str(end_ns),
        "attributes": attrs(attributes or {}),
        "status": {"code": status, **({"message": status_message} if status_message else {})},
    }
    return out


def export_spans(service_name: str, spans: list[dict], resource: dict | None = None) -> tuple[int, str]:
    """POST spans to <base>/v1/traces. Returns (http_status, body). Never raises on HTTP errors."""
    payload = {
        "resourceSpans": [
            {
                "resource": {"attributes": attrs({"service.name": service_name, **(resource or {})})},
                "scopeSpans": [{"scope": {"name": "factory-spike-06"}, "spans": spans}],
            }
        ]
    }
    req = urllib.request.Request(
        f"{OTLP_BASE}/v1/traces",
        data=json.dumps(payload).encode(),
        headers={"content-type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status, resp.read().decode(errors="replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")
    except urllib.error.URLError as e:
        return 0, f"export failed: {e.reason}"


def now_ns() -> int:
    return time.time_ns()
