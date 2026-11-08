# shellcheck shell=bash
# bun-bin.sh — resolve the directory holding bun (and its bunx shim) without
# trusting the caller's PATH. A non-login make (launchd, an agent dispatch, a
# herdr-core terminal) inherits no login shell's PATH, and the bun official
# installer puts the binaries in ~/.bun/bin — a directory nothing in this
# repo's non-interactive PATH block (~/.zshenv) covers. Callers resolve it
# here rather than trusting PATH.
#
# bun_bin_dir prints the first directory holding an executable `bun` and
# returns 0, or returns 1 with no output when none does. Candidate order
# mirrors collie-ctl.sh's own resolve_bun: an explicit install root, then the
# common Homebrew prefixes.
bun_bin_dir() {
  local d
  if command -v bun >/dev/null 2>&1; then
    dirname "$(command -v bun)"
    return 0
  fi
  for d in \
    "${BUN_INSTALL:-${HOME}/.bun}/bin" \
    "${HOME}/.local/bin" \
    /opt/homebrew/bin \
    /usr/local/bin; do
    if [ -x "$d/bun" ]; then
      printf '%s\n' "$d"
      return 0
    fi
  done
  return 1
}

# bunx_path_dir BUN_DIR SHIM_DIR — print the directory to put in front of PATH so
# `bunx` resolves. bun's `bunx` is a shim next to `bun`, and an install can lack it
# (the mini's ~/.bun/bin held bun alone: `bun run typecheck` → `bunx tsc` died with
# exit 127). Prints BUN_DIR when it, or a bunx elsewhere on PATH, already works;
# otherwise writes SHIM_DIR/bunx (`exec bun x "$@"`, which is exactly what bunx is)
# and prints SHIM_DIR.
bunx_path_dir() {
  local bun_dir="$1" shim_dir="$2"
  if [ -x "$bun_dir/bunx" ] || PATH="$bun_dir:$PATH" command -v bunx >/dev/null 2>&1; then
    printf '%s\n' "$bun_dir"
    return 0
  fi
  mkdir -p "$shim_dir" || return 1
  printf '#!/bin/sh\nexec "%s/bun" x "$@"\n' "$bun_dir" > "$shim_dir/bunx" || return 1
  chmod +x "$shim_dir/bunx" || return 1
  printf '%s\n' "$shim_dir"
}

# Executed (not sourced): print the resolved directory and exit on its code.
# The collie-setup recipe captures it as `$(bash …/bun-bin.sh)`; sourcing it
# only defines the function and prints nothing.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  bun_bin_dir
fi
