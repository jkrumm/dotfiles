#!/usr/bin/env python3
"""Stand-in for warden: open a `warden.item` root span, run a worker under it, close the span.

Question it answers (Spike 6, step 2): can a stdlib script emit the root span over OTLP/HTTP JSON
and hand the worker a TRACEPARENT derived from it?

  python3 -I warden_item.py traceparent --item-id spike6-a        # print the derived TRACEPARENT only
  python3 -I warden_item.py run --item-id spike6-a [--summary out.json] -- <cmd...>   # root span around <cmd>

`run` mirrors the Round 5 W9 design:
  * trace id  = sha256("warden-item:" + item id)[:32]   (recomputable from the item id alone)
  * span id   = random, becomes the parent of everything the worker emits
  * the worker is started with TRACEPARENT in its environment (and only there: this process's
    own environment is left alone)
  * the span is exported when the worker exits (OTLP cannot export an unfinished span); there is
    deliberately no timeout around the worker (rules/agent-limits.md).

Env: SPIKE_OTLP_BASE (default http://localhost:4319). Result JSON is printed on stdout.
"""

import argparse
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import otlp  # noqa: E402


def derive(item_id: str) -> dict:
    trace_id = otlp.trace_id_from_item(item_id)
    span_id = otlp.new_span_id()
    return {
        "item_id": item_id,
        "trace_id": trace_id,
        "span_id": span_id,
        "traceparent": otlp.make_traceparent(trace_id, span_id),
    }


def cmd_traceparent(args: argparse.Namespace) -> int:
    print(json.dumps(derive(args.item_id)))
    return 0


def cmd_run(args: argparse.Namespace) -> int:
    if not args.cmd:
        print("run: missing worker command after --", file=sys.stderr)
        return 2
    ids = derive(args.item_id)
    env = {**os.environ, "TRACEPARENT": ids["traceparent"]}
    start = otlp.now_ns()
    proc = subprocess.run(args.cmd, env=env, check=False)  # no timeout, on purpose
    end = otlp.now_ns()
    status = otlp.STATUS_OK if proc.returncode == 0 else otlp.STATUS_ERROR
    root = otlp.span(
        trace_id=ids["trace_id"],
        span_id=ids["span_id"],
        name="warden.item",
        kind=otlp.KIND_INTERNAL,
        start_ns=start,
        end_ns=end,
        status=status,
        attributes={
            "warden.item.id": args.item_id,
            "warden.item.kind": "spike",
            "warden.worker.exit_code": proc.returncode,
            "warden.spike": "06-telemetry",
        },
    )
    http_status, body = otlp.export_spans(
        "warden-spike", [root], {"service.version": "spike", "deployment.environment": "local"}
    )
    summary = json.dumps(
        {
            **ids,
            "worker_exit_code": proc.returncode,
            "root_span_start_ns": start,
            "root_span_end_ns": end,
            "otlp_status": http_status,
            "otlp_body": body[:200],
        }
    )
    if args.summary:
        with open(args.summary, "w", encoding="utf-8") as f:
            f.write(summary + "\n")
    else:
        print(summary)
    return proc.returncode


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="verb", required=True)
    p1 = sub.add_parser("traceparent")
    p1.add_argument("--item-id", required=True)
    p1.set_defaults(fn=cmd_traceparent)
    p2 = sub.add_parser("run")
    p2.add_argument("--item-id", required=True)
    p2.add_argument("--summary", help="write the result JSON here instead of stdout (keeps the worker's stdout clean)")
    p2.add_argument("cmd", nargs=argparse.REMAINDER)
    p2.set_defaults(fn=cmd_run)
    args = ap.parse_args()
    if getattr(args, "cmd", None) and args.cmd[:1] == ["--"]:
        args.cmd = args.cmd[1:]
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
