#!/usr/bin/env python3
"""Track Tinycast's settings in git as readable JSON.

Tinycast keeps everything that matters in its UserDefaults domain: feature
switches, hotkeys (JSON *strings* under `hotkey.*`) and custom commands (JSON
*data* under `customCommands`). A raw plist export would bury the last two in
base64, so this round-trips them as tagged JSON:

  {"$json": ...}        a Data value holding UTF-8 JSON
  {"$jsonString": ...}  a String value holding a JSON object or array
  {"$data": "<b64>"}    any other Data value
  {"$date": "<iso>"}    a Date value

Clipboard history, quicklinks and notes live in SQLite under Application
Support and are deliberately not tracked (state, not config).

  export  live -> config/tinycast/defaults.json (adopt live)
  apply   config/tinycast/defaults.json -> live, merged over it (adopt repo);
          quits Tinycast first and relaunches it, since the app rewrites its
          domain from memory on quit
  check   exit 0 = live matches the repo, 1 = diverged, 2 = nothing to compare
  setup   `make setup` step: apply on a fresh install, report divergence otherwise
"""

import base64
import datetime
import json
import plistlib
import re
import subprocess
import sys
import time
from pathlib import Path

DOMAIN = "com.tinycast.app"
APP = Path("/Applications/Tinycast.app")
TRACKED = Path(__file__).resolve().parent.parent / "config/tinycast/defaults.json"

# Window geometry, status-item slots and AppKit/Sparkle bookkeeping: rewritten
# by the OS on every run, so tracking them only ever produces noise.
VOLATILE = re.compile(r"^(NS|Apple|SU|com\.apple\.)")


def read_live() -> dict:
    out = subprocess.run(
        ["defaults", "export", DOMAIN, "-"], capture_output=True, check=False
    )
    if out.returncode != 0 or not out.stdout:
        return {}
    return plistlib.loads(out.stdout)


def encode(value):
    if isinstance(value, bytes):
        try:
            return {"$json": json.loads(value.decode("utf-8"))}
        except (UnicodeDecodeError, json.JSONDecodeError):
            return {"$data": base64.b64encode(value).decode("ascii")}
    if isinstance(value, datetime.datetime):
        return {"$date": value.isoformat()}
    if isinstance(value, str) and value[:1] in "{[":
        try:
            return {"$jsonString": json.loads(value)}
        except json.JSONDecodeError:
            return value
    if isinstance(value, dict):
        return {k: encode(v) for k, v in value.items()}
    if isinstance(value, list):
        return [encode(v) for v in value]
    return value


def decode(value):
    if isinstance(value, dict):
        if value.keys() == {"$json"}:
            return json.dumps(value["$json"], separators=(",", ":")).encode("utf-8")
        if value.keys() == {"$jsonString"}:
            return json.dumps(value["$jsonString"], separators=(",", ":"))
        if value.keys() == {"$data"}:
            return base64.b64decode(value["$data"])
        if value.keys() == {"$date"}:
            return datetime.datetime.fromisoformat(value["$date"])
        return {k: decode(v) for k, v in value.items()}
    if isinstance(value, list):
        return [decode(v) for v in value]
    return value


def portable(live: dict) -> dict:
    return {k: encode(v) for k, v in sorted(live.items()) if not VOLATILE.match(k)}


def read_tracked() -> dict:
    return json.loads(TRACKED.read_text())


def diverged_keys(tracked: dict, live: dict) -> list[str]:
    ours = portable(live)
    return sorted(k for k in tracked.keys() | ours.keys() if tracked.get(k) != ours.get(k))


def running() -> bool:
    return subprocess.run(["pgrep", "-x", "Tinycast"], capture_output=True).returncode == 0


def quit_app() -> None:
    subprocess.run(
        ["osascript", "-e", f'tell application id "{DOMAIN}" to quit'], capture_output=True
    )
    for _ in range(50):
        if not running():
            return
        time.sleep(0.1)
    sys.exit("Tinycast did not quit — close it by hand and re-run")


def cmd_export() -> int:
    live = read_live()
    if not live:
        print(f"  ✗ no live {DOMAIN} domain — launch Tinycast once first")
        return 2
    TRACKED.parent.mkdir(parents=True, exist_ok=True)
    TRACKED.write_text(json.dumps(portable(live), indent=2, ensure_ascii=False) + "\n")
    print(f"  ✓ exported live settings → {TRACKED.relative_to(Path.home())} (review the git diff)")
    return 0


def cmd_apply() -> int:
    was_running = running()
    if was_running:
        quit_app()
    merged = read_live()
    merged.update({k: decode(v) for k, v in read_tracked().items()})
    subprocess.run(
        ["defaults", "import", DOMAIN, "-"], input=plistlib.dumps(merged), check=True
    )
    print(f"  ✓ applied {TRACKED.relative_to(Path.home())} → {DOMAIN}")
    subprocess.run(["open", "-g", str(APP)], check=True)
    return 0


def cmd_check() -> int:
    live = read_live()
    if not live:
        print(f"  - no live {DOMAIN} domain yet")
        return 2
    keys = diverged_keys(read_tracked(), live)
    if not keys:
        print("  ✓ Tinycast settings match the repo")
        return 0
    print("  ! Tinycast settings differ from the repo:")
    for k in keys:
        print(f"      {k}")
    return 1


def cmd_setup() -> int:
    if not APP.exists():
        print("    - Tinycast not installed, skipping (Brewfile installs it)")
        return 0
    live = read_live()
    tracked = read_tracked()
    # Fresh install: none of the tracked keys have been written yet.
    if not tracked.keys() & live.keys():
        return cmd_apply()
    if not diverged_keys(tracked, live):
        print("    ✓ Tinycast settings match the repo")
        return 0
    print("    ! Tinycast settings differ from the repo — NOT overwritten.")
    print("      The live domain is authoritative until you decide otherwise:")
    print("        make tinycast-check    # which keys differ")
    print("        make tinycast-export   # adopt live")
    print("        make tinycast-apply    # adopt repo")
    return 0


if __name__ == "__main__":
    commands = {"export": cmd_export, "apply": cmd_apply, "check": cmd_check, "setup": cmd_setup}
    if len(sys.argv) != 2 or sys.argv[1] not in commands:
        sys.exit(f"usage: {Path(sys.argv[0]).name} {{{'|'.join(commands)}}}")
    sys.exit(commands[sys.argv[1]]())
