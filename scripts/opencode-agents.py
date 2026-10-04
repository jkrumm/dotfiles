#!/usr/bin/env python3
"""Render agents/*.md (Claude Code subagents) into ~/.config/opencode/agent/.

OpenCode rejects Claude's frontmatter outright — `tools` must be an object, `color`
a hex/theme name — and one invalid file fails the whole config load, so the agents
cannot be symlinked. This keeps the body (the actual brief) verbatim and rewrites
the frontmatter: `description` kept, `mode: subagent`, `tools` as the object form,
`model`/`effort`/`color`/`permissionMode` dropped (the model is the session's — a
Claude alias means nothing on the IU provider; permission is global `allow`).
Rendered files carry a marker; anything without it is left alone.
"""
import re
import sys
from pathlib import Path

SRC = Path(__file__).resolve().parent.parent / "agents"
DST = Path.home() / ".config" / "opencode" / "agent"
MARK = "<!-- rendered from dotfiles/agents by scripts/opencode-agents.py — edit the source -->"


def render(text: str) -> str:
    m = re.match(r"^---\n(.*?)\n---\n(.*)$", text, re.S)
    if not m:
        raise SystemExit("no frontmatter")
    fm = dict(l.split(": ", 1) for l in m.group(1).splitlines() if ": " in l)
    tools = [t.strip().lower() for t in fm.get("tools", "").split(",") if t.strip()]
    out = ["---", f"description: {fm['description']}", "mode: subagent"]
    if tools:
        out.append("tools:")
        out += [f"  {t}: true" for t in tools]
    out += ["---", MARK, m.group(2)]
    return "\n".join(out)


def main() -> int:
    DST.mkdir(parents=True, exist_ok=True)
    for src in sorted(SRC.glob("*.md")):
        dst = DST / src.name
        if dst.exists() and MARK not in dst.read_text():
            print(f"    · {dst} is hand-written — left alone")
            continue
        dst.write_text(render(src.read_text()))
        print(f"    ✓ {dst}")
    for stale in DST.glob("*.md"):
        if not (SRC / stale.name).exists() and MARK in stale.read_text():
            stale.unlink()
            print(f"    − removed {stale}")
    return 0


sys.exit(main())
