# IU Unified Endpoint — Multimodal Exploration

> **Decision rationale moved.** The vision/image model choices (gemini-3-pro for dense diagrams, gpt-image-2, EU/US residency table, the stateless-HTTP-vs-agent-loop placement) now live in `modelpick/docs/decisions/vision-and-image.md`. This file retains the operational exploration notes and wiring.

*Exploration / decision memo. Not yet implemented. Written 2026-05-22 after empirically
verifying that the IU unified endpoint serves image, vision, TTS, and STT — not just chat.*

## TL;DR

The IU unified endpoint (`<iu-unified-endpoint>`) is **not** chat-only.
The OpenAI transport already serves image generation, **image understanding (vision input)**,
TTS, and STT — and there's a separate Replicate transport for the long tail (flux, SDXL,
many audio/video models). Everything below was verified live with the `op://common/anthropic` key.

This unlocks three concrete improvements, in rough order of value:

1. **`read-drawing` and `browse` can read images with stronger models than Anthropic Haiku** —
   and the read step is a *stateless HTTP call*, so it belongs as a sideclaw HTTP tool, not a `claude -p` agent session.
2. **A new general `vision`/`read-image` capability** in sideclaw — one direct fetch, no Kimi worker, no Max quota.
3. **TTS/STT could move off the local `mlx-audio`/Fish stack to hosted IU models** — *but only the
   Azure-Sweden (EU) audio models pass the GDPR bar*; the OpenAI-vendor ones (US) do not. See the residency table.

## Verified capability matrix

| Capability | Transport / endpoint | Working model(s) | Status | Data residency |
|-|-|-|-|-|
| Chat | `/openai/v1/chat/completions` | `gpt-4.1-mini`, … | ✅ 200 | mixed (per model) |
| **Vision input** (image → text) | `/openai/v1/chat/completions` (`image_url` content) | `gpt-4.1-mini`, `gpt-5.5`, `gemini-3-pro-preview` | ✅ 200 | mixed (per model) |
| **Image generation** | `/openai/v1/images/generations` | `gpt-image-1` (b64 PNG out) | ✅ 200 | ⚠️ **US** (OpenAI vendor key) |
| Image generation (legacy) | same | `dall-e-3` | ❌ 410 deprecated | — |
| **TTS** | `/openai/v1/audio/speech` | `tts`, `tts-hd` | ✅ 200 (`audio/mpeg`) | ✅ **EU** (Azure Sweden Central) |
| **STT** | `/openai/v1/audio/transcriptions` | `whisper` | ✅ 200 | ✅ **EU** (Azure Sweden Central) |
| STT (newer) | same | `gpt-4o-transcribe`, `gpt-4o-mini-transcribe` | ✅ works | ⚠️ **US** (OpenAI vendor key) |
| **Replicate** | `/replicate/v1/predictions` | `hello-world`, `black-forest-labs/flux-schnell` | ✅ 201 | vendor (Replicate, US) |

### Two gotchas worth remembering

- **Image gen "wasn't working" before because of `dall-e-3`** — it now returns `410 ModelDeprecated`.
  Use `gpt-image-1` / `gpt-image-1-mini` / `gpt-image-1.5` / `gpt-image-2` instead.
- **STT rejects uploads without a recognized file extension.** `file=@audio.bin` → `503 Invalid file format`;
  `file=@audio.mp3` → `200`. The middleware sniffs the *filename*, not the bytes. Supported:
  `flac, m4a, mp3, mp4, mpeg, mpga, oga, ogg, wav, webm`.
- **Replicate auth** accepts both the documented `api-key: <key>` header **and** `Authorization: Bearer <key>`
  — same key as everything else. `prefer: wait` makes it synchronous; otherwise poll
  `GET /replicate/v1/predictions/{id}`. Run a model by name (no version hash) via
  `POST /replicate/v1/models/{owner}/{name}/predictions`.

## Data residency — the deciding factor for audio

The middleware exposes the serving backend in response headers (`x-ms-region`,
`x-middleware-forwarded-server`). Verified:

| Model | `x-middleware-forwarded-server` | EU? |
|-|-|-|
| `tts` | `IU AI Middleware Sweden Central Azure` (`x-ms-region: Sweden Central`) | ✅ EU |
| `whisper` | Sweden Central Azure (seen in error path) | ✅ EU |
| `gpt-image-1` | `OpenAI Vendor Group Key` | ❌ US |
| `gpt-4o-transcribe` | `OpenAI Vendor Group Key` | ❌ US |

**Implication:** anything carrying personal/voice content should stay on the Azure-Sweden models
(`tts`, `tts-hd`, `whisper`) or the `*-eu` Claude aliases. The OpenAI-vendor models (gpt-image,
gpt-4o-transcribe) route to OpenAI in the US — fine for non-personal content (a diagram already in git),
not for arbitrary recorded speech. This is the same EU/US split documented for the chat catalog in CLAUDE.md.

## Model inventory (relevant subset)

- **Vision-capable chat:** `gpt-4.1-mini`, `gpt-5.5`, `gemini-3-pro-preview`, `gemini-3-flash-preview`,
  plus the `claude-*-eu` aliases (EU-guaranteed, multimodal).
- **Image gen:** `gpt-image-1{,-mini,.5}`, `gpt-image-2`, `gemini-3-pro-image-preview`, `gemini-2.5-flash-image`.
- **TTS:** `tts`, `tts-hd` (EU), `gpt-4o-mini-tts`, `gpt-audio*`, `gemini-*-tts`, `voxtral-mini-tts` (Mistral).
- **STT:** `whisper` (EU), `gpt-4o-transcribe`, `gpt-4o-mini-transcribe`, `gpt-4o-transcribe-diarize` (diarization!), `voxtral-mini-transcribe`.

## The key architectural insight

There are **two fundamentally different shapes of work**, and they want different homes:

| Shape | Examples | Right home | Cost |
|-|-|-|-|
| **Stateless single HTTP call** | read one image, generate one image, TTS a string, transcribe a file | **sideclaw HTTP tool** — direct `fetch` to the IU transport | ~0 (IU per-token, no Max, no Kimi worker) |
| **Multi-step agent session** | drive Chrome, navigate + click + inspect + screenshot | agent loop (Claude Code subprocess / MCP session) | depends on driver model |

Today both `read-drawing` and `browse` conflate these:

- `read-drawing` spins up a **whole `claude -p` Haiku agent** just to do what is really *one* vision call
  plus some local JSON parsing. The agent overhead (cold spawn, tool loop) buys nothing here.
- `browse` runs a **Haiku fork on Max quota** to drive chrome-devtools *and* interpret screenshots with
  Anthropic vision. The driving genuinely needs an agent loop; the *screenshot interpretation* is again one vision call.

So the migration isn't "move the skill into sideclaw" wholesale — it's **split each skill into (a) the
stateless vision/audio call, which becomes a cheap sideclaw HTTP tool, and (b) the orchestration, which
stays where it makes sense.** sideclaw's worker model (Kimi-K2.6) is text-only and irrelevant here —
these new tools are *direct fetches*, they never spawn a Kimi or Claude session.

## Direction 1 — `read-drawing` → sideclaw `read_image` / `read_drawing` tool

**Today:** `/read-drawing` → `claude_iu` Haiku subprocess → reads `.svg` (vision) + `.excalidraw` JSON, synthesizes.

**Proposal:** a sideclaw HTTP tool `read_drawing({ path })` that:
1. Renders/loads the `.svg` (or `.png`) and does **one** `/openai/v1/chat/completions` vision call with
   `gemini-3-pro-preview` or `gpt-5.5` (both beat Haiku on diagram structure) — or `claude-sonnet-4-6-eu` if EU is wanted.
2. Parses the paired `.excalidraw` JSON in-process (the schema rules already in the skill — containerId, bindings, groups).
3. Returns the structured synthesis as the tool result.

**Wins:** stronger vision model, no `claude -p` cold-spawn, off Max, schema-validated output, parallelizable.
**Caveat:** diagram content is usually non-sensitive (already in git) → US-routed `gpt-5.5`/`gemini` is acceptable;
use `claude-sonnet-4-6-eu` if a given diagram is sensitive. Keep `claude_iu` as a fallback only if a model regresses.

**Open question:** SVG → the IU vision endpoint may need rasterization to PNG first (most vision models don't take raw SVG).
Excalidraw already exports PNG; or rasterize with a headless render. Worth a quick spike.

## Direction 2 — `browse` screenshot interpretation

**Today:** Haiku fork on **Max quota** drives chrome-devtools and interprets screenshots with Anthropic vision.

**Proposal:** keep the Chrome-driving agent loop (it's genuinely multi-step and needs a live MCP), but:
- Route **screenshot interpretation** through the same `read_image` tool (stronger model, off Max).
- Consider whether sideclaw can *host* chrome-devtools MCP so the whole browse flow detaches from Max —
  this is a bigger lift (sideclaw becomes an MCP *client*, manages a Chrome lifecycle) and may not be worth it
  vs. the cheap win of just upgrading the vision step. **Recommend: do the vision-step upgrade first, defer the full move.**

## Direction 3 — TTS / STT: local `mlx-audio`+Fish → hosted IU

**Today:** three local launchd services (Parakeet STT :8000, Fish S2 Pro TTS :8002, helper :8001).
Stable, free, fully private, expressive (Fish emotion tags, cloned DE/EN voices, smile EQ).

**Hosted option:** `whisper` (EU) for STT, `tts`/`tts-hd` (EU) for TTS — both free via IU, both Azure Sweden.

**Honest assessment — this one I'd be cautious about:**

| Factor | Local (mlx-audio + Fish) | Hosted IU (whisper / tts) |
|-|-|-|
| Privacy | Fully local, nothing leaves the Mac | EU (Azure Sweden) — good, but voice *does* leave the device |
| Cost | Free (electricity) | Free (IU per-token) |
| Voice quality | Fish S2 Pro: cloned DE/EN voices, emotion tags, smile EQ — **highly tuned** | OpenAI `tts` stock voices — generic, no cloning, no emotion tags |
| Latency | Local, no network; warm models | Network round-trip + EU region |
| Offline | Works offline | Needs connectivity + IU uptime |
| Maintenance | mlx-audio patches, Metal quirks, launchd | None |

**Tendency:** the TTS side is a **downgrade** if moved — Fish's cloned voices + emotion tags +
smile EQ are the whole point of Hermes's voice identity, and stock `tts` voices throw that away.
STT is more of a wash: `whisper` (EU) is a credible Parakeet replacement and would *remove* the
mlx-audio Whisper-bug/Metal-crash maintenance burden — but Parakeet already works and is faster locally.

**Recommendation:** keep local TTS (voice identity matters). Treat hosted `whisper` as a **fallback/redundancy**
for STT (e.g. when the local stack is down, or for batch transcription where the local Metal cap hurts),
not a replacement. `gpt-4o-transcribe-diarize` is the one genuinely new capability (speaker diarization)
the local stack can't do — worth keeping in mind for meeting/multi-speaker use cases, accepting US routing for that.

## Recommended sequence

1. **Spike `read_image` as a sideclaw HTTP tool** (one vision call, model configurable). Smallest, highest-leverage.
2. **Re-point `read-drawing`** at it (SVG→PNG rasterization spike included). Retire the `claude_iu` agent path.
3. **Upgrade `browse`'s screenshot step** to `read_image`; defer the full chrome-into-sideclaw move.
4. **Add hosted `whisper` STT as a documented fallback** to `/localai`; leave TTS local.
5. Optionally expose **image generation** (`gpt-image-1`) and **Replicate** as sideclaw tools if a real use case appears
   (e.g. diagram/asset generation) — no current consumer, so build on demand.

## POC results (2026-05-22) — image gen + diagram-reading bake-off

Ran the spike. Two findings dominate.

### Finding 1 — rasterization fidelity is the real bottleneck, not the model

SVG→PNG on this Mac, without `brew install`-ing anything new, is the hard part:

| Method | Result | Verdict |
|-|-|-|
| `qlmanage -t -s 1600` | correct fonts, but **forces a square thumbnail → crops wide diagrams** | ✗ |
| `svglib` (pure-Python, no native deps) | correct geometry/colors/aspect, but **all text → tofu boxes** (no font resolution) | ✗ |
| `cairosvg` | `libcairo` not on dlopen path (brew `cairo` exists but unlinked) | ✗ (fixable) |
| **headless Google Chrome** (`--screenshot` of an HTML-wrapped `<img src=svg>`) | **faithful — browser fonts, full aspect, every label legible** | ✅ |

Chrome is the gold standard (it's literally a browser). Wrap the SVG in a tiny HTML at native
`width`/`height` (read from the SVG header) and `--screenshot`. For `.excalidraw` inputs the most
faithful path is Excalidraw's own PNG export (sideclaw already embeds Excalidraw) — but Chrome-rendering
the committed `.svg` is simpler and covers any SVG, including non-Excalidraw screenshots.

### Finding 2 — model quality only separates on *dense* diagrams

Two diagrams, identical structural prompt, `temperature:0`:

**Simple diagram** (`read-drawing-example`, ~6 nodes): **every model was 100% correct.** Haiku was
fastest (3.8s) and cheapest. gpt-4.1-mini also perfect. gemini pro/flash perfect but 3× slower.
`gpt-5.5` returned a transient `503` (single-backend throttle).

**Dense diagram** (`claude-workflow`, 4 nested frames, ~14 multi-line nodes, bidirectional edges):

| Model | Latency | Accuracy on the dense diagram |
|-|-|-|
| **gemini-3-pro-preview** | 27.4s | **Best.** All 4 frame names correct, every node in the right frame, *noticed and flagged the double-arrowhead bidirectional edges*. |
| **gemini-3-flash-preview** | 13.6s | **Best balance.** All 4 frames + correct node placement; missed only the bidirectional nuance. |
| claude-haiku-4-5 | 10.0s | Fast but **flattened the frame hierarchy** — missed the `Supporting Skills` / `MCP spawn` frame names, mis-placed nodes, misread `Chrome MCP`→`ACP`. |
| gpt-4.1-mini | 17.3s | **Worst on nesting** — double-listed nodes, got tangled in overlapping frames. |

So your instinct was right: **Gemini (Flash/Pro) beats Haiku on dense diagram structure.** On simple
ones it's a tie and Haiku wins on cost/latency.

### The Excalidraw nuance that changes the model calculus

`read-drawing` also parses the paired `.excalidraw` JSON, which carries **exact** structure —
`frameId` (frame membership), `containerId` (label↔shape), arrow `startBinding`/`endBinding`, `groupIds`.
That JSON *covers Haiku's exact weakness* (frame flattening). So:
- **For Excalidraw** (`read-drawing`): JSON gives ground-truth structure; vision is supplementary →
  Haiku is adequate, Gemini-Flash a cheap upgrade for the visual gestalt.
- **For arbitrary screenshots** (`browse`, no JSON): vision quality is the *only* signal →
  **Gemini-3-Flash should be the default**, Gemini-3-Pro for hard cases.

### Image generation

`gpt-image-2` works and produced a clean, legible architecture diagram (blue boxes, arrows, a DB
cylinder) — genuinely usable for asset/diagram generation. Use `gpt-image-2`; `gpt-image-1*` also fine.
Reminder: image gen routes to the **OpenAI vendor key (US)** — fine for generated assets, not for PII.

### Recommendation (updated)

1. **Build the rasterizer on headless Chrome.** It's the actual engineering; the model is a swappable param.
2. **`read_image` sideclaw tool** → default `gemini-3-flash-preview`, configurable to `gemini-3-pro-preview`.
3. **`read-drawing`**: keep the JSON-parse path (it's the structural ground truth), swap the visual read
   from a `claude_iu` Haiku *agent* to a single Gemini-Flash vision *call*. Net: faster, off Max, better visual.
4. **`browse`**: route screenshot interpretation through `read_image` (Gemini-Flash) — biggest quality win there.
5. **Gen**: expose `gpt-image-2` as a tool only when a real consumer appears.

**Still open:** Gemini EU residency (Google vendor — region not exposed; treat as non-EU until verified —
acceptable for git-committed diagrams, not for sensitive screenshots → use `claude-sonnet-4-6-eu` there).

## What I deliberately did *not* do

- No production code changes yet — this remains a memo + verified spike (commands all run live).
- Didn't wire `cairo` for `cairosvg` (Chrome path is better anyway).
- Didn't verify `gemini` vision EU residency (Google vendor — region not exposed; assume non-EU until checked).
