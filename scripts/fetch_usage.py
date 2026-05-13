# /// script
# requires-python = ">=3.14"
# ///
"""Fetch Claude Code subscription usage via the official OAuth /api/oauth/usage endpoint.

Reads the OAuth access token from macOS Keychain (entry "Claude Code-credentials"),
calls Anthropic's usage endpoint, writes /tmp/claude_sl/usage_api.json for
statusline.sh. Same output shape as the legacy Chrome-cookie scraper —
statusline.sh and sideclaw quota.ts both consume this file unchanged.

The endpoint is rate-limited (per-token 429s within a few requests/min); on 429
we keep the existing cache rather than blanking it.

Run via: uv run ~/.claude/fetch_usage.py
"""

import json
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

CACHE_DIR = Path("/tmp/claude_sl")
CACHE_FILE = CACHE_DIR / "usage_api.json"
LOG_DIR = Path.home() / ".claude" / "logs"

USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
CQUEUE_URL = "http://localhost:7705/api/usage"
KEYCHAIN_SERVICE = "Claude Code-credentials"
ANTHROPIC_BETA = "oauth-2025-04-20"


def log_event(src: str, event: str, level: str, data: dict) -> None:
    try:
        LOG_DIR.mkdir(exist_ok=True)
        date_str = datetime.now().strftime("%Y-%m-%d")
        entry = json.dumps({
            "ts": datetime.now(timezone.utc).isoformat(),
            "src": src,
            "event": event,
            "level": level,
            "data": data,
        }) + "\n"
        with open(LOG_DIR / f"{date_str}.jsonl", "a") as f:
            f.write(entry)
    except Exception:
        pass


def cleanup_old_logs(keep_days: int = 3) -> None:
    try:
        cutoff = time.time() - keep_days * 86400
        for f in LOG_DIR.glob("*.jsonl"):
            if f.stat().st_mtime < cutoff:
                f.unlink(missing_ok=True)
    except Exception:
        pass


def _oauth_token() -> str:
    """Pull the Claude Code OAuth access token from macOS Keychain."""
    result = subprocess.run(
        ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"],
        capture_output=True,
        text=True,
        check=True,
    )
    payload = json.loads(result.stdout.strip())
    return payload["claudeAiOauth"]["accessToken"]


def _to_epoch(ts: str | None) -> int | None:
    if not ts:
        return None
    try:
        return int(datetime.fromisoformat(ts).timestamp())
    except Exception:
        return None


def _http_get_json(url: str, headers: dict, timeout: int = 10) -> tuple[dict, int, int]:
    req = urllib.request.Request(url, headers=headers, method="GET")
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        body = resp.read()
        status = resp.status
    return json.loads(body), status, round((time.time() - t0) * 1000)


def _http_post_json(url: str, payload: dict, timeout: int = 1) -> None:
    data = json.dumps(payload).encode()
    req = urllib.request.Request(
        url, data=data, headers={"Content-Type": "application/json"}, method="POST"
    )
    with urllib.request.urlopen(req, timeout=timeout):
        pass


def fetch() -> None:
    CACHE_DIR.mkdir(exist_ok=True)
    cleanup_old_logs()

    token = _oauth_token()
    log_event("fetch_usage", "token_ok", "info", {"prefix": token[:8]})

    data, status, latency_ms = _http_get_json(
        USAGE_URL,
        headers={
            "Authorization": f"Bearer {token}",
            "anthropic-beta": ANTHROPIC_BETA,
            "Accept": "application/json",
        },
    )

    def extract(key: str) -> dict:
        w = data.get(key) or {}
        return {
            "utilization": w.get("utilization"),
            "resets_at_epoch": _to_epoch(w.get("resets_at")),
        }

    result = {
        "five_hour": extract("five_hour"),
        "seven_day": extract("seven_day"),
        "seven_day_sonnet": extract("seven_day_sonnet"),
        "fetched_at": int(datetime.now(timezone.utc).timestamp()),
    }

    five_h_pct = round(result["five_hour"].get("utilization") or 0)
    seven_d_pct = result["seven_day"].get("utilization")
    log_event("fetch_usage", "fetch_success", "info", {
        "five_hour_pct": five_h_pct,
        "seven_day_pct": round(seven_d_pct) if seven_d_pct is not None else None,
        "http_status": status,
        "latency_ms": latency_ms,
    })

    tmp = CACHE_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(result))
    tmp.rename(CACHE_FILE)

    # Push to cqueue UI (localhost:7705) — fail silently if not running
    try:
        five_h = result["five_hour"]
        seven_d = result["seven_day"]
        now_ts = result["fetched_at"]
        reset_epoch = five_h.get("resets_at_epoch")
        mins_left = round((reset_epoch - now_ts) / 60) if reset_epoch and reset_epoch > now_ts else None
        _http_post_json(CQUEUE_URL, {
            "five_hour_pct": round(five_h.get("utilization") or 0),
            "five_hour_mins_left": mins_left,
            "seven_day_pct": round(seven_d.get("utilization")) if seven_d.get("utilization") is not None else None,
        })
    except Exception:
        pass


if __name__ == "__main__":
    try:
        fetch()
    except urllib.error.HTTPError as e:
        # 429: keep existing cache rather than blanking — endpoint is rate-limited
        # per-token and statusline tolerates stale data better than missing data.
        if e.code == 429:
            log_event("fetch_usage", "rate_limited", "warning", {"http_status": 429})
            sys.exit(0)
        log_event("fetch_usage", "fetch_error", "error", {
            "error": str(e),
            "type": type(e).__name__,
            "http_status": e.code,
        })
        CACHE_DIR.mkdir(exist_ok=True)
        CACHE_FILE.write_text(json.dumps({"error": str(e), "fetched_at": 0}))
        sys.exit(1)
    except Exception as e:
        log_event("fetch_usage", "fetch_error", "error", {
            "error": str(e),
            "type": type(e).__name__,
        })
        CACHE_DIR.mkdir(exist_ok=True)
        CACHE_FILE.write_text(json.dumps({"error": str(e), "fetched_at": 0}))
        sys.exit(1)
