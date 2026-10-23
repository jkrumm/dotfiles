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
# THE DOCKER STEP IS DELIBERATELY NARROW. Build cache is capped (LRU, with --all: without it only
# dangling records are eligible and the cap is not honoured — 24 GB survived a 15 GB cap) and
# dangling images go.
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
# run. A step also reports FAILED when it removes less than it set out to, or when it cannot tell
# what is safe to remove (tmpdir with no lsof answer removes nothing). Every external tool runs
# under with_timeout. Overrides (also what the test suite uses): DISK_SWEEP_TMPDIR,
# OCR_SESSIONS_ROOT, DISK_SWEEP_LSOF, DISK_SWEEP_BUILDCACHE_MAX, DISK_SWEEP_NPM_MAX_GB,
# DISK_SWEEP_BUN_MAX_GB. `make disk-sweep-run` runs every step once, docker included.

set -euo pipefail

BUILDCACHE_MAX="${DISK_SWEEP_BUILDCACHE_MAX:-15GB}"
NPM_MAX_GB="${DISK_SWEEP_NPM_MAX_GB:-3}"
BUN_MAX_GB="${DISK_SWEEP_BUN_MAX_GB:-5}"
OCR_ROOT="${OCR_SESSIONS_ROOT:-$HOME/.opencodereview/sessions}"
LSOF="${DISK_SWEEP_LSOF:-/usr/sbin/lsof}"
TOOL_TIMEOUT=600

# Cheap independent steps first, so a wedged Docker daemon cannot starve them of the job timeout.
STEPS=(ocr-sessions tmpdir pkg-caches simulators docker colima-trim)

# Free KB on the volume holding $1; 0 when df cannot say, so the arithmetic below never breaks.
free_kb() {
  local kb
  kb=$(df -k "$1" 2>/dev/null | awk 'NR==2 {print $4}') || kb=""
  echo "${kb:-0}"
}

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

# Over a NUL-separated path list ($1): how many entries it holds, and how many no longer exist.
count_listed() { tr -cd '\0' < "$1" | wc -c | tr -d ' '; }
count_gone() {
  local p n=0
  while IFS= read -r -d '' p; do
    [ -e "$p" ] || [ -L "$p" ] || n=$((n + 1))
  done < "$1"
  echo "$n"
}

step_docker() {
  command -v docker >/dev/null 2>&1 || { skip docker "docker not installed"; return 0; }
  with_timeout 20 docker info >/dev/null 2>&1 || { skip docker "daemon not reachable"; return 0; }
  local before after cache images
  before=$(free_kb "$HOME")
  cache=$(with_timeout "$TOOL_TIMEOUT" docker builder prune -f --all --max-used-space "$BUILDCACHE_MAX" 2>&1) \
    || { echo "docker: builder prune failed: $(tail -n 1 <<<"$cache")"; return 1; }
  images=$(with_timeout "$TOOL_TIMEOUT" docker image prune -f 2>&1) \
    || { echo "docker: image prune failed: $(tail -n 1 <<<"$images")"; return 1; }
  after=$(free_kb "$HOME")
  # The VM keeps the blocks until colima-trim, so the host figure is expected to read ~0 here.
  echo "docker: build cache capped at $BUILDCACHE_MAX (reclaimed $(docker_total "$cache")), dangling images removed (reclaimed $(docker_total "$images")), $(delta "$before" "$after")"
}

step_colima-trim() {
  command -v colima >/dev/null 2>&1 || { skip colima-trim "colima not installed"; return 0; }
  with_timeout 30 colima status >/dev/null 2>&1 || { skip colima-trim "colima not running"; return 0; }
  local before after out summary
  before=$(free_kb "$HOME")
  out=$(with_timeout "$TOOL_TIMEOUT" colima ssh -- sudo fstrim -a -v 2>&1) \
    || { echo "colima-trim: fstrim failed: $(tail -n 1 <<<"$out")"; return 1; }
  after=$(free_kb "$HOME")
  # The data disk is the mount the VM names lima-colima; fall back to every line if the name moves.
  summary=$(grep 'lima-colima' <<<"$out" || printf '%s' "$out")
  echo "colima-trim: $(tr '\n' ';' <<<"$summary" | sed 's/;$//'), $(delta "$before" "$after")"
}

# agent-gateway reads only the session logs of the attempt that just failed (server/lib/ocr.ts),
# so anything older than two weeks is dead weight. Counts are what is confirmed gone afterwards.
step_ocr-sessions() {
  [ -d "$OCR_ROOT" ] || { skip ocr-sessions "no sessions dir at $OCR_ROOT"; return 0; }
  local before after files_list dirs_list total files dirs left
  before=$(free_kb "$OCR_ROOT")
  files_list=$(mktemp) || { echo "ocr-sessions: FAILED: mktemp"; return 1; }
  dirs_list=$(mktemp) || { rm -f "$files_list"; echo "ocr-sessions: FAILED: mktemp"; return 1; }
  if ! find "$OCR_ROOT" -type f -mtime +14 -print0 > "$files_list"; then
    rm -f "$files_list" "$dirs_list"; echo "ocr-sessions: FAILED: find over $OCR_ROOT"; return 1
  fi
  total=$(count_listed "$files_list")
  xargs -0 rm -f -- < "$files_list" || true # judged by the re-test below, not by rm's exit
  files=$(count_gone "$files_list")
  # Deepest first, so a parent emptied by its children goes in the same pass. rmdir refuses
  # non-empty dirs, which is the expected outcome for most of them.
  if ! find "$OCR_ROOT" -mindepth 1 -depth -type d -print0 > "$dirs_list"; then
    rm -f "$files_list" "$dirs_list"; echo "ocr-sessions: FAILED: find over $OCR_ROOT"; return 1
  fi
  xargs -0 rmdir < "$dirs_list" 2>/dev/null || true
  dirs=$(count_gone "$dirs_list")
  rm -f "$files_list" "$dirs_list"
  after=$(free_kb "$OCR_ROOT")
  left=$((total - files))
  if [ "$left" -gt 0 ]; then
    echo "ocr-sessions: FAILED: $files of $total files older than 14 days removed from $OCR_ROOT ($left could not be), $dirs empty dirs removed, $(delta "$before" "$after")"
    return 1
  fi
  echo "ocr-sessions: $files files older than 14 days and $dirs empty dirs removed from $OCR_ROOT, $(delta "$before" "$after")"
}

# Top-level entries only, older than 3 days, with nothing recent beneath them, not currently open.
# The open set comes from ONE lsof call for the whole machine: `lsof +D` per entry over 300k
# entries would never finish. That set is what keeps live work safe, so without a trustworthy one
# nothing is removed. Entries carrying the sunlnk flag are macOS daemon state (SIP-protected, rm
# fails on them): never touched.
step_tmpdir() {
  [ -x "$LSOF" ] || { skip tmpdir "$LSOF missing — cannot tell which entries are open"; return 0; }
  local root=${DISK_SWEEP_TMPDIR:-$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)}
  root=${root%/}
  [ -n "$root" ] && [ -d "$root" ] || { skip tmpdir "no tmp dir${root:+ at $root}"; return 0; }
  # lsof reports resolved paths (/private/var/...), so match against the resolved root.
  root=$(cd "$root" && pwd -P) || { echo "tmpdir: FAILED: cannot resolve $root"; return 1; }

  local before after raw rc=0 open cand_list list entry name total removed left
  # Any non-zero lsof exit means the open set may be incomplete (exit 1 = some files could not be
  # listed), and an incomplete set would let rm -rf take an open entry. On the mini lsof exits 0.
  raw=$(with_timeout 300 "$LSOF" -Fn 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ] || ! grep -q '^n/' <<<"$raw"; then
    echo "tmpdir: FAILED: lsof gave no open-file set — nothing removed"
    return 1
  fi
  open=$(awk -v p="$root/" 'index($0, "n" p) == 1 {s = substr($0, length(p) + 2); sub(/\/.*/, "", s); if (s != "") print s}' <<<"$raw" | sort -u) \
    || { echo "tmpdir: FAILED: could not reduce the open-file set — nothing removed"; return 1; }

  before=$(free_kb "$root")
  cand_list=$(mktemp) || { echo "tmpdir: FAILED: mktemp"; return 1; }
  list=$(mktemp) || { rm -f "$cand_list"; echo "tmpdir: FAILED: mktemp"; return 1; }
  if ! find "$root" -mindepth 1 -maxdepth 1 -mmin +4320 ! -flags +sunlnk -print0 > "$cand_list"; then
    rm -f "$cand_list" "$list"; echo "tmpdir: FAILED: find over $root — nothing removed"; return 1
  fi
  while IFS= read -r -d '' entry; do
    name=${entry##*/}
    # Apple-owned entries (sockets, launchd and dirhelper state) are not ours to remove.
    case "$name" in com.apple.*) continue ;; esac
    case $'\n'"$open"$'\n' in *$'\n'"$name"$'\n'*) continue ;; esac
    # A directory's own mtime only moves when a direct child does: stale means nothing beneath it is recent.
    if [ -d "$entry" ] && [ ! -L "$entry" ] && [ -n "$(find "$entry" -mmin -4320 -print -quit 2>/dev/null)" ]; then continue; fi
    printf '%s\0' "$entry"
  done < "$cand_list" > "$list"
  total=$(count_listed "$list")
  xargs -0 rm -rf -- < "$list" || true # judged by the re-test below, not by rm's exit
  removed=$(count_gone "$list")
  rm -f "$cand_list" "$list"
  after=$(free_kb "$root")
  left=$((total - removed))
  if [ "$left" -gt 0 ]; then
    echo "tmpdir: FAILED: $removed of $total stale entries removed from $root ($left could not be), $(delta "$before" "$after")"
    return 1
  fi
  echo "tmpdir: $removed entries older than 3 days removed from $root, $(delta "$before" "$after")"
}

# Size in KB, or non-zero when du could not measure all of it — a cap check must not read that as 0.
dir_kb() {
  local kb
  kb=$(du -sk "$1" 2>/dev/null | awk '{print $1}') || return 1
  [ -n "$kb" ] || return 1
  echo "$kb"
}

step_pkg-caches() {
  local before after parts="" rc=0 kb
  before=$(free_kb "$HOME")

  if command -v uv >/dev/null 2>&1; then
    local uvout
    if uvout=$(with_timeout "$TOOL_TIMEOUT" uv cache prune 2>&1); then parts+="uv pruned, "; else parts+="uv prune FAILED: $(tail -n 1 <<<"$uvout"), "; rc=1; fi
  fi

  if command -v brew >/dev/null 2>&1; then
    # Best effort: brew exits 1 on any file it cannot remove, and the old caddy kegs hold root-owned
    # binaries from `make caddy-dns-build`, so a non-zero exit is reported, not graded. A timeout still fails.
    local brc=0
    with_timeout "$TOOL_TIMEOUT" env HOMEBREW_NO_AUTO_UPDATE=1 brew cleanup -s >/dev/null 2>&1 || brc=$?
    case "$brc" in
      0) parts+="brew cleaned, " ;;
      124) parts+="brew cleanup FAILED (timeout), "; rc=1 ;;
      *) parts+="brew cleaned (partial, rc=$brc), " ;;
    esac
  fi

  local npm_dir="${npm_config_cache:-$HOME/.npm}/_cacache"
  if [ -d "$npm_dir" ]; then
    if ! kb=$(dir_kb "$npm_dir"); then
      parts+="npm cache FAILED: cannot measure $npm_dir, "; rc=1
    elif [ "$kb" -le $((NPM_MAX_GB * 1024 * 1024)) ]; then
      parts+="npm cache $((kb / 1024)) MB under cap, "
    elif command -v npm >/dev/null 2>&1; then
      if with_timeout "$TOOL_TIMEOUT" npm cache clean --force >/dev/null 2>&1; then parts+="npm cache cleared ($((kb / 1024)) MB), "; else parts+="npm cache clean FAILED, "; rc=1; fi
    else
      # launchd's PATH has no fnm-managed node; the cache is a plain directory, which is all `npm cache clean` empties.
      if rm -rf -- "$npm_dir"; then parts+="npm cache removed ($((kb / 1024)) MB, npm not on PATH), "; else parts+="npm cache removal FAILED, "; rc=1; fi
    fi
  fi

  local bun_dir="$HOME/.bun/install/cache"
  if [ -d "$bun_dir" ] && command -v bun >/dev/null 2>&1; then
    if ! kb=$(dir_kb "$bun_dir"); then
      parts+="bun cache FAILED: cannot measure $bun_dir, "; rc=1
    elif [ "$kb" -le $((BUN_MAX_GB * 1024 * 1024)) ]; then
      parts+="bun cache $((kb / 1024)) MB under cap, "
    else
      # bun refuses `pm cache rm` outside a project, so run it from a scratch one.
      local scratch
      if scratch=$(mktemp -d) && echo '{}' > "$scratch/package.json" \
        && (cd "$scratch" && with_timeout "$TOOL_TIMEOUT" bun pm cache rm >/dev/null 2>&1); then
        parts+="bun cache cleared ($((kb / 1024)) MB), "
      else
        parts+="bun cache rm FAILED, "; rc=1
      fi
      [ -z "${scratch:-}" ] || rm -rf "$scratch"
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
  out=$(with_timeout "$TOOL_TIMEOUT" xcrun simctl delete unavailable 2>&1) \
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
