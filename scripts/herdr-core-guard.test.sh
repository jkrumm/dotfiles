#!/bin/bash
# Hermetic test for herdr-core-guard.sh: stub launchctl / nc and a stub "real" binary. No core, no live job.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T=$(mktemp -d); T=$(cd -P "$T" && pwd -P); trap 'rm -rf "$T"' EXIT
fail() { echo "herdr-core-guard.test.sh: FAIL: $*" >&2; exit 1; }

mkdir -p "$T/bin" "$T/real/Cellar" "$T/home/.local/bin"
cat > "$T/real/Cellar/herdr-core" <<'S'
#!/bin/bash
echo "$0 $*" >> "$RAN_LOG"
S
ln -s herdr-core "$T/real/Cellar/hc"
ln -s Cellar "$T/real/opt"   # the opt symlink: the guard must exec the resolved path
cat > "$T/bin/launchctl" <<'S'
#!/bin/bash
[ -f "$STATE_FILE" ] || exit 113
printf 'x = {\n\tstate = %s\n\tpid = 1\n\t\tstate = active\n}\n' "$(cat "$STATE_FILE")"
S
cat > "$T/bin/nc" <<'S'
#!/bin/bash
[ -f "$SOCK_UP" ]
S
chmod +x "$T/real/Cellar/herdr-core" "$T/bin/"*
ln -s "$HERE/herdr-core-guard.sh" "$T/home/.local/bin/hc"
ln -s "$HERE/herdr-core-guard.sh" "$T/home/.local/bin/herdr-core"

export RAN_LOG="$T/ran" STATE_FILE="$T/state" SOCK_UP="$T/sockup" HOME="$T/home"
export HC_GUARD_REAL_DIR="$T/real/opt" LAUNCHCTL_BIN="$T/bin/launchctl" NC_BIN="$T/bin/nc" HC_GUARD_WAIT=1 HC_SOCKET="$T/s.sock"
unset HC_SESSION XDG_RUNTIME_DIR
python3 -I -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$T/real.sock" 2>/dev/null
ln -s "$T/real.sock" "$T/s.sock"
[ -S "$T/s.sock" ] || fail "test setup: no socket"
hc() { "$T/home/.local/bin/hc" "$@"; }
reset() { rm -f "$RAN_LOG" "$STATE_FILE" "$SOCK_UP"; }

# job not loaded -> refusal, real binary never ran
reset
out=$(hc ls --json 2>&1); rc=$?
[ "$rc" = 75 ] || fail "not loaded: want exit 75, got $rc"
[ ! -f "$RAN_LOG" ] || fail "real binary ran with the job down"
case "$out" in *"refusing to start"*"not loaded"*"make herdr-core-setup"*) ;; *) fail "refusal text: $out" ;; esac

# job stopped / pended -> refusal with kickstart fix
reset; echo "not running" > "$STATE_FILE"
out=$(hc connect 2>&1); rc=$?
[ "$rc" = 75 ] && [ ! -f "$RAN_LOG" ] || fail "stopped job must refuse (rc=$rc)"
case "$out" in *"launchctl kickstart gui/"*"/com.jkrumm.herdr-core"*) ;; *) fail "kickstart fix missing: $out" ;; esac

# running but the socket does not answer -> refusal
reset; echo running > "$STATE_FILE"
out=$(hc ls 2>&1); rc=$?
[ "$rc" = 75 ] && [ ! -f "$RAN_LOG" ] || fail "unanswered socket must refuse (rc=$rc)"
case "$out" in *"does not answer"*) ;; *) fail "socket text: $out" ;; esac

# job up + socket answers -> exec the Cellar-resolved binary with every arg
reset; echo running > "$STATE_FILE"; : > "$SOCK_UP"
hc run --bg "a b" c || fail "job up must pass through (rc=$?)"
[ "$(cat "$RAN_LOG")" = "$T/real/Cellar/hc run --bg a b c" ] || fail "exec/args: $(cat "$RAN_LOG")"
"$T/home/.local/bin/herdr-core" connect
grep -q "^$T/real/Cellar/herdr-core connect$" "$RAN_LOG" || fail "herdr-core name not kept: $(cat "$RAN_LOG")"

# inside a core terminal (HC_TERMINAL_ID set) behaves the same as outside
HC_TERMINAL_ID=t1 hc ls || fail "core terminal must pass with the job up"
reset
HC_TERMINAL_ID=t1 hc ls 2>/dev/null && fail "core terminal with the job down must refuse"

# a job that comes up within the wait is not a refusal
reset; ( sleep 0.4; echo running > "$STATE_FILE"; : > "$SOCK_UP" ) &
hc ls || fail "job coming up inside the wait must pass"
wait

# scratch session exempt (env and flag), even with the job down
reset
HC_SESSION=scr1 hc ls || fail "HC_SESSION=scr1 must be exempt"
hc connect --session scr1 || fail "--session must be exempt"
HC_SESSION=default hc ls 2>/dev/null && fail "HC_SESSION=default is not a scratch session"

# help/version/skill/schema passthrough with the job down
reset
for a in "--help" "-V" "--version" "--skill" "schema" "run --help" "server status --help"; do
  rm -f "$RAN_LOG"
  # shellcheck disable=SC2086
  hc $a || fail "passthrough failed for: $a"
  [ -f "$RAN_LOG" ] || fail "real binary not run for: $a"
done

echo "herdr-core-guard.test.sh: ok"
