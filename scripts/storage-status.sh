#!/usr/bin/env bash
# storage-status — one page for "are my drives connected and are my copies fresh" (docs/storage.md §Status).
#
#   storage-status.sh            table for a person
#   storage-status.sh --json     one object, the contract in docs/storage.md §Status (the Tinycast command reads it)
#   --no-remote                  skip the one network read that is not a mount (the restic age from Uptime Kuma)
#
# READ-ONLY and BOUNDED: it never mounts, unmounts or writes anything but its own temp dir, and every external call has a
# deadline. A hung smbfs call is abandoned (killed, never waited on: it can sit in the kernel), so a dead mount costs
# STORAGE_PROBE_SECONDS, not forever; the shares are probed in parallel.
#
# The mount probe reads nothing from the share. A launchd job (the heartbeat that calls this) cannot LIST an SMB mount:
# macOS answers "Operation not permitted" or hangs on a Network Volumes prompt, unless the program holds that grant
# (docs/storage.md §Mounts). So it is the keepalive's probe (smb/smb-keepalive.sh, issue 1106), not its `ls`: `stat` of the
# mount root, then `stat` of a name that cannot exist, which has to reach the server (ENOENT = healthy, a hang = a silent
# server, "Operation timed out" = a dropped session). `df` only supplies free and total (it is answered from cache, so it
# proves nothing about liveness) and must name an SMB file system. `smbutil statshares` is not used: it hangs under a job.
#
# Sources: the mount table + declared shares (dotfiles-private/smb-shares.conf, for this host), the keepalive's graded jobrun
# row (scripts/lib/jobs-grade.ts), and on the mini the external volume gate (scripts/lib/volume-gate.sh), the mirror's
# <volume>/mirror/.status.json, and the age of the last restic success from the Uptime Kuma push monitor (the read
# `make doctor` already makes: keyless ssh, no new credential). A source that does not exist yet is null with a reason.
#
# Exit 0 whenever a status was produced (warnings are data, never a failure); 1 on a missing dependency; 2 on usage.
# Never put a server name in the output: the shares are reported by their share name only. BASH 3.2.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES_DIR="${DOTFILES_DIR:-$(cd "$HERE/.." && pwd)}"
CONF="${SMB_SHARES_CONF:-$HOME/SourceRoot/dotfiles-private/smb-shares.conf}"
PROBE_SECONDS="${STORAGE_PROBE_SECONDS:-5}"
KEEPALIVE_LABEL="${STORAGE_KEEPALIVE_LABEL:-com.jkrumm.smb-keepalive}"
MIRROR_MAX_AGE_HOURS="${STORAGE_MIRROR_MAX_AGE_HOURS:-36}"
KUMA_HOST="${KUMA_HOST:-homelab}"
KUMA_DB="${KUMA_DB:-/home/jkrumm/ssd/uptime-kuma/kuma.db}"
KUMA_MONITOR="${STORAGE_KUMA_MONITOR:-Restic Backup - Push}"

MODE=table
REMOTE=1
for arg in "$@"; do
  case "$arg" in
    --json) MODE=json ;;
    --no-remote) REMOTE=0 ;;
    *) echo "usage: $(basename "$0") [--json] [--no-remote]" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "storage-status: jq is required" >&2; exit 1; }

# Which host: the secrets backend marker (cache = the mini). STORAGE_HOST_KIND is the test seam.
host_kind="${STORAGE_HOST_KIND:-}"
if [ -z "$host_kind" ]; then
  MARKER="${XDG_CONFIG_HOME:-$HOME/.config}/secrets/backend"
  if [ "$(tr -d '[:space:]' 2>/dev/null < "$MARKER" || true)" = cache ]; then host_kind=mini; else host_kind=macbook; fi
fi

NOW="${STORAGE_NOW:-$(date +%s)}"
T=$(mktemp -d "${TMPDIR:-/tmp}/storage-status.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT

# bcap SECS OUT ERR cmd...  stdout -> OUT, stderr -> ERR. Returns the command's status; 124 = still running at the deadline
# (killed, never waited on).
bcap() {
  local secs="$1" out="$2" err="$3" pid i max
  shift 3
  "$@" </dev/null >"$out" 2>"$err" &
  pid=$!
  max=$((secs * 10))
  for ((i = 0; i < max; i++)); do
    kill -0 "$pid" 2>/dev/null || { wait "$pid"; return $?; }
    sleep 0.1
  done
  kill -9 "$pid" 2>/dev/null
  return 124
}

# --- the mount table (kernel table, no server contact) --------------------------------------------------------------------
bcap "$PROBE_SECONDS" "$T/mounts" /dev/null mount

# Mount point of //[user@]server/share (case-insensitive: smbfs reports the server the way it was typed).
mount_point() {
  awk -v want="$(printf '%s/%s' "$1" "$2" | tr '[:upper:]' '[:lower:]')" '
    / \(smbfs/ {
      src = tolower($1); sub(/^\/\/([^@]*@)?/, "", src)
      if (src == want) { sub(/^[^ ]+ on /, ""); sub(/ \(smbfs.*$/, ""); print; exit }
    }' "$T/mounts"
}

# --- one share (runs in a subshell; writes $T/share.<n>.json) -------------------------------------------------------------
share_probe() {
  local n="$1" server="$2" share="$3" automount="$4"
  local mp reach=null state reason="" healthy=null free=null total=null rc out="$T/s$n"
  mp=$(mount_point "$server" "$share")
  if bcap "$PROBE_SECONDS" /dev/null /dev/null nc -z -G 3 "$server" 445; then reach=true; else reach=false; fi

  if [ -z "$mp" ]; then
    if [ "$reach" = true ]; then state=not_mounted; reason="reachable, not mounted"
    else state=unreachable; reason="server not reachable on 445 (HomeLab down, Tailscale down or off-tailnet)"; fi
  else
    state=healthy
    # 1. the root is there (answered from cache: it only proves the mount exists)
    bcap "$PROBE_SECONDS" "$out.stat" "$out.stat.err" stat "$mp"; rc=$?
    if [ "$rc" -eq 124 ]; then state=stale; reason="stat hung > ${PROBE_SECONDS}s"
    elif [ "$rc" -ne 0 ]; then
      if grep -q "Operation not permitted" "$out.stat.err" 2>/dev/null; then state=unprobeable; reason="macOS refuses the probe (Operation not permitted)"
      else state=stale; reason="stat failed"; fi
    fi
    # 2. a name that cannot exist: the lookup has to reach the server. A healthy share answers ENOENT, a silent server hangs
    #    it, a dropped session answers "Operation timed out". Reads nothing from the share, needs no grant.
    if [ "$state" = healthy ]; then
      bcap "$PROBE_SECONDS" "$out.look" "$out.look.err" stat "$mp/.storage-status-probe-$RANDOM$RANDOM"; rc=$?
      if [ "$rc" -eq 124 ]; then state=stale; reason="lookup hung > ${PROBE_SECONDS}s (the server is silent)"
      elif [ "$rc" -ne 0 ] && grep -q "Operation not permitted" "$out.look.err" 2>/dev/null; then state=unprobeable; reason="macOS refuses the probe (Operation not permitted)"
      elif [ "$rc" -ne 0 ] && ! grep -q "No such file or directory" "$out.look.err" 2>/dev/null; then state=stale; reason="lookup failed (the SMB session is gone)"; fi
    fi
    # 3. free and total from df. It is answered from cache, so it proves nothing about liveness, but a path that fell
    #    through to the boot volume answers it too: the file system must be an SMB one.
    if [ "$state" = healthy ]; then
      bcap "$PROBE_SECONDS" "$out.df" "$out.df.err" df -k -P "$mp"; rc=$?
      if [ "$rc" -ne 0 ]; then state=stale; reason="df $([ "$rc" -eq 124 ] && echo hung || echo failed)"
      else
        # filesystem = field 1 ("//user@server/share", no spaces); blocks are 1 KiB
        read -r fs total_k free_k < <(awk 'NR == 2 { print $1, $2, $4 }' "$out.df")
        case "${fs:-}" in
          //*) total=$((total_k * 1024)); free=$((free_k * 1024)) ;;
          *) state=stale; reason="df did not answer for an SMB file system (the mount is gone or hidden)" ;;
        esac
      fi
    fi
    if [ "$state" = healthy ]; then healthy=true
    elif [ "$state" = unprobeable ]; then healthy=null
    else healthy=false; free=null; total=null; fi
  fi
  jq -n --arg name "$share" --argjson automount "$([ "$automount" = yes ] && echo true || echo false)" \
    --arg mp "$mp" --argjson reach "$reach" --arg state "$state" --argjson healthy "$healthy" \
    --argjson free "$free" --argjson total "$total" --arg reason "$reason" '{
      name: $name, automount: $automount, state: $state,
      mounted: ($mp != ""), mount_point: (if $mp == "" then null else $mp end),
      reachable: $reach, healthy: $healthy, free_bytes: $free, total_bytes: $total,
      reason: (if $reason == "" then null else $reason end) }' > "$T/share.$n.json"
}

pids=""
n=0
shares_reason=""
if [ ! -f "$CONF" ]; then
  shares_reason="no share declaration (smb-shares.conf) on this machine"
else
  # Row: <server> <user> <share> <automount yes|no> [macbook|mini] — the optional last field restricts the row to one host.
  while read -r server _user share automount scope _rest; do
    case "${server:-}" in ''|\#*) continue ;; esac
    [ -n "${share:-}" ] || continue
    case "${scope:-}" in \#*) scope="" ;; esac
    case "${scope:-$host_kind}" in "$host_kind") ;; *) continue ;; esac
    n=$((n + 1))
    share_probe "$(printf '%02d' "$n")" "$server" "$share" "${automount:-no}" &
    pids="$pids $!"
  done < "$CONF"
  [ "$n" -gt 0 ] || shares_reason="no shares declared for the $host_kind"
fi

# --- the keepalive's graded row ---------------------------------------------------------------------------------------------
keepalive_probe() {
  local rows="$T/grade.json" bun_dir
  if [ -n "${STORAGE_JOBS_GRADE_CMD:-}" ]; then
    bcap 20 "$rows" /dev/null bash -c "$STORAGE_JOBS_GRADE_CMD"
  else
    bun_dir=$(/bin/bash "$DOTFILES_DIR/scripts/lib/bun-bin.sh" 2>/dev/null) \
      || { echo '{"available":false,"reason":"bun not found, the job is not graded"}' > "$T/keepalive.json"; return; }
    bcap 20 "$rows" /dev/null "$bun_dir/bun" "$DOTFILES_DIR/scripts/lib/jobs-grade.ts"
  fi
  jq --arg label "$KEEPALIVE_LABEL" --argjson now "$NOW" '
    def iso: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
    ([.[]? | select(.label == $label)] | first) as $r
    | if $r == null then {available: false, reason: "no jobrun state for \($label)"}
      else {available: true, reason: ($r.reason // null), grade: $r.grade, rc: $r.rc,
            last_run: $r.last_started, last_run_age_seconds: (if $r.last_started then $now - ($r.last_started | iso) else null end),
            last_ok: ($r.last_ok // null), consecutive_fail: ($r.consecutive_fail // 0)} end' "$rows" > "$T/keepalive.json" 2>/dev/null \
    || echo '{"available":false,"reason":"the job grader gave no answer"}' > "$T/keepalive.json"
  [ -s "$T/keepalive.json" ] || echo '{"available":false,"reason":"the job grader gave no answer"}' > "$T/keepalive.json"
}
keepalive_probe &
pids="$pids $!"

# --- restic: age of the last success, from the Uptime Kuma push monitor ---------------------------------------------------------
backup_probe() {
  local out="$T/kuma.out" rc sql
  if [ "$REMOTE" -eq 0 ]; then
    echo '{"available":false,"reason":"skipped (--no-remote)"}' > "$T/backup.json"; return
  fi
  sql="SELECT strftime('%s', MAX(h.time)) FROM heartbeat h JOIN monitor m ON m.id = h.monitor_id WHERE m.name = '$KUMA_MONITOR' AND h.status = 1;"
  bcap 10 "$out" /dev/null ssh -o ConnectTimeout=6 -o BatchMode=yes "$KUMA_HOST" "sqlite3 -readonly '$KUMA_DB' \"$sql\""; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo '{"available":false,"reason":"Uptime Kuma not reachable, read over keyless ssh (not a backup fault)"}' > "$T/backup.json"; return
  fi
  jq -n --argjson now "$NOW" --arg v "$(tr -d '[:space:]' < "$out")" '
    if ($v | test("^[0-9]+$")) then
      {available: true, reason: null, source: "uptime-kuma push monitor", last_success_epoch: ($v | tonumber),
       last_success: (($v | tonumber) | todateiso8601), age_seconds: ($now - ($v | tonumber))}
    else {available: false, reason: "the push monitor has no successful heartbeat"} end' > "$T/backup.json"
}
backup_probe &
pids="$pids $!"

# --- the mini's external volume and the mirror ----------------------------------------------------------------------------------
volume_probe() {
  local state root total=null free=null out="$T/vol" reason
  # shellcheck source=lib/volume-gate.sh
  . "$HERE/lib/volume-gate.sh"
  volume_gate_state
  state="$VG_STATE"; root="$VG_ROOT"
  case "$state" in
    unattached) reason="not adopted yet (attached=false in config/external-volume.json)" ;;
    present) reason="" ;;
    *) reason="the volume is $state; dependents skip themselves (docs/external-ssd.md)" ;;
  esac
  if [ "$state" = present ] && bcap "$PROBE_SECONDS" "$out.df" /dev/null df -k -P "$root"; then
    read -r total_k free_k < <(awk 'NR == 2 { print $2, $4 }' "$out.df")
    [ -z "${total_k:-}" ] || { total=$((total_k * 1024)); free=$((free_k * 1024)); }
  fi
  jq -n --arg state "$state" --arg reason "$reason" --argjson free "$free" --argjson total "$total" '{
    available: ($state != "unattached"), state: $state, free_bytes: $free, total_bytes: $total,
    reason: (if $reason == "" then null else $reason end)}' > "$T/volume.json"

  # The mirror's status file (plan row ext-mirror writes <volume>/mirror/.status.json after each run).
  if [ "$state" != present ]; then
    jq -n --arg r "the external volume is $state" '{available: false, reason: $r}' > "$T/mirror.json"; return
  fi
  if ! bcap "$PROBE_SECONDS" "$out.mirror" /dev/null cat "$root/mirror/.status.json"; then
    echo '{"available":false,"reason":"not built yet: no mirror/.status.json on the volume (plan row ext-mirror)"}' > "$T/mirror.json"; return
  fi
  jq --argjson now "$NOW" '
    def iso: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
    (.finished | if type == "number" then . elif type == "string" then (try iso catch null) else null end) as $fin
    | if $fin == null then {available: false, reason: "mirror/.status.json has no readable \"finished\" time"}
      else {available: true, reason: null, finished: ($fin | todateiso8601), age_seconds: ($now - $fin), sources: (.sources // null)} end' \
    "$out.mirror" > "$T/mirror.json" 2>/dev/null \
    || echo '{"available":false,"reason":"mirror/.status.json is not valid JSON"}' > "$T/mirror.json"
}
if [ "$host_kind" = mini ]; then
  volume_probe &
  pids="$pids $!"
else
  echo '{"available":false,"state":null,"free_bytes":null,"total_bytes":null,"reason":"mini only"}' > "$T/volume.json"
  echo '{"available":false,"reason":"mini only"}' > "$T/mirror.json"
fi

# shellcheck disable=SC2086  # a word list of pids on purpose
wait $pids

# --- assemble -------------------------------------------------------------------------------------------------------------------
if ls "$T"/share.*.json >/dev/null 2>&1; then jq -s '.' "$T"/share.*.json > "$T/shares.json"; else echo '[]' > "$T/shares.json"; fi

jq -n --argjson now "$NOW" --arg host "$host_kind" --arg shares_reason "$shares_reason" --argjson max_h "$MIRROR_MAX_AGE_HOURS" \
  --slurpfile shares "$T/shares.json" --slurpfile keepalive "$T/keepalive.json" --slurpfile volume "$T/volume.json" \
  --slurpfile mirror "$T/mirror.json" --slurpfile backup "$T/backup.json" '
  {
    schema: 1,
    generated_at: ($now | todateiso8601),
    host: $host,
    shares: $shares[0],
    shares_reason: (if $shares_reason == "" then null else $shares_reason end),
    keepalive: $keepalive[0],
    external_volume: $volume[0],
    mirror: $mirror[0],
    backup: $backup[0]
  }
  | .warnings = (
      [ .shares[] | select(.automount and .state != "healthy" and .state != "unprobeable")
        | {code: "share_not_healthy", subject: .name, message: "\(.name) is \(.state): \(.reason)"} ]
      + [ select(.mirror.available and .mirror.age_seconds > ($max_h * 3600))
          | {code: "mirror_stale", subject: "mirror", message: "the mirror finished \((.mirror.age_seconds / 3600) | floor) h ago (limit \($max_h) h)"} ])' > "$T/status.json" \
  || { echo "storage-status: could not assemble the status" >&2; exit 1; }

if [ "$MODE" = json ]; then cat "$T/status.json"; exit 0; fi

# --- table ----------------------------------------------------------------------------------------------------------------------
jq -r --arg home "$HOME" '
  def gib: if . >= 1099511627776 then ((. / 1099511627776 * 10 | round) / 10 | tostring) + " TiB" else ((. / 1073741824 * 10 | round) / 10 | tostring) + " GiB" end;
  def ago: if . == null then "never" elif . < 120 then "\(.)s ago" elif . < 7200 then "\((. / 60) | floor) min ago"
           elif . < 172800 then "\((. / 3600) | floor) h ago" else "\((. / 86400) | floor) d ago" end;
  def pad($n): . + (" " * ([$n - length, 1] | max));
  def tilde: if . == null then "-" else sub("^" + $home; "~") end;
  "storage on \(.host), \(.generated_at)",
  "",
  (if .shares_reason then "  shares      \(.shares_reason)" else empty end),
  (.shares[] | "  " + (.name | pad(6)) + (.state | pad(13)) + (.mount_point | tilde | pad(26))
      + (if .free_bytes then "\(.free_bytes | gib) free of \(.total_bytes | gib)" else (.reason // "") end)),
  "",
  "  keepalive   " + (if .keepalive.available then "\(.keepalive.grade), last run \(.keepalive.last_run_age_seconds | ago), \(.keepalive.consecutive_fail) failed in a row" + (if .keepalive.reason then " (\(.keepalive.reason))" else "" end)
                       else "-  \(.keepalive.reason)" end),
  "  volume      " + (if .external_volume.available then (.external_volume.state + (if .external_volume.free_bytes then ", \(.external_volume.free_bytes | gib) free of \(.external_volume.total_bytes | gib)" else "" end))
                       else "-  \(.external_volume.reason)" end),
  "  mirror      " + (if .mirror.available then "finished \(.mirror.age_seconds | ago)" else "-  \(.mirror.reason)" end),
  "  restic      " + (if .backup.available then "last success \(.backup.age_seconds | ago)" else "-  \(.backup.reason)" end),
  (if (.warnings | length) > 0 then "", (.warnings[] | "  WARN \(.message)") else empty end)' "$T/status.json"
exit 0
