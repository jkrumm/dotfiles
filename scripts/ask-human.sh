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
# and a human either drains it on their own schedule (`make human-queue` on the
# MacBook, over the existing MacBook→mini ssh) or this script triggers the
# approval itself: `ask-human.sh ask … --push` (or `push <id>` for an
# already-enqueued request) opens `ssh iumac` — the mini's own dedicated,
# restricted key, see docs/remote-dev.md → *mini → iumac* — and runs
# `human-queue.sh gui-run` there, which shows the exact request in a native
# macOS dialog on the MacBook and only executes on a click. There is still no
# path that skips a present human: the dialog is a second gate next to the
# typed-'yes' TTY gate `run` already requires, not a bypass of it — it exists
# precisely because that ssh key already lets the mini run arbitrary commands
# on the MacBook non-interactively, and turns that reach back into something a
# human approves per request. The result lands back here either way (written
# locally by `push`, or written by `human-queue.sh` over ssh after a manual
# drain) for a waiting agent to pick up. No new credential beyond what already
# exists.
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

# The MacBook-side ssh alias `push` targets — see `Host iumac` in
# config/ssh_config (port 2222, IdentityAgent none, no agent forwarding).
# Overridable for the test harness.
MAC_HOST="${HUMAN_QUEUE_MAC_HOST:-iumac}"
PUSH_SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8)

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
    note "no notify hook at $hook — request $id enqueued with no push (see docs/remote-dev.md → Human queue notifications)"
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

# --wait defaults to 0 (return at once). The median time to a resolution is
# about seven days — the human drains this queue when a MacBook session happens
# to be open, not on any schedule — so a polling default only ever produced a
# timeout after a wasted quarter hour. A caller that genuinely wants to block
# passes an explicit budget: `--wait 600`. --push triggers the approval itself
# right after enqueueing (see push_request below) instead of waiting for a
# manual `make human-queue`; combined with --wait it takes precedence and
# --wait is ignored — push already resolves synchronously over one ssh round
# trip, so there is nothing left to poll for.
cmd_ask() {
  [[ $# -ge 1 ]] || die "ask requires <text> [--cmd <command>] [--wait <seconds>] [--push]"
  local text="$1"; shift
  local cmd="" wait_seconds=0 push_after=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cmd)
        [[ $# -ge 2 ]] || die "--cmd requires a value"
        cmd="$2"
        shift 2
        ;;
      --wait)
        # An optional numeric seconds arg follows; anything starting with
        # `--` is the next flag, not a value, so leave it for the next loop.
        # A bare --wait keeps the 0 default and is a no-op, deliberately.
        if [[ $# -ge 2 && "$2" != --* ]]; then
          wait_seconds="$2"
          shift 2
        else
          shift
        fi
        ;;
      --push)
        push_after=1
        shift
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

  if (( push_after )); then
    push_request "$id"
    return $?
  fi

  if (( wait_seconds > 0 )); then
    poll_for_result "$id" "$wait_seconds"
    return $?
  fi
}

# Persists a result JSON already fetched from the MacBook (gui-run's stdout,
# see push_request) into this machine's own queue — no extra ssh hop, unlike
# write_result on the MacBook side, because this function already runs ON the
# mini, where the queue lives. Same temp+mv+chmod pattern as cmd_ask's own
# .req write, for the same reason: a concurrent `list`/`status` must never see
# a partially-written .res.
write_local_result() {
  local id="$1" result_json="$2"
  local res_file="$QUEUE_DIR/$id.res" tmp_file
  tmp_file="$(mktemp "$QUEUE_DIR/.${id}.res.XXXXXX")"
  printf '%s\n' "$result_json" > "$tmp_file"
  chmod 600 "$tmp_file"
  mv "$tmp_file" "$res_file"
}

# Triggers the approval itself: ssh to the MacBook (its own dedicated,
# restricted key — see docs/remote-dev.md → *mini → iumac*; no agent
# forwarding, so this borrows no other credential) and run `human-queue.sh
# gui-run` there, piping the request's OWN .req file to it over stdin — never
# as a command-string argument, same reason write_result on the MacBook side
# pipes rather than interpolates. PATH is set explicitly first: a non-login,
# non-interactive ssh command may not see /opt/homebrew/bin.
#
# Exit codes: the command's own exit code on done, 1 on denied, 75 on
# unanswered (dialog timed out, or too long to show — request stays pending,
# unchanged, for `make human-queue`), 69 on an ssh failure or a response this
# script cannot make sense of (also leaves the request pending).
push_request() {
  local id="$1"
  validate_id "$id"
  ensure_queue_dir

  local req_file="$QUEUE_DIR/$id.req"
  local res_file="$QUEUE_DIR/$id.res"
  [[ -f "$req_file" ]] || die "no such request: $id"
  [[ -f "$res_file" ]] && die "request $id already has a result — refusing to push twice"

  # shellcheck disable=SC2016
  local remote_cmd='export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"; bash "$HOME/SourceRoot/dotfiles/scripts/human-queue.sh" gui-run'

  # `|| rc=$?`, never a bare `rc=$?` after the assignment: under `set -e` a failed
  # ssh would end the script right there, with ssh's 255 instead of the documented
  # 69 and the request's state unexplained. Only the LAST line is the result — a
  # login shell on the MacBook may print before the command runs.
  local out rc=0
  # shellcheck disable=SC2029
  out="$(ssh "${PUSH_SSH_OPTS[@]}" "$MAC_HOST" "$remote_cmd" < "$req_file" 2>/dev/null | tail -n 1)" || rc=$?

  if (( rc != 0 )) || [[ -z "$out" ]]; then
    note "push $id: could not reach $MAC_HOST or got no response (ssh rc=$rc) — request stays pending, run 'make human-queue' on the MacBook"
    return 69
  fi

  local resp_id resp_status
  resp_id="$(json_field "$out" id)"
  resp_status="$(json_field "$out" status)"

  if [[ "$resp_id" != "$id" ]]; then
    note "push $id: response id mismatch (got '$resp_id') — ignoring, request stays pending"
    return 69
  fi

  case "$resp_status" in
    done|failed|denied)
      write_local_result "$id" "$out"
      if [[ "$resp_status" == denied ]]; then
        note "push $id: denied on the MacBook"
        return 1
      fi
      local exit_code
      exit_code="$(json_field "$out" exit)"
      if [[ "$exit_code" =~ ^[0-9]+$ ]]; then
        return "$exit_code"
      fi
      return 0
      ;;
    unanswered)
      note "push $id: unanswered ($(json_field "$out" output_tail)) — request stays pending, run 'make human-queue' on the MacBook"
      return 75
      ;;
    *)
      note "push $id: unrecognized response status '$resp_status' — request stays pending"
      return 69
      ;;
  esac
}

cmd_push() {
  local id="${1:-}"
  [[ -n "$id" ]] || die "push requires <id>"
  push_request "$id"
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
  ask-human.sh ask <text> [--cmd <command>] [--wait <seconds>] [--push]
                              Enqueue a request. Prints the request id.
                              --cmd proposes a shell command for the human to
                              review and run on the MacBook (never auto-run).
                              --wait <seconds> polls for a result and exits
                              0/1/2/3 for done/denied/failed/timeout. Default
                              0 = return at once: the median resolution is
                              ~7 days, so polling by default only timed out.
                              --push triggers the approval itself right away:
                              ssh to the MacBook, show a native dialog there,
                              execute on click. Still needs a present human —
                              see push below. Takes precedence over --wait.
  ask-human.sh push <id>      Trigger the dialog for an already-enqueued
                              request. Exits with the command's own exit code
                              on done, 1 on denied, 75 on unanswered (dialog
                              timed out or the command was too long to show —
                              request stays pending), 69 on an ssh failure or
                              an unparseable response (also stays pending).
  ask-human.sh list           List pending requests (no result yet).
  ask-human.sh status <id>    Print a request, and its result if one exists.
  ask-human.sh help           This message.

Queue root: ${XDG_STATE_HOME:-$HOME/.local/state}/human-queue/
Drained from the MacBook by scripts/human-queue.sh (`make human-queue`), or
triggered from here with `--push`/`push <id>` (ssh to $HUMAN_QUEUE_MAC_HOST,
default `iumac`, running `human-queue.sh gui-run` there).
EOF
}

main() {
  local sub="${1:-help}"
  case "$sub" in
    ask) shift; cmd_ask "$@" ;;
    push) shift; cmd_push "$@" ;;
    list) shift; cmd_list "$@" ;;
    status) shift; cmd_status "$@" ;;
    help|-h|--help) usage ;;
    *) die "unknown subcommand: $sub (see: ask-human.sh help)" ;;
  esac
}

main "$@"
