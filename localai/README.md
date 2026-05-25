# LocalAI Stack — Per-Machine TTS + STT

> **⚠️ RETIRED 2026-05-25.** This local stack (mlx-audio STT :8000, Fish S2 Pro TTS :8002, localai-helper :8001) is no longer installed by `make setup` and no longer runs. TTS/STT moved to the **cloud audio-proxy** (`~/SourceRoot/audio-proxy`, OpenAI-compatible on :7716) which fronts the IU unified audio endpoint. Hermes and MacWhisper now point at the proxy (`https://audio-proxy.test/v1`). Everything in this directory is **kept, not deleted**, so the stack can be re-added later by re-listing `_setup-localai` in the Makefile setup chain. To tear down a machine that still has it loaded: `make localai-teardown`. The rest of this file documents the stack as it was.

> **Model-selection rationale moved.** Why Fish S2 Pro (TTS) + Parakeet (STT), the rejected-alternatives eval, and the reference-clip-quality insight now live in `modelpick/docs/decisions/audio-stack.md`. This file retains the operational stack (ports, services, warm-up, wiring).

Each Mac runs three local services:
- `mlx-audio` :8000 — STT only (Parakeet)
- `fish-s2-pro` :8002 — TTS (Fish S2 Pro, both DE and EN)
- `localai-helper` :8001 — orchestration (Hermes-only)

Installed automatically by `make setup`.

## Architecture

```
Hermes (tts_tool.py)        →  http://127.0.0.1:8001/v1/tts/synthesize  (helper)
MacWhisper / strict clients →  https://whisper.test/v1/...               (Caddy)
                                  ├─ /v1/audio/transcriptions → :8001 (helper, response transform)
                                  └─ /v1/*                     → :8000 (mlx-audio direct)

mlx-audio          (com.localai.audio,  127.0.0.1:8000)
  POST /v1/audio/transcriptions → STT  (warm on launchd start)
  GET  /v1/models               → list of currently-loaded models

fish-s2-pro        (com.localai.fish,   127.0.0.1:8002)
  POST /v1/audio/speech         → TTS  (warm on launchd start)
                                  voice: "de" | "en" — DE applies smile EQ post,
                                  EN passes through raw
  GET  /v1/models               → loaded reference voices
  GET  /health                  → liveness probe

localai-helper     (com.localai.helper, 127.0.0.1:8001)
  POST /v1/tts/synthesize       → TTS orchestration: language detect → speakable
                                  rewrite (Haiku, only when markdown-heavy) →
                                  title (Haiku) → pysbd-segmented paragraph-aware
                                  chunking (800-char default — Metal cap on M2 Pro) → Fish synthesis at
                                  :8002 with dynamic max_new_tokens per chunk and
                                  post_process=False → 5 ms edge fades + break-aware
                                  silence (300 ms sentence / 600 ms paragraph) →
                                  numpy concat → single ffmpeg pass: smile EQ (DE)
                                  + loudnorm to -16 LUFS → MP3 → base64 JSON
  POST /v1/audio/transcriptions → forwards to mlx-audio + transforms
                                  Parakeet's {text, sentences} into OpenAI's
                                  verbose_json {text, segments, language,
                                  duration, task} for strict clients.
  GET  /health                  → liveness probe

  Extension point — drop new modules in `helper/routes/` for additional
  local processing. Helper runs in mlx-audio's uv venv (fastapi + httpx +
  soundfile + numpy available). Anthropic API credentials injected from
  Keychain at launchd start for Haiku calls.
```

LLM is no longer local — Hermes uses the IU unified endpoint (Anthropic-compatible path) for all chat completions.

## Models

### STT: NVIDIA Parakeet TDT v3

| Model | Size | Languages | Speed |
|-|-|-|-|
| **mlx-community/parakeet-tdt-0.6b-v3** | 1.2 GB | 25 EU langs incl. EN/DE | 10–60× RT |

Always-warm: the launchd wrapper script (`bin/start-mlx-audio.sh`) fires a warm-up transcription right after server boot so the model stays resident in `ModelProvider.models[]` for the process lifetime.

**Why Parakeet, not Whisper:** Tried Whisper Turbo but mlx-audio 0.4.2 has a bug — `load_model()` doesn't attach `WhisperProcessor`, so `get_tokenizer()` raises `Processor not found`. Patching to load the processor at request time triggers an MLX Metal threading crash (`There is no Stream(gpu, 2) in current thread`). Parakeet works cleanly.

**MacWhisper:** Point at `https://whisper.test` — Caddy proxies `/v1/audio/transcriptions` through `localai-helper` which transforms the response into OpenAI verbose_json shape (`{text, segments, language, duration, task}`). Other paths go direct to mlx-audio. Model: `mlx-community/parakeet-tdt-0.6b-v3`. API key: any non-empty string.

### TTS: Fish S2 Pro (8-bit MLX)

| Model | Size | Voices | Notes |
|-|-|-|-|
| **appautomaton/fishaudio-s2-pro-8bit-mlx** | 6.7 GB | clone-only, 2 production refs (de/en) | ~2–10× RTF on M2 Pro depending on chunk length |

**Production reference clips** (in `fish-s2-pro/voices/`):
- `pip_cut_smile_de` — Pip Klöckner snippet, manually cut in Audacity, smile EQ baked into the reference itself. The helper applies the same smile EQ chain (highpass+scoop+presence+air via ffmpeg) plus `loudnorm` once to the concatenated audio. The Fish server can also apply the EQ inline (one-shot direct calls) but `loudnorm` runs only at the helper to keep loudness stable across chunks.
- `ethan_en` — fish.audio's own demo voice "Ethan" (warm/expressive American male). The helper still runs `loudnorm` on EN output for consistent listening level; no smile EQ.

**Fish S2 Pro is clone-only** — no stock voice presets. Each synthesis call needs a paired `reference_audio` + `reference_text`. Both refs are loaded once at server startup.

**Inline emotion tags** are first-class: `[chuckle]`, `[whisper]`, `[excited]`, `[pause]`, `[emphasis]`, etc. Fish accepts 15,000+ free-form tags. See `fish-s2-pro/REFERENCE.md` for the taxonomy.

**Warm on launchd start** — `start-fish.sh` loads the model and fires a short German synthesis at boot so the first real request hits a hot pipeline.

All TTS calls from Hermes go through `localai-helper:8001/v1/tts/synthesize` which detects language, picks the matching ref via `voice: "de"|"en"`, and calls Fish at `:8002`. The smile EQ for German is applied server-side by Fish.

## Files

| File | Purpose |
|-|-|
| `com.localai.audio.plist.template` | mlx-audio launchd plist (templated — `__HOME__` substituted at install) |
| `com.localai.fish.plist.template` | Fish S2 Pro TTS launchd plist (templated) |
| `com.localai.helper.plist.template` | localai-helper launchd plist (templated) |
| `bin/start-mlx-audio.sh` | Wrapper: starts mlx-audio + fires STT warm-up curl |
| `bin/start-fish.sh` | Wrapper: starts Fish S2 Pro server via uv (mlx-speech venv) |
| `bin/start-localai-helper.sh` | Wrapper: starts the FastAPI helper using mlx-audio's venv |
| `helper/server.py` | FastAPI app — extension point for local processing |
| `helper/routes/tts.py` | TTS orchestration — calls Fish at :8002, applies chunking + Haiku rewrite |
| `helper/routes/macwhisper.py` | OpenAI verbose_json transform for STT |
| `fish-s2-pro/server.py` | Fish S2 Pro TTS server (warm-loaded model, smile EQ for DE) |
| `fish-s2-pro/voices/` | Production reference clips (Pip + Ethan) |
| `patches/mlx-audio-m4a-stt.patch` | m4a/aac/mp4/ogg/opus/webm transcoding via ffmpeg (Slack voice memos) |

Re-apply the patch after `uv tool upgrade mlx-audio`. `_setup-localai` does this idempotently.

## Setup

```bash
make setup           # Full setup — runs _setup-localai automatically
make _setup-localai  # Just the localai chunk (mlx-audio + deps + ffmpeg + patch + plist)
make localai-setup   # Just (re)render the audio plist + reload
make start           # launchctl load com.localai.audio
make stop            # launchctl unload com.localai.audio
```

First run downloads:
- ~2 GB of Python deps for mlx-audio (STT venv)
- ~250 MB of mlx-speech deps (TTS venv, separate Python 3.13)
- Parakeet (1.2 GB) on first STT request
- Fish S2 Pro 8-bit (6.7 GB) on first TTS request

All cached at `~/.cache/huggingface/hub/` and warmed by the launchd wrappers at next boot.

## Verify

```bash
# mlx-audio (STT) reachable
curl http://127.0.0.1:8000/v1/models

# Fish (TTS) reachable
curl http://127.0.0.1:8002/health
curl http://127.0.0.1:8002/v1/models

# Transcribe
curl -X POST http://127.0.0.1:8000/v1/audio/transcriptions \
  -F "model=mlx-community/parakeet-tdt-0.6b-v3" \
  -F "file=@audio.m4a"

# Synthesize (Fish S2 Pro)
curl -X POST http://127.0.0.1:8002/v1/audio/speech \
  -H "Content-Type: application/json" \
  -d '{"input":"Hallo zusammen.","voice":"de","response_format":"mp3"}' \
  --output out.mp3

# Tail server logs
tail -f /tmp/audio.log     # mlx-audio
tail -f /tmp/fish.log      # Fish S2 Pro
tail -f /tmp/helper.log    # orchestrator (when present)

# Tail mlx-audio warm-up log
cat /tmp/mlx-audio-warmup.log
```

## Hermes Integration

`~/.hermes/config.yaml`:

```yaml
stt:
  provider: "openai"
  openai:
    model: "mlx-community/parakeet-tdt-0.6b-v3"
    base_url: "http://127.0.0.1:8000/v1"
    api_key: "not-needed"

tts:
  provider: "openai"
  openai:
    model: "fish-s2-pro"
    voice: ""
    base_url: "http://127.0.0.1:8001/v1"  # helper, not Fish direct
    api_key: "not-needed"
```

TTS calls from Hermes go through `localai-helper:8001` (`tts_tool.py` → `POST /v1/tts/synthesize`). The helper detects language, applies Haiku rewrites for markdown-heavy input, paragraph-aware chunks, calls Fish S2 Pro at `:8002` with the right reference voice, and base64-encodes the MP3. Production references and the smile EQ chain live in `fish-s2-pro/`.

## Rejected Alternatives

| Tool | Why |
|-|-|
| Ollama (Gemma 4 local) | Cloud Sonnet 4.6 cheaper than M2 Max electricity for light use; better agent quality |
| LocalAI (mudler) | llama.cpp not MLX (40-90% slower) |
| WhisperKit | `serve` unreliable, fragile Swift build |
| whisper-large-v3-turbo | Replaced by Parakeet v3 — 25% smaller, ~3× faster, similar accuracy |
| Voxtral 4B TTS (Mistral) | Was the prior TTS — German at Tier-1, but emotionally flat, no inline emotion tags. Replaced by Fish S2 Pro for expressiveness. |
| Qwen3-TTS VoiceDesign | English-accented German output ("Hasselhoff effect") — VoiceDesign instruct path is Chinese/English-only by design |
| Qwen3-TTS Base + voice clone | Better German quality but requires server-accessible WAV reference; Voxtral preset was simpler at the time |
| F5-TTS-German | Documented umlaut bug requiring Ä→ae preprocessing; fragile for production |
| Piper TTS (thorsten-de) | Native German phonetics but robotic |
| Kokoro-82M | Fastest of the lot but emotionally flat ("talented narrator reading, not performing") |
| Orpheus-3B | Best inline emotion tag support but MPS broken on Mac, only viable via CPU/Ollama |
| VibeVoice (Microsoft) | Robotic intonation per HN consensus, male voices admittedly weaker due to training-data skew |

**Last model research:** 2026-04-29 — Fish S2 Pro 8-bit MLX promoted to production after side-by-side blind comparison vs Voxtral, Ben (fish.audio library), Tim Peters, Paluten, and the unprocessed Pip recording.
