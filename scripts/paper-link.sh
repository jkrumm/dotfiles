#!/bin/bash
# paper-link.sh: paper on PATH on this Mac (rules/clis.md, skill documents).
#
# paper (~/SourceRoot/paper, a private repo) is the one CLI for scan, inbox, the document index and print. Both Macs run it
# straight from a checkout that follows origin/master; this script makes that true on the machine it runs on:
#   1. no checkout under ~/SourceRoot: clone it over https; a checkout: fast-forward it (a refusal is a warning, not a stop);
#   2. `make install` in the checkout links ~/.local/bin/paper (the repo owns that recipe);
#   3. on the MacBook (secrets backend `op`) a missing ~/.config/paper/config.json is written with host "mini", so scan,
#      inbox and docs verbs run on the mini, where the one scanner state lives. An existing config is never touched;
#   4. retires the old print wrapper: ~/.local/bin/print, when it is a link to this repo's scripts/print.sh (even a dead one).
# Needs no 1Password, sudo or SSH identity: setup and the MacBook's dotfiles-sync (config/macbook-sync.tsv) both run it.
# Exit 0 when paper is linked; 1 when there is no checkout and none could be cloned, or the install failed.
#
# Test seam (tests only): PAPER_LINK_REMOTE replaces the https remote. Runs under /bin/bash 3.2.
set -u

REMOTE="${PAPER_LINK_REMOTE:-https://github.com/jkrumm/paper.git}"
SRC="$HOME/SourceRoot/paper"
CONFIG="$HOME/.config/paper/config.json"
BACKEND="$HOME/.config/secrets/backend"

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/.bun/bin:$PATH"
export GIT_TERMINAL_PROMPT=0

# 4. the old print wrapper
legacy="$HOME/.local/bin/print"
if [ -L "$legacy" ]; then
  case "$(readlink "$legacy")" in
    */dotfiles/scripts/print.sh | */scripts/print.sh)
      rm -f "$legacy"
      echo "paper-link: removed the old $legacy"
      ;;
  esac
fi

# 1. the checkout
if [ -e "$SRC/.git" ]; then
  git -C "$SRC" pull --ff-only --quiet || echo "paper-link: warning: $SRC did not fast-forward (dirty, diverged or no access); linking what is there"
else
  mkdir -p "$HOME/SourceRoot"
  git clone --quiet "$REMOTE" "$SRC" || {
    echo "paper-link: FAIL - no checkout at $SRC and the clone of $REMOTE failed (the repo is private: the first clone needs a stored https git credential)"
    exit 1
  }
fi

# 2. the link
make --no-print-directory -C "$SRC" install || {
  echo "paper-link: FAIL - make install in $SRC failed"
  exit 1
}

# 3. the MacBook forwards scan, inbox and docs to the mini
if [ "$(cat "$BACKEND" 2>/dev/null)" = "op" ]; then
  if [ -e "$CONFIG" ]; then
    echo "paper-link: $CONFIG exists, left as is"
  else
    mkdir -p "$(dirname "$CONFIG")"
    printf '{\n  "host": "mini"\n}\n' >"$CONFIG"
    echo "paper-link: wrote $CONFIG (host: mini)"
  fi
fi
