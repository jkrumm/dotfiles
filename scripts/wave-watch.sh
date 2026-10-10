#!/usr/bin/env bash
# The one wave watcher: block until something needs the orchestrator, print why, exit 0.
#
#   wave-watch.sh <agent> <repo-dir> <plan-file> <wave-number> [--stall 45]
#       sequential / orchestrated wave: wakes on the wave's PLAN status flipping to done,
#       the agent going idle/blocked/done/gone, or no repo change for --stall minutes.
#
#   wave-watch.sh --agents a,b,c [--repo <dir>] [--events <file>] [--heartbeat 20] [--stall 45]
#       fan-out / fleet: wakes on ANY listed agent leaving `working` or vanishing, a new
#       line in --events, a 20-minute heartbeat, or (with --repo) the stall rule. Output starts with
#       DONE | AGENT | EVENT | HEARTBEAT | STALL so the caller can branch on one word.
#
# "Change" = HEAD + status + diff across EVERY worktree of the repo, so a worker busy in a
# fan-out worktree is not mistaken for a stall. Bound the call from the caller side with
# `timeout` when it must not run forever.
set -euo pipefail

stall_min=45 heartbeat_min=20 events="" repo="" agents="" single=""
if [[ ${1:-} == --agents ]]; then
  while (($#)); do
    case $1 in
      --agents) agents=${2:?--agents needs a comma list}; shift 2 ;;
      --repo) repo=${2:?--repo needs a dir}; shift 2 ;;
      --events) events=${2:?--events needs a file}; shift 2 ;;
      --heartbeat) heartbeat_min=${2:?--heartbeat needs minutes}; shift 2 ;;
      --stall) stall_min=${2:?--stall needs minutes}; shift 2 ;;
      *) echo "unknown flag $1" >&2; exit 2 ;;
    esac
  done
  [[ -n $agents ]] || { echo "--agents needs a comma list" >&2; exit 2; }
  IFS=, read -r -a agent_list <<<"$agents"
else
  agent=${1:?usage: wave-watch.sh <agent> <repo-dir> <plan-file> <wave-number> | --agents a,b,c ...}
  repo=${2:?repo-dir} plan=${3:?plan-file} wave=${4:?wave-number}; shift 4
  [[ ${1:-} == --stall ]] && stall_min=$2
  single=1
  plan_dir=$(dirname "$(dirname "$(dirname "$plan")")")
fi

# A transient herdr/jq error yields "" (= gone), never an aborted watcher.
status_of() { herdr agent list 2>/dev/null | jq -r --arg n "$1" '.result.agents[]? | select(.name==$n) | .agent_status' 2>/dev/null || true; }
# An idle/done agent still waiting on its own background subagents, shells or monitors
# (Claude Code's footer: "2 background tasks", "Waiting for 1 background agent", "1 monitor")
# is not finished — its close-out lands when they return.
waiting_on_background() {
  rd read "$1" 2>/dev/null | tail -8 |
    grep -qE '[0-9]+ background tasks?|Waiting for [0-9]+ background|[0-9]+ monitors?\b'
}
repo_sig() {
  [[ -n $repo ]] || return 0
  git -C "$repo" worktree list --porcelain | awk '/^worktree /{print $2}' |
    while read -r wt; do git -C "$wt" rev-parse HEAD; git -C "$wt" status --porcelain; git -C "$wt" diff; done | shasum
}

last_sig="" start=$(date +%s) last_change=$start
event_lines=0; [[ -n $events && -f $events ]] && event_lines=$(wc -l <"$events")
while :; do
  now=$(date +%s)
  if [[ -n $single ]]; then
    git -C "$plan_dir" pull -q --rebase 2>/dev/null || true
    if grep -qE "^## Wave $wave .*status: done" "$plan"; then echo "DONE wave $wave"; exit 0; fi
    st=$(status_of "$agent")
    case $st in
      idle|done) waiting_on_background "$agent" || { echo "AGENT $agent status=$st"; exit 0; } ;;
      blocked|"") echo "AGENT $agent status=${st:-gone}"; exit 0 ;;
    esac
  else
    for a in "${agent_list[@]}"; do
      st=$(status_of "$a")
      case $st in
        working) ;;
        idle|done) waiting_on_background "$a" || { echo "AGENT $a status=$st"; exit 0; } ;;
        *) echo "AGENT $a status=${st:-gone}"; exit 0 ;;
      esac
    done
    if [[ -n $events && -f $events ]]; then
      n=$(wc -l <"$events")
      if ((n > event_lines)); then echo "EVENT $(sed -n "$((event_lines + 1))p" "$events")"; exit 0; fi
    fi
    if ((now - start >= heartbeat_min * 60)); then echo "HEARTBEAT ${heartbeat_min}m"; exit 0; fi
  fi
  sig=$(repo_sig)
  if [[ -z $repo ]]; then :  # no --repo: no stall signal, only the heartbeat bounds the wait
  elif [[ $sig != "$last_sig" ]]; then last_sig=$sig last_change=$now
  elif ((now - last_change > stall_min * 60)); then echo "STALL: no repo change for ${stall_min}m"; exit 0; fi
  sleep 90
done
