#!/bin/bash
# Hermetic test for lib/core-health.sh: the core-up definition (launchd running + socket), stray and detached-core
# detection, and "the core that answers is the job's child". Stub ps / launchctl / nc / hc, no live core touched.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail() { echo "core-health.test.sh: FAIL: $*" >&2; exit 1; }

mkdir -p "$T/bin"
# fixture: $JOB_STATE (default running), the job pid 100; the core that answers is $CORE_PID (default 101)
cat > "$T/bin/launchctl" <<'S'
#!/bin/bash
printf 'x = {\n\tstate = %s\n\tpid = 100\n\t\tstate = active\n}\n' "${JOB_STATE:-running}"
S
cat > "$T/bin/nc" <<'S'
#!/bin/bash
[ -z "${SOCK_DOWN:-}" ]
S
cat > "$T/bin/hc" <<'S'
#!/bin/bash
[ "$1 $2" = "server status" ] || exit 1
echo "{\"version\":\"0.1.15\",\"installed_by\":\"homebrew\",\"uptime_ms\":5000,\"pid\":${CORE_PID:-101}}"
S
cat > "$T/bin/ps" <<'S'
#!/bin/bash
# fixture: $PS_TABLE (pid ppid command), $PS_ENV (pid=ENVLINE)
if [ "$1 $2" = "-o ppid=" ]; then
  awk -v p="$4" '$1 == p { print $2 }' "$PS_TABLE"
elif [ "$1" = "-E" ]; then
  pid="$4"; echo "/x/herdr-core serve $(grep "^$pid=" "$PS_ENV" | cut -d= -f2-)"
else
  # -U <uid>: lines marked "#other" belong to another user and are dropped; the marker is stripped
  if [ "$1" = "-U" ]; then grep -v '#other$' "$PS_TABLE"; else sed 's/ #other$//' "$PS_TABLE"; fi
fi
S
chmod +x "$T/bin/"*
export LAUNCHCTL_BIN="$T/bin/launchctl" NC_BIN="$T/bin/nc" HC_BIN="$T/bin/hc" PS_BIN="$T/bin/ps" CORE_LAUNCHER=/h/launcher CORE_PEER_SSH_HOST='' XDG_CONFIG_HOME="$T/config" PS_TABLE="$T/table" PS_ENV="$T/env"
: > "$T/env"
# shellcheck source=lib/core-health.sh
source "$HERE/lib/core-health.sh"
check() { msg=$(core_health_check); rc=$?; }
healthy() { printf '  100     1 /h/launcher /opt/homebrew/opt/herdr-core/bin/herdr-core serve\n  101   100 /opt/homebrew/Cellar/herdr-core/0.1.15/bin/herdr-core serve\n'; }

# 1. core is the launcher's child -> healthy
cat > "$T/table" <<'S'
  100     1 /h/launcher /opt/homebrew/opt/herdr-core/bin/herdr-core serve
  101   100 /opt/homebrew/Cellar/herdr-core/0.1.15/bin/herdr-core serve
  102   101 /opt/homebrew/Cellar/herdr-core/0.1.15/bin/herdr-core hold --socket /s
S
check; [ "$rc" = 0 ] || fail "launcher child must be healthy: rc=$rc $msg"

# 2. stray core started by a client (parent launchd) -> FAIL naming pid and fix
cat > "$T/table" <<'S'
  100     1 /h/launcher /opt/homebrew/opt/herdr-core/bin/herdr-core serve
  101   100 /opt/homebrew/Cellar/herdr-core/0.1.15/bin/herdr-core serve
  900     1 /Users/x/.local/bin/herdr-core serve
S
check; [ "$rc" = 1 ] || fail "stray must FAIL: rc=$rc $msg"
case "$msg" in *"pid 900"*"kill 900"*"kickstart"*) ;; *) fail "message must name pid and fix: $msg" ;; esac

# 3. stray whose parent is an sshd/app process still FAILs
{ healthy; printf '  900   55 /usr/bin/hc serve\n   55     1 /usr/sbin/sshd\n'; } > "$T/table"
check; [ "$rc" = 1 ] || fail "stray under sshd must FAIL: rc=$rc $msg"

# 4. scratch-session core (HC_SESSION in its env) is not a stray; HC_SESSION=default is
{ healthy; printf '  900     1 /opt/homebrew/opt/herdr-core/bin/hc serve\n'; } > "$T/table"
echo "900=HC_SESSION=scr1 PATH=/bin" > "$T/env"
check; [ "$rc" = 0 ] || fail "scratch session must be exempt: rc=$rc $msg"
echo "900=HC_SESSION=default PATH=/bin" > "$T/env"
check; [ "$rc" = 1 ] || fail "HC_SESSION=default is a stray: rc=$rc $msg"

# 5. an hc client (not serve) is never a stray
{ healthy; printf '  900     1 /Users/x/.local/bin/herdr-core connect\n'; } > "$T/table"; : > "$T/env"
check; [ "$rc" = 0 ] || fail "connect client must not be flagged: rc=$rc $msg"

# 6. another user's serve process is not ours to report (ps is restricted to the current uid)
{ healthy; printf '  900     1 /Users/x/.local/bin/herdr-core serve #other\n'; } > "$T/table"; : > "$T/env"
check; [ "$rc" = 0 ] || fail "another user's serve must not be reported: rc=$rc $msg"

# 7. 0.1.17's escape: a detached `--hc-launchd` daemon (parent launchd) is a stray, even beside a healthy job
: > "$T/env"
{ healthy; printf '  950     1 /opt/homebrew/Cellar/herdr-core/0.1.17/bin/herdr-core --hc-launchd /tmp/hc-launchd-1-2-x/ready\n'; } > "$T/table"
check; [ "$rc" = 1 ] || fail "detached daemon must FAIL: rc=$rc $msg"
case "$msg" in *"pid 950"*"kill 950"*"SIGTERM keeps terminals"*) ;; *) fail "detached daemon message: $msg" ;; esac
# ...and the stray is named first while the job it blocks loops `spawn scheduled` (the state would hide it)
msg=$(JOB_STATE="spawn scheduled" core_health_check); rc=$?
[ "$rc" = 1 ] || fail "stray with a flapping job must FAIL: rc=$rc $msg"
case "$msg" in *"pid 950"*) ;; *) fail "a flapping job must not hide the stray: $msg" ;; esac

# 8. the incident shape: launchd respawning the job (`spawn scheduled`) while an orphan answers -> FAIL, no hc call
healthy > "$T/table"
printf '#!/bin/bash\ntouch "%s/hc-called"\n' "$T" > "$T/bin/hc-spy"; chmod +x "$T/bin/hc-spy"
msg=$(JOB_STATE="spawn scheduled" HC_BIN="$T/bin/hc-spy" core_health_check); rc=$?
[ "$rc" = 1 ] || fail "spawn scheduled must FAIL: rc=$rc $msg"
[ ! -e "$T/hc-called" ] || fail "hc was called while launchd does not run the job"
case "$msg" in *"'spawn scheduled', not running"*"kickstart"*) ;; *) fail "spawn scheduled message: $msg" ;; esac

# 9. running but the socket does not answer -> FAIL
msg=$(SOCK_DOWN=1 core_health_check); rc=$?
[ "$rc" = 1 ] || fail "dead socket must FAIL: rc=$rc"
case "$msg" in *"does not answer"*) ;; *) fail "dead socket message: $msg" ;; esac

# 10. the core that answers is not the job's child (an orphan took the socket) -> FAIL
{ healthy; printf '  777     1 /opt/homebrew/Cellar/herdr-core/0.1.15/bin/herdr-core hold --socket /s\n'; } > "$T/table"
msg=$(CORE_PID=777 core_health_check); rc=$?
[ "$rc" = 1 ] || fail "core outside the job must FAIL: rc=$rc $msg"
case "$msg" in *"not the child"*"job pid 100"*) ;; *) fail "not-child message: $msg" ;; esac

echo "core-health.test.sh: ok"
