#!/usr/bin/env bash
# human-queue.test.sh — regression harness for `human-queue.sh gui-run` (the
# non-interactive dialog trigger `ask-human.sh push` fires over `ssh iumac`)
# and the validate_id/build_result_json plumbing it shares with the rest of
# the queue.
#
# Hermetic and runnable on either machine: stubs `osascript` (a fake script
# whose behaviour is chosen by env var, and which optionally dumps its own
# argv for inspection — proving strings reach AppleScript as ARGV, never
# spliced into the script source) and forces the "not the mini" branch by
# pointing XDG_CONFIG_HOME at a scratch dir whose backend marker is not
# `cache`. Never invokes real osascript, never touches a real dialog, never
# opens a real ssh connection — `ask-human.sh push`'s live ssh leg is for the
# orchestrator to exercise against a real MacBook.
#
# Usage: scripts/human-queue.test.sh   (exit 0 = all pass)

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HQ="$HERE/human-queue.sh"
AH="$HERE/ask-human.sh"

pass=0
fail=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; [[ -n "${2:-}" ]] && printf '         %s\n' "$2"; fail=$((fail + 1)); }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
assert_contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "[$3] does not contain [$2]" ;; esac; }
assert_not_contains() { case "$3" in *"$2"*) bad "$1" "[$3] unexpectedly contains [$2]" ;; *) ok "$1" ;; esac; }

[[ -x "$HQ" ]] || { echo "✗ $HQ not found/executable"; exit 2; }
[[ -x "$AH" ]] || { echo "✗ $AH not found/executable"; exit 2; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/human-queue-test.XXXXXX")" || exit 2
trap 'rm -rf "$TMP"' EXIT

# --- force the "not the mini" branch, hermetically -----------------------
# on_dev_host() reads $XDG_CONFIG_HOME/secrets/backend; anything other than
# the literal string "cache" takes the MacBook path. A per-test scratch dir
# means this never reads (or could ever disagree with) the real machine's
# marker.
CFG="$TMP/config"
mkdir -p "$CFG/secrets"
printf 'op' > "$CFG/secrets/backend"
export XDG_CONFIG_HOME="$CFG"

# A throwaway queue dir for ask-human.sh's own req/res files.
STATE="$TMP/state"
mkdir -p "$STATE"
export XDG_STATE_HOME="$STATE"

# json_field/validate_id call die() on a malformed value — only used below to
# build assertion inputs, so a plain stderr message is enough.
die() { echo "die: $*" >&2; return 1; }
# shellcheck source=lib/human-queue-json.sh
source "$HERE/lib/human-queue-json.sh"

# --- osascript stub ---------------------------------------------------------
# Behaviour selected by $HUMAN_QUEUE_TEST_BUTTON: a button label echoes
# "button returned:<label>, gave up:false"; TIMEOUT echoes gave-up:true;
# FAIL exits non-zero (osascript itself failed to show anything). When
# $HUMAN_QUEUE_CAPTURE_ARGV is set, every argv element is dumped one per line
# — the only way this harness inspects what gui-run handed to "AppleScript"
# without a real display.
OSASCRIPT_STUB="$TMP/osascript-stub.sh"
cat > "$OSASCRIPT_STUB" <<'STUB'
#!/usr/bin/env bash
if [[ -n "${HUMAN_QUEUE_CAPTURE_ARGV:-}" ]]; then
  printf '%s\n' "$@" > "$HUMAN_QUEUE_CAPTURE_ARGV"
fi
case "${HUMAN_QUEUE_TEST_BUTTON:-Run}" in
  FAIL) exit 3 ;;
  TIMEOUT) echo "button returned:Deny, gave up:true" ;;
  *) echo "button returned:${HUMAN_QUEUE_TEST_BUTTON}, gave up:false" ;;
esac
STUB
chmod +x "$OSASCRIPT_STUB"
export HUMAN_QUEUE_OSASCRIPT="$OSASCRIPT_STUB"

# build_req <id> <text> <cmd-or-empty>
build_req() {
  local id="$1" text="$2" cmd="$3" cmd_json="null"
  [[ -n "$cmd" ]] && cmd_json="$(json_escape "$cmd")"
  printf '{"id":%s,"created":"2026-09-14T00:00:00Z","host":"mini","cwd":"/tmp","text":%s,"cmd":%s}\n' \
    "$(json_escape "$id")" "$(json_escape "$text")" "$cmd_json"
}

gui_run() {
  # $1=request json, rest = extra env assignments already exported by caller
  printf '%s' "$1" | HUMAN_QUEUE_OSASCRIPT="$OSASCRIPT_STUB" bash "$HQ" gui-run
}

echo "gui-run — dialog outcomes"

# --- Run ---------------------------------------------------------------------
req="$(build_req "20260914T000001-1" "reseal the cache" "echo marker-run-ok")"
out="$(HUMAN_QUEUE_TEST_BUTTON=Run gui_run "$req")"
lines="$(printf '%s\n' "$out" | grep -c .)"
assert_eq "Run: exactly one stdout line (protocol, not the command's own output)" "1" "$lines"
assert_eq "Run: status done"   "done" "$(json_field "$out" status)"
assert_eq "Run: exit 0"        "0"    "$(json_field "$out" exit)"
assert_contains "Run: output_tail carries the command's stdout" "marker-run-ok" "$(json_field "$out" output_tail)"

# A failing command → status failed, non-zero exit preserved.
req="$(build_req "20260914T000002-1" "run something that fails" "exit 7")"
out="$(HUMAN_QUEUE_TEST_BUTTON=Run gui_run "$req")"
assert_eq "Run (failing cmd): status failed" "failed" "$(json_field "$out" status)"
assert_eq "Run (failing cmd): exit 7"        "7"      "$(json_field "$out" exit)"

# --- Deny ----------------------------------------------------------------
req="$(build_req "20260914T000003-1" "reseal the cache" "echo should-not-run")"
out="$(HUMAN_QUEUE_TEST_BUTTON=Deny gui_run "$req")"
assert_eq "Deny: status denied" "denied" "$(json_field "$out" status)"

# --- give-up / timeout ----------------------------------------------------
req="$(build_req "20260914T000004-1" "reseal the cache" "echo should-not-run")"
out="$(HUMAN_QUEUE_TEST_BUTTON=TIMEOUT gui_run "$req")"
assert_eq "Give-up: status unanswered" "unanswered" "$(json_field "$out" status)"

# --- osascript itself fails (no GUI session) ------------------------------
req="$(build_req "20260914T000005-1" "reseal the cache" "echo should-not-run")"
out="$(HUMAN_QUEUE_TEST_BUTTON=FAIL gui_run "$req")"
assert_eq "osascript failure: status unanswered" "unanswered" "$(json_field "$out" status)"

echo ""
echo "gui-run — informational requests (no cmd)"

req="$(build_req "20260914T000006-1" "just checking in" "")"
out="$(HUMAN_QUEUE_TEST_BUTTON="Mark done" gui_run "$req")"
assert_eq "informational, Mark done: status done" "done" "$(json_field "$out" status)"

req="$(build_req "20260914T000007-1" "just checking in" "")"
out="$(HUMAN_QUEUE_TEST_BUTTON="Not yet" gui_run "$req")"
assert_eq "informational, Not yet: status unanswered (stays pending)" "unanswered" "$(json_field "$out" status)"

echo ""
echo "gui-run — safety properties"

# AppleScript-injection payload: reaches osascript as argv, never spliced into
# the script source, so it can carry quotes/backticks/newlines with no special
# handling needed here beyond normal JSON round-tripping.
inject='"; do shell script "touch /tmp/human-queue-test-pwned"; return "'
req="$(build_req "20260914T000008-1" "$inject" "echo inject-marker-ok")"
capture="$TMP/argv-inject.txt"
out="$(HUMAN_QUEUE_TEST_BUTTON=Deny HUMAN_QUEUE_CAPTURE_ARGV="$capture" gui_run "$req")"
assert_eq "injection payload: still a single valid result line" "denied" "$(json_field "$out" status)"
[[ -f "$capture" ]] && assert_contains "injection payload: reached osascript as a literal argv string" "$inject" "$(cat "$capture")" \
  || bad "injection payload: capture file missing"
[[ ! -f /tmp/human-queue-test-pwned ]] && ok "injection payload: never executed" || { bad "injection payload: WAS EXECUTED"; rm -f /tmp/human-queue-test-pwned; }

# Control byte (raw ESC) in the request text: printable() must strip it from
# what reaches the dialog (argv element 3 = the message), while the command
# itself still executes with its own unmodified bytes (checked separately —
# json_escape/json_field already round-trip control bytes faithfully via jq).
esc_text="$(printf 'status line one\x1b[31mred\x1b[0mline two')"
req="$(build_req "20260914T000009-1" "$esc_text" "echo esc-marker-ok")"
capture="$TMP/argv-esc.txt"
out="$(HUMAN_QUEUE_TEST_BUTTON=Run HUMAN_QUEUE_CAPTURE_ARGV="$capture" gui_run "$req")"
assert_eq "control byte: command still executes normally" "done" "$(json_field "$out" status)"
if [[ -f "$capture" ]]; then
  msg_line="$(sed -n '3p' "$capture")"
  if printf '%s' "$msg_line" | LC_ALL=C grep -q $'\x1b'; then
    bad "control byte: raw ESC leaked into the dialog message"
  else
    ok "control byte: stripped from the dialog message"
  fi
else
  bad "control byte: capture file missing"
fi

# Over-long command: must never reach the dialog at all (no osascript call —
# a truncated command must not be offered a Run button).
long_cmd="echo $(head -c 3000 </dev/zero | tr '\0' 'x')"
req="$(build_req "20260914T000010-1" "an oversized command" "$long_cmd")"
capture="$TMP/argv-long.txt"
rm -f "$capture"
out="$(HUMAN_QUEUE_TEST_BUTTON=Run HUMAN_QUEUE_CAPTURE_ARGV="$capture" gui_run "$req")"
assert_eq "over-long command: status unanswered" "unanswered" "$(json_field "$out" status)"
assert_contains "over-long command: says too long, points at make human-queue" "make human-queue" "$(json_field "$out" output_tail)"
[[ ! -f "$capture" ]] && ok "over-long command: dialog never shown (no osascript call)" || bad "over-long command: osascript WAS called"

echo ""
echo "gui-run — refuses on the mini (dev host)"

CACHE_CFG="$TMP/config-cache"
mkdir -p "$CACHE_CFG/secrets"
printf 'cache' > "$CACHE_CFG/secrets/backend"
req="$(build_req "20260914T000011-1" "should be refused" "echo nope")"
err="$(printf '%s' "$req" | XDG_CONFIG_HOME="$CACHE_CFG" HUMAN_QUEUE_OSASCRIPT="$OSASCRIPT_STUB" bash "$HQ" gui-run 2>&1 1>/dev/null)"
rc_out="$(printf '%s' "$req" | XDG_CONFIG_HOME="$CACHE_CFG" HUMAN_QUEUE_OSASCRIPT="$OSASCRIPT_STUB" bash "$HQ" gui-run >/dev/null 2>&1; echo $?)"
assert_eq "cache backend (the mini): gui-run exits 1" "1" "$rc_out"
assert_contains "cache backend (the mini): explains this is the MacBook-side script" "MacBook" "$err"

echo ""
echo "validate_id — shared between both scripts"

bash "$HQ" show "not-a-valid-id" >/dev/null 2>&1
assert_eq "human-queue.sh show: malformed id rejected (rc 1)" "1" "$?"

out="$(bash "$AH" push "not-a-valid-id" 2>&1 1>/dev/null)"
bash "$AH" push "not-a-valid-id" >/dev/null 2>&1
rc="$?"
assert_eq "ask-human.sh push: malformed id rejected (rc 1)" "1" "$rc"
assert_contains "ask-human.sh push: malformed id error names the id" "invalid request id" "$out"

echo ""
echo "ask-human.sh push — pre-ssh guard clauses (no network involved)"

bash "$AH" push "20260914T000099-1" >/dev/null 2>&1
assert_eq "push: unknown id refused before any ssh attempt (rc 1)" "1" "$?"

id="$(bash "$AH" ask "already resolved" --cmd "echo hi")"
res_file="$STATE/human-queue/$id.res"
printf '{"id":%s,"status":"done","exit":0,"ran_at":"2026-09-14T00:00:00Z","output_tail":""}\n' "$(json_escape "$id")" > "$res_file"
bash "$AH" push "$id" >/dev/null 2>&1
assert_eq "push: refuses to push an id that already has a .res (rc 1)" "1" "$?"

echo ""
[[ "$fail" -eq 0 ]] \
  && { echo "✓ human-queue: all $pass assertion(s) passed"; exit 0; } \
  || { echo "✗ human-queue: $fail of $((pass + fail)) assertion(s) failed"; exit 1; }
