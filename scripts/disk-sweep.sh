#!/usr/bin/env bash
# Bound the things that regrow on disk. Daily, via com.jkrumm.disk-sweep
# (see scripts/com.jkrumm.disk-sweep.plist.template). Usage: disk-sweep.sh [step...]
# — no arguments runs every step, in order; the test suite names only the hermetic ones.
#
# WHY THIS EXISTS. The mini ran short of disk (2026-10-20) and every large consumer turned out
# to be an unbounded cache or leak that nothing swept: Docker build cache and dangling images,
# the Colima data disk (a sparse file that never shrinks on its own), OCR session logs (11 GB),
# $TMPDIR (300k+ entries — test suites in warden and agent-gateway leak tmp dirs) and the
# package-manager caches. Each step is one bounded rule; none touches anything that holds state.
#
# THE DOCKER STEP IS DELIBERATELY NARROW. Build cache is capped (LRU) and dangling images go.
# Never `image prune -a`, `volume prune` or `container prune`: named volumes hold data
# (databases) and weatherorb's tagged images are production — an unused-looking image is the
# rollback target.
#
# WHY colima-trim FOLLOWS docker. Pruned space stays inside the VM's data disk until fstrim
# tells the host the blocks are free (measured 2026-10-20: 83 GiB trimmed, +37 GiB host free).
#
# CONTRACT. Every step prints one line, `<step>: <what was removed>, free space +<N> MB`, measured
# with df on the volume it frees. A step whose tool is missing or unreachable prints one
# "skipped: <reason>" line and counts as success (this runs on both machines). One step failing
# never stops the others, but the script exits non-zero at the end so jobs-grade grades the
# run. Overrides (also what the test suite uses): DISK_SWEEP_TMPDIR, OCR_SESSIONS_ROOT,
# DISK_SWEEP_BUILDCACHE_MAX, DISK_SWEEP_NPM_MAX_GB, DISK_SWEEP_BUN_MAX_GB.

set -euo pipefail

BUILDCACHE_MAX="${DISK_SWEEP_BUILDCACHE_MAX:-15GB}"
NPM_MAX_GB="${DISK_SWEEP_NPM_MAX_GB:-3}"
BUN_MAX_GB="${DISK_SWEEP_BUN_MAX_GB:-5}"
OCR_ROOT="${OCR_SESSIONS_ROOT:-$HOME/.opencodereview/sessions}"

STEPS=(docker colima-trim ocr-sessions tmpdir pkg-caches simulators)

free_kb() { df -k "$1" 2>/dev/null | awk 'NR==2 {print $4}'; }

# "free space +N MB" for a before/after pair of free_kb readings.
delta() { echo "free space +$(( ($2 - $1) / 1024 )) MB"; }

skip() { echo "$1: skipped: $2"; }

# Bound a command that can hang (an unreachable daemon). Plain run when no timeout binary exists.
with_timeout() {
  local secs=$1; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"
  else "$@"; fi
}

# The last "Total..." line docker prints, reduced to its figure: "Total reclaimed space: 1.2GB" -> 1.2GB.
docker_total() { awk '/^Total/ {sub(/^[^:]*:[[:space:]]*/, ""); last=$0} END {print last}' <<<"$1"; }

step_docker() {
  command -v docker >/dev/null 2>&1 || { skip docker "docker not installed"; return 0; }
  with_timeout 20 docker info >/dev/null 2>&1 || { skip docker "daemon not reachable"; return 0; }
  local before after cache images
  before=$(free_kb "$HOME")
  cache=$(docker builder prune -f --max-used-space "$BUILDCACHE_MAX" 2>&1) \
    || { echo "docker: builder prune failed: $(tail -n 1 <<<"$cache")"; return 1; }
  images=$(docker image prune -f 2>&1) \
    || { echo "docker: image prune failed: $(tail -n 1 <<<"$images")"; return 1; }
  after=$(free_kb "$HOME")
  # The VM keeps the blocks until colima-trim, so the host figure is expected to read ~0 here.
  echo "docker: build cache capped at $BUILDCACHE_MAX (reclaimed $(docker_total "$cache")), dangling images removed (reclaimed $(docker_total "$images")), $(delta "$before" "$after")"
}

step_colima-trim() {
  command -v colima >/dev/null 2>&1 || { skip colima-trim "colima not installed"; return 0; }
  colima status >/dev/null 2>&1 || { skip colima-trim "colima not running"; return 0; }
  local before after out
  before=$(free_kb "$HOME")
  out=$(colima ssh -- sudo fstrim -a -v 2>&1) \
    || { echo "colima-trim: fstrim failed: $(tail -n 1 <<<"$out")"; return 1; }
  after=$(free_kb "$HOME")
  # The data disk is the mount the VM names lima-colima; fall back to every line if the name moves.
  local summary
  summary=$(grep 'lima-colima' <<<"$out" || printf '%s' "$out")
  echo "colima-trim: $(tr '\n' ';' <<<"$summary" | sed 's/;$//'), $(delta "$before" "$after")"
}

# agent-gateway reads only the session logs of the attempt that just failed (server/lib/ocr.ts),
# so anything older than two weeks is dead weight.
step_ocr-sessions() {
  [ -d "$OCR_ROOT" ] || { skip ocr-sessions "no sessions dir at $OCR_ROOT"; return 0; }
  local before after files dirs
  before=$(free_kb "$OCR_ROOT")
  files=$(find "$OCR_ROOT" -type f -mtime +14 -print -delete | wc -l | tr -d ' ')
  dirs=$(find "$OCR_ROOT" -mindepth 1 -type d -empty -print -delete | wc -l | tr -d ' ')
  after=$(free_kb "$OCR_ROOT")
  echo "ocr-sessions: $files files older than 14 days and $dirs empty dirs removed from $OCR_ROOT, $(delta "$before" "$after")"
}

# Top-level entries only, older than 3 days, not currently open. The open set comes from ONE lsof
# call for the whole machine: `lsof +D` per entry over 300k entries would never finish. Entries
# carrying the sunlnk flag are macOS daemon state (SIP-protected, rm fails on them): never touched.
step_tmpdir() {
  [ -x /usr/sbin/lsof ] || { skip tmpdir "/usr/sbin/lsof missing — cannot tell which entries are open"; return 0; }
  local root=${DISK_SWEEP_TMPDIR:-$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)}
  root=${root%/}
  [ -n "$root" ] && [ -d "$root" ] || { skip tmpdir "no tmp dir${root:+ at $root}"; return 0; }
  # lsof reports resolved paths (/private/var/...), so match against the resolved root.
  root=$(cd "$root" && pwd -P)

  local before after open list entry name removed
  before=$(free_kb "$root")
  open=$(/usr/sbin/lsof -Fn 2>/dev/null \
    | awk -v p="$root/" 'index($0, "n" p) == 1 {s = substr($0, length(p) + 2); sub(/\/.*/, "", s); if (s != "") print s}' \
    | sort -u || true)
  list=$(mktemp)
  while IFS= read -r -d '' entry; do
    name=${entry##*/}
    # Apple-owned entries (sockets, launchd and dirhelper state) are not ours to remove.
    case "$name" in com.apple.*) continue ;; esac
    case $'\n'"$open"$'\n' in *$'\n'"$name"$'\n'*) continue ;; esac
    printf '%s\0' "$entry"
  done < <(find "$root" -mindepth 1 -maxdepth 1 -mmin +4320 ! -flags +sunlnk -print0) > "$list"
  removed=$(tr -cd '\0' < "$list" | wc -c | tr -d ' ')
  xargs -0 rm -rf -- < "$list" || true
  rm -f "$list"
  after=$(free_kb "$root")
  echo "tmpdir: $removed entries older than 3 days removed from $root, $(delta "$before" "$after")"
}

dir_kb() { du -sk "$1" 2>/dev/null | awk '{print $1}'; }

step_pkg-caches() {
  local before after parts="" rc=0 kb
  before=$(free_kb "$HOME")

  if command -v uv >/dev/null 2>&1; then
    if uv cache prune >/dev/null 2>&1; then parts+="uv pruned, "; else parts+="uv prune FAILED, "; rc=1; fi
  fi

  if command -v brew >/dev/null 2>&1; then
    if brew cleanup -s >/dev/null 2>&1; then parts+="brew cleaned, "; else parts+="brew cleanup FAILED, "; rc=1; fi
  fi

  local npm_dir="${npm_cache:-$HOME/.npm}/_cacache"
  if [ -d "$npm_dir" ]; then
    kb=$(dir_kb "$npm_dir")
    if [ "${kb:-0}" -le $((NPM_MAX_GB * 1024 * 1024)) ]; then
      parts+="npm cache $((kb / 1024)) MB under cap, "
    elif command -v npm >/dev/null 2>&1; then
      if npm cache clean --force >/dev/null 2>&1; then parts+="npm cache cleared ($((kb / 1024)) MB), "; else parts+="npm cache clean FAILED, "; rc=1; fi
    else
      # launchd's PATH has no fnm-managed node; the cache is a plain directory, which is all `npm cache clean` empties.
      if rm -rf -- "$npm_dir"; then parts+="npm cache removed ($((kb / 1024)) MB, npm not on PATH), "; else parts+="npm cache removal FAILED, "; rc=1; fi
    fi
  fi

  local bun_dir="$HOME/.bun/install/cache"
  if [ -d "$bun_dir" ] && command -v bun >/dev/null 2>&1; then
    kb=$(dir_kb "$bun_dir")
    if [ "${kb:-0}" -le $((BUN_MAX_GB * 1024 * 1024)) ]; then
      parts+="bun cache $((kb / 1024)) MB under cap, "
    else
      # bun refuses `pm cache rm` outside a project, so run it from a scratch one.
      local scratch
      scratch=$(mktemp -d)
      echo '{}' > "$scratch/package.json"
      if (cd "$scratch" && bun pm cache rm >/dev/null 2>&1); then parts+="bun cache cleared ($((kb / 1024)) MB), "; else parts+="bun cache rm FAILED, "; rc=1; fi
      rm -rf "$scratch"
    fi
  fi

  after=$(free_kb "$HOME")
  [ -n "$parts" ] || { skip pkg-caches "no package manager found"; return 0; }
  echo "pkg-caches: ${parts}$(delta "$before" "$after")"
  return "$rc"
}

step_simulators() {
  command -v xcrun >/dev/null 2>&1 && with_timeout 20 xcrun --find simctl >/dev/null 2>&1 \
    || { skip simulators "xcrun simctl not available"; return 0; }
  local before after out
  before=$(free_kb "$HOME")
  out=$(with_timeout 300 xcrun simctl delete unavailable 2>&1) \
    || { echo "simulators: simctl delete unavailable failed: $(tail -n 1 <<<"$out")"; return 1; }
  after=$(free_kb "$HOME")
  echo "simulators: unavailable simulators deleted, $(delta "$before" "$after")"
}

if [ "$#" -gt 0 ]; then SELECTED=("$@"); else SELECTED=("${STEPS[@]}"); fi

for name in "${SELECTED[@]}"; do
  case " ${STEPS[*]} " in *" $name "*) ;; *) echo "disk-sweep: unknown step '$name' (known: ${STEPS[*]})" >&2; exit 2 ;; esac
done

start=$(free_kb "$HOME")
failed=0
for name in "${SELECTED[@]}"; do
  if ! "step_$name"; then
    echo "$name: FAILED" >&2
    failed=$((failed + 1))
  fi
done
end=$(free_kb "$HOME")

echo "$(date '+%Y-%m-%d %H:%M:%S') disk-sweep: ${#SELECTED[@]} steps, $failed failed, $(delta "$start" "$end")"
[ "$failed" -eq 0 ]
