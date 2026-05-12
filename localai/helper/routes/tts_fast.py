"""Supertonic-3 ONNX/CPU fallback TTS.

POST /v1/tts/synthesize/fast
  Body (JSON):
    text:      str   — text to speak (any length)
    lang_hint: str?  — ISO code (en/de/...); auto-detected if absent
    speed:     float — playback speed, default 0.9 (Supertonic's 1.05 default
                        sounds rushed for narrative briefings)

  Response (JSON): same shape as /v1/tts/synthesize.

Why this exists:
  Fish-S2-Pro is the highest-Elo open-weights TTS (Artificial Analysis
  TTS leaderboard, May 2026: Elo 1128) but needs 6.7 GB Metal-resident
  weights. On a memory-pressed Mac (Mac mini doing double duty as
  workstation + Hermes server), MLX weights get evicted and synthesis
  hangs — Hermes morning briefing failed on 2026-05-11 + 2026-05-12 for
  this exact reason.

  Supertonic-3 runs on ONNX Runtime/CPU at ~900 MB RSS. Different memory
  pool from Fish/MLX, so it works while Fish is wedged. Quality is below
  Fish in blind eval, but its preset M4 ("Sam") voice — soft, neutral,
  youthful, friendly — fits the briefing aesthetic well enough.

  This route serves two roles:
    1. Standalone fast endpoint for callers that want speed over quality.
    2. Internal fallback target — `synthesize_fast` is imported by
       routes/tts.py and called when the Fish path times out or errors.
"""

import asyncio
import base64
import io
import re
import subprocess

import numpy as np
import soundfile as sf
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel
from supertonic import TTS

from routes.tts import TTSResponse, _LOUDNORM, _detect_lang

router = APIRouter()

# Sam (M4): "A soft, neutral-toned male voice; gentle and approachable
# with a youthful, friendly quality." Matches the stated voice profile
# (calm, deep, young English male). Other M-series voices: M1=Alex
# (upbeat), M2=James (deep robust), M3=Robert (authoritative),
# M5=Daniel (warm storyteller). See script.js VOICE_DESCRIPTIONS in
# huggingface.co/spaces/Supertone/supertonic-3 for the full preset list.
_DEFAULT_VOICE = "M4"

# 12 inference steps = quality knob. Demo Space defaults to 5 (production-
# ready but rougher). 12 trades a few hundred ms for noticeably cleaner
# prosody at briefing length. >16 gives diminishing returns.
_DEFAULT_STEPS = 12

# 0.9 speed = calm pacing. Supertonic's 1.05 default sounds rushed for a
# morning briefing. 0.9 is steady without dragging.
_DEFAULT_SPEED = 0.9

# Supertonic native rate (confirmed by sf.info on a synthesized sample).
_SAMPLE_RATE = 44100

# Load once at module import. ~900 MB RSS, ONNX Runtime session, CPU only.
# First run downloads ~99M of model files to ~/.cache/huggingface/hub/.
_tts = TTS(model="supertonic-3", auto_download=True)
_sam = _tts.get_voice_style(voice_name=_DEFAULT_VOICE)


class FastTTSRequest(BaseModel):
    text: str
    lang_hint: str | None = None
    speed: float = _DEFAULT_SPEED


def _to_mp3(audio: np.ndarray) -> bytes:
    """Encode mono float audio to MP3 via ffmpeg + loudnorm to -16 LUFS.
    Shares the same loudness target as the Fish pipeline so cron audio
    sounds equally loud regardless of which engine served it."""
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


async def synthesize_fast(
    text: str,
    lang_hint: str | None = None,
    speed: float = _DEFAULT_SPEED,
) -> TTSResponse:
    """Direct synthesis — used by both this route's HTTP endpoint and the
    Fish fallback path in routes/tts.py. Same response shape as the primary
    endpoint so callers stay engine-agnostic."""
    text = text.strip()
    if not text:
        raise HTTPException(status_code=400, detail="text is required")

    lang = (lang_hint or _detect_lang(text)).lower()

    # supertonic.synthesize is synchronous ONNX inference — run in a thread
    # so a long briefing render doesn't block the FastAPI event loop.
    wav, dur = await asyncio.to_thread(
        _tts.synthesize,
        text,
        _sam,
        _DEFAULT_STEPS,
        speed,
        None,    # max_chunk_length — auto per language
        0.3,     # silence_duration between internal chunks
        lang,
        False,   # verbose
    )
    duration_secs = float(np.asarray(dur).item())

    mp3_bytes = await asyncio.to_thread(_to_mp3, wav)
    audio_b64 = base64.b64encode(mp3_bytes).decode()

    return TTSResponse(
        title=_title_from_text(text),
        audio_b64=audio_b64,
        duration_secs=round(duration_secs, 2),
        chunks=1,  # Supertonic handles its own internal chunking
        lang=lang,
    )


@router.post("/v1/tts/synthesize/fast", response_model=TTSResponse)
async def synthesize_endpoint(req: FastTTSRequest) -> TTSResponse:
    return await synthesize_fast(req.text, req.lang_hint, req.speed)
