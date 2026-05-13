---
name: read-drawing
description: Read and interpret Excalidraw diagrams (.excalidraw + .svg) via claude -p subprocess. Isolates large diagram files from main context.
---

# Read Drawing Skill

Launches a `claude -p` subprocess to interpret an Excalidraw diagram. Large JSON/SVG content stays isolated — only the semantic context block returns to main context.

## IMPORTANT — Subprocess Only

Always run via `claude -p`. Never execute inline. Never use the Agent tool.
If the API key lookup fails, report the error — do not fall back to inline execution.

## Usage

```
/read-drawing /path/to/diagram.svg
/read-drawing /path/to/diagram.excalidraw
/read-drawing /path/to/diagram          # resolves both automatically
```

## Execution

**Step 1** — Generate a unique temp path for this invocation: `/tmp/claude-read-drawing-<timestamp>`
(Use current epoch ms. This avoids conflicts if skill runs in parallel.)

**Step 2** — Write the prompt below to that path using the Write tool. Replace `[FILE_PATH]` with the actual file path argument.

```
You are a diagram interpreter. Read and interpret the Excalidraw diagram at the path below.

Step 1 — Resolve files:
Strip extension to get base path. Check which exist: <base>.svg, <base>.excalidraw

Step 2 — Visual read (if .svg exists):
Use the Read tool on the .svg file. It renders as an image. Observe:
- Overall layout, composition, flow direction
- Color coding and visual hierarchy
- Shape types and spatial groupings
- Apparent purpose from visual structure alone

Step 3 — Semantic analysis (if .excalidraw exists):
Read the JSON file. Apply these schema rules:
- text.containerId → text is the label for that shape (pair them)
- arrow.startBinding.elementId → source; endBinding.elementId → target
- Resolve element IDs to their labels when describing flows
- element.groupIds[] → shared ID = same logical component
- element.frameId → element lives inside this named frame/section
- strokeStyle: "dashed" = optional/async/secondary flow
- type: "diamond" = decision; "ellipse" = actor/endpoint; "rectangle" = process/component
- Free-floating text (no containerId) = annotation, section title

Label resolution:
1. Collect text elements where containerId != null → that shape's label
2. Standalone text (containerId == null) → annotation or title
3. Sort shapes by y coordinate → reading order top-to-bottom

Step 4 — Synthesize. Produce this output (under 2000 chars):

### Diagram: [filename or inferred title]

**Visual:** [1-2 sentences from SVG perception]

**Purpose:** [what this diagram communicates]

**Components:**
- [type] "label" — role

**Flows:**
- "A" → "B" — meaning
- "B" → "C" [dashed] — optional path

**Groups/Sections:** [if present]

**Implementation insight:** [the key actionable takeaway — what to build or understand]

FILE PATH: [FILE_PATH]
```

**Step 3** — Run the subprocess and clean up:

```bash
ANTHROPIC_API_KEY=$(security find-generic-password -s claude-sdk-api-key -w) \
ANTHROPIC_BASE_URL=$(security find-generic-password -s claude-sdk-base-url -w) \
  claude -p --model claude-haiku-4-5-20251001 < /tmp/claude-read-drawing-<timestamp>
rm -f /tmp/claude-read-drawing-<timestamp>
```
