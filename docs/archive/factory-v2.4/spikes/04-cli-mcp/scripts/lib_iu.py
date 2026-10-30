"""Shared helpers for the Spike 4 harness (stdlib only).

`iu_env()` rebuilds exactly what the `claude_iu` zsh function does (config/zsh/claude.zsh):
the IU credential and base URL come from the same two Keychain entries, ANTHROPIC_API_KEY is
stripped, and the session is a headless `claude -p`. Nothing here prints or stores a credential.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path

SCRATCH = Path(os.environ.get("SPIKE_SCRATCH", "~/.local/share/factory/spikes/04-cli-mcp")).expanduser()
CLAUDE = shutil.which("claude") or str(Path("~/.local/bin/claude").expanduser())


def _keychain(service: str) -> str:
    out = subprocess.run(
        ["security", "find-generic-password", "-s", service, "-w"],
        capture_output=True, text=True, check=False,
    )
    return out.stdout.strip()


def iu_env(extra: dict[str, str] | None = None) -> dict[str, str]:
    """Environment for one `claude_iu`-equivalent session. Raises if the Keychain is empty."""
    key, base = _keychain("claude-sdk-api-key"), _keychain("claude-sdk-base-url")
    if not key or not base:
        raise SystemExit("IU credentials missing in Keychain (run `make setup` in dotfiles)")
    env = {k: v for k, v in os.environ.items() if k != "ANTHROPIC_API_KEY"}
    env["ANTHROPIC_AUTH_TOKEN"] = key
    env["ANTHROPIC_BASE_URL"] = base
    env.pop("CLAUDE_CODE_OAUTH_TOKEN", None)
    env.pop("ENABLE_TOOL_SEARCH", None)
    env.update(extra or {})
    return env


def iu_base() -> str:
    return _keychain("claude-sdk-base-url").rstrip("/")


def iu_key() -> str:
    return _keychain("claude-sdk-api-key")


def load_json(path: str | Path):
    return json.loads(Path(path).read_text())
