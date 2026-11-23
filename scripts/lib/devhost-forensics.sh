#!/usr/bin/env bash
# devhost-forensics.sh — what the heartbeat records so a hang or panic can be explained afterwards, and the one
# push that tells the owner the host went through one. Sourced by devhost-health-check.sh; every function reads
# that script's globals (STATE_DIR, the *_BIN overrides, DIAGNOSTIC_REPORTS_DIR, run_bounded) and bash 3.2 only.
#
# WHY. 2026-11-13 the mini kernel-panicked (watchdogd saw no check-in for 94 s). The report named no culprit and
# nothing had recorded which processes ran or how memory looked, so the cause could not be established; and the
# Dev Host monitor (interval 600 s, 1 retry) recovered before DOWN, so nobody was told. See
# docs/incident-2026-11-13-mini-panic.md.
#
#   panic_newest_report          newest panic report file (shared with check_kernel_panics)
#   panic_headline <file>        the panicString's first line, with the `panic(cpu N caller 0x…):` prefix removed
#   devhost_snapshot             one compact JSON line appended to DEVHOST_SNAPSHOT_LOG
#   devhost_boot_record          one `boot` line per boot: kernel boot, userspace, session, core ready, load settled
#   devhost_panic_notify         one ntfy push per panic report, state in $STATE_DIR/panic-notified

DEVHOST_SNAPSHOT_LOG="${DEVHOST_SNAPSHOT_LOG:-$HOME/Library/Logs/devhost-snapshots.jsonl}"
# Every sub-tool of the snapshot is bounded on its own (run_bounded): a hung `ps` costs this one line, not the run.
SNAPSHOT_TOOL_TIMEOUT="${DEVHOST_SNAPSHOT_TOOL_TIMEOUT:-5}"
SNAPSHOT_TOP_N=8
SWAP_DIR="${DEVHOST_SWAP_DIR:-/private/var/vm}"
VM_STAT_BIN="${VM_STAT_BIN:-/usr/bin/vm_stat}"
PANIC_NTFY_TOPIC="${DEVHOST_PANIC_NTFY_TOPIC:-alerts}"
NTFY_CONFIG="${NTFY_CONFIG:-$HOME/SourceRoot/homelab/config/ntfy/server.yml}"
PANIC_NOTIFIED_FILE="$STATE_DIR/panic-notified"

# `<mtime>\t<path>` of the newest panic report, empty when there is none. EVERY spelling macOS has used (the
# reasoning is in check_kernel_panics); a pattern that matches nothing expands to itself and `-f` drops it.
# `panic-*`, not `panic-full-*`: the 2026-11-13 panic was written as `panic-base+socd-<date>.000.panic` (the
# watchdog-timeout form), which the old pattern never matched. The hidden `.contents.panic` is skipped by the glob.
panic_newest_report() {
  local dir="$DIAGNOSTIC_REPORTS_DIR" f mtime newest="" newest_mtime=0
  for f in "$dir"/panic-*.panic "$dir"/panic-*.ips \
           "$dir"/Kernel-*.panic "$dir"/Kernel_*.panic; do
    [[ -f "$f" ]] || continue
    mtime=$("$STAT_BIN" -f %m "$f" 2>/dev/null) || continue
    [[ -n "$mtime" ]] || continue
    if (( mtime > newest_mtime )); then newest_mtime=$mtime; newest="$f"; fi
  done
  [[ -z "$newest" ]] || printf '%s\t%s\n' "$newest_mtime" "$newest"
}

# The panic's own one-line signature: the string before the first newline of `panicString`. The report is a stream
# of JSON documents (a small header first), so jq slurps it and picks the document that has one. The
# `panic(cpu N caller 0x…):` prefix is 40 characters of identifier noise; an older report quotes the message
# after it, so a leading quote is unwrapped. Never prints a newline, so it is safe inside a heartbeat message.
panic_headline() {
  local raw
  raw=$("$JQ_BIN" -rs '[.[] | select(type == "object" and .panicString) | .panicString] | first // "" | split("\n")[0]' "$1" 2>/dev/null) || raw=""
  raw=$("$SED_BIN" -e 's/^[[:space:]]*//' -e 's/^panic([^)]*):[[:space:]]*//' -e 's/^"\([^"]*\)".*$/\1/' <<<"$raw")
  [[ -n "$raw" ]] || raw="headline unreadable"
  printf '%s\n' "$raw"
}

# --- Rolling pre-hang snapshot -------------------------------------------------------------------------------
# One line per heartbeat run, so the five minutes before a hang are on disk. ~2.5 KB a line, ~720 KB a day;
# scripts/log-rotate.sh caps it (16 MB, one generation) as an EXTRA entry. Four bounded tools in all (sysctl,
# vm_stat, ps, df), at most 4 x SNAPSHOT_TOOL_TIMEOUT, run after the liveness push. Never fails the heartbeat.
devhost_snapshot() {
  [[ -n "$DEVHOST_SNAPSHOT_LOG" ]] || return 0
  local sysctl_out vmstat_out ps_out df_out load="" level="" swap="" swapfiles=0 free_pages="" disk_free_gb="" f
  sysctl_out=$(run_bounded "$SNAPSHOT_TOOL_TIMEOUT" "$SYSCTL_BIN" -n vm.loadavg kern.memorystatus_vm_pressure_level vm.swapusage) || sysctl_out=""
  vmstat_out=$(run_bounded "$SNAPSHOT_TOOL_TIMEOUT" "$VM_STAT_BIN") || vmstat_out=""
  ps_out=$(run_bounded "$SNAPSHOT_TOOL_TIMEOUT" "$PS_BIN" -axo pid=,rss=,pcpu=,comm=) || ps_out=""
  df_out=$(run_bounded "$SNAPSHOT_TOOL_TIMEOUT" "$DF_BIN" -kP "$HOME") || df_out=""

  # vm.loadavg: "{ 1.20 1.50 1.60 }" -> "1.20 1.50 1.60"; swapusage: "total = 5120.00M  used = 3672.38M  ..." -> used MB.
  # shellcheck disable=SC2016  # awk fields, not shell expansions
  load=$("$AWK_BIN" 'NR == 1 { gsub(/[{}]/, ""); print $1, $2, $3 }' <<<"$sysctl_out")
  level=$("$AWK_BIN" 'NR == 2 { print $1 }' <<<"$sysctl_out")
  # shellcheck disable=SC2016
  swap=$("$AWK_BIN" 'NR == 3 {
      for (i = 1; i <= NF; i++) if ($i == "used") { v = $(i + 2); break }
      u = v + 0; unit = substr(v, length(v), 1)
      if (unit == "G") u *= 1024; else if (unit == "K") u /= 1024
      printf "%d", u }' <<<"$sysctl_out")
  for f in "$SWAP_DIR"/swapfile*; do [[ -e "$f" ]] && swapfiles=$(( swapfiles + 1 )); done
  # shellcheck disable=SC2016
  free_pages=$("$AWK_BIN" '/^Pages free:/ { gsub(/\./, "", $3); print $3 }' <<<"$vmstat_out")
  # shellcheck disable=SC2016
  disk_free_gb=$("$AWK_BIN" 'END { if (NR > 1) printf "%d", $4 / 1048576 }' <<<"$df_out")

  # jq builds the line (escaping is its job, never a printf). Empty readings are null: a missing field says the
  # tool failed. Process rows: `<pid> <rss KiB> <%cpu> <command path>`; the command is shown by basename.
  local line
  line=$(printf '%s\n' "$ps_out" | "$JQ_BIN" -Rn -c \
    --arg ts "$("$DATE_BIN" -u +%Y-%m-%dT%H:%M:%SZ)" --arg up "${uptime_s:-}" --arg load "$load" --arg level "$level" \
    --arg swap "$swap" --argjson swapfiles "$swapfiles" --arg free "$free_pages" --arg disk "$disk_free_gb" \
    --argjson n "$SNAPSHOT_TOP_N" '
      def num: if . == "" or . == null then null else (tonumber? // null) end;
      [inputs | capture("^\\s*(?<pid>[0-9]+)\\s+(?<rss>[0-9]+)\\s+(?<cpu>[0-9.]+)\\s+(?<comm>.+)$")?
       | {pid: (.pid | tonumber), rss_mb: ((.rss | tonumber) / 1024 | floor), cpu: (.cpu | tonumber),
          cmd: (.comm | split("/") | last), path: .comm}] as $p
      | ($load | split(" ")) as $l
      | {ts: $ts, up_s: ($up | num),
         load: (if ($l | length) == 3 then [$l[] | tonumber? // null] else null end),
         pressure: ($level | num), swap_used_mb: ($swap | num), swapfiles: $swapfiles,
         free_pages: ($free | num), disk_free_gb: ($disk | num),
         procs: ($p | length),
         claude: ([$p[] | select(.path | test("claude"))] | length),
         node: ([$p[] | select(.cmd == "node")] | length),
         virtualization: ([$p[] | select(.path | test("Virtualization"))] | length),
         top_rss: ([$p | sort_by(-.rss_mb) | .[:$n][] | {cmd, pid, rss_mb}]),
         top_cpu: ([$p | sort_by(-.cpu) | .[:$n][] | {cmd, pid, cpu}])}') || line=""
  [[ -n "$line" ]] || { echo "snapshot: could not build the line" >&2; return 0; }
  mkdir -p "$(dirname "$DEVHOST_SNAPSHOT_LOG")" 2>/dev/null || true
  printf '%s\n' "$line" >> "$DEVHOST_SNAPSHOT_LOG" 2>/dev/null || echo "snapshot: cannot append to $DEVHOST_SNAPSHOT_LOG" >&2
  return 0
}

# --- One boot record per boot ----------------------------------------------------------------------------------
# 2026-11-23 the mini sat about six minutes between kernel boot and its first userspace daemon, then another ten
# before the post-boot load fell (docs/recovery-drill.md §Boot to userspace). The two halves have different causes
# and different owners, so every boot records both, once: a line `{ts, up_s, boot: {...}}` in the snapshot log.
#
#   boot_at          kern.boottime (kernel start), UTC
#   userspace_at     start of the earliest surviving process that is neither kernel_task (pid 0) nor launchd (pid 1)
#   session_at       start of the earliest surviving process of this user other than loginwindow (the session leader):
#                    the first agent of the user session (a user agent's parent shows as pid 1, so a parent test cannot tell)
#   core_ready_at    mtime of the herdr-core socket, i.e. when the core bound it (null when older than the boot)
#   settled_at       the first heartbeat whose 1-min load average is under SETTLE_LOAD; settled_prev_at is the heartbeat
#                    before it, so the true crossing lies in between (the heartbeat runs every 300 s)
#   boot_to_userspace_s, userspace_to_settled_s   the two halves, in seconds
#
# Written when the load settles, or at DEVHOST_BOOT_RECORD_WINDOW_S (45 min) with settled_at null: a boot that never
# settled is a finding too. A boot whose FIRST sighting was later than BOOT_RECORD_LATE_S (a deploy mid-uptime, a
# heartbeat that was down) gets no record: its settle time would be a guess. State: $STATE_DIR/boot-record =
# `<boot epoch> <first sighting up_s> <previous run epoch> <pending|done>`. Start times come from `ps etime` (whole
# seconds, no timezone parsing). DEVHOST_BOOT_RECORD=0 turns it off. Never fails the heartbeat.
BOOT_RECORD_WINDOW_S="${DEVHOST_BOOT_RECORD_WINDOW_S:-2700}"
BOOT_RECORD_LATE_S="${DEVHOST_BOOT_RECORD_LATE_S:-900}"
BOOT_SETTLE_LOAD="${DEVHOST_BOOT_SETTLE_LOAD:-20}"
BOOT_RECORD_STATE="$STATE_DIR/boot-record"

# `<userspace epoch> <comm>` then `<session epoch> <comm>`, from ps rows `pid uid etime comm` (etime [[dd-]hh:]mm:ss).
# An unreadable row is skipped; a section with no row prints `- -`.
_boot_earliest_procs() {
  local now="$1" uid="$2" rows="$3"
  # shellcheck disable=SC2016  # awk program
  "$AWK_BIN" -v now="$now" -v uid="$uid" '
    function secs(e,  d, a, p, n) {
      d = 0
      if (e ~ /-/) { split(e, a, "-"); d = a[1]; e = a[2] }
      n = split(e, p, ":")
      if (n == 3) return d * 86400 + p[1] * 3600 + p[2] * 60 + p[3]
      if (n == 2) return d * 86400 + p[1] * 60 + p[2]
      return -1
    }
    { s = secs($3); if (s < 0 || $1 + 0 < 2) next
      name = $4; for (i = 5; i <= NF; i++) name = name " " $i
      n = split(name, parts, "/"); name = parts[n]
      if (s > us) { us = s; un = name }
      if ($2 == uid && name != "loginwindow" && s > ss) { ss = s; sn = name } }
    END {
      if (us > 0) printf "%d %s\n", now - us, un; else print "- -"
      if (ss > 0) printf "%d %s\n", now - ss, sn; else print "- -" }' <<<"$rows"
}

devhost_boot_record() {
  [[ "${DEVHOST_BOOT_RECORD:-1}" != 0 && -n "$DEVHOST_SNAPSHOT_LOG" ]] || return 0
  local up="${1:-}" now boot_epoch s_boot="" s_first="" s_prev="" s_state="" load1="" settled=0 out
  case "$up" in ''|*[!0-9]*) return 0 ;; esac
  (( up < BOOT_RECORD_WINDOW_S + 600 )) || return 0
  now=$("$DATE_BIN" +%s)
  boot_epoch=$(( now - up ))
  if [[ -f "$BOOT_RECORD_STATE" ]]; then read -r s_boot s_first s_prev s_state < "$BOOT_RECORD_STATE" || true; fi
  case "$s_boot" in ''|*[!0-9]*) s_boot="" ;; esac
  # The boot epoch is now - uptime: exact on a real host, a second or two of jitter under the test hook.
  if [[ -n "$s_boot" ]] && (( s_boot - boot_epoch <= 60 && boot_epoch - s_boot <= 60 )); then
    [[ "$s_state" != "done" ]] || return 0
  else
    s_boot=$boot_epoch s_first=$up s_prev="" s_state=pending
  fi
  case "$s_first" in ''|*[!0-9]*) s_first=$up ;; esac
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  if (( s_first > BOOT_RECORD_LATE_S )); then
    echo "$s_boot $s_first ${s_prev:-0} done" > "$BOOT_RECORD_STATE" 2>/dev/null || true
    return 0
  fi

  out=$(run_bounded "$SNAPSHOT_TOOL_TIMEOUT" "$SYSCTL_BIN" -n vm.loadavg) || out=""
  # shellcheck disable=SC2016  # awk fields
  load1=$("$AWK_BIN" 'NR == 1 { gsub(/[{}]/, ""); print $1 }' <<<"$out")
  if [[ -n "$load1" ]] && "$AWK_BIN" -v l="$load1" -v t="$BOOT_SETTLE_LOAD" 'BEGIN { exit !(l + 0 < t + 0) }'; then settled=1; fi
  if (( ! settled && up < BOOT_RECORD_WINDOW_S )); then
    echo "$s_boot $s_first $now pending" > "$BOOT_RECORD_STATE" 2>/dev/null || true
    return 0
  fi

  local ps_out procs core_sock core_at="" uid
  uid=$(id -u)
  ps_out=$(run_bounded "$SNAPSHOT_TOOL_TIMEOUT" "$PS_BIN" -axo pid=,uid=,etime=,comm=) || ps_out=""
  procs=$(_boot_earliest_procs "$now" "$uid" "$ps_out")
  if declare -F core_socket >/dev/null 2>&1; then
    core_sock=$(core_socket)
    core_at=$("$STAT_BIN" -f %m "$core_sock" 2>/dev/null) || core_at=""
    case "$core_at" in ''|*[!0-9]*) core_at="" ;; esac
  fi
  local line
  line=$("$JQ_BIN" -nc --arg ts "$("$DATE_BIN" -u +%Y-%m-%dT%H:%M:%SZ)" --argjson up "$up" --argjson boot "$boot_epoch" \
    --argjson now "$now" --argjson first "$s_first" --arg prev "$s_prev" --arg core "$core_at" --arg load "$load1" \
    --argjson settled "$settled" --arg procs "$procs" '
      def ep: if . == "" or . == "-" then null else (tonumber? // null) end;
      def iso: if . == null then null else todate end;
      ($procs | split("\n")) as $p
      | ($p[0] | split(" ")) as $u | ($p[1] | split(" ")) as $s
      | ($u[0] | ep) as $us | ($s[0] | ep) as $ss | ($core | ep) as $cr
      | (if $settled == 1 then $now else null end) as $st
      | ($prev | ep) as $pv
      | {ts: $ts, up_s: $up,
         boot: {boot_at: ($boot | iso),
                userspace_at: ($us | iso), userspace_proc: ($u[1:] | join(" ") | if . == "-" then null else . end),
                session_at: ($ss | iso), session_proc: ($s[1:] | join(" ") | if . == "-" then null else . end),
                core_ready_at: (if $cr != null and $cr >= $boot then $cr else null end | iso),
                settled_at: ($st | iso), settled_prev_at: (if $st != null and $pv != null and $pv > 0 then $pv else null end | iso),
                settled_load: (if $settled == 1 then ($load | tonumber? // null) else null end),
                boot_to_userspace_s: (if $us != null then $us - $boot else null end),
                userspace_to_settled_s: (if $us != null and $st != null then $st - $us else null end),
                first_seen_up_s: $first}}') || line=""
  [[ -n "$line" ]] || { echo "boot record: could not build the line" >&2; return 0; }
  printf '%s\n' "$line" >> "$DEVHOST_SNAPSHOT_LOG" 2>/dev/null || { echo "boot record: cannot append to $DEVHOST_SNAPSHOT_LOG" >&2; return 0; }
  echo "$s_boot $s_first $now done" > "$BOOT_RECORD_STATE" 2>/dev/null || true
  return 0
}

# --- One push per panic --------------------------------------------------------------------------------------
# A panic recovers by itself (autorestart) and a sub-10-minute outage never reaches DOWN on the Kuma monitor
# (interval 600 s, 1 retry), so this push is the alert for it. Once per panic REPORT, not per run: the newest
# report's `<mtime> <name>` is stored after a delivered push, and only a report younger than PANIC_MAX_AGE_DAYS
# is considered, so a host that has carried an old report for weeks never pushes it. A failed push stores
# nothing and is retried by the next run (the age window ends it).
#
# Args: $1 = uptime seconds, $2 = liveness verdict text when a liveness check failed (else empty).
devhost_panic_notify() {
  local up="${1:-0}" liveness_down="${2:-}" found mtime path now age_s mark
  found=$(panic_newest_report) || found=""
  [[ -n "$found" ]] || return 0
  mtime=${found%%$'\t'*}
  path=${found#*$'\t'}
  mark="$mtime ${path##*/}"
  [[ "$(cat "$PANIC_NOTIFIED_FILE" 2>/dev/null || true)" != "$mark" ]] || return 0
  now=$("$DATE_BIN" -u +%s)
  age_s=$(( now - mtime ))
  (( age_s < PANIC_MAX_AGE_DAYS * 86400 )) || return 0

  local headline boot_epoch ready title body
  headline=$(panic_headline "$path")
  boot_epoch=$(( now - up ))
  if [[ -n "$liveness_down" ]]; then ready="not ready ${up}s after boot: ${liveness_down}"
  elif (( up < 3600 )); then ready="ready ${up}s after boot (first heartbeat found tailnet, sshd and the core alive)"
  else ready="boot was ${up}s ago, time to ready not measured (no heartbeat in its first hour)"; fi
  title="Mini panicked and rebooted"
  body=$(printf '%s\nboot %s, report %s (%s)\n%s\nSnapshots: ~/Library/Logs/devhost-snapshots.jsonl' \
    "$headline" "$("$DATE_BIN" -r "$boot_epoch" '+%Y-%m-%d %H:%M:%S %Z')" "${path##*/}" \
    "$("$DATE_BIN" -r "$mtime" '+%Y-%m-%d %H:%M:%S %Z')" "$ready")
  if devhost_ntfy "$PANIC_NTFY_TOPIC" "$title" "$body"; then
    printf '%s\n' "$mark" > "$PANIC_NOTIFIED_FILE" 2>/dev/null || echo "panic push: cannot write $PANIC_NOTIFIED_FILE (will repeat)" >&2
    echo "panic push sent: $headline" >&2
  else
    echo "panic push failed (retried next run): $headline" >&2
  fi
  return 0
}

# devhost_ntfy <topic> <title> <body> — the bearer from the secrets cache (never `op`: it hangs on the mini), the
# server host from NTFY_URL or the homelab repo's ntfy config (the host is private, this repo is public).
devhost_ntfy() {
  local topic="$1" title="$2" body="$3" token base
  [[ -x "$SECRETS_RUN_BIN" ]] || return 1
  token=$("$SECRETS_RUN_BIN" read op://common/ntfy/TOKEN 2>/dev/null) || return 1
  [[ -n "$token" ]] || return 1
  base="${NTFY_URL:-}"
  if [[ -z "$base" && -r "$NTFY_CONFIG" ]]; then
    base=$("$SED_BIN" -n 's/^base-url:[[:space:]]*"\{0,1\}\([^"[:space:]]*\)"\{0,1\}[[:space:]]*$/\1/p' "$NTFY_CONFIG" | head -1)
  fi
  [[ -n "$base" ]] || return 1
  "$CURL_BIN" -fsS --max-time 10 -o /dev/null -X POST "${base%/}/$topic" \
    -H "Authorization: Bearer $token" -H "Title: $title" -H "Priority: high" -H "Tags: rotating_light" \
    --data-binary "$body" >/dev/null 2>&1
}
