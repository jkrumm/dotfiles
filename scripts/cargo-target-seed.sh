#!/usr/bin/env bash
# cargo-target-seed — a warm cargo `target/` for a new worktree instead of a cold build (weatherorb measured 6.6 s
# instead of 182 s). One tool for every Rust repo on the mini; a repo's Makefile calls it when `command -v
# cargo-target-seed` succeeds and builds cold when it does not. Linked to ~/.local/bin by `make setup`.
#
#   cargo-target-seed [options] key      print the seed key: the toolchain plus one digest over Cargo.lock, every Cargo.toml,
#                                        .cargo/config.toml, rust-toolchain.toml and each --key-path tree (what a dependency
#                                        compiles to)
#   cargo-target-seed [options] clone    give this worktree a <workspace>/target when it has none: the key's seed, else the
#                                        newest seed; then touch every --own file
#   cargo-target-seed [options] build -- <command...>
#                                        run the command in <workspace> with CARGO_TARGET_DIR set to a temporary directory
#                                        (warm from this worktree's target, else the newest seed), rename it into place only
#                                        when the command exits 0, then prune. The command is what the repo's gates compile
#                                        (clippy's check artifacts and the test builds are different artifacts: seed both)
#   cargo-target-seed jobs               print the cargo job cap of this host
#
# Options (paths are relative to the repo root; options come before the verb):
#   --workspace DIR    the directory holding Cargo.lock and target/ (default: the repo root)
#   --own PATH         a pathspec of the workspace's own sources, repeatable; REQUIRED for clone and build
#   --key-path PATH    an extra tree that is part of the key (a vendored dependency tree), repeatable
#   --name NAME        seeds live under ~/cache/NAME/seed (default: the main repo's directory name, the same from every worktree)
#
# Environment: CARGO_SEED_ROOT (the seeds' directory), CARGO_SEED_JOBS (the job cap), CARGO_SEED_TOOLCHAIN (replaces `rustc -V`
# in the key; tests), CARGO_TARGET_DIR (set: clone does nothing, CI keeps its own persistent target).
#
# Seeds live on the volume of the worktrees: an APFS clone (`cp -c`) shares the seed's blocks until a file changes, so a clone
# costs no disk.
#
# The touch. Cargo decides freshness by file time, and a clone keeps the seed's times, so a source file older than the seed
# would count as built and a check could pass on code it never compiled. After every clone each --own file is touched, so the
# workspace's own crates rebuild from this worktree's sources and only the dependencies come from the seed. A seed of another
# key gets the --key-path trees touched too. --own is required and must match a file: a repo that forgets it fails, it does
# not get an unsafe clone. This rule lives only here; the test pins it (scripts/cargo-target-seed.test.sh).
set -euo pipefail

usage() {
    sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2
    exit 2
}
die() {
    echo "cargo-target-seed: $*" >&2
    exit 1
}

name="" workspace="." own=() keypaths=() verb="" cmd=()
while [ $# -gt 0 ]; do
    case "$1" in
        --name) [ $# -ge 2 ] || usage; name=$2; shift 2 ;;
        --workspace) [ $# -ge 2 ] || usage; workspace=$2; shift 2 ;;
        --own) [ $# -ge 2 ] || usage; own+=("$2"); shift 2 ;;
        --key-path) [ $# -ge 2 ] || usage; keypaths+=("$2"); shift 2 ;;
        -h | --help) usage ;;
        --) shift; cmd=("$@"); break ;;
        -*) echo "cargo-target-seed: unknown option $1" >&2; usage ;;
        *)
            [ -z "$verb" ] || usage
            verb=$1
            shift
            ;;
    esac
done

jobs() {
    if [ -n "${CARGO_SEED_JOBS:-}" ]; then echo "$CARGO_SEED_JOBS"; return 0; fi
    local cores
    cores=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 6)
    # A third of the cores: five leads at cargo's default jobs took the 12-core mini to load 152; 4 is the measured cap.
    local n=$((cores / 3))
    if [ "$n" -lt 2 ]; then n=2; fi
    echo "$n"
}

case "$verb" in
    jobs) jobs; exit 0 ;;
    key) ;;
    clone | build)
        [ ${#own[@]} -gt 0 ] || { echo "cargo-target-seed: $verb needs at least one --own PATH" >&2; usage; }
        ;;
    *) usage ;;
esac

workspace=${workspace%/}
if [ -z "$workspace" ] || [ "$workspace" = "." ] || [ "$workspace" = "./" ]; then workspace=.; fi

repo=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
if [ -z "$name" ]; then
    name=$(basename "$(cd "$repo" && cd "$(git rev-parse --git-common-dir)/.." && pwd)")
fi
root=${CARGO_SEED_ROOT:-$HOME/cache/$name/seed}
if [ "$workspace" = . ]; then wsdir=$repo; wsprefix=""; else wsdir=$repo/$workspace; wsprefix=$workspace/; fi
target=$wsdir/target

mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1"; }
if command -v shasum >/dev/null 2>&1; then sha256=(shasum -a 256); else sha256=(sha256sum); fi
# Paths the EXIT trap removes: globals, because a trap runs after a function's locals are gone.
cleanup_tmp="" cleanup_list=""
trap 'rm -rf "$cleanup_tmp" "$cleanup_list"' EXIT

# The seeds, newest first (a seed's time is set when it is renamed into place).
seeds() {
    [ -d "$root" ] || return 0
    local dir
    for dir in "$root"/*; do
        if [ -d "$dir" ]; then echo "$(mtime "$dir") $dir"; fi
    done | sort -rn | cut -d' ' -f2-
}

key() {
    local toolchain digest files
    if [ -n "${CARGO_SEED_TOOLCHAIN:-}" ]; then
        toolchain=$CARGO_SEED_TOOLCHAIN
    else
        toolchain=$(cd "$wsdir" && rustc --version | awk '{print $2}') || die "rustc is not available in $wsdir"
    fi
    [ -n "$toolchain" ] || die "empty toolchain"
    toolchain=$(printf '%s' "$toolchain" | tr -c 'A-Za-z0-9._\n-' '_')
    # sha256, not blake3: it ships with the OS and a key needs no install. Untracked files count (a new crate).
    files=$(mktemp "${TMPDIR:-/tmp}/cargo-target-seed.XXXXXX")
    (cd "$repo" && git ls-files -co --exclude-standard -z -- "${wsprefix}Cargo.lock" ":(glob)${wsprefix}**/Cargo.toml" \
        "${wsprefix}.cargo/config.toml" rust-toolchain.toml "${wsprefix}rust-toolchain.toml" ${keypaths[@]+"${keypaths[@]}"}) >"$files"
    if ! [ -s "$files" ]; then rm -f "$files"; die "no Cargo.lock or Cargo.toml under $workspace"; fi
    digest=$(cd "$repo" && xargs -0 "${sha256[@]}" <"$files" | "${sha256[@]}" | cut -c1-16)
    rm -f "$files"
    echo "$toolchain-$digest"
}

# Copy-on-write: clonefile on macOS, a reflink where the filesystem has one; a plain copy where neither works.
clone_dir() {
    if [ "$(uname)" = Darwin ]; then
        cp -cR "$1" "$2" 2>/dev/null || { rm -rf "$2"; cp -R "$1" "$2"; }
    else
        cp -R --reflink=auto "$1" "$2"
    fi
}

# List this worktree's own files (tracked and untracked, not deleted) under the given pathspecs into a NUL list file.
own_list() {
    local list=$1
    shift
    (cd "$repo" && git ls-files -co --exclude-standard -z -- "$@") >"$list"
}

# Touch a list made by own_list. `touch -c`: a tracked file deleted in the worktree is not created.
touch_list() { xargs -0 touch -c <"$1"; }

clone() {
    if [ -n "${CARGO_TARGET_DIR:-}" ]; then return 0; fi # CI's persistent target, or a caller's own
    if [ -e "$target" ]; then return 0; fi               # the worktree's own target: never replaced
    local want seed started tmp list
    list=$(mktemp "${TMPDIR:-/tmp}/cargo-target-seed.XXXXXX")
    tmp=$target.seeding.$$
    cleanup_tmp=$tmp cleanup_list=$list
    want=$(key)
    seed=$root/$want
    if [ ! -d "$seed" ]; then
        seed=$(seeds | sed -n 1p)
        if [ -z "$seed" ]; then
            echo "seed: none under $root, so this first build is cold; build one with \`cargo-target-seed build\`"
            return 0
        fi
        echo "seed: no seed for key $want, cloning the newest ($(basename "$seed")); \`cargo-target-seed build\` makes this key's"
        own_list "$list" "${own[@]}" ${keypaths[@]+"${keypaths[@]}"}
    else
        own_list "$list" "${own[@]}"
    fi
    # Fail closed before cloning: an --own that matches nothing would leave the clone untouched.
    [ -s "$list" ] || die "--own matched no file in $repo; a clone without the touch could pass a check on code it never compiled"
    started=$(date +%s)
    clone_dir "$seed" "$tmp"
    mv "$tmp" "$target"
    touch_list "$list"
    echo "seed: cloned $(basename "$seed") into ${wsprefix}target in $(($(date +%s) - started)) s; the workspace's own crates rebuild"
}

# An old seed goes a day after its successor exists; a temporary directory a day after it was started.
prune() {
    local successor="" seed
    while read -r seed; do
        if [ -n "$successor" ] && [ $(($(date +%s) - $(mtime "$successor"))) -gt 86400 ]; then
            echo "seed: pruning $(basename "$seed") (its successor $(basename "$successor") is older than a day)"
            rm -rf "$seed"
        else
            successor=$seed
        fi
    done < <(seeds)
    find "$root" -maxdepth 1 -name '.tmp-*' -mtime +0 -exec rm -rf {} + 2>/dev/null || true
}

build() {
    [ ${#cmd[@]} -gt 0 ] || { echo "cargo-target-seed: build needs \`-- <command...>\`" >&2; usage; }
    local want seed tmp from list
    want=$(key)
    seed=$root/$want
    if [ -d "$seed" ]; then
        echo "seed: $want exists"
        prune
        return 0
    fi
    mkdir -p "$root"
    tmp=$root/.tmp-$want-$$
    list=$(mktemp "${TMPDIR:-/tmp}/cargo-target-seed.XXXXXX")
    cleanup_tmp=$tmp cleanup_list=$list
    # Start warm: from this worktree's own target, else from the newest seed (then touched like any clone).
    from=$target
    if [ ! -d "$from" ]; then
        from=$(seeds | sed -n 1p)
        if [ -n "$from" ]; then
            own_list "$list" "${own[@]}" ${keypaths[@]+"${keypaths[@]}"}
            [ -s "$list" ] || die "--own matched no file in $repo"
            touch_list "$list"
        fi
    fi
    if [ -n "$from" ]; then clone_dir "$from" "$tmp"; else mkdir -p "$tmp"; fi
    echo "seed: building $want in $tmp${from:+ (from $from)}"
    # The command runs before the rename, so a broken master never becomes the seed every worktree clones.
    if ! (cd "$wsdir" && CARGO_TARGET_DIR=$tmp "${cmd[@]}"); then
        echo "seed: the build command failed, no seed made for $want" >&2
        return 1
    fi
    if [ -e "$seed" ]; then
        echo "seed: $want appeared meanwhile, keeping it"
        return 0
    fi
    touch "$tmp"
    mv "$tmp" "$seed"
    echo "seed: $want in place ($(du -sh "$seed" | cut -f1))"
    prune
}

case "$verb" in
    key) key ;;
    clone) clone ;;
    build) build ;;
esac
