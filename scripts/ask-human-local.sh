#!/usr/bin/env bash
# ask-human-local — the `ask-human` command on PATH (~/.local/bin/ask-human), the same on both machines.
#
# On the mini (backend marker `cache`) it is exactly scripts/ask-human.sh. On the MacBook it is the same script
# with three defaults for an agent that runs THERE:
#   - HUMAN_QUEUE_MAC_HOST=local   the dialog opens in this session (`gui-run` in-process), not through ssh to
#                                  the MacBook the agent already is on; the answer is the exit code and stdout
#                                  of the asking call, so it returns to that session
#   - HUMAN_QUEUE_ERRANDS=0        the factory (the Console list of the mini's requests) is not reached from here;
#                                  a request nobody answered stays in this machine's queue dir (exit 75): push it
#                                  again with `ask-human push <id>`
#   - the text is prefixed         the pinned dialog says "agent on the mini"; the prefix says who really asked
# ask-human.sh and human-queue.sh themselves stay untouched: the IuRoot deploy gate pins their hashes
# (scripts/AGENTS.md §Deploy gate pins). An explicit HUMAN_QUEUE_* in the environment wins over these defaults.
#
# Bash 3.2.
set -u

HERE="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
BACKEND_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/secrets/backend"
backend=""
[ -r "$BACKEND_FILE" ] && backend="$(tr -d '[:space:]' <"$BACKEND_FILE")"

if [ "$backend" != cache ]; then
  export HUMAN_QUEUE_MAC_HOST="${HUMAN_QUEUE_MAC_HOST:-local}"
  export HUMAN_QUEUE_ERRANDS="${HUMAN_QUEUE_ERRANDS:-0}"
  if [ "${1:-}" = ask ] && [ -n "${2:-}" ] && [[ "$2" != --* ]]; then
    text="(asked by an agent on this MacBook) $2"
    shift 2
    set -- ask "$text" "$@"
  fi
fi

exec bash "$HERE/ask-human.sh" "$@"
