#!/usr/bin/env bash
set +x
set -euo pipefail

# secrets-freshness-check — a staleness HEARTBEAT for the SOPS+age secrets cache,
# reported to Uptime Kuma. This is a *reminder*, never an automated reseed: the
# biometric half of a reseed can't be cron-approved (PRD N4), so this only nudges
# the human to run `make secrets-seed` when the cache goes stale.
#
# It reads only the cache files' MTIME — it never decrypts, so a health check
# never touches a secret value. The seed writes each cache atomically (temp+mv),
# so mtime ≈ last-seed time.
#
# Reports to an Uptime Kuma PUSH monitor: green (status=up) while the newest
# cache is younger than the threshold, red (status=down) once it's older —
# Uptime Kuma then alerts. If the cache is missing entirely, we also push down.
# If the push URL can't be resolved, we exit non-zero WITHOUT pushing, so the
# monitor's own "missed heartbeat" fires (fail-loud, not fail-silent).
#
# Usage: secrets-freshness-check.sh
#   SECRETS_FRESHNESS_MAX_AGE_DAYS  (default 8 — one day of slack past a weekly ritual)
#   SECRETS_FRESHNESS_PUSH_URL      Uptime Kuma push URL; if unset, read from the
#                                   chmod-600 PUSH_URL_FILE below.

SECRETS_PRIVATE_REPO="${SECRETS_PRIVATE_REPO:-$HOME/SourceRoot/dotfiles-private}"
CACHE_FILE="$SECRETS_PRIVATE_REPO/cache/secrets.enc.json"
MAX_AGE_DAYS="${SECRETS_FRESHNESS_MAX_AGE_DAYS:-8}"
# The push URL lives in a chmod-600 file OUTSIDE the cache on purpose: a health
# monitor's liveness must not depend on the very thing it monitors. If the URL
# came from the cache, a broken/missing cache (exactly the alert condition) would
# leave us unable to push at all. The base URL (no query) is a low-sensitivity
# Uptime Kuma push token, never committed to git.
PUSH_URL_FILE="${SECRETS_FRESHNESS_PUSH_URL_FILE:-$HOME/.config/secrets/freshness-push-url}"

# Resolve the push URL: explicit env wins, else the local chmod-600 file.
push_url="${SECRETS_FRESHNESS_PUSH_URL:-}"
if [[ -z "$push_url" && -r "$PUSH_URL_FILE" ]]; then
  push_url=$(tr -d '[:space:]' <"$PUSH_URL_FILE")
fi
[[ -n "$push_url" ]] || {
  echo "✗ no push URL (set SECRETS_FRESHNESS_PUSH_URL or write the base push URL to $PUSH_URL_FILE) — not pushing; Kuma will alert on the missed heartbeat" >&2
  exit 1
}

# Uptime Kuma push endpoint: <base>/api/push/<token>?status=up|down&msg=...&ping=
push() {
  local status="$1" msg="$2" sep="?"
  [[ "$push_url" == *\?* ]] && sep="&"
  curl -fsS --max-time 15 -o /dev/null \
    --data-urlencode "status=$status" \
    --data-urlencode "msg=$msg" \
    -G "$push_url" 2>/dev/null \
    || curl -fsS --max-time 15 -o /dev/null \
         "${push_url}${sep}status=${status}&msg=$(printf '%s' "$msg" | sed 's/ /%20/g')" 2>/dev/null
}

# Cache mtime = last seed time (the seed writes it atomically: temp + mv).
newest_epoch=0
if [[ -f "$CACHE_FILE" ]]; then
  newest_epoch=$(stat -f %m "$CACHE_FILE" 2>/dev/null || echo 0)
fi

if [[ "$newest_epoch" -eq 0 ]]; then
  push down "no secrets cache present — run make secrets-seed"
  echo "! no cache at $CACHE_FILE — pushed down" >&2
  exit 0
fi

now_epoch=$(date -u +%s)
age_days=$(((now_epoch - newest_epoch) / 86400))

if ((age_days > MAX_AGE_DAYS)); then
  push down "secrets cache ${age_days}d old (max ${MAX_AGE_DAYS}d) — reseed with make secrets-seed"
  echo "! cache ${age_days}d old (> ${MAX_AGE_DAYS}d) — pushed down (reseed reminder)" >&2
else
  push up "secrets cache ${age_days}d old"
  echo "✓ cache ${age_days}d old — pushed up" >&2
fi
