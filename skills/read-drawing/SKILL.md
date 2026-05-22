---
name: read-drawing
description: Read and interpret Excalidraw diagrams (.excalidraw + .svg) via the sideclaw read_drawing MCP tool. Off Max, stronger vision model, structural JSON ground truth.
---

# Read Drawing Skill

Thin wrapper over the sideclaw `read_drawing` MCP tool. The whole pipeline —
SVG→PNG rasterization (headless Chrome), the vision read (`gemini-3-pro-preview`,
off Max), and the deterministic `.excalidraw` JSON parse (frames, bindings,
groups — the structural ground truth) — lives in sideclaw and runs as a single
stateless IU OpenAI-transport call. No `claude -p` subprocess, no Haiku agent.

## Usage

```
/read-drawing /path/to/diagram          # resolves <base>.svg + <base>.excalidraw
/read-drawing /path/to/diagram.svg
/read-drawing /path/to/diagram.excalidraw
```

## Execution

Call the MCP tool directly:

```
mcp__sideclaw__read_drawing({ path: "<the file or base path argument>" })
```

It returns `{ synthesis, structure, svgPath, excalidrawPath, model, latencyMs, usage }`:
- `synthesis` — merged prose (Diagram / Visual / Purpose / Components / Flows /
  Groups / Implementation-insight) combining the vision gestalt with the JSON
  ground truth.
- `structure` — the deterministic parse (components, flows with resolved
  bindings, groups, frames, annotations). Authoritative for structure where the
  image and JSON disagree.

Report the `synthesis` to the user; surface `structure` details when the exact
wiring (which arrow binds what, frame membership) matters.

## Notes

- For an arbitrary single image (screenshot, photo, non-Excalidraw SVG) use
  `mcp__sideclaw__read_image` instead.
- The vision model routes to a non-EU vendor — fine for git-committed/non-sensitive
  diagrams, not for PII.
- If the sideclaw MCP server is unavailable, report it (the tool needs the
  sideclaw MCP registered: `make setup` in `~/SourceRoot/dotfiles`). Do not fall
  back to an inline `claude -p` read.
