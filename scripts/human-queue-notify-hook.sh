#!/usr/bin/env bash
# human-queue-notify-hook — the push half of ask-human.sh. Installed by
# `make setup` on the cache backend (the mini) as
# ~/.config/human-queue/notify-hook; ask-human.sh fires it in the background
# right after a request lands on disk, with `<id> <text>`.
#
# One Slack line to #agents, through Argo's Slack proxy, so the human learns a
# request exists without opening a terminal. The queue itself is the source of
# truth: this is a nudge, and every failure here is soft. It never blocks, never
# retries, never exits non-zero — ask-human.sh has already returned by the time
# this runs, and a hook that could fail an enqueue would be worse than no hook.
#
# The bearer comes from the secrets cache (`secrets-run read`, never `op`: a
# direct `op` call on the mini hangs on a biometric prompt). The channel id is
# resolved from Argo's channel list by name, once per call, so a re-created
# channel keeps working without a config edit.
#
# Usage: human-queue-notify-hook.sh <request-id> <text>

# shellcheck disable=SC2016  # jq filters and Slack backticks are literal by design
set -u

ARGO_BASE_URL="${ARGO_BASE_URL:-https://argo.jkrumm.com/api}"
CHANNEL="${HUMAN_QUEUE_NOTIFY_CHANNEL:-agents}"
SECRETS_RUN_BIN="${SECRETS_RUN_BIN:-$HOME/.local/bin/secrets-run}"
CURL_BIN="${CURL_BIN:-/usr/bin/curl}"
JQ_BIN="${JQ_BIN:-/usr/bin/jq}"

id="${1:-}"
text="${2:-}"
[[ -n "$id" && -n "$text" ]] || exit 0

[[ -x "$SECRETS_RUN_BIN" && -x "$JQ_BIN" ]] || exit 0
token=$("$SECRETS_RUN_BIN" read op://common/api/SECRET 2>/dev/null) || exit 0
[[ -n "$token" ]] || exit 0

channel_id=$("$CURL_BIN" -fsS --max-time 10 "$ARGO_BASE_URL/slack/channels" \
  -H "Authorization: Bearer $token" 2>/dev/null \
  | "$JQ_BIN" -r --arg name "$CHANNEL" '.[] | select((.name // "") == $name) | .id' 2>/dev/null \
  | head -1) || exit 0
[[ -n "$channel_id" ]] || exit 0

host=$(hostname -s 2>/dev/null || hostname)
message=$(printf 'Human needed on %s: %s\n`%s` — drain with `make human-queue` on the MacBook' "$host" "$text" "$id")
body=$("$JQ_BIN" -cn --arg text "$message" '{text: $text}')

"$CURL_BIN" -fsS --max-time 10 -o /dev/null -X POST \
  "$ARGO_BASE_URL/slack/channels/$channel_id/messages" \
  -H "Authorization: Bearer $token" \
  -H "content-type: application/json" \
  -d "$body" >/dev/null 2>&1 || true
exit 0
