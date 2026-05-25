# Fish S2 Pro — Production TTS

> **Selection rationale moved.** Why Fish S2 Pro, the expressiveness/emotion-tag case, the German tier-2 limitation, and the reference-clip tuning insight now live in `modelpick/docs/decisions/audio-stack.md`. This file retains operational config (endpoints, voice IDs, EQ chain, budgets).

The Hermes / Claude Code text-to-speech engine on this Mac. Replaces Voxtral.
Runs as `com.localai.fish` on `127.0.0.1:8002`, launchd-managed, model warm-loaded
at boot. Called by `localai-helper:8001` for orchestrated TTS.

## Locked production config

| Lang | Reference | Output post-process |
|-|-|-|
| **de** | `voices/pip_cut_smile_de.wav` — Pip Klöckner snippet, Audacity-cut, smile EQ baked into the reference | Smile EQ (highpass + scoop + presence + air) applied via ffmpeg, then `loudnorm` to -16 LUFS |
| **en** | `voices/ethan_en.wav` — fish.audio S2 demo voice "Ethan" (warm/expressive American male) | `loudnorm` only — fish.audio's reference quality holds up raw |

The smile EQ chain lives in `server.py:SMILE_EQ_CHAIN` (static EQ filters only).
Loudness normalization runs in `localai-helper` after concatenating chunks —
per-chunk `loudnorm` would produce audible loudness drift across chunk seams.

The helper sends `post_process=False` to this server for chunked long-form
synthesis and applies a single ffmpeg pass over the concatenated audio. One-shot
direct calls (`curl /v1/audio/speech`) get the EQ inline for convenience but
no `loudnorm` — that's by design.

## Endpoints

```
GET  /health              — liveness probe
GET  /v1/models           — list loaded reference voices
POST /v1/audio/speech     — OpenAI-compatible TTS
```

Request body (matches OpenAI shape so existing clients work):

```json
{
  "model": "fish-s2-pro",
  "input": "text to speak",
  "voice": "de" | "en",
  "response_format": "wav" | "mp3",
  "max_new_tokens": 1536
}
```

Legacy Voxtral preset names (`de_male`, `neutral_male`, etc.) map to language
codes automatically — anything starting with `de` → `de`, everything else → `en`.

## Layout

```
fish-s2-pro/
  README.md          — this
  REFERENCE.md       — Fish S2 Pro API, parameters, emotion tag taxonomy, lessons
  server.py          — production server (warm-loaded model, smile EQ)
  voices/
    pip_cut_smile_de.{wav,txt,json}   — DE production reference
    ethan_en.{wav,txt,json}           — EN production reference
    _source/pip_audacity.wav          — raw Audacity cut, archived for reproducibility
```

## Adding a voice

Drop three files into `voices/`:

```
voices/<id>.wav     # 5–15 s clean speech, mono, any sample rate
voices/<id>.txt     # exact transcript of the wav
voices/<id>.json    # {"label": "...", "lang": "en|de", ...}
```

Wire the new id into `server.py:_VOICES` (language → id mapping). If the language
needs output post-processing, add it to `_POST_EQ`.

## Emotion tags

Inline `[tag]` syntax is first-class in Fish S2 Pro. Hermes can include any of:

```
[chuckle] [whisper] [pause] [emphasis] [excited] [sigh]
[professional broadcast tone] [narrator tone] [low voice] …
```

See `REFERENCE.md` for the full taxonomy and patterns that work.

## Operations

```bash
# launchd state
launchctl list | grep com.localai.fish

# manual restart (KeepAlive=true, kill triggers respawn)
launchctl kickstart -k gui/$(id -u)/com.localai.fish

# logs
tail -f /tmp/fish.log
tail -f /tmp/fish.err

# verify
curl http://127.0.0.1:8002/health
curl -X POST http://127.0.0.1:8002/v1/audio/speech \
  -H "Content-Type: application/json" \
  -d '{"input":"Test","voice":"de","response_format":"wav"}' \
  -o /tmp/test.wav
```

## Why Fish S2 Pro

Decided after multi-step listening evaluation (April 2026):

- **Voxtral 4B**: Tier-1 German, but emotionally flat, no inline emotion tags. The previous baseline.
- **Ben** (fish.audio library): clean and warm but "Schlaftablette" — too documentary for daily use
- **Tim Peters / Paluten**: too energetic / too gaming-kid for the use case
- **Pip Klöckner snippet**: real human voice from a personal recording. Best baseline, BUT only after Audacity-cut + smile EQ on the reference. Raw Pip = too dumpf.
- **Ethan / James** (fish.audio S2 demos): both excellent. Ethan picked for the natural laugh and warmth.

The biggest non-obvious lesson: **reference clip quality dominates output quality**. Fish clones the timbre AND cadence of the reference. Synthetic voices (macOS Daniel, Voxtral output) clone-of-clone catastrophically. Real human voice → real human output. EQ on the reference itself (not just on the output) measurably shapes how the model speaks.

The +5% atempo trick on the reference clip energized "Ben" but wasn't needed for Pip — Pip's natural cadence is already engaging.

## License

Fish Audio Research License — non-commercial. Personal Hermes use only.
For commercial: business@fish.audio.
