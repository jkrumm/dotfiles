#!/usr/bin/env bash
# Block until a wave needs the orchestrator: its PLAN status flips to done, its agent
# goes idle/blocked/done, or its repo shows no change (diff + HEAD) for --stall minutes.
# Usage: wave-watch.sh <agent-name> <repo-dir> <plan-file> <wave-number> [--stall 45]
set -euo pipefail
agent=$1 repo=$2 plan=$3 wave=$4; shift 4
stall_min=45; [[ ${1:-} == --stall ]] && stall_min=$2
plan_dir=$(dirname "$(dirname "$(dirname "$plan")")")
last_sig="" last_change=$(date +%s)
while :; do
  git -C "$plan_dir" pull -q --rebase 2>/dev/null || true
  if grep -qE "^## Wave $wave .*status: done" "$plan"; then echo "DONE wave $wave"; exit 0; fi
  st=$(herdr agent list | jq -r --arg n "$agent" '.result.agents[] | select(.name==$n) | .agent_status')
  case $st in idle|blocked|done|"") echo "AGENT $agent status=${st:-gone}"; exit 0;; esac
  sig=$(git -C "$repo" rev-parse HEAD)$(git -C "$repo" diff | shasum | cut -c1-12)
  now=$(date +%s)
  if [[ $sig != "$last_sig" ]]; then last_sig=$sig last_change=$now
  elif (( now - last_change > stall_min * 60 )); then echo "STALL $agent: no repo change for ${stall_min}m"; exit 0; fi
  sleep 90
done
