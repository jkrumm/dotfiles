#!/usr/bin/env bash
# Shared Uptime Kuma push helpers, sourced by the heartbeat scripts
# (secrets-freshness-check.sh, devhost-health-check.sh). Extracted once there
# were two copies and a third was foreseeable.
#
# Every heartbeat here follows the same two rules:
#   - The push token lives in a chmod-600 file, never in the SOPS+age cache. A
#     monitor must not depend on the thing it monitors: if the URL came from the
#     cache, a broken cache — exactly the alert condition — would leave us
#     unable to report it.
#   - Fail loud, never fail silent. If the URL cannot be resolved we refuse to
#     push at all, so Uptime Kuma's own missed-heartbeat alert fires. A monitor
#     that quietly stops reporting is worse than no monitor.
#
# Not executable on its own; `source` it.

# kuma_resolve_push_url <env-value> <url-file>
# Echoes the resolved URL, or returns 1 having explained itself on stderr.
kuma_resolve_push_url() {
  local from_env="${1:-}" url_file="${2:-}" url=""

  if [[ -n "$from_env" ]]; then
    url="$from_env"
  elif [[ -r "$url_file" ]]; then
    url=$(tr -d '[:space:]' <"$url_file")
  fi

  if [[ -z "$url" ]]; then
    echo "✗ no push URL (pass it in the environment, or write the base push URL to $url_file) — not pushing; Kuma will alert on the missed heartbeat" >&2
    return 1
  fi

  printf '%s' "$url"
}

# kuma_push <url> <up|down> <msg>
# Uptime Kuma push endpoint: <base>/api/push/<token>?status=up|down&msg=...
# `curl -G --data-urlencode` builds the query string, so every reserved
# character in msg is encoded properly. Do NOT hand-roll the URL — an earlier
# version appended a fallback that escaped only spaces, which would have
# corrupted the query as soon as a check interpolated tool output into msg.
#
# One retry on a transport failure (curl 6/7/28/35/52/55/56: DNS, refused, timed out,
# TLS, empty reply, reset). Kuma's push endpoint stalls past 15 s now and then; before
# the retry that one lost push failed the whole devhost-health run (6 flaps in a day,
# every one a single timed-out push, all sibling pushes fine). An HTTP error (rc 22)
# is a real answer and is never retried. The retry is spent at most once per process:
# when Kuma is genuinely down the first retry fails too, and later pushes then go out
# once each, so a dead Kuma cannot stretch a heartbeat run past its jobrun timeout.
KUMA_PUSH_RETRY_SPENT=0
kuma_push() {
  local url="$1" status="$2" msg="$3" rc=0
  kuma_push_once 15 "$url" "$status" "$msg" || rc=$?
  case "$rc" in
    6|7|28|35|52|55|56)
      (( KUMA_PUSH_RETRY_SPENT == 0 )) || return "$rc"
      sleep 2
      rc=0
      kuma_push_once 10 "$url" "$status" "$msg" || rc=$?
      (( rc == 0 )) || KUMA_PUSH_RETRY_SPENT=1
      ;;
  esac
  return "$rc"
}

kuma_push_once() {
  local max_time="$1" url="$2" status="$3" msg="$4"
  curl -fsS --max-time "$max_time" -o /dev/null \
    --data-urlencode "status=$status" \
    --data-urlencode "msg=$msg" \
    -G "$url"
}
