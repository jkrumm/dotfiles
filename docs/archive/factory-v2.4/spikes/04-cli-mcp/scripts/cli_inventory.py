#!/usr/bin/env python3
"""Inventory the CLI surface of the three gateways: commands, `--help` size, routing-block size.

Token counts use the IU endpoint's count_tokens route on the plain text (tokens(text) - tokens("ok")).

  cli_inventory.py --out raw/inventory-cli.json
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import render_routing  # noqa: E402
from mcp_inventory import count_tokens  # noqa: E402


def text_tokens(text: str, base: int) -> int | None:
    n = count_tokens(None, probe=text)
    return n - base if n is not None else None


def run_help(argv: list[str]) -> str:
    p = subprocess.run(argv, capture_output=True, text=True, check=False)
    return p.stdout or p.stderr


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    base = count_tokens(None, probe="ok") or 0
    cfg = json.loads(render_routing.CONFIG.read_text())
    out = {"clis": {}}
    for cli in cfg["clis"]:
        b = cli["bin"]
        top = run_help([b, "--help"])
        parsed = render_routing.parse_help(top, b)
        cmds = [render_routing.command_of(e["sig"], b) for e in parsed["entries"]]
        sub = {}
        for c in cmds:
            if c.startswith(('"', "<", "[")):
                continue
            h = run_help([b, c, "--help"])
            if h.startswith(f"{b} {c}"):  # a real per-command help, not the top-level text or an error
                sub[c] = {"bytes": len(h)}
        out["clis"][b] = {
            "commands": cmds, "command_count": len(cmds),
            "help_bytes": len(top), "help_tokens": text_tokens(top, base),
            "subcommand_help": sub, "subcommands_with_own_help": len(sub), "has_exit_codes": bool(parsed["exit"]),
        }
    block = render_routing.render(cfg)
    out["routing_block"] = {"lines": len(block.splitlines()), "chars": len(block), "tokens": text_tokens(block, base),
                            "exposes": {c["bin"]: c["expose"] for c in cfg["clis"]}}
    Path(a.out).write_text(json.dumps(out, indent=1) + "\n")
    for b, v in out["clis"].items():
        print(f"{b:<9} {v['command_count']:>2} commands, --help {v['help_bytes']} bytes / {v['help_tokens']} tokens")
    print(f"routing block: {out['routing_block']['lines']} lines, {out['routing_block']['tokens']} tokens")
    return 0


if __name__ == "__main__":
    sys.exit(main())
