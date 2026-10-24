# /// script
# requires-python = ">=3.14"
# ///
"""Fetch Claude Code subscription usage via the official OAuth /api/oauth/usage endpoint.

Reads the OAuth access token from macOS Keychain (entry "Claude Code-credentials"),
calls Anthropic's usage endpoint, writes /tmp/claude_sl/usage_api.json for
statusline.sh. Same output shape as the legacy Chrome-cookie scraper —
statusline.sh consumes this file as its pre-first-response fallback (docs/statusline.md).

The endpoint is rate-limited (per-token 429s within a few requests/min); on 429
we keep the existing cache rather than blanking it.

W0 of docs/claude-accounts.md: a fresh (<5 min) default-account (iu) sample in the quota cache
(read through `claude-account usage --json`, the single owner of the cache schema and freshness)
is preferred; the API path below runs only when that sample is stale (retired in W2).
All accounts are also written to /tmp/claude_sl/usage_accounts.json.

Run via: uv run ~/.claude/fetch_usage.py
"""

import json
import os
import shutil
import subprocess
import tempfile
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

CACHE_DIR = Path("/tmp/claude_sl")
CACHE_FILE = CACHE_DIR / "usage_api.json"
RAW_FILE = CACHE_DIR / "usage_raw.json"
LOG_DIR = Path.home() / ".claude" / "logs"

USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
AGENT_GATEWAY_URL = "http://localhost:7705/api/usage"
KEYCHAIN_SERVICE = "Claude Code-credentials"
ANTHROPIC_BETA = "oauth-2025-04-20"

CLAUDE_ACCOUNT_BIN = "claude-account"
DEFAULT_ACCOUNT = "iu"  # registry id of the default ~/.claude login (CLAUDE_CONFIG_DIR unset)
ACCOUNTS_FILE = CACHE_DIR / "usage_accounts.json"
CACHE_FRESH_S = 300


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


def _write_json(path: Path, payload: dict, indent: int | None = None) -> None:
    """Atomic write via a unique temp file in the same directory (concurrent callers never share one)."""
    fd = tempfile.NamedTemporaryFile("w", dir=path.parent, prefix=f".{path.name}.", suffix=".tmp", delete=False)
    try:
        with fd:
            json.dump(payload, fd, indent=indent)
        os.replace(fd.name, path)
    except BaseException:
        Path(fd.name).unlink(missing_ok=True)
        raise


def _push_gateway(five_pct, mins_left, seven_pct, account: str = DEFAULT_ACCOUNT) -> None:
    # Push to agent-gateway UI (localhost:7705) — fail silently if not running.
    # Both feeds here read the default account (the cache's default_account, or the default keychain login).
    try:
        _http_post_json(AGENT_GATEWAY_URL, {
            "five_hour_pct": round(five_pct or 0),
            "five_hour_mins_left": mins_left,
            "seven_day_pct": round(seven_pct) if seven_pct is not None else None,
            "account": account,
        })
    except Exception:
        pass


def _claude_account_usage() -> dict:
    """`claude-account usage --json`: the only reader of the per-account quota cache."""
    exe = shutil.which(CLAUDE_ACCOUNT_BIN) or str(Path.home() / ".local" / "bin" / CLAUDE_ACCOUNT_BIN)
    result = subprocess.run([exe, "usage", "--json"], capture_output=True, text=True, check=True, timeout=30)
    return json.loads(result.stdout)


def _window(row: dict, key: str, now: float) -> dict:
    """One window, only when its own sample is fresh enough; otherwise null (never a carried-over value)."""
    age = row.get(f"{key}_age_s")
    fresh = row.get(key) is not None and age is not None and age < CACHE_FRESH_S
    return {
        "utilization": row[key] if fresh else None,
        "resets_at_epoch": row.get(f"{key}_resets_at") if fresh else None,
        "age_s": age,
    }


def from_account_cache() -> bool:
    """Write usage_accounts.json for all accounts; write usage_api.json from the default account when its 5h window is fresh.

    Returns True when usage_api.json was served from the cache (no API call needed). Any problem returns False
    so the caller falls through to the API path."""
    try:
        data = _claude_account_usage()
        now = time.time()
        rows = data["accounts"]
        _write_json(ACCOUNTS_FILE, {
            "default_account": data.get("default_account"),
            "accounts": {
                r["id"]: {
                    "five_hour": _window(r, "five_hour", now),
                    "seven_day": _window(r, "seven_day", now),
                    "sampled_at": int(now - r["age_s"]) if r.get("age_s") is not None else None,
                    "source": r.get("source"),
                    "enabled": r.get("enabled"),
                    "auth_ok": r.get("auth_ok"),
                    "exhausted_until": r.get("exhausted_until"),
                }
                for r in rows
            },
            "fetched_at": int(now),
        })
        row = next((r for r in rows if r["id"] == data.get("default_account")), None)
        if not row:
            return False
        five, seven = _window(row, "five_hour", now), _window(row, "seven_day", now)
        if five["utilization"] is None:
            return False
        sampled_at = int(now - min(a for a in (five["age_s"], seven["age_s"]) if a is not None))
        _write_json(CACHE_FILE, {
            "five_hour": {"utilization": five["utilization"], "resets_at_epoch": five["resets_at_epoch"]},
            "seven_day": {"utilization": seven["utilization"], "resets_at_epoch": seven["resets_at_epoch"]},
            "seven_day_sonnet": {"utilization": None, "resets_at_epoch": None},
            "limits": [],
            "extra_usage": None,
            "fetched_at": int(now),  # write time: statusline.sh gates its respawn on it
            "sampled_at": sampled_at,  # age of the data
            "source": "claude-accounts",
        })
        reset = five["resets_at_epoch"]
        mins = round((reset - now) / 60) if reset and reset > now else None
        _push_gateway(five["utilization"], mins, seven["utilization"], data.get("default_account") or DEFAULT_ACCOUNT)
        log_event("fetch_usage", "served_from_cache", "info", {"five_hour_pct": five["utilization"], "seven_day_pct": seven["utilization"]})
        return True
    except Exception as e:
        log_event("fetch_usage", "account_cache_error", "warning", {"error": str(e), "type": type(e).__name__})
        return False


def fetch() -> None:
    CACHE_DIR.mkdir(exist_ok=True)
    cleanup_old_logs()
    if from_account_cache():
        return

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

    # The endpoint's generic limit list (session, weekly_all, weekly_scoped
    # per model — Fable today, whatever later), normalized: consumers show
    # model limits from here instead of hardcoding a seven_day_<model> key.
    shares = {
        share.get("limit_index"): share.get("allowance_percent_of_weekly")
        for share in data.get("weekly_scoped_shares") or []
    }

    def limit(index: int, item: dict) -> dict:
        scope = item.get("scope") or {}
        model = (scope.get("model") or {}).get("display_name")
        surface = scope.get("surface")
        return {
            "kind": item.get("kind"),
            "group": item.get("group"),
            "label": model or (surface if isinstance(surface, str) else None),
            "percent": item.get("percent"),
            "resets_at_epoch": _to_epoch(item.get("resets_at")),
            "severity": item.get("severity"),
            "is_active": item.get("is_active"),
            "allowance_percent_of_weekly": shares.get(index),
        }

    limits = [limit(i, item) for i, item in enumerate(data.get("limits") or [])]

    result = {
        # Legacy top-level keys — statusline.sh and agent-gateway read these.
        "five_hour": extract("five_hour"),
        "seven_day": extract("seven_day"),
        "seven_day_sonnet": extract("seven_day_sonnet"),
        "limits": limits,
        "extra_usage": data.get("extra_usage"),
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

    _write_json(CACHE_FILE, result)
    # Unmodified response, for checking what the endpoint returns today.
    _write_json(RAW_FILE, data, indent=2)

    five_h = result["five_hour"]
    seven_d = result["seven_day"]
    now_ts = result["fetched_at"]
    reset_epoch = five_h.get("resets_at_epoch")
    mins_left = round((reset_epoch - now_ts) / 60) if reset_epoch and reset_epoch > now_ts else None
    _push_gateway(five_h.get("utilization"), mins_left, seven_d.get("utilization"))


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
        _write_json(CACHE_FILE, {"error": str(e), "fetched_at": 0})
        sys.exit(1)
    except Exception as e:
        log_event("fetch_usage", "fetch_error", "error", {
            "error": str(e),
            "type": type(e).__name__,
        })
        CACHE_DIR.mkdir(exist_ok=True)
        _write_json(CACHE_FILE, {"error": str(e), "fetched_at": 0})
        sys.exit(1)
