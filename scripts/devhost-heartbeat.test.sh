#!/usr/bin/env bash
# devhost-heartbeat.test.sh — the bounded run, the composite budget, the side-monitors-first order and the
# exit semantics of devhost-health-check.sh, end to end with a stub `curl` first on PATH (records every
# push) and stub tool binaries. DEVHOST_COMPONENTS narrows the composite to the components under test.
# Usage: scripts/devhost-heartbeat.test.sh   (exit 0 = all pass)
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0; fail=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; [[ -n "${2:-}" ]] && printf '         %s\n' "$2"; fail=$((fail + 1)); }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
assert_contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "[$3] does not contain [$2]" ;; esac; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/devhost-heartbeat-test.XXXXXX")" || exit 2
cleanup() {
  # Only the sleepers this test's stub recorded, by pid; never a pattern kill.
  [[ -f "$TMP/sleeper.pids" ]] && while read -r p; do kill -KILL "$p" 2>/dev/null; done < "$TMP/sleeper.pids"
  rm -rf "$TMP"
}
trap cleanup EXIT
mkdir -p "$TMP/bin" "$TMP/state"

# curl stub: records the full arg list of every call; STUB_CURL_FAIL=1 fails like a refused push.
cat > "$TMP/bin/curl" <<STUB
#!/bin/sh
echo "\$*" >> "$TMP/curl.log"
case "\$*" in *api/push/composite*) date +%s >> "$TMP/liveness.ts" ;; esac
case "\$*" in *api/push/*) ;; *7793*)
  # STUB_FACTORY_DOWN=1: refused every time; =N>1: refused the first N-1 calls, then answers (a restart gap).
  if [ "\${STUB_FACTORY_DOWN:-0}" != 0 ]; then
    n=\$(cat "$TMP/factory.calls" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "$TMP/factory.calls"
    if [ "\${STUB_FACTORY_DOWN}" = 1 ] || [ "\$n" -lt "\${STUB_FACTORY_DOWN}" ]; then exit 7; fi
  fi
  echo '{"heartbeat":{"ok":true,"tickAt":"t","queueMovedAt":"q"}}'; exit 0 ;; esac
[ "\${STUB_CURL_FAIL:-0}" = 1 ] && exit 22
exit 0
STUB
# obsidian stub: version answers, or hangs (and leaves a grandchild sleeper) when STUB_OBSIDIAN_HANG=1.
cat > "$TMP/obsidian" <<STUB
#!/bin/sh
if [ "\${STUB_OBSIDIAN_HANG:-0}" = 1 ]; then
  sh -c 'echo \$\$ >> "$TMP/sleeper.pids"; exec sleep 300' &
  sleep 300
fi
echo 1.0.0
STUB
# drift stub: counts its runs; STUB_DRIFT_HANG=1 hangs (with a grandchild sleeper) like a stuck network call.
cat > "$TMP/drift-stub.sh" <<STUB
#!/bin/bash
echo run >> "$TMP/drift.runs"
if [ "\${STUB_DRIFT_HANG:-0}" = 1 ]; then
  sh -c 'echo \$\$ >> "$TMP/sleeper.pids"; exec sleep 300' &
  sleep 300
fi
exit 0
STUB
chmod +x "$TMP/bin/curl" "$TMP/obsidian"
printf 'http://kuma.invalid/api/push/composite\n' > "$TMP/composite-url"
printf 'http://kuma.invalid/api/push/detail\n' > "$TMP/detail-url"
printf 'http://kuma.invalid/api/push/collie\n' > "$TMP/collie-url"
printf 'http://kuma.invalid/api/push/factory\n' > "$TMP/factory-url"

# run_script <env assignments...> — runs the real script; sets RC and ELAPSED (output in $TMP/out.log).
run_script() {
  : > "$TMP/curl.log"
  local t0=$SECONDS
  env PATH="$TMP/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    DEVHOST_HEALTH_STATE_DIR="$TMP/state" \
    DEVHOST_PUSH_URL_FILE="$TMP/composite-url" DEVHOST_DETAIL_PUSH_URL_FILE="$TMP/detail-url" \
    DEVHOST_LIVENESS="" \
    COLLIE_PUSH_URL_FILE="$TMP/collie-url" COLLIE_PLIST="$TMP/none.plist" \
    FACTORY_PUSH_URL_FILE="$TMP/factory-url" FACTORY_HEALTH_URL="http://127.0.0.1:7793/health" \
    SECRETS_FRESHNESS_PUSH_URL_FILE="$TMP/none-secrets-url" \
    CURL_BIN="$TMP/bin/curl" JQ_BIN=/usr/bin/jq \
    DEVHOST_DRIFT_CHECK_BIN="$TMP/none-drift.sh" \
    OBSIDIAN_BIN="$TMP/obsidian" TAILSCALE_BIN=/usr/bin/false \
    DEVHOST_TRANSIENT_FAILS=1 DEVHOST_BOOT_GRACE_SECONDS=0 \
    "$@" /bin/bash "$HERE/devhost-health-check.sh" >"$TMP/out.log" 2>&1
  RC=$?
  ELAPSED=$(( SECONDS - t0 ))
}
pushes() { /usr/bin/grep -c 'api/push/' "$TMP/curl.log"; }

echo "healthy components: one up push, exit 0"
run_script DEVHOST_COMPONENTS="check_obsidian"
assert_eq "exit 0" 0 "$RC"
assert_contains "composite pushed up" "status=up" "$(/usr/bin/grep 'push/detail' "$TMP/curl.log")"

echo "a hung tool fails only its own component, the push still goes out"
run_script DEVHOST_COMPONENTS="check_obsidian check_agents_md_flag" DEVHOST_COMPONENT_TIMEOUT=1 STUB_OBSIDIAN_HANG=1
composite=$(/usr/bin/grep 'push/detail' "$TMP/curl.log")
assert_contains "push is down" "status=down" "$composite"
assert_contains "msg names the component and the timeout" "check_obsidian timed out after 1s" "$composite"
assert_eq "a DOWN verdict that was delivered exits 0" 0 "$RC"
(( ELAPSED < 20 )) && ok "bounded runtime (${ELAPSED}s)" || bad "bounded runtime" "took ${ELAPSED}s"
# side monitors push independently, before the composite, even when a composite component hangs (same run)
assert_eq "liveness + collie + factory + composite summary + detail = 5 pushes" 5 "$(pushes)"
order=$(/usr/bin/grep -o 'push/[a-z]*' "$TMP/curl.log" | /usr/bin/tr '\n' ' ')
assert_eq "liveness first, side monitors next, detail last" "push/composite push/collie push/factory push/detail push/composite " "$order"
assert_contains "the hung component does not turn the composite DOWN" "status=up" "$(/usr/bin/grep 'push/composite' "$TMP/curl.log" | /usr/bin/tail -1)"
assert_contains "factory relayed up" "status=up" "$(/usr/bin/grep 'push/factory' "$TMP/curl.log")"
left=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  left=0
  if [[ -f "$TMP/sleeper.pids" ]]; then
    while read -r p; do kill -0 "$p" 2>/dev/null && left=$((left + 1)); done < "$TMP/sleeper.pids"
  fi
  (( left == 0 )) && break
  sleep 0.1
done
assert_eq "no grandchild sleeper survives the group kill" 0 "$left"

echo "check_claude_auth has its own, wider bound (a slow claude cold start is not a hang)"
cat > "$TMP/claude-slow" <<STUB
#!/bin/sh
sleep 3
echo '{"loggedIn":true,"subscriptionType":"max"}'
STUB
chmod +x "$TMP/claude-slow"
run_script DEVHOST_COMPONENTS="check_claude_auth" DEVHOST_COMPONENT_TIMEOUT=1 DEVHOST_CLAUDE_AUTH_TIMEOUT=15 \
  DEVHOST_SLOW_COMPONENT_LOG=2 CLAUDE_BIN="$TMP/claude-slow" DEVHOST_CLAUDE_ACCOUNTS_REGISTRY="$TMP/none-registry.json"
composite=$(/usr/bin/grep 'push/detail' "$TMP/curl.log")
assert_contains "slow auth probe still reads as up" "status=up" "$composite"
assert_contains "slow component is named in the local log" "slow component: check_claude_auth took" "$(/bin/cat "$TMP/out.log")"
run_script DEVHOST_COMPONENTS="check_claude_auth" DEVHOST_COMPONENT_TIMEOUT=1 DEVHOST_CLAUDE_AUTH_TIMEOUT=1 \
  CLAUDE_BIN="$TMP/claude-slow" DEVHOST_CLAUDE_ACCOUNTS_REGISTRY="$TMP/none-registry.json"
assert_contains "past its own bound it still fails as a hung tool" "check_claude_auth timed out after 1s" "$(/usr/bin/grep 'push/detail' "$TMP/curl.log")"

echo "budget exhaustion: remaining components are not run, still graded, the push still goes out"
run_script DEVHOST_COMPONENTS="check_obsidian check_agents_md_flag" DEVHOST_COMPONENT_TIMEOUT=30 DEVHOST_HEARTBEAT_BUDGET=1 STUB_OBSIDIAN_HANG=1
composite=$(/usr/bin/grep 'push/detail' "$TMP/curl.log")
assert_contains "push is down" "status=down" "$composite"
assert_contains "later component not run" "check_agents_md_flag not run (heartbeat budget spent)" "$composite"
(( ELAPSED < 20 )) && ok "bounded runtime (${ELAPSED}s)" || bad "bounded runtime" "took ${ELAPSED}s"
run_script DEVHOST_COMPONENTS="check_obsidian" DEVHOST_HEARTBEAT_BUDGET=0
assert_contains "zero budget runs nothing" "check_obsidian not run (heartbeat budget spent)" "$(/usr/bin/grep 'push/detail' "$TMP/curl.log")"

echo "exit 1 only when a push was not delivered"
run_script DEVHOST_COMPONENTS="check_obsidian" STUB_CURL_FAIL=1
assert_eq "failed push exits 1" 1 "$RC"
run_script DEVHOST_COMPONENTS="check_obsidian" DEVHOST_PUSH_URL_FILE="$TMP/missing-url"
assert_eq "no push URL exits 1" 1 "$RC"
assert_eq "...and pushes nothing" 0 "$(pushes)"

echo "drift: runs once after the composite, the stamp holds it back for 20 h"
rm -f "$TMP/drift.runs" "$TMP/state/drift-last-run"
runs() { if [[ -f "$TMP/drift.runs" ]]; then /usr/bin/wc -l < "$TMP/drift.runs" | /usr/bin/tr -d ' '; else echo 0; fi; }
run_script DEVHOST_COMPONENTS="check_obsidian" DEVHOST_DRIFT_CHECK_BIN="$TMP/drift-stub.sh"
assert_eq "first run executes drift" 1 "$(runs)"
assert_eq "exit 0" 0 "$RC"
[[ -f "$TMP/state/drift-last-run" ]] && ok "stamp written" || bad "stamp written"
run_script DEVHOST_COMPONENTS="check_obsidian" DEVHOST_DRIFT_CHECK_BIN="$TMP/drift-stub.sh"
assert_eq "second run within 20 h skips drift" 1 "$(runs)"
touch -t 200001010000 "$TMP/state/drift-last-run"
run_script DEVHOST_COMPONENTS="check_obsidian" DEVHOST_DRIFT_CHECK_BIN="$TMP/drift-stub.sh"
assert_eq "an old stamp runs drift again" 2 "$(runs)"

echo "drift: a hung script is killed at its timeout, the heartbeat still exits 0, the retry comes in ~1 h"
rm -f "$TMP/state/drift-last-run"
run_script DEVHOST_COMPONENTS="check_obsidian" DEVHOST_DRIFT_CHECK_BIN="$TMP/drift-stub.sh" DEVHOST_DRIFT_TIMEOUT=1 STUB_DRIFT_HANG=1
assert_eq "hung drift: heartbeat exits 0" 0 "$RC"
assert_contains "timeout is logged" "drift-check timed out after 1s" "$(cat "$TMP/out.log")"
assert_contains "composite still pushed" "status=up" "$(/usr/bin/grep 'push/detail' "$TMP/curl.log")"
(( ELAPSED < 20 )) && ok "bounded runtime (${ELAPSED}s)" || bad "bounded runtime" "took ${ELAPSED}s"
age=$(( $(date +%s) - $(stat -f %m "$TMP/state/drift-last-run") ))
(( age >= 68000 && age <= 69000 )) && ok "timed-out run is stamped to retry in ~1 h" || bad "retry stamp" "age ${age}s"
run_script DEVHOST_COMPONENTS="check_obsidian" DEVHOST_DRIFT_CHECK_BIN="$TMP/drift-stub.sh" DEVHOST_DRIFT_TIMEOUT=2
assert_eq "no retry before the hour is up" 3 "$(runs)"

echo "check_claude_auth wired through the real script: composite verdict and message"
cat > "$TMP/claude" <<'STUB'
#!/bin/sh
if [ "${STUB_CLAUDE_DEAD:-0}" = 1 ]; then echo '{"loggedIn":false}'; else echo '{"loggedIn":true,"subscriptionType":"max"}'; fi
STUB
printf '#!/bin/sh\nexit 1\n' > "$TMP/secrets-run"
printf '#!/bin/sh\necho %s\n' "'{\"accounts\":[{\"id\":\"iu\",\"severity\":\"PASS\",\"detail\":\"login valid\"}]}'" > "$TMP/ca"
echo '{"accounts":{"iu":{"dir":null,"enabled":true}}}' > "$TMP/registry.json"
chmod +x "$TMP/claude" "$TMP/secrets-run" "$TMP/ca"
run_script DEVHOST_COMPONENTS="check_claude_auth" CLAUDE_BIN="$TMP/claude" SECRETS_RUN_BIN="$TMP/secrets-run" \
  DEVHOST_CLAUDE_ACCOUNT_BIN="$TMP/ca" DEVHOST_CLAUDE_ACCOUNTS_REGISTRY="$TMP/registry.json"
composite=$(/usr/bin/grep 'push/detail' "$TMP/curl.log")
assert_contains "logged in: push is up" "status=up" "$composite"
assert_contains "logged in: message" "claude auth ok (max)" "$composite"
run_script DEVHOST_COMPONENTS="check_claude_auth" CLAUDE_BIN="$TMP/claude" SECRETS_RUN_BIN="$TMP/secrets-run" \
  DEVHOST_CLAUDE_ACCOUNT_BIN="$TMP/ca" DEVHOST_CLAUDE_ACCOUNTS_REGISTRY="$TMP/registry.json" STUB_CLAUDE_DEAD=1
composite=$(/usr/bin/grep 'push/detail' "$TMP/curl.log")
assert_contains "dead login, dead token: push is down" "status=down" "$composite"
assert_contains "dead login: message" "billing API credits" "$composite"

echo "check_memory: parked swap is a WARN, only a leak-sized share FAILs; fseventsd over the limit is named"
cat > "$TMP/sysctl" <<'STUB'
#!/bin/sh
case "$*" in
  *pressure_level*) echo "${STUB_PRESSURE:-1}" ;;
  *swapusage*) echo "total = 40960.00M  used = ${STUB_SWAP_MB:-100}.00M  free = 1.00M  (encrypted)" ;;
  *memsize*) echo 34359738368 ;;
esac
STUB
printf '#!/bin/sh\n[ "${STUB_FSEVENTSD:-0}" = 0 ] && exit 1\necho 551\n' > "$TMP/pgrep"
printf '#!/bin/sh\necho "MEM"\necho "${STUB_FSEVENTSD_MEM:-4544K}"\n' > "$TMP/top"
chmod +x "$TMP/sysctl" "$TMP/pgrep" "$TMP/top"
mem_run() { run_script DEVHOST_COMPONENTS="check_memory" SYSCTL_BIN="$TMP/sysctl" PGREP_BIN="$TMP/pgrep" TOP_BIN="$TMP/top" "$@"; composite=$(/usr/bin/grep 'push/detail' "$TMP/curl.log"); }
mem_run STUB_SWAP_MB=100 STUB_FSEVENTSD=1
assert_contains "idle host, small fseventsd: up" "status=up" "$composite"
mem_run STUB_SWAP_MB=9300
assert_contains "28% swap, pressure normal: still up (WARN)" "status=up" "$composite"
assert_contains "28% swap: WARN text" "parked pages" "$composite"
mem_run STUB_SWAP_MB=30000
assert_contains "87% swap: down" "status=down" "$composite"
mem_run STUB_SWAP_MB=100 STUB_FSEVENTSD=1 STUB_FSEVENTSD_MEM=61G
assert_contains "fseventsd 61G: up (WARN), not a page" "status=up" "$composite"
assert_contains "fseventsd 61G: named with the fix" "fseventsd holds 61G" "$composite"
assert_contains "fseventsd 61G: killall, not kickstart" "sudo killall fseventsd" "$composite"
mem_run STUB_SWAP_MB=100 STUB_FSEVENTSD=1 STUB_FSEVENTSD_MEM=9G
assert_eq "fseventsd 9G: no note" 0 "$(printf '%s' "$composite" | /usr/bin/grep -c 'fseventsd holds')"

echo "factory monitor: a deploy restart gap does not page, a server that stays down does"
factory_run() { rm -f "$TMP/factory.calls"; run_script DEVHOST_COMPONENTS="check_obsidian" FACTORY_PROBE_PAUSE=0 \
  DEVHOST_DELIBERATE_RESTART_DIR="$TMP/restart-marks" "$@"; factory_push=$(/usr/bin/grep 'push/factory' "$TMP/curl.log"); }
mkdir -p "$TMP/restart-marks"
factory_run STUB_FACTORY_DOWN=3
assert_contains "gap shorter than the retries: up" "status=up" "$factory_push"
assert_eq "answered on the 3rd probe" 3 "$(cat "$TMP/factory.calls")"
factory_run STUB_FACTORY_DOWN=1
assert_contains "down with no mark: pages" "status=down" "$factory_push"
assert_contains "down names the tries" "3 tries" "$factory_push"
assert_eq "retried 3 times" 3 "$(cat "$TMP/factory.calls")"
date +%s > "$TMP/restart-marks/com.jkrumm.software-factory"
factory_run STUB_FACTORY_DOWN=1
assert_contains "fresh mark: restarting, up" "status=up" "$factory_push"
assert_contains "fresh mark: says restarting" "restarting" "$factory_push"
assert_eq "fresh mark: no retry wait" 1 "$(cat "$TMP/factory.calls")"
assert_eq "mark is read only, not consumed" 1 "$(wc -l < "$TMP/restart-marks/com.jkrumm.software-factory" | tr -d ' ')"
echo $(( $(date +%s) - 3600 )) > "$TMP/restart-marks/com.jkrumm.software-factory"
factory_run STUB_FACTORY_DOWN=1
assert_contains "stale mark: pages" "status=down" "$factory_push"
rm -f "$TMP/restart-marks/com.jkrumm.software-factory"

echo "liveness first: a hung slow component never delays or downgrades the liveness push (acceptance)"
# DEVHOST_LIVENESS names the dead-machine checks; the stub netstat makes sshd listen.
printf '#!/bin/sh\necho "tcp4  0  0  *.22  *.*  LISTEN"\n' > "$TMP/netstat-ok"
printf '#!/bin/sh\nexit 0\n' > "$TMP/netstat-dead"
chmod +x "$TMP/netstat-ok" "$TMP/netstat-dead"
# check_sshd calls /usr/sbin/netstat by absolute path, so the liveness stub is a function the test injects:
cat > "$TMP/liveness-lib.sh" <<'STUB'
liveness_stub_ok() { echo "stub alive"; }
liveness_stub_dead() { echo "stub dead"; return 1; }
liveness_stub_slow() { /bin/sleep 30; }
STUB
run_script DEVHOST_LIVENESS="liveness_stub_ok" DEVHOST_TEST_LIB="$TMP/liveness-lib.sh" DEVHOST_COMPONENTS="check_obsidian check_agents_md_flag" \
  DEVHOST_COMPONENT_TIMEOUT=1 STUB_OBSIDIAN_HANG=1
first=$(/usr/bin/grep 'api/push/' "$TMP/curl.log" | /usr/bin/head -1)
assert_contains "the FIRST push is the liveness push" "push/composite?" "$(printf '%s?' "$first")"
assert_contains "liveness push is up" "status=up" "$first"
assert_contains "liveness msg" "stub alive" "$first"
mapfile_like=$(/usr/bin/grep 'push/composite' "$TMP/curl.log" | /usr/bin/tail -1)
assert_contains "second composite push carries the detail, still up" "check_obsidian timed out after 1s" "$mapfile_like"
assert_contains "second composite push is up" "status=up" "$mapfile_like"
assert_contains "detail monitor is the one that goes down" "status=down" "$(/usr/bin/grep 'push/detail' "$TMP/curl.log")"
assert_eq "no composite push is ever down" 0 "$(/usr/bin/grep 'push/composite' "$TMP/curl.log" | /usr/bin/grep -c 'status=down')"

echo "liveness: the push lands within 20 s while a slow component is still hanging"
# A component that outlives the whole run: the liveness push is already out before it starts.
rm -f "$TMP/liveness.ts"
t0=$(date +%s)
run_script DEVHOST_LIVENESS="liveness_stub_ok" DEVHOST_TEST_LIB="$TMP/liveness-lib.sh" DEVHOST_COMPONENTS="check_obsidian" \
  DEVHOST_COMPONENT_TIMEOUT=6 STUB_OBSIDIAN_HANG=1
tl=$(/usr/bin/head -1 "$TMP/liveness.ts" 2>/dev/null || echo 0)
(( tl > 0 && tl - t0 <= 3 )) && ok "liveness push landed $(( tl - t0 )) s after the start, the hang ran 6 s" || bad "liveness push timing" "first composite push at +$(( tl - t0 )) s"

echo "liveness: only a dead-machine check failing pushes down"
run_script DEVHOST_LIVENESS="liveness_stub_dead" DEVHOST_TEST_LIB="$TMP/liveness-lib.sh" DEVHOST_COMPONENTS="check_agents_md_flag"
first=$(/usr/bin/grep 'api/push/' "$TMP/curl.log" | /usr/bin/head -1)
assert_contains "dead machine: liveness push is down" "status=down" "$first"
assert_contains "dead machine: names the check" "stub dead" "$first"
assert_eq "dead machine: the detail push does not overwrite DOWN with up" 0 "$(/usr/bin/grep 'push/composite' "$TMP/curl.log" | /usr/bin/grep -c 'status=up')"
assert_eq "dead machine: exit 0 (delivered verdict)" 0 "$RC"
run_script DEVHOST_LIVENESS="liveness_stub_dead" DEVHOST_TEST_LIB="$TMP/liveness-lib.sh" DEVHOST_COMPONENTS="check_agents_md_flag" \
  DEVHOST_TRANSIENT_FAILS=3
assert_contains "below the streak: still up, degraded" "status=up" "$(/usr/bin/grep 'api/push/' "$TMP/curl.log" | /usr/bin/head -1)"
echo "liveness: a check that times out is slow, not dead (needs the long streak)"
rm -f "$TMP/state"/fail-*
run_script DEVHOST_LIVENESS="liveness_stub_slow" DEVHOST_TEST_LIB="$TMP/liveness-lib.sh" DEVHOST_COMPONENTS="check_agents_md_flag" \
  DEVHOST_LIVENESS_STEP_TIMEOUT=1
first=$(/usr/bin/grep 'api/push/' "$TMP/curl.log" | /usr/bin/head -1)
assert_contains "timeout under the long streak: up" "status=up" "$first"
assert_contains "timeout is named as slow" "timed out after 1s" "$first"
rm -f "$TMP/state"/fail-*
run_script DEVHOST_LIVENESS="liveness_stub_slow" DEVHOST_TEST_LIB="$TMP/liveness-lib.sh" DEVHOST_COMPONENTS="check_agents_md_flag" \
  DEVHOST_LIVENESS_STEP_TIMEOUT=1 DEVHOST_LIVENESS_TIMEOUT_STREAK=1
assert_contains "timeout past the long streak: down" "status=down" "$(/usr/bin/grep 'api/push/' "$TMP/curl.log" | /usr/bin/head -1)"
rm -f "$TMP/state"/fail-*

echo "liveness: the real tailnet / sshd / core checks grade without blocking"
run_script DEVHOST_LIVENESS="liveness_tailnet" DEVHOST_COMPONENTS="check_agents_md_flag"
assert_contains "tailscale stub /usr/bin/false: dead tailnet pushes down" "status=down" "$(/usr/bin/grep 'api/push/' "$TMP/curl.log" | /usr/bin/head -1)"
assert_contains "...and says why" "tailscaled not Running" "$(/usr/bin/grep 'api/push/' "$TMP/curl.log" | /usr/bin/head -1)"

echo "the default component list only names functions the script or its libs define"
list=$(/usr/bin/awk '/^components="\$\{DEVHOST_COMPONENTS:-/{f=1} f{print} f&&/\}"$/{exit}' "$HERE/devhost-health-check.sh" | /usr/bin/sed -e 's/^components="${DEVHOST_COMPONENTS:-//' -e 's/}"$//' -e 's/\\$//')
[[ -n "$list" ]] && ok "default list found" || bad "default list found"
for name in $list; do
  if /usr/bin/grep -q "^${name}()" "$HERE/devhost-health-check.sh" "$HERE"/lib/*.sh; then ok "$name is defined"; else bad "$name is defined" "no ^${name}() in the script or lib/*.sh"; fi
done

echo
echo "passed: $pass, failed: $fail"
(( fail == 0 ))
