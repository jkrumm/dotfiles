#!/usr/bin/env bash
set -euo pipefail

# ask-human — enqueue present-human work from the mini (or any machine with no
# path back to a human). The mini can now `ssh iumac` (dedicated key, see
# ssh_config), so a network path to the MacBook exists — but SSH gives it
# reach, not a fingerprint. This channel is for what actually still needs a
# *present human*: biometric `op` (`make secrets-seed`), the Tailscale ACL
# push, or any decision only a person can make. Before this, an agent on the
# mini signalled blocked-on-human work by editing prose handover docs, which
# the human might not read for days.
#
# This is the async channel instead: an agent here writes a small request file,
# `human-queue.sh` on the MacBook (the human's own machine) lists and runs or
# denies it over the existing MacBook→mini ssh, and the result lands back here
# for a waiting agent to pick up. No new credential beyond what already exists.
#
# Queue root: ${XDG_STATE_HOME:-$HOME/.local/state}/human-queue/, mode 700.
# One request is two files: <id>.req (written here) and <id>.res (written by
# human-queue.sh once a human has acted). "Pending" means a .req with no
# matching .res yet.
#
# No `jq` hard dependency (this machine's cache-backend allowlist is narrow and
# must not gain a package requirement for a queue file) — used opportunistically
# when present, hand-rolled JSON otherwise.

QUEUE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/human-queue"

die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
note() { printf '\033[2m%s\033[0m\n' "$*" >&2; }

# json_escape, json_field, printable — shared with human-queue.sh, which
# displays these same fields on the MacBook right before a typed-'yes'
# execution prompt.
# shellcheck source=lib/human-queue-json.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/human-queue-json.sh"

ensure_queue_dir() {
  mkdir -p "$QUEUE_DIR"
  chmod 700 "$QUEUE_DIR"
}

format_age() {
  local s="$1"
  if (( s < 60 )); then
    printf '%ds' "$s"
  elif (( s < 3600 )); then
    printf '%dm' "$(( s / 60 ))"
  elif (( s < 86400 )); then
    printf '%dh' "$(( s / 3600 ))"
  else
    printf '%dd' "$(( s / 86400 ))"
  fi
}

# Fire-and-forget on purpose: backgrounding inside a subshell means this
# function returns immediately regardless of what the hook does, so a hook
# that hangs, crashes, or was never wired can never delay or fail the enqueue
# — the request is already durably on disk by the time this runs. `|| true`
# is belt-and-braces on top of that for the case where even the background
# launch itself fails (e.g. a non-executable file that slipped past -x).
fire_notify_hook() {
  local id="$1" text="$2"
  local hook="${XDG_CONFIG_HOME:-$HOME/.config}/human-queue/notify-hook"
  if [[ -x "$hook" ]]; then
    ( "$hook" "$id" "$text" >/dev/null 2>&1 & ) || true
  else
    note "no notify hook at $hook — request $id enqueued with no push (see docs/remote-dev.md)"
  fi
}

# Poll <id>.res every 5s. Prints the result and returns 0/1/2 for
# done/denied/failed on arrival, or prints the id and returns 3 on timeout —
# callers that don't care about the distinction can just check `$?`.
poll_for_result() {
  local id="$1" seconds="$2" waited=0
  local res_file="$QUEUE_DIR/$id.res"
  while (( waited < seconds )); do
    if [[ -f "$res_file" ]]; then
      cat "$res_file"
      local status
      status="$(json_field "$(cat "$res_file")" status)"
      case "$status" in
        done) return 0 ;;
        denied) return 1 ;;
        *) return 2 ;;
      esac
    fi
    sleep 5
    waited=$(( waited + 5 ))
  done
  printf '%s\n' "$id"
  return 3
}

cmd_ask() {
  [[ $# -ge 1 ]] || die "ask requires <text> [--cmd <command>] [--wait [seconds]]"
  local text="$1"; shift
  local cmd="" wait_requested=0 wait_seconds=900

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cmd)
        [[ $# -ge 2 ]] || die "--cmd requires a value"
        cmd="$2"
        shift 2
        ;;
      --wait)
        wait_requested=1
        # An optional numeric seconds arg follows; anything starting with
        # `--` is the next flag, not a value, so leave it for the next loop.
        if [[ $# -ge 2 && "$2" != --* ]]; then
          wait_seconds="$2"
          shift 2
        else
          shift
        fi
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
  done

  ensure_queue_dir

  local id created host cwd
  id="$(date +%Y%m%dT%H%M%S)-$RANDOM"
  created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  host="$(hostname -s 2>/dev/null || hostname)"
  cwd="$PWD"

  local cmd_json="null"
  [[ -n "$cmd" ]] && cmd_json="$(json_escape "$cmd")"

  # temp + mv (chmod on the temp file, before it has the final name) so a
  # concurrent `list` never observes a request file that is both present and
  # world-readable, even for an instant.
  local req_file="$QUEUE_DIR/$id.req" tmp_file
  tmp_file="$(mktemp "$QUEUE_DIR/.${id}.req.XXXXXX")"
  {
    printf '{'
    printf '"id":%s,' "$(json_escape "$id")"
    printf '"created":%s,' "$(json_escape "$created")"
    printf '"host":%s,' "$(json_escape "$host")"
    printf '"cwd":%s,' "$(json_escape "$cwd")"
    printf '"text":%s,' "$(json_escape "$text")"
    printf '"cmd":%s' "$cmd_json"
    printf '}\n'
  } > "$tmp_file"
  chmod 600 "$tmp_file"
  mv "$tmp_file" "$req_file"

  fire_notify_hook "$id" "$text"

  printf '%s\n' "$id"

  if [[ $wait_requested -eq 1 ]]; then
    poll_for_result "$id" "$wait_seconds"
    return $?
  fi
}

cmd_list() {
  ensure_queue_dir
  local f found=0
  for f in "$QUEUE_DIR"/*.req; do
    [[ -e "$f" ]] || continue
    local id
    id="$(basename "$f" .req)"
    [[ -f "$QUEUE_DIR/$id.res" ]] && continue
    found=1
    local json text cmd_value marker mtime now age text_disp
    json="$(cat "$f")"
    text="$(json_field "$json" text)"
    cmd_value="$(json_field "$json" cmd)"
    marker=""
    [[ -n "$cmd_value" ]] && marker="[cmd]"
    mtime="$(stat -f %m "$f" 2>/dev/null || echo 0)"
    now="$(date +%s)"
    age="$(format_age "$(( now - mtime ))")"
    # Sanitize before truncating — a raw ESC in the request could otherwise
    # begin a multi-byte escape sequence that the 60-char cut slices in half,
    # plus the same terminal-injection risk print_req (human-queue.sh) exists
    # to close (see printable() in scripts/lib/human-queue-json.sh).
    text_disp="$(printable "$text")"
    printf '%s\t%s\t%-60s\t%s\n' "$id" "$age" "${text_disp:0:60}" "$marker"
  done
  (( found )) || echo "no pending requests"
}

cmd_status() {
  local id="${1:-}"
  [[ -n "$id" ]] || die "status requires <id>"
  ensure_queue_dir
  local req="$QUEUE_DIR/$id.req"
  local res="$QUEUE_DIR/$id.res"
  [[ -f "$req" ]] || die "no such request: $id"
  cat "$req"
  [[ -f "$res" ]] && cat "$res"
  return 0
}

usage() {
  cat <<'EOF'
ask-human.sh — enqueue present-human work from the mini (or any machine)

Usage:
  ask-human.sh ask <text> [--cmd <command>] [--wait [seconds]]
                              Enqueue a request. Prints the request id.
                              --cmd proposes a shell command for the human to
                              review and run on the MacBook (never auto-run).
                              --wait polls for a result (default 900s) and
                              exits 0/1/2/3 for done/denied/failed/timeout.
  ask-human.sh list           List pending requests (no result yet).
  ask-human.sh status <id>    Print a request, and its result if one exists.
  ask-human.sh help           This message.

Queue root: ${XDG_STATE_HOME:-$HOME/.local/state}/human-queue/
Drained from the MacBook by scripts/human-queue.sh (`make human-queue`).
EOF
}

main() {
  local sub="${1:-help}"
  case "$sub" in
    ask) shift; cmd_ask "$@" ;;
    list) shift; cmd_list "$@" ;;
    status) shift; cmd_status "$@" ;;
    help|-h|--help) usage ;;
    *) die "unknown subcommand: $sub (see: ask-human.sh help)" ;;
  esac
}

main "$@"
