#!/bin/bash
# Hermetic suite for disk-sweep.sh: only the steps that touch nothing outside the fixtures.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP=$(mktemp -d)
trap 'chflags -R nouchg "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME"
export DISK_SWEEP_TMPDIR="$TMP/tmproot"
T="$DISK_SWEEP_TMPDIR"
mkdir -p "$T"
# The second tmp root (/private/tmp on the mini) is a fixture too: no run may touch the real one.
SH="$TMP/shared-tmproot"; mkdir -p "$SH"; export DISK_SWEEP_SHARED_TMP="$SH"
FAKE="$TMP/fake"
mkdir -p "$FAKE"

fail=0
check() { # $1 = name, rest = a condition; passes when it exits 0
  local name=$1; shift
  if "$@"; then echo "  ok  $name"; else echo "  FAIL $name"; fail=1; fi
}
old() { touch -t "$(date -v-"$1"d +%Y%m%d%H%M)" "${@:2}"; }

# tmpdir: old entries go, fresh stay, an old one with an open file stays, Apple-owned stay.
mkdir "$T/old-dir" "$T/fresh-dir" "$T/held" "$T/com.apple.keep"
echo x > "$T/old-dir/f"; echo x > "$T/old-file"; echo x > "$T/fresh-file"
echo x > "$T/held/f"
mkdir "$T/old-dir-fresh-child"
echo x > "$T/old-dir-fresh-child/new"
old 5 "$T/old-dir-fresh-child"
old 5 "$T/old-dir/f" "$T/old-dir" "$T/old-file" "$T/held" "$T/com.apple.keep"
mkdir "$SH/old-shared" "$SH/fresh-shared" "$SH/held-shared"
echo x > "$SH/old-shared/f"; echo x > "$SH/fresh-shared/f"; echo x > "$SH/held-shared/f"
old 5 "$SH/old-shared/f" "$SH/old-shared" "$SH/held-shared/f" "$SH/held-shared"
sleep 60 > "$T/held/f" &
holder=$!
sleep 60 > "$SH/held-shared/f" &
holder2=$!

# The real lsof, asked only about the fixture file: a machine-wide scan costs ~10 s and adds nothing here.
printf '#!/bin/sh\nexec /usr/sbin/lsof -Fn -- "%s" "%s"\n' "$T/held/f" "$SH/held-shared/f" > "$FAKE/lsof-scoped"; chmod +x "$FAKE/lsof-scoped"
out=$(DISK_SWEEP_LSOF="$FAKE/lsof-scoped" bash "$HERE/disk-sweep.sh" tmpdir 2>&1); rc=$?
kill "$holder" "$holder2" 2>/dev/null; wait "$holder" "$holder2" 2>/dev/null
printf '%s\n' "$out" | sed 's/^/    | /'

check "exits 0" test "$rc" -eq 0
check "old tmp dir removed" test ! -e "$T/old-dir"
check "old tmp file removed" test ! -e "$T/old-file"
check "fresh tmp dir kept" test -d "$T/fresh-dir"
check "fresh tmp file kept" test -f "$T/fresh-file"
check "old tmp dir with an open file kept" test -f "$T/held/f"
check "Apple-owned tmp entry kept" test -d "$T/com.apple.keep"
check "old tmp dir holding a fresh file kept" test -f "$T/old-dir-fresh-child/new"
check "shared tmp: old entry removed" test ! -e "$SH/old-shared"
check "shared tmp: fresh entry kept" test -f "$SH/fresh-shared/f"
check "shared tmp: old entry held open kept" test -f "$SH/held-shared/f"
check "tmpdir: one summary line naming both roots" sh -c 'printf "%s" "$1" | grep -q "^tmpdir: .* removed from .* and "' _ "$out"
check "every step prints a size line" sh -c 'printf "%s\n" "$1" | grep -c "free space +" | grep -qx 2' _ "$out"

bash "$HERE/disk-sweep.sh" nonsense >/dev/null 2>&1; rc3=$?
check "unknown step exits 2" test "$rc3" -eq 2

# (a) lsof gives no answer: the open set cannot be trusted, so nothing is removed and the step fails.
printf '#!/bin/sh\nexit 2\n' > "$FAKE/lsof-dead"; chmod +x "$FAKE/lsof-dead"
printf '#!/bin/sh\necho p1; echo "n/not/under/root"; exit 1\n' > "$FAKE/lsof-partial"; chmod +x "$FAKE/lsof-partial"
T2="$TMP/tmproot2"; mkdir -p "$T2/stale" "$T2/stale2"
old 5 "$T2/stale" "$T2/stale2"
out4=$(DISK_SWEEP_TMPDIR="$T2" DISK_SWEEP_LSOF="$FAKE/lsof-dead" bash "$HERE/disk-sweep.sh" tmpdir 2>&1); rc4=$?
check "dead lsof: step fails" sh -c '[ "$1" -ne 0 ] && printf "%s" "$2" | grep -q "lsof gave no open-file set"' _ "$rc4" "$out4"
check "dead lsof: nothing removed" test -d "$T2/stale" -a -d "$T2/stale2"
DISK_SWEEP_TMPDIR="$T2" DISK_SWEEP_LSOF="$FAKE/lsof-partial" bash "$HERE/disk-sweep.sh" tmpdir >/dev/null 2>&1; rc5=$?
check "lsof exit 1 (partial open set): nothing removed, step fails" sh -c '[ "$1" -ne 0 ] && [ -d "$2/stale" ]' _ "$rc5" "$T2"

# (b) an old entry rm cannot remove: counted as left behind, step exits non-zero.
T3="$TMP/tmproot3"; mkdir -p "$T3/locked" "$T3/gone"
echo x > "$T3/locked/f"
old 5 "$T3/locked/f" "$T3/locked" "$T3/gone"
chflags uchg "$T3/locked/f"
printf '#!/bin/sh\necho p1; echo "n/not/under/root"; exit 0\n' > "$FAKE/lsof-none"; chmod +x "$FAKE/lsof-none"
out6=$(DISK_SWEEP_TMPDIR="$T3" DISK_SWEEP_LSOF="$FAKE/lsof-none" bash "$HERE/disk-sweep.sh" tmpdir 2>&1); rc6=$?
check "unremovable entry: step fails and says so" sh -c '[ "$1" -ne 0 ] && printf "%s" "$2" | grep -q "1 could not be"' _ "$rc6" "$out6"
check "unremovable entry: the removable one still went" test ! -e "$T3/gone"
chflags nouchg "$T3/locked/f"

# node-cache: a compile-cache file not written for 3 days goes (nested too), a fresh one and the directories stay.
NC="$TMP/nodecache-root"; mkdir -p "$NC/node-compile-cache/sub"
echo x > "$NC/node-compile-cache/old-entry"; echo x > "$NC/node-compile-cache/sub/old2"; echo x > "$NC/node-compile-cache/fresh-entry"
old 5 "$NC/node-compile-cache/old-entry" "$NC/node-compile-cache/sub/old2"
out_nc=$(DISK_SWEEP_TMPDIR="$NC" bash "$HERE/disk-sweep.sh" node-cache 2>&1); rc_nc=$?
check "node-cache: exit 0" test "$rc_nc" -eq 0
check "node-cache: old files gone, nested too" sh -c '[ ! -e "$1/old-entry" ] && [ ! -e "$1/sub/old2" ]' _ "$NC/node-compile-cache"
check "node-cache: fresh file and directories kept" sh -c '[ -f "$1/fresh-entry" ] && [ -d "$1/sub" ]' _ "$NC/node-compile-cache"
check "node-cache: summary counts two files" sh -c 'printf "%s" "$1" | grep -q "^node-cache: 2 file(s) not written for 3 days removed"' _ "$out_nc"
out_nc2=$(DISK_SWEEP_TMPDIR="$TMP/no-such-tmp" bash "$HERE/disk-sweep.sh" node-cache 2>&1); rc_nc2=$?
check "node-cache: no cache dir: skipped, exit 0" sh -c '[ "$1" -eq 0 ] && printf "%s" "$2" | grep -q "node-cache: skipped"' _ "$rc_nc2" "$out_nc2"

# -user only on the shared root; $TMPDIR keeps its reach. Sockets are excluded from both. A recording find shows the argv.
mkdir -p "$TMP/argvlog"
cat > "$TMP/argvlog/find" <<'FIND2'
#!/bin/sh
case " $* " in *" -mmin +4320 "*) printf '%s\n' "$*" >> "$FAKE_FIND_ARGV" ;; esac
exec /usr/bin/find "$@"
FIND2
chmod +x "$TMP/argvlog/find"
export FAKE_FIND_ARGV="$TMP/find-argv.log"; : > "$FAKE_FIND_ARGV"
PATH="$TMP/argvlog:$PATH" DISK_SWEEP_LSOF="$FAKE/lsof-none" bash "$HERE/disk-sweep.sh" tmpdir >/dev/null 2>&1
SHR=$(cd "$SH" && pwd -P); TR=$(cd "$T" && pwd -P)   # the script searches the resolved roots (/private/var/...)
check "tmpdir: the shared root's find is limited to this user" sh -c 'grep -F "$1 -mindepth" "$2" | grep -q -- "-user"' _ "$SHR" "$FAKE_FIND_ARGV"
check "tmpdir: the TMPDIR find keeps its reach (no -user)" sh -c 'grep -F "$1 -mindepth" "$2" | grep -vq -- "-user"' _ "$TR" "$FAKE_FIND_ARGV"
check "tmpdir: sockets are never candidates" grep -q -- '! -type s' "$FAKE_FIND_ARGV"

# node-cache: a subdirectory it cannot list fails the step, and nothing is removed.
NC2="$TMP/nodecache-locked"; mkdir -p "$NC2/node-compile-cache/locked" "$NC2/node-compile-cache/other"
echo x > "$NC2/node-compile-cache/locked/f"; echo x > "$NC2/node-compile-cache/other/stale"
old 5 "$NC2/node-compile-cache/locked/f" "$NC2/node-compile-cache/other/stale"
chmod 000 "$NC2/node-compile-cache/locked"
out_nc3=$(DISK_SWEEP_TMPDIR="$NC2" bash "$HERE/disk-sweep.sh" node-cache 2>&1); rc_nc3=$?
chmod 755 "$NC2/node-compile-cache/locked"
check "node-cache: unlistable subdirectory fails the step" sh -c '[ "$1" -ne 0 ] && printf "%s" "$2" | grep -q "node-cache: FAILED: find over"' _ "$rc_nc3" "$out_nc3"
check "node-cache: nothing removed when the listing is partial" test -f "$NC2/node-compile-cache/other/stale"

# (c) find loses an entry mid-listing (exit 1, "No such file or directory"): not a failure, the rest still goes.
# Any other find error still fails the step with nothing removed.
cat > "$FAKE/find" <<'FIND'
#!/bin/sh
case " $* " in
  *" -flags "*)
    /usr/bin/find "$@"
    case "$FAKE_FIND_MODE" in
      vanish) echo "find: $4/.vanished.package: No such file or directory" >&2; exit 1 ;;
      denied) echo "find: $4/private: Permission denied" >&2; exit 1 ;;
    esac ;;
  *) exec /usr/bin/find "$@" ;;
esac
FIND
chmod +x "$FAKE/find"
findsweep() { # $1 = FAKE_FIND_MODE, $2 = tmp root
  PATH="$FAKE:$PATH" FAKE_FIND_MODE="$1" DISK_SWEEP_TMPDIR="$2" DISK_SWEEP_LSOF="$FAKE/lsof-none" bash "$HERE/disk-sweep.sh" tmpdir 2>&1
}
T4="$TMP/tmproot4"; mkdir -p "$T4/stale"; old 5 "$T4/stale"
out13=$(findsweep vanish "$T4"); rc13=$?
check "find loses an entry mid-listing: exit 0, stale entry removed" sh -c '[ "$1" -eq 0 ] && [ ! -e "$2/stale" ] && ! printf "%s" "$3" | grep -q FAILED' _ "$rc13" "$T4" "$out13"
T5="$TMP/tmproot5"; mkdir -p "$T5/stale"; old 5 "$T5/stale"
out14=$(findsweep denied "$T5"); rc14=$?
check "find permission error: step fails, nothing removed" sh -c '[ "$1" -ne 0 ] && [ -d "$2/stale" ] && printf "%s" "$3" | grep -q "find over"' _ "$rc14" "$T5" "$out14"

# (d) pkg-caches with no package manager on PATH: an over-cap npm cache is removed, the rest is silent.
mkdir -p "$HOME/.npm/_cacache"; echo x > "$HOME/.npm/_cacache/blob"
out7=$(PATH=/usr/bin:/bin DISK_SWEEP_NPM_MAX_GB=0 /bin/bash "$HERE/disk-sweep.sh" pkg-caches 2>&1); rc7=$?
check "pkg-caches: npm cache removed, exit 0" sh -c '[ "$1" -eq 0 ] && [ ! -e "$2/.npm/_cacache" ] && printf "%s" "$3" | grep -q "npm cache removed"' _ "$rc7" "$HOME" "$out7"
check "pkg-caches: absent tools stay silent" sh -c '! printf "%s" "$1" | grep -qE "uv|brew|bun"' _ "$out7"

# (e) uv prune: a busy cache lock is a skip naming the holder (step ok, rc 0); any other uv error fails the step.
cat > "$FAKE/uv" <<'UV'
#!/bin/sh
case "$1 $2" in
  "cache dir") echo "$FAKE_UV_DIR" ;;
  "cache prune")
    echo "seen UV_LOCK_TIMEOUT=$UV_LOCK_TIMEOUT" >> "$FAKE_UV_LOG"
    if [ "$3" = "--force" ]; then
      echo "seen --force" >> "$FAKE_UV_LOG"
      [ "$FAKE_UV_MODE" = busy-stuck ] && { echo "error: forced prune broke" >&2; exit 2; }
      echo "Pruning cache at: $FAKE_UV_DIR"; exit 0
    fi
    case "$FAKE_UV_MODE" in
      busy|busy-stuck) echo "error: Timeout ($UV_LOCK_TIMEOUT s) when waiting for lock on \`$FAKE_UV_DIR\` at \`$FAKE_UV_DIR/.lock\`, is another uv process running?" >&2; exit 2 ;;
      error) echo "error: failed to read cache entry" >&2; exit 2 ;;
      *) echo "Pruning cache at: $FAKE_UV_DIR"; exit 0 ;;
    esac ;;
esac
UV
printf '#!/bin/sh\necho 4242\necho 4343\n' > "$FAKE/lsof-holder"
chmod +x "$FAKE/uv" "$FAKE/lsof-holder"
export FAKE_UV_DIR="$TMP/uvcache" FAKE_UV_LOG="$TMP/uv.log"
uvsweep() { # $1 = FAKE_UV_MODE
  PATH="$FAKE:/usr/bin:/bin" FAKE_UV_MODE="$1" DISK_SWEEP_LSOF="$FAKE/lsof-holder" /bin/bash "$HERE/disk-sweep.sh" pkg-caches 2>&1
}
out8=$(uvsweep busy); rc8=$?
check "uv lock busy: pruned past the lock, names the holder, exit 0" sh -c '[ "$1" -eq 0 ] && printf "%s" "$2" | grep -q "uv pruned past the lock held by pid 4242" && ! printf "%s" "$2" | grep -q FAILED' _ "$rc8" "$out8"
check "uv lock busy: probes with the short lock timeout, then forces" sh -c 'grep -qx "seen UV_LOCK_TIMEOUT=20" "$1" && grep -qx "seen --force" "$1"' _ "$FAKE_UV_LOG"
out8b=$(uvsweep busy-stuck); rc8b=$?
check "uv lock busy and the forced prune fails: step fails, exit 1" sh -c '[ "$1" -eq 1 ] && printf "%s" "$2" | grep -q "uv prune FAILED: error: forced prune broke"' _ "$rc8b" "$out8b"
out9=$(uvsweep error); rc9=$?
check "uv real error: step fails, exit 1" sh -c '[ "$1" -eq 1 ] && printf "%s" "$2" | grep -q "uv prune FAILED: error: failed to read cache entry"' _ "$rc9" "$out9"
out10=$(uvsweep ok); rc10=$?
check "uv prune ok: pruned, exit 0" sh -c '[ "$1" -eq 0 ] && printf "%s" "$2" | grep -q "uv pruned"' _ "$rc10" "$out10"

# (f) lima-cache: an image untouched for 2 days goes, a fresh one stays.
L="$HOME/Library/Caches/lima/download/by-url-sha256"; mkdir -p "$L/stale" "$L/fresh"
echo x > "$L/stale/data"; echo x > "$L/fresh/data"
old 2 "$L/stale/data" "$L/stale"
printf "#!/bin/sh\nexit 1\n" > "$FAKE/pgrep-none"; chmod +x "$FAKE/pgrep-none"
out11=$(DISK_SWEEP_PGREP="$FAKE/pgrep-none" bash "$HERE/disk-sweep.sh" lima-cache 2>&1); rc11=$?
check "lima-cache: exit 0, stale image removed, fresh kept" sh -c '[ "$1" -eq 0 ] && [ ! -e "$2/stale" ] && [ -d "$2/fresh" ] && printf "%s" "$3" | grep -q "1 image(s)"' _ "$rc11" "$L" "$out11"
# An old image rm cannot remove: counted, step fails.
mkdir -p "$L/locked"; echo x > "$L/locked/data"; old 2 "$L/locked/data" "$L/locked"; chflags uchg "$L/locked/data"
out12=$(DISK_SWEEP_PGREP="$FAKE/pgrep-none" bash "$HERE/disk-sweep.sh" lima-cache 2>&1); rc12=$?
check "lima-cache: unremovable image fails the step" sh -c '[ "$1" -ne 0 ] && printf "%s" "$2" | grep -q "1 could not be"' _ "$rc12" "$out12"
chflags nouchg "$L/locked/data"

# (g) worktrees: only a closed Issue's build dirs go. The factory is faked: 7001 closed, 7002 working, 7003 unknown.
cat > "$FAKE/factory" <<'FACT'
#!/bin/sh
case "$3" in
  issue_7001) echo '{"id":7001,"state":"closed"}' ;;
  issue_7002) echo '{"id":7002,"state":"working"}' ;;
  *) echo "no such issue" >&2; exit 1 ;;
esac
FACT
chmod +x "$FAKE/factory"
W="$HOME/SourceRoot/app/.claude/worktrees"
mkdir -p "$W/factory-7001-1/src" "$W/factory-7001-1/node_modules/pkg" "$W/factory-7001-1/web/node_modules/x" \
  "$W/factory-7001-1/core/target/debug" "$W/factory-7001-1/docs/target" \
  "$W/factory-7002-1/node_modules" "$W/factory-7003-1/target" "$W/scratch-1/node_modules"
echo x > "$W/factory-7001-1/src/main.ts"
echo x > "$W/factory-7001-1/core/Cargo.toml"
echo x > "$W/factory-7001-1/core/target/debug/bin"
echo x > "$W/factory-7001-1/node_modules/pkg/index.js"
echo x > "$W/factory-7001-1/docs/target/keep.md"
echo x > "$W/factory-7002-1/node_modules/keep"
echo x > "$W/factory-7003-1/target/keep"
echo x > "$W/scratch-1/node_modules/keep"
out13=$(DISK_SWEEP_FACTORY="$FAKE/factory" bash "$HERE/disk-sweep.sh" worktrees 2>&1); rc13=$?
check "worktrees: exit 0" test "$rc13" -eq 0
check "closed Issue: node_modules gone, nested too" sh -c '[ ! -e "$1/factory-7001-1/node_modules" ] && [ ! -e "$1/factory-7001-1/web/node_modules" ]' _ "$W"
check "closed Issue: Rust target/ beside Cargo.toml gone" test ! -e "$W/factory-7001-1/core/target"
check "closed Issue: source kept" test -f "$W/factory-7001-1/src/main.ts"
check "closed Issue: target/ without Cargo.toml kept" test -f "$W/factory-7001-1/docs/target/keep.md"
check "working Issue kept" test -f "$W/factory-7002-1/node_modules/keep"
check "unknown Issue kept" test -f "$W/factory-7003-1/target/keep"
check "non-factory worktree kept" test -f "$W/scratch-1/node_modules/keep"
check "worktrees: counts 3 dirs of 1 closed Issue" sh -c 'printf "%s" "$1" | grep -qF "worktrees: 3 target/node_modules dir(s) of 1 closed Issue(s) removed"' _ "$out13"
out14=$(DISK_SWEEP_FACTORY="$TMP/no-factory" bash "$HERE/disk-sweep.sh" worktrees 2>&1); rc14=$?
check "no factory CLI: skipped, exit 0, nothing removed" sh -c '[ "$1" -eq 0 ] && printf "%s" "$2" | grep -q "skipped" && [ -f "$3/factory-7002-1/node_modules/keep" ]' _ "$rc14" "$out14" "$W"

# (h) scratch: a closed Issue's ~/cache/<repo>/<id> goes; open, unknown, non-numeric and seed dirs stay. A cloud-wave
# clone untouched 14 days goes; a fresh clone, a loose file and a ~/.cache dir outside cloud-wave stay. An sccache dir
# over its cap goes (the server is stopped first); one under its cap stays.
S="$HOME/cache"
mkdir -p "$S/weatherorb/7001/target" "$S/weatherorb/7002" "$S/weatherorb/7003" "$S/weatherorb/e162-2176" "$S/shutterflow/seed/k"
echo x > "$S/weatherorb/7001/target/f"; echo x > "$S/weatherorb/7002/f"; echo x > "$S/weatherorb/7003/f"
echo x > "$S/weatherorb/e162-2176/f"; echo x > "$S/shutterflow/seed/k/f"
W2="$HOME/.cache/cloud-wave"
mkdir -p "$W2/clean-old/src" "$W2/clean-new/src" "$HOME/.cache/uv/wheel"
echo x > "$W2/clean-old/src/f"; echo x > "$W2/clean-new/src/f"; echo x > "$W2/loose.log"; echo x > "$HOME/.cache/uv/wheel/f"
old 20 "$W2/clean-old/src/f" "$W2/clean-old/src" "$W2/clean-old" "$W2/loose.log" "$HOME/.cache/uv/wheel/f" "$HOME/.cache/uv/wheel" "$HOME/.cache/uv"
SC="$TMP/sccache-over"; SC2="$TMP/sccache-under"
mkdir -p "$SC/blob" "$SC2/blob"; echo x > "$SC/blob/f"; echo x > "$SC2/blob/f"
printf '#!/bin/sh\necho "$*" >> "%s"\n' "$TMP/sccache.log" > "$FAKE/sccache"; chmod +x "$FAKE/sccache"
out15=$(PATH="$FAKE:$PATH" DISK_SWEEP_FACTORY="$FAKE/factory" DISK_SWEEP_SCCACHE_DIR="$SC" DISK_SWEEP_SCCACHE_MAX_GB=0 bash "$HERE/disk-sweep.sh" scratch 2>&1); rc15=$?
PATH="$FAKE:$PATH" DISK_SWEEP_FACTORY="$FAKE/factory" DISK_SWEEP_SCCACHE_DIR="$SC2" bash "$HERE/disk-sweep.sh" scratch >/dev/null 2>&1; rc16=$?
printf '%s\n' "$out15" | sed 's/^/    | /'
check "scratch: exit 0" test "$rc15" -eq 0
check "scratch: closed Issue's cache dir gone" test ! -e "$S/weatherorb/7001"
check "scratch: working and unknown Issue dirs kept" sh -c '[ -f "$1/weatherorb/7002/f" ] && [ -f "$1/weatherorb/7003/f" ]' _ "$S"
check "scratch: non-numeric and seed dirs kept" sh -c '[ -f "$1/weatherorb/e162-2176/f" ] && [ -f "$1/shutterflow/seed/k/f" ]' _ "$S"
check "scratch: 14-day wave clone gone" test ! -e "$W2/clean-old"
check "scratch: fresh clone, loose file and ~/.cache/uv kept" sh -c '[ -f "$1/clean-new/src/f" ] && [ -f "$1/loose.log" ] && [ -f "$2/.cache/uv/wheel/f" ]' _ "$W2" "$HOME"
check "scratch: over-cap sccache removed" test ! -e "$SC"
check "scratch: sccache server stopped before removal" grep -qx -- '--stop-server' "$TMP/sccache.log"
check "scratch: under-cap sccache kept" test -f "$SC2/blob/f"
check "scratch: under-cap run exit 0" test "$rc16" -eq 0
# (i) scratch without the factory CLI: the closed-Issue part is skipped, but the sccache cap and the wave-clone reap still run.
SC3="$TMP/sccache-nofactory"; mkdir -p "$SC3/blob"; echo x > "$SC3/blob/f"
mkdir -p "$W2/clean-old2/src"; echo x > "$W2/clean-old2/src/f"; old 20 "$W2/clean-old2/src/f" "$W2/clean-old2/src" "$W2/clean-old2"
PATH="$FAKE:$PATH" DISK_SWEEP_FACTORY="$TMP/no-factory" DISK_SWEEP_SCCACHE_DIR="$SC3" DISK_SWEEP_SCCACHE_MAX_GB=0 bash "$HERE/disk-sweep.sh" scratch >"$TMP/nofactory.out" 2>&1; rc17=$?
check "scratch without factory: exit 0" test "$rc17" -eq 0
check "scratch without factory: over-cap sccache still removed" test ! -e "$SC3"
check "scratch without factory: 14-day wave clone still removed" test ! -e "$W2/clean-old2"
check "scratch without factory: working Issue dir kept" test -f "$S/weatherorb/7002/f"
check "scratch without factory: says the closed-Issue part was skipped" grep -q "closed-Issue dirs skipped" "$TMP/nofactory.out"
check "scratch: summary counts, no FAILED" sh -c 'printf "%s" "$1" | grep -q "^scratch: 1 cache dir(s) of closed Issues and 1 wave clone(s) untouched 14 days removed" && ! printf "%s" "$1" | grep -q FAILED' _ "$out15"

exit "$fail"
