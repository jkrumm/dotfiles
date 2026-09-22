# shellcheck shell=bash
# bun-bin.sh — resolve the directory holding bun (and its bunx shim) without
# trusting the caller's PATH. A non-login make (launchd, an agent dispatch, a
# herdr pane) inherits no login shell's PATH, and the bun official installer
# puts the binaries in ~/.bun/bin — a directory nothing in this repo's
# non-interactive PATH block (~/.zshenv) covers. Collie's plugin rebuild runs
# `bun`/`bunx` from the plugin's own scripts, so whatever PATH collie-setup
# hands `herdr plugin install` is what the rebuild gets; resolving here and
# prepending it there is the same treatment collie-ctl.sh gives the bridge.
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

# Executed (not sourced): print the resolved directory and exit on its code.
# The collie-setup recipe captures it as `$(bash …/bun-bin.sh)`; sourcing it
# only defines the function and prints nothing.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  bun_bin_dir
fi
