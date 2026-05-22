import json
import os
from datetime import datetime, timezone

from litellm.integrations.custom_logger import CustomLogger


def _get(obj, key, default=0):
    """Read a field from either a dict or an object (pydantic usage models)."""
    if obj is None:
        return default
    if isinstance(obj, dict):
        val = obj.get(key, default)
    else:
        val = getattr(obj, key, default)
    return default if val is None else val


class UsageLogger(CustomLogger):
    """Append per-request token usage to a JSONL file for usage-tracker ingestion.

    The bridge serves the OpenAI chat/completions transport, where `prompt_tokens`
    INCLUDES cached input. usage-tracker treats input and cache-read separately and
    prices them differently, so we record non-cached input (prompt - cache_read).
    Cache fields are surfaced both at the top level (Anthropic-style
    cache_read_input_tokens / cache_creation_input_tokens) and nested under
    prompt_tokens_details (cached_tokens / cache_creation_tokens) — prefer the
    top-level values and fall back to the nested ones.
    """

    _LOG_PATH = os.path.expanduser("~/.local/share/usage-tracker/litellm.jsonl")

    async def async_log_success_event(self, kwargs, response_obj, start_time, end_time):
        try:
            sl = kwargs.get("standard_logging_object") if isinstance(kwargs, dict) else None
            usage = getattr(response_obj, "usage", None) if response_obj is not None else None

            # Stable identifiers from the standard logging object, then fallbacks.
            request_id = _get(sl, "litellm_call_id", "") or (
                _get(kwargs, "litellm_call_id", "") if isinstance(kwargs, dict) else ""
            ) or _get(response_obj, "id", "")
            model = _get(sl, "model", "") or (
                _get(kwargs, "model", "") if isinstance(kwargs, dict) else ""
            )

            prompt_tokens = int(_get(usage, "prompt_tokens", 0))
            output_tokens = int(_get(usage, "completion_tokens", 0))

            ptd = _get(usage, "prompt_tokens_details", None)
            cache_read = int(_get(usage, "cache_read_input_tokens", 0) or _get(ptd, "cached_tokens", 0))
            cache_write = int(
                _get(usage, "cache_creation_input_tokens", 0) or _get(ptd, "cache_creation_tokens", 0)
            )

            ctd = _get(usage, "completion_tokens_details", None)
            reasoning = int(_get(ctd, "reasoning_tokens", 0))

            # prompt_tokens includes cached input on the OpenAI transport; record
            # only the non-cached portion as input so cost isn't double-counted.
            input_tokens = max(0, prompt_tokens - cache_read)

            record = {
                "ts": datetime.now(timezone.utc).isoformat(),
                "request_id": request_id,
                "model": model,
                "input_tokens": input_tokens,
                "output_tokens": output_tokens,
                "cache_read_tokens": cache_read,
                "cache_write_tokens": cache_write,
                "reasoning_tokens": reasoning,
            }

            os.makedirs(os.path.dirname(self._LOG_PATH), exist_ok=True)
            with open(self._LOG_PATH, "a", encoding="utf-8") as f:
                f.write(json.dumps(record, default=str) + "\n")
        except Exception:
            # Logging must never break the proxy.
            pass

    async def async_log_failure_event(self, kwargs, response_obj, start_time, end_time):
        """Append a token-less error record so usage-tracker can compute the bridge
        error rate. Kimi-K2.6 is single-backend (Azure Sweden) and intermittently
        5xx/429s, so this rate reflects every consumer's experience, not just one.
        A failed attempt the fallback later rescues still logs here (the rescue is a
        separate success event) — the right signal for Kimi availability.
        """
        try:
            sl = kwargs.get("standard_logging_object") if isinstance(kwargs, dict) else None
            exception = kwargs.get("exception") if isinstance(kwargs, dict) else None

            request_id = _get(sl, "litellm_call_id", "") or (
                _get(kwargs, "litellm_call_id", "") if isinstance(kwargs, dict) else ""
            )
            model = _get(sl, "model", "") or (
                _get(kwargs, "model", "") if isinstance(kwargs, dict) else ""
            )

            err_info = _get(sl, "error_information", None)
            error_type = (
                _get(err_info, "error_class", "")
                or (type(exception).__name__ if exception is not None else "")
                or "error"
            )
            error_code = _get(err_info, "error_code", "") or None
            status_code = getattr(exception, "status_code", None) if exception is not None else None

            record = {
                "ts": datetime.now(timezone.utc).isoformat(),
                "request_id": request_id,
                "model": model,
                "event": "error",
                "error_type": error_type,
                "error_code": error_code,
                "status_code": status_code,
            }

            os.makedirs(os.path.dirname(self._LOG_PATH), exist_ok=True)
            with open(self._LOG_PATH, "a", encoding="utf-8") as f:
                f.write(json.dumps(record, default=str) + "\n")
        except Exception:
            # Logging must never break the proxy.
            pass


usage_logger_instance = UsageLogger()
