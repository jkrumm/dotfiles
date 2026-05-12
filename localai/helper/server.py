"""LocalAI Helper Server — extensible local processing layer.

Runs at 127.0.0.1:8001 (mlx-audio is on :8000). Hermes connects to mlx-audio
directly for low overhead; MacWhisper and other strict OpenAI clients go
through this helper (via Caddy at https://whisper.test) so we can transform
responses to match each client's expectations without modifying mlx-audio.

Extension points: drop a new module in `routes/` and include its router below.
The helper has direct access to mlx-audio over localhost — useful for any
local pre/post-processing that needs to wrap audio I/O without forking
mlx-audio source.

Why this exists at all:
- mlx-audio returns Parakeet-shape `{text, sentences}` instead of OpenAI
  verbose_json `{text, segments, language, duration}`
- mlx-audio Whisper STT is broken in 0.4.2 (load_model doesn't attach
  WhisperProcessor; patching at request time crashes Metal threads)
- We can't easily modify mlx-audio without re-applying patches on every
  upgrade. A separate helper is more sustainable.
"""

import argparse

from fastapi import FastAPI

from routes import macwhisper, tts, tts_fast

app = FastAPI(title="LocalAI Helper", version="0.3.0")
app.include_router(macwhisper.router)
app.include_router(tts.router)
app.include_router(tts_fast.router)


@app.get("/health")
def health():
    return {
        "status": "ok",
        "upstream": macwhisper.UPSTREAM,
        "tts": "enabled",
        "tts_fast": "enabled",
    }


def main():
    import uvicorn

    parser = argparse.ArgumentParser(description="LocalAI Helper Server")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8001)
    args = parser.parse_args()
    uvicorn.run(app, host=args.host, port=args.port, access_log=True)


if __name__ == "__main__":
    main()
