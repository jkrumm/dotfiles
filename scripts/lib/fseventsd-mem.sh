#!/usr/bin/env bash
# fseventsd-mem — fseventsd_leak_note for check_memory in devhost-health-check.sh.
#
# Sourceable, no side effects on load, bash 3.2. Reads TOP_BIN, AWK_BIN, PGREP_BIN and
# FSEVENTSD_MAX_MB (default 10240 = 10 GiB), all overridable so the test stubs them.
#
# WHY. On 2026-11-06 fseventsd (up 5 days) grew to 61 GiB, 55 GiB of it compressed, filled the
# 64 GiB swap and made the host thrash; the heartbeat only said so once swap was full. `ps` RSS
# showed 4.7 GiB for it, because RSS leaves out compressed pages: `top`'s MEM column counts them
# and needs no root. A healthy fseventsd is a few MiB, so 10 GiB is far past noise.
#
# Prints nothing when fseventsd is fine or unreadable (a missing process is not a leak, and this
# is a warning aid, never a verdict); prints one clause when it is over the limit.
fseventsd_leak_note() {
  local pid line mem_mb
  pid=$("${PGREP_BIN:-/usr/bin/pgrep}" -x fseventsd 2>/dev/null | "${AWK_BIN:-/usr/bin/awk}" 'NR==1') || pid=""
  [[ -n "$pid" ]] || return 0
  line=$("${TOP_BIN:-/usr/bin/top}" -l 1 -pid "$pid" -stats mem 2>/dev/null | "${AWK_BIN:-/usr/bin/awk}" 'NF { l = $1 } END { print l }') || line=""
  mem_mb=$("${AWK_BIN:-/usr/bin/awk}" -v v="$line" 'BEGIN {
      n = v + 0; u = substr(v, length(v), 1)
      if (u == "G") n *= 1024; else if (u == "K") n /= 1024; else if (u == "B") n /= 1048576
      else if (u != "M") n = 0
      printf "%d", n }') || mem_mb=0
  (( mem_mb > ${FSEVENTSD_MAX_MB:-10240} )) || return 0
  echo "fseventsd holds $(( mem_mb / 1024 ))G (leak; restart: sudo killall fseventsd, launchctl kickstart is refused by SIP)"
}
