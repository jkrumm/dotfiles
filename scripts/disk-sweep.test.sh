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
sleep 60 > "$T/held/f" &
holder=$!

# The real lsof, asked only about the fixture file: a machine-wide scan costs ~10 s and adds nothing here.
printf '#!/bin/sh\nexec /usr/sbin/lsof -Fn -- "%s"\n' "$T/held/f" > "$FAKE/lsof-scoped"; chmod +x "$FAKE/lsof-scoped"
out=$(DISK_SWEEP_LSOF="$FAKE/lsof-scoped" bash "$HERE/disk-sweep.sh" tmpdir 2>&1); rc=$?
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
printf '%s\n' "$out" | sed 's/^/    | /'

check "exits 0" test "$rc" -eq 0
check "old tmp dir removed" test ! -e "$T/old-dir"
check "old tmp file removed" test ! -e "$T/old-file"
check "fresh tmp dir kept" test -d "$T/fresh-dir"
check "fresh tmp file kept" test -f "$T/fresh-file"
check "old tmp dir with an open file kept" test -f "$T/held/f"
check "Apple-owned tmp entry kept" test -d "$T/com.apple.keep"
check "old tmp dir holding a fresh file kept" test -f "$T/old-dir-fresh-child/new"
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
    case "$FAKE_UV_MODE" in
      busy) echo "error: Timeout ($UV_LOCK_TIMEOUT s) when waiting for lock on \`$FAKE_UV_DIR\` at \`$FAKE_UV_DIR/.lock\`, is another uv process running?" >&2; exit 2 ;;
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
check "uv lock busy: skipped with the holder pid, exit 0" sh -c '[ "$1" -eq 0 ] && printf "%s" "$2" | grep -q "uv prune skipped: cache lock held by pid 4242" && ! printf "%s" "$2" | grep -q FAILED' _ "$rc8" "$out8"
check "uv lock busy: probes with the short lock timeout" grep -qx "seen UV_LOCK_TIMEOUT=20" "$FAKE_UV_LOG"
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

exit "$fail"
