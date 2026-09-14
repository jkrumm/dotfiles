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
# The important property is in `run` (and now `gui-run`, below): the mini only
# ever *proposes* a command string. This script prints it — or, for `gui-run`,
# shows it in a native dialog (control bytes stripped for display either way,
# see print_req/printable — a raw ESC must never be able to make the shown text
# differ from what would run) — and requires an explicit human act before
# anything executes: a typed 'yes' on a real TTY for `run`, or a clicked "Run"
# button in that dialog for `gui-run`. Only then does it execute the UNMODIFIED
# string locally with the human's full privileges. There is no path that skips
# the human: a compromised or misbehaving mini can put a string in front of a
# human, never open a shell on its own. The dialog is a second gate next to the
# typed-yes TTY gate, not a bypass of it — it exists because the ssh key the
# mini already holds (`~/.ssh/id_ed25519_iumac`, see docs/remote-dev.md → *mini
# → iumac*) already lets it run arbitrary commands non-interactively on this
# machine; `gui-run` is what turns that reach into something a present human
# still has to approve, one request at a time, by reading the exact string.
#
# No LaunchAgent drains this automatically, and that is deliberate, not an
# oversight: the machine reaching the mini is the human's own MacBook, and the
# 1Password SSH agent behind that ssh hop is per-use biometric — a poller would
# mean a Touch ID prompt firing on its own schedule, unattended, forever.
# Draining is something the human does (`make human-queue`) or triggers
# (`ask-human.sh ask … --push` from the mini, landing as a dialog here), not
# something that runs unattended.

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

# "Is a real human at a terminal here?" — deliberately NOT plain `[ -t 0 ]`.
# The interactive walk reads its request ids from stdin (a here-string), so
# inside it stdin is legitimately not a tty while a controlling terminal very
# much exists; every prompt reads from /dev/tty for exactly that reason. A
# launchd/cron/ssh-batch context has no controlling terminal at all, so the
# open fails and `run` stays unreachable — the property that matters. A
# backgrounded shell that still has one gets SIGTTIN on the read and stops,
# which is a safe failure, not a bypass.
have_tty() {
  [[ -t 0 ]] && return 0
  { : </dev/tty; } 2>/dev/null
}

# Every subcommand that embeds $id into a remote command STRING (not piped as
# data) validates it first — the id otherwise flows unescaped into a string
# that a remote shell parses, and a request id is attacker-influenced input
# (it names whatever an agent on the mini chose to enqueue). validate_id
# itself lives in lib/human-queue-json.sh (sourced below), shared with
# ask-human.sh.

# json_escape, json_field, printable, validate_id — shared with ask-human.sh. Both scripts
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

# Same scan as remote_count_script, emitting the pending ids themselves so the
# interactive drain can walk them without a human copy-pasting an id. The ids
# come FROM the mini, i.e. from the design's own stated adversary, so every one
# of them is re-validated below before it is embedded in any remote command
# string — pending_ids is a source of untrusted input, not a source of trust.
# shellcheck disable=SC2016
remote_ids_script() {
  printf 'dir="%s"; if [ -d "$dir" ]; then for f in "$dir"/*.req; do [ -e "$f" ] || continue; id=$(basename "$f" .req); [ -f "$dir/$id.res" ] || echo "$id"; done; fi' \
    "$REMOTE_QUEUE_DIR"
}

pending_ids() {
  local script
  script="bash -c '$(remote_ids_script)'"
  # shellcheck disable=SC2029
  ssh "${SSH_OPTS[@]}" "$HOST" "$script" \
    || die "could not reach $HOST to list the queue"
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
# `created` included: it is nominally a `date -u` stamp ask-human.sh writes
# itself, but nothing on THIS side of the hop verifies that, and the .req is
# authored on the mini — the adversary this whole function exists for. It
# renders two lines above the proposed command and four above the typed-`yes`
# prompt, so an ESC smuggled into it can redraw both. "We generate that field"
# is a statement about the honest case only. The value that EXECUTES (cmd_run's
# own `cmd_value` read) must never come from here — this function only prints.
print_req() {
  local req_json="$1"
  local id text host cwd created cmd_value
  id="$(json_field "$req_json" id)"
  text="$(json_field "$req_json" text)"
  host="$(json_field "$req_json" host)"
  cwd="$(json_field "$req_json" cwd)"
  created="$(json_field "$req_json" created)"
  cmd_value="$(json_field "$req_json" cmd)"

  local id_disp text_disp host_disp cwd_disp created_disp cmd_disp
  id_disp="$(printable "$id")"
  text_disp="$(printable "$text")"
  host_disp="$(printable "$host")"
  cwd_disp="$(printable "$cwd")"
  created_disp="$(printable "$created")"
  cmd_disp="$(printable "$cmd_value")"

  echo ""
  echo "  request $id_disp"
  echo "  from:    $host_disp  ($cwd_disp)"
  echo "  created: $created_disp"
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

# The result payload shape, shared by write_result (ssh'd back to the mini
# after an interactive `run`) and gui-run's own stdout (read by ask-human.sh's
# `push`, running ON the mini, which persists it locally with no extra hop).
# Both callers already validate the id before reaching here.
build_result_json() {
  local id="$1" status="$2" exit_code="$3" ran_at="$4" output_tail="$5"
  local exit_json="null"
  [[ -n "$exit_code" ]] && exit_json="$exit_code"
  printf '{'
  printf '"id":%s,' "$(json_escape "$id")"
  printf '"status":%s,' "$(json_escape "$status")"
  printf '"exit":%s,' "$exit_json"
  printf '"ran_at":%s,' "$(json_escape "$ran_at")"
  printf '"output_tail":%s' "$(json_escape "$output_tail")"
  printf '}\n'
}

# Pipes the JSON body to `ssh … 'cat > …'` over stdin — content never touches
# the remote command STRING, which is the whole point: a request's own
# output_tail can contain arbitrary bytes from a command an agent proposed, and
# interpolating that into a shell command line the remote has to parse would
# reopen exactly the injection risk `validate_id` exists to close for ids.
write_result() {
  local id="$1" status="$2" exit_code="$3" ran_at="$4" output_tail="$5"
  validate_id "$id"
  local payload
  payload="$(build_result_json "$id" "$status" "$exit_code" "$ran_at" "$output_tail")"
  local remote_cmd="cat > \"$REMOTE_QUEUE_DIR/$id.res\" && chmod 600 \"$REMOTE_QUEUE_DIR/$id.res\""
  # shellcheck disable=SC2029
  printf '%s' "$payload" | ssh "${SSH_OPTS[@]}" "$HOST" "$remote_cmd" \
    || die "could not write the result back to $HOST — the mini will keep waiting on $id"
}

cmd_run() {
  local id="${1:-}"
  [[ -n "$id" ]] || die "run requires <id>"
  validate_id "$id"

  have_tty || die "run requires an interactive terminal — refusing (there is no non-interactive path to executing a request)"

  local req_json
  req_json="$(fetch_req "$id")"
  print_req "$req_json"
  run_one "$id" "$req_json"
}

# The confirm-and-execute half, split out so the interactive drain can reuse it
# after it has already printed the request. Returns 1 on abort instead of
# exiting, so declining one request inside the drain does not end the walk —
# the typed 'yes' gate itself is unchanged, and there is still no caller that
# reaches it without a TTY.
run_one() {
  local id="$1" req_json="$2"

  have_tty || die "run requires an interactive terminal — refusing (there is no non-interactive path to executing a request)"

  local cmd_value
  cmd_value="$(json_field "$req_json" cmd)"

  echo "  WARNING: if you confirm, this runs on THIS machine (the MacBook) with your"
  echo "  full privileges — your unlocked 1Password session, your keychain, everything"
  echo "  you can reach. It was authored by an agent on the mini, not by you."
  echo "  The last 2000 bytes of its output are written back to $HOST, so a command"
  echo "  that prints a secret hands that secret to the machine that proposed it."
  echo ""

  local reply=""
  # `|| reply=""` — `read` returns 1 on EOF (Ctrl-D), and under `set -e` an
  # unguarded one kills the script mid-walk with a bare exit 1 instead of the
  # intended abort message. EOF means "no", which is what an empty reply is.
  read -r -p "  type 'yes' to proceed, anything else aborts: " reply </dev/tty || reply=""
  if [[ "$reply" != "yes" ]]; then
    echo "  aborted — no side effects, no result written."
    return 1
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

# gui-run — the non-interactive trigger for `ask-human.sh … --push`/`push`.
# Invoked over `ssh iumac … gui-run` FROM the mini with the request's raw JSON
# on stdin (never as a command-string argument — same reason write_result pipes
# instead of interpolates). Shows a native dialog with the exact command,
# requires a click, and stdout carries exactly ONE result JSON line (the
# build_result_json shape) for the caller on the mini to parse — nothing else
# may go to stdout in this path. A command's own output goes to a temp file,
# never here, so a chatty or secret-printing command can't corrupt the one
# line of protocol the mini is parsing.
#
# Deliberately does NOT require have_tty: this is the whole point of the
# subcommand — the dialog is what stands in for the TTY's typed-yes when
# nothing is attached to this ssh session, and osascript talks to the Aqua
# session's WindowServer regardless.
GUI_RUN_MAX_CMD_CHARS=2500

osascript_bin() { printf '%s' "${HUMAN_QUEUE_OSASCRIPT:-osascript}"; }

# One "Deny"/"Run" or "Not yet"/"Mark done" dialog. Every string reaches
# AppleScript as argv (`osascript - … <<'OSA'` + `on run argv`), never spliced
# into the script source — the request text and the proposed command are both
# written by the mini, the design's stated adversary, and interpolating them
# into AppleScript source would be exactly the injection print_req's own
# control-byte stripping exists to close one layer down. Echoes
# `button returned:<label>, gave up:<true|false>` on success; a non-zero exit
# means osascript itself failed to show anything (e.g. no GUI session).
gui_dialog() {
  local title="$1" msg="$2" btn_no="$3" btn_yes="$4" giveup="$5"
  "$(osascript_bin)" - "$title" "$msg" "$btn_no" "$btn_yes" "$giveup" <<'OSA'
on run argv
  set theTitle to item 1 of argv
  set theMsg to item 2 of argv
  set btnNo to item 3 of argv
  set btnYes to item 4 of argv
  set giveUp to (item 5 of argv) as integer
  set theResult to display dialog theMsg with title theTitle buttons {btnNo, btnYes} default button btnNo giving up after giveUp
  -- A dialog record does not coerce to text (error -1700), so spell the fields out
  -- in the same "button returned:X, gave up:Y" shape `osascript -e` prints.
  return "button returned:" & (button returned of theResult) & ", gave up:" & ((gave up of theResult) as text)
end run
OSA
}

gui_run_informational() {
  local id="$1" text_disp="$2" giveup="$3" ran_at="$4"
  local msg result rc
  msg="$text_disp

No command proposed — this is an informational request from an agent on the mini. \"Mark done\" tells the mini you have handled it; \"Not yet\" leaves it pending for make human-queue."

  # set +e around the assignment: under `set -e`, a failing command
  # substitution used as an assignment's RHS aborts the script immediately,
  # before `rc=$?` ever runs — osascript exiting non-zero (no GUI session)
  # must be a handled outcome (unanswered), not a script crash.
  set +e
  result="$(gui_dialog "human-queue: informational request from the mini" "$msg" "Not yet" "Mark done" "$giveup")"
  rc=$?
  set -e
  if (( rc != 0 )); then
    build_result_json "$id" "unanswered" "" "$ran_at" "could not show the dialog (osascript exit $rc)"
    return
  fi
  if [[ "$result" == *"gave up:true"* ]]; then
    build_result_json "$id" "unanswered" "" "$ran_at" "no response within ${giveup}s"
  elif [[ "$result" == *"button returned:Mark done"* ]]; then
    build_result_json "$id" "done" 0 "$ran_at" "marked done via dialog"
  else
    build_result_json "$id" "unanswered" "" "$ran_at" "left pending via dialog"
  fi
}

gui_run_command() {
  local id="$1" text_disp="$2" cmd_value="$3" cmd_disp="$4" giveup="$5" ran_at="$6"

  # Never show a truncated command — a dialog that cannot fit the whole string
  # must not offer to run it sight-unseen. No dialog is shown at all; this is
  # not a "click through anyway" prompt, it is a hard refusal.
  if (( ${#cmd_disp} > GUI_RUN_MAX_CMD_CHARS )); then
    build_result_json "$id" "unanswered" "" "$ran_at" \
      "too long (${#cmd_disp} chars) — use make human-queue"
    return
  fi

  local msg result rc
  msg="$text_disp

Runs on THIS MacBook with your full privileges, proposed by an agent on the mini:

---- proposed command ----
$cmd_disp
---------------------------"

  # See gui_run_informational above for why set -e is suspended here.
  set +e
  result="$(gui_dialog "human-queue: request from the mini" "$msg" "Deny" "Run" "$giveup")"
  rc=$?
  set -e
  if (( rc != 0 )); then
    build_result_json "$id" "unanswered" "" "$ran_at" "could not show the dialog (osascript exit $rc)"
    return
  fi
  if [[ "$result" == *"gave up:true"* ]]; then
    build_result_json "$id" "unanswered" "" "$ran_at" "no response within ${giveup}s"
    return
  fi
  if [[ "$result" != *"button returned:Run"* ]]; then
    build_result_json "$id" "denied" "" "$ran_at" "denied via dialog"
    return
  fi

  local tmp_out exit_code output_tail
  tmp_out="$(mktemp)"
  set +e
  bash -c "$cmd_value" >"$tmp_out" 2>&1
  exit_code=$?
  set -e
  output_tail="$(tail -c 2000 "$tmp_out")"
  rm -f "$tmp_out"

  local status
  [[ $exit_code -eq 0 ]] && status="done" || status="failed"
  build_result_json "$id" "$status" "$exit_code" "$ran_at" "$output_tail"
}

cmd_gui_run() {
  local req_json
  req_json="$(cat)"
  [[ -n "$req_json" ]] || die "gui-run requires a request JSON on stdin"

  local id text cmd_value
  id="$(json_field "$req_json" id)"
  text="$(json_field "$req_json" text)"
  cmd_value="$(json_field "$req_json" cmd)"
  [[ -n "$id" ]] || die "gui-run: request JSON on stdin has no id"
  validate_id "$id"

  local text_disp cmd_disp giveup ran_at
  text_disp="$(printable "$text")"
  cmd_disp="$(printable "$cmd_value")"
  giveup="${HUMAN_QUEUE_DIALOG_SECONDS:-600}"
  ran_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if [[ -z "$cmd_value" ]]; then
    gui_run_informational "$id" "$text_disp" "$giveup" "$ran_at"
  else
    gui_run_command "$id" "$text_disp" "$cmd_value" "$cmd_disp" "$giveup" "$ran_at"
  fi
}

# The default `make human-queue` path: list, then walk each pending request in
# front of the human and act on it in place. Purely an ergonomics layer over
# show/run/deny — every security property lives one level down and is untouched:
# the TTY requirement, the typed 'yes', the unmodified command string, the
# control-byte stripping in print_req. Without a TTY it degrades to a plain
# list, which is what the SessionStart hook and any non-interactive caller get.
cmd_drain() {
  if ! have_tty; then
    cmd_list
    return 0
  fi

  local ids
  ids="$(pending_ids)"
  if [[ -z "$ids" ]]; then
    echo "  nothing pending on $HOST."
    return 0
  fi

  # Collected into an array FIRST, never walked with `while read … <<< "$ids"`:
  # every iteration below runs ssh (fetch_req, and write_result on run/deny),
  # and ssh reads stdin — inside such a loop it swallows the remaining ids and
  # the walk silently ends after the first request. Bash 3.2 here, so no
  # mapfile.
  local -a queue=()
  local id
  while IFS= read -r id; do
    [[ -n "$id" ]] && queue+=("$id")
  done <<< "$ids"
  [[ ${#queue[@]} -gt 0 ]] || { echo "  nothing pending on $HOST."; return 0; }

  local total n=0
  total=${#queue[@]}
  echo "  $total pending request(s) from $HOST."

  for id in "${queue[@]}"; do
    n=$((n + 1))
    if ! [[ "$id" =~ ^[0-9]{8}T[0-9]{6}-[0-9]+$ ]]; then
      echo "  !! skipping malformed request id from $HOST: $(printable "$id")" >&2
      continue
    fi

    local req_json
    req_json="$(fetch_req "$id")"
    echo ""
    echo "  ---- [$n/$total] ----"
    print_req "$req_json"

    local action=""
    read -r -p "  [r]un / [a]lready done / [d]eny / [s]kip / [q]uit: " action </dev/tty || action="q"
    case "$action" in
      r|run)
        run_one "$id" "$req_json" || true
        ;;
      a|already|done)
        local note=""
        read -r -p "  note (optional): " note </dev/tty || note=""
        cmd_resolve "$id" "$note"
        ;;
      d|deny)
        local reason=""
        read -r -p "  reason (optional): " reason </dev/tty || reason=""
        cmd_deny "$id" "$reason"
        ;;
      q|quit)
        echo "  stopped — $((total - n + 1)) request(s) left pending."
        return 0
        ;;
      *)
        echo "  skipped — still pending."
        ;;
    esac
  done

  echo ""
  echo "  ✓ walked $n request(s)."
}

# Mark a request done WITHOUT running its proposed command — the case the queue
# was missing: the human satisfied the request out of band (here: `make
# secrets-seed` run directly), so the mini needs a `done`, not a `denied`, and
# re-running the command would only cost a second biometric pass. It needs no
# TTY and no typed 'yes' precisely because it never executes the mini's string;
# the gate exists to stop a proposed command from running, not to stop a human
# from reporting that the work already happened.
cmd_resolve() {
  local id="${1:-}"
  [[ -n "$id" ]] || die "resolve requires <id> [note]"
  shift
  local note="$*"
  [[ -n "$note" ]] || note="satisfied out of band by the human"
  validate_id "$id"

  local ran_at
  ran_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  write_result "$id" "done" 0 "$ran_at" "$note"
  echo "  ✓ $id marked done: $note"
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
  human-queue.sh                Walk every pending request and run/deny it in place
                                (falls back to `list` without a TTY)
  human-queue.sh count          Number of pending requests (fast; 0 on any failure)
  human-queue.sh list           List pending requests (table-ish, newest last)
  human-queue.sh show <id>      Print one request in full, including any proposed cmd
  human-queue.sh run <id>       Review + confirm ('yes') + execute a request's cmd
  human-queue.sh gui-run        Read one request JSON on stdin, show a native dialog,
                                execute on click. Called remotely by
                                `ask-human.sh push` over ssh — not for interactive use.
  human-queue.sh resolve <id> [note]  Mark done without running the cmd (already handled)
  human-queue.sh deny <id> [reason]   Deny a request; writes a denied result back
  human-queue.sh help           This message.

Reaches the mini over `ssh mini` (BatchMode, 8s connect timeout). `run` is
never non-interactive — including from the interactive walk: it refuses without
a TTY and requires a typed 'yes' per request.
See docs/remote-dev.md for the full model.
EOF
}

main() {
  local sub="${1:-drain}"
  case "$sub" in
    drain) cmd_drain ;;
    count) cmd_count ;;
    list) cmd_list ;;
    show) shift; cmd_show "$@" ;;
    run) shift; cmd_run "$@" ;;
    gui-run) shift; cmd_gui_run "$@" ;;
    resolve) shift; cmd_resolve "$@" ;;
    deny) shift; cmd_deny "$@" ;;
    help|-h|--help) usage ;;
    *) die "unknown subcommand: $sub (see: human-queue.sh help)" ;;
  esac
}

main "$@"
