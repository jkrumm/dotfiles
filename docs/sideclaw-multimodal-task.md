# Sideclaw task — add IU multimodal tools (vision read + image gen)

> Hand this to a Claude Code session started **inside `~/SourceRoot/sideclaw`**.
> You (sideclaw) are the expert on your own architecture, async-job model, logging, and usage
> telemetry — apply your own conventions; this brief specifies *what* and *why*, not your internals.
> Full background + verified curl evidence: `~/SourceRoot/dotfiles/docs/iu-multimodal-exploration.md`.

## Context

The IU unified endpoint (`https://<iu-unified-endpoint>`) serves far more than chat.
We empirically verified (see the memo) that its **OpenAI transport** (`/openai/v1/...`) does:
- **Vision input** (image → text) — `gemini-3-pro-preview` is the chosen model (best on dense diagrams).
- **Image generation** — `gpt-image-2`.

These are **stateless single HTTPS calls** — *not* Claude Code agent sessions. They must **not** go
through the LiteLLM bridge, `session-runner.ts`, `claude -p`, or the read-only allowlist machinery.
They are plain `fetch` calls to the IU OpenAI transport. That makes them cheap (IU per-token, zero Max,
zero bridge worker) and fast (a single call, well under the 60s MCP SDK timeout — see "sync vs async" below).

## Goal

Add two MCP tools to sideclaw:
1. **`read_image`** — interpret an image (or an SVG, after rasterizing) with `gemini-3-pro-preview`.
2. **`generate_image`** — generate an image with `gpt-image-2`.

Plus one composite that reuses `read_image`:
3. **`read_drawing`** — **fully owned by sideclaw.** One tool does the whole pipeline: rasterize the
   `.svg` → `read_image` for the visual gestalt, **and** parse the paired `.excalidraw` JSON for exact
   structure, then merge into a single response for the orchestrating / implementing agent. All the
   repetitive Python/TS (SVG→PNG, base64, vision call, JSON extraction, label/binding resolution) lives
   here once instead of being re-derived per caller. The JSON parse is the *structural ground truth* —
   `frameId`, `containerId`, arrow `startBinding`/`endBinding`, `groupIds` — and it covers the vision
   model's one weakness, frame-flattening on dense diagrams. The schema rules are spelled out in
   `dotfiles/skills/read-drawing/SKILL.md` — reuse them verbatim.
   **The dotfiles `/read-drawing` skill then becomes a thin wrapper** that just calls this tool (or is
   retired in favor of the MCP tool directly). The `claude_iu` Haiku subprocess path goes away.

`browse` integration is **out of scope** for this task — see the last section.

## Verified endpoint facts (use these exactly)

**Auth:** `Authorization: Bearer <IU_KEY>`. The IU key + base live in macOS Keychain as
`claude-sdk-api-key` and `claude-sdk-base-url` (the same credential the API-offload path and the
LiteLLM bridge already use; `op://common/anthropic` is the 1Password source). The base in Keychain
ends in `/anthropic`; derive the OpenAI base by string-replacing `…/anthropic` → `…/openai/v1`
(this is exactly what `opencode.json` does). Source it however fits your runtime (LaunchAgent env,
`.env`, or read Keychain at startup) — do **not** hardcode the key or hostname in tracked files.

**Vision read** — `POST {OPENAI_BASE}/chat/completions`:
```jsonc
{
  "model": "gemini-3-pro-preview",
  "temperature": 0,
  "messages": [{
    "role": "user",
    "content": [
      { "type": "text", "text": "<prompt>" },
      { "type": "image_url", "image_url": { "url": "data:image/png;base64,<B64>" } }
    ]
  }]
}
```
Response: `choices[0].message.content`. `usage` object is present — capture it (see Telemetry).

**Image gen** — `POST {OPENAI_BASE}/images/generations`:
```jsonc
{ "model": "gpt-image-2", "prompt": "<prompt>", "n": 1, "size": "1024x1024" }
```
Response: `data[0].b64_json` (base64 PNG). Decode and write to disk.
⚠️ **Gotcha:** `dall-e-3` is dead (`410 ModelDeprecated`) — only `gpt-image-{1,1-mini,1.5,2}` work.

**Models are fixed:** vision = `gemini-3-pro-preview`, image gen = `gpt-image-2`. Both route to their
vendor backend (non-EU) — that's accepted; no GDPR fallback, no EU model override. (A `model` param can
stay for future flexibility, but it is not a residency knob — don't add EU-aware branching.)

## Tool contracts (adapt names/shapes to your conventions)

**`read_image`**
- In: `{ path: string; prompt?: string; model?: string /* default "gemini-3-pro-preview" */ }`
- Behavior: if `path` is `.svg` → rasterize to PNG (see Rasterizer task) → base64; else read+base64
  the image. Default prompt = a structural diagram-reading prompt (reuse the bake-off prompt from the
  memo). POST as above. Return the model's text.
- Out: `{ text: string; model: string; latencyMs: number; usage?: {...} }`

**`read_drawing`**
- In: `{ path: string /* base path or .svg/.excalidraw */; model?: string }`
- Behavior: resolve `<base>.svg` + `<base>.excalidraw`; rasterize+`read_image` the SVG; parse the JSON
  per the schema rules in `dotfiles/skills/read-drawing/SKILL.md`; merge into the structured synthesis
  that skill already specifies (Diagram/Visual/Purpose/Components/Flows/Groups/Implementation-insight).
- Out: the structured synthesis + `usage`.

**`generate_image`**
- In: `{ prompt: string; model?: string /* default "gpt-image-2" */; size?: string; outputPath?: string }`
- Behavior: POST, decode `b64_json`, write PNG (default a temp path under your workspace). 
- Out: `{ path: string; model: string }`

## Sideclaw integration requirements (your wheelhouse — enforce them)

- **Logging:** emit your structured `/tmp/sideclaw.jsonl` events for each call (submit/start/done/fail
  with model, latency, byte sizes) consistent with how `check`/`review` log.
- **Token/cost telemetry — important:** these calls bypass the LiteLLM bridge, so the `usage-tracker`
  collector will **not** see them automatically. The OpenAI responses carry a `usage` block
  (prompt/completion tokens; image gen reports its own usage). Record it into your usage reporting
  (`server/routes/usage.ts` / `UsageTags` surface) so cost telemetry stays complete. Flag clearly if
  there's no clean seam for this — don't silently drop it.
- **Sync vs async:** a single vision call measured **~10–27s** for `gemini-3-pro-preview` (dense diagram),
  i.e. under the 60s MCP SDK timeout — so these can be **synchronous** MCP tools, no `job_wait` machinery.
  Confirm against your transport limits; if you'd rather route through the durable job store for
  consistency, that's your call — but don't add the bridge worker/session-runner path, these are direct fetches.
- **Conventions:** follow `.claude/rules/mcp-tools.md` for tool authoring; wrappers in
  `server/mcp/tools/`, schemas/logic where your other tools keep them, register in `server/mcp.ts`.
- **Failure modes to handle:** transient `503` (single-backend throttle — retry with small backoff;
  we saw `gpt-5.5` flap, gemini was stable), `410` for dead models, non-PNG image bytes.

## Rasterizer — research + human-validated POC (do NOT just pick one)

SVG→PNG fidelity is the actual hard part (the model is easy). We already proved on this Mac:
- `qlmanage -t -s N` → correct fonts but **crops** wide diagrams (forces square thumbnail). ✗
- `svglib` (pure-Python) → correct geometry but **all text → tofu boxes** (no font resolution). ✗
- `cairosvg` → `libcairo` not on the dlopen path (brew `cairo` is installed but unlinked). ✗ (fixable)
- **headless Google Chrome** (screenshot an HTML-wrapped `<img src=file://…svg width/height>`) →
  **faithful: browser fonts, full aspect, every label legible.** ✅ (Chrome is already effectively a
  dependency here — `ms-playwright` chromium is cached and your kiosk mode already spawns Chrome.)

**Task:** research and POC the cleanest *production* rasterizer, then **show me (human) the rendered
PNGs of `dotfiles/docs/diagrams/claude-workflow.svg` and `read-drawing-example.svg` for visual sign-off
before locking it in.** Candidates to weigh — decision criteria: font fidelity, aspect correctness,
dependency weight, speed, already-present:
- **resvg** (single static Rust binary, fast, good built-in font handling) — likely cleanest if fonts resolve.
- **librsvg / `rsvg-convert`** (brew) — solid, native dep.
- **headless Chrome** — most faithful, already present, but heavyweight per-call (process spawn).
- **Excalidraw native PNG export** (you embed Excalidraw already) — most faithful for `.excalidraw`
  specifically, but only covers Excalidraw, not arbitrary SVGs/screenshots.

Don't assume — verify font rendering on the two real diagrams above and let the human eyeball them.

## Out of scope here — `browse` (note for later)

`browse` is two different things glued together: (a) **driving** Chrome (navigate / console / network /
DOM — genuinely multi-step, needs the live `chrome-devtools` MCP which is registered in the *main* Claude
Code session, not in sideclaw) and (b) **interpreting** screenshots (one vision call). Only (b) overlaps
this work. Once `read_image` exists, `browse`'s screenshot step can call it for a stronger, off-Max read
while keeping the chrome-devtools driving in its fork. Moving the *whole* browse flow into sideclaw
(sideclaw becomes a chrome-devtools MCP client + owns a Chrome lifecycle) is a separate, bigger decision —
don't tackle it in this task. Just keep `read_image`'s contract clean enough that `browse` can call it on
a saved screenshot path later.

## Suggested order

1. Credential plumbing (OpenAI base derivation + key sourcing) — smallest, unblocks everything.
2. `generate_image` (`gpt-image-2`) — simplest, no rasterizer dependency. Validates the transport + telemetry seam.
3. Rasterizer research/POC → **human sign-off**.
4. `read_image` (on the chosen rasterizer).
5. `read_drawing` (compose `read_image` + Excalidraw JSON parse); retire the dotfiles skill's subprocess path.
