#!/usr/bin/env bash
# human-queue-notify-hook — the push half of ask-human.sh. Installed by
# `make setup` on the cache backend (the mini) as
# ~/.config/human-queue/notify-hook; ask-human.sh fires it in the background
# right after a request lands on disk, with `<id> <text>`.
#
# One ntfy message on topic `factory` (priority high), so the human learns a
# request exists on the iPhone and the Mac without opening a terminal. The queue
# itself is the source of truth: this is a nudge, and every failure here is
# soft. It never blocks, never retries, never exits non-zero — ask-human.sh has
# already returned by the time this runs, and a hook that could fail an enqueue
# would be worse than no hook.
#
# The bearer comes from the secrets cache (`secrets-run read`, never `op`: a
# direct `op` call on the mini hangs on a biometric prompt). The server host is
# private and this repo is public: NTFY_URL, else the base-url in the homelab
# repo's ntfy config, read at run time.
#
# Usage: human-queue-notify-hook.sh <request-id> <text>

set -u

NTFY_TOPIC="${HUMAN_QUEUE_NOTIFY_TOPIC:-factory}"
NTFY_CONFIG="${NTFY_CONFIG:-$HOME/SourceRoot/homelab/config/ntfy/server.yml}"
SECRETS_RUN_BIN="${SECRETS_RUN_BIN:-$HOME/.local/bin/secrets-run}"
CURL_BIN="${CURL_BIN:-/usr/bin/curl}"

id="${1:-}"
text="${2:-}"
[[ -n "$id" && -n "$text" ]] || exit 0

[[ -x "$SECRETS_RUN_BIN" ]] || exit 0
token=$("$SECRETS_RUN_BIN" read op://common/ntfy/TOKEN 2>/dev/null) || exit 0
[[ -n "$token" ]] || exit 0

base="${NTFY_URL:-}"
if [[ -z "$base" && -r "$NTFY_CONFIG" ]]; then
  base=$(sed -n 's/^base-url:[[:space:]]*"\{0,1\}\([^"[:space:]]*\)"\{0,1\}[[:space:]]*$/\1/p' "$NTFY_CONFIG" | head -1)
fi
[[ -n "$base" ]] || exit 0

host=$(hostname -s 2>/dev/null || hostname)
message=$(printf 'Human needed on %s: %s\n%s — drain with `make human-queue` on the MacBook' "$host" "$text" "$id")

"$CURL_BIN" -fsS --max-time 10 -o /dev/null -X POST "${base%/}/$NTFY_TOPIC" \
  -H "Authorization: Bearer $token" \
  -H "Title: Human needed" \
  -H "Priority: high" \
  -H "Tags: raising_hand" \
  --data-binary "$message" >/dev/null 2>&1 || true
exit 0
