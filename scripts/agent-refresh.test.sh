#!/usr/bin/env bash
# agent-refresh.test — hermetic: stubbed launchctl/ps, scratch files and marker dir.
# Proves: changed file after start -> kickstart + marker; unchanged -> nothing;
# not running -> nothing; herdr-core refused; missing file fails; etime forms parse.
set -uo pipefail
SUT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/agent-refresh.sh"
[ -f "$SUT" ] || { echo "✗ $SUT not found"; exit 1; }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/agent-refresh-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/launchctl" <<EOS
#!/bin/sh
case "\$1" in
  print) cat "$TMP/print" ;;
  kickstart) echo "\$@" >> "$TMP/kicks"; exit \${KICK_RC:-0} ;;
esac
EOS
cat > "$TMP/ps" <<EOS
#!/bin/sh
cat "$TMP/etime"
EOS
chmod +x "$TMP/launchctl" "$TMP/ps"
export LAUNCHCTL_BIN="$TMP/launchctl" PS_BIN="$TMP/ps" AGENT_REFRESH_UID=501
export DEVHOST_DELIBERATE_RESTART_DIR="$TMP/markers"
LABEL=com.example.svc
FILE="$TMP/prog.ts"; DEP="$TMP/dep.ts"

fails=0
ok()  { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fails=$((fails + 1)); }

# run NAME PID_LINE ETIME FILE_AGE_SECS WANT_RC WANT_KICKS [WANT_MARKS]
run() {
  local name=$1 pidline=$2 et=$3 age=$4 want=$5 kicks=$6 marks=${7:-$6} out rc nk nm
  rm -rf "$TMP/kicks" "$TMP/markers"
  { echo "$LABEL = {"; [ -n "$pidline" ] && echo "	pid = $pidline"; echo "}"; } > "$TMP/print"
  echo "  $et" > "$TMP/etime"
  : > "$FILE"; : > "$DEP"
  touch -t "$(date -v-"${age}"S +%Y%m%d%H%M.%S)" "$FILE"
  touch -t "$(date -v-400000S +%Y%m%d%H%M.%S)" "$DEP"
  rc=0; out=$(bash "$SUT" "${LABEL_OVERRIDE:-$LABEL}" "$FILE" "$DEP" 2>&1) || rc=$?
  nk=0; [ -f "$TMP/kicks" ] && nk=$(wc -l < "$TMP/kicks" | tr -d ' ')
  nm=0; [ -f "$TMP/markers/$LABEL" ] && nm=$(wc -l < "$TMP/markers/$LABEL" | tr -d ' ')
  if [ "$rc" = "$want" ] && [ "$nk" = "$kicks" ] && [ "$nm" = "$marks" ]; then ok "$name → rc=$rc kicks=$nk marks=$nm"
  else bad "$name → rc=$rc kicks=$nk marks=$nm, want rc=$want kicks=$kicks marks=$marks ($out)"; fi
}

echo "agent-refresh"
run "file changed after start (started 1h ago, edited 10m ago)" 123 "01:00:00" 600 0 1
run "file older than the process"                              123 "00:10:00" 3600 0 0
run "days-form etime, edited after start"                      123 "2-03:00:00" 600 0 1
run "days-form etime, file older"                              123 "2-03:00:00" 200000 0 0
run "mm:ss etime, edited 30 s ago, started 5 min ago"          123 "05:00" 30 0 1
run "not running (no pid)"                                     ""  "00:10" 5 0 0
run "unreadable etime is left alone"                           123 "garbage" 5 0 0

LABEL_OVERRIDE=com.jkrumm.herdr-core run "herdr-core is never refreshed" 123 "01:00:00" 600 2 0
unset LABEL_OVERRIDE

rm -rf "$TMP/kicks" "$TMP/markers"
echo "	pid = 1" > "$TMP/print"; echo "01:00:00" > "$TMP/etime"
rc=0; bash "$SUT" "$LABEL" "$TMP/nope.ts" >/dev/null 2>&1 || rc=$?
[ "$rc" = 1 ] && [ ! -f "$TMP/kicks" ] && ok "missing program file fails, no kick" || bad "missing file: rc=$rc"

: > "$FILE"; touch -t "$(date -v-60S +%Y%m%d%H%M.%S)" "$FILE"
rc=0; KICK_RC=1 bash "$SUT" "$LABEL" "$FILE" >/dev/null 2>&1 || rc=$?
[ "$rc" = 1 ] && ok "failed kickstart exits 1" || bad "failed kickstart: rc=$rc"

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed"; exit 1
