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


def render(text: str, name: str) -> str:
    """Raise ValueError (message prefixed with `name`) on invalid frontmatter."""
    m = re.match(r"^---\n(.*?)\n---\n(.*)$", text, re.S)
    if not m:
        raise ValueError(f"{name}: no frontmatter")
    fm = dict(l.split(": ", 1) for l in m.group(1).splitlines() if ": " in l)
    if "description" not in fm:
        raise ValueError(f"{name}: frontmatter has no `description` — OpenCode needs one")
    tools = [t.strip().lower() for t in fm.get("tools", "").split(",") if t.strip()]
    out = ["---", f"description: {fm['description']}", "mode: subagent"]
    if tools:
        out.append("tools:")
        out += [f"  {t}: true" for t in tools]
    out += ["---", MARK, m.group(2)]
    return "\n".join(out)


def main() -> int:
    # Validate every source before touching DST: all errors reported together,
    # nothing written and no stale cleanup on failure.
    rendered: dict[Path, str] = {}
    errors: list[str] = []
    for src in sorted(SRC.glob("*.md")):
        try:
            rendered[src] = render(src.read_text(), str(src))
        except ValueError as e:
            errors.append(str(e))
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1

    DST.mkdir(parents=True, exist_ok=True)
    for src, text in rendered.items():
        dst = DST / src.name
        if dst.exists() and MARK not in dst.read_text():
            print(f"    · {dst} is hand-written — left alone")
            continue
        dst.write_text(text)
        print(f"    ✓ {dst}")
    for stale in DST.glob("*.md"):
        if not (SRC / stale.name).exists() and MARK in stale.read_text():
            stale.unlink()
            print(f"    − removed {stale}")
    return 0


sys.exit(main())
