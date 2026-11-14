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
mkdir -p "$TMP/bin" "$TMP/state" "$TMP/diag" "$TMP/vm"
printf '#!/bin/sh\necho stub-token\n' > "$TMP/secrets-run-default"; chmod +x "$TMP/secrets-run-default"

# curl stub: records the full arg list of every call; STUB_CURL_FAIL=1 fails like a refused push.
cat > "$TMP/bin/curl" <<STUB
#!/bin/sh
echo "\$*" >> "$TMP/curl.log"
case "\$*" in *api/push/composite*) date +%s >> "$TMP/liveness.ts" ;; esac
[ "\${STUB_NTFY_FAIL:-0}" = 1 ] && case "\$*" in *ntfy.invalid*) exit 22 ;; esac
case "\$*" in *api/push/*) ;; *7793*)
  # STUB_FACTORY_DOWN=1: refused every time; =N>1: refused the first N-1 calls, then answers (a restart gap).
  if [ "\${STUB_FACTORY_DOWN:-0}" != 0 ]; then
    n=\$(cat "$TMP/factory.calls" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "$TMP/factory.calls"
    if [ "\${STUB_FACTORY_DOWN}" = 1 ] || [ "\$n" -lt "\${STUB_FACTORY_DOWN}" ]; then exit 7; fi
  fi
  echo '{"heartbeat":{"ok":true,"tickAt":"t","queueMovedAt":"q"}}'; exit 0 ;; esac
[ "\${STUB_CURL_FAIL:-0}" = 1 ] && exit 22
# STUB_CURL_TIMEOUT=once: the first push call times out (rc 28), later ones answer; =always: every push call does.
case "\$*" in *api/push/*)
  if [ "\${STUB_CURL_TIMEOUT:-0}" != 0 ]; then
    n=\$(cat "$TMP/timeout.calls" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "$TMP/timeout.calls"
    if [ "\${STUB_CURL_TIMEOUT}" = always ] || [ "\$n" = 1 ]; then exit 28; fi
  fi ;; esac
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
    DEVHOST_DIAGNOSTIC_REPORTS_DIR="$TMP/diag" DEVHOST_SNAPSHOT_LOG="$TMP/snapshots.jsonl" DEVHOST_SWAP_DIR="$TMP/vm" \
    NTFY_URL="http://ntfy.invalid" NTFY_CONFIG="$TMP/none-ntfy.yml" SECRETS_RUN_BIN="$TMP/secrets-run-default" \
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

echo "exit 75 (undelivered) only when a push was not delivered; exit 1 when no push URL resolves"
run_script DEVHOST_COMPONENTS="check_obsidian" STUB_CURL_FAIL=1
assert_eq "failed push exits 75" 75 "$RC"
run_script DEVHOST_COMPONENTS="check_obsidian" DEVHOST_PUSH_URL_FILE="$TMP/missing-url"
assert_eq "no push URL exits 1" 1 "$RC"
assert_eq "...and pushes nothing" 0 "$(pushes)"

echo "a push that times out once is retried: exit 0; a dead Kuma still exits 75 and retries only once"
rm -f "$TMP/timeout.calls"
run_script DEVHOST_COMPONENTS="check_obsidian" STUB_CURL_TIMEOUT=once
assert_eq "one timed-out push is absorbed by the retry" 0 "$RC"
base=$(( $(pushes) - 1 ))
rm -f "$TMP/timeout.calls"
run_script DEVHOST_COMPONENTS="check_obsidian" STUB_CURL_TIMEOUT=always
assert_eq "Kuma down: exit 75" 75 "$RC"
assert_eq "Kuma down: one retry in the whole run, not one per push" $(( base + 1 )) "$(pushes)"

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

echo "snapshot: one compact JSON line per run, appended, with the fields a hang needs"
rm -f "$TMP/snapshots.jsonl" "$TMP/vm"/*; : > "$TMP/vm/swapfile0"; : > "$TMP/vm/swapfile1"
run_script DEVHOST_COMPONENTS="check_obsidian" DEVHOST_TEST_UPTIME_S=7200
assert_eq "one line after one run" 1 "$(wc -l < "$TMP/snapshots.jsonl" | tr -d ' ')"
snap=$(/usr/bin/head -1 "$TMP/snapshots.jsonl")
shape=$(/usr/bin/jq -c '{ts: (.ts|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")), up_s, load: (.load|length), pressure: (.pressure|type), swap: (.swap_used_mb|type),
  swapfiles, free: (.free_pages|type), disk: (.disk_free_gb|type), procs: (.procs > 0), claude: (.claude|type), node: (.node|type), virt: (.virtualization|type),
  rss: (.top_rss|length), cpu: (.top_cpu|length), rss0: (.top_rss[0]|keys), cpu0: (.top_cpu[0]|keys)}' <<<"$snap")
assert_eq "line shape" '{"ts":true,"up_s":7200,"load":3,"pressure":"number","swap":"number","swapfiles":2,"free":"number","disk":"number","procs":true,"claude":"number","node":"number","virt":"number","rss":8,"cpu":8,"rss0":["cmd","pid","rss_mb"],"cpu0":["cmd","cpu","pid"]}' "$shape"
assert_eq "valid single-line JSON" 1 "$(printf '%s\n' "$snap" | /usr/bin/jq -c . | wc -l | tr -d ' ')"
run_script DEVHOST_COMPONENTS="check_obsidian"
assert_eq "second run appends" 2 "$(wc -l < "$TMP/snapshots.jsonl" | tr -d ' ')"
# Stub ps: counts by command name, ranking by rss and by cpu, a path with a space, a hung ps costs only its own fields.
cat > "$TMP/ps" <<'STUB'
#!/bin/sh
if [ "${STUB_PS_HANG:-0}" = 1 ]; then sleep 30; fi
cat <<'EOT'
  101  900000  1.5 /Users/x/.local/share/claude/versions/2.1.0/claude
  102  800000  9.5 /Users/x/.local/share/claude/versions/2.1.0/claude
  103  100000 80.0 /opt/homebrew/bin/node
  104  700000  0.0 /opt/homebrew/Cellar/colima/com.apple.Virtualization.VirtualMachine
  105  300000  3.0 /Applications/Some App.app/Contents/MacOS/Some App
  106  200000 40.0 /usr/sbin/fseventsd
EOT
STUB
chmod +x "$TMP/ps"
rm -f "$TMP/snapshots.jsonl"
run_script DEVHOST_COMPONENTS="check_obsidian" PS_BIN="$TMP/ps"
snap=$(/usr/bin/head -1 "$TMP/snapshots.jsonl")
assert_eq "counts by command" '{"procs":6,"claude":2,"node":1,"virt":1}' "$(/usr/bin/jq -c '{procs, claude, node, virt: .virtualization}' <<<"$snap")"
assert_eq "top by rss, command names only" '["claude","claude","com.apple.Virtualization.VirtualMachine","Some App"]' "$(/usr/bin/jq -c '[.top_rss[:4][] | .cmd]' <<<"$snap")"
assert_eq "top by cpu leads with node" "node" "$(/usr/bin/jq -r '.top_cpu[0].cmd' <<<"$snap")"
rm -f "$TMP/snapshots.jsonl"
run_script DEVHOST_COMPONENTS="check_obsidian" PS_BIN="$TMP/ps" STUB_PS_HANG=1 DEVHOST_SNAPSHOT_TOOL_TIMEOUT=1
assert_eq "a hung ps still yields a line, no process data" '{"procs":0,"rss":0}' "$(/usr/bin/jq -c '{procs, rss: (.top_rss|length)}' "$TMP/snapshots.jsonl")"
assert_eq "...and the heartbeat still exits 0" 0 "$RC"

echo "snapshot log is bounded by log-rotate (the declared EXTRA entry)"
assert_contains "log-rotate names the file" "devhost-snapshots.jsonl" "$(/usr/bin/grep -c 'devhost-snapshots.jsonl' "$HERE/log-rotate.sh") $(/usr/bin/grep 'devhost-snapshots.jsonl' "$HERE/log-rotate.sh")"

echo "panic: the heartbeat message carries the headline, the reboot push goes out once per panic"
rm -f "$TMP/state/panic-notified"; rm -f "$TMP/diag"/*
printf '{"panicString":"decoy"}\n' > "$TMP/diag/.contents.panic"
panic="$TMP/diag/panic-base+socd-2026-11-13-190826.000.panic"
printf '%s\n%s\n' '{"bug_type":"210","os_version":"macOS"}' \
  '{"panicString":"panic(cpu 3 caller 0xfffffe0011223344): watchdog timeout: no checkins from watchdogd in 94 seconds (104645 total checkins)\nDebugger message: panic\nmore","build":"x"}' > "$panic"
run_script DEVHOST_COMPONENTS="check_kernel_panics" DEVHOST_TEST_UPTIME_S=120
detail=$(/usr/bin/grep 'push/detail' "$TMP/curl.log")
assert_contains "heartbeat: headline, not a count" "watchdog timeout: no checkins from watchdogd in 94 seconds (104645 total checkins)" "$detail"
assert_eq "heartbeat: no prefix noise, no second line" 0 "$(printf '%s' "$detail" | /usr/bin/grep -c 'caller 0x\|Debugger message')"
assert_contains "heartbeat: still a WARN, push is up" "status=up" "$detail"
ntfy=$(cat "$TMP/curl.log")
assert_eq "one ntfy push on the first run" 1 "$(printf '%s\n' "$ntfy" | /usr/bin/grep -c 'ntfy.invalid/alerts')"
assert_contains "push is high priority" "Priority: high" "$ntfy"
assert_contains "push names the panic" "Title: Mini panicked and rebooted" "$ntfy"
assert_contains "push carries the headline" "watchdog timeout: no checkins from watchdogd in 94 seconds" "$ntfy"
assert_contains "push carries the time to ready" "ready 120s after boot" "$ntfy"
assert_contains "push carries the boot time" "boot 20" "$ntfy"
assert_contains "state records the report" "${panic##*/}" "$(cat "$TMP/state/panic-notified")"
run_script DEVHOST_COMPONENTS="check_kernel_panics" DEVHOST_TEST_UPTIME_S=420
assert_eq "second run, same panic: no push" 0 "$(/usr/bin/grep -c 'ntfy.invalid' "$TMP/curl.log")"
cp "$panic" "$TMP/diag/panic-full-2026-11-13-190500.0003.panic"
touch -t "$(date -v+10S '+%Y%m%d%H%M.%S')" "$TMP/diag/panic-full-2026-11-13-190500.0003.panic"
run_script DEVHOST_COMPONENTS="check_kernel_panics" DEVHOST_TEST_UPTIME_S=420
assert_eq "a NEW report pushes again" 1 "$(/usr/bin/grep -c 'ntfy.invalid' "$TMP/curl.log")"
echo "panic: a failed push is retried, a report past the age window is never pushed"
rm -f "$TMP/state/panic-notified"
run_script DEVHOST_COMPONENTS="check_kernel_panics" DEVHOST_TEST_UPTIME_S=120 STUB_NTFY_FAIL=1
assert_eq "failed push: nothing stored" 0 "$([[ -f "$TMP/state/panic-notified" ]] && echo 1 || echo 0)"
assert_eq "failed push: heartbeat still exits 0" 0 "$RC"
run_script DEVHOST_COMPONENTS="check_kernel_panics" DEVHOST_TEST_UPTIME_S=120
assert_eq "next run retries and succeeds" 1 "$(/usr/bin/grep -c 'ntfy.invalid' "$TMP/curl.log")"
rm -f "$TMP/state/panic-notified"
touch -t "$(date -v-4d '+%Y%m%d%H%M.%S')" "$TMP/diag"/*
run_script DEVHOST_COMPONENTS="check_kernel_panics" DEVHOST_TEST_UPTIME_S=120
assert_eq "outside the age window: no push" 0 "$(/usr/bin/grep -c 'ntfy.invalid' "$TMP/curl.log")"
touch "$TMP/diag"/*
run_script DEVHOST_COMPONENTS="check_kernel_panics" DEVHOST_TEST_UPTIME_S=120 SECRETS_RUN_BIN="$TMP/none-secrets-run"
assert_eq "no ntfy token: no push, heartbeat unharmed" 0 "$(/usr/bin/grep -c 'ntfy.invalid' "$TMP/curl.log")"
rm -f "$TMP/diag"/* "$TMP/diag"/.contents.panic "$TMP/state/panic-notified"
run_script DEVHOST_COMPONENTS="check_kernel_panics" DEVHOST_TEST_UPTIME_S=120
assert_eq "no report: no push" 0 "$(/usr/bin/grep -c 'ntfy.invalid' "$TMP/curl.log")"
assert_contains "no report: says so" "no kernel panic on record" "$(/usr/bin/grep 'push/detail' "$TMP/curl.log")"

echo "recovery: the core component carries the measured line, a WARN (never a FAIL) and the snapshot counts"
mkdir -p "$TMP/config"
printf '#!/bin/sh\n[ -z "${STUB_SOCK_DOWN:-}" ]\n' > "$TMP/bin/nc"
printf '#!/bin/sh\nprintf "    0 /sbin/launchd\\n    1 /x/Herdr Core.app/Contents/MacOS/herdr-core --hc-launchd /tmp/ready\\n"\n' > "$TMP/ps-core"
printf '#!/bin/sh\nexit 0\n' > "$TMP/resp"
cat > "$TMP/hc" <<'STUB'
#!/bin/sh
echo "$*" >> "$HC_CALLED"
case "$1 $2" in
  "server status") echo '{"version":"0.1.18","uptime_ms":5000}'; exit 0 ;;
  "machine ls") echo '{"machines":[{"version":"0.1.18"}]}'; exit 0 ;;
esac
[ "$1" = connect ] || exit 1
cat > /dev/null
printf '{"jsonrpc":"2.0","id":1,"result":{"terminals":[{"address":"t1","state":"live","keep":true,"labels":{"jk.claude.session":"aaaaaaaa-1"},"foreground":{"argv":["/x/claude"]}},{"address":"t2","state":"live","keep":true,"labels":{"jk.claude.session":"aaaaaaaa-2"},"foreground":{"argv":["/bin/zsh","-l"]}},{"address":"t3","state":"live","keep":false,"labels":{},"foreground":{"argv":["/bin/zsh","-l"]}}]}}\n'
STUB
chmod +x "$TMP/bin/nc" "$TMP/ps-core" "$TMP/resp" "$TMP/hc"
core_env=(NC_BIN="$TMP/bin/nc" PS_BIN="$TMP/ps-core" HC_BIN="$TMP/hc" HC_RESPONSIBLE_BIN="$TMP/resp" HC_SOCKET="$TMP/sock" HC_CALLED="$TMP/hc-called"
  CORE_PEER_SSH_HOST= XDG_CONFIG_HOME="$TMP/config" RECOVERY_RESUME_LOG="$TMP/none-resume.log")
detail_line() { /usr/bin/grep 'push/detail' "$TMP/curl.log"; }
rm -f "$TMP/snapshots.jsonl" "$TMP/state/tailnet-up-at" "$TMP/hc-called"
run_script DEVHOST_COMPONENTS="check_core" DEVHOST_TEST_UPTIME_S=1500 "${core_env[@]}"
assert_contains "booted 25 min ago: the line is in the core detail" "recovery: 2 resumable, 1 running claude, 1 waiting, 0 skipped" "$(detail_line)"
assert_eq "tailnet stub down, no stamp: not a WARN" 0 "$(detail_line | /usr/bin/grep -c 'WARN: ')"
assert_eq "snapshot carries the counts" '{"resumable":2,"running":1,"waiting":1,"skipped":0,"sent":0}' "$(/usr/bin/jq -c 'select(.recovery) | .recovery' "$TMP/snapshots.jsonl")"
echo $(( $(date +%s) - 700 )) > "$TMP/state/tailnet-up-at"
run_script DEVHOST_COMPONENTS="check_core" DEVHOST_TEST_UPTIME_S=1500 "${core_env[@]}"
assert_contains "11 min after tailnet-up: WARN" "WARN: core 0.1.18, up 5s" "$(detail_line)"
assert_contains "...naming the shortfall" "WARN: fewer running than resumable" "$(detail_line)"
assert_eq "a WARN is no FAIL: exit 0" 0 "$RC"
assert_contains "a WARN keeps the monitor up" "status=up" "$(detail_line)"
rm -f "$TMP/hc-called"
run_script DEVHOST_COMPONENTS="check_core" DEVHOST_TEST_UPTIME_S=2800 "${core_env[@]}"
assert_eq "booted 46 min ago: no recovery line" 0 "$(detail_line | /usr/bin/grep -c 'recovery:')"
run_script DEVHOST_COMPONENTS="check_core" DEVHOST_TEST_UPTIME_S=1500 DEVHOST_RECOVERY=0 "${core_env[@]}"
assert_eq "DEVHOST_RECOVERY=0: no recovery line" 0 "$(detail_line | /usr/bin/grep -c 'recovery:')"
assert_eq "...and no terminal.list" 0 "$(/usr/bin/grep -c '^connect' "$TMP/hc-called")"
rm -f "$TMP/hc-called"
run_script DEVHOST_COMPONENTS="check_core" DEVHOST_TEST_UPTIME_S=1500 STUB_SOCK_DOWN=1 "${core_env[@]}"
assert_contains "no core: the core check FAILs as before" "FAIL: no core answers" "$(detail_line)"
assert_eq "...and no hc call, no recovery line" "0 0" "$([[ -e "$TMP/hc-called" ]] && echo 1 || echo 0) $(detail_line | /usr/bin/grep -c 'recovery:')"
rm -f "$TMP/state/tailnet-up-at" "$TMP/snapshots.jsonl"

echo "the default component list only names functions the script or its libs define"
list=$(/usr/bin/awk '/^components="\$\{DEVHOST_COMPONENTS:-/{f=1} f{print} f&&/\}"$/{exit}' "$HERE/devhost-health-check.sh" | /usr/bin/sed -e 's/^components="${DEVHOST_COMPONENTS:-//' -e 's/}"$//' -e 's/\\$//')
[[ -n "$list" ]] && ok "default list found" || bad "default list found"
for name in $list; do
  if /usr/bin/grep -q "^${name}()" "$HERE/devhost-health-check.sh" "$HERE"/lib/*.sh; then ok "$name is defined"; else bad "$name is defined" "no ^${name}() in the script or lib/*.sh"; fi
done

echo
echo "passed: $pass, failed: $fail"
(( fail == 0 ))
