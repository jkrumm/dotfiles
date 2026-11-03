#!/bin/bash
# Hermetic test for the stray-core detection in lib/core-health.sh: stub ps / launchctl / hc, no live core touched.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail() { echo "core-health.test.sh: FAIL: $*" >&2; exit 1; }

mkdir -p "$T/bin"
cat > "$T/bin/launchctl" <<'S'
#!/bin/bash
printf 'x = {\n\tstate = running\n\tpid = 1\n\t\tstate = active\n}\n'
S
cat > "$T/bin/hc" <<'S'
#!/bin/bash
[ "$1 $2" = "server status" ] || exit 1
echo "{\"version\":\"0.1.15\",\"installed_by\":\"homebrew\",\"uptime_ms\":5000}"
S
cat > "$T/bin/ps" <<'S'
#!/bin/bash
# fixture: $PS_TABLE (pid ppid command), $PS_ENV (pid=ENVLINE)
if [ "$1" = "-E" ]; then
  pid="$4"; echo "/x/herdr-core serve $(grep "^$pid=" "$PS_ENV" | cut -d= -f2-)"
else
  # -U <uid>: lines marked "#other" belong to another user and are dropped; the marker is stripped
  if [ "$1" = "-U" ]; then grep -v '#other$' "$PS_TABLE"; else sed 's/ #other$//' "$PS_TABLE"; fi
fi
S
chmod +x "$T/bin/"*
export LAUNCHCTL_BIN="$T/bin/launchctl" HC_BIN="$T/bin/hc" PS_BIN="$T/bin/ps" CORE_LAUNCHER=/h/launcher CORE_PEER_SSH_HOST='' XDG_CONFIG_HOME="$T/config" PS_TABLE="$T/table" PS_ENV="$T/env"
: > "$T/env"
# shellcheck source=lib/core-health.sh
source "$HERE/lib/core-health.sh"
check() { msg=$(core_health_check); rc=$?; }

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
printf '  900   55 /usr/bin/hc serve\n   55     1 /usr/sbin/sshd\n' > "$T/table"
check; [ "$rc" = 1 ] || fail "stray under sshd must FAIL: rc=$rc $msg"

# 4. scratch-session core (HC_SESSION in its env) is not a stray; HC_SESSION=default is
printf '  900     1 /opt/homebrew/opt/herdr-core/bin/hc serve\n' > "$T/table"
echo "900=HC_SESSION=scr1 PATH=/bin" > "$T/env"
check; [ "$rc" = 0 ] || fail "scratch session must be exempt: rc=$rc $msg"
echo "900=HC_SESSION=default PATH=/bin" > "$T/env"
check; [ "$rc" = 1 ] || fail "HC_SESSION=default is a stray: rc=$rc $msg"

# 5. an hc client (not serve) is never a stray
printf '  900     1 /Users/x/.local/bin/herdr-core connect\n' > "$T/table"; : > "$T/env"
check; [ "$rc" = 0 ] || fail "connect client must not be flagged: rc=$rc $msg"

# 6. another user's serve process is not ours to report (ps is restricted to the current uid)
printf '  900     1 /Users/x/.local/bin/herdr-core serve #other\n' > "$T/table"; : > "$T/env"
check; [ "$rc" = 0 ] || fail "another user's serve must not be reported: rc=$rc $msg"

echo "core-health.test.sh: ok"
