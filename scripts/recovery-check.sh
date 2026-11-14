#!/bin/bash
# recovery-check.sh — the measured answer to "did every Claude terminal come back after a boot?", read-only.
#
#   recovery_measure <since-epoch>   fills RECOVERY_JSON; returns 0 measured, 1 no launchd-born core (RECOVERY_WHY), 2 hc did not answer
#   recovery_line                    the human line from RECOVERY_JSON
#   recovery_warn_due <running> <resumable> <age_s>   0 when the heartbeat should WARN
#   recovery_heartbeat <uptime_s> <stamp-file> <tailnet-running 0|1>   the heartbeat's bounded sub-check
#
# Three numbers over the kept terminals (docs/devhost-health.md §Recovery after a boot):
#   resumable  state live, keep on, labelled jk.claude.session (what hc-resume may bring back)
#   running    resumable AND the foreground is `claude` (or the agent reported itself: status.app, the same live-agent
#              rule hc-resume uses, because a foreground fact can be stale)
#   waiting    resumable, not running, the foreground is positively a login shell: hc-resume has not typed yet, or
#              typed and Claude is still loading
#   skipped    the rest of resumable: foreground unknown or some other program; hc-resume never types into those
# running + waiting + skipped = resumable. Each terminal also carries hc-resume's last verdict since boot, read from
# ~/Library/Logs/hc-resume.log: sent (at), skipped / failed (with the reason).
#
# NEVER starts anything. Any `hc` call starts a core when none answers, so lib/core-up.sh (bare socket connect + ps)
# runs first and no `hc` is called unless a launchd-born core answers. The only hc traffic is one `terminal.list`
# request over `hc connect`, bounded at 5 s. Writes nothing but, in the heartbeat path, one line to the snapshot log.
#
# Run: bash recovery-check.sh [--json] [--since <epoch>]   exit 0 measured, 1 not measured. `make recovery-check`.
# bash 3.2 (launchd hands the heartbeat Apple's /bin/bash).
#
# Overrides (tests): HC_BIN, JQ_BIN, RECOVERY_RESUME_LOG, RECOVERY_HC_TIMEOUT, plus lib/core-up.sh's (PS_BIN, NC_BIN, HC_SOCKET).

# shellcheck source=lib/core-up.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/core-up.sh"

RECOVERY_WINDOW_SECONDS="${DEVHOST_RECOVERY_WINDOW_S:-2700}"   # the heartbeat measures only this long after boot (45 min)
RECOVERY_WARN_AFTER_SECONDS="${DEVHOST_RECOVERY_WARN_AFTER_S:-600}" # WARN only this long after the tailnet came up (10 min)
RECOVERY_JSON=""
RECOVERY_WHY=""

_recovery_bounded() {
  local secs="$1"; shift
  /usr/bin/perl -e 'alarm shift; exec @ARGV or exit 127' "$secs" "$@"
}

# hc-resume.log lines since <since-epoch> -> `<address>\t<kind>\t<timestamp>\t<reason>`, one per line, in log order
# (the caller keeps the last per address). Kinds: sent, skipped, failed. The log's lines:
#   <iso> resume <addr> <session> (<account>)     typed
#   <iso> resume <addr> failed: <message>         nothing typed ("skipped: ..." messages are skips)
#   <iso> skip <addr>: <reason>
_recovery_verdicts() {
  local since="$1" log="${RECOVERY_RESUME_LOG:-$HOME/Library/Logs/hc-resume.log}" since_iso
  [[ -r "$log" ]] || return 0
  since_iso=$(/bin/date -u -r "$since" +%Y-%m-%dT%H:%M:%S 2>/dev/null) || since_iso=""
  /usr/bin/awk -v since="$since_iso" '
    substr($1, 1, 19) < since { next }
    $2 == "resume" && $4 == "failed:" {
      line = $0; sub(/^[^ ]+ resume [^ ]+ failed: /, "", line)
      kind = "failed"
      if (line ~ /^skipped: /) { kind = "skipped"; sub(/^skipped: /, "", line) }
      printf "%s\t%s\t%s\t%s\n", $3, kind, $1, line; next }
    $2 == "resume" && $4 != "" { printf "%s\tsent\t%s\t\n", $3, $1; next }
    $2 == "skip" {
      addr = $3; sub(/:$/, "", addr)
      line = $0; sub(/^[^ ]+ skip [^ ]+: /, "", line)
      printf "%s\tskipped\t%s\t%s\n", addr, $1, line }
  ' "$log"
}

recovery_measure() {
  local since="${1:-0}" hc="${HC_BIN:-$HOME/.local/bin/hc}" jq="${JQ_BIN:-/usr/bin/jq}" raw terminals verdicts
  RECOVERY_JSON="" RECOVERY_WHY=""
  core_up || { RECOVERY_WHY="$CORE_UP_WHY"; return 1; }
  [[ -x "$hc" ]] || { RECOVERY_WHY="hc not installed at $hc"; return 2; }

  raw=$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"terminal.list","params":{}}' \
    | _recovery_bounded "${RECOVERY_HC_TIMEOUT:-5}" "$hc" connect 2>/dev/null) || raw=""
  terminals=$("$jq" -c 'select(.id == 1) | .result.terminals // empty' <<<"$raw" 2>/dev/null | /usr/bin/head -1)
  [[ -n "$terminals" ]] || { RECOVERY_WHY="hc did not answer terminal.list within ${RECOVERY_HC_TIMEOUT:-5}s"; return 2; }

  verdicts=$(_recovery_verdicts "$since")
  # shellcheck disable=SC2016  # jq, not shell
  RECOVERY_JSON=$("$jq" -c --arg verdicts "$verdicts" '
    def base: split("/") | last;
    def argv0: ((.foreground.argv // [])[0] // "");
    def login_shell:
      (.foreground.argv // []) as $a
      | ($a | length) > 0
        and (["sh","bash","zsh","fish","dash","ksh"] | index($a[0] | ltrimstr("-") | base)) != null
        and (($a[0] | startswith("-")) or ($a[1:] | any(. == "-l" or . == "--login")));
    ($verdicts | split("\n") | map(select(length > 0) | split("\t") | {key: .[0], value: {kind: .[1], at: .[2], reason: (.[3] // "")}})
      | from_entries) as $v
    | [.[] | select(.state == "live" and .keep == true and ((.labels["jk.claude.session"] // "") != ""))
       | (if ((argv0 | base) == "claude") or ((.status.app // "") != "") then "running"
          elif login_shell then "waiting" else "skipped" end) as $s
       | ($v[.address] // null) as $d
       | {address, name: (.name // null), state: $s,
          verdict: ($d.kind // null), at: ($d.at // null),
          reason: (if $d != null and $d.reason != "" then $d.reason
                   elif $s == "skipped" then (if .foreground == null then "foreground unknown" else "foreground is \(argv0 | base)" end)
                   else null end)}] as $r
    | {resumable: ($r | length),
       running: ($r | map(select(.state == "running")) | length),
       waiting: ($r | map(select(.state == "waiting")) | length),
       skipped: ($r | map(select(.state == "skipped")) | length),
       sent: ($r | map(select(.verdict == "sent")) | length),
       terminals: $r}' <<<"$terminals" 2>/dev/null) || RECOVERY_JSON=""
  [[ -n "$RECOVERY_JSON" ]] || { RECOVERY_WHY="terminal.list is not the JSON this check reads"; return 2; }
  return 0
}

recovery_line() {
  "${JQ_BIN:-/usr/bin/jq}" -r '"recovery: \(.resumable) resumable, \(.running) running claude, \(.waiting) waiting, \(.skipped) skipped"' <<<"$RECOVERY_JSON"
}

# WARN when fewer are running than are resumable, once the tailnet has been up long enough (ten minutes) that hc-resume's
# pacing (about 75 s for 25 sessions) and Claude's own start are over. Never a FAIL: a session someone closed on purpose
# stays labelled and counts as waiting.
recovery_warn_due() {
  local running="$1" resumable="$2" age="${3:-}"
  case "$age" in ''|*[!0-9]*) return 1 ;; esac
  (( age >= RECOVERY_WARN_AFTER_SECONDS && running < resumable ))
}

# Seconds since the heartbeat first saw the tailnet Running in this boot; empty when it has not. The stamp is the epoch of
# that first sight, valid only if written after the boot (now - uptime), so a stamp left by the previous boot is replaced.
_recovery_tailnet_age() {
  local uptime_s="$1" stamp="$2" running="$3" now at=""
  now=$(/bin/date +%s)
  [[ -f "$stamp" ]] && read -r at < "$stamp"
  case "$at" in ''|*[!0-9]*) at="" ;; esac
  if [[ -n "$at" ]] && (( at < now - uptime_s - 60 )); then at=""; fi
  if [[ -z "$at" && "$running" == 1 ]]; then
    at=$now
    echo "$at" > "$stamp" 2>/dev/null || true
  fi
  [[ -n "$at" ]] && echo $(( now - at ))
  return 0
}

# The heartbeat's sub-check (check_core calls it). Prints one line, or nothing when it is off, past the window, or no
# core answers (check_core already reports that). Returns 0, or 2 for the WARN. Appends the counts to
# DEVHOST_SNAPSHOT_LOG when set. DEVHOST_RECOVERY=0 turns it off.
recovery_heartbeat() {
  local uptime_s="$1" stamp="$2" running="${3:-0}" age line rc=0 jq="${JQ_BIN:-/usr/bin/jq}" now
  [[ "${DEVHOST_RECOVERY:-1}" != 0 ]] || return 0
  case "$uptime_s" in ''|*[!0-9]*) return 0 ;; esac
  (( uptime_s < RECOVERY_WINDOW_SECONDS )) || return 0

  now=$(/bin/date +%s)
  recovery_measure $(( now - uptime_s )) || rc=$?
  if (( rc == 1 )); then return 0; fi
  if (( rc == 2 )); then echo "recovery: not measured ($RECOVERY_WHY)"; return 0; fi

  age=$(_recovery_tailnet_age "$uptime_s" "$stamp" "$running")
  line=$(recovery_line)
  if [[ -n "${DEVHOST_SNAPSHOT_LOG:-}" ]]; then
    "$jq" -c --arg ts "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson up "$uptime_s" --arg age "$age" \
      '{ts: $ts, up_s: $up, tailnet_up_s: ($age | tonumber? // null), recovery: (del(.terminals))}' <<<"$RECOVERY_JSON" \
      >> "$DEVHOST_SNAPSHOT_LOG" 2>/dev/null || true
  fi
  # shellcheck disable=SC2046  # three integers, split on purpose
  if recovery_warn_due $("$jq" -r '"\(.running) \(.resumable)"' <<<"$RECOVERY_JSON") "$age"; then
    echo "$line (WARN: fewer running than resumable, $(( age / 60 )) min after tailnet-up; see make recovery-check)"
    return 2
  fi
  echo "$line"
}

recovery_main() {
  local json=0 since="" rc=0
  while (( $# )); do
    case "$1" in
      --json) json=1 ;;
      --since) shift; since="${1:-}" ;;
      *) echo "usage: recovery-check.sh [--json] [--since <epoch>]" >&2; return 2 ;;
    esac
    shift
  done
  if [[ -z "$since" ]]; then
    since=$(/usr/sbin/sysctl -n kern.boottime 2>/dev/null | /usr/bin/sed -n 's/^{ *sec *= *\([0-9][0-9]*\).*/\1/p')
    : "${since:=0}"
  fi
  recovery_measure "$since" || rc=$?
  if (( rc != 0 )); then
    if (( json )); then "${JQ_BIN:-/usr/bin/jq}" -nc --arg why "$RECOVERY_WHY" '{measured: false, why: $why}'
    else echo "recovery: not measured ($RECOVERY_WHY)"; fi
    return 1
  fi
  if (( json )); then echo "$RECOVERY_JSON"; else recovery_line; fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  recovery_main "$@"
  exit $?
fi
