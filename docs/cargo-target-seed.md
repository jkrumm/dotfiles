# cargo-target-seed — a warm `target/` for every new Rust worktree

`scripts/cargo-target-seed.sh` (linked by `make setup` to `~/.local/bin/cargo-target-seed`; test: `make cargo-target-seed-test`)
is the one tool for every Rust repo on the mini. It generalises weatherorb's `core/seed.sh`, which measured 6.6 s instead of
182 s for a new worktree's dependencies. A repo's Makefile calls it when `command -v cargo-target-seed` succeeds and builds cold
when it does not, like sccache.

| Verb | Does |
|-|-|
| `key` | the toolchain (`rustc --version`, run in the workspace) plus a sha256 over `Cargo.lock`, every `Cargo.toml`, `.cargo/config.toml`, `rust-toolchain.toml` and each `--key-path` tree; untracked files count |
| `clone` | no `CARGO_TARGET_DIR`, no `<workspace>/target`: `cp -c` the key's seed (else the newest) into it, then touch every `--own` file |
| `build -- <cmd…>` | run `<cmd>` in the workspace with `CARGO_TARGET_DIR` at a temp dir (warm from this worktree's `target/`, else the newest seed); rename it into place only on exit 0; prune |
| `jobs` | the cargo job cap: `CARGO_SEED_JOBS`, else cores / 3, at least 2 (4 on the mini) |

Options come before the verb, paths are relative to the repo root: `--workspace DIR` (default: the root), `--own PATH` (repeat;
**required** for `clone` and `build`), `--key-path PATH` (repeat), `--name N` (default: the main repo's directory name, the same
from every worktree). Seeds live in `~/cache/<name>/seed/<key>` (`CARGO_SEED_ROOT` overrides). `clone` and `build` also write the key-deciding options (`--workspace`, `--key-path`, one argument per line) to `seed/.args`: the disk sweep's `seeds` step runs `cargo-target-seed $(cat .args) key` in the repo's main checkout to learn the default branch's key.

## The touch rule

Cargo decides freshness by file time and a clone keeps the seed's times, so a source file older than the seed counts as built
and a check can pass on code it never compiled. After every clone each `--own` file is touched (tracked and untracked, never
recreating a deleted one); a seed of another key also gets the `--key-path` trees touched. `--own` has no default and must match
a file: a missing or empty one fails before anything is cloned. The rule lives only in this script and its test.

## The relocation

`build` compiles in `<root>/.tmp-<key>-<pid>` and renames it, so a build script's cached record (`build/<pkg>/output`,
`root-output`, the `*-permission-files` lists in `out/`) names a directory that is gone, and cargo trusts it as fresh: tauri's
`DEP_*` paths fail with "No such file", a final link looks for aws-lc and SQLite in it. After a clone (and after a warm start of
`build`) every `.tmp-*` path in those files is rewritten to the directory the target now lives in. Each file keeps its time to the
nanosecond: a newer `output` makes cargo rerun the script and rebuild the package and everything above it, the cold build again
(46 crates in shutterflow, measured). Objects and rlibs carry the path only in debuginfo and are left alone. Idempotent; shutterflow's
`scripts/target-seed/relocate.sh` workaround is a no-op once this is live and can go.

## In a repo's Makefile

```make
SEED := $(shell command -v cargo-target-seed 2>/dev/null)
SEED_ARGS := --workspace core --own core/crates --own core/xtask --key-path core/vendor
JOBS ?= $(if $(SEED),$(shell cargo-target-seed jobs),4)
export CARGO_BUILD_JOBS := $(JOBS)
check: ; $(if $(SEED),cargo-target-seed $(SEED_ARGS) clone;) …
target-seed: ; cargo-target-seed $(SEED_ARGS) build -- sh -c 'cargo clippy --workspace --all-targets --locked -- -D warnings && cargo nextest run --workspace --locked'
```

`build` runs the repo's own gate commands, so the seed holds exactly the artifacts the gates use (clippy's check artifacts and the
test builds differ: seed both) and a broken master never becomes a seed. Whoever lands a change to a key input runs
`target-seed`; an old seed goes a day after its successor exists, and `disk-sweep.sh seeds` (daily) removes every seed a day old except the current key's and the newest, for a repo nobody builds again (`docs/disk.md` §Sweeps). A seed is about the size of `target/`; a clone costs no disk
until files change.

## Not here

Adoption by weatherorb (replace `core/seed.sh`) and shutterflow (its `target-seed` plan row calls the tool), and shutterflow's
sccache-versus-seed measurement, belong to those repos. A job cap derived from the factory's live lead count is later work, if
the static cap is ever measured too low or too high.
