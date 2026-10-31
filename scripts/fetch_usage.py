# /// script
# requires-python = ">=3.14"
# ///
"""Adapt claude-account's quota cache to the files statusline.sh and Tinycast read.

`claude-account` is the only owner of subscription usage (docs/claude-accounts.md): this script never calls
Anthropic itself. It writes /tmp/claude_sl/usage_api.json (the default account, the legacy shape the
statusline's pre-first-response fallback and Tinycast read) from `claude-account usage --json`. When that
account's sample is stale it asks the owner for one (`claude-account refresh --ids <default>`, which applies
its own rate-limit budget and claim) and reads again. Still stale afterwards: the existing file is kept, or a
login error is written when claude-account says the login is rejected.
All accounts are also written to /tmp/claude_sl/usage_accounts.json (per account: plan, and per window the
fresh `utilization` plus the last known `value`/`value_resets_at_epoch` with its `age_s` — the statusline's
other-account and pool segments read those). `--accounts` writes only that file: no API call, no host
report (the statusline's own 60 s refresh while a session already has rate_limits).

Run via: uv run ~/.claude/fetch_usage.py [--accounts]
"""

import json
import os
import shutil
import subprocess
import tempfile
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

CACHE_DIR = Path("/tmp/claude_sl")
CACHE_FILE = CACHE_DIR / "usage_api.json"
LOG_DIR = Path.home() / ".claude" / "logs"

AGW_BIN = "agw"
KEYCHAIN_SERVICE = "Claude Code-credentials"

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


def _report_quota(five_pct, mins_left, seven_pct, account: str = DEFAULT_ACCOUNT) -> None:
    # Report to the host's quota view (`agw quota-report`, held in memory, no journal row) — fail silently
    # when agw or the host is absent (the MacBook). Both feeds here read the default account (the cache's
    # default_account, or the default keychain login).
    exe = shutil.which(AGW_BIN) or str(Path.home() / ".local" / "bin" / AGW_BIN)
    cmd = [exe, "quota-report", "--five-hour-pct", str(round(five_pct or 0)), "--account", account]
    if mins_left is not None:
        cmd += ["--five-hour-mins-left", str(mins_left)]
    if seven_pct is not None:
        cmd += ["--seven-day-pct", str(round(seven_pct))]
    try:
        subprocess.run(cmd, capture_output=True, timeout=5)
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
        "value": row.get(key),  # last known, whatever its age: judge it by age_s
        "value_resets_at_epoch": row.get(f"{key}_resets_at"),
    }


def write_accounts_file(data: dict, now: float) -> None:
    _write_json(ACCOUNTS_FILE, {
        "default_account": data.get("default_account"),
        "accounts": {
            r["id"]: {
                "plan": r.get("plan"),
                "five_hour": _window(r, "five_hour", now),
                "seven_day": _window(r, "seven_day", now),
                "sampled_at": int(now - r["age_s"]) if r.get("age_s") is not None else None,
                "source": r.get("source"),
                "enabled": r.get("enabled"),
                "auth_ok": r.get("auth_ok"),
                "exhausted_until": r.get("exhausted_until"),
            }
            for r in data["accounts"]
        },
        "fetched_at": int(now),
    })


def from_account_cache() -> bool:
    """Write usage_accounts.json for all accounts; write usage_api.json from the default account when its 5h window is fresh.

    Returns True when usage_api.json was served from the cache (no API call needed). Any problem returns False
    so the caller falls through to the API path."""
    try:
        data = _claude_account_usage()
        now = time.time()
        rows = data["accounts"]
        write_accounts_file(data, now)
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
        _report_quota(five["utilization"], mins, seven["utilization"], data.get("default_account") or DEFAULT_ACCOUNT)
        log_event("fetch_usage", "served_from_cache", "info", {"five_hour_pct": five["utilization"], "seven_day_pct": seven["utilization"]})
        return True
    except Exception as e:
        log_event("fetch_usage", "account_cache_error", "warning", {"error": str(e), "type": type(e).__name__})
        return False


def _refresh_default(default: str) -> None:
    """Ask the owner for a fresh sample of the default account (its budget and claim apply)."""
    exe = shutil.which(CLAUDE_ACCOUNT_BIN) or str(Path.home() / ".local" / "bin" / CLAUDE_ACCOUNT_BIN)
    subprocess.run([exe, "refresh", "--ids", default], capture_output=True, text=True, timeout=60)


def fetch() -> None:
    CACHE_DIR.mkdir(exist_ok=True)
    cleanup_old_logs()
    if from_account_cache():
        return
    data = _claude_account_usage()
    default = data.get("default_account") or DEFAULT_ACCOUNT
    _refresh_default(default)
    if from_account_cache():
        return
    row = next((r for r in _claude_account_usage()["accounts"] if r["id"] == default), None)
    if row and row.get("auth_ok") is False:
        # The statusline shows "⚠ claude.ai login" for an error file; claude-account health names the fix.
        _write_json(CACHE_FILE, {"error": f"{default}: login rejected (claude-account health)", "fetched_at": int(time.time())})
        log_event("fetch_usage", "login_rejected", "warning", {"account": default})
        return
    # Stale but logged in: keep the last file; the statusline's 5-min respawn gate tries again.
    log_event("fetch_usage", "stale_kept", "info", {"account": default})


if __name__ == "__main__":
    if "--accounts" in sys.argv[1:]:
        try:
            CACHE_DIR.mkdir(exist_ok=True)
            write_accounts_file(_claude_account_usage(), time.time())
        except Exception as e:
            log_event("fetch_usage", "accounts_file_error", "warning", {"error": str(e), "type": type(e).__name__})
            sys.exit(1)
        sys.exit(0)
    try:
        fetch()
    except Exception as e:
        log_event("fetch_usage", "fetch_error", "error", {
            "error": str(e),
            "type": type(e).__name__,
        })
        sys.exit(1)
