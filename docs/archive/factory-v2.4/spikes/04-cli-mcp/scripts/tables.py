#!/usr/bin/env python3
"""Print the report's tables as Markdown (minimum separators) from raw/*.json.

  tables.py inventory | turn1 | medians | adjusted | tasks | probes | friction | failures | all
"""

from __future__ import annotations

import json
import statistics
import sys
from pathlib import Path

RAW = Path(__file__).resolve().parents[1] / "raw"
GW = {"agw": "agent-gateway", "research": "research-gateway", "email": "email-gateway"}
COND = {"mcp": "MCP inline", "mcp_deferred": "MCP deferred", "cli": "CLI + routing block", "cli_v0": "CLI v0 (ablation)", "cli_v2": "CLI + no-wait policy (ablation)", "cli_v3": "CLI + foreground-timeout policy (ablation)", "mcp_deferred_hint": "MCP deferred + hint"}


def load(name: str):
    return json.loads((RAW / name).read_text())


def row(*cells) -> str:
    return "| " + " | ".join(str(c) for c in cells) + " |"


def fmt(x, nd=0):
    if x is None:
        return "-"
    return f"{x:,.{nd}f}" if nd else f"{x:,.0f}"


def inventory() -> None:
    print(row("Gateway", "MCP tools", "tools/list bytes", "model-visible bytes (desc + input schema)", "definition tokens (count_tokens)", "CLI commands", "`--help` bytes / tokens"))
    print("|-|-|-|-|-|-|-|")
    cli = load("inventory-cli.json")["clis"]
    for key, name, cbin in (("agw", "agent-gateway", "agw"), ("research", "research-gateway", "research"), ("email", "email-gateway", "mailgw")):
        m = load(f"inventory-{key}-mcp.json")
        visible = sum(r["description_chars"] + r["input_schema_bytes"] for r in m["per_tool"])
        c = cli[cbin]
        print(row(name, m["tool_count"], fmt(m["tools_list_bytes"]), fmt(visible), fmt(m["definition_tokens_count_tokens"]), c["command_count"], f"{fmt(c['help_bytes'])} / {fmt(c['help_tokens'])}"))


def turn1() -> None:
    rows = {r["label"]: r["turn1_input_tokens"] for r in load("turn1.json")["rows"]}
    med = lambda l: statistics.median(rows[l]) if l in rows else None  # noqa: E731
    base0, base_bash = med("lab/baseline/no-tools"), med("lab/baseline/bash")
    print(row("Configuration", "turn-1 input tokens", "marginal over its tool baseline"))
    print("|-|-|-|")
    print(row("baseline, no tools", fmt(base0), "-"))
    print(row("baseline, Bash only", fmt(base_bash), f"+{fmt(base_bash - base0)} vs no tools"))
    blk = med("lab/cli/bash+routing-block")
    print(row("CLI: Bash + generated routing block (all three gateways)", fmt(blk), f"+{fmt(blk - base_bash)} (the block)"))
    for gw, name in GW.items():
        a, d = med(f"lab/mcp/{gw}"), med(f"lab/mcp_deferred/{gw}")
        print(row(f"{name}: MCP inline", fmt(a), f"+{fmt(a - base0)}"))
        print(row(f"{name}: MCP deferred (ToolSearch)", fmt(d), f"+{fmt(d - base0)}"))
    print()
    print(row("Ambient (owner's real settings, hooks, skills, all built-ins)", "turn-1 input tokens", "marginal over no MCP"))
    print("|-|-|-|")
    b = med("ambient/no-mcp")
    b_off = med("ambient/no-mcp/tool-search-off")
    print(row("no MCP server (tool search at its default)", fmt(b), "-"))
    if b_off is not None:
        print(row("no MCP server, tool search forced off (inlines the deferred built-ins too)", fmt(b_off), f"+{fmt(b_off - b)} vs default"))
    for gw, name in GW.items():
        for lab, suffix, ref in (("tool search at its default (deferred)", "default", b), ("tool search forced off (inline)", "tool-search-off", b_off)):
            v = med(f"ambient/{gw}/{suffix}")
            if v is not None and ref is not None:
                print(row(f"{name}, {lab}", fmt(v), f"+{fmt(v - ref)}"))


def medians() -> None:
    s = load("summary.json")["by_gateway_condition"]
    print(row("Gateway", "Condition", "n", "success", "turn-1 in", "total in (fresh)", "out", "API calls", "calls to success", "discovery", "wall s net of queue", "cost $"))
    print("|-|-|-|-|-|-|-|-|-|-|-|-|")
    for r in s:
        if r["probe"] or r["condition"] not in ("mcp", "mcp_deferred", "cli"):  # ablations live in `probes`
            continue
        print(row(GW[r["gateway"]], COND[r["condition"]], r["runs"], f"{r['success_rate']:.0%}", fmt(r["turn1_input_tokens"]),
                  f"{fmt(r['input_tokens_total'])} ({fmt(r['input_tokens_fresh'])})", fmt(r["output_tokens"]), fmt(r["api_calls"], 1),
                  fmt(r["calls_to_success"], 1), fmt(r["discovery_calls"], 1), fmt(r["wall_net_s"], 1), f"{r['cost_usd']:.3f}"))
    # probes are reported per task by `tables.py probes`


def tasks() -> None:
    t = load("summary.json")["by_task_condition"]
    print(row("Task", "Condition", "ok/n", "turn-1", "total in", "out", "tool calls", "wall s net", "cost $"))
    print("|-|-|-|-|-|-|-|-|-|")
    for r in t:
        print(row(r["task"], COND[r["condition"]], f"{r['success']}/{r['runs']}", fmt(r["turn1"]), fmt(r["tokens_total"]), fmt(r["output"]),
                  fmt(r["tool_calls"], 1), fmt(r["wall_s"], 1), f"{r['cost']:.3f}"))


def failures() -> None:
    runs = [json.loads(l) for l in (RAW / "runs.jsonl").read_text().splitlines() if l.strip()]
    bad = [r for r in runs if not r["success"]]
    print(row("Run", "Failure mode", "Answer", "Tool calls", "Note"))
    print("|-|-|-|-|-|")
    for r in bad:
        note = (r.get("final_text") or "")[:90].replace("\n", " ").replace("|", "/")
        print(row(r["run_id"], r["failure_mode"], json.dumps(r["answer"])[:70] if r["answer"] else "-", r["tool_calls"], note))
    print(f"\n{len(bad)} of {len(runs)} runs failed.")


def adjusted() -> None:
    """Total input tokens per task as a real session would pay them.

    The lab CLI condition carries the Bash tool definition and the deferred condition carries the ToolSearch
    definition; every real coding session has both already. Both are measured in turn1.json and removed per API call.
    Inline MCP is unchanged (its definitions are the cost under test)."""
    rows = {r["label"]: statistics.median(r["turn1_input_tokens"]) for r in load("turn1.json")["rows"]}
    bash_def = rows["lab/baseline/bash"] - rows["lab/baseline/no-tools"]
    ts_def = statistics.median([(rows[f"lab/mcp_deferred/{g}"] - rows["lab/baseline/no-tools"]) - (rows[f"ambient/{g}/default"] - rows["ambient/no-mcp"]) for g in GW])
    per_call = {"cli": bash_def, "mcp_deferred": ts_def, "mcp_deferred_hint": ts_def, "mcp": 0}
    print(f"Removed per API call: Bash definition {bash_def:,.0f} tokens (CLI), ToolSearch definition {ts_def:,.0f} tokens (deferred).\n")
    runs = [json.loads(l) for l in (RAW / "runs.jsonl").read_text().splitlines() if l.strip()]
    groups: dict[tuple[str, str], list[float]] = {}
    for r in runs:
        if r["probe"] or r["condition"] not in per_call:
            continue
        groups.setdefault((r["gateway"], r["condition"]), []).append(r["input_tokens_total"] - per_call[r["condition"]] * r["api_calls"])
    print(row("Gateway", "Condition", "n", "median total input tokens, real-session basis"))
    print("|-|-|-|-|")
    for (gw, cond), v in sorted(groups.items()):
        print(row(GW[gw], COND[cond], len(v), fmt(statistics.median(v))))


def probes() -> None:
    """Per-task rows for the probes and the ablations (every condition that ran for those tasks)."""
    rows = load("summary.json")["by_task_condition"]
    keep = {"agw-review-large", "research-standard-long", "email-probe-unread"}
    abl = {r["task"] for r in rows if r["condition"] in ("cli_v0", "cli_v2", "cli_v3", "mcp_deferred_hint")}
    print(row("Task", "Condition", "ok/n", "turn-1", "total in", "out", "tool calls", "wall s net", "cost $"))
    print("|-|-|-|-|-|-|-|-|-|")
    for r in rows:
        if r["task"] in keep | abl:
            print(row(r["task"], COND.get(r["condition"], r["condition"]), f"{r['success']}/{r['runs']}", fmt(r["turn1"]), fmt(r["tokens_total"]),
                      fmt(r["output"]), fmt(r["tool_calls"], 1), fmt(r["wall_net_s"], 1), f"{r['cost']:.3f}"))


def friction() -> None:
    """Runs that hit at least one tool error, per gateway and condition, with the commonest error heads."""
    runs = [json.loads(l) for l in (RAW / "runs.jsonl").read_text().splitlines() if l.strip()]
    groups: dict[tuple[str, str], list[dict]] = {}
    for r in runs:
        groups.setdefault((r["gateway"], r["condition"]), []).append(r)
    print(row("Gateway", "Condition", "runs", "with a tool error", "tool errors (all runs)", "most common error"))
    print("|-|-|-|-|-|-|")
    for (gw, cond), rs in sorted(groups.items()):
        heads: dict[str, int] = {}
        for r in rs:
            for c in r["calls"]:
                if c["is_error"]:
                    k = " ".join(c["result_head"].split())[:70]
                    heads[k] = heads.get(k, 0) + 1
        top = max(heads, key=heads.get) if heads else "-"
        print(row(GW[gw], COND.get(cond, cond), len(rs), sum(1 for r in rs if r["tool_errors"]), sum(r["tool_errors"] for r in rs), top.replace("|", "/")))


if __name__ == "__main__":
    which = sys.argv[1] if len(sys.argv) > 1 else "all"
    fns = {"inventory": inventory, "turn1": turn1, "medians": medians, "adjusted": adjusted, "tasks": tasks, "probes": probes, "friction": friction, "failures": failures}
    for name in (fns if which == "all" else [which]):
        print(f"\n### {name}\n")
        fns[name]()
