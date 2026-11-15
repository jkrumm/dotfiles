#!/usr/bin/env bash
set -u
# Hermetic test for scripts/cargo-target-seed.sh: a temp git repo with a fake cargo workspace, a fake toolchain
# (CARGO_SEED_TOOLCHAIN), seeds under a temp CARGO_SEED_ROOT. No cargo, no rustc and nothing outside the temp dir is touched.
# The touch rule is the part that must not drift: a clone without it lets a check pass on code it never compiled.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEED="$HERE/cargo-target-seed.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/cargo-target-seed-test.XXXXXX")" || exit 2
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; fail=$((fail + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
ne()  { if [ "$2" != "$3" ]; then ok "$1"; else bad "$1" "both [$2]"; fi; }
mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1"; }
OLD=202001010000   # touch -t stamps: far older than anything made now
MID=202101010000

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null HOME="$T/home"
export CARGO_SEED_TOOLCHAIN=1.99.0
unset CARGO_TARGET_DIR CARGO_SEED_JOBS CARGO_SEED_ROOT
mkdir -p "$HOME"
G() { git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }

# A repo `proj` whose workspace is `ws/` (crates/ and xtask/ are its own sources, vendor/ is part of the key).
R="$T/proj"
mkdir -p "$R/ws/crates/a/src" "$R/ws/xtask/src" "$R/ws/vendor/dep" "$R/ws/.cargo" "$R/docs"
echo 'lock-1' > "$R/ws/Cargo.lock"
echo '[workspace]' > "$R/ws/Cargo.toml"
echo '[package]' > "$R/ws/crates/a/Cargo.toml"
echo 'fn main() {}' > "$R/ws/crates/a/src/main.rs"
echo 'fn main() {}' > "$R/ws/xtask/src/main.rs"
echo 'vendored' > "$R/ws/vendor/dep/lib.rs"
echo '[build]' > "$R/ws/.cargo/config.toml"
echo 'notes' > "$R/docs/notes.md"
(cd "$R" && G init -q && G add -A && G commit -qm init)

S() { (cd "$R" && "$SEED" --workspace ws --own ws/crates --own ws/xtask --key-path ws/vendor "$@"); }
SEEDS="$T/seeds"
export CARGO_SEED_ROOT="$SEEDS"

# Make a finished seed directory for a key: one artifact file, stamped MID.
mkseed() { mkdir -p "$SEEDS/$1"; echo "artifact-$1" > "$SEEDS/$1/dep.rlib"; touch -t "${2:-$MID}" "$SEEDS/$1/dep.rlib" "$SEEDS/$1"; }
agesources() { touch -t "$OLD" "$R/ws/crates/a/src/main.rs" "$R/ws/xtask/src/main.rs" "$R/ws/vendor/dep/lib.rs" "$R/docs/notes.md"; }

echo "usage"
(cd "$R" && "$SEED" >/dev/null 2>&1); eq "no verb is a usage error" 2 $?
(cd "$R" && "$SEED" clone >/dev/null 2>&1); eq "clone without --own is a usage error" 2 $?
(cd "$R" && "$SEED" --own x build >/dev/null 2>&1); eq "build without a command is a usage error" 2 $?
(cd "$R" && "$SEED" --bogus key >/dev/null 2>&1); eq "an unknown option is a usage error" 2 $?

echo "key"
K1=$(S key); eq "the key starts with the toolchain" "1.99.0-" "${K1%%-*}-"
eq "the key is stable" "$K1" "$(S key)"
echo 'fn main() { 1 }' > "$R/ws/crates/a/src/main.rs"
eq "a source edit leaves the key alone" "$K1" "$(S key)"
echo 'lock-2' > "$R/ws/Cargo.lock"; K2=$(S key); ne "Cargo.lock changes the key" "$K1" "$K2"
echo 'lock-1' > "$R/ws/Cargo.lock"
echo '# dep' >> "$R/ws/crates/a/Cargo.toml"; ne "a Cargo.toml changes the key" "$K1" "$(S key)"
(cd "$R" && git checkout -q ws/crates/a/Cargo.toml)
echo 'vendored 2' > "$R/ws/vendor/dep/lib.rs"; ne "a --key-path tree changes the key" "$K1" "$(S key)"
(cd "$R" && git checkout -q ws/vendor ws/crates)
echo '[build] x' > "$R/ws/.cargo/config.toml"; ne ".cargo/config.toml changes the key" "$K1" "$(S key)"
(cd "$R" && git checkout -q ws/.cargo)
eq "restoring the files restores the key" "$K1" "$(S key)"
ne "the toolchain changes the key" "$K1" "$(CARGO_SEED_TOOLCHAIN=1.100.0 S key)"
mkdir -p "$R/ws/crates/b"; echo '[package]' > "$R/ws/crates/b/Cargo.toml"
ne "a new untracked crate changes the key" "$K1" "$(S key)"; rm -rf "$R/ws/crates/b"
mkdir -p "$T/empty" && (cd "$T/empty" && G init -q && "$SEED" key >/dev/null 2>&1); eq "key with no Cargo.lock fails" 1 $?

echo "clone: the touch"
mkseed "$K1"; agesources
out=$(S clone 2>&1); eq "clone exits 0" 0 $?
[ -f "$R/ws/target/dep.rlib" ] && ok "the seed's contents are in ws/target" || bad "ws/target/dep.rlib missing" "$out"
seedtime=$(mtime "$R/ws/target/dep.rlib")
[ "$(mtime "$R/ws/crates/a/src/main.rs")" -gt "$seedtime" ] && ok "an own crate source is newer than the seed's artifacts" || bad "crates/a source is not newer than the artifact"
[ "$(mtime "$R/ws/xtask/src/main.rs")" -gt "$seedtime" ] && ok "a second --own tree is touched" || bad "xtask source is not newer than the artifact"
touch -t "$OLD" "$T/oldref"
eq "a file outside --own keeps its time" "$(mtime "$T/oldref")" "$(mtime "$R/docs/notes.md")"
eq "the key's own seed leaves --key-path alone" "$(mtime "$T/oldref")" "$(mtime "$R/ws/vendor/dep/lib.rs")"
case "$out" in *"cloned $K1"*) ok "it says which seed it cloned" ;; *) bad "no clone line" "$out" ;; esac

echo "clone: a worktree's own target is never replaced"
echo mine > "$R/ws/target/marker"; S clone >/dev/null 2>&1
eq "marker survives a second clone" mine "$(cat "$R/ws/target/marker")"
[ -f "$R/ws/target/dep.rlib" ] && ok "target is intact" || bad "target lost its content"
rm -rf "$R/ws/target"

echo "clone: CARGO_TARGET_DIR"
CARGO_TARGET_DIR="$T/ci" S clone >/dev/null 2>&1; eq "exit 0" 0 $?
[ -e "$R/ws/target" ] && bad "CARGO_TARGET_DIR set but a target was cloned" || ok "CARGO_TARGET_DIR set: nothing cloned"

echo "clone: another key's seed (the newest)"
rm -rf "$SEEDS"; mkseed "1.99.0-aaaaaaaaaaaaaaaa" "$OLD"; mkseed "1.99.0-bbbbbbbbbbbbbbbb" "$MID"
agesources
out=$(S clone 2>&1); eq "exit 0" 0 $?
eq "the newest seed was cloned" "artifact-1.99.0-bbbbbbbbbbbbbbbb" "$(cat "$R/ws/target/dep.rlib" 2>/dev/null)"
[ "$(mtime "$R/ws/vendor/dep/lib.rs")" -gt "$(mtime "$R/ws/target/dep.rlib")" ] && ok "another key's seed: --key-path trees are touched too" || bad "vendor not touched for a foreign seed"
case "$out" in *"no seed for key"*) ok "it says the key has no seed" ;; *) bad "no fallback line" "$out" ;; esac
rm -rf "$R/ws/target"

echo "clone: no seed at all"
rm -rf "$SEEDS"
out=$(S clone 2>&1); eq "exit 0 (a cold build follows)" 0 $?
[ -e "$R/ws/target" ] && bad "a target appeared with no seed" || ok "no target made"
case "$out" in *"first build is cold"*) ok "it says the build is cold" ;; *) bad "no cold line" "$out" ;; esac

echo "clone: build-script records are relocated to the clone"
rm -rf "$SEEDS"; mkseed "$K1"
GONE="$SEEDS/.tmp-$K1-4242"
mkdir -p "$SEEDS/$K1/debug/build/tauri-x/out/permissions"
echo "cargo:rustc-link-search=native=$GONE/debug/build/tauri-x/out" > "$SEEDS/$K1/debug/build/tauri-x/output"
echo "$GONE/debug/build/tauri-x/out" > "$SEEDS/$K1/debug/build/tauri-x/root-output"
echo "$GONE/debug/build/tauri-x/out/permissions/a.toml" > "$SEEDS/$K1/debug/build/tauri-x/out/a-permission-files"
echo "debuginfo $GONE/x" > "$SEEDS/$K1/debug/build/tauri-x/stderr"
echo "/elsewhere/keep" > "$SEEDS/$K1/debug/build/tauri-x/out/permissions/a.toml"
touch -t "$OLD" "$SEEDS/$K1/debug/build/tauri-x/output" "$SEEDS/$K1/debug/build/tauri-x/root-output" "$SEEDS/$K1/debug/build/tauri-x/out/a-permission-files"
stamp_before=$(perl -MTime::HiRes=stat -e 'print((stat $ARGV[0])[9])' "$SEEDS/$K1/debug/build/tauri-x/output")
agesources; S clone >"$T/reloc.out" 2>&1
RT="$(cd "$R/ws/target" && pwd -P)" # git resolves symlinks (macOS /var), so the clone is named by its real path
grep -q "$GONE" "$R/ws/target/debug/build/tauri-x/output" && bad "output still names the gone directory" || ok "output no longer names the gone directory"
eq "output points at the clone's target" "cargo:rustc-link-search=native=$RT/debug/build/tauri-x/out" "$(cat "$R/ws/target/debug/build/tauri-x/output")"
eq "root-output points at the clone's target" "$RT/debug/build/tauri-x/out" "$(cat "$R/ws/target/debug/build/tauri-x/root-output")"
eq "a *-permission-files list is rewritten" "$RT/debug/build/tauri-x/out/permissions/a.toml" "$(cat "$R/ws/target/debug/build/tauri-x/out/a-permission-files")"
eq "a record keeps its time to the nanosecond" "$stamp_before" "$(perl -MTime::HiRes=stat -e 'print((stat $ARGV[0])[9])' "$R/ws/target/debug/build/tauri-x/output")"
eq "the seed itself is not rewritten" "$GONE/debug/build/tauri-x/out/permissions/a.toml" "$(cat "$SEEDS/$K1/debug/build/tauri-x/out/a-permission-files")"
grep -q "$GONE" "$R/ws/target/debug/build/tauri-x/stderr" && ok "a file that is not a record is left alone" || bad "stderr was rewritten"
eq "a path outside a temporary directory is left alone" "/elsewhere/keep" "$(cat "$R/ws/target/debug/build/tauri-x/out/permissions/a.toml")"
case "$(cat "$T/reloc.out")" in *"relocated 3 build-script records"*) ok "it says how many records moved" ;; *) bad "no relocate line" "$(cat "$T/reloc.out")" ;; esac
rm -rf "$R/ws/target"

echo "build: a warm start from a seed relocates its records to the new temporary directory"
rm -rf "$SEEDS"; mkseed "old-key" "$OLD"
mkdir -p "$SEEDS/old-key/debug/build/p-1"
echo "$SEEDS/.tmp-old-key-1/debug/build/p-1/out" > "$SEEDS/old-key/debug/build/p-1/output"
S build -- sh -c 'cp "$CARGO_TARGET_DIR/debug/build/p-1/output" "$CARGO_TARGET_DIR/seen"' >/dev/null 2>&1
case "$(cat "$SEEDS/$K1/seen" 2>/dev/null)" in */.tmp-"$K1"-*/debug/build/p-1/out) ok "the command sees records naming its own target" ;; *) bad "records not relocated before the build" "$(cat "$SEEDS/$K1/seen" 2>/dev/null)" ;; esac

echo "clone: an --own that matches nothing fails closed"
mkseed "$K1"
(cd "$R" && "$SEED" --workspace ws --own ws/nope clone >/dev/null 2>&1); eq "exit 1" 1 $?
[ -e "$R/ws/target" ] && bad "cloned despite an empty --own" || ok "nothing cloned"

echo "clone: a tracked file deleted in the worktree is not recreated by the touch"
rm "$R/ws/xtask/src/main.rs"
S clone >/dev/null 2>&1
[ -e "$R/ws/xtask/src/main.rs" ] && bad "touch recreated a deleted file" || ok "deleted file stays deleted"
rm -rf "$R/ws/target"; (cd "$R" && git checkout -q ws/xtask)

echo "build"
rm -rf "$SEEDS"
S build -- sh -c 'pwd > "$CARGO_TARGET_DIR/cwd"; echo built > "$CARGO_TARGET_DIR/out"' >"$T/build.out" 2>&1; eq "exit 0" 0 $?
[ -f "$SEEDS/$K1/out" ] && ok "the seed is renamed into place under the key" || bad "no seed $K1" "$(cat "$T/build.out")"
eq "the command ran in the workspace" "$(cd "$R/ws" && pwd -P)" "$(cd "$(cat "$SEEDS/$K1/cwd")" && pwd -P)"
compgen -G "$SEEDS/.tmp-*" >/dev/null && bad "a temporary directory is left" || ok "no temporary directory is left"
out=$(S build -- false 2>&1); eq "a key with a seed is not rebuilt" 0 $?
case "$out" in *"$K1 exists"*) ok "it says the seed exists" ;; *) bad "no exists line" "$out" ;; esac

echo "build: a failing command leaves no seed"
echo 'lock-3' > "$R/ws/Cargo.lock"; K3=$(S key)
S build -- sh -c 'echo half > "$CARGO_TARGET_DIR/half"; exit 3' >/dev/null 2>&1; eq "build exits non-zero" 1 $?
[ -e "$SEEDS/$K3" ] && bad "a failed build became a seed" || ok "no seed for the failed key"
compgen -G "$SEEDS/.tmp-*" >/dev/null && bad "temporary directory left after a failure" || ok "the temporary directory is removed"

echo "build: warm from the newest seed"
S build -- sh -c 'test "$(cat "$CARGO_TARGET_DIR/out")" = built && echo more > "$CARGO_TARGET_DIR/more"' >/dev/null 2>&1; eq "the new key starts from the old seed's contents" 0 $?
[ -f "$SEEDS/$K3/more" ] && [ -f "$SEEDS/$K3/out" ] && ok "the new seed carries both" || bad "new seed incomplete"

echo "build: warm from this worktree's own target"
echo 'lock-4' > "$R/ws/Cargo.lock"; K4=$(S key)
mkdir -p "$R/ws/target"; echo local > "$R/ws/target/local"
S build -- sh -c 'cat "$CARGO_TARGET_DIR/local" > "$CARGO_TARGET_DIR/seen"' >/dev/null 2>&1
eq "the worktree's target was the start" local "$(cat "$SEEDS/$K4/seen" 2>/dev/null)"
rm -rf "$R/ws/target"; echo 'lock-1' > "$R/ws/Cargo.lock"

echo "prune"
rm -rf "$SEEDS"; mkseed "old-key" "$OLD"; mkseed "$K1" "$MID"
S build -- false >/dev/null 2>&1
[ -d "$SEEDS/old-key" ] && bad "the old seed outlived a successor older than a day" || ok "an old seed goes when its successor is older than a day"
[ -d "$SEEDS/$K1" ] && ok "the newest seed stays" || bad "the newest seed was pruned"
rm -rf "$SEEDS"; mkseed "old-key" "$OLD"; mkseed "$K1" "$MID"; touch "$SEEDS/$K1"
S build -- false >/dev/null 2>&1
[ -d "$SEEDS/old-key" ] && ok "an old seed stays while its successor is under a day old" || bad "pruned too early"

echo "name and root"
unset CARGO_SEED_ROOT
(cd "$R" && G worktree add -q "$T/wt" -b wt >/dev/null 2>&1)
mkdir -p "$HOME/cache/proj/seed/$K1"; echo viaworktree > "$HOME/cache/proj/seed/$K1/dep.rlib"
(cd "$T/wt" && "$SEED" --workspace ws --own ws/crates clone >/dev/null 2>&1); eq "a worktree resolves ~/cache/<main repo name>/seed" 0 $?
eq "and clones from it" viaworktree "$(cat "$T/wt/ws/target/dep.rlib" 2>/dev/null)"
mkdir -p "$HOME/cache/other/seed/$K1"; echo other > "$HOME/cache/other/seed/$K1/dep.rlib"; rm -rf "$T/wt/ws/target"
(cd "$T/wt" && "$SEED" --name other --workspace ws --own ws/crates clone >/dev/null 2>&1)
eq "--name picks another seed directory" other "$(cat "$T/wt/ws/target/dep.rlib" 2>/dev/null)"

echo "jobs"
eq "CARGO_SEED_JOBS wins" 7 "$(CARGO_SEED_JOBS=7 "$SEED" jobs)"
n=$("$SEED" jobs)
case "$n" in ''|*[!0-9]*) bad "jobs is not a number" "$n" ;; *) [ "$n" -ge 2 ] && ok "jobs defaults to a number of at least 2 ($n)" || bad "jobs under 2" "$n" ;; esac
(cd "$T" && "$SEED" jobs >/dev/null 2>&1); eq "jobs needs no repository" 0 $?

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
