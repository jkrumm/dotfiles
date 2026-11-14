#!/usr/bin/env bash
# pg-process-type.test — hermetic: a scratch LaunchAgents dir, a stub launchctl, no host state.
# Proves: brew's stock plist (no ProcessType) gets the key and keeps every other key; a second run changes nothing;
# the old name is found; `check` fails on a reverted file and on a stale loaded job and passes on a good pair.
set -uo pipefail
SUT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pg-process-type.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/pg-process-type-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
export BREW_SERVICE_GUI_DIR="$TMP/agents" PG_PROCESS_TYPE_UID=501 LAUNCHCTL_BIN="$TMP/launchctl"
mkdir -p "$TMP/agents"
cat > "$TMP/launchctl" <<EOS
#!/bin/sh
[ -f "$TMP/spawn" ] || exit 113
printf 'gui/501/sh.brew.postgresql@18 = {\n\tspawn type = %s\n}\n' "\$(cat "$TMP/spawn")"
EOS
chmod +x "$TMP/launchctl"

stock() { # brew's generated plist, as it was before the key (kept by the owner at /tmp/mini-review on 2026-11-14)
  cat > "$TMP/agents/${1:-sh.brew.postgresql@18}.plist" <<'EOP'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>EnvironmentVariables</key><dict><key>LC_ALL</key><string>en_US.UTF-8</string></dict>
<key>ExitTimeOut</key><integer>120</integer>
<key>KeepAlive</key><dict><key>Crashed</key><true/></dict>
<key>Label</key><string>sh.brew.postgresql@18</string>
<key>ProgramArguments</key><array><string>/opt/homebrew/opt/postgresql@18/bin/postgres</string><string>-D</string><string>/opt/homebrew/var/postgresql@18</string></array>
<key>RunAtLoad</key><true/>
<key>WorkingDirectory</key><string>/opt/homebrew</string>
</dict></plist>
EOP
}

fails=0
ok()  { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fails=$((fails + 1)); }
pt() { /usr/libexec/PlistBuddy -c 'Print :ProcessType' "$TMP/agents/sh.brew.postgresql@18.plist" 2>/dev/null; }

echo "pg-process-type"
rm -f "$TMP/spawn"
stock
before=$(plutil -p "$TMP/agents/sh.brew.postgresql@18.plist" | grep -v ProcessType)
out=$(bash "$SUT" check 2>&1); rc=$?
[ "$rc" = 1 ] && ok "check fails on brew's stock plist" || bad "check on stock rc=$rc ($out)"
out=$(bash "$SUT" converge 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(pt)" = Interactive ] && ok "converge pins the key ($out)" || bad "converge rc=$rc type=$(pt) ($out)"
after=$(plutil -p "$TMP/agents/sh.brew.postgresql@18.plist" | grep -v ProcessType)
[ "$before" = "$after" ] && ok "every other key is untouched" || bad "other keys changed"
sum=$(shasum "$TMP/agents/sh.brew.postgresql@18.plist")
out=$(bash "$SUT" converge 2>&1)
[ "$sum" = "$(shasum "$TMP/agents/sh.brew.postgresql@18.plist")" ] && echo "$out" | grep -q "(ok)" && ok "a second converge changes nothing" || bad "converge is not idempotent ($out)"
bash "$SUT" check >/dev/null 2>&1 && ok "check passes on the file with the job not loaded" || bad "check failed on a good file"

echo interactive > "$TMP/spawn"
out=$(bash "$SUT" check 2>&1) && echo "$out" | grep -q "runs interactive" && ok "check passes when the loaded job is interactive" || bad "check on loaded interactive ($out)"
echo daemon > "$TMP/spawn"
out=$(bash "$SUT" check 2>&1); rc=$?
[ "$rc" = 1 ] && echo "$out" | grep -q "still runs 'daemon'" && ok "check fails while the loaded job is stale (daemon)" || bad "check on stale loaded rc=$rc ($out)"
out=$(bash "$SUT" converge 2>&1); rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -q "still runs 'daemon'" && ok "converge only notes a stale loaded job" || bad "converge on stale loaded rc=$rc ($out)"

rm -f "$TMP/spawn" "$TMP/agents/"*
stock homebrew.mxcl.postgresql@18
bash "$SUT" converge >/dev/null 2>&1 && [ "$(/usr/libexec/PlistBuddy -c 'Print :ProcessType' "$TMP/agents/homebrew.mxcl.postgresql@18.plist")" = Interactive ] && ok "the pre-Homebrew-6 plist name is found" || bad "old plist name not handled"

rm -f "$TMP/agents/"*
bash "$SUT" converge >/dev/null 2>&1 && bash "$SUT" check >/dev/null 2>&1 && ok "no postgres service here: nothing to do, not a failure" || bad "absent service failed"

[ "$fails" = 0 ] && echo "ok" || { echo "$fails failed"; exit 1; }
