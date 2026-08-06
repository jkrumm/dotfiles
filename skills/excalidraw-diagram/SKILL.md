---
name: excalidraw-diagram
description: Create Excalidraw diagram files that make visual arguments. Use when the user wants to visualize workflows, architectures, or concepts. Delegates JSON generation + hydration to the sideclaw `excalidraw_diagram` MCP tool.
---

# Excalidraw Diagram Creator

Generate `.excalidraw` files that **argue visually**, not just display information.

This skill is the **design director**: you decide depth, pattern variety, and
evidence. The mechanical work — JSON shape, element bindings, hydration into a
portable `.excalidraw` v2 file — lives in the sideclaw MCP tool
(`mcp__sideclaw__excalidraw_diagram`). You author the prompt; the tool delivers
a portable file.

## Output portability (the guarantee)

The sideclaw tool emits **fully-hydrated `.excalidraw` v2 files**: complete
`type`/`version`/`source`/`elements`/`appState`/`files` envelope with all IDs,
seeds, versionNonces, and bindings computed. The same file opens cleanly in:

| Target                                | How                                                       |
|---------------------------------------|-----------------------------------------------------------|
| sideclaw DiagramPanel                 | Open at `https://sideclaw.test`                           |
| Obsidian Excalidraw plugin (zsviczian)| Drop the file anywhere in the vault                       |
| excalidraw.com                        | Drag-and-drop the file onto the canvas, or *File → Open*  |
| Any third-party Excalidraw renderer   | Standard v2 envelope — no plugin-specific fields          |

You don't pick the target — the file is universal.

## Flow

1. **Assess depth** — Simple/Conceptual or Comprehensive/Technical (see below).
2. **Research** (if technical) — look up actual specs, event names, formats.
3. **Design the visual argument** — pattern variety, multi-zoom, evidence.
4. **Resolve the output path** — infer from context (brain vault path, working
   dir) and state the chosen path in the output.
5. **Call `mcp__sideclaw__excalidraw_diagram`** with the prompt + outputPath.
6. **Open the result** — read the path back to the user. They open it in their
   editor of choice.

## When to use which mode

- `mode: "create"` (default) — generate a fresh diagram at `outputPath`.
- `mode: "extend"` — read the existing file at `outputPath`, pass it to the
  worker as a baseline, and append/modify. Use when the user says "add X to
  this diagram" or "make Y change to the chart from yesterday."

## Resolving the output path

Infer from context, in this order:

- If cwd is under `~/SourceRoot/brain` (the live vault) → put it in a sensible
  subfolder, co-located with the note it belongs to. Never write to
  `~/Obsidian/Vault` (cold backup, closed).
- Otherwise → default to the brain vault too, in a sensible subfolder inferred
  from the diagram's subject. Don't dump diagram files in random project repos.

Always pass an **absolute path** ending in `.excalidraw`. State the chosen path
in the output.

---

## Design Philosophy

The technical JSON shape is owned by the sideclaw tool. The design quality is
owned by **you, here**. The rest of this file is about how to think before you
call the tool.

### Diagrams ARGUE, not DISPLAY

A diagram isn't formatted text. It's a visual argument that shows
relationships, causality, and flow that words alone can't express. The shape
should BE the meaning.

**The Isomorphism Test**: If you removed all text, would the structure alone
communicate the concept? If not, redesign.

**The Education Test**: Could someone learn something concrete from this
diagram, or does it just label boxes? A good diagram teaches — it shows actual
formats, real event names, concrete examples.

### Depth Assessment (Do This First)

| Mode                       | Use when                                                          | Output                                          |
|----------------------------|-------------------------------------------------------------------|-------------------------------------------------|
| **Simple/Conceptual**      | Mental model, philosophy, abstract concept                        | Abstract shapes, labels, relationships          |
| **Comprehensive/Technical**| Real system, protocol, API, tutorial, YouTube/docs                | Concrete examples, code snippets, real data     |

**For technical diagrams, research first.** Look up the actual specs, formats,
event names. Pass real terminology to the tool in your prompt — generic
"Protocol → Frontend" labels waste the format.

### Multi-Zoom Architecture

Comprehensive diagrams operate at three zoom levels simultaneously:

1. **Summary Flow** — simplified overview (`input → process → output`).
2. **Section Boundaries** — labeled background-zone rectangles grouping
   related elements (`opacity: 35`).
3. **Detail Inside Sections** — evidence artifacts, code snippets, real names.

State these levels explicitly in your prompt to the tool. The worker handles
the rendering.

### Evidence Artifacts (Technical Diagrams)

Concrete examples that prove the diagram is accurate:

| Artifact type            | When                                | How                                            |
|--------------------------|-------------------------------------|------------------------------------------------|
| Code snippets            | APIs, integrations                  | Dark rect + monospace + syntax color           |
| JSON / data examples     | Formats, schemas, payloads          | Dark rect + light-yellow text                  |
| Event sequences          | Protocols, workflows                | Timeline (line + dots + free-floating labels)  |
| UI mockups               | Showing actual output               | Nested rectangles mimicking real UI            |
| Real API/method names    | Function calls, endpoints           | Actual names, never "Endpoint" / "Method"      |

### Visual Pattern Variety

For multi-concept diagrams, **each major concept must use a different visual
pattern**. No uniform card grids.

| If the concept...        | Use this pattern                                |
|--------------------------|-------------------------------------------------|
| One-to-many              | **Fan-out** (radial arrows from a center)       |
| Many-to-one              | **Convergence** (arrows funneling into one)     |
| Sequence of steps        | **Timeline** (line + dots + free-floating text) |
| Hierarchy / nesting      | **Tree** (lines + free-floating text)           |
| Loop / cycle             | **Spiral / Cycle** (arrow returning to start)   |
| Abstract state / context | **Cloud** (overlapping ellipses)                |
| Transformation           | **Assembly line** (before → process → after)    |
| Comparison               | **Side-by-side** (parallel with contrast)       |
| Phase separation         | **Gap/break** (visual whitespace)               |

### Container Discipline

Default to **free-floating text**. Add a container only when:

- It's the focal point of a section.
- An arrow needs to connect to it.
- The shape itself carries meaning (decision diamond).
- It represents a distinct "thing" in the system.

Typography (font size + color) creates hierarchy without boxes. **Aim for
<30% of text elements wrapped in containers.**

### Color as Meaning

Colors encode information, not decoration. The sideclaw skill prompt owns the
palette — don't redefine colors here. When telling the tool what to make,
describe roles ("primary action", "external dependency", "error state",
"cached/secondary path") rather than hex values. The worker will pick the right
swatch.

---

## Process

### Step 0: Assess depth
Simple/conceptual or comprehensive/technical? Tell the tool which.

### Step 1: Understand deeply
For each concept, ask: what does it DO? What relationships exist? What would
someone need to SEE to understand it (not just read about)?

### Step 2: Map concepts to patterns
Each major concept gets a different visual pattern from the table above.

### Step 3: Sketch the flow
Trace how the eye moves through the diagram. Left→right or top→bottom for
sequences, radial for hub-and-spoke. There should be a clear visual story.

### Step 4: Compose the tool prompt
Pass a *design brief* to `mcp__sideclaw__excalidraw_diagram`:

- The subject of the diagram (be specific — actual system / actual concept).
- The depth mode you chose (conceptual or technical).
- The visual patterns for each major concept ("fan-out from build to deploy,
  convergence on the database, timeline along the bottom for the lifecycle").
- Evidence artifacts to include (which real names, which sample payloads).
- Any zone groupings ("CI block on the left, deploy block on the right").
- Camera/viewport hint if relevant (default is 800×600).

The worker handles colors, sizes, fonts, bindings, and JSON shape.

### Step 5: Call the tool
```
mcp__sideclaw__excalidraw_diagram({
  prompt: "<design brief>",
  outputPath: "/absolute/path/to/diagram.excalidraw",
  mode: "create" | "extend"   // default "create"
})
```

The tool returns `{ outputPath, elementCount, viewport, hydratedBytes }`.

### Step 6: Hand the file to the user
Tell the user where it landed and how to open it (browser at
`https://sideclaw.test` for sideclaw, drop into the brain vault for Obsidian,
drag onto canvas for excalidraw.com).

If the user wants edits, call again with `mode: "extend"` and the same path.

---

## Quality Checklist (before declaring done)

### Depth & evidence (technical diagrams)
1. Research done — actual specs, formats, event names looked up?
2. Evidence artifacts present — code snippets, JSON examples, real data?
3. Multi-zoom — summary flow + section boundaries + detail?
4. Concrete over abstract — real content shown, not just labeled boxes?
5. Educational value — could someone learn something from this?

### Conceptual
6. Isomorphism — does each visual structure mirror its concept's behavior?
7. Argument — does the diagram SHOW something text alone couldn't?
8. Variety — does each major concept use a different visual pattern?
9. No uniform containers — avoided card grids and equal boxes?

### Container discipline
10. Minimal containers — could any boxed element work as free-floating text?
11. Lines as structure — tree/timeline patterns using lines + text, not boxes?
12. Typography hierarchy — font size and color creating visual hierarchy?

### Delivery
13. File written and reported back to the user.
14. User knows which app to open it in (sideclaw / Obsidian / excalidraw.com).
15. If extending an existing diagram, used `mode: "extend"` (not "create").

---

## Failure modes to avoid

- **Bypassing the tool** to write `.excalidraw` JSON directly. Don't —
  hand-rolled JSON corrupts arrow bindings, missing `versionNonce`, broken
  containers. The tool exists to make this reliable.
- **Specifying hex colors in your prompt.** Describe roles, not colors. The
  worker has a curated palette.
- **Asking for camera sizes outside 4:3.** Stick to listed sizes
  (`400×300`, `600×450`, `800×600`, `1200×900`, `1600×1200`).
- **Skipping the design assessment.** A request like "draw the auth flow" is
  too vague to produce a good diagram — clarify depth and patterns first.
- **Writing diagram files to arbitrary project repos.** Default to the brain
  vault — most diagrams belong there, not in a project repo.
