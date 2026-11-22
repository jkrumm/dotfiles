#!/usr/bin/env bash
# Bound the things that regrow on disk. Daily, via com.jkrumm.disk-sweep
# (see scripts/com.jkrumm.disk-sweep.plist.template). Usage: disk-sweep.sh [step...]
# — no arguments runs every step, in order; the test suite names only the hermetic ones.
#
# WHY THIS EXISTS. The mini ran short of disk (2026-10-20) and every large consumer turned out
# to be an unbounded cache or leak that nothing swept: Docker build cache and dangling images,
# the Colima data disk (a sparse file that never shrinks on its own),
# $TMPDIR (300k+ entries — test suites leaked tmp dirs) and the
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
# DISK_SWEEP_LSOF, DISK_SWEEP_PGREP, DISK_SWEEP_BUILDCACHE_MAX, DISK_SWEEP_NPM_MAX_GB,
# DISK_SWEEP_BUN_MAX_GB, DISK_SWEEP_UV_LOCK_TIMEOUT, DISK_SWEEP_FACTORY, DISK_SWEEP_SCCACHE_MAX_GB, DISK_SWEEP_SCCACHE_DIR, DISK_SWEEP_SHARED_TMP. `make disk-sweep-run` runs every step once, docker included.

set -euo pipefail

BUILDCACHE_MAX="${DISK_SWEEP_BUILDCACHE_MAX:-15GB}"
NPM_MAX_GB="${DISK_SWEEP_NPM_MAX_GB:-3}"
BUN_MAX_GB="${DISK_SWEEP_BUN_MAX_GB:-5}"
SCCACHE_MAX_GB="${DISK_SWEEP_SCCACHE_MAX_GB:-5}"
LSOF="${DISK_SWEEP_LSOF:-/usr/sbin/lsof}"
PGREP="${DISK_SWEEP_PGREP:-pgrep}"
TOOL_TIMEOUT=600
UV_LOCK_WAIT="${DISK_SWEEP_UV_LOCK_TIMEOUT:-20}"

# Cheap independent steps first, so a wedged Docker daemon cannot starve them of the job timeout.
STEPS=(tmpdir node-cache pkg-caches lima-cache simulators worktrees scratch docker colima-trim)

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

# The tmp roots the tmpdir step sweeps. Both are this user's to clear: $TMPDIR under /var/folders, and
# /private/tmp, where the same processes leave entries too (2026-11-21: 2646 stale top-level entries there, ~12 GB,
# that no step reached). DISK_SWEEP_SHARED_TMP overrides the second root; the test suite points it at a fixture, empty disables it.
# Top-level entries only, older than 3 days, owned by this user, with nothing recent beneath them, not currently open.
# The open set comes from ONE lsof call for the whole machine: `lsof +D` per entry over 300k
# entries would never finish. That set is what keeps live work safe, so without a trustworthy one
# nothing is removed. Entries carrying the sunlnk flag are macOS daemon state (SIP-protected, rm
# fails on them): never touched.

# One tmp root against the lsof output in $2. Counts into TMP_TOTAL and TMP_REMOVED; a failure is appended to
# TMP_REASONS. Always returns 0, so one root's failure never stops the other.
tmp_sweep_root() {
  local root raw=$2 open cand_list list find_err entry name total removed owner_args=""
  # "owned" (the shared /private/tmp) limits the sweep to this user's entries: it also holds root's. $TMPDIR keeps its reach.
  if [ "${3:-}" = owned ]; then owner_args="-user $(id -u)"; fi
  root=$(cd "$1" 2>/dev/null && pwd -P) || { TMP_REASONS+="${TMP_REASONS:+; }cannot resolve $1"; return 0; }
  # lsof reports resolved paths (/private/var/...), so match against the resolved root.
  open=$(awk -v p="$root/" 'index($0, "n" p) == 1 {s = substr($0, length(p) + 2); sub(/\/.*/, "", s); if (s != "") print s}' <<<"$raw" | sort -u) \
    || { TMP_REASONS+="${TMP_REASONS:+; }could not reduce the open-file set for $root — nothing removed"; return 0; }
  cand_list=$(mktemp) || { TMP_REASONS+="${TMP_REASONS:+; }mktemp"; return 0; }
  list=$(mktemp) || { rm -f "$cand_list"; TMP_REASONS+="${TMP_REASONS:+; }mktemp"; return 0; }
  find_err=$(mktemp) || { rm -f "$cand_list" "$list"; TMP_REASONS+="${TMP_REASONS:+; }mktemp"; return 0; }
  # find exits 1 when an entry vanishes between readdir and stat — routine in a tmp dir that live
  # processes churn (2026-11-21: a `.package` dotfile). A vanished entry needs no removing, so
  # "No such file or directory" alone is not a failure; any other error still is.
  # Sockets are never candidates: a bound socket can be older than 3 days and still live (a server's /tmp socket).
  if ! find "$root" -mindepth 1 -maxdepth 1 $owner_args -mmin +4320 ! -type s ! -flags +sunlnk -print0 > "$cand_list" 2> "$find_err" \
    && grep -qv ': No such file or directory$' "$find_err"; then
    rm -f "$cand_list" "$list" "$find_err"; TMP_REASONS+="${TMP_REASONS:+; }find over $root — nothing removed"; return 0
  fi
  rm -f "$find_err"
  while IFS= read -r -d '' entry; do
    name=${entry##*/}
    # Apple-owned entries (launchd and dirhelper state) and lock files (state a flock holder reuses, not stock) are not ours to remove.
    case "$name" in com.apple.*|*.lock) continue ;; esac
    case $'\n'"$open"$'\n' in *$'\n'"$name"$'\n'*) continue ;; esac
    # A directory's own mtime only moves when a direct child does: stale means nothing beneath it is recent.
    # A socket beneath it (a daemon's, live whatever its age) is recent too, and so is a tree find cannot read in
    # full: its error text is the output, so the test is non-empty and the entry is kept.
    if [ -d "$entry" ] && [ ! -L "$entry" ] && [ -n "$(find "$entry" \( -mmin -4320 -o -type s \) -print -quit 2>&1)" ]; then continue; fi
    printf '%s\0' "$entry"
  done < "$cand_list" > "$list"
  total=$(count_listed "$list")
  xargs -0 rm -rf -- < "$list" || true # judged by the re-test below, not by rm's exit
  removed=$(count_gone "$list")
  rm -f "$cand_list" "$list"
  TMP_TOTAL=$((TMP_TOTAL + total)); TMP_REMOVED=$((TMP_REMOVED + removed))
  if [ "$removed" -lt "$total" ]; then
    TMP_REASONS+="${TMP_REASONS:+; }$removed of $total stale entries removed from $root ($((total - removed)) could not be)"
  fi
  return 0
}

step_tmpdir() {
  [ -x "$LSOF" ] || { skip tmpdir "$LSOF missing — cannot tell which entries are open"; return 0; }
  local root=${DISK_SWEEP_TMPDIR:-$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)}
  root=${root%/}
  [ -n "$root" ] && [ -d "$root" ] || { skip tmpdir "no tmp dir${root:+ at $root}"; return 0; }
  local shared=${DISK_SWEEP_SHARED_TMP-/private/tmp}
  shared=${shared%/}
  local before after raw rc=0
  # Any non-zero lsof exit means the open set may be incomplete (exit 1 = some files could not be
  # listed), and an incomplete set would let rm -rf take an open entry. On the mini lsof exits 0.
  raw=$(with_timeout 300 "$LSOF" -Fn 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ] || ! grep -q '^n/' <<<"$raw"; then
    echo "tmpdir: FAILED: lsof gave no open-file set — nothing removed"
    return 1
  fi
  before=$(free_kb "$HOME")
  TMP_TOTAL=0; TMP_REMOVED=0; TMP_REASONS=""
  tmp_sweep_root "$root" "$raw" any
  if [ -n "$shared" ] && [ "$shared" != "$root" ] && [ -d "$shared" ]; then tmp_sweep_root "$shared" "$raw" owned; fi
  after=$(free_kb "$HOME")
  if [ -n "$TMP_REASONS" ]; then
    echo "tmpdir: FAILED: $TMP_REASONS, $(delta "$before" "$after")"
    return 1
  fi
  echo "tmpdir: $TMP_REMOVED entries older than 3 days removed from $root${shared:+ and $shared}, $(delta "$before" "$after")"
}

# Node's compile cache (NODE_COMPILE_CACHE, under $TMPDIR) is rewritten all day, so the tmpdir step's directory
# rule never reaches it (2026-11-21: 7.8 GB, touched every minute). Its files go by their own age: a file not written
# for 3 days is regenerable, and a node process that misses an entry just compiles it again.
step_node-cache() {
  local root=${DISK_SWEEP_TMPDIR:-$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)}
  root=${root%/}
  local dir="$root/node-compile-cache" before after list find_err total removed
  [ -n "$root" ] && [ -d "$dir" ] || { skip node-cache "no node compile cache at $dir"; return 0; }
  before=$(free_kb "$HOME")
  list=$(mktemp) || { echo "node-cache: FAILED: mktemp"; return 1; }
  find_err=$(mktemp) || { rm -f "$list"; echo "node-cache: FAILED: mktemp"; return 1; }
  # A find that cannot read part of the directory would give a partial list: judged before anything is removed.
  find "$dir" -type f -mmin +4320 -print0 > "$list" 2> "$find_err" || true
  if grep -qv ': No such file or directory$' "$find_err"; then
    rm -f "$list" "$find_err"; echo "node-cache: FAILED: find over $dir — nothing removed"; return 1
  fi
  rm -f "$find_err"
  total=$(count_listed "$list")
  xargs -0 rm -f -- < "$list" || true # judged by the re-test below, not by rm's exit
  removed=$(count_gone "$list")
  rm -f "$list"
  after=$(free_kb "$HOME")
  if [ "$removed" -lt "$total" ]; then
    echo "node-cache: FAILED: $removed of $total files not written for 3 days removed from $dir ($((total - removed)) could not be), $(delta "$before" "$after")"
    return 1
  fi
  echo "node-cache: $removed file(s) not written for 3 days removed from $dir, $(delta "$before" "$after")"
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
    local uvout uvrc=0 lockfile holder
    # A held cache lock is held for a uv process's life, and a `uv run` can outlive every sweep
    # (2026-11-21: pid 69270, six days): the plain prune then never ran. Probe with a short wait; on a
    # lock timeout prune with --force, which ignores the lock. The cache is regenerable (a process that
    # loses an entry re-fetches it). Any other uv error still fails the step.
    uvout=$(with_timeout "$TOOL_TIMEOUT" env UV_LOCK_TIMEOUT="$UV_LOCK_WAIT" uv cache prune 2>&1) || uvrc=$?
    if [ "$uvrc" -eq 0 ]; then
      parts+="uv pruned, "
    elif grep -q 'when waiting for lock' <<<"$uvout"; then
      lockfile="$(with_timeout 10 uv cache dir 2>/dev/null || true)/.lock"
      holder=$(with_timeout 10 "$LSOF" -t -- "$lockfile" 2>/dev/null | head -n 1 || true)
      if uvout=$(with_timeout "$TOOL_TIMEOUT" uv cache prune --force 2>&1); then
        parts+="uv pruned past the lock held by pid ${holder:-unknown}, "
      else
        parts+="uv prune FAILED: $(tail -n 1 <<<"$uvout"), "; rc=1
      fi
    else
      parts+="uv prune FAILED: $(tail -n 1 <<<"$uvout"), "; rc=1
    fi
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

# Lima's download cache holds every macOS IPSW a `limactl create` fetched, 16-20 GB each, and keeps it
# after the VM exists (2026-11-14: two IPSWs, 36 GB, beside two 28 GB VM disks took the mini from 86% to
# 95% and past the 90% page). A VM already created never needs its image again; re-creating one
# re-downloads it. Entries untouched for a day go, and none while a limactl create/start runs.
step_lima-cache() {
  local dir="$HOME/Library/Caches/lima/download/by-url-sha256"
  [ -d "$dir" ] || { skip lima-cache "no lima download cache"; return 0; }
  if "$PGREP" -qf 'limactl (create|start|clone)'; then skip lima-cache "limactl create/start running"; return 0; fi
  local before after n=0 left=0 entry
  before=$(free_kb "$HOME")
  while IFS= read -r -d '' entry; do
    [ -z "$(find "$entry" -mmin -1440 -print -quit 2>/dev/null)" ] || continue
    if rm -rf -- "$entry"; then n=$((n + 1)); else left=$((left + 1)); fi
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -print0)
  after=$(free_kb "$HOME")
  if [ "$left" -gt 0 ]; then
    echo "lima-cache: FAILED: $n image(s) removed, $left could not be, $(delta "$before" "$after")"
    return 1
  fi
  echo "lima-cache: $n image(s) older than 1 day removed, $(delta "$before" "$after")"
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

# A factory worktree outlives its Issue (the factory reaps processes, not directories), and its build dirs
# are regenerable: target/ (Rust, 15-60 GB per live lead) and node_modules/ (~1.3 GB each). 2026-11-21: 38 GiB
# across closed worktrees (Issue 2756). Only a worktree whose Issue the factory reports as closed is touched,
# and only its build dirs go: the source, the git checkout and a target/ with no sibling Cargo.toml stay.
# An Issue the factory cannot show is kept.
step_worktrees() {
  local factory=${DISK_SWEEP_FACTORY:-factory}
  command -v "$factory" >/dev/null 2>&1 || { skip worktrees "$factory not on PATH"; return 0; }
  command -v jq >/dev/null 2>&1 || { skip worktrees "jq not installed"; return 0; }
  local before after wt base dir issue state list total removed left closed=0
  before=$(free_kb "$HOME")
  list=$(mktemp) || { echo "worktrees: FAILED: mktemp"; return 1; }
  for wt in "$HOME"/SourceRoot/*/.claude/worktrees/factory-* "$HOME"/IuRoot/*/.claude/worktrees/factory-*; do
    [ -d "$wt" ] || continue
    base=${wt##*/}
    [[ $base =~ ^factory-([0-9]+)-[0-9]+$ ]] || continue
    issue=${BASH_REMATCH[1]}
    state=$(with_timeout 30 "$factory" issue show "issue_$issue" 2>/dev/null | with_timeout 10 jq -r '.state // empty' 2>/dev/null) || state=""
    [ "$state" = closed ] || continue
    closed=$((closed + 1))
    while IFS= read -r -d '' dir; do
      if [ "${dir##*/}" = target ] && [ ! -f "$(dirname "$dir")/Cargo.toml" ]; then continue; fi
      printf '%s\0' "$dir" >> "$list"
    done < <(find "$wt" -type d \( -name node_modules -o -name target \) -prune -print0 2>/dev/null)
  done
  total=$(count_listed "$list")
  xargs -0 rm -rf -- < "$list" || true # judged by the re-test below, not by rm's exit
  removed=$(count_gone "$list")
  rm -f "$list"
  after=$(free_kb "$HOME")
  left=$((total - removed))
  if [ "$left" -gt 0 ]; then
    echo "worktrees: FAILED: $removed of $total build dirs of $closed closed Issue(s) removed ($left could not be), $(delta "$before" "$after")"
    return 1
  fi
  echo "worktrees: $total target/node_modules dir(s) of $closed closed Issue(s) removed, $(delta "$before" "$after")"
}

# Scratch that outlives its use. ~/cache/<repo>/<issue-id> is a per-Issue cache: reaped where `factory issue show`
# reports that Issue closed (the worktrees step's rule, applied to the cache tree). A ~/.cache/cloud-wave clone (a directory)
# untouched for 14 days goes: a wave clone is regenerable. sccache's disk cache goes when it is over DISK_SWEEP_SCCACHE_MAX_GB.
# Kept: a name that is not a plain Issue number (cargo-target-seed's `seed` is that tool's to prune), an Issue the factory
# cannot show, and loose files in cloud-wave.
step_scratch() {
  local factory=${DISK_SWEEP_FACTORY:-factory} issues=yes missing="" closed_note=""
  command -v "$factory" >/dev/null 2>&1 || { issues=no; missing=$factory; }
  command -v jq >/dev/null 2>&1 || { issues=no; missing="${missing:+$missing, }jq"; }
  [ "$issues" = yes ] || closed_note=" (closed-Issue dirs skipped: no $missing)"
  local before after dir base state list total removed left kb closed=0 clones=0 rc=0
  local sc=${DISK_SWEEP_SCCACHE_DIR:-$HOME/Library/Caches/Mozilla.sccache} sc_note="sccache not cached"
  before=$(free_kb "$HOME")
  list=$(mktemp) || { echo "scratch: FAILED: mktemp"; return 1; }
  if [ "$issues" = yes ]; then
    for dir in "$HOME"/cache/*/[0-9]*; do
      [ -d "$dir" ] || continue
      base=${dir##*/}
      [[ $base =~ ^[0-9]+$ ]] || continue
      state=$(with_timeout 30 "$factory" issue show "issue_$base" 2>/dev/null | with_timeout 10 jq -r '.state // empty' 2>/dev/null) || state=""
      [ "$state" = closed ] || continue
      closed=$((closed + 1))
      printf '%s\0' "$dir" >> "$list"
    done
  fi
  if [ -d "$HOME/.cache/cloud-wave" ]; then
    while IFS= read -r -d '' dir; do
      [ -z "$(find "$dir" -mmin -20160 -print -quit 2>/dev/null)" ] || continue
      clones=$((clones + 1))
      printf '%s\0' "$dir" >> "$list"
    done < <(find "$HOME/.cache/cloud-wave" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
  fi
  total=$(count_listed "$list")
  xargs -0 rm -rf -- < "$list" || true # judged by the re-test below, not by rm's exit
  removed=$(count_gone "$list")
  rm -f "$list"
  if [ -d "$sc" ]; then
    if ! kb=$(dir_kb "$sc"); then
      sc_note="sccache FAILED: cannot measure $sc"; rc=1
    elif [ "$kb" -le $((SCCACHE_MAX_GB * 1024 * 1024)) ]; then
      sc_note="sccache $((kb / 1024)) MB under cap"
    else
      with_timeout 20 sccache --stop-server >/dev/null 2>&1 || true
      if rm -rf -- "$sc" && [ ! -e "$sc" ]; then
        sc_note="sccache $((kb / 1024)) MB over the $SCCACHE_MAX_GB GB cap, removed"
      else
        sc_note="sccache removal FAILED"; rc=1
      fi
    fi
  fi
  after=$(free_kb "$HOME")
  left=$((total - removed))
  if [ "$left" -gt 0 ]; then
    echo "scratch: FAILED: $removed of $total entries removed ($left could not be), $sc_note, $(delta "$before" "$after")"
    return 1
  fi
  echo "scratch: $closed cache dir(s) of closed Issues$closed_note and $clones wave clone(s) untouched 14 days removed, $sc_note, $(delta "$before" "$after")"
  return "$rc"
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
