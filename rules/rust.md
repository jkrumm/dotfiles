---
description: Rust in any of our repos — pins and locked builds, errors, concurrency, tests, and where the proven build-cost, CI, cross-target and desktop-release patterns live (weatherorb, shutterflow).
paths: ["**/*.rs", "**/Cargo.toml", "**/rust-toolchain.toml"]
---

# Rust

A repo's own Rust rules win (weatherorb `.claude/rules/rust.md`, shutterflow `AGENTS.md` §Conventions and each crate's `AGENTS.md`). This is what holds in every repo, and where to copy a pattern from instead of inventing it.

## Writing it

- **Compile before you reason.** `cargo check -p <crate>` after each edit; read the first error. An API you remember may not exist in the pinned version: read `~/.cargo/registry/src` or `cargo doc -p <dep>` before calling it.
- **Pins.** `rust-toolchain.toml` pins the toolchain through rustup; a bump is its own commit. Every external dependency is declared once in `[workspace.dependencies]`, a crate says `dep.workspace = true`. `--locked` on every cargo command. A conflict in `Cargo.lock` is regenerated (`cargo update --workspace --offline`), never hand-merged.
- **Errors.** A library crate returns its own `thiserror` enum; `anyhow` only in a binary. `?` over `unwrap`; an `unwrap`/`expect` outside tests names the invariant that makes it safe.
- **Lints are the first rule set.** clippy runs with `-D warnings`; a suppression is `#[expect(clippy::<lint>, reason = "…")]` on the smallest item. New workspace: start from weatherorb `core/Cargo.toml` `[workspace.lints]` and `core/clippy.toml`.
- **Concurrency.** CPU and blocking file work stay off the async runtime (`spawn_blocking`, rayon). No lock held across `.await`.
- **`unsafe`** lives in one named module of one crate, behind a safe API (shutterflow `crates/imageio/src/ffi`).
- **Tests** call the changed code through the crate's public interface; I/O sits behind a port with a production and a test adapter, injected, not mocked. A fix starts with a test that fails.
- **Cargo tools are pinned and repo-local**: `cargo install --locked --version =<x> --root target/<tool>`, never a global install the next machine lacks.

## Building it on the mini

Several leads build at once on 12 cores and 32 GiB. Measured patterns, copy them:

| Need | Pattern | Reference |
|-|-|-|
| A new worktree without a cold build | a finished `target` cloned copy-on-write (`cp -c`), own sources touched afterwards; 182 s became 6.6 s | weatherorb `core/seed.sh`, `docs/v2/design/11-foundation.md` §4.3 |
| The same without a seed | sccache from the Makefile's environment (only when installed, with `CARGO_INCREMENTAL=0`), never in `.cargo/config.toml`; 81 % hits in a fresh worktree | shutterflow `docs/engineering/build-cache.md` |
| One `target` per worktree | a shared `CARGO_TARGET_DIR` serialises every build on its lock | both |
| A job cap | five leads at cargo's default jobs took the mini to load 152; cap cargo and the test runner | weatherorb `core/core.mk` `CORE_JOBS` |
| Tests of what changed only | nextest's `rdeps()` filter from an xtask, or a script over the crate graph | weatherorb `cargo xtask affected`, shutterflow `scripts/check-changed/` |
| A test runner with timeouts and JUnit | cargo-nextest, config in `.config/nextest.toml` | weatherorb `core/.config/nextest.toml` |

## CI, other platforms, release

- **CI of a private repo** runs on the VPS runner, which has no C compiler: build in a container image with the toolchain, and keep the target directory and cargo home on the runner between jobs (weatherorb `core/ci/Dockerfile`, `make core-ci`; shutterflow `.github/workflows/portability.yml` for the throwaway variant).
- **Linux and Windows from a Mac:** `cargo check --target <triple>` with a stub C toolchain proves the code compiles, links nothing (shutterflow `scripts/check-targets/`, `make check-targets`). Platform-only std APIs sit behind one module.
- **Supply chain:** `cargo deny` (licences, bans, sources) and `cargo machete` in the gate (weatherorb `core/deny.toml`).
- **A desktop app (Tauri):** signing, notarization, the update feed and the other platforms are decided in shutterflow `docs/decisions/0060-distribution-and-updates.md`; the Apple side follows `dotfiles/docs/apple-signing.md`.
