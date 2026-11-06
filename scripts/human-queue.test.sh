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
# ask pushes by default (ssh iumac) — never from a test.
export HUMAN_QUEUE_PUSH=0
# A factory session running this suite must not leak into ask-human's notify sweep.
unset FACTORY_SESSION

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

# Approval text must equal the executed text: a command the sanitizer would
# alter is refused without a dialog, for control bytes and invisible Unicode.
for variant in $'echo a\x1b[2Kb' $'echo a\xe2\x80\xaeb' $'echo a\xe2\x80\x8bb' $'echo a\xef\xbb\xbfb' $'echo a\xc2\x85b'; do
  req="$(build_req "20260914T000020-1" "hidden chars" "$variant")"
  capture="$TMP/argv-hidden.txt"
  rm -f "$capture"
  out="$(HUMAN_QUEUE_TEST_BUTTON=Run HUMAN_QUEUE_CAPTURE_ARGV="$capture" gui_run "$req")"
  label="$(printf '%s' "$variant" | od -An -tx1 | tr -d ' \n')"
  assert_eq "altered command [$label]: status unanswered" "unanswered" "$(json_field "$out" status)"
  assert_contains "altered command [$label]: refusal reason" "refused" "$(json_field "$out" output_tail)"
  [[ ! -f "$capture" ]] && ok "altered command [$label]: dialog never shown" || bad "altered command [$label]: osascript WAS called"
done

# Invisible Unicode in the request text is stripped from the dialog message.
uni_text="$(printf 'plain\xe2\x80\xaeRTL\xe2\x80\x8bZW end')"
req="$(build_req "20260914T000021-1" "$uni_text" "echo uni-ok")"
capture="$TMP/argv-uni.txt"
out="$(HUMAN_QUEUE_TEST_BUTTON=Deny HUMAN_QUEUE_CAPTURE_ARGV="$capture" gui_run "$req")"
msg_line="$(sed -n '3p' "$capture")"
assert_contains "unicode text: visible characters kept" "plainRTLZW end" "$msg_line"
if printf '%s' "$msg_line" | LC_ALL=C grep -q $'\xe2\x80'; then bad "unicode text: invisible characters leaked into the dialog"; else ok "unicode text: invisible characters stripped"; fi

# Ordinary non-ASCII text is untouched and still runs.
req="$(build_req "20260914T000022-1" "Prüfung €" "echo Prüfung-ok")"
out="$(HUMAN_QUEUE_TEST_BUTTON=Run gui_run "$req")"
assert_eq "umlaut command: still runs" "done" "$(json_field "$out" status)"

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
echo "ask-human.sh push, HUMAN_QUEUE_MAC_HOST=local — gui-run on this machine, no ssh"
export HUMAN_QUEUE_PUSH=1
ssh_probe="$TMP/ssh-called"
mkdir -p "$TMP/fakebin"
printf '#!/bin/sh\ntouch "%s"\nexit 255\n' "$ssh_probe" > "$TMP/fakebin/ssh"; chmod +x "$TMP/fakebin/ssh"
out="$(PATH="$TMP/fakebin:$PATH" HUMAN_QUEUE_MAC_HOST=local HUMAN_QUEUE_TEST_BUTTON=Run bash "$AH" ask "local approval" --cmd "echo local-ran" 2>/dev/null)"; rc=$?
id="$(printf '%s\n' "$out" | head -1)"
assert_eq "local push, Run: rc 0" "0" "$rc"
assert_eq "local push: ssh never called" "no" "$([[ -e "$ssh_probe" ]] && echo yes || echo no)"
assert_contains "local push: result persisted as done" '"status":"done"' "$(cat "$STATE/human-queue/$id.res")"
out="$(PATH="$TMP/fakebin:$PATH" HUMAN_QUEUE_MAC_HOST=local HUMAN_QUEUE_TEST_BUTTON=Deny bash "$AH" ask "local approval" --cmd "echo nope" 2>/dev/null)"; rc=$?
assert_eq "local push, Deny: rc 1" "1" "$rc"
export HUMAN_QUEUE_PUSH=0

echo ""
echo "ask-human.sh list --json — the machine read"

# Fresh queue so earlier sections' requests don't leak in.
QDIR="$STATE/human-queue"
rm -rf "$QDIR"
if ! command -v jq >/dev/null 2>&1; then
  echo "  (jq missing — skipping list --json assertions)"
else
  out="$(bash "$AH" list --json)"
  assert_eq "list --json: empty queue is []" "[]" "$out"

  id1="$(bash "$AH" ask "plain request" --cmd "echo hi")"
  out="$(bash "$AH" list --json)"
  assert_eq "list --json: one request, one row" "1" "$(jq 'length' <<<"$out")"
  assert_eq "list --json: id" "$id1" "$(jq -r '.[0].id' <<<"$out")"
  assert_eq "list --json: text" "plain request" "$(jq -r '.[0].text' <<<"$out")"
  assert_eq "list --json: cmd as stored" "echo hi" "$(jq -r '.[0].cmd' <<<"$out")"
  assert_eq "list --json: state pending" "pending" "$(jq -r '.[0].state' <<<"$out")"
  assert_eq "list --json: askedAt is ISO 8601 UTC" "true" "$(jq '.[0].askedAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' <<<"$out")"
  assert_eq "list --json: ageSeconds is a small non-negative integer" "true" "$(jq '.[0].ageSeconds | (. >= 0 and . < 60 and . == floor)' <<<"$out")"

  # askedAt is the request's own `created`; age counts from it.
  past="$(date -u -v-2H +%Y-%m-%dT%H:%M:%SZ)"
  sed -i '' "s/\"created\":\"[^\"]*\"/\"created\":\"$past\"/" "$QDIR/$id1.req"
  out="$(bash "$AH" list --json)"
  assert_eq "list --json: askedAt echoes created" "$past" "$(jq -r '.[0].askedAt' <<<"$out")"
  assert_eq "list --json: ageSeconds counts from created (~2h)" "true" "$(jq '.[0].ageSeconds | (. >= 7200 and . < 7260)' <<<"$out")"

  # No cmd -> null; quotes, backslash, newline, tab, control byte round-trip.
  tricky=$'say "hi" \\ back\nsecond line\ttab \001 ctl'
  id2="$(bash "$AH" ask "$tricky")"
  out="$(bash "$AH" list --json)"
  assert_eq "list --json: tricky text round-trips exactly" "$tricky" "$(jq -r --arg id "$id2" '.[] | select(.id == $id) | .text' <<<"$out")"
  assert_eq "list --json: no cmd is null" "null" "$(jq -c --arg id "$id2" '.[] | select(.id == $id) | .cmd' <<<"$out")"
  tricky_cmd=$'printf "%s\\n" \'a\'\necho b'
  id3="$(bash "$AH" ask "tricky cmd" --cmd "$tricky_cmd")"
  out="$(bash "$AH" list --json)"
  assert_eq "list --json: tricky cmd round-trips exactly" "$tricky_cmd" "$(jq -r --arg id "$id3" '.[] | select(.id == $id) | .cmd' <<<"$out")"

  # A push that finds the MacBook unreachable marks the request queued.
  PATH="$TMP/fakebin:$PATH" HUMAN_QUEUE_PUSH=1 HUMAN_QUEUE_MAC_HOST=unreachable-host bash "$AH" push "$id1" >/dev/null 2>&1
  assert_eq "push to an unreachable MacBook: rc 69" "69" "$?"
  out="$(bash "$AH" list --json)"
  assert_eq "list --json: unreachable push -> state queued" "queued" "$(jq -r --arg id "$id1" '.[] | select(.id == $id) | .state' <<<"$out")"
  assert_eq "list --json: an unpushed request stays pending" "pending" "$(jq -r --arg id "$id3" '.[] | select(.id == $id) | .state' <<<"$out")"

  # A later push that reaches the MacBook (even unanswered) is no longer "queued".
  PATH="$TMP/fakebin:$PATH" HUMAN_QUEUE_MAC_HOST=local HUMAN_QUEUE_TEST_BUTTON=TIMEOUT bash "$AH" push "$id1" >/dev/null 2>&1
  out="$(bash "$AH" list --json)"
  assert_eq "list --json: a push that reaches the MacBook clears queued" "pending" "$(jq -r --arg id "$id1" '.[] | select(.id == $id) | .state' <<<"$out")"

  # Missing or malformed created: askedAt/ageSeconds fall back to the file's mtime.
  id4="$(bash "$AH" ask "no created" 2>/dev/null)"
  sed -i '' 's/"created":"[^"]*",//' "$QDIR/$id4.req"
  assert_not_contains "list --json: created really removed for the fallback test" '"created"' "$(cat "$QDIR/$id4.req")"
  touch -t "$(date -v-1H +%Y%m%d%H%M.%S)" "$QDIR/$id4.req"
  out="$(bash "$AH" list --json)"
  assert_eq "list --json: no created -> mtime askedAt is ISO UTC" "true" "$(jq --arg id "$id4" '.[] | select(.id == $id) | .askedAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' <<<"$out")"
  assert_eq "list --json: no created -> ageSeconds from mtime (~1h)" "true" "$(jq --arg id "$id4" '.[] | select(.id == $id) | .ageSeconds | (. >= 3600 and . < 3660)' <<<"$out")"
  sed -i '' 's/"text":/"created":"not-a-date","text":/' "$QDIR/$id4.req"
  out="$(bash "$AH" list --json)"
  assert_eq "list --json: malformed created -> mtime askedAt, not the junk" "true" "$(jq --arg id "$id4" '.[] | select(.id == $id) | .askedAt | test("^[0-9]{4}-")' <<<"$out")"
  rm -f "$QDIR/$id4.req"

  # A result hides the request, and clears its queued marker.
  printf '{"id":%s,"status":"done","exit":0,"ran_at":"2026-09-14T00:00:00Z","output_tail":""}\n' "$(json_escape "$id1")" > "$QDIR/$id1.res"
  out="$(bash "$AH" list --json)"
  assert_eq "list --json: request with a result is absent" "0" "$(jq --arg id "$id1" '[.[] | select(.id == $id)] | length' <<<"$out")"

  # Mid-write requests (the dotted temp file ask/mv uses) are never seen.
  printf '{"id":"half","text":"par' > "$QDIR/.20260914T000001-1.req.AbC123"
  out="$(bash "$AH" list --json)"
  assert_eq "list --json: half-written temp file is absent" "2" "$(jq 'length' <<<"$out")"
  assert_eq "list --json: output stays valid JSON" "true" "$(jq -e 'type == "array"' <<<"$out" >/dev/null 2>&1 && echo true || echo false)"

  # write_local_result drops the queued marker.
  : > "$QDIR/$id3.queued"
  PATH="$TMP/fakebin:$PATH" HUMAN_QUEUE_MAC_HOST=local HUMAN_QUEUE_TEST_BUTTON=Deny bash "$AH" push "$id3" >/dev/null 2>&1
  assert_eq "result written: queued marker removed" "no" "$([[ -e "$QDIR/$id3.queued" ]] && echo yes || echo no)"
fi

echo ""
echo "ask-human.sh list — plain output unchanged, flags validated"
rm -rf "$QDIR"
assert_eq "list: empty queue prints the usual line" "no pending requests" "$(bash "$AH" list)"
id="$(bash "$AH" ask "plain listing")"
out="$(bash "$AH" list)"
assert_contains "list: tab row carries the id" "$id" "$out"
assert_not_contains "list: no JSON in plain output" '{"id"' "$out"
bash "$AH" list --bogus >/dev/null 2>&1
assert_eq "list --bogus: exit 2" "2" "$?"
bash "$AH" list --json --bogus >/dev/null 2>&1
assert_eq "list --json --bogus: exit 2" "2" "$?"

echo ""
echo "ask-human.sh resolve — the owner's answer without the MacBook"
rm -rf "$QDIR"
if ! command -v jq >/dev/null 2>&1; then
  echo "  (jq missing — skipping resolve assertions)"
else
  marker="$TMP/resolve-ran"
  rid="$(bash "$AH" ask "resolve me" --cmd "touch $marker")"
  bash "$AH" resolve "$rid" --as "done" --note "did it by hand" >/dev/null 2>&1; rc=$?
  assert_eq "resolve --as done: rc 0" "0" "$rc"
  res="$(cat "$QDIR/$rid.res")"
  assert_eq "resolve done: one-line result" "1" "$(printf '%s\n' "$res" | grep -c .)"
  assert_eq "resolve done: status done" "done" "$(jq -r .status <<<"$res")"
  assert_eq "resolve done: exit 0" "0" "$(jq -r .exit <<<"$res")"
  assert_eq "resolve done: resolvedAs" "done" "$(jq -r .resolvedAs <<<"$res")"
  assert_eq "resolve done: resolvedNote" "did it by hand" "$(jq -r .resolvedNote <<<"$res")"
  assert_eq "resolve done: id matches" "$rid" "$(jq -r .id <<<"$res")"
  assert_eq "resolve done: result mode 600" "600" "$(stat -f %Lp "$QDIR/$rid.res")"
  assert_eq "resolve: the request's command never ran" "no" "$([[ -e "$marker" ]] && echo yes || echo no)"
  assert_eq "resolve: no temp file left behind" "0" "$(find "$QDIR" -name '.*res.*' | wc -l | tr -d ' ')"
  assert_not_contains "resolve: resolved request is out of list" "$rid" "$(bash "$AH" list --json)"
  assert_contains "status shows resolvedAs" '"resolvedAs":"done"' "$(bash "$AH" status "$rid")"
  assert_contains "status shows resolvedNote" 'did it by hand' "$(bash "$AH" status "$rid")"

  err="$(bash "$AH" resolve "$rid" --as denied 2>&1)"; rc=$?
  assert_eq "second resolve: refused with rc 2" "2" "$rc"
  assert_contains "second resolve: says why in a line" "already has a result" "$err"
  assert_eq "second resolve: result untouched" "done" "$(jq -r .resolvedAs "$QDIR/$rid.res")"

  for as in denied superseded; do
    rid="$(bash "$AH" ask "resolve as $as" --cmd "touch $marker")"
    : > "$QDIR/$rid.queued"
    bash "$AH" resolve "$rid" --as "$as" >/dev/null 2>&1; rc=$?
    assert_eq "resolve --as $as: rc 0" "0" "$rc"
    res="$(cat "$QDIR/$rid.res")"
    assert_eq "resolve $as: status denied (not run)" "denied" "$(jq -r .status <<<"$res")"
    assert_eq "resolve $as: resolvedAs" "$as" "$(jq -r .resolvedAs <<<"$res")"
    assert_eq "resolve $as: no note is null" "null" "$(jq -c .resolvedNote <<<"$res")"
    assert_eq "resolve $as: queued marker dropped" "no" "$([[ -e "$QDIR/$rid.queued" ]] && echo yes || echo no)"
    assert_eq "resolve $as: command never ran" "no" "$([[ -e "$marker" ]] && echo yes || echo no)"
  done

  # A note with quotes/newlines round-trips.
  rid="$(bash "$AH" ask "tricky note")"
  tricky=$'said "no" \\ and\nmore'
  bash "$AH" resolve "$rid" --as superseded --note "$tricky" >/dev/null 2>&1
  assert_eq "resolve: tricky note round-trips" "$tricky" "$(jq -r .resolvedNote "$QDIR/$rid.res")"

  err="$(bash "$AH" resolve "20260914T000099-1" --as "done" 2>&1)"; rc=$?
  assert_eq "resolve unknown id: rc 2" "2" "$rc"
  assert_contains "resolve unknown id: one line naming it" "no such request" "$err"
  bash "$AH" resolve "not-an-id" --as "done" >/dev/null 2>&1
  assert_eq "resolve malformed id: rc 2" "2" "$?"
  rid="$(bash "$AH" ask "bad args")"
  bash "$AH" resolve "$rid" >/dev/null 2>&1
  assert_eq "resolve without --as: rc 2" "2" "$?"
  bash "$AH" resolve "$rid" --as maybe >/dev/null 2>&1
  assert_eq "resolve --as maybe: rc 2" "2" "$?"
  bash "$AH" resolve "$rid" --as "done" --bogus >/dev/null 2>&1
  assert_eq "resolve --bogus: rc 2" "2" "$?"
  assert_eq "resolve bad args: request still pending" "no" "$([[ -e "$QDIR/$rid.res" ]] && echo yes || echo no)"

  # A waiting `ask --wait` caller sees a denied resolve as not run (rc 1), a done one as rc 0.
  for pair in "denied:1" "superseded:1" "done:0"; do
    as="${pair%%:*}"; want="${pair##*:}"
    outf="$TMP/wait-$as.out"
    bash "$AH" ask "waiting caller $as" --cmd "touch $marker" --wait 30 > "$outf" 2>&1 &
    wpid=$!
    for _ in $(seq 1 50); do [[ -s "$outf" ]] && break; sleep 0.1; done
    wid="$(head -1 "$outf")"
    if [[ -z "$wid" ]]; then
      kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null
      bad "waiting ask ($as): no request id printed"
      continue
    fi
    bash "$AH" resolve "$wid" --as "$as" >/dev/null 2>&1
    wait "$wpid"; wrc=$?
    assert_eq "waiting ask sees resolve $as as rc $want" "$want" "$wrc"
    assert_contains "waiting ask prints the result line ($as)" "\"resolvedAs\":\"$as\"" "$(cat "$outf")"
  done
  assert_eq "waiting callers: command never ran" "no" "$([[ -e "$marker" ]] && echo yes || echo no)"
fi

echo ""
echo "ask-human.sh — keys, clear, expiry, factory notes"
rm -rf "$QDIR"
if ! command -v jq >/dev/null 2>&1; then
  echo "  (jq missing — skipping key/expiry assertions)"
else
  has_res() { [[ -e "$QDIR/$1.res" ]] && echo yes || echo no; }

  # Replace by key.
  a="$(bash "$AH" ask "deploy gate old" --key deploy:x)"; sleep 1
  other="$(bash "$AH" ask "other key" --key deploy:y)"
  b="$(bash "$AH" ask "deploy gate new" --key deploy:x)"
  assert_eq "key: older same-key request resolved" "yes" "$(has_res "$a")"
  assert_eq "key: resolvedAs superseded" "superseded" "$(jq -r .resolvedAs "$QDIR/$a.res")"
  assert_eq "key: note names the new id" "replaced by $b" "$(jq -r .resolvedNote "$QDIR/$a.res")"
  assert_eq "key: different key untouched" "no" "$(has_res "$other")"
  assert_eq "key: new request pending" "no" "$(has_res "$b")"
  assert_eq "key: stored in the .req" "deploy:x" "$(jq -r .key "$QDIR/$b.req")"
  out="$(bash "$AH" list --json)"
  assert_eq "key: list --json shows only the new one for the key" "1" "$(jq --arg k deploy:x '[.[] | select(.key == $k)] | length' <<<"$out")"
  assert_eq "key: list --json fields stay (state)" "pending" "$(jq -r --arg id "$b" '.[] | select(.id == $id) | .state' <<<"$out")"
  bash "$AH" ask "bad key" --key 'a b' >/dev/null 2>&1
  assert_eq "key: invalid chars die" "1" "$?"
  nk="$(bash "$AH" ask "no key")"
  assert_eq "no key: stored as null" "null" "$(jq -c .key "$QDIR/$nk.req")"

  # clear <key>.
  out="$(bash "$AH" clear deploy:x)"; rc=$?
  assert_eq "clear: rc 0" "0" "$rc"
  assert_eq "clear: prints cleared 1" "cleared 1" "$out"
  assert_eq "clear: resolved done" "done" "$(jq -r .resolvedAs "$QDIR/$b.res")"
  assert_contains "clear: default note" "later success" "$(jq -r .resolvedNote "$QDIR/$b.res")"
  assert_eq "clear: other key untouched" "no" "$(has_res "$other")"
  assert_eq "clear again: idempotent cleared 0" "cleared 0" "$(bash "$AH" clear deploy:x)"
  assert_eq "clear unknown key: rc 0" "0" "$(bash "$AH" clear nothing:here >/dev/null 2>&1; echo $?)"
  bash "$AH" clear deploy:y --as superseded --note "gone" >/dev/null
  assert_eq "clear --as/--note" "superseded:gone" "$(jq -r '"\(.resolvedAs):\(.resolvedNote)"' "$QDIR/$other.res")"
  bash "$AH" resolve "$nk" --as "done" >/dev/null

  # Default expiry, never, malformed.
  d="$(bash "$AH" ask "default ttl")"
  assert_eq "expiry: default present (ISO)" "true" "$(jq '.expires | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")' "$QDIR/$d.req")"
  assert_eq "expiry: default is ~3d" "true" "$(jq --argjson now "$(date +%s)" '(.expires | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) as $e | ($e - $now) | (. > 259000 and . < 259300)' "$QDIR/$d.req")"
  n="$(bash "$AH" ask "never expires" --expires never)"
  assert_eq "expiry: never -> null" "null" "$(jq -c .expires "$QDIR/$n.req")"
  bash "$AH" ask "bad ttl" --expires soon >/dev/null 2>&1
  assert_eq "expiry: malformed duration dies" "1" "$?"
  assert_eq "expiry: malformed leaves no request" "0" "$(bash "$AH" list --json | jq '[.[] | select(.text == "bad ttl")] | length')"
  bash "$AH" resolve "$d" --as "done" >/dev/null; bash "$AH" resolve "$n" --as "done" >/dev/null

  # Expiry: --expires 1s and a hand-edited past date.
  # e1 is enqueued last: any later `ask` would reap it quietly before `reap` runs.
  e2="$(bash "$AH" ask "hand edited")"
  e1="$(bash "$AH" ask "short lived" --expires 1s --key exp:k --cmd "touch $TMP/expired-ran")"
  sed -i '' 's/"expires":"[^"]*"/"expires":"2020-01-01T00:00:00Z"/' "$QDIR/$e2.req"
  sleep 2
  out="$(bash "$AH" reap)"
  assert_eq "reap: prints one line per expired request" "2" "$(printf '%s\n' "$out" | grep -c .)"
  assert_eq "reap: .res resolvedAs expired" "expired" "$(jq -r .resolvedAs "$QDIR/$e1.res")"
  assert_eq "reap: status denied" "denied" "$(jq -r .status "$QDIR/$e1.res")"
  assert_contains "reap: note says expired" "expired " "$(jq -r .resolvedNote "$QDIR/$e1.res")"
  assert_eq "reap: command never ran" "no" "$([[ -e "$TMP/expired-ran" ]] && echo yes || echo no)"
  assert_eq "reap: events.log has one line for it" "1" "$(grep -c " expired $e1 exp:k short lived" "$QDIR/events.log")"
  assert_eq "reap: events.log has two lines total" "2" "$(grep -c . "$QDIR/events.log")"
  assert_eq "reap again: no output" "" "$(bash "$AH" reap)"
  assert_eq "reap again: no new event line" "2" "$(grep -c . "$QDIR/events.log")"

  e3="$(bash "$AH" ask "expires on list" --expires 1s)"; sleep 2
  out="$(bash "$AH" list --json)"
  assert_eq "list --json drops an expired item" "0" "$(jq --arg id "$e3" '[.[] | select(.id == $id)] | length' <<<"$out")"
  assert_eq "list --json reap wrote the result" "expired" "$(jq -r .resolvedAs "$QDIR/$e3.res")"
  assert_eq "list --json reap logged it" "1" "$(grep -c " expired $e3 " "$QDIR/events.log")"

  # Notify sweep via a stub factory.
  CALLS="$TMP/factory-calls"; : > "$CALLS"
  FSTUB="$TMP/factory-stub.sh"
  cat > "$FSTUB" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FACTORY_CALLS"
[[ -n "${FACTORY_FAIL:-}" ]] && exit 1
exit 0
STUB
  chmod +x "$FSTUB"
  export HUMAN_QUEUE_FACTORY="$FSTUB" FACTORY_CALLS="$CALLS"

  s1="$(FACTORY_SESSION=lead-x bash "$AH" ask "needs the owner")"
  assert_eq "session: recorded in the .req" "lead-x" "$(jq -r .session "$QDIR/$s1.req")"
  assert_eq "session: 14d default expiry" "true" "$(jq --argjson now "$(date +%s)" '(.expires | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) as $e | ($e - $now) | (. > 1209000 and . < 1209700)' "$QDIR/$s1.req")"
  s0="$(bash "$AH" ask "no lead")"
  assert_eq "session: absent -> null" "null" "$(jq -c .session "$QDIR/$s0.req")"
  assert_eq "notify: nothing before a result" "0" "$(grep -c . "$CALLS")"
  bash "$AH" resolve "$s1" --as "done" --note "by hand" >/dev/null
  bash "$AH" resolve "$s0" --as "done" >/dev/null
  bash "$AH" list --json >/dev/null; bash "$AH" reap >/dev/null; bash "$AH" list >/dev/null
  assert_eq "notify: exactly one call across repeated sweeps" "1" "$(grep -c . "$CALLS")"
  call="$(cat "$CALLS")"
  assert_contains "notify: session note to the lead" "session note lead-x " "$call"
  assert_contains "notify: --id ask-human-<id>" "--id ask-human-$s1" "$call"
  assert_contains "notify: names the request text" '"needs the owner" was done' "$call"
  assert_contains "notify: carries the note" "by hand" "$call"
  assert_not_contains "notify: no lead -> never called for it" "$s0" "$call"

  # A request that expires notifies too, and a superseded one.
  FACTORY_SESSION=lead-x bash "$AH" ask "will expire" --expires 1s >/dev/null; sleep 2
  bash "$AH" reap >/dev/null
  assert_contains "notify: expiry reported" '"will expire" was denied (expired)' "$(cat "$CALLS")"

  # A synchronous push answer is not re-notified.
  : > "$CALLS"
  s3="$(FACTORY_SESSION=lead-x PATH="$TMP/fakebin:$PATH" HUMAN_QUEUE_PUSH=1 HUMAN_QUEUE_MAC_HOST=local HUMAN_QUEUE_TEST_BUTTON=Deny bash "$AH" ask "pushed" --cmd "echo nope" 2>/dev/null)"; s3="${s3%%$'\n'*}"
  bash "$AH" list --json >/dev/null
  assert_eq "notify: synchronous push result not announced" "0" "$(grep -c . "$CALLS")"
  assert_eq "notify: marker set for it" "yes" "$([[ -e "$QDIR/$s3.notified" ]] && echo yes || echo no)"

  # A failing factory: retried, then given up after 5.
  : > "$CALLS"
  s4="$(FACTORY_SESSION=lead-x bash "$AH" ask "fails to notify")"
  export FACTORY_FAIL=1
  bash "$AH" resolve "$s4" --as denied >/dev/null
  for _ in 1 2 3 4 5 6 7 8; do bash "$AH" reap >/dev/null; done
  unset FACTORY_FAIL
  assert_eq "notify: failing stub gives up after 5 tries" "5" "$(grep -c "ask-human-$s4" "$CALLS")"
  assert_eq "notify: marker set after giving up" "yes" "$([[ -e "$QDIR/$s4.notified" ]] && echo yes || echo no)"
  unset HUMAN_QUEUE_FACTORY FACTORY_CALLS
fi

echo ""
[[ "$fail" -eq 0 ]] \
  && { echo "✓ human-queue: all $pass assertion(s) passed"; exit 0; } \
  || { echo "✗ human-queue: $fail of $((pass + fail)) assertion(s) failed"; exit 1; }
