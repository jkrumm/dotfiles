#!/usr/bin/env bash
# Block until no herdr agent is `working` for a sustained window.
#
#   herdr-wait-quiet.sh [--exclude-name NAME]... [--interval SEC] [--quiet-checks N]
#
# Excludes the caller's own pane ($HERDR_PANE_ID). An agent counts as busy only
# while `working`; idle, done and blocked are settled (blocked waits on a human
# and would otherwise hold the wait forever). The window must be quiet for N
# consecutive checks, so a /loop tab that wakes hourly does not slip a start in
# between two of its turns. Prints one status line per check; exits 0 when quiet.
set -euo pipefail

interval=120
quiet_checks=3
excludes=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --exclude-name) excludes+=("$2"); shift 2 ;;
    --interval) interval="$2"; shift 2 ;;
    --quiet-checks) quiet_checks="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

self="${HERDR_PANE_ID:-}"
exclude_json=$(printf '%s\n' "${excludes[@]+"${excludes[@]}"}" | jq -R . | jq -sc 'map(select(length > 0))')

streak=0
while true; do
  busy=$(herdr agent list | jq -r --arg self "$self" --argjson ex "$exclude_json" '
    .result.agents[]
    | select(.pane_id != $self)
    | select((.name // "") as $n | ($ex | index($n)) | not)
    | select(.agent_status == "working")
    | "\(.name // .terminal_title_stripped) (\(.cwd | sub("^/Users/[^/]+/"; "~/")))"')
  if [[ -z "$busy" ]]; then
    streak=$((streak + 1))
    echo "$(date +%H:%M) quiet ${streak}/${quiet_checks}"
    [[ $streak -ge $quiet_checks ]] && exit 0
  else
    streak=0
    echo "$(date +%H:%M) busy: $(echo "$busy" | paste -sd ';' -)"
  fi
  sleep "$interval"
done
