---
name: localai
description: Manage per-machine mlx-audio (TTS + STT) on 127.0.0.1:8000 — install, status, swap STT model, troubleshoot
---

# LocalAI Stack Management

Per-machine `mlx-audio` (TTS + STT) bound to `127.0.0.1:8000`. Installed automatically by `make setup`. No Tailscale exposure, no Ollama, no LLM — Hermes uses cloud Sonnet 4.6 via the IU unified endpoint.

**Full documentation:** Read `~/SourceRoot/dotfiles/localai/README.md` first.

## Stack Overview

| Component | Service | Port |
|-|-|-|
| mlx-audio (STT only — Parakeet) | `com.localai.audio` | 8000 (localhost) |
| fish-s2-pro (TTS — Fish Audio S2 Pro) | `com.localai.fish` | 8002 (localhost) |
| localai-helper (FastAPI orchestration layer — TTS pipeline, STT response transform) | `com.localai.helper` | 8001 (localhost) |

**Models (both warm on launchd start):**
- STT: `mlx-community/parakeet-tdt-0.6b-v3` — 1.2 GB, 25 EU langs incl. EN/DE, 10–60× RT
- TTS: `appautomaton/fishaudio-s2-pro-8bit-mlx` — 6.7 GB, clone-only with two production references (Pip Klöckner for `de` with smile EQ, Ethan from fish.audio demos for `en`)

Hermes calls `:8001/v1/tts/synthesize` (the helper) for all TTS. The helper handles language detection, speakable rewrite (Haiku), title (Haiku), paragraph-aware chunking, Fish synthesis at `:8002`, and MP3 encoding. DE output gets a smile EQ applied server-side by Fish. Inline emotion tags (`[chuckle]`, `[whisper]`, `[pause]`, `[excited]`, …) are first-class — see `localai/fish-s2-pro/REFERENCE.md`.

**Why Parakeet, not Whisper:** mlx-audio 0.4.2 has a Whisper bug — `load_model()` doesn't attach `WhisperProcessor` (required for `get_tokenizer()`). Patching at request-time triggers an MLX Metal threading crash. Parakeet works cleanly.

**MacWhisper endpoint:** `https://whisper.test` — Caddy block in `config/Caddyfile` rewrites Content-Type to `application/json` (mlx-audio's `application/x-ndjson` confuses MacWhisper's parser). Use any STT model id (e.g., `mlx-community/parakeet-tdt-0.6b-v3`).

## Commands

### `/localai setup`

Run the Makefile target — does everything (mlx-audio, deps, ffmpeg, m4a patch, plist install + load):

```bash
cd ~/SourceRoot/dotfiles
make _setup-localai
```

Or as part of full setup: `make setup`.

First run downloads ~2 GB of Python deps. Parakeet (1.2 GB) downloads on first STT request and caches at `~/.cache/huggingface/hub/`.

### `/localai status`

```bash
echo "=== mlx-audio (127.0.0.1:8000) ==="
curl -sf http://127.0.0.1:8000/v1/models | jq -r '.data[]?.id' 2>/dev/null \
  || echo "DOWN — check tail /tmp/audio.err"

echo ""
echo "=== launchd ==="
launchctl list | grep com.localai.audio || echo "Not loaded"

echo ""
echo "=== Warm-up log ==="
tail -3 /tmp/mlx-audio-warmup.log 2>/dev/null

echo ""
echo "=== System ==="
memory_pressure | head -1
```

### `/localai update`

```bash
# Upgrade mlx-audio + deps
uv tool upgrade mlx-audio
uv pip install --python ~/.local/share/uv/tools/mlx-audio/bin/python3 "setuptools<81" python-multipart
uv pip install --python ~/.local/share/uv/tools/mlx-audio/bin/python3 \
  "misaki[en]<0.9" num2words phonemizer espeakng_loader spacy

# Re-apply m4a STT patch (uv tool upgrade overwrites server.py)
patch -p1 -d ~/.local/share/uv/tools/mlx-audio/lib/python3.12/site-packages \
  < ~/SourceRoot/dotfiles/localai/patches/mlx-audio-m4a-stt.patch

# Restart
launchctl kickstart -k gui/$(id -u)/com.localai.audio
```

Or just re-run `make _setup-localai` — it handles all of the above idempotently.

### `/localai swap-model <component> <model>`

Components: `tts` | `stt`.

**STT default (warm-on-start):** edit the wrapper script env or set `LOCALAI_STT_MODEL` in the audio plist:

```xml
<key>EnvironmentVariables</key>
<dict>
  <key>LOCALAI_STT_MODEL</key><string>mlx-community/parakeet-tdt-0.6b-v3</string>
  ...
</dict>
```

Then restart: `launchctl kickstart -k gui/$(id -u)/com.localai.audio`.

**Per-request:** any client can specify any model in the API call — it lazy-loads.

**Pre-load manually:**
```bash
curl -X POST http://127.0.0.1:8000/v1/models \
  -H 'Content-Type: application/json' \
  -d '{"model":"<model-id>"}'
```

### `/localai stop` / `/localai start`

```bash
make stop    # launchctl unload com.localai.audio
make start   # launchctl load com.localai.audio
```

## Troubleshooting

**Server won't start:**
- `tail -50 /tmp/audio.err` — startup errors
- `pkg_resources` error → `uv pip install --python ~/.local/share/uv/tools/mlx-audio/bin/python3 "setuptools<81"`
- Port 8000 conflict → `lsof -i :8000`

**STT not warm on first request:**
- Check `/tmp/mlx-audio-warmup.log` — should see "STT warm-up complete"
- If empty: server may not have been ready when warm-up curl fired (wrapper retries 60×1s). Increase polling timeout in `localai/bin/start-mlx-audio.sh` if needed.

**TTS request returns 404 from the helper:**
- The `tts_tool.py` thin client posts to `:8001/v1/tts/synthesize`. If the helper isn't running, you'll see connection errors; if the route isn't registered (helper started before the route file existed), 404. Restart helper: `launchctl kickstart -k gui/$(id -u)/com.localai.helper`.

**Helper Haiku calls failing silently (no rewrite, generic title):**
- The wrapper script `bin/start-localai-helper.sh` injects `ANTHROPIC_API_KEY` + `ANTHROPIC_BASE_URL` from macOS Keychain. Verify:
  ```bash
  security find-generic-password -s claude-sdk-api-key -w | head -c 8
  security find-generic-password -s claude-sdk-base-url -w
  ```
- If empty, re-run `make setup` to rebuild the keychain cache.

**Slack voice memo "incorrect format" / m4a errors:**
- Verify m4a STT patch applied: `grep -q "ffmpeg" ~/.local/share/uv/tools/mlx-audio/lib/python3.12/site-packages/mlx_audio/server.py && echo "patched" || echo "MISSING"`
- Re-apply: `make _setup-localai`
