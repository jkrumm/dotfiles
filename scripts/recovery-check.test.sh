#!/bin/bash
# Hermetic test for recovery-check.sh: the counts from a fixture of hc terminal records (all running, some waiting, no
# label, skipped), hc-resume's last verdict per terminal, no `hc` call unless a launchd-born core answers, the WARN
# threshold and the booted-less-than-45-minutes gate. Stub ps / nc / hc; no live core touched.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail() { echo "recovery-check.test.sh: FAIL: $*" >&2; exit 1; }
eq() { [ "$2" = "$3" ] || fail "$1: expected [$2] got [$3]"; }

mkdir -p "$T/bin"
cat > "$T/bin/nc" <<'S'
#!/bin/bash
[ -z "${SOCK_DOWN:-}" ]
S
cat > "$T/bin/ps" <<'S'
#!/bin/bash
cat "$PS_TABLE"
S
# hc stub: records every call; `connect` answers the fixture as the JSON-RPC result of terminal.list.
cat > "$T/bin/hc" <<'S'
#!/bin/bash
echo "$*" >> "$HC_CALLED"
[ "$1" = connect ] || exit 1
[ -z "${HC_HANG:-}" ] || exec sleep 30
cat > /dev/null
printf '{"jsonrpc":"2.0","id":1,"result":{"terminals":%s,"hidden_finished":0}}\n' "$(cat "$FIXTURE")"
S
# factory stub: records its arguments (one block per call); FACTORY_RC makes it refuse.
cat > "$T/bin/factory" <<'S'
#!/bin/bash
{ printf 'CALL'; printf ' [%s]' "$@"; printf '\n'; } >> "$FACTORY_CALLED"
exit "${FACTORY_RC:-0}"
S
chmod +x "$T/bin/"*
export RECOVERY_FACTORY_BIN="$T/bin/factory" FACTORY_CALLED="$T/factory-called"
export NC_BIN="$T/bin/nc" HC_BIN="$T/bin/hc" PS_BIN="$T/bin/ps" HC_SOCKET="$T/sock" PS_TABLE="$T/table" HC_CALLED="$T/hc-called" \
  FIXTURE="$T/terminals.json" RECOVERY_RESUME_LOG="$T/hc-resume.log" JQ_BIN=/usr/bin/jq
printf '    0 /sbin/launchd\n    1 /x/Herdr Core.app/Contents/MacOS/herdr-core --hc-launchd /tmp/ready\n' > "$T/table"
# shellcheck source=recovery-check.sh
source "$HERE/recovery-check.sh"

# term <address> <label?> <foreground argv json | null | absent> [status.app] [keep] [state]
term() {
  local addr="$1" label="$2" fg="$3" app="${4:-}" keep="${5:-true}" state="${6:-live}" labels='{}' fgj='' st='null'
  [ "$label" = none ] || labels="{\"jk.claude.session\":\"$label\"}"
  [ "$fg" = absent ] || fgj=",\"foreground\":{\"argv\":$fg}"
  [ "$fg" != null ] || fgj=',"foreground":null'
  [ -z "$app" ] || st="{\"app\":\"$app\",\"state\":\"done\"}"
  printf '{"address":"%s","name":"n-%s","state":"%s","keep":%s,"labels":%s,"status":%s%s}' "$addr" "$addr" "$state" "$keep" "$labels" "$st" "$fgj"
}
CLAUDE='["/Users/x/.local/share/claude/versions/2.1.0/claude","--resume","a"]'
LOGIN='["/bin/zsh","-l"]'
fixture() { local IFS=,; echo "[$*]" > "$FIXTURE"; }
measure() { rm -f "$HC_CALLED"; recovery_measure "${1:-0}"; mrc=$?; }
field() { /usr/bin/jq -r "$1" <<<"$RECOVERY_JSON"; }

NOW=$(/bin/date +%s)
BOOT=$((NOW - 1200))
iso() { /bin/date -u -r "$1" +%Y-%m-%dT%H:%M:%S.000Z; }

# 1. all running (a stale foreground that the agent itself reported also counts as running, hc-resume's rule)
fixture "$(term t1 aaaaaaaa-1 "$CLAUDE")" "$(term t2 aaaaaaaa-2 "$CLAUDE")" "$(term t3 aaaaaaaa-3 "$LOGIN" claude-code)"
measure; eq "all running: rc" 0 "$mrc"
eq "all running: counts" "3 3 0 0" "$(field '"\(.resumable) \(.running) \(.waiting) \(.skipped)"')"
eq "all running: line" "recovery: 3 resumable, 3 running claude, 0 waiting, 0 skipped" "$(recovery_line)"

# 2. some waiting (login shell, no agent), one skipped (other program), one unknown foreground
fixture "$(term t1 aaaaaaaa-1 "$CLAUDE")" "$(term t2 aaaaaaaa-2 "$LOGIN")" "$(term t3 aaaaaaaa-3 '["-zsh"]')" \
  "$(term t4 aaaaaaaa-4 '["/usr/bin/vim"]')" "$(term t5 aaaaaaaa-5 null)" "$(term t6 aaaaaaaa-6 absent)"
measure; eq "mixed: counts" "6 1 2 3" "$(field '"\(.resumable) \(.running) \(.waiting) \(.skipped)"')"
eq "mixed: running+waiting+skipped = resumable" "true" "$(field '(.running + .waiting + .skipped) == .resumable')"
eq "mixed: skipped reasons" "foreground is vim|foreground unknown|foreground unknown" "$(field '[.terminals[] | select(.state == "skipped") | .reason] | join("|")')"

# 3. no label, not kept, finished: not resumable at all
fixture "$(term t1 none "$CLAUDE")" "$(term t2 aaaaaaaa-2 "$LOGIN" '' false)" "$(term t3 aaaaaaaa-3 "$LOGIN" '' true finished)" "$(term t4 aaaaaaaa-4 "$LOGIN")"
measure; eq "unlabelled/unkept/finished ignored" "1 0 1 0" "$(field '"\(.resumable) \(.running) \(.waiting) \(.skipped)"')"
fixture; measure; eq "empty roster" "0 0 0 0" "$(field '"\(.resumable) \(.running) \(.waiting) \(.skipped)"')"

# 4. hc-resume verdicts: last one since boot per address; older lines and other boots are ignored
fixture "$(term t1 aaaaaaaa-1 "$CLAUDE")" "$(term t2 aaaaaaaa-2 "$LOGIN")" "$(term t3 aaaaaaaa-3 '["/usr/bin/vim"]')" "$(term t4 aaaaaaaa-4 "$LOGIN")" "$(term t5 aaaaaaaa-5 "$LOGIN")"
{
  echo "$(iso $((BOOT - 3600))) resume t2 aaaaaaaa-2 (iu)"
  echo "$(iso $((BOOT + 100))) resume t1 aaaaaaaa-1 (iu)"
  echo "$(iso $((BOOT + 103))) resume t2 failed: skipped: t2 is no longer at a login shell"
  echo "$(iso $((BOOT + 106))) resume t2 aaaaaaaa-2 (/Users/x/.claude-me)"
  echo "$(iso $((BOOT + 109))) skip t3: unusable session label"
  echo "$(iso $((BOOT + 112))) resume t4 failed: send to t4 timed out after 15000 ms"
  echo "$(iso $((BOOT + 115))) hc-resume started pid=1"
} > "$RECOVERY_RESUME_LOG"
measure "$BOOT"
eq "verdicts: sent count" 2 "$(field '.sent')"
eq "verdict t1" "sent" "$(field '.terminals[] | select(.address == "t1") | .verdict')"
eq "verdict t2: the last line wins" "sent" "$(field '.terminals[] | select(.address == "t2") | .verdict')"
eq "verdict t3: skipped with the log's reason" "skipped:unusable session label" "$(field '.terminals[] | select(.address == "t3") | "\(.verdict):\(.reason)"')"
eq "verdict t4: failed with the message" "failed:send to t4 timed out after 15000 ms" "$(field '.terminals[] | select(.address == "t4") | "\(.verdict):\(.reason)"')"
eq "verdict t5: none" "null" "$(field '.terminals[] | select(.address == "t5") | .verdict')"
measure "$((BOOT + 107))"
eq "since filters earlier lines" "null" "$(field '.terminals[] | select(.address == "t1") | .verdict')"
rm -f "$RECOVERY_RESUME_LOG"; measure "$BOOT"; eq "missing log: measured, no verdicts" "0" "$(field '.sent')"

# 5. core not up: no hc call, rc 1 with the why
printf '    0 /sbin/launchd\n' > "$T/table"; SOCK_DOWN=1 measure "$BOOT"
eq "socket dead: rc" 1 "$mrc"; [ ! -e "$HC_CALLED" ] || fail "hc called while no core answers"
printf '    0 /sbin/launchd\n   55 /usr/bin/herdr-core serve\n    1 /usr/sbin/sshd\n' > "$T/table"; measure "$BOOT"
eq "stray core: rc" 1 "$mrc"; [ ! -e "$HC_CALLED" ] || fail "hc called against a stray core"
case "$RECOVERY_WHY" in *"launchd did not start it"*) ;; *) fail "stray why: $RECOVERY_WHY" ;; esac
printf '    0 /sbin/launchd\n    1 /x/Herdr Core.app/Contents/MacOS/herdr-core --hc-launchd /tmp/ready\n' > "$T/table"

# 6. a wedged hc is bounded; not measured, rc 2
fixture "$(term t1 aaaaaaaa-1 "$CLAUDE")"
start=$SECONDS; HC_HANG=1 RECOVERY_HC_TIMEOUT=1 measure "$BOOT"
eq "hung hc: rc" 2 "$mrc"; [ $((SECONDS - start)) -lt 10 ] || fail "hung hc was not bounded"
eq "hung hc: only one connect, a read verb" "connect" "$(cat "$HC_CALLED")"

# 7. the WARN threshold: ten minutes after tailnet-up, running below resumable
recovery_warn_due 3 3 9999 && fail "all running must not warn"
recovery_warn_due 2 3 599 && fail "9 min after tailnet-up must not warn"
recovery_warn_due 2 3 600 || fail "10 min after tailnet-up must warn"
recovery_warn_due 0 25 3000 || fail "late and short must warn"
recovery_warn_due 2 3 '' && fail "unknown tailnet-up time must not warn"
recovery_warn_due 3 3 600 && fail "running = resumable must not warn"

# 8. the heartbeat sub-check: the 45-minute gate, the knob, the WARN, the snapshot line, the stamp
fixture "$(term t1 aaaaaaaa-1 "$CLAUDE")" "$(term t2 aaaaaaaa-2 "$LOGIN")"
export DEVHOST_SNAPSHOT_LOG="$T/snap.jsonl"
STAMP="$T/tailnet-up-at"
rm -f "$HC_CALLED" "$STAMP" "$DEVHOST_SNAPSHOT_LOG"
out=$(recovery_heartbeat 2700 "$STAMP" 1); rc=$?
eq "booted 45 min ago: silent" "" "$out"; eq "...rc" 0 "$rc"; [ ! -e "$HC_CALLED" ] || fail "hc called past the window"
out=$(recovery_heartbeat 999999 "$STAMP" 1); eq "parse-failure uptime: silent" "" "$out"
out=$(DEVHOST_RECOVERY=0 recovery_heartbeat 300 "$STAMP" 1); eq "knob off: silent" "" "$out"; [ ! -e "$HC_CALLED" ] || fail "hc called with the knob off"
out=$(recovery_heartbeat 2699 "$STAMP" 1); rc=$?
eq "booted 44 min ago: measured" "recovery: 2 resumable, 1 running claude, 1 waiting, 0 skipped" "$out"; eq "...no WARN on the first sight of the tailnet" 0 "$rc"
[ -s "$STAMP" ] || fail "tailnet-up stamp not written"
eq "snapshot line carries the counts" '{"resumable":2,"running":1,"waiting":1,"skipped":0,"sent":0}' "$(/usr/bin/jq -c .recovery "$DEVHOST_SNAPSHOT_LOG")"
# the stamp 11 minutes old, uptime 20 min: WARN, rc 2
echo $((NOW - 660)) > "$STAMP"
out=$(recovery_heartbeat 1200 "$STAMP" 1); rc=$?
eq "WARN rc" 2 "$rc"
case "$out" in "recovery: 2 resumable, 1 running claude, 1 waiting, 0 skipped (WARN: "*"11 min after tailnet-up"*) ;; *) fail "WARN line: $out" ;; esac
eq "second snapshot line" 2 "$(wc -l < "$DEVHOST_SNAPSHOT_LOG" | tr -d ' ')"
# 9 min old: no WARN
echo $((NOW - 540)) > "$STAMP"; out=$(recovery_heartbeat 1200 "$STAMP" 1); rc=$?; eq "9 min: rc" 0 "$rc"
# a stamp from before this boot is replaced, not trusted
echo $((NOW - 5000)) > "$STAMP"; out=$(recovery_heartbeat 1200 "$STAMP" 1); rc=$?; eq "stale stamp: no WARN" 0 "$rc"
[ "$(cat "$STAMP")" -ge $((NOW - 5)) ] || fail "stale stamp not replaced"
# tailnet not Running and no stamp: age unknown, never a WARN
rm -f "$STAMP"; out=$(recovery_heartbeat 1200 "$STAMP" 0); rc=$?; eq "no tailnet: no WARN" 0 "$rc"; [ ! -e "$STAMP" ] || fail "stamp written with the tailnet down"
# everything running: no WARN even late
fixture "$(term t1 aaaaaaaa-1 "$CLAUDE")"; echo $((NOW - 1000)) > "$STAMP"
out=$(recovery_heartbeat 1200 "$STAMP" 1); rc=$?; eq "all running late: rc" 0 "$rc"
# no core: silent, no hc call
rm -f "$HC_CALLED"; out=$(SOCK_DOWN=1 recovery_heartbeat 300 "$STAMP" 1); rc=$?
eq "no core: silent" "" "$out"; eq "no core: rc" 0 "$rc"; [ ! -e "$HC_CALLED" ] || fail "hc called with no core"
# a wedged hc: a line that says so, never a WARN
out=$(HC_HANG=1 RECOVERY_HC_TIMEOUT=1 recovery_heartbeat 300 "$STAMP" 1); rc=$?
eq "hung hc: rc" 0 "$rc"; case "$out" in "recovery: not measured (hc did not answer"*) ;; *) fail "hung hc line: $out" ;; esac

# 8b. the 10-minute escalation (issue 1367): the WARN names the waiting count; waiting terminals file ONE factory signal per boot
fixture "$(term t1 aaaaaaaa-1 "$CLAUDE")" "$(term t2 aaaaaaaa-2 "$LOGIN")" "$(term t3 aaaaaaaa-3 "$LOGIN")" "$(term t4 aaaaaaaa-4 '["/usr/bin/vim"]')"
{
  echo "$(iso $((NOW - 300))) resume t2 aaaaaaaa-2 (iu)"
  echo "$(iso $((NOW - 200))) skip t4: foreground is vim"
} > "$RECOVERY_RESUME_LOG"
STAMP="$T/tailnet-up-at"; SIGSTAMP="$T/recovery-signal-at"
rm -f "$FACTORY_CALLED" "$SIGSTAMP"
echo $((NOW - 540)) > "$STAMP"; out=$(recovery_heartbeat 1200 "$STAMP" 1); rc=$?
eq "9 min waiting: no WARN" 0 "$rc"; [ ! -e "$FACTORY_CALLED" ] || fail "signal filed 9 min after tailnet-up"
echo $((NOW - 660)) > "$STAMP"; out=$(recovery_heartbeat 1200 "$STAMP" 1); rc=$?
eq "11 min waiting: WARN rc" 2 "$rc"
case "$out" in *"WARN: fewer running than resumable, 2 still waiting at a shell 11 min after tailnet-up"*) ;; *) fail "WARN names the count: $out" ;; esac
eq "one signal filed" 1 "$(grep -c "^CALL" "$FACTORY_CALLED")"
call=$(cat "$FACTORY_CALLED")
case "$call" in "CALL [signal] [file] [--from] [agent:dotfiles] [--repo] [dotfiles] [--title] [Claude terminals still waiting at a shell after a boot] [--text] ["*) ;; *) fail "signal arguments: $call" ;; esac
case "$call" in *"2 of 4 resumable Claude terminals are still at a login shell 11 min after the tailnet came up (1 running, 1 skipped)"*) ;; *) fail "signal text counts: $call" ;; esac
[ -s "$SIGSTAMP" ] || fail "signal stamp not written"
# a heartbeat five minutes later: still WARN, no second signal
out=$(recovery_heartbeat 1500 "$STAMP" 1); rc=$?
eq "still WARN" 2 "$rc"; eq "once per boot" 1 "$(grep -c "^CALL" "$FACTORY_CALLED")"
# a stamp left by the previous boot does not count: the next boot files again
echo $((NOW - 5000)) > "$SIGSTAMP"; recovery_heartbeat 1200 "$STAMP" 1 >/dev/null
eq "new boot files again" 2 "$(grep -c "^CALL" "$FACTORY_CALLED")"
# the factory refuses: no stamp, the next heartbeat tries again
rm -f "$SIGSTAMP" "$FACTORY_CALLED"
FACTORY_RC=1 recovery_heartbeat 1200 "$STAMP" 1 >/dev/null; [ ! -e "$SIGSTAMP" ] || fail "stamp written for a refused signal"
recovery_heartbeat 1200 "$STAMP" 1 >/dev/null; eq "retried after a refusal" 2 "$(grep -c "^CALL" "$FACTORY_CALLED")"; [ -s "$SIGSTAMP" ] || fail "stamp missing after the retry"
# nothing waiting (only a skipped terminal short of running): WARN, but no signal
rm -f "$SIGSTAMP" "$FACTORY_CALLED"
fixture "$(term t1 aaaaaaaa-1 "$CLAUDE")" "$(term t4 aaaaaaaa-4 '["/usr/bin/vim"]')"
out=$(recovery_heartbeat 1200 "$STAMP" 1); rc=$?
eq "skipped only: WARN" 2 "$rc"; [ ! -e "$FACTORY_CALLED" ] || fail "signal filed with nothing waiting"
# all running: neither
fixture "$(term t1 aaaaaaaa-1 "$CLAUDE")"; recovery_heartbeat 1200 "$STAMP" 1 >/dev/null; [ ! -e "$FACTORY_CALLED" ] || fail "signal filed with everything running"
rm -f "$RECOVERY_RESUME_LOG" "$FACTORY_CALLED" "$SIGSTAMP"
fixture "$(term t1 aaaaaaaa-1 "$CLAUDE")"

# 8c. not restorable (issue 3160): hc-resume's `not restorable` lines since boot, for tabs still at a login shell without a label
rawterm() { printf '{"address":"%s","name":"n-%s","state":"live","keep":true,"labels":%s,"status":null,"foreground":{"argv":%s}}' "$1" "$1" "$2" "$3"; }
fixture "$(term t1 aaaaaaaa-1 "$CLAUDE")" \
  "$(rawterm t4nn '{"where":"basalt-ui / plan"}' "$LOGIN")" \
  "$(rawterm t5aa '{"where":"basalt-ui / docs"}' '["bun","dev"]')" \
  "$(rawterm t6bb '{"where":"vps / web","jk.resume.cmd":"make dev"}' "$LOGIN")"
{
  echo "$(iso $((BOOT - 3600))) not restorable: t9old a / old node"
  echo "$(iso $((BOOT + 100))) not restorable: t4nn basalt-ui / plan bun"
  echo "$(iso $((BOOT + 101))) not restorable: t5aa basalt-ui / docs bun"
  echo "$(iso $((BOOT + 102))) not restorable: t6bb vps / web make"
  echo "$(iso $((BOOT + 103))) not restorable: t7gone a / gone node"
  echo "$(iso $((BOOT + 104))) not restorable: t4nn basalt-ui / plan bun"
  echo "$(iso $((BOOT - 3500))) not restorable: t4nn basalt-ui / plan yesterday-bun"  # last in the file: it would win if the since filter were gone
} > "$RECOVERY_RESUME_LOG"
measure "$BOOT"
eq "lost: only the tab still at a shell, no label, since boot, once" "t4nn|basalt-ui / plan|bun" "$(field '[.lost[] | "\(.address)|\(.where)|\(.program)"] | join(";")')"
eq "lost: not part of the Claude counts" "1 1 0 0" "$(field '"\(.resumable) \(.running) \(.waiting) \(.skipped)"')"
eq "lost: line counts it" "recovery: 1 resumable, 1 running claude, 0 waiting, 0 skipped, 1 not restorable" "$(recovery_line)"
eq "lost: named per tab" "not restorable: t4nn basalt-ui / plan bun" "$(recovery_lost_lines)"
out=$(bash "$HERE/recovery-check.sh" --since "$BOOT"); eq "lost: cli prints the line and the tab" "recovery: 1 resumable, 1 running claude, 0 waiting, 0 skipped, 1 not restorable
not restorable: t4nn basalt-ui / plan bun" "$out"
rm -f "$RECOVERY_RESUME_LOG"; fixture "$(term t1 aaaaaaaa-1 "$CLAUDE")"; measure "$BOOT"
eq "lost: none without log lines" "0" "$(field '.lost | length')"
eq "lost: line unchanged when none" "recovery: 1 resumable, 1 running claude, 0 waiting, 0 skipped" "$(recovery_line)"

# 9. the CLI: --json, and the not-measured line
out=$(bash "$HERE/recovery-check.sh" --json --since 0); eq "cli json" 1 "$(/usr/bin/jq -r .resumable <<<"$out")"
out=$(bash "$HERE/recovery-check.sh" --since 0); eq "cli line" "recovery: 1 resumable, 1 running claude, 0 waiting, 0 skipped" "$out"
printf '    0 /sbin/launchd\n' > "$T/table"
out=$(bash "$HERE/recovery-check.sh" --since 0); rc=$?; eq "cli not up: rc" 1 "$rc"
case "$out" in "recovery: not measured (a core answers"*|"recovery: not measured (no core answers"*) ;; *) fail "cli not-up line: $out" ;; esac

echo "recovery-check.test.sh: ok"
