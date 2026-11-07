#!/bin/bash
# Hermetic test for lib/core-health.sh: FAIL when core_up fails (nothing answers, or a core answers that launchd did not
# start = stray), WARN when hc-responsible.py names offenders or the peer runs another version, and never an `hc` call
# before core_up passes. Stub ps / nc / hc / hc-responsible, no live core touched.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail() { echo "core-health.test.sh: FAIL: $*" >&2; exit 1; }

mkdir -p "$T/bin"
cat > "$T/bin/nc" <<'S'
#!/bin/bash
[ -z "${SOCK_DOWN:-}" ]
S
cat > "$T/bin/hc" <<'S'
#!/bin/bash
touch "$HC_CALLED"
if [ "$1 $2" = "machine ls" ]; then
  [ -z "${PEER:-}" ] || echo "{\"machines\":[{\"version\":\"$PEER\"}]}"
  exit 0
fi
[ "$1 $2" = "server status" ] || exit 1
[ -z "${STATUS_DOWN:-}" ] || exit 1
echo '{"version":"0.1.18","uptime_ms":5000,"pid":101}'
S
cat > "$T/bin/ps" <<'S'
#!/bin/bash
cat "$PS_TABLE"   # ppid command, as core-up.sh asks
S
cat > "$T/bin/resp" <<'S'
#!/bin/bash
if [ -n "${RESP_TAINT:-}" ]; then echo "agent environment inherited by 100: every terminal gets it"; exit 1; fi
if [ -n "${RESP_OFFENDERS:-}" ]; then echo "   300 holder responsible=300 (/opt/homebrew/Cellar/herdr-core/0.1.17/bin/herdr-core) NOT Herdr Core.app"; echo "offenders: $RESP_OFFENDERS of 4 not attributed to Herdr Core.app"; exit 1; fi
echo "   100 core   responsible=100 (/x/Herdr Core.app/Contents/MacOS/herdr-core) ok"
S
chmod +x "$T/bin/"*
export NC_BIN="$T/bin/nc" HC_BIN="$T/bin/hc" PS_BIN="$T/bin/ps" HC_RESPONSIBLE_BIN="$T/bin/resp" CORE_PEER_SSH_HOST='' XDG_CONFIG_HOME="$T/config" PS_TABLE="$T/table" HC_CALLED="$T/hc-called" HC_SOCKET="$T/sock"
# shellcheck source=lib/core-health.sh
source "$HERE/lib/core-health.sh"
check() { rm -f "$HC_CALLED"; msg=$(core_health_check); rc=$?; }
born() { printf '    0 /sbin/launchd\n    1 /x/Herdr Core.app/Contents/MacOS/herdr-core --hc-launchd /tmp/hc-launchd-1-2-x/ready\n'; }

# 1. launchd-born core answering, holders under the bundle -> healthy, one line with the version
born > "$T/table"
check; [ "$rc" = 0 ] || fail "healthy core: rc=$rc $msg"
case "$msg" in "core 0.1.18, up 5s"*) ;; *) fail "healthy message: $msg" ;; esac

# 2. nothing answers -> FAIL with why + fix, and hc is never called
born > "$T/table"; SOCK_DOWN=1 check
[ "$rc" = 1 ] || fail "dead socket must FAIL: rc=$rc"
case "$msg" in *"no core answers"*"fix:"*) ;; *) fail "dead socket message: $msg" ;; esac
[ ! -e "$HC_CALLED" ] || fail "hc was called while no core answers"

# 3. a core answers but launchd did not start it (stray, e.g. client-started under sshd) -> FAIL, hc not called
printf '    0 /sbin/launchd\n   55 /usr/bin/herdr-core serve\n    1 /usr/sbin/sshd\n' > "$T/table"
check; [ "$rc" = 1 ] || fail "stray must FAIL: rc=$rc $msg"
case "$msg" in *"launchd did not start it"*"fix:"*) ;; *) fail "stray message: $msg" ;; esac
[ ! -e "$HC_CALLED" ] || fail "hc was called against a stray"

# 4. core up but hc server status silent -> FAIL
born > "$T/table"; STATUS_DOWN=1 check
[ "$rc" = 1 ] || fail "silent hc must FAIL: rc=$rc $msg"

# 5. an old holder not under the bundle -> WARN naming the count
born > "$T/table"; RESP_OFFENDERS=2 check
[ "$rc" = 2 ] || fail "offending holder must WARN: rc=$rc $msg"
case "$msg" in *"offenders: 2 of 4"*) ;; *) fail "offender message: $msg" ;; esac

# 5b. a core that inherited an agent's environment -> WARN naming it, though its identity is right
born > "$T/table"; RESP_TAINT=1 check
[ "$rc" = 2 ] || fail "inherited agent env must WARN: rc=$rc $msg"
case "$msg" in *"agent environment inherited"*) ;; *) fail "taint message: $msg" ;; esac

# 6. the other machine runs another version -> WARN; the same version is quiet
born > "$T/table"; PEER=0.1.17 check
[ "$rc" = 2 ] || fail "version mismatch must WARN: rc=$rc $msg"
case "$msg" in *"0.1.17"*) ;; *) fail "mismatch message: $msg" ;; esac
born > "$T/table"; PEER=0.1.18 check
[ "$rc" = 0 ] || fail "same peer version must be healthy: rc=$rc $msg"

# 7. the peer version over plain ssh: the MacBook (iumac) is sent the bare verb, the mini the hc command
_core_bounded() { case "$2" in /usr/bin/ssh) printf '%s\n' "${@: -1}" > "$T/ssh-cmd"; echo "hc 0.1.18" ;; *) return 1 ;; esac; }
v=$(CORE_PEER_SSH_HOST=iumac core_peer_version /nonexistent)
[ "$v" = 0.1.18 ] && [ "$(cat "$T/ssh-cmd")" = hc-version ] || fail "iumac must get the hc-version verb: v=$v cmd=$(cat "$T/ssh-cmd")"
grep -qE '^[a-z0-9 -]+$' "$T/ssh-cmd" || fail "iumac command carries shell syntax"
v=$(CORE_PEER_SSH_HOST=mini core_peer_version /nonexistent)
case "$(cat "$T/ssh-cmd")" in *'hc" --version'*) ;; *) fail "mini keeps the hc command: $(cat "$T/ssh-cmd")" ;; esac

echo "core-health.test.sh: ok"
