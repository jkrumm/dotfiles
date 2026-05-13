"""Supertonic-3 ONNX/CPU fast TTS — info-preserving with custom chunking.

POST /v1/tts/synthesize/fast
  Body (JSON):
    text:                  str    — text to speak (any length)
    lang_hint:             str?   — ISO code; auto-detected if absent
    speed:                 float  — playback speed, default 0.95
    english_only:          bool   — force English output; polish translates
                                    non-English input. Default true (M-series
                                    voices are English-tuned).
    polish:                bool   — run Haiku rewrite, default true
    paragraph_pause_secs:  float? — override paragraph-break silence

  Response (JSON): same shape as /v1/tts/synthesize.

What this path does differently from `tts.TTS.synthesize()`:
  - We pre-chunk paragraph→sentence at 280 chars and call the lower-level
    `_tts.model(...)` per chunk. The library's auto-chunker fixes inter-chunk
    silence at 0.3 s and omits edge fading, which on multi-paragraph output
    produces audible amplitude bumps at chunk boundaries.
  - 5 ms linear edge fades on each chunk (suppresses diffusion-boundary clicks).
  - Two-tier pauses: ~0.3 s after a sentence break, ~0.6 s after a paragraph
    break — same calibration as the Fish path so cadence feels consistent
    across both engines.
  - The polish prompt preserves every piece of information (no distillation).
    Short inputs stay short; multi-paragraph inputs render with paragraph-aware
    cadence. Polish may insert the literal `<breath>` tag inline once per long
    paragraph — Supertonic-3 renders this as an audible inhale, replacing dead
    silence with something natural.

Two roles, same shape:
  1. Standalone fast endpoint — short and long English voice memos.
  2. Internal fallback target — `synthesize_fast` is imported by routes/tts.py
     and called when the Fish path times out or errors.

Why a fast path exists at all:
  Fish-S2-Pro is the highest-Elo open-weights TTS but needs 6.7 GB Metal-
  resident weights. On a memory-pressed Mac, MLX weights get evicted and
  synthesis hangs. Supertonic-3 runs on ONNX Runtime/CPU at ~900 MB RSS;
  different memory pool, so it works while Fish is wedged. Quality is below
  Fish in blind eval but acceptable for ad-hoc memos.

  Supertonic-3 supports 31 languages (model card, 2026-04-29 release), but
  the M-series preset voices are English-tuned. The english_only + translate
  default keeps the voice profile coherent.
"""

import asyncio
import base64
import io
import os
import re
import subprocess

import httpx
import numpy as np
import soundfile as sf
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel
from supertonic import TTS

from routes.tts import (
    TTSResponse,
    _ANTHROPIC_KEY,
    _LOUDNORM,
    _PAUSE_AFTER,
    _chunk_text,
    _detect_lang,
    _fade_edges,
    _silence,
    _strip_markdown,
)

# Local Haiku client (separate from routes.tts._haiku) so we can log failures
# loudly instead of silently returning "" (we were shipping German-text-as-
# English-voice when the IU endpoint flaked because the shared helper
# swallowed every exception), and use a 30 s timeout vs the shared 15 s since
# polish output can be longer than a title and IU latency varies.
_ANTHROPIC_URL = os.getenv("ANTHROPIC_BASE_URL", "https://api.anthropic.com")
_HAIKU_MODEL = "claude-haiku-4-5-20251001"


async def _fast_haiku(system: str, user: str, max_tokens: int, label: str) -> str:
    if not _ANTHROPIC_KEY:
        print(f"[tts_fast.{label}] ANTHROPIC_API_KEY missing — skipping Haiku", flush=True)
        return ""
    try:
        async with httpx.AsyncClient(timeout=30.0) as client:
            r = await client.post(
                f"{_ANTHROPIC_URL.rstrip('/')}/v1/messages",
                headers={
                    "x-api-key": _ANTHROPIC_KEY,
                    "anthropic-version": "2023-06-01",
                    "content-type": "application/json",
                },
                json={
                    "model": _HAIKU_MODEL,
                    "max_tokens": max_tokens,
                    "system": system,
                    "messages": [{"role": "user", "content": user}],
                },
            )
            if r.status_code != 200:
                print(
                    f"[tts_fast.{label}] Haiku HTTP {r.status_code}: {r.text[:300]}",
                    flush=True,
                )
                return ""
            return r.json()["content"][0]["text"].strip()
    except Exception as e:
        print(f"[tts_fast.{label}] Haiku call failed ({type(e).__name__}): {e}", flush=True)
        return ""


router = APIRouter()

# Sam (M4): "A soft, neutral-toned male voice; gentle and approachable with a
# youthful, friendly quality." Matches the voice-memo aesthetic. Other M-series
# (verbatim from the Supertonic-3 demo Space VOICE_DESCRIPTIONS):
#   M1=Alex (lively, upbeat), M2=James (deep, robust, serious),
#   M3=Robert (polished, authoritative, broadcast-ready),
#   M5=Daniel (warm, soft-spoken storyteller).
_DEFAULT_VOICE = "M4"

# 12 inference steps = quality knob. Library default 5, demo CLI default 8.
# 12 trades a few hundred ms of CPU for cleaner prosody at memo length;
# >16 gives diminishing returns.
_DEFAULT_STEPS = 12

# 0.95 speed = slightly slower than Supertonic's 1.05 default; takes the
# rushed edge off without dragging. 0.9 felt sluggish on one-sentence memos.
_DEFAULT_SPEED = 0.95

# Supertonic-3 native rate.
_SAMPLE_RATE = 44100

# Per-chunk character cap. The library's default is 300 (120 for ko/ja); we
# stay just under that to leave headroom for an occasional inline <breath>
# tag (~8 chars) without pushing the engine past its stable-voice band.
# Within a single diffusion pass, voice identity is rock-solid; across chunks
# the noise schedule re-samples so smaller chunks → more boundaries → more
# chances for subtle voice drift. 280 chars on English prose averages 4–5
# sentences per chunk, which is a good cadence ceiling.
_FAST_MAX_CHUNK = 280

# Load once at module import. ~900 MB RSS, ONNX Runtime session, CPU only.
# First run downloads ~99 MB of model files to ~/.cache/huggingface/hub/.
_tts = TTS(model="supertonic-3", auto_download=True)
_sam = _tts.get_voice_style(voice_name=_DEFAULT_VOICE)


class FastTTSRequest(BaseModel):
    text: str
    lang_hint: str | None = None
    speed: float = _DEFAULT_SPEED
    english_only: bool = True
    polish: bool = True
    # Per-request override of the silence inserted between paragraph-boundary
    # chunks. Default (None) keeps the standard ~0.6s breath. Use this for
    # multi-section content where a longer beat between sections aids
    # comprehension (~1.5–2.5s feels natural without sounding stalled).
    paragraph_pause_secs: float | None = None


def _to_mp3(audio: np.ndarray) -> bytes:
    """Encode mono float audio to MP3 via ffmpeg + loudnorm to -16 LUFS.
    Same loudness target as the Fish pipeline so cron audio sounds equally
    loud regardless of which engine served it."""
    if audio.ndim > 1:
        audio = audio.squeeze()
    wav_buf = io.BytesIO()
    sf.write(wav_buf, audio, _SAMPLE_RATE, format="WAV", subtype="PCM_16")
    proc = subprocess.run(
        [
            "ffmpeg", "-loglevel", "error",
            "-i", "pipe:0",
            "-af", _LOUDNORM,
            "-ar", str(_SAMPLE_RATE),
            "-ac", "1",
            "-codec:a", "libmp3lame", "-q:a", "4",
            "-f", "mp3", "pipe:1",
        ],
        input=wav_buf.getvalue(),
        capture_output=True,
        timeout=60,
    )
    if proc.returncode != 0:
        raise HTTPException(
            status_code=500,
            detail=f"ffmpeg encode failed: {proc.stderr.decode()[-300:]}",
        )
    return proc.stdout


def _title_from_text(text: str) -> str:
    cleaned = re.sub(r'[<>:"/\\|?*]', "", text)[:40].strip()
    return cleaned or "Voice memo"


# Info-preserving English polish prompt for Supertonic-3. No Fish-style
# bracket tags (the engine reads them as literal text). The one allowed tag
# is <breath> — model-card-documented Supertonic expression tag that renders
# as an audible inhale.
_POLISH_SYSTEM_EN = """You convert messages into natural spoken English prose for the Supertonic-3 TTS engine. Reply with ONLY the rewritten text — no commentary, no quotes.

GROUND RULES:
- Output language: English. If the input is in another language (German etc.), TRANSLATE to natural spoken English. Do not preserve the source language.
- PRESERVE EVERY PIECE OF INFORMATION. This is a rewrite for spoken delivery, NOT a summary. Do not condense, do not drop sentences, do not paraphrase aggressively. Short inputs stay short; long inputs stay long. Output length tracks input length plus translation overhead.
- Strip markdown: bullets become flowing sentences, no bold/italic, no headers, omit URLs (describe what they point to), describe code/paths in plain words.
- Sound spoken, not written: short sentences, contractions are fine, natural connectors ("then", "also", "so", "by the way").

STRUCTURE FOR MULTI-TOPIC OUTPUTS:
- Use a real blank-line paragraph break at every topic shift. The engine inserts a longer pause at paragraph boundaries than at sentence boundaries, so this gives the listener natural section beats.
- A one-line snap stays one paragraph. A multi-section briefing becomes one paragraph per section.

ALLOWED MARKUP — exactly one tag, used sparingly:
- <breath> — Supertonic-3 renders this as an audible inhale. Insert at MOST one per long paragraph, INLINE (mid-sentence or between two sentences within the same paragraph), at a natural turn in the narration. NEVER as its own line. NEVER in short messages. NEVER more than once per paragraph.

NO OTHER MARKUP. No [emphasis], no [pause], no SSML, no quoted tags. The engine reads anything besides <breath> as literal text. Pacing comes from punctuation and paragraph breaks alone.

The engine auto-handles numbers ($5.2M, 18°C, 9:30), dates ("Wed, Apr 3"), abbreviations, and units — write them naturally, don't expand or spell out.

TECHNICALITIES (terminal commands, long IDs, hash strings, file paths, API URLs): name the purpose, not the syntax. "the homelab API" not the full URL. "the journal schema doc" not the full path. "an ffmpeg command re-encodes the audio" not the flag list.

EXAMPLES:

Input: "**Status:** alle Server up. garmin-sync seit drei Tagen unhealthy."
Output: All servers are up, except garmin-sync — that one's been unhealthy for three days now.

Input: "Munich: 18°C sonnig. Standup 9:30, Architektur-Review um 11."
Output: Munich today, eighteen degrees and sunny. Standup at nine thirty, then the architecture review at eleven.

Input: "PR #142 merged, CI green, deploy queued."
Output: PR one-forty-two is merged, CI is green, deploy is queued.

Input (multi-section, longer):
"Morning briefing. Weather Munich 12°C cloudy with light rain. Calendar: standup at 9:30, lunch with Anna at 1pm, architecture review at 3. Inbox: 3 new emails — one from the CTO about the deploy freeze, the rest newsletters. Infrastructure: mostly green, garmin-sync still unhealthy day 3, hr-dashboard back online after yesterday's fix."

Output:
Morning briefing. Munich today, twelve degrees and cloudy with light rain.

On the calendar, standup at nine thirty, then lunch with Anna at one, <breath> and the architecture review at three.

Inbox has three new emails. One from the CTO about the deploy freeze, the rest are newsletters.

Infrastructure is mostly green. The exception is garmin-sync — still unhealthy on day three. Hr-dashboard is back online after yesterday's fix."""


async def _polish_for_supertonic(text: str, english_only: bool) -> str:
    """Info-preserving rewrite for the Supertonic path. May insert <breath>
    at natural inhale points within long paragraphs.

    On Haiku failure: one retry, then surface a 502 if english_only is set
    (better to fail loud than ship German audio in an English voice). When
    english_only is False, we tolerate a fallback to _strip_markdown because
    synthesis will at least be in the right language."""
    if not _ANTHROPIC_KEY:
        print("[tts_fast.polish] no ANTHROPIC_API_KEY — using _strip_markdown", flush=True)
        return _strip_markdown(text)

    _ = english_only  # the system prompt itself handles the translation step
    for attempt in (1, 2):
        polished = await _fast_haiku(
            system=_POLISH_SYSTEM_EN,
            user=text,
            # 8192 tokens of output handles a multi-paragraph briefing
            # comfortably. The old 1024 cap silently truncated longer polish
            # outputs to the first ~700 chars — that's why the path felt
            # "1–4 sentences only".
            max_tokens=8192,
            label=f"polish.try{attempt}",
        )
        if polished:
            print(
                f"[tts_fast.polish] OK try={attempt} in={len(text)} out={len(polished)} "
                f"in_prefix={text[:80]!r} out_prefix={polished[:80]!r}",
                flush=True,
            )
            return polished

    if english_only:
        # Refuse to mispronounce. Caller asked for English; we can't guarantee
        # it without Haiku. Surface so the caller can retry or fall back to
        # the Fish primary path.
        print(
            f"[tts_fast.polish] Haiku failed twice; refusing to ship {len(text)}-char "
            "input in English voice",
            flush=True,
        )
        raise HTTPException(
            status_code=502,
            detail="Haiku polish failed; cannot guarantee English output",
        )

    print("[tts_fast.polish] Haiku failed; falling back to _strip_markdown (english_only=False)", flush=True)
    return _strip_markdown(text)


async def _make_english_title(text: str) -> str:
    """3–8 word English title for the output filename. Title failures are
    non-fatal — we fall back to a prefix-of-text since the audio is already
    correct."""
    if not _ANTHROPIC_KEY:
        return _title_from_text(text)
    result = await _fast_haiku(
        system=(
            "Generate a concise 3-8 word title in English for this spoken memo. "
            "Reply ONLY with the title — no quotes, no punctuation at the end."
        ),
        user=text[:400],
        max_tokens=24,
        label="title",
    )
    return re.sub(r'[<>:"/\\|?*]', "", result).strip() or _title_from_text(text)


def _synth_chunk_sync(chunk: str, lang: str, speed: float) -> np.ndarray:
    """Single-chunk synthesis via the lower-level model.__call__. Returns
    1D mono float32 with 5 ms linear edge fades to suppress diffusion-
    boundary clicks.

    We bypass TTS.synthesize() so we control chunking, inter-chunk pauses,
    and fading. The library's built-in chunker fixes silence at 0.3 s for
    every boundary and omits edge fading, which on multi-paragraph output
    produces audible amplitude bumps."""
    wav, _ = _tts.model([chunk], _sam, _DEFAULT_STEPS, speed, lang)
    audio = wav[0].astype(np.float32)
    return _fade_edges(np.ascontiguousarray(audio))


async def synthesize_fast(
    text: str,
    lang_hint: str | None = None,
    speed: float = _DEFAULT_SPEED,
    english_only: bool = True,
    polish: bool = True,
    paragraph_pause_secs: float | None = None,
) -> TTSResponse:
    """Direct synthesis. Used by this route's HTTP endpoint and by the Fish
    fallback path in routes/tts.py. Same response shape as the primary
    endpoint so callers stay engine-agnostic.

    Default flags (english_only + polish) match the external voice-memo use
    case. Internal Fish fallback passes english_only=True + polish=True (the
    same defaults) — Supertonic in Sam's English embedding sounds better on
    translated English than on raw German."""
    text = text.strip()
    if not text:
        raise HTTPException(status_code=400, detail="text is required")

    if polish:
        polished = await _polish_for_supertonic(text, english_only=english_only)
        title = (
            await _make_english_title(polished)
            if english_only
            else _title_from_text(polished)
        )
    else:
        polished = _strip_markdown(text)
        title = _title_from_text(polished)

    # english_only forces lang=en. The polish step has already translated;
    # without polish, the caller has explicitly accepted Sam pronouncing
    # non-English text in his English embedding.
    if english_only:
        lang = "en"
    else:
        lang = (lang_hint or _detect_lang(polished)).lower()

    # Pre-chunk: paragraph then sentence boundaries, capped at 280 chars.
    # preserve_paragraphs keeps each paragraph as its own beat (paragraph
    # pause inserted between) rather than greedy-merging short paragraphs.
    chunks = _chunk_text(
        polished,
        "en" if lang not in {"de", "fr", "es", "it", "pt", "nl"} else lang,
        max_chars=_FAST_MAX_CHUNK,
        preserve_paragraphs=True,
    )

    pause_overrides = dict(_PAUSE_AFTER)
    if paragraph_pause_secs is not None and paragraph_pause_secs >= 0:
        pause_overrides["paragraph"] = float(paragraph_pause_secs)

    # Sequential synthesis. ONNX Runtime's intra-op pool already saturates
    # the M2 Pro's cores per call; thread-pool parallelism here would thrash
    # the scheduler without speedup, and would also need intra_op_num_threads
    # tuning we don't have evidence for. asyncio.to_thread keeps the FastAPI
    # event loop responsive between chunks.
    audio_parts: list[np.ndarray] = []
    for chunk_text_str, brk in chunks:
        part = await asyncio.to_thread(_synth_chunk_sync, chunk_text_str, lang, speed)
        audio_parts.append(part)
        pause = pause_overrides.get(brk, 0.0)
        if pause > 0:
            audio_parts.append(_silence(pause))

    combined = np.concatenate(audio_parts) if audio_parts else _silence(0.1)
    duration_secs = round(len(combined) / _SAMPLE_RATE, 2)
    mp3_bytes = await asyncio.to_thread(_to_mp3, combined)
    audio_b64 = base64.b64encode(mp3_bytes).decode()

    return TTSResponse(
        title=title,
        audio_b64=audio_b64,
        duration_secs=duration_secs,
        chunks=len(chunks),
        lang=lang,
    )


@router.post("/v1/tts/synthesize/fast", response_model=TTSResponse)
async def synthesize_endpoint(req: FastTTSRequest) -> TTSResponse:
    return await synthesize_fast(
        req.text,
        lang_hint=req.lang_hint,
        speed=req.speed,
        english_only=req.english_only,
        polish=req.polish,
        paragraph_pause_secs=req.paragraph_pause_secs,
    )
