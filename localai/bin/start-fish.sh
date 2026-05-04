#!/bin/bash
# Fish S2 Pro production TTS server — launchd-managed.
#
# Started by ~/Library/LaunchAgents/com.localai.fish.plist via launchd.
# Runs server.py via uv with mlx-speech + fastapi + uvicorn pulled per-run
# into a shared cache. The mlx-speech model (~6.7 GB) is downloaded from
# HuggingFace on first run and cached at ~/.cache/huggingface/hub/.

set -u

PORT="${FISH_PORT:-8002}"
ROOT="$HOME/SourceRoot/dotfiles/localai/fish-s2-pro"

cd "$ROOT" || exit 1

exec /opt/homebrew/bin/uv run \
  --python 3.13 \
  --with mlx-speech \
  --with fastapi --with uvicorn --with pydantic --with soundfile \
  python server.py
