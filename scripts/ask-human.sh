#!/usr/bin/env bash
set -euo pipefail

# ask-human — enqueue present-human work from the mini (or any machine with no
# path back to a human). The mini can `ssh iumac` (dedicated key, see
# ssh_config) for a fixed set of verbs; SSH gives it reach, not a fingerprint. This channel is for what actually still needs a
# *present human*: biometric `op` (`make secrets-seed`), the Tailscale ACL
# push, or any decision only a person can make. Before this, an agent on the
# mini signalled blocked-on-human work by editing prose handover docs, which
# the human might not read for days.
#
# This is the async channel instead: an agent here writes a small request file,
# and a human either drains it on their own schedule (`make human-queue` on the
# MacBook, over the existing MacBook→mini ssh) or this script triggers the
# approval itself — the DEFAULT since 2026-09-15 (owner: "I don't ever want to
# hear again it needs me; execute it yourself, I'm here and can approve"):
# `ask` pushes right away (or `push <id>` for an already-enqueued request) and
# opens `ssh iumac` — the mini's own dedicated key, which runs only fixed
# verbs, see docs/remote-dev.md → *mini → iumac* — and sends the `gui-run`
# verb, which runs `human-queue.sh gui-run` there and shows the exact request in a native
# macOS dialog on the MacBook and only executes on a click. There is still no
# path that skips a present human: the dialog is a second gate next to the
# typed-'yes' TTY gate `run` already requires, not a bypass of it: `gui-run` is
# the human-approved path for anything beyond the key's fixed verbs, one
# request at a time. The result lands back here either way (written
# locally by `push`, or written by `human-queue.sh` over ssh after a manual
# drain) for a waiting agent to pick up. No new credential beyond what already
# exists.
#
# Since 2026-11-13 the factory holds the live list: `ask` first posts the request
# as an Errand (`factory errand request`, source ask-human), which runs its
# `--check` hourly, expires it and lets a newer request with the same key replace
# it; the dialog push is unchanged and its answer closes the Errand. The queue
# file below is the OFFLINE FALLBACK only: written when the factory does not
# answer, and posted to the factory (the file resolved as superseded) by a later
# ask/list/reap once it does. `HUMAN_QUEUE_ERRANDS=0` turns the factory path off.
#
# Queue root: ${XDG_STATE_HOME:-$HOME/.local/state}/human-queue/, mode 700.
# One request is two files: <id>.req (written here) and <id>.res (written by
# human-queue.sh once a human has acted). "Pending" means a .req with no
# matching .res yet.
#
# No `jq` hard dependency (this machine's cache-backend allowlist is narrow and
# must not gain a package requirement for a queue file) — used opportunistically
# when present, hand-rolled JSON otherwise.
#
# Self-cleaning: `ask --key K` supersedes every older pending request with key K,
# a producer's success path calls `clear K`, and every request expires (default 3d
# without a waiter, 14d when FACTORY_SESSION is set; `--expires`). `reap` (also
# run quietly by ask/list/status) writes expired ones off as denied/expired and
# logs them to events.log. A request enqueued under FACTORY_SESSION is reported
# back to that lead once, via `factory session note`, when its result lands.

QUEUE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/human-queue"
ID_RE='^[0-9]{8}T[0-9]{6}-[0-9]+$'
KEY_RE='^[A-Za-z0-9._:/@-]{1,80}$'
DEFAULT_TTL="${HUMAN_QUEUE_DEFAULT_TTL:-3d}"
WAITER_TTL=14d
NOTIFY_MAX_TRIES=5

# The MacBook-side ssh alias `push` targets — see `Host iumac` in
# config/ssh_config (port 2222, IdentityAgent none, no agent forwarding).
# Overridable for the test harness; `local` = this IS the MacBook, run gui-run directly instead of ssh.
MAC_HOST="${HUMAN_QUEUE_MAC_HOST:-iumac}"
# 1 = `ask` pushes the dialog immediately (the default); 0 = enqueue only.
# Tests set 0 so no ask ever opens a real ssh connection.
PUSH_DEFAULT="${HUMAN_QUEUE_PUSH:-1}"
PUSH_SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8)

# The factory CLI (also what notify_sweep calls) and the errand path's switch.
FACTORY_CMD="${HUMAN_QUEUE_FACTORY:-factory}"
ERRANDS_ON="${HUMAN_QUEUE_ERRANDS:-1}"
FACTORY_TO=()
if command -v timeout >/dev/null 2>&1; then FACTORY_TO=(timeout 20)
elif command -v gtimeout >/dev/null 2>&1; then FACTORY_TO=(gtimeout 20); fi
ERRAND_ID_RE='^errand_[A-Za-z0-9-]{1,80}$'

die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
note() { printf '\033[2m%s\033[0m\n' "$*" >&2; }

# json_escape, json_field, printable — shared with human-queue.sh, which
# displays these same fields on the MacBook right before a typed-'yes'
# execution prompt.
# shellcheck source=lib/human-queue-json.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/human-queue-json.sh"

ensure_queue_dir() {
  mkdir -p "$QUEUE_DIR"
  chmod 700 "$QUEUE_DIR"
}

# --- the factory path ------------------------------------------------------
# Exit 7 from factory_call = the factory path is unavailable here (switched off,
# no jq, no CLI) or did not answer: every caller falls back to the queue file.
factory_enabled() {
  [[ "$ERRANDS_ON" != 0 ]] && command -v jq >/dev/null 2>&1 && command -v "$FACTORY_CMD" >/dev/null 2>&1
}

factory_run() { ${FACTORY_TO[@]+"${FACTORY_TO[@]}"} "$FACTORY_CMD" "$@" </dev/null 2>/dev/null; }

# factory <args>: stdout and exit code pass through. A session's agent token may
# not read or close an Errand (exit 3, auth): the owner's click is what closes it
# here, so the call is repeated once with the token cleared and the CLI resolves
# the owner's own.
factory_call() {
  factory_enabled || return 7
  local out rc=0
  out="$(factory_run "$@")" || rc=$?
  if (( rc == 3 )); then
    rc=0
    out="$(FACTORY_TOKEN='' factory_run "$@")" || rc=$?
  fi
  printf '%s' "$out"
  return "$rc"
}

# ISO 8601 UTC time <seconds> from now.
iso_in() { date -u -r "$(( $(date +%s) + $1 ))" +%Y-%m-%dT%H:%M:%SZ; }

# Posts one request as an Errand; prints its id on stdout. $1 text, $2 cmd, $3 key,
# $4 check, $5 expires (ISO, `never` or empty = the factory's rule). Non-zero = fall back.
post_errand() {
  local text="$1" cmd="$2" key="$3" check="$4" expires="$5"
  local args=(errand request --source ask-human --text "$text")
  [[ -n "$cmd" ]] && args+=(--command "$cmd" --where macbook)
  [[ -n "$key" ]] && args+=(--key "$key")
  [[ -n "$check" ]] && args+=(--check "$check")
  [[ -n "$expires" ]] && args+=(--expires "$expires")
  args+=(--format json)
  local out rc=0 id
  out="$(factory_call "${args[@]}")" || rc=$?
  if (( rc != 0 )); then
    (( rc == 7 )) || note "factory errand request failed (rc $rc) — queued locally, a later ask/list/reap posts it"
    return "$rc"
  fi
  id="$(jq -r '.errand.id // empty' <<<"$out" 2>/dev/null)" || id=""
  [[ "$id" =~ $ERRAND_ID_RE ]] || { note "factory answered without an errand id — queued locally"; return 1; }
  printf '%s\n' "$id"
}

# The open ask-human Errands as one JSON array on stdout.
factory_open_json() {
  local out rc=0
  out="$(factory_call errand list --open yes --format json)" || rc=$?
  (( rc == 0 )) || return "$rc"
  jq -c '[.errands[]? | select(.source == "ask-human")]' <<<"$out" 2>/dev/null || return 1
}

# Closes an Errand: $1 id, $2 done|not_needed, $3 note. Never fatal.
close_errand() {
  local id="$1" outcome="$2" note_text="${3:0:500}" args
  args=(errand "done" "$id" --note "$note_text" --format json)
  [[ "$outcome" == not_needed ]] && args+=(--outcome not_needed)
  factory_call "${args[@]}" >/dev/null || { note "could not close $id in the factory — it stays open (its check or expiry ends it)"; return 1; }
}

# The dialog's answer (gui-run's result JSON) closes the Errand it was for.
errand_answer() {
  local errand="$1" status="$2" out="$3" tail_text exit_code
  tail_text="$(json_field "$out" output_tail 2>/dev/null || true)"
  exit_code="$(json_field "$out" exit 2>/dev/null || true)"
  case "$status" in
    denied) close_errand "$errand" not_needed "denied on the MacBook" || true ;;
    failed) close_errand "$errand" "done" "ran on the MacBook and failed (exit ${exit_code:-?}): $tail_text" || true ;;
    *) close_errand "$errand" "done" "answered on the MacBook (exit ${exit_code:-0}): $tail_text" || true ;;
  esac
}

# Posts every queue-file request written while the factory was down (not a
# lead's: that one is told through `factory session note`) and resolves its file
# superseded. Stops at the first failure, so a dead factory costs one call.
replay_pending() {
  factory_enabled || return 0
  [[ -d "$QUEUE_DIR" ]] || return 0
  local f id json session text cmd key expires check eid
  for f in "$QUEUE_DIR"/*.req; do
    [[ -e "$f" ]] || continue
    id="$(basename "$f" .req)"
    [[ -f "$QUEUE_DIR/$id.res" ]] && continue
    json="$(cat "$f")"
    session="$(json_field "$json" session 2>/dev/null || true)"
    [[ -n "$session" ]] && continue
    text="$(json_field "$json" text 2>/dev/null)" || continue
    cmd="$(json_field "$json" cmd 2>/dev/null || true)"
    key="$(json_field "$json" key 2>/dev/null || true)"
    expires="$(json_field "$json" expires 2>/dev/null || true)"
    check="$(json_field "$json" check 2>/dev/null || true)"
    [[ -n "$expires" ]] || expires=never
    eid="$(post_errand "$text" "$cmd" "$key" "$check" "$expires" 2>/dev/null)" || return 0
    resolve_one "$id" superseded "moved to the factory as $eid" 1 || true
  done
  return 0
}

# One request object, the shape of a <id>.req file.
# $1 id $2 text $3 cmd $4 key $5 expires_json $6 session_json $7 check
req_json() {
  local cmd_json="null" key_json="null" check_json="null"
  [[ -n "$3" ]] && cmd_json="$(json_escape "$3")"
  [[ -n "$4" ]] && key_json="$(json_escape "$4")"
  [[ -n "$7" ]] && check_json="$(json_escape "$7")"
  printf '{'
  printf '"id":%s,' "$(json_escape "$1")"
  printf '"created":%s,' "$(json_escape "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
  printf '"host":%s,' "$(json_escape "$(hostname -s 2>/dev/null || hostname)")"
  printf '"cwd":%s,' "$(json_escape "$PWD")"
  printf '"text":%s,' "$(json_escape "$2")"
  printf '"cmd":%s,' "$cmd_json"
  printf '"key":%s,' "$key_json"
  printf '"check":%s,' "$check_json"
  printf '"expires":%s,' "$5"
  printf '"session":%s' "$6"
  printf '}\n'
}

# Waits for a factory-held request: prints the Errand and returns 0 when the
# owner did it, 1 when it closed any other way, 3 on timeout (the id is printed).
poll_errand() {
  local errand="$1" seconds="$2" waited=0 out row
  while (( waited < seconds )); do
    if out="$(factory_call errand list --format json --limit 200)"; then
      row="$(jq -c --arg id "$errand" '[.errands[]? | select(.id == $id)][0] // empty' <<<"$out" 2>/dev/null || true)"
      if [[ -n "$row" && "$(jq -r '.doneAt // empty' <<<"$row")" != "" ]]; then
        printf '%s\n' "$row"
        case "$(jq -r '.closedKind // "done"' <<<"$row")" in done) return 0 ;; *) return 1 ;; esac
      fi
    fi
    sleep 5
    waited=$(( waited + 5 ))
  done
  printf '%s\n' "$errand"
  return 3
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
# passes an explicit budget: `--wait 600`. Pushing is the default: the approval
# dialog opens on the MacBook right after enqueueing (see push_request below),
# and --wait is ignored — push resolves synchronously over one ssh round trip.
# --no-push (or HUMAN_QUEUE_PUSH=0) enqueues only. The notify hook (the ntfy
# "Human needed" message) fires only when the push did not resolve the request —
# MacBook unreachable, dialog unanswered — or pushing was turned off; a request
# the owner clicked through never reaches ntfy. --push is still accepted.
cmd_ask() {
  [[ $# -ge 1 ]] || die "ask requires <text> [--cmd <command>] [--key <key>] [--expires <dur|never>] [--check <sh>] [--wait <seconds>] [--no-push]"
  local text="$1"; shift
  local cmd="" wait_seconds=0 push_after="$PUSH_DEFAULT" key="" expires_arg="" check=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cmd)
        [[ $# -ge 2 ]] || die "--cmd requires a value"
        cmd="$2"
        shift 2
        ;;
      --key)
        [[ $# -ge 2 ]] || die "--key requires a value"
        [[ "$2" =~ $KEY_RE ]] || die "invalid --key: $2 (allowed: A-Za-z0-9._:/@- , 1-80 chars)"
        key="$2"
        shift 2
        ;;
      --expires)
        [[ $# -ge 2 ]] || die "--expires requires a value"
        expires_arg="$2"
        shift 2
        ;;
      --check)
        [[ $# -ge 2 ]] || die "--check requires a value"
        check="$2"
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
      --no-push)
        push_after=0
        shift
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
  done

  # A lead (FACTORY_SESSION) that enqueues without waiting will not come back to
  # collect the answer: the notify sweep tells it. Only a safe-charset session
  # name is recorded (it reaches an argv and json_field).
  local session=""
  if [[ -n "${FACTORY_SESSION:-}" ]] && (( wait_seconds <= 0 )) && [[ "$FACTORY_SESSION" =~ $KEY_RE ]]; then
    session="$FACTORY_SESSION"
  fi

  # Validate the duration before anything is written.
  # An explicit --expires is also what the factory is given; with none it applies
  # its own rule (7 days, or until the --check says otherwise).
  local expires_json="null" ttl_secs factory_expires=""
  if [[ "$expires_arg" != never ]]; then
    local ttl="$DEFAULT_TTL"
    [[ -n "$session" ]] && ttl="$WAITER_TTL"
    [[ -n "$expires_arg" ]] && ttl="$expires_arg"
    ttl_secs="$(parse_dur "$ttl")" || exit 1
    expires_json="$(json_escape "$(iso_in "$ttl_secs")")"
    [[ -n "$expires_arg" ]] && factory_expires="$(iso_in "$ttl_secs")"
  else
    factory_expires=never
  fi

  ensure_queue_dir
  reap_quiet
  replay_pending

  local session_json="null"
  [[ -n "$session" ]] && session_json="$(json_escape "$session")"

  local id
  id="$(date +%Y%m%dT%H%M%S)-$RANDOM"

  # The factory first. A lead's request stays a queue file: its answer reaches the
  # lead as a `factory session note`, which an Errand with no Issue cannot send.
  local errand=""
  if [[ -z "$session" ]] && errand="$(post_errand "$text" "$cmd" "$key" "$check" "$factory_expires")"; then
    printf '%s\n' "$errand"
    if (( push_after )); then
      local fx_tmp frc=0
      fx_tmp="$(mktemp "$QUEUE_DIR/.${id}.fx.XXXXXX")"
      req_json "$id" "$text" "$cmd" "$key" "$expires_json" "$session_json" "$check" > "$fx_tmp"
      chmod 600 "$fx_tmp"
      push_request "$id" "$fx_tmp" "$errand" || frc=$?
      rm -f "$fx_tmp"
      # 75 unanswered / 69 unreachable: the Errand stays open, nudge the phone.
      (( frc == 75 || frc == 69 )) && fire_notify_hook "$errand" "$text"
      return "$frc"
    fi
    fire_notify_hook "$errand" "$text"
    (( wait_seconds > 0 )) && { poll_errand "$errand" "$wait_seconds"; return $?; }
    return 0
  fi

  # temp + mv (chmod on the temp file, before it has the final name) so a
  # concurrent `list` never observes a request file that is both present and
  # world-readable, even for an instant.
  local req_file="$QUEUE_DIR/$id.req" tmp_file
  tmp_file="$(mktemp "$QUEUE_DIR/.${id}.req.XXXXXX")"
  req_json "$id" "$text" "$cmd" "$key" "$expires_json" "$session_json" "$check" > "$tmp_file"
  chmod 600 "$tmp_file"
  mv "$tmp_file" "$req_file"

  if [[ -n "$key" ]]; then
    local old
    while IFS= read -r old; do
      resolve_one "$old" superseded "replaced by $id" 1 || true
    done < <(pending_with_key "$key" "$id")
  fi

  printf '%s\n' "$id"

  if (( push_after )); then
    local rc=0
    # A synchronous answer reaches the caller as the exit code, so the lead needs
    # no note: mark it notified up front (the push's own result write sweeps),
    # and take the marker off again when the request stays pending.
    [[ -n "$session" ]] && : > "$QUEUE_DIR/$id.notified"
    push_request "$id" || rc=$?
    # 75 unanswered / 69 unreachable: still pending, so fall back to the hook.
    if (( rc == 75 || rc == 69 )); then
      rm -f "$QUEUE_DIR/$id.notified"
      fire_notify_hook "$id" "$text"
    fi
    return "$rc"
  fi

  fire_notify_hook "$id" "$text"

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
  rm -f "$QUEUE_DIR/$id.queued"
  notify_sweep || true
}

# Where a still-pending request is answered: the factory's Console for an Errand, the queue otherwise.
pending_where() {
  if [[ -n "$1" ]]; then echo "answer it in the factory Console (Needs you) or push $1 again"; else echo "run 'make human-queue' on the MacBook"; fi
}

# Triggers the approval itself: ssh to the MacBook (its own dedicated key,
# which runs only fixed verbs — see docs/remote-dev.md → *mini → iumac*; no
# agent forwarding, so this borrows no other credential) and send the `gui-run`
# verb, which runs `human-queue.sh gui-run` there, piping the request's OWN .req file to it over stdin — never
# as a command-string argument, same reason write_result on the MacBook side
# pipes rather than interpolates. The gate on the MacBook sets PATH.
#
# Exit codes: the command's own exit code on done, 1 on denied, 75 on
# unanswered (dialog timed out, or too long to show — request stays pending,
# unchanged, for `make human-queue`), 69 on an ssh failure or a response this
# script cannot make sense of (also leaves the request pending), 76 when the
# approved command is still running in a MacBook terminal at its wait (pending,
# the terminal id is on stderr; no result is written).
#
# A factory-held request passes its own temp request file and the Errand id: the
# answer then closes the Errand and no queue file is touched.
push_request() {
  local id="$1" req_file="${2:-}" errand="${3:-}"
  validate_id "$id"
  ensure_queue_dir

  local res_file="$QUEUE_DIR/$id.res"
  [[ -n "$req_file" ]] || req_file="$QUEUE_DIR/$id.req"
  [[ -f "$req_file" ]] || die "no such request: $id"
  [[ -z "$errand" && -f "$res_file" ]] && die "request $id already has a result — refusing to push twice"

  local remote_cmd='gui-run'

  # `|| rc=$?`, never a bare `rc=$?` after the assignment: under `set -e` a failed
  # ssh would end the script right there, with ssh's 255 instead of the documented
  # 69 and the request's state unexplained. Only the LAST line is the result — a
  # login shell on the MacBook may print before the command runs.
  local out rc=0
  if [[ "$MAC_HOST" == local ]]; then
    # Already on the MacBook (the MacBook's own keepalive asking for a re-login): no ssh self-loop, run the same
    # gui-run here. human-queue.sh refuses on the mini, which surfaces below as the usual "no response" (69).
    out="$(bash "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/human-queue.sh" gui-run < "$req_file" 2>/dev/null | tail -n 1)" || rc=$?
  else
    # shellcheck disable=SC2029
    out="$(ssh "${PUSH_SSH_OPTS[@]}" "$MAC_HOST" "$remote_cmd" < "$req_file" 2>/dev/null | tail -n 1)" || rc=$?
  fi

  if (( rc != 0 )) || [[ -z "$out" ]]; then
    note "push $id: could not reach $MAC_HOST or got no response (ssh rc=$rc) — request stays pending, $(pending_where "$errand")"
    # Remembered for `list --json` (state "queued"); cleared when a result lands or a later push reaches the MacBook.
    [[ -n "$errand" ]] || : > "$QUEUE_DIR/$id.queued" 2>/dev/null || true
    return 69
  fi

  local resp_id resp_status
  resp_id="$(json_field "$out" id)"
  resp_status="$(json_field "$out" status)"

  if [[ "$resp_id" != "$id" ]]; then
    note "push $id: response id mismatch (got '$resp_id') — ignoring, request stays pending"
    return 69
  fi

  # The MacBook answered (even "unanswered"), so it is no longer unreachable.
  rm -f "$QUEUE_DIR/$id.queued"

  case "$resp_status" in
    done|failed|denied)
      if [[ -n "$errand" ]]; then errand_answer "$errand" "$resp_status" "$out"; else write_local_result "$id" "$out"; fi
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
    pending)
      # Approved and started, but still running in a MacBook terminal when the wait
      # ended (an interactive prompt such as sudo's Password:). Not a failure and no
      # result yet: the request stays open, and a second push would run it again.
      note "push $id: still running in MacBook terminal $(json_field "$out" terminal) — finish it there (hc read/wait $(json_field "$out" terminal)); output so far: $(json_field "$out" output_tail)"
      return 76
      ;;
    unanswered)
      note "push $id: unanswered ($(json_field "$out" output_tail)) — request stays pending, $(pending_where "$errand")"
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
  if [[ "$id" =~ $ERRAND_ID_RE ]]; then
    # A factory-held request: build the request file from the Errand and push that.
    local open row tmp rc=0 lid
    open="$(factory_open_json)" || die "the factory did not answer — cannot look up $id"
    row="$(jq -c --arg id "$id" '[.[] | select(.id == $id)][0] // empty' <<<"$open")"
    [[ -n "$row" ]] || die "no open request: $id"
    ensure_queue_dir
    lid="$(date +%Y%m%dT%H%M%S)-$RANDOM"
    tmp="$(mktemp "$QUEUE_DIR/.${lid}.fx.XXXXXX")"
    req_json "$lid" "$(jq -r '.summary' <<<"$row")" "$(jq -r '.command // empty' <<<"$row")" \
      "$(jq -r '.requestKey // empty' <<<"$row")" null null "" > "$tmp"
    chmod 600 "$tmp"
    push_request "$lid" "$tmp" "$id" || rc=$?
    rm -f "$tmp"
    return "$rc"
  fi
  push_request "$id"
}

# Epoch seconds of an ISO 8601 UTC timestamp (BSD date, like the stat -f below); empty on a malformed one.
iso_to_epoch() {
  date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null || true
}

# One JSON array on stdout, every request with no result yet. All-or-nothing:
# the array is assembled first, so a request json_field cannot read (no jq and
# an escape sequence in the text) fails the command instead of dropping a row.
# askedAt is the request's own `created`; ageSeconds counts from it (the file's
# mtime stands in when `created` is missing or malformed). state is "queued"
# once a push found the MacBook unreachable (the .queued marker, dropped when
# any later push reaches it), else "pending"; consumers ignore unknown states.
# [] is an empty queue; a non-zero exit with empty stdout is a read failure.
# BSD date/stat only (macOS), like the rest of this script.
cmd_list_json() {
  ensure_queue_dir
  reap_quiet
  replay_pending
  local f now rows="" sep=""
  now="$(date +%s)"
  for f in "$QUEUE_DIR"/*.req; do
    [[ -e "$f" ]] || continue
    local id
    id="$(basename "$f" .req)"
    [[ -f "$QUEUE_DIR/$id.res" ]] && continue
    local json text cmd_value created asked_epoch asked_at age state cmd_json="null"
    local key_value expires_value key_json="null" expires_json="null"
    json="$(cat "$f")"
    text="$(json_field "$json" text)" || return 1
    key_value="$(json_field "$json" key)" || return 1
    expires_value="$(json_field "$json" expires)" || return 1
    [[ -n "$key_value" ]] && key_json="$(json_escape "$key_value")"
    [[ -n "$expires_value" ]] && expires_json="$(json_escape "$expires_value")"
    cmd_value="$(json_field "$json" cmd)" || return 1
    created="$(json_field "$json" created)" || return 1
    asked_epoch="$(iso_to_epoch "$created")"
    if [[ -n "$asked_epoch" ]]; then
      asked_at="$created"
    else
      asked_epoch="$(stat -f %m "$f" 2>/dev/null || echo "$now")"
      asked_at="$(date -u -r "$asked_epoch" +%Y-%m-%dT%H:%M:%SZ)"
    fi
    age=$(( now - asked_epoch ))
    (( age < 0 )) && age=0
    state=pending
    [[ -e "$QUEUE_DIR/$id.queued" ]] && state=queued
    [[ -n "$cmd_value" ]] && cmd_json="$(json_escape "$cmd_value")"
    rows+="$sep{\"id\":$(json_escape "$id"),\"text\":$(json_escape "$text"),\"cmd\":$cmd_json,\"askedAt\":$(json_escape "$asked_at"),\"ageSeconds\":$age,\"state\":\"$state\",\"key\":$key_json,\"expires\":$expires_json}"
    sep=","
  done
  notify_sweep || true
  local local_json="[$rows]" open
  if open="$(factory_open_json 2>/dev/null)"; then
    jq -c --argjson now "$now" --argjson local "$local_json" '
      (map({id, text: .summary, cmd: .command, askedAt: .raisedAt,
            ageSeconds: ([0, ($now - (.raisedAt | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601))] | max),
            state: "pending", key: .requestKey, expires: .expiresAt,
            host, checkNote, where: "factory"})) + $local' <<<"$open"
  else
    printf '%s\n' "$local_json"
  fi
}

cmd_list() {
  local as_json=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) as_json=1; shift ;;
      *) note "error: unknown argument to list: $1 (usage: ask-human.sh list [--json])"; exit 2 ;;
    esac
  done
  if (( as_json )); then
    cmd_list_json
    return
  fi
  ensure_queue_dir
  reap_quiet
  replay_pending
  local f found=0 open frow
  if open="$(factory_open_json 2>/dev/null)"; then
    while IFS= read -r frow; do
      [[ -n "$frow" ]] || continue
      found=1
      local fcmd
      fcmd=""; [[ -n "$(jq -r '.command // empty' <<<"$frow")" ]] && fcmd="[cmd]"
      printf '%s\t%s\t%-60s\t%s\n' "$(jq -r .id <<<"$frow")" \
        "$(format_age "$(( $(date +%s) - $(jq -r '.raisedAt | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601' <<<"$frow") ))")" \
        "$(printable "$(jq -r '.summary' <<<"$frow")" | cut -c1-60)" "$fcmd"
    done < <(jq -c '.[]' <<<"$open")
  fi
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
  if [[ "$id" =~ $ERRAND_ID_RE ]]; then
    local all row
    all="$(factory_call errand list --format json --limit 200)" || die "the factory did not answer"
    row="$(jq -c --arg id "$id" '[.errands[]? | select(.id == $id)][0] // empty' <<<"$all")"
    [[ -n "$row" ]] || die "no such request: $id"
    printf '%s\n' "$row"
    return 0
  fi
  ensure_queue_dir
  reap_quiet
  local req="$QUEUE_DIR/$id.req"
  local res="$QUEUE_DIR/$id.res"
  [[ -f "$req" ]] || die "no such request: $id"
  cat "$req"
  [[ -f "$res" ]] && cat "$res"
  return 0
}

# The owner's answer to a request without the MacBook (the factory's fleet view
# calls this; dotfiles stays the queue's only writer). Writes <id>.res the way a
# real answer is written (temp, chmod, then publish) but NEVER runs the request's
# command. `done` = satisfied by other means, status done / exit 0. `denied` and
# `superseded` both read as "not run": status denied, so a waiting `ask --wait`
# caller gets the refused-request code (1) and human-queue.sh/push read it like
# a dialog Deny; resolvedAs keeps which of the two it was. Publishing uses a
# hard link, which fails when <id>.res exists, so two racing resolves cannot
# both win. A real answer (write_local_result, human-queue.sh) still overwrites
# silently: an owner who clicks Run while a resolve lands can have the command
# run and replace the resolve's result. Exit 2 with one line on any refusal.
cmd_resolve() {
  local id="" as="" note_text="" have_note=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --as)
        [[ $# -ge 2 ]] || { note "error: --as requires done|denied|superseded"; exit 2; }
        as="$2"; shift 2 ;;
      --note)
        [[ $# -ge 2 ]] || { note "error: --note requires a value"; exit 2; }
        note_text="$2"; have_note=1; shift 2 ;;
      --*) note "error: unknown argument to resolve: $1"; exit 2 ;;
      *)
        [[ -z "$id" ]] || { note "error: resolve takes one <id> (got extra: $1)"; exit 2; }
        id="$1"; shift ;;
    esac
  done
  [[ -n "$id" ]] || { note "error: resolve requires <id> --as done|denied|superseded [--note <text>]"; exit 2; }
  case "$as" in
    done|denied|superseded) ;;
    *) note "error: resolve requires --as done|denied|superseded"; exit 2 ;;
  esac
  if [[ "$id" =~ $ERRAND_ID_RE ]]; then
    local outcome="done"
    [[ "$as" == "done" ]] || outcome=not_needed
    [[ -n "$note_text" ]] || note_text="resolved as $as by ask-human resolve"
    close_errand "$id" "$outcome" "$note_text" || { note "error: could not close $id in the factory"; exit 2; }
    printf 'resolved %s as %s\n' "$id" "$as"
    return 0
  fi
  [[ "$id" =~ $ID_RE ]] || { note "error: invalid request id: $id"; exit 2; }

  ensure_queue_dir
  [[ -f "$QUEUE_DIR/$id.req" ]] || { note "error: no such request: $id"; exit 2; }
  [[ -f "$QUEUE_DIR/$id.res" ]] && { note "error: request $id already has a result"; exit 2; }

  resolve_one "$id" "$as" "$note_text" "$have_note" || { note "error: request $id already has a result"; exit 2; }
  printf 'resolved %s as %s\n' "$id" "$as"
}

# Writes <id>.res without running anything. as = done|denied|superseded|expired.
# Returns 1 (silently) when the result already exists — the hard-link publish
# fails then, so racing resolvers cannot both win. Per-call temp, removed here:
# an EXIT trap would be clobbered when this runs in a loop.
resolve_one() {
  local id="$1" as="$2" note_text="${3:-}" have_note="${4:-0}"
  local status="done" exit_json="0" tail_text="resolved as done without running the command"
  if [[ "$as" != "done" ]]; then
    status="denied"
    exit_json="null"
    tail_text="resolved as $as, the command was not run"
  fi
  local note_json="null"
  (( have_note )) && note_json="$(json_escape "$note_text")"

  local res_file="$QUEUE_DIR/$id.res" tmp
  tmp="$(mktemp "$QUEUE_DIR/.${id}.res.XXXXXX")"
  {
    printf '{'
    printf '"id":%s,' "$(json_escape "$id")"
    printf '"status":"%s",' "$status"
    printf '"exit":%s,' "$exit_json"
    printf '"ran_at":%s,' "$(json_escape "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
    printf '"output_tail":%s,' "$(json_escape "$tail_text")"
    printf '"resolvedAs":"%s",' "$as"
    printf '"resolvedNote":%s' "$note_json"
    printf '}\n'
  } > "$tmp"
  chmod 600 "$tmp"
  if ! ln "$tmp" "$res_file" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  rm -f "$tmp" "$QUEUE_DIR/$id.queued"
  notify_sweep || true
  return 0
}

# Seconds from "90", "90s", "5m", "2h", "3d" on stdout; dies on anything else.
parse_dur() {
  local s="$1" n unit
  [[ "$s" =~ ^([0-9]+)([smhd]?)$ ]] || die "invalid duration: $s (seconds, Ns/Nm/Nh/Nd, or never)"
  n="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[2]}"
  case "$unit" in
    m) echo $(( n * 60 )) ;;
    h) echo $(( n * 3600 )) ;;
    d) echo $(( n * 86400 )) ;;
    *) echo "$n" ;;
  esac
}

# Ids of pending requests carrying <key>, optionally skipping one id.
pending_with_key() {
  local key="$1" skip="${2:-}" f id
  for f in "$QUEUE_DIR"/*.req; do
    [[ -e "$f" ]] || continue
    id="$(basename "$f" .req)"
    [[ "$id" == "$skip" || -f "$QUEUE_DIR/$id.res" ]] && continue
    [[ "$(json_field "$(cat "$f")" key 2>/dev/null || true)" == "$key" ]] && printf '%s\n' "$id"
  done
  return 0
}

# A producer's success path: resolve everything it still has pending. Idempotent.
cmd_clear() {
  local key="" as="done" note_text="cleared by a later success of the same producer"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --as)
        [[ $# -ge 2 ]] || { note "error: --as requires done|superseded"; exit 2; }
        as="$2"; shift 2 ;;
      --note)
        [[ $# -ge 2 ]] || { note "error: --note requires a value"; exit 2; }
        note_text="$2"; shift 2 ;;
      --*) note "error: unknown argument to clear: $1"; exit 2 ;;
      *)
        [[ -z "$key" ]] || { note "error: clear takes one <key> (got extra: $1)"; exit 2; }
        key="$1"; shift ;;
    esac
  done
  [[ -n "$key" ]] || { note "error: clear requires <key> [--as done|superseded] [--note <text>]"; exit 2; }
  [[ "$key" =~ $KEY_RE ]] || { note "error: invalid key: $key"; exit 2; }
  case "$as" in
    done|superseded) ;;
    *) note "error: clear --as takes done|superseded"; exit 2 ;;
  esac
  ensure_queue_dir
  local id n=0 open
  # The factory's open request with this key first (a producer's success path).
  if open="$(factory_open_json 2>/dev/null)"; then
    while IFS= read -r id; do
      [[ "$id" =~ $ERRAND_ID_RE ]] || continue
      close_errand "$id" not_needed "cleared by its producer" && n=$(( n + 1 ))
    done < <(jq -r --arg k "$key" '.[] | select(.requestKey == $k) | .id' <<<"$open")
  fi
  while IFS= read -r id; do
    resolve_one "$id" "$as" "$note_text" 1 && n=$(( n + 1 ))
  done < <(pending_with_key "$key")
  printf 'cleared %d\n' "$n"
}

# Writes off every pending request whose "expires" is past: denied/expired, the
# command never runs, one line each to events.log and stdout. Idempotent (the
# hard-link publish lets only one reaper win).
reap_expired() {
  [[ -d "$QUEUE_DIR" ]] || return 0
  local f id expires epoch now text key line
  now="$(date +%s)"
  for f in "$QUEUE_DIR"/*.req; do
    [[ -e "$f" ]] || continue
    id="$(basename "$f" .req)"
    [[ -f "$QUEUE_DIR/$id.res" ]] && continue
    local json
    json="$(cat "$f")"
    expires="$(json_field "$json" expires 2>/dev/null || true)"
    [[ -n "$expires" ]] || continue
    epoch="$(iso_to_epoch "$expires")"
    [[ -n "$epoch" ]] && (( epoch <= now )) || continue
    resolve_one "$id" expired "expired $expires" 1 || continue
    text="$(printable "$(json_field "$json" text 2>/dev/null || true)" | tr '\n\t' '  ')"
    key="$(json_field "$json" key 2>/dev/null || true)"
    line="$(date -u +%Y-%m-%dT%H:%M:%SZ) expired $id ${key:--} ${text:0:80}"
    printf '%s\n' "$line" >> "$QUEUE_DIR/events.log"
    printf '%s\n' "$line"
  done
  return 0
}

reap_quiet() { ( reap_expired ) >/dev/null 2>&1 || true; }

cmd_reap() {
  ensure_queue_dir
  reap_expired
  replay_pending
  notify_sweep || true
}

# Tells the lead (FACTORY_SESSION at enqueue) once that its request resolved.
# Recent results only; a <id>.notified marker ends it, a failing note is retried
# on later sweeps and given up after NOTIFY_MAX_TRIES. Never fails or blocks the
# caller: bounded by timeout, every error swallowed.
notify_sweep() {
  [[ -d "$QUEUE_DIR" ]] || return 0
  local factory="$FACTORY_CMD" to=() res id req_json session res_json
  local text status as note_text msg tries
  if command -v timeout >/dev/null 2>&1; then to=(timeout 15)
  elif command -v gtimeout >/dev/null 2>&1; then to=(gtimeout 15); fi
  while IFS= read -r res; do
    id="$(basename "$res" .res)"
    [[ "$id" =~ $ID_RE ]] || continue
    [[ -e "$QUEUE_DIR/$id.notified" ]] && continue
    req_json="$(cat "$QUEUE_DIR/$id.req" 2>/dev/null)" || continue
    session="$(json_field "$req_json" session 2>/dev/null)" || continue
    [[ -n "$session" ]] || continue
    res_json="$(cat "$res" 2>/dev/null)" || continue
    text="$(printable "$(json_field "$req_json" text 2>/dev/null || true)" | tr '\n\t' '  ')"
    status="$(json_field "$res_json" status 2>/dev/null || true)"
    as="$(json_field "$res_json" resolvedAs 2>/dev/null || true)"
    note_text="$(json_field "$res_json" resolvedNote 2>/dev/null || true)"
    msg="human queue: \"${text:0:80}\" was $status (${as:-$status})"
    [[ -n "$note_text" ]] && msg+=" - $(printable "$note_text" | tr '\n\t' '  ')"
    if ${to[@]+"${to[@]}"} "$factory" session note "$session" "$msg" --id "ask-human-$id" </dev/null >/dev/null 2>&1; then
      : > "$QUEUE_DIR/$id.notified"
      continue
    fi
    tries="$(cat "$QUEUE_DIR/$id.notify-tries" 2>/dev/null || echo 0)"
    [[ "$tries" =~ ^[0-9]+$ ]] || tries=0
    tries=$(( tries + 1 ))
    printf '%d\n' "$tries" > "$QUEUE_DIR/$id.notify-tries"
    (( tries >= NOTIFY_MAX_TRIES )) && : > "$QUEUE_DIR/$id.notified"
  done < <(find "$QUEUE_DIR" -maxdepth 1 -name '*.res' -mtime -2 2>/dev/null)
  return 0
}

usage() {
  cat <<'EOF'
ask-human.sh — enqueue present-human work from the mini (or any machine)

The factory holds the live list: `ask` posts an Errand (`factory errand request`)
and prints its id (errand_…); the queue file is the offline fallback, posted to
the factory by a later ask/list/reap once it answers. list/status/resolve/clear/
push take an errand id as well as a queue id. HUMAN_QUEUE_ERRANDS=0 = queue file only.

Usage:
  ask-human.sh ask <text> [--cmd <command>] [--key <key>] [--expires <dur|never>]
                          [--check <sh>] [--wait <seconds>] [--no-push]
                              Enqueue a request. Prints the request id.
                              --key replaces: older pending requests with the same
                              key are resolved as superseded. --expires <dur>
                              (seconds, Ns/Nm/Nh/Nd, never) sets when it is
                              written off; default 3d ($HUMAN_QUEUE_DEFAULT_TTL),
                              14d when FACTORY_SESSION is set (that lead is told
                              of the result via `factory session note`).
                              --check <sh> (factory only): a read-only command that
                              exits 0 while the request is still needed; the
                              factory runs it hourly and closes the request when
                              it exits 1..125.
                              --cmd proposes a shell command for the human to
                              review and run on the MacBook (never auto-run).
                              --wait <seconds> polls for a result and exits
                              0/1/2/3 for done/denied/failed/timeout. Default
                              0 = return at once: the median resolution is
                              ~7 days, so polling by default only timed out.
                              By default the approval is pushed right away:
                              ssh to the MacBook, show a native dialog there,
                              execute on click (overrides --wait). Only an
                              unreachable MacBook or an unanswered dialog
                              falls back to the notify hook and the queue.
                              --no-push (or HUMAN_QUEUE_PUSH=0) enqueues only.
  ask-human.sh push <id>      Trigger the dialog for an already-enqueued
                              request. Exits with the command's own exit code
                              on done, 1 on denied, 75 on unanswered (dialog
                              timed out or the command was too long to show —
                              request stays pending), 69 on an ssh failure or
                              an unparseable response (also stays pending), 76 when the
                              approved command was still running in a MacBook
                              terminal (e.g. at sudo's Password:) when the wait
                              ended: pending with the terminal id, not failed.
  ask-human.sh list [--json]  List pending requests (no result yet). --json: one
                              array on stdout of {id, text, cmd, askedAt,
                              ageSeconds, state}; state is "pending", or
                              "queued" once a push found the MacBook
                              unreachable. An unknown flag exits 2.
  ask-human.sh status <id>    Print a request, and its result if one exists
                              (a resolved one carries resolvedAs/resolvedNote).
  ask-human.sh resolve <id> --as done|denied|superseded [--note <text>]
                              The owner's answer without the MacBook. Writes the
                              result; NEVER runs the request's command. done =
                              satisfied by other means (exit 0); denied and
                              superseded read as "not run" (a waiting caller
                              exits 1, like a dialog Deny). Exit 2 and one line
                              when the id is unknown or already has a result.
  ask-human.sh clear <key> [--as done|superseded] [--note <text>]
                              A producer's success path: resolve every pending
                              request with that key (default done). Always exit 0;
                              prints `cleared N`.
  ask-human.sh reap           Write off expired requests (denied, resolvedAs
                              expired; the command never runs), log them to
                              events.log, and send due factory notes. ask, list and
                              status do the write-off quietly.
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
    resolve) shift; cmd_resolve "$@" ;;
    clear) shift; cmd_clear "$@" ;;
    reap) shift; cmd_reap "$@" ;;
    help|-h|--help) usage ;;
    *) die "unknown subcommand: $sub (see: ask-human.sh help)" ;;
  esac
}

main "$@"
