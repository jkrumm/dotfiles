#!/usr/bin/env python3
"""Verify every Claude Code flag and env switch the harness uses against the installed build.

Flags are looked up in `claude --help`; env switches in the binary's own strings (they are not in --help).
Writes raw/claude-flags-verified.json and exits 1 if anything the harness relies on is missing.
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from lib_iu import CLAUDE  # noqa: E402

FLAGS = ["--print", "--output-format", "--verbose", "--dangerously-skip-permissions", "--setting-sources", "--disable-slash-commands",
         "--strict-mcp-config", "--mcp-config", "--tools", "--model", "--effort", "--append-system-prompt", "--no-session-persistence", "--bare", "--safe-mode"]
ENV = ["ENABLE_TOOL_SEARCH", "CLAUDE_CODE_DISABLE_CLAUDE_MDS", "CLAUDE_CODE_DISABLE_AUTO_MEMORY", "CLAUDE_CODE_SUBPROCESS_ENV_SCRUB"]
NOT_USED = {"--bare", "--safe-mode", "CLAUDE_CODE_SUBPROCESS_ENV_SCRUB"}  # investigated, rejected (see spike4 docstrings)

version = subprocess.run([CLAUDE, "--version"], capture_output=True, text=True).stdout.strip()
help_text = subprocess.run([CLAUDE, "--help"], capture_output=True, text=True).stdout
binary = Path(CLAUDE).resolve().read_bytes()
out = {
    "claude_version": version,
    "flags_in_help": {f: bool(re.search(rf"(^|\s|,){re.escape(f)}(\s|,|$)", help_text, re.M)) for f in FLAGS},
    "env_in_binary": {e: e.encode() in binary for e in ENV},
    "rejected": sorted(NOT_USED),
}
(Path(__file__).resolve().parents[1] / "raw" / "claude-flags-verified.json").write_text(json.dumps(out, indent=1) + "\n")
missing = [k for k, v in {**out["flags_in_help"], **out["env_in_binary"]}.items() if not v and k not in NOT_USED]
print(version, "| all used flags and switches present" if not missing else f"| MISSING: {missing}")
sys.exit(1 if missing else 0)
