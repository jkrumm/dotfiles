#!/usr/bin/env bash
set -euo pipefail

# human-queue — MacBook-side drain of the async present-human queue an agent on
# the mini writes with `ask-human.sh`. The mini can now `ssh iumac` (a
# dedicated, restricted key — see ssh_config), so a network path back exists;
# that is not what this queue is for. SSH gives the mini reach, not a
# fingerprint — this is for work that needs a *present human*: biometric `op`
# (`make secrets-seed`), the Tailscale ACL push, or any decision only a person
# can make, none of which an agent on the mini can do for itself no matter how
# much reach it has. Everything here rides the existing MacBook→mini ssh hop
# (`ControlMaster`'d `Host mini`); no new credential, no inbound door opened on
# the MacBook.
#
# The important property is in `run`: the mini only ever *proposes* a command
# string. This script prints it (control bytes stripped for display, see
# print_req/printable — a raw ESC must never be able to make the terminal show
# something other than what would run), requires a typed 'yes' on a real TTY,
# and only then executes the UNMODIFIED string locally with the human's full
# privileges. A compromised or misbehaving mini therefore gets a string in
# front of a human, never a shell — there is no non-interactive path to `run`
# at all.
#
# No LaunchAgent drains this automatically, and that is deliberate, not an
# oversight: the machine reaching the mini is the human's own MacBook, and the
# 1Password SSH agent behind that ssh hop is per-use biometric — a poller would
# mean a Touch ID prompt firing on its own schedule, unattended, forever.
# Draining is something the human does (`make human-queue`), not something that
# runs.

HOST="${HUMAN_QUEUE_HOST:-mini}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8)

# Same literal text on both ends of the ssh hop — this variable is never
# expanded LOCALLY (assigned single-quoted), only ever handed to the remote
# shell inside a command string, where $XDG_STATE_HOME/$HOME are the mini's.
# shellcheck disable=SC2016
REMOTE_QUEUE_DIR='${XDG_STATE_HOME:-$HOME/.local/state}/human-queue'

die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# Same "am I the dev host" signal remote-dev.sh, git-headless and herdr-setup
# already key off — one definition, so this script cannot silently disagree
# with them about which machine it is running on.
on_dev_host() {
  [[ "$(cat "${XDG_CONFIG_HOME:-$HOME/.config}/secrets/backend" 2>/dev/null)" == "cache" ]]
}

if on_dev_host; then
  echo "human-queue.sh is the MacBook (present-human) side — this machine is the mini." >&2
  echo "Use ask-human.sh directly here instead: bash scripts/ask-human.sh ask \"…\" [--cmd …] [--wait]" >&2
  exit 1
fi

# A request id is always <date>T<time>-<RANDOM> from ask-human.sh. Every
# subcommand that embeds $id into a remote command STRING (not piped as data)
# validates it first — the id otherwise flows unescaped into a string that a
# remote shell parses, and a request id is attacker-influenced input (it names
# whatever an agent on the mini chose to enqueue).
validate_id() {
  [[ "$1" =~ ^[0-9]{8}T[0-9]{6}-[0-9]+$ ]] || die "invalid request id: $1"
}

# json_escape, json_field, printable — shared with ask-human.sh. Both scripts
# hold a full `dotfiles` checkout regardless of which machine they run on, so
# there is nothing stopping either from sourcing the other's helpers.
# shellcheck source=lib/human-queue-json.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/human-queue-json.sh"

# One-off remote scan for pending requests (a .req with no matching .res).
# Deliberately not layered on ask-human.sh's own `list` text output — a stable
# machine-readable count must not depend on that format never changing. The
# `$dir`/`$f`/`$id` references below are single-quoted on purpose: they are
# meant for the REMOTE shell to expand, once `%s` has substituted the queue
# path (still containing its own literal $XDG_STATE_HOME/$HOME) into it.
# shellcheck disable=SC2016
remote_count_script() {
  printf 'dir="%s"; n=0; if [ -d "$dir" ]; then for f in "$dir"/*.req; do [ -e "$f" ] || continue; id=$(basename "$f" .req); [ -f "$dir/$id.res" ] || n=$((n + 1)); done; fi; echo "$n"' \
    "$REMOTE_QUEUE_DIR"
}

# SC2029 (client-side expansion of the remote command): the intent, exactly
# like remote-dev.sh's host_run — `$dir`/`$HOME`/etc inside the built command
# strings below must expand on the MINI, not here, since they name the mini's
# paths.
cmd_count() {
  local script n
  script="bash -c '$(remote_count_script)'"
  # shellcheck disable=SC2029
  n=$(ssh "${SSH_OPTS[@]}" "$HOST" "$script" 2>/dev/null) || n=""
  case "$n" in
    ''|*[!0-9]*) echo 0 ;;
    *) echo "$n" ;;
  esac
  return 0
}

cmd_list() {
  local remote_cmd="bash \"\$HOME/SourceRoot/dotfiles/scripts/ask-human.sh\" list"
  # shellcheck disable=SC2029
  ssh "${SSH_OPTS[@]}" "$HOST" "$remote_cmd" \
    || die "could not reach $HOST to list the queue"
}

fetch_req() {
  local id="$1"
  validate_id "$id"
  # `|| true` remotely: a missing .req makes `cat` exit 1, which without this
  # is indistinguishable from ssh itself failing to reach $HOST — the two
  # failure modes need to report differently below (connection vs no-such-id).
  local remote_cmd="cat \"$REMOTE_QUEUE_DIR/$id.req\" 2>/dev/null || true"
  local out
  # shellcheck disable=SC2029
  out=$(ssh "${SSH_OPTS[@]}" "$HOST" "$remote_cmd") || die "could not reach $HOST"
  [[ -n "$out" ]] || die "no such request on $HOST: $id"
  printf '%s' "$out"
}

# Every field below was written on the mini — the design's own stated
# adversary — so everything DISPLAYED here is routed through printable()
# first (see its comment in lib/human-queue-json.sh for why: an unstripped
# ESC byte could otherwise render an ANSI/OSC sequence that makes the shown
# command differ from what cmd_run actually executes). `created` is excluded
# on purpose — it's a `date -u` timestamp ask-human.sh generates itself, not
# attacker-supplied text. The value that EXECUTES (cmd_run's own `cmd_value`
# read) must never come from here — this function only ever prints.
print_req() {
  local req_json="$1"
  local id text host cwd created cmd_value
  id="$(json_field "$req_json" id)"
  text="$(json_field "$req_json" text)"
  host="$(json_field "$req_json" host)"
  cwd="$(json_field "$req_json" cwd)"
  created="$(json_field "$req_json" created)"
  cmd_value="$(json_field "$req_json" cmd)"

  local id_disp text_disp host_disp cwd_disp cmd_disp
  id_disp="$(printable "$id")"
  text_disp="$(printable "$text")"
  host_disp="$(printable "$host")"
  cwd_disp="$(printable "$cwd")"
  cmd_disp="$(printable "$cmd_value")"

  echo ""
  echo "  request $id_disp"
  echo "  from:    $host_disp  ($cwd_disp)"
  echo "  created: $created"
  echo "  text:    $text_disp"
  if [[ -n "$cmd_value" ]]; then
    echo ""
    if [[ "$cmd_disp" != "$cmd_value" ]]; then
      echo "  !! WARNING: this command contains control characters (e.g. a raw ESC) —"
      echo "  !! they have been stripped for display below. What you see here is NOT"
      echo "  !! what would execute: the raw bytes are what cmd_run actually runs."
    fi
    echo "  ---- proposed command, authored by an agent on the mini ----"
    echo "$cmd_disp"
    echo "  --------------------------------------------------------------"
  else
    echo "  cmd:     (none — informational request)"
  fi
  echo ""
}

cmd_show() {
  local id="${1:-}"
  [[ -n "$id" ]] || die "show requires <id>"
  # Plain assignment, not `print_req "$(fetch_req …)"` — a die() inside
  # fetch_req only exits ITS subshell, and `set -e` does not inspect a command
  # substitution used inline as an argument, so that shape would silently
  # print an empty request instead of aborting. Assigned first, `set -e` does
  # catch a failing right-hand side here.
  local req_json
  req_json="$(fetch_req "$id")"
  print_req "$req_json"
}

# Pipes the JSON body to `ssh … 'cat > …'` over stdin — content never touches
# the remote command STRING, which is the whole point: a request's own
# output_tail can contain arbitrary bytes from a command an agent proposed, and
# interpolating that into a shell command line the remote has to parse would
# reopen exactly the injection risk `validate_id` exists to close for ids.
write_result() {
  local id="$1" status="$2" exit_code="$3" ran_at="$4" output_tail="$5"
  validate_id "$id"
  local exit_json="null"
  [[ -n "$exit_code" ]] && exit_json="$exit_code"
  local payload
  payload=$(
    printf '{'
    printf '"id":%s,' "$(json_escape "$id")"
    printf '"status":%s,' "$(json_escape "$status")"
    printf '"exit":%s,' "$exit_json"
    printf '"ran_at":%s,' "$(json_escape "$ran_at")"
    printf '"output_tail":%s' "$(json_escape "$output_tail")"
    printf '}\n'
  )
  local remote_cmd="cat > \"$REMOTE_QUEUE_DIR/$id.res\" && chmod 600 \"$REMOTE_QUEUE_DIR/$id.res\""
  # shellcheck disable=SC2029
  printf '%s' "$payload" | ssh "${SSH_OPTS[@]}" "$HOST" "$remote_cmd" \
    || die "could not write the result back to $HOST — the mini will keep waiting on $id"
}

cmd_run() {
  local id="${1:-}"
  [[ -n "$id" ]] || die "run requires <id>"
  validate_id "$id"

  [[ -t 0 ]] || die "run requires an interactive terminal — refusing (there is no non-interactive path to executing a request)"

  local req_json
  req_json="$(fetch_req "$id")"
  print_req "$req_json"

  local cmd_value
  cmd_value="$(json_field "$req_json" cmd)"

  echo "  WARNING: if you confirm, this runs on THIS machine (the MacBook) with your"
  echo "  full privileges — your unlocked 1Password session, your keychain, everything"
  echo "  you can reach. It was authored by an agent on the mini, not by you."
  echo ""

  local reply=""
  read -r -p "  type 'yes' to proceed, anything else aborts: " reply
  if [[ "$reply" != "yes" ]]; then
    echo "  aborted — no side effects, no result written."
    exit 0
  fi

  local ran_at status exit_code output_tail
  ran_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if [[ -z "$cmd_value" ]]; then
    # Informational request: confirming IS the action. Nothing executes.
    status="done"
    exit_code=0
    output_tail=""
  else
    local tmp_out
    tmp_out="$(mktemp)"
    set +e
    bash -c "$cmd_value" 2>&1 | tee "$tmp_out"
    exit_code=${PIPESTATUS[0]}
    set -e
    [[ $exit_code -eq 0 ]] && status="done" || status="failed"
    output_tail="$(tail -c 2000 "$tmp_out")"
    rm -f "$tmp_out"
  fi

  write_result "$id" "$status" "$exit_code" "$ran_at" "$output_tail"
  echo ""
  echo "  ✓ result written back to $HOST: $status (exit $exit_code)"
}

cmd_deny() {
  local id="${1:-}"
  [[ -n "$id" ]] || die "deny requires <id> [reason]"
  shift
  local reason="$*"
  [[ -n "$reason" ]] || reason="denied by human, no reason given"
  validate_id "$id"

  local ran_at
  ran_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  write_result "$id" "denied" "" "$ran_at" "$reason"
  echo "  ✓ $id marked denied: $reason"
}

usage() {
  cat <<'EOF'
human-queue.sh — MacBook-side drain of the mini's present-human request queue

Usage:
  human-queue.sh count          Number of pending requests (fast; 0 on any failure)
  human-queue.sh list           List pending requests (table-ish, newest last)
  human-queue.sh show <id>      Print one request in full, including any proposed cmd
  human-queue.sh run <id>       Review + confirm ('yes') + execute a request's cmd
  human-queue.sh deny <id> [reason]   Deny a request; writes a denied result back
  human-queue.sh help           This message.

Reaches the mini over `ssh mini` (BatchMode, 8s connect timeout). `run` is
never non-interactive: it refuses without a TTY and requires a typed 'yes'.
See docs/remote-dev.md for the full model.
EOF
}

main() {
  local sub="${1:-help}"
  case "$sub" in
    count) cmd_count ;;
    list) cmd_list ;;
    show) shift; cmd_show "$@" ;;
    run) shift; cmd_run "$@" ;;
    deny) shift; cmd_deny "$@" ;;
    help|-h|--help) usage ;;
    *) die "unknown subcommand: $sub (see: human-queue.sh help)" ;;
  esac
}

main "$@"
